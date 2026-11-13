using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;

namespace Locman7
{
    /// <summary>Маршруты в туннель: весь IPv4, кроме частных, служебных и групповых подсетей
    /// (локальная сеть остаётся мимо узла). Как routes.dart.</summary>
    static class Routes
    {
        static readonly string[] Excluded = {
            "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
            "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/3",
        };

        public static List<string> PublicIpv4()
        {
            var ex = Excluded.Select(Parse).ToList();
            var outList = new List<string>();
            Walk(0, 0, ex, outList);
            return outList;
        }

        static Tuple<uint, int> Parse(string cidr)
        {
            var parts = cidr.Split('/');
            uint n = 0;
            foreach (var p in parts[0].Split('.')) n = (n << 8) | uint.Parse(p);
            return Tuple.Create(n, int.Parse(parts[1]));
        }

        static bool Overlaps(uint start, int len, Tuple<uint, int> e)
        {
            var l = Math.Min(len, e.Item2);
            var mask = l == 0 ? 0u : 0xFFFFFFFFu << (32 - l);
            return (start & mask) == (e.Item1 & mask);
        }

        static void Walk(uint start, int len, List<Tuple<uint, int>> ex, List<string> outList)
        {
            var hits = ex.Where(e => Overlaps(start, len, e)).ToList();
            if (hits.Count == 0) { outList.Add(Format(start) + "/" + len); return; }
            if (hits.Any(e => e.Item2 <= len)) return;
            Walk(start, len + 1, ex, outList);
            Walk(start | (1u << (31 - len)), len + 1, ex, outList);
        }

        static string Format(uint n) => string.Join(".", new[] { 24, 16, 8, 0 }.Select(s => ((n >> s) & 0xFF).ToString()));
    }

    /// <summary>Ссылка «Поделиться своими» из телефона: locman://import?data=… (gzip + base64url).</summary>
    static class Share
    {
        public static List<string> Unpack(string text)
        {
            var result = new List<string>();
            foreach (Match m in Regex.Matches(text ?? "", @"data=([A-Za-z0-9_\-+/=]+)"))
            {
                try
                {
                    var clean = m.Groups[1].Value.Replace('-', '+').Replace('_', '/').TrimEnd('=');
                    clean += new string('=', (4 - clean.Length % 4) % 4);
                    using (var gz = new GZipStream(new MemoryStream(Convert.FromBase64String(clean)), CompressionMode.Decompress))
                    using (var r = new StreamReader(gz, Encoding.UTF8))
                    {
                        var body = r.ReadToEnd();
                        if (body.Length > 1024 * 1024) continue;
                        result.AddRange(Regex.Split(body, @"\s+").Where(l => l.Contains("://") && l.Length <= 4096));
                    }
                }
                catch { }
            }
            return result;
        }
    }

    /// <summary>Проверка сервисов через туннель. Claude и ChatGPT стоят за Cloudflare и отвечают
    /// проверкой на робота — для них спрашиваем служебную /cdn-cgi/trace (страна выхода узла).</summary>
    static class Services
    {
        public static readonly string[][] List = {
            new[] { "gemini", "Gemini", "https://gemini.google.com/app" },
            new[] { "chatgpt", "ChatGPT", "https://chatgpt.com/" },
            new[] { "claude", "Claude", "https://claude.ai/login" },
            new[] { "youtube", "YouTube", "https://www.youtube.com/" },
        };

        static readonly HashSet<string> Anthropic = new HashSet<string>((
            "AL DZ AD AO AG AR AM AU AT AZ BS BH BD BB BE BZ BJ BT BO BA BW BR BN BG BF BI CV KH CM CA CF TD CL CO KM CG CD CR " +
            "CI HR CY CZ DK DJ DM DO EC EG SV GQ ER EE SZ ET FJ FI FR GA GM GE DE GH GR GD GT GN GW GY HT HN HU IS IN ID IQ IE " +
            "IL IT JM JP JO KZ KE KI KW KG LA LV LB LS LR LY LI LT LU MG MW MY MV ML MT MH MR MU MX FM MD MC MN ME MA MZ NA NR " +
            "NP NL NZ NI NE NG MK NO OM PK PW PS PA PG PY PE PH PL PT QA RO RW KN LC VC WS SM ST SA SN RS SC SL SG SK SI SO SB " +
            "ZA KR SS ES LK SD SR SE CH TW TJ TZ TH TL TG TO TT TN TR TM TV UG UA AE GB US UY UZ VU VA VN ZM ZW " +
            "PR GU VI AS MP UM GF GP MQ RE YT PF NC PM BL MF WF GL FO AW CW SX BQ GI BM KY VG TC AI MS FK IM JE GG CX CC NF AX")
            .Split(' '));

        static readonly HashSet<string> OpenAiBlocked = new HashSet<string> { "RU", "BY", "CN", "HK", "MO", "IR", "KP", "SY", "CU" };

        static readonly string[] Region = {
            "unavailable-in-region", "unsupported_country", "unsupported-country", "not available in your country",
            "not available in your region", "not supported in your country", "isn't supported in your country",
            "isn’t supported in your country", "not currently supported in your country", "isn't currently supported in your country",
            "isn’t currently supported in your country",
        };

        static readonly string[] Bot = { "cf-chl", "challenge-platform", "just a moment...", "/sorry/index", "unusual traffic", "g-recaptcha", "hcaptcha" };

        /// <summary>(успех, пояснение).</summary>
        public static Tuple<bool, string> Check(string id, string name, string url, int httpPort)
        {
            if (id == "claude" || id == "chatgpt")
            {
                var trace = (id == "claude" ? "https://claude.ai" : "https://chatgpt.com") + "/cdn-cgi/trace";
                var body = Fetch(trace, httpPort, out var code, out var err);
                var loc = body == null ? null : Regex.Match(body, @"^loc=([A-Z]{2})\s*$", RegexOptions.Multiline).Groups[1].Value;
                if (!string.IsNullOrEmpty(loc))
                {
                    var ok = id == "claude" ? Anthropic.Contains(loc) : !OpenAiBlocked.Contains(loc);
                    return Tuple.Create(ok, ok ? "сайт открывается, страна выхода " + loc : name + " не работает в стране выхода " + loc);
                }
                if (err != null) return Tuple.Create(false, err);
            }
            var page = Fetch(url, httpPort, out var status, out var error);
            if (page == null) return Tuple.Create(false, error ?? "нет ответа");
            var low = page.ToLowerInvariant();
            if (Region.Any(low.Contains)) return Tuple.Create(false, "ограничение по региону");
            if (Bot.Any(low.Contains)) return Tuple.Create(false, "проверка «не робот ли вы»");
            return status >= 200 && status < 400 ? Tuple.Create(true, "страница открывается") : Tuple.Create(false, "ответ " + status);
        }

        static string Fetch(string url, int httpPort, out int status, out string error)
        {
            status = 0;
            error = null;
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(url);
                req.Proxy = new WebProxy("127.0.0.1", httpPort);
                req.UserAgent = "Mozilla/5.0 (Windows NT 6.1; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0 Safari/537.36";
                req.Accept = "text/html,application/xhtml+xml,*/*;q=0.8";
                req.Headers["Accept-Language"] = "en-US,en;q=0.8";
                req.Timeout = 12000;
                req.ReadWriteTimeout = 12000;
                req.AllowAutoRedirect = true;
                HttpWebResponse resp;
                try { resp = (HttpWebResponse)req.GetResponse(); }
                catch (WebException we) when (we.Response is HttpWebResponse r) { resp = r; }
                using (resp)
                {
                    status = (int)resp.StatusCode;
                    var final = resp.ResponseUri?.ToString() ?? url;
                    using (var st = resp.GetResponseStream())
                    using (var ms = new MemoryStream())
                    {
                        var buf = new byte[16384];
                        int n;
                        while (ms.Length < 300 * 1024 && (n = st.Read(buf, 0, buf.Length)) > 0) ms.Write(buf, 0, n);
                        return final + "\n" + Encoding.UTF8.GetString(ms.ToArray());
                    }
                }
            }
            catch (WebException e)
            {
                error = e.Status == WebExceptionStatus.Timeout ? "истекло время ожидания"
                    : e.Status == WebExceptionStatus.TrustFailure || e.Status == WebExceptionStatus.SecureChannelFailure ? "ошибка TLS"
                    : "ошибка соединения";
                return null;
            }
            catch (Exception e)
            {
                error = e.Message;
                return null;
            }
        }
    }

    /// <summary>Резервная копия — в формате «Лоцмана» для телефона: копию с телефона можно
    /// восстановить здесь и наоборот (свои подписки и ключи).</summary>
    static class Backup
    {
        public static string Make(Settings s)
        {
            var mine = s.Mine.Select(m =>
            {
                var d = new Dictionary<string, object> {
                    { "id", m.Id }, { "title", m.Title }, { "author", "Вы" }, { "homepage", "" }, { "license", "своё" },
                    { "description", m.Keys != null ? "Свои ключи" : "Подписка по ссылке" }, { "mode", "any" },
                    { "mirrors", m.Mirrors }, { "origin", "mine" },
                };
                if (m.Keys != null) d["links"] = m.Keys;
                return (object)d;
            }).ToArray();
            var j = new Dictionary<string, object> {
                { "app", "locman" }, { "format", 1 }, { "created", DateTime.Now.ToString("s") }, { "version", "Lite " + AppInfo.Version },
                { "settings", new Dictionary<string, object> {
                    { "mine", mine }, { "directRu", s.DirectRu }, { "lite", new Dictionary<string, object> {
                        { "mode", s.Mode }, { "tun", s.Tun }, { "enabled", s.Enabled.ToArray() }, { "disabled", s.Disabled.ToArray() },
                        { "theme", s.Theme },
                    } },
                } },
                { "security", new Dictionary<string, object>() },
            };
            return Json.Write(j);
        }

        /// <summary>Добавить свои источники из копии (с телефона или отсюда). Возвращает, сколько добавлено.</summary>
        public static int Restore(Settings s, string text)
        {
            if (!(Json.Parse(text) is Dictionary<string, object> j) || Json.Str(j, "app") != "locman" ||
                !(j["settings"] is Dictionary<string, object> st))
                throw new InvalidDataException("Это не резервная копия «Лоцмана»");
            var added = 0;
            if (st.TryGetValue("mine", out var mine) && mine is object[] arr)
            {
                foreach (var m in arr.OfType<Dictionary<string, object>>())
                {
                    var id = Json.Str(m, "id");
                    if (id.Length == 0 || s.Mine.Any(x => x.Id == id)) continue;
                    var src = new Source { Id = id, Title = Json.Str(m, "title"), Mine = true };
                    if (m.TryGetValue("mirrors", out var mm) && mm is object[] ma) src.Mirrors = ma.Select(x => x.ToString()).ToArray();
                    var links = Json.Str(m, "links");
                    if (links.Length > 0) src.Keys = links;
                    if (src.Keys == null && src.Mirrors.Length == 0) continue;
                    s.Mine.Add(src);
                    added++;
                }
            }
            if (st.TryGetValue("directRu", out var dr) && dr is bool b) s.DirectRu = b;
            if (st.TryGetValue("lite", out var lite) && lite is Dictionary<string, object> l)
            {
                var mode = Json.Str(l, "mode");
                if (mode.Length > 0) s.Mode = mode;
                if (l.TryGetValue("enabled", out var en) && en is object[] ea) foreach (var x in ea) s.Enabled.Add(x.ToString());
                if (l.TryGetValue("disabled", out var di) && di is object[] da) foreach (var x in da) s.Disabled.Add(x.ToString());
            }
            s.Save();
            return added;
        }
    }

    /// <summary>Обновление внутри программы: update.json из ветки updates, установщик для win7-x64,
    /// проверка SHA-256, запуск установщика.</summary>
    static class Updater
    {
        public sealed class Info { public string Version, Url, Sha256, Notes; }

        public static Info Check(int? viaPort)
        {
            var text = Net.Get(new[] {
                $"https://raw.githubusercontent.com/{Net.Repo}/updates/update.json",
                $"https://cdn.jsdelivr.net/gh/{Net.Repo}@updates/update.json",
            }, viaPort);
            if (!(Json.Parse(text) is Dictionary<string, object> j)) return null;
            var version = Json.Str(j, "versionName");
            if (!(j.TryGetValue("assets", out var a) && a is Dictionary<string, object> assets &&
                  assets.TryGetValue("win7-x64", out var w) && w is Dictionary<string, object> win)) return null;
            if (!Newer(version, AppInfo.Version)) return null;
            var notes = j.TryGetValue("notes", out var n) && n is object[] na ? string.Join("\n", na.Select(x => "• " + x)) : Json.Str(j, "notes");
            return new Info { Version = version, Url = Json.Str(win, "url"), Sha256 = Json.Str(win, "sha256").ToLowerInvariant(), Notes = notes };
        }

        static bool Newer(string a, string b)
        {
            Version va, vb;
            return Version.TryParse(a, out va) && Version.TryParse(b, out vb) && va > vb;
        }

        public static string Download(Info u, int? viaPort, Action<int> progress)
        {
            var path = Path.Combine(Path.GetTempPath(), "Locman-Lite-" + u.Version + "-setup.exe");
            Exception last = null;
            foreach (var proxy in viaPort.HasValue ? new int?[] { viaPort, null } : new int?[] { null })
            {
                try
                {
                    var req = (HttpWebRequest)WebRequest.Create(u.Url);
                    req.UserAgent = Net.UserAgent;
                    req.Timeout = 30000;
                    req.ReadWriteTimeout = 30000;
                    req.Proxy = proxy.HasValue ? new WebProxy("127.0.0.1", proxy.Value) : null;
                    using (var resp = req.GetResponse())
                    using (var st = resp.GetResponseStream())
                    using (var f = File.Create(path))
                    using (var sha = SHA256.Create())
                    {
                        var total = resp.ContentLength;
                        var buf = new byte[65536];
                        long read = 0;
                        int n;
                        while ((n = st.Read(buf, 0, buf.Length)) > 0)
                        {
                            f.Write(buf, 0, n);
                            sha.TransformBlock(buf, 0, n, null, 0);
                            read += n;
                            if (total > 0) progress?.Invoke((int)(read * 100 / total));
                        }
                        sha.TransformFinalBlock(new byte[0], 0, 0);
                        var hash = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
                        if (u.Sha256.Length > 0 && hash != u.Sha256) throw new InvalidDataException("контрольная сумма не совпала");
                    }
                    return path;
                }
                catch (Exception e)
                {
                    last = e;
                    try { File.Delete(path); } catch { }
                }
            }
            throw last;
        }
    }

    static class Elevation
    {
        public static bool IsAdmin
        {
            get
            {
                using (var id = WindowsIdentity.GetCurrent())
                    return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
            }
        }

        /// <summary>Перезапуск с правами администратора (нужны для режима «весь трафик»).</summary>
        public static bool Relaunch(string args)
        {
            try
            {
                Process.Start(new ProcessStartInfo(AppInfo.ExecutablePath, args) { UseShellExecute = true, Verb = "runas" });
                return true;
            }
            catch { return false; }
        }
    }
}
