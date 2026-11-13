using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace Locman7
{
    /// <summary>Источник из каталога «Лоцмана» или свой (ссылка подписки либо набор ключей).</summary>
    sealed class Source
    {
        public string Id, Title, Mode = "any", Description = "";
        public string[] Mirrors = new string[0];
        public bool Recommended, Mine;
        public string Keys; // свои ключи вместо ссылки

        public Dictionary<string, object> ToJson() => new Dictionary<string, object> {
            { "id", Id }, { "title", Title }, { "mirrors", Mirrors }, { "keys", Keys },
        };
    }

    /// <summary>Настройки в %APPDATA%\Locman7\settings.json.</summary>
    sealed class Settings
    {
        public string Mode = "black"; // black — обычный интернет, white — белые списки, any — все
        public bool DirectRu = true, Autostart, StartMinimized, CloseToTray = true;

        /// <summary>true — весь трафик через TUN (Wintun, нужны права администратора); false — системный прокси.</summary>
        public bool Tun;

        /// <summary>dark или light.</summary>
        public string Theme = "dark";

        public bool AutoServices;
        public HashSet<string> Enabled = new HashSet<string>(), Disabled = new HashSet<string>();
        public List<Source> Mine = new List<Source>();
        public string LastNode;
        public int SocksPort = 10808, HttpPort = 10809;

        public static string Dir
        {
            get
            {
                var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Locman7");
                Directory.CreateDirectory(d);
                return d;
            }
        }

        static string FilePath => Path.Combine(Dir, "settings.json");

        public static Settings Load()
        {
            var s = new Settings();
            try
            {
                if (!(Json.Parse(File.ReadAllText(FilePath, Encoding.UTF8)) is Dictionary<string, object> j)) return s;
                s.Mode = Json.Str(j, "mode") is string m && m.Length > 0 ? m : "black";
                s.DirectRu = !Equals(j.ContainsKey("directRu") ? j["directRu"] : true, false);
                s.Autostart = Equals(j.ContainsKey("autostart") ? j["autostart"] : false, true);
                s.StartMinimized = Equals(j.ContainsKey("startMinimized") ? j["startMinimized"] : false, true);
                s.CloseToTray = !Equals(j.ContainsKey("closeToTray") ? j["closeToTray"] : true, false);
                s.LastNode = Json.Str(j, "lastNode");
                s.Tun = Equals(j.ContainsKey("tun") ? j["tun"] : false, true);
                s.AutoServices = Equals(j.ContainsKey("autoServices") ? j["autoServices"] : false, true);
                s.Theme = Json.Str(j, "theme") == "light" ? "light" : "dark";
                s.Enabled = Strings(j, "enabled");
                s.Disabled = Strings(j, "disabled");
                if (j.TryGetValue("mine", out var mine) && mine is object[] arr)
                {
                    foreach (var o in arr.OfType<Dictionary<string, object>>())
                    {
                        var src = new Source { Id = Json.Str(o, "id"), Title = Json.Str(o, "title"), Mine = true };
                        if (o.TryGetValue("mirrors", out var mm) && mm is object[] ma) src.Mirrors = ma.Select(x => x.ToString()).ToArray();
                        var keys = Json.Str(o, "keys");
                        src.Keys = keys.Length > 0 ? keys : null;
                        if (src.Id.Length > 0) s.Mine.Add(src);
                    }
                }
            }
            catch { }
            return s;
        }

        static HashSet<string> Strings(Dictionary<string, object> j, string key) =>
            j.TryGetValue(key, out var v) && v is object[] a ? new HashSet<string>(a.Select(x => x.ToString())) : new HashSet<string>();

        public void Save()
        {
            var j = new Dictionary<string, object> {
                { "mode", Mode }, { "directRu", DirectRu }, { "autostart", Autostart }, { "startMinimized", StartMinimized },
                { "closeToTray", CloseToTray }, { "lastNode", LastNode }, { "tun", Tun }, { "theme", Theme },
                { "autoServices", AutoServices }, { "enabled", Enabled.ToArray() },
                { "disabled", Disabled.ToArray() }, { "mine", Mine.Select(m => m.ToJson()).ToArray() },
            };
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, Json.Write(j), Encoding.UTF8);
            if (File.Exists(FilePath)) File.Replace(tmp, FilePath, null); else File.Move(tmp, FilePath);
        }
    }

    static class Net
    {
        public const string Repo = "atomicpel/locman";
        public const string UserAgent = "Locman7/1 (Windows 7)";

        /// <summary>Скачать текст: через туннель, если подключены (на Win7 без обновлений часть сайтов иначе
        /// не открывается), потом напрямую; по очереди все зеркала.</summary>
        public static string Get(IEnumerable<string> urls, int? viaHttpProxyPort, int timeoutMs = 20000)
        {
            Exception last = null;
            var routes = viaHttpProxyPort.HasValue ? new int?[] { viaHttpProxyPort, null } : new int?[] { null };
            foreach (var url in urls)
                foreach (var proxy in routes)
                {
                    try
                    {
                        var req = (HttpWebRequest)WebRequest.Create(url);
                        req.UserAgent = UserAgent;
                        req.Timeout = timeoutMs;
                        req.ReadWriteTimeout = timeoutMs;
                        req.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
                        req.Proxy = proxy.HasValue ? new WebProxy("127.0.0.1", proxy.Value) : null;
                        using (var resp = (HttpWebResponse)req.GetResponse())
                        using (var r = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                        {
                            var body = r.ReadToEnd();
                            if (body.Length > 0) return body;
                        }
                    }
                    catch (Exception e) { last = e; }
                }
            throw last ?? new WebException("пусто");
        }

        public static int FreePort()
        {
            var l = new TcpListener(IPAddress.Loopback, 0);
            l.Start();
            var port = ((IPEndPoint)l.LocalEndpoint).Port;
            l.Stop();
            return port;
        }

        /// <summary>TCP-рукопожатие с сервером, мс; -1 — нет ответа.</summary>
        public static async Task<int> TcpPing(string host, int port, int timeoutMs)
        {
            var sw = Stopwatch.StartNew();
            using (var c = new TcpClient())
            {
                try
                {
                    var connect = c.ConnectAsync(host, port);
                    var done = await Task.WhenAny(connect, Task.Delay(timeoutMs)).ConfigureAwait(false);
                    if (done != connect || !c.Connected) return -1;
                    return Math.Max(1, (int)sw.ElapsedMilliseconds);
                }
                catch { return -1; }
            }
        }

        /// <summary>Запрос через локальный HTTP-вход Xray: время до ответа, мс; -1 — не прошёл.
        /// minBytes &gt; 0 — ещё и скачать столько данных (заморозка ТСПУ пропускает первые ~16 КБ).</summary>
        public static int ProbeVia(int httpPort, string url, int timeoutMs, int minBytes = 0)
        {
            var sw = Stopwatch.StartNew();
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(url);
                req.Proxy = new WebProxy("127.0.0.1", httpPort);
                req.UserAgent = "Mozilla/5.0";
                req.Timeout = timeoutMs;
                req.ReadWriteTimeout = timeoutMs;
                req.KeepAlive = false;
                using (var resp = (HttpWebResponse)req.GetResponse())
                {
                    var code = (int)resp.StatusCode;
                    if (code != 204 && code != 200) return -1;
                    if (minBytes > 0)
                    {
                        var buf = new byte[16384];
                        var total = 0;
                        using (var st = resp.GetResponseStream())
                        {
                            int n;
                            while (total < minBytes && (n = st.Read(buf, 0, buf.Length)) > 0) total += n;
                        }
                        if (total < minBytes) return -1;
                    }
                    return Math.Max(1, (int)sw.ElapsedMilliseconds);
                }
            }
            catch { return -1; }
        }
    }

    /// <summary>Процесс xray.exe: в «задании» Windows, чтобы закрывался вместе с программой.</summary>
    sealed class XrayProcess : IDisposable
    {
        static readonly IntPtr Job = CreateJob();
        readonly Process _p;
        readonly string _config;
        readonly StringBuilder _err = new StringBuilder();

        public static string Exe => Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "xray.exe");

        public XrayProcess(string configJson, Action<string> log = null)
        {
            _config = Path.Combine(Settings.Dir, "run-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".json");
            File.WriteAllText(_config, configJson, new UTF8Encoding(false));
            var psi = new ProcessStartInfo(Exe, "run -c \"" + _config + "\"")
            {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true,
                WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory,
            };
            psi.EnvironmentVariables["XRAY_LOCATION_ASSET"] = AppDomain.CurrentDomain.BaseDirectory;
            _p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            DataReceivedEventHandler onLine = (s, e) =>
            {
                if (e.Data == null) return;
                lock (_err) { if (_err.Length < 8000) _err.AppendLine(e.Data); }
                log?.Invoke(e.Data);
            };
            _p.OutputDataReceived += onLine;
            _p.ErrorDataReceived += onLine;
            _p.Start();
            if (Job != IntPtr.Zero) AssignProcessToJobObject(Job, _p.Handle);
            _p.BeginErrorReadLine();
            _p.BeginOutputReadLine();
        }

        public bool Exited { get { try { return _p.HasExited; } catch { return true; } } }

        public string Errors { get { lock (_err) return _err.ToString(); } }

        /// <summary>Ждём, что ядро поднялось (порт слушается) и не упало.</summary>
        public bool WaitReady(int port, int timeoutMs)
        {
            var sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < timeoutMs)
            {
                if (Exited) return false;
                try
                {
                    using (var c = new TcpClient())
                    {
                        c.Connect(IPAddress.Loopback, port);
                        return true;
                    }
                }
                catch { Thread.Sleep(100); }
            }
            return !Exited;
        }

        public void Dispose()
        {
            try { if (!_p.HasExited) _p.Kill(); } catch { }
            try { _p.WaitForExit(2000); } catch { }
            try { _p.Dispose(); } catch { }
            try { File.Delete(_config); } catch { }
        }

        static IntPtr CreateJob()
        {
            try
            {
                var job = CreateJobObject(IntPtr.Zero, null);
                var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                info.BasicLimitInformation.LimitFlags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                var len = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
                var ptr = Marshal.AllocHGlobal(len);
                Marshal.StructureToPtr(info, ptr, false);
                SetInformationJobObject(job, 9, ptr, (uint)len);
                Marshal.FreeHGlobal(ptr);
                return job;
            }
            catch { return IntPtr.Zero; }
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr CreateJobObject(IntPtr a, string name);

        [DllImport("kernel32.dll")]
        static extern bool SetInformationJobObject(IntPtr job, int type, IntPtr info, uint len);

        [DllImport("kernel32.dll")]
        static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct IO_COUNTERS { public ulong a, b, c, d, e, f; }

        [StructLayout(LayoutKind.Sequential)]
        struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }
    }

    /// <summary>Системный прокси Windows (WinINet): Internet Explorer, Chrome, Edge, Firefox по умолчанию.</summary>
    static class SysProxy
    {
        const string Key = @"Software\Microsoft\Windows\CurrentVersion\Internet Settings";
        const string Bypass = "localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.2*;172.30.*;172.31.*;192.168.*;<local>";

        public static void Set(int httpPort)
        {
            using (var k = Registry.CurrentUser.CreateSubKey(Key))
            {
                k.SetValue("ProxyEnable", 1, RegistryValueKind.DWord);
                k.SetValue("ProxyServer", "127.0.0.1:" + httpPort);
                k.SetValue("ProxyOverride", Bypass);
            }
            Refresh();
        }

        /// <summary>Снимаем, только если прокси наш (чужой не трогаем).</summary>
        public static void Clear(int httpPort)
        {
            using (var k = Registry.CurrentUser.CreateSubKey(Key))
            {
                if ((k.GetValue("ProxyServer") as string) != "127.0.0.1:" + httpPort) return;
                k.SetValue("ProxyEnable", 0, RegistryValueKind.DWord);
            }
            Refresh();
        }

        static void Refresh()
        {
            InternetSetOption(IntPtr.Zero, 39, IntPtr.Zero, 0); // INTERNET_OPTION_SETTINGS_CHANGED
            InternetSetOption(IntPtr.Zero, 37, IntPtr.Zero, 0); // INTERNET_OPTION_REFRESH
        }

        [DllImport("wininet.dll", SetLastError = true)]
        static extern bool InternetSetOption(IntPtr h, int option, IntPtr buffer, int len);
    }

    static class Autostart
    {
        const string Run = @"Software\Microsoft\Windows\CurrentVersion\Run";

        /// <summary>Обычный режим — ключ Run. Режим «весь трафик» — задание планировщика
        /// «с наивысшими правами»: так программа стартует с правами администратора без запроса.</summary>
        public static void Apply(bool on, bool admin)
        {
            using (var k = Registry.CurrentUser.CreateSubKey(Run))
            {
                if (on && !admin) k.SetValue("Locman7", "\"" + AppInfo.ExecutablePath + "\" --tray");
                else k.DeleteValue("Locman7", false);
            }
            if (on && admin)
                Schtasks("/Create /F /TN \"Locman7\" /SC ONLOGON /RL HIGHEST /TR \"\\\"" + AppInfo.ExecutablePath + "\\\" --tray\"");
            else
                Schtasks("/Delete /F /TN \"Locman7\"");
        }

        static void Schtasks(string args)
        {
            try
            {
                var p = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("schtasks.exe", args)
                {
                    UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
                });
                p?.WaitForExit(10000);
            }
            catch { }
        }
    }

    static class AppInfo
    {
        public static string ExecutablePath => Assembly.GetExecutingAssembly().Location;
        public static string Version => Assembly.GetExecutingAssembly().GetName().Version.ToString(3);
    }

    /// <summary>Каталог источников: с GitHub (или jsDelivr), иначе — встроенный в программу.</summary>
    static class Catalog
    {
        public static List<Source> Load(int? viaPort, Action<string> log)
        {
            var cache = Path.Combine(Settings.Dir, "catalog.json");
            string text = null;
            try
            {
                text = Net.Get(new[] {
                    $"https://raw.githubusercontent.com/{Net.Repo}/main/catalog/catalog.json",
                    $"https://cdn.jsdelivr.net/gh/{Net.Repo}@main/catalog/catalog.json",
                }, viaPort);
                var parsed = Parse(text);
                if (parsed.Count > 0)
                {
                    File.WriteAllText(cache, text, Encoding.UTF8);
                    return parsed;
                }
            }
            catch (Exception e) { log?.Invoke("Каталог не скачался: " + e.Message); }
            try { if (File.Exists(cache)) return Parse(File.ReadAllText(cache, Encoding.UTF8)); } catch { }
            using (var st = Assembly.GetExecutingAssembly().GetManifestResourceStream("catalog.json"))
            using (var r = new StreamReader(st, Encoding.UTF8))
                return Parse(r.ReadToEnd());
        }

        static List<Source> Parse(string text)
        {
            var list = new List<Source>();
            if (!(Json.Parse(text) is Dictionary<string, object> j) || !(j["sources"] is object[] arr)) return list;
            foreach (var o in arr.OfType<Dictionary<string, object>>())
            {
                if (Json.Str(o, "status") == "dead") continue;
                var src = new Source
                {
                    Id = Json.Str(o, "id"), Title = Json.Str(o, "title"), Mode = Json.Str(o, "mode"),
                    Description = Json.Str(o, "description"),
                    Recommended = Equals(o.ContainsKey("recommended") ? o["recommended"] : false, true),
                };
                if (o.TryGetValue("mirrors", out var m) && m is object[] ma) src.Mirrors = ma.Select(x => x.ToString()).ToArray();
                if (src.Id.Length > 0 && src.Mirrors.Length > 0) list.Add(src);
            }
            return list;
        }
    }
}
