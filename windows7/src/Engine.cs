using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Locman7
{
    enum Phase { Off, Seek, On }

    /// <summary>Логика «Лоцмана Lite»: подписки, проверка узлов, подключение, сторож.
    /// Все события приходят из фоновых потоков — окно переносит их в свой поток само.</summary>
    sealed class Engine
    {
        public readonly Settings S = Settings.Load();
        public List<Source> Catalog = new List<Source>();
        public readonly ConcurrentDictionary<string, List<Node>> NodesBySource = new ConcurrentDictionary<string, List<Node>>();

        /// <summary>Задержка по настоящему запросу через узел, мс (-1 — не прошёл).</summary>
        public readonly ConcurrentDictionary<string, int> Latency = new ConcurrentDictionary<string, int>();

        public Phase Phase { get; private set; } = Phase.Off;
        public Node Active { get; private set; }
        public string Status { get; private set; } = "Выключено";

        public event Action Changed;
        public event Action<string> Logged;

        /// <summary>Обновилась скорость (раз в 2 секунды) — без перерисовки списков.</summary>
        public event Action Rates;

        /// <summary>Режиму «весь трафик» нужны права администратора — окно спросит и перезапустит.</summary>
        public event Action NeedAdmin;

        /// <summary>Результаты проверки сервисов через текущий узел: id → (успех, пояснение).</summary>
        public readonly ConcurrentDictionary<string, Tuple<bool, string>> ServiceResults = new ConcurrentDictionary<string, Tuple<bool, string>>();
        public bool CheckingServices { get; private set; }

        XrayProcess _xray;
        CancellationTokenSource _seek;
        Timer _watch;
        int _fails;
        readonly object _lock = new object();
        readonly HashSet<string> _bad = new HashSet<string>(); // не пропустили данные в этот сеанс

        void Log(string text) => Logged?.Invoke(DateTime.Now.ToString("HH:mm:ss") + "  " + text);

        void Set(Phase phase, string status)
        {
            Phase = phase;
            Status = status;
            Changed?.Invoke();
        }

        void Note(string status)
        {
            Status = status;
            Changed?.Invoke();
        }

        // ---------------- Источники ----------------

        public IEnumerable<Source> AllSources => Catalog.Concat(S.Mine);

        public bool IsEnabled(Source s)
        {
            if (s.Mine) return !S.Disabled.Contains(s.Id);
            if (S.Disabled.Contains(s.Id)) return false;
            if (S.Enabled.Contains(s.Id)) return true;
            return s.Recommended && Fits(s);
        }

        public bool Fits(Source s) => S.Mode == "any" || s.Mode == "any" || s.Mode == S.Mode;

        public void SetEnabled(Source s, bool on)
        {
            if (on) { S.Disabled.Remove(s.Id); if (!s.Mine) S.Enabled.Add(s.Id); }
            else { S.Enabled.Remove(s.Id); S.Disabled.Add(s.Id); }
            S.Save();
        }

        static string CachePath(Source s) => Path.Combine(Settings.Dir, "cache", s.Id + ".txt");

        public void LoadCatalog()
        {
            Catalog = Locman7.Catalog.Load(Phase == Phase.On ? S.HttpPort : (int?)null, Log);
            foreach (var src in AllSources)
            {
                try
                {
                    var path = CachePath(src);
                    if (src.Keys != null) NodesBySource[src.Id] = Subscription.Parse(src.Keys, src.Id);
                    else if (File.Exists(path)) NodesBySource[src.Id] = Subscription.Parse(File.ReadAllText(path, Encoding.UTF8), src.Id);
                }
                catch { }
            }
            Changed?.Invoke();
        }

        /// <summary>Обновить включённые источники (по 6 одновременно).</summary>
        public void RefreshSources(bool all = false)
        {
            Directory.CreateDirectory(Path.Combine(Settings.Dir, "cache"));
            var list = AllSources.Where(s => s.Keys == null && (all || IsEnabled(s))).ToList();
            var ok = 0;
            Parallel.ForEach(list, new ParallelOptions { MaxDegreeOfParallelism = 6 }, src =>
            {
                try
                {
                    var body = Net.Get(src.Mirrors, Phase == Phase.On ? S.HttpPort : (int?)null);
                    var nodes = Subscription.Parse(body, src.Id);
                    if (nodes.Count == 0) throw new Exception("нет узлов");
                    NodesBySource[src.Id] = nodes;
                    File.WriteAllText(CachePath(src), body, Encoding.UTF8);
                    Interlocked.Increment(ref ok);
                }
                catch (Exception e) { Log($"{src.Title}: не обновился ({e.Message})"); }
            });
            foreach (var src in AllSources.Where(s => s.Keys != null)) NodesBySource[src.Id] = Subscription.Parse(src.Keys, src.Id);
            Log($"Источники обновлены: {ok} из {list.Count}");
            Changed?.Invoke();
        }

        /// <summary>Узлы из включённых источников: безопасные, без повторов.</summary>
        public List<Node> Candidates()
        {
            var seen = new HashSet<string>();
            var list = new List<Node>();
            foreach (var src in AllSources.Where(IsEnabled))
            {
                if (!NodesBySource.TryGetValue(src.Id, out var nodes)) continue;
                foreach (var n in nodes)
                    if (n.SecurityIssue == null && seen.Add(n.EndpointKey)) list.Add(n);
            }
            return list;
        }

        /// <summary>Добавить свои: ссылки https:// становятся подписками, ключи — одним набором.</summary>
        public string AddMine(string text)
        {
            var lines = text.Split(new[] { '\r', '\n', ' ' }, StringSplitOptions.RemoveEmptyEntries).Select(l => l.Trim()).ToList();
            var urls = lines.Where(l => l.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || l.StartsWith("https://", StringComparison.OrdinalIgnoreCase)).ToList();
            var keys = lines.Where(l => l.Contains("://") && !urls.Contains(l)).ToList();
            var added = 0;
            foreach (var u in urls)
            {
                var id = "mine-" + Util.StableId(u);
                if (S.Mine.Any(m => m.Id == id)) continue;
                Uri uri;
                S.Mine.Add(new Source { Id = id, Title = Uri.TryCreate(u, UriKind.Absolute, out uri) ? uri.Host : "Подписка", Mirrors = new[] { u }, Mine = true });
                added++;
            }
            if (keys.Count > 0)
            {
                var nodes = Subscription.Parse(string.Join("\n", keys), "probe");
                if (nodes.Count > 0)
                {
                    var id = "mine-" + Util.StableId(string.Join("\n", keys));
                    S.Mine.Add(new Source { Id = id, Title = "Мои ключи (" + nodes.Count + ")", Keys = string.Join("\n", keys), Mine = true });
                    NodesBySource[id] = Subscription.Parse(string.Join("\n", keys), id);
                    added++;
                }
            }
            S.Save();
            Changed?.Invoke();
            return added == 0 ? "Не нашёл ни ссылок подписок, ни подходящих ключей" : "Добавлено: " + added;
        }

        public void RemoveMine(Source s)
        {
            S.Mine.RemoveAll(m => m.Id == s.Id);
            NodesBySource.TryRemove(s.Id, out _);
            S.Save();
            Changed?.Invoke();
        }

        // ---------------- Проверка узлов ----------------

        /// <summary>Проверка настоящим запросом: один процесс Xray на пачку узлов, у каждого свой вход.
        /// Если конфиг пачки не поднялся (кривой узел), делим пачку пополам.</summary>
        public void TestBatch(IList<Node> nodes, CancellationToken ct, int timeoutMs = 8000)
        {
            if (nodes.Count == 0 || ct.IsCancellationRequested) return;
            var ports = nodes.Select(_ => Net.FreePort()).ToList();
            XrayProcess xray = null;
            try
            {
                xray = new XrayProcess(XrayConfig.Batch(nodes, ports));
                if (!xray.WaitReady(ports[0], 6000))
                {
                    xray.Dispose();
                    xray = null;
                    if (nodes.Count == 1) { Latency[nodes[0].Id] = -1; return; }
                    var half = nodes.Count / 2;
                    TestBatch(nodes.Take(half).ToList(), ct, timeoutMs);
                    TestBatch(nodes.Skip(half).ToList(), ct, timeoutMs);
                    return;
                }
                Parallel.For(0, nodes.Count, new ParallelOptions { MaxDegreeOfParallelism = 16, CancellationToken = ct }, i =>
                {
                    Latency[nodes[i].Id] = Net.ProbeVia(ports[i], "https://www.gstatic.com/generate_204", timeoutMs);
                });
            }
            catch (OperationCanceledException) { }
            finally { xray?.Dispose(); }
        }

        /// <summary>Пачки для проверки: в одной пачке — не больше одного узла с тем же SNI и подсетью
        /// и не больше двух из одной подсети. Порядок (по задержке) сохраняется, насколько возможно.</summary>
        public static List<List<Node>> GentleBatches(IList<Node> nodes, int size)
        {
            var batches = new List<List<Node>>();
            var keys = new List<HashSet<string>>();
            var nets = new List<Dictionary<string, int>>();
            foreach (var n in nodes)
            {
                var placed = false;
                for (var i = 0; i < batches.Count && !placed; i++)
                {
                    nets[i].TryGetValue(n.Subnet, out var c);
                    if (batches[i].Count >= size || keys[i].Contains(n.GentleKey) || c >= 2) continue;
                    batches[i].Add(n);
                    keys[i].Add(n.GentleKey);
                    nets[i][n.Subnet] = c + 1;
                    placed = true;
                }
                if (placed) continue;
                batches.Add(new List<Node> { n });
                keys.Add(new HashSet<string> { n.GentleKey });
                nets.Add(new Dictionary<string, int> { { n.Subnet, 1 } });
            }
            return batches;
        }

        /// <summary>Сначала TCP до всех (быстро), потом настоящий запрос через 40 лучших.</summary>
        public List<Node> Rank(List<Node> pool, CancellationToken ct, Action<string> progress, int realCount = 40)
        {
            progress?.Invoke($"Проверяю связь с {pool.Count} узлами…");
            var tcp = new ConcurrentDictionary<Node, int>();
            var gate = new SemaphoreSlim(64);
            var tasks = pool.Select(async n =>
            {
                await gate.WaitAsync(ct).ConfigureAwait(false);
                try { tcp[n] = await Net.TcpPing(n.Address, n.Port, 2500).ConfigureAwait(false); }
                finally { gate.Release(); }
            }).ToArray();
            try { Task.WaitAll(tasks, ct); } catch (OperationCanceledException) { return new List<Node>(); } catch (AggregateException) { }
            // Hysteria2 идёт по UDP — TCP-проверка ей не показатель.
            var reachable = pool.Where(n => n.Protocol == Proto.Hysteria2 || (tcp.TryGetValue(n, out var d) && d > 0))
                .OrderBy(n => n.Protocol == Proto.Hysteria2 ? 900 : tcp[n]).Take(realCount).ToList();
            progress?.Invoke($"Отвечают {reachable.Count}, проверяю их настоящим запросом…");
            foreach (var batch in GentleBatches(reachable, 20))
            {
                if (ct.IsCancellationRequested) break;
                TestBatch(batch, ct);
                Thread.Sleep(500); // пауза, чтобы рукопожатия к одним и тем же серверам не шли пачкой
            }
            return reachable.Where(n => Latency.TryGetValue(n.Id, out var l) && l > 0)
                .OrderBy(n => Latency[n.Id]).ToList();
        }

        public void CheckAll(Action<string> progress)
        {
            var cts = new CancellationTokenSource();
            var pool = Candidates();
            var ranked = Rank(pool.OrderBy(_ => Guid.NewGuid()).Take(600).ToList(), cts.Token, progress, 80);
            progress?.Invoke($"Проверено: работают {ranked.Count}");
            Log($"Проверка узлов: работают {ranked.Count} из {Math.Min(pool.Count, 600)}");
            Changed?.Invoke();
        }

        // ---------------- Подключение ----------------

        public void Toggle()
        {
            if (Phase == Phase.Off) ConnectAuto(null);
            else Disconnect();
        }

        bool AdminOk()
        {
            if (!S.Tun || Elevation.IsAdmin) return true;
            NeedAdmin?.Invoke();
            return false;
        }

        /// <summary>Проверить Gemini, ChatGPT, Claude, YouTube через текущее подключение.</summary>
        public void CheckServices()
        {
            if (Phase != Phase.On || CheckingServices) return;
            CheckingServices = true;
            ServiceResults.Clear();
            Changed?.Invoke();
            Task.Run(() =>
            {
                try
                {
                    foreach (var s in Services.List)
                    {
                        if (Phase != Phase.On) break;
                        ServiceResults[s[0]] = Services.Check(s[0], s[1], s[2], S.HttpPort);
                        Changed?.Invoke();
                    }
                    Log("Сервисы: " + string.Join(", ", Services.List.Where(s => ServiceResults.TryGetValue(s[0], out var r) && r.Item1).Select(s => s[1])
                        .DefaultIfEmpty("ни один не открылся")));
                }
                finally
                {
                    CheckingServices = false;
                    Changed?.Invoke();
                }
            });
        }

        /// <summary>Найти рабочий узел и подключиться. avoid — узел, который пропускаем.</summary>
        public void ConnectAuto(string avoid)
        {
            if (!AdminOk()) return;
            CancelSeek();
            var cts = new CancellationTokenSource();
            _seek = cts;
            Set(Phase.Seek, "Ищу рабочий узел…");
            Task.Run(() =>
            {
                try
                {
                    if (Candidates().Count == 0)
                    {
                        Note("Обновляю источники…");
                        RefreshSources();
                    }
                    var pool = Candidates().Where(n => n.Id != avoid && !_bad.Contains(n.Id)).ToList();
                    if (pool.Count == 0) { Fail("Нет узлов: включите источники или добавьте свои"); return; }
                    // Последний рабочий — первым.
                    var last = pool.FirstOrDefault(n => n.Id == S.LastNode);
                    var rest = pool.Where(n => n != last).OrderBy(_ => Guid.NewGuid()).Take(500).ToList();
                    var ranked = new List<Node>();
                    if (last != null)
                    {
                        TestBatch(new[] { last }, cts.Token);
                        if (Latency.TryGetValue(last.Id, out var l) && l > 0) ranked.Add(last);
                    }
                    if (ranked.Count == 0) ranked = Rank(rest, cts.Token, Note);
                    foreach (var n in ranked.Take(6))
                    {
                        if (cts.IsCancellationRequested) return;
                        Note("Подключаюсь: " + n.Name);
                        if (Start(n, cts.Token)) return;
                    }
                    if (!cts.IsCancellationRequested) Fail("Рабочий узел не найден — попробуйте позже или включите другие источники");
                }
                catch (Exception e) { if (!cts.IsCancellationRequested) Fail("Ошибка: " + e.Message); }
            });
        }

        /// <summary>Подключиться к выбранному узлу.</summary>
        public void ConnectTo(Node n)
        {
            if (!AdminOk()) return;
            CancelSeek();
            var cts = new CancellationTokenSource();
            _seek = cts;
            Set(Phase.Seek, "Подключаюсь: " + n.Name);
            Task.Run(() => { if (!Start(n, cts.Token) && !cts.IsCancellationRequested) Fail(n.Name + ": данные через узел не идут"); });
        }

        /// <summary>«Переключить»: на следующий из уже проверенных, иначе — новый поиск без текущего.</summary>
        public void Switch()
        {
            var current = Active?.Id;
            var next = Candidates().Where(n => n.Id != current && !_bad.Contains(n.Id) && Latency.TryGetValue(n.Id, out var l) && l > 0)
                .OrderBy(n => Latency[n.Id]).Take(8).ToList();
            CancelSeek();
            var cts = new CancellationTokenSource();
            _seek = cts;
            Set(Phase.Seek, "Переключаю узел…");
            Task.Run(() =>
            {
                Log("Переключаем узел по кнопке");
                TestBatch(next, cts.Token);
                foreach (var n in next.Where(x => Latency.TryGetValue(x.Id, out var l) && l > 0).OrderBy(x => Latency[x.Id]))
                {
                    if (cts.IsCancellationRequested) return;
                    if (Start(n, cts.Token)) return;
                }
                if (!cts.IsCancellationRequested) { _seek = null; ConnectAuto(current); }
            });
        }

        bool Start(Node n, CancellationToken ct)
        {
            lock (_lock)
            {
                StopCore();
                XrayProcess xray;
                _metricsPort = Net.FreePort();
                try { xray = new XrayProcess(XrayConfig.Connect(n, S.SocksPort, S.HttpPort, S.DirectRu, S.Tun && Elevation.IsAdmin, _metricsPort), line => { if (line.Contains("[Error]") || line.Contains("failed")) Log("Xray: " + line); }); }
                catch (Exception e) { Log("Xray не запустился: " + e.Message); return false; }
                if (!xray.WaitReady(S.HttpPort, 6000))
                {
                    Log($"{n.Name}: ядро не поднялось. {xray.Errors.Trim()}");
                    xray.Dispose();
                    return false;
                }
                if (ct.IsCancellationRequested) { xray.Dispose(); return false; }
                // Подключение засчитываем, только если реально пошли данные (64 КБ) — короткий ответ
                // проходит и тогда, когда фильтр «замораживает» соединение.
                var ok = Net.ProbeVia(S.HttpPort, "https://www.gstatic.com/generate_204", 8000) > 0
                    && (Net.ProbeVia(S.HttpPort, "https://speed.cloudflare.com/__down?bytes=65536", 12000, 48 * 1024) > 0
                        || Net.ProbeVia(S.HttpPort, "https://proof.ovh.net/files/1Mb.dat", 12000, 48 * 1024) > 0);
                if (!ok || ct.IsCancellationRequested)
                {
                    if (!ok) { _bad.Add(n.Id); Log($"{n.Name}: отвечает, но данные не идут"); }
                    xray.Dispose();
                    return false;
                }
                _xray = xray;
                Active = n;
                S.LastNode = n.Id;
                try { S.Save(); } catch { }
                if (!S.Tun)
                {
                    try { SysProxy.Set(S.HttpPort); } catch (Exception e) { Log("Системный прокси не включился: " + e.Message); }
                }
                _fails = 0;
                _watch?.Dispose();
                _watch = new Timer(_ => Watch(), null, 20000, 20000);
                ResetFlow();
                _flow?.Dispose();
                _flow = new Timer(_ => Flow(), null, 2000, 2000);
                Log($"Подключено: {n.Name} ({n.Label}){(S.Tun ? ", весь трафик через TUN" : ", системный прокси")}");
                ServiceResults.Clear();
                Set(Phase.On, "Подключено");
                if (S.AutoServices) Task.Delay(1500).ContinueWith(_ => CheckServices());
                return true;
            }
        }

        /// <summary>Сторож: раз в 20 секунд запрос через узел; две неудачи подряд — переключаемся.</summary>
        void Watch()
        {
            if (Phase != Phase.On || _xray == null) return;
            if (_xray.Exited) { Log("Ядро остановилось — ищу другой узел"); Reconnect(); return; }
            var ok = Net.ProbeVia(S.HttpPort, "https://www.gstatic.com/generate_204", 8000) > 0
                || Net.ProbeVia(S.HttpPort, "https://cp.cloudflare.com/generate_204", 8000) > 0;
            if (ok) { _fails = 0; return; }
            if (++_fails < 2) return;
            Log("Узел перестал отвечать — переключаюсь");
            Reconnect();
        }

        // ---- Скорость и заморозка: запросы уходят, а в ответ ничего ----
        int _metricsPort;
        Timer _flow;
        readonly long[] _flowUp = new long[12], _flowDown = new long[12];
        int _flowAt;
        long _lastUp = -1, _lastDown = -1;
        DateTime _flowSince, _lastFreezeCheck;
        int _freezing;

        /// <summary>Скорость за последние 2 секунды, байт/с.</summary>
        public long RateUp { get; private set; }
        public long RateDown { get; private set; }

        void ResetFlow()
        {
            Array.Clear(_flowUp, 0, _flowUp.Length);
            Array.Clear(_flowDown, 0, _flowDown.Length);
            _lastUp = _lastDown = -1;
            _flowSince = DateTime.Now;
            RateUp = RateDown = 0;
        }

        void Flow()
        {
            if (Phase != Phase.On || _metricsPort == 0) return;
            long up, down;
            if (!Net.ProxyTraffic(_metricsPort, out up, out down)) return;
            var du = _lastUp < 0 ? 0 : Math.Max(0, up - _lastUp);
            var dd = _lastDown < 0 ? 0 : Math.Max(0, down - _lastDown);
            _lastUp = up;
            _lastDown = down;
            _flowUp[_flowAt] = du;
            _flowDown[_flowAt] = dd;
            _flowAt = (_flowAt + 1) % _flowUp.Length;
            RateUp = du / 2;
            RateDown = dd / 2;
            Rates?.Invoke();
            if ((DateTime.Now - _flowSince).TotalSeconds < 20 || (DateTime.Now - _lastFreezeCheck).TotalSeconds < 60) return;
            if (_flowUp.Sum() < 1500 || _flowDown.Sum() > 1024) return;
            if (Interlocked.Exchange(ref _freezing, 1) == 1) return;
            _lastFreezeCheck = DateTime.Now;
            Task.Run(() =>
            {
                try
                {
                    // Похоже на заморозку — проверяем настоящей загрузкой (64 КБ), дважды.
                    for (var i = 0; i < 2; i++)
                        if (Net.ProbeVia(S.HttpPort, "https://speed.cloudflare.com/__down?bytes=65536", 12000, 48 * 1024) > 0
                            || Net.ProbeVia(S.HttpPort, "https://proof.ovh.net/files/1Mb.dat", 12000, 48 * 1024) > 0) return;
                    if (Phase != Phase.On) return;
                    Log("Запросы уходят, а данные не приходят (похоже на заморозку) — переключаюсь");
                    Reconnect();
                }
                finally { Interlocked.Exchange(ref _freezing, 0); }
            });
        }

        void Reconnect()
        {
            var old = Active?.Id;
            if (old != null) { _bad.Add(old); Latency[old] = -1; }
            Switch();
        }

        void Fail(string text)
        {
            Log(text);
            lock (_lock) StopCore();
            try { SysProxy.Clear(S.HttpPort); } catch { }
            Set(Phase.Off, text);
        }

        void CancelSeek()
        {
            _seek?.Cancel();
            _seek = null;
        }

        void StopCore()
        {
            _watch?.Dispose();
            _watch = null;
            _flow?.Dispose();
            _flow = null;
            RateUp = RateDown = 0;
            _xray?.Dispose();
            _xray = null;
            Active = null;
        }

        public void Disconnect()
        {
            CancelSeek();
            lock (_lock) StopCore();
            try { SysProxy.Clear(S.HttpPort); } catch { }
            Log("Отключено");
            Set(Phase.Off, "Выключено");
        }

        /// <summary>При запуске: если от прошлого раза остался наш системный прокси (программа упала) — убираем.</summary>
        public void CleanupStale()
        {
            try { SysProxy.Clear(S.HttpPort); } catch { }
            try
            {
                foreach (var f in Directory.GetFiles(Settings.Dir, "run-*.json")) File.Delete(f);
            }
            catch { }
        }
    }
}
