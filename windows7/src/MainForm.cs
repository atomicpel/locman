using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Linq;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Locman7
{
    static class Theme
    {
        public static Color Bg = Color.FromArgb(11, 14, 20);
        public static Color Surface = Color.FromArgb(21, 26, 36);
        public static Color Border = Color.FromArgb(42, 53, 72);
        public static Color Fg = Color.FromArgb(231, 237, 245);
        public static Color Muted = Color.FromArgb(139, 151, 168);
        public static Color Accent = Color.FromArgb(62, 198, 255);
        public static Color Accent2 = Color.FromArgb(124, 92, 255);
        public static Color Danger = Color.FromArgb(232, 93, 76);
        public static Color OnAccent = Color.FromArgb(4, 16, 24);

        /// <summary>Светлая тема (применяется при запуске).</summary>
        public static void Light()
        {
            Bg = Color.FromArgb(231, 238, 245);
            Surface = Color.White;
            Border = Color.FromArgb(211, 222, 232);
            Fg = Color.FromArgb(18, 24, 32);
            Muted = Color.FromArgb(82, 98, 116);
            Accent = Color.FromArgb(0, 126, 171);
            Accent2 = Color.FromArgb(106, 75, 214);
            Danger = Color.FromArgb(180, 51, 42);
            OnAccent = Color.White;
        }
        public static Font F(float size, FontStyle style = FontStyle.Regular) => new Font("Segoe UI", size, style);
    }

    /// <summary>Круглая кнопка подключения с градиентом.</summary>
    sealed class PowerButton : Control
    {
        public bool On, Busy;
        float _spin;
        readonly Timer _t = new Timer { Interval = 40 };

        public PowerButton()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint |
                     ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Theme.Bg;
            Cursor = Cursors.Hand;
            Size = new Size(170, 170);
            _t.Tick += (s, e) => { _spin = (_spin + 9) % 360; Invalidate(); };
            AccessibleRole = AccessibleRole.PushButton;
        }

        public void Sync(bool on, bool busy)
        {
            On = on;
            Busy = busy;
            AccessibleName = busy ? "Идёт поиск, нажмите, чтобы остановить" : on ? "Отключить VPN" : "Подключить VPN";
            _t.Enabled = busy;
            Invalidate();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(8, 8, Width - 17, Height - 17);
            using (var halo = new SolidBrush(Color.FromArgb(On ? 40 : 18, Theme.Accent)))
                g.FillEllipse(halo, 0, 0, Width - 1, Height - 1);
            using (var br = On || Busy
                       ? (Brush)new LinearGradientBrush(r, Theme.Accent, Theme.Accent2, 45f)
                       : new SolidBrush(Theme.Surface))
                g.FillEllipse(br, r);
            using (var pen = new Pen(On ? Color.FromArgb(120, Color.White) : Theme.Border, 2))
                g.DrawEllipse(pen, r);
            if (Busy)
                using (var pen = new Pen(Color.White, 4) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                    g.DrawArc(pen, Rectangle.Inflate(r, -10, -10), _spin, 90);
            // значок питания
            var c = new Point(Width / 2, Height / 2);
            var col = On || Busy ? Color.White : Theme.Accent;
            using (var pen = new Pen(col, 6) { StartCap = LineCap.Round, EndCap = LineCap.Round })
            {
                g.DrawArc(pen, c.X - 30, c.Y - 30, 60, 60, -60, 300);
                g.DrawLine(pen, c.X, c.Y - 38, c.X, c.Y - 6);
            }
        }
    }

    sealed class MainForm : Form
    {
        readonly Engine _e = new Engine();
        readonly NotifyIcon _tray = new NotifyIcon();
        readonly PowerButton _power = new PowerButton();
        readonly Label _status = new Label(), _node = new Label();
        readonly Button _switch, _again;
        readonly Panel _pages = new Panel();
        readonly Panel _home = new Panel(), _nodesPage = new Panel(), _sourcesPage = new Panel(), _settingsPage = new Panel(), _logPage = new Panel();
        readonly ListView _nodes = new ListView(), _sources = new ListView();
        readonly TextBox _log = new TextBox(), _add = new TextBox();
        readonly Label _nodesInfo = new Label(), _hint = new Label();
        readonly Label[] _svc = new Label[Services.List.Length];
        Button _svcBtn;
        readonly Button _update = Flat("Обновить", true);
        Updater.Info _pending;
        bool _exiting, _filling;
        readonly bool _startHidden;

        readonly bool _connectOnStart;

        public MainForm(bool startHidden, bool connect)
        {
            _startHidden = startHidden;
            _connectOnStart = connect;
            Text = "Лоцман Lite";
            Icon = LoadIcon();
            BackColor = Theme.Bg;
            ForeColor = Theme.Fg;
            Font = Theme.F(10);
            ClientSize = new Size(480, 720);
            MinimumSize = new Size(440, 600);
            StartPosition = FormStartPosition.CenterScreen;

            // Шапка и навигация
            var title = new Label { Text = "Лоцман", Font = Theme.F(20, FontStyle.Bold), AutoSize = true, Location = new Point(20, 14) };
            var sub = new Label { Text = "Lite для Windows 7", ForeColor = Theme.Muted, AutoSize = true, Location = new Point(22, 52) };
            Controls.Add(title);
            Controls.Add(sub);
            var nav = new FlowLayoutPanel { Location = new Point(12, 80), Size = new Size(460, 36), Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right };
            var navNames = new[] { "Главная", "Узлы", "Источники", "Настройки", "Журнал" };
            var navPages = new[] { _home, _nodesPage, _sourcesPage, _settingsPage, _logPage };
            for (var i = 0; i < navNames.Length; i++)
            {
                var page = navPages[i];
                var b = Flat(navNames[i], false);
                b.AutoSize = true;
                b.Margin = new Padding(2);
                b.Click += (s, e) => Show(page);
                nav.Controls.Add(b);
            }
            Controls.Add(nav);
            _pages.Location = new Point(0, 120);
            _pages.Size = new Size(480, 600);
            _pages.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
            Controls.Add(_pages);
            foreach (var p in new[] { _home, _nodesPage, _sourcesPage, _settingsPage, _logPage })
            {
                p.Dock = DockStyle.Fill;
                p.Padding = new Padding(16, 8, 16, 16);
                p.Visible = false;
                _pages.Controls.Add(p);
            }

            // Главная
            _power.Location = new Point(155, 10);
            _power.Click += (s, e) => _e.Toggle();
            _home.Controls.Add(_power);
            _status.SetBounds(16, 190, 448, 30);
            _status.TextAlign = ContentAlignment.MiddleCenter;
            _status.Font = Theme.F(13, FontStyle.Bold);
            _node.SetBounds(16, 222, 448, 44);
            _node.TextAlign = ContentAlignment.TopCenter;
            _node.ForeColor = Theme.Muted;
            _home.Controls.Add(_status);
            _home.Controls.Add(_node);
            _switch = Flat("⇄  Переключить", true);
            _switch.SetBounds(16, 276, 218, 44);
            _switch.Click += (s, e) => _e.Switch();
            _again = Flat("Найти заново", false);
            _again.SetBounds(246, 276, 218, 44);
            _again.Click += (s, e) => _e.ConnectAuto(_e.Active?.Id);
            _home.Controls.Add(_switch);
            _home.Controls.Add(_again);
            _hint.ForeColor = Theme.Muted;
            _hint.SetBounds(16, 330, 448, 40);
            _home.Controls.Add(_hint);
            var svcTitle = new Label { Text = "Сервисы через этот узел", Font = Theme.F(11, FontStyle.Bold) };
            svcTitle.SetBounds(16, 374, 300, 24);
            _home.Controls.Add(svcTitle);
            for (var i = 0; i < Services.List.Length; i++)
            {
                var name = new Label { Text = Services.List[i][1] };
                name.SetBounds(16, 402 + i * 24, 90, 22);
                _svc[i] = new Label { ForeColor = Theme.Muted, AutoEllipsis = true };
                _svc[i].SetBounds(106, 402 + i * 24, 358, 22);
                _home.Controls.Add(name);
                _home.Controls.Add(_svc[i]);
            }
            _svcBtn = Flat("Проверить сервисы", false);
            _svcBtn.SetBounds(16, 502, 200, 34);
            _svcBtn.Click += (s, e) => _e.CheckServices();
            _home.Controls.Add(_svcBtn);
            _update.SetBounds(226, 502, 238, 34);
            _update.Visible = false;
            _update.Click += (s, e) => InstallUpdate();
            _home.Controls.Add(_update);

            // Узлы
            SetupList(_nodes, "Узел", 220, "Тип", 120, "Задержка", 80);
            _nodes.SetBounds(16, 50, 448, 440);
            _nodes.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
            _nodes.DoubleClick += (s, e) => { if (_nodes.SelectedItems.Count == 1) _e.ConnectTo((Node)_nodes.SelectedItems[0].Tag); };
            var check = Flat("Проверить все", true);
            check.SetBounds(16, 8, 160, 36);
            check.Click += (s, e) => { _nodesInfo.Text = "Проверяю…"; Task.Run(() => _e.CheckAll(t => Ui(() => _nodesInfo.Text = t))); };
            _nodesInfo.SetBounds(186, 8, 278, 36);
            _nodesInfo.TextAlign = ContentAlignment.MiddleLeft;
            _nodesInfo.ForeColor = Theme.Muted;
            _nodesInfo.Text = "Двойной щелчок — подключиться к узлу";
            _nodesPage.Controls.AddRange(new Control[] { check, _nodesInfo, _nodes });

            // Источники
            SetupList(_sources, "Источник", 250, "Режим", 90, "Узлов", 70);
            _sources.CheckBoxes = true;
            _sources.SetBounds(16, 50, 448, 300);
            _sources.Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right;
            _sources.ItemChecked += (s, e) => { if (!_filling) _e.SetEnabled((Source)e.Item.Tag, e.Item.Checked); };
            var refresh = Flat("Обновить подписки", true);
            refresh.SetBounds(16, 8, 180, 36);
            refresh.Click += (s, e) => Task.Run(() => _e.RefreshSources());
            var remove = Flat("Удалить свой", false);
            remove.SetBounds(206, 8, 140, 36);
            remove.Click += (s, e) =>
            {
                var src = _sources.SelectedItems.Count == 1 ? (Source)_sources.SelectedItems[0].Tag : null;
                if (src == null || !src.Mine) { MessageBox.Show(this, "Выберите свою подписку в списке.", "Лоцман"); return; }
                _e.RemoveMine(src);
            };
            var addLabel = new Label { Text = "Свои подписки и ключи (ссылки https://…, vless://, vmess://, trojan://, ss://, hy2://):", ForeColor = Theme.Muted };
            addLabel.SetBounds(16, 358, 448, 36);
            _add.Multiline = true;
            _add.ScrollBars = ScrollBars.Vertical;
            _add.BackColor = Theme.Surface;
            _add.ForeColor = Theme.Fg;
            _add.BorderStyle = BorderStyle.FixedSingle;
            _add.SetBounds(16, 396, 448, 90);
            var addBtn = Flat("Добавить", true);
            addBtn.SetBounds(16, 494, 140, 36);
            addBtn.Click += (s, e) =>
            {
                var text = _add.Text;
                var shared = Share.Unpack(text);
                if (shared.Count > 0) text += "\n" + string.Join("\n", shared);
                text = System.Text.RegularExpressions.Regex.Replace(text, @"locman://\S+", "");
                var res = _e.AddMine(text);
                _add.Clear();
                MessageBox.Show(this, res, "Лоцман");
                Task.Run(() => _e.RefreshSources());
            };
            _sourcesPage.Controls.AddRange(new Control[] { refresh, remove, _sources, addLabel, _add, addBtn });

            // Настройки
            var y = 8;
            var mode = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, BackColor = Theme.Surface, ForeColor = Theme.Fg, FlatStyle = FlatStyle.Flat };
            mode.Items.AddRange(new object[] { "Обычный интернет", "Белые списки (мобильный интернет)", "Все источники" });
            mode.SelectedIndex = _e.S.Mode == "white" ? 1 : _e.S.Mode == "any" ? 2 : 0;
            mode.SelectedIndexChanged += (s, e) => { _e.S.Mode = new[] { "black", "white", "any" }[mode.SelectedIndex]; _e.S.Save(); FillSources(); };
            AddRow(_settingsPage, ref y, "Сеть", mode);
            var how = Combo(new[] { "Системный прокси — браузеры и программы", "Весь трафик (TUN) — нужны права администратора" }, _e.S.Tun ? 1 : 0);
            how.SelectedIndexChanged += (s, e) =>
            {
                _e.S.Tun = how.SelectedIndex == 1;
                _e.S.Save();
                try { Autostart.Apply(_e.S.Autostart, _e.S.Tun); } catch { }
                if (_e.Phase != Phase.Off) MessageBox.Show(this, "Новый режим заработает при следующем подключении.", "Лоцман");
                if (_e.S.Tun && !Elevation.IsAdmin) AskAdmin(false);
                Sync();
            };
            AddRow(_settingsPage, ref y, "Режим", how);
            var theme = Combo(new[] { "Тёмная", "Светлая" }, _e.S.Theme == "light" ? 1 : 0);
            theme.SelectedIndexChanged += (s, e) =>
            {
                _e.S.Theme = theme.SelectedIndex == 1 ? "light" : "dark";
                _e.S.Save();
                MessageBox.Show(this, "Тема сменится при следующем запуске «Лоцмана».", "Лоцман");
            };
            AddRow(_settingsPage, ref y, "Тема", theme);
            AddCheck(_settingsPage, ref y, "Российские сайты напрямую (банки, Госуслуги, Яндекс, VK)", _e.S.DirectRu, v => _e.S.DirectRu = v);
            AddCheck(_settingsPage, ref y, "Запускать вместе с Windows", _e.S.Autostart, v => { _e.S.Autostart = v; try { Autostart.Apply(v, _e.S.Tun); } catch { } });
            AddCheck(_settingsPage, ref y, "Проверять сервисы сразу после подключения", _e.S.AutoServices, v => _e.S.AutoServices = v);
            AddCheck(_settingsPage, ref y, "Запускать свёрнутым к часам", _e.S.StartMinimized, v => _e.S.StartMinimized = v);
            AddCheck(_settingsPage, ref y, "Крестик сворачивает к часам, а не закрывает", _e.S.CloseToTray, v => _e.S.CloseToTray = v);
            var about = new Label
            {
                Text = $"Лоцман Lite {AppInfo.Version} — для Windows 7 SP1 (x64). Ядро Xray для Windows 7.\n" +
                       "Полная версия «Лоцмана» — для Windows 10/11 и Android.\n" +
                       "Исходный код: github.com/atomicpel/locman (GPL-3.0).\n" +
                       "Подписки и настройки хранятся только на этом компьютере.",
                ForeColor = Theme.Muted,
            };
            var save = Flat("Сохранить копию в файл", false);
            save.SetBounds(16, y + 8, 220, 34);
            save.Click += (s, e) => SaveBackup();
            var load = Flat("Восстановить из копии", false);
            load.SetBounds(244, y + 8, 220, 34);
            load.Click += (s, e) => LoadBackup();
            var backupHint = new Label
            {
                Text = "Копия совместима с «Лоцманом» на телефоне: свои подписки и ключи переносятся в обе стороны. " +
                       "Файл не шифруется — в нём ссылки подписок и ключи.",
                ForeColor = Theme.Muted,
            };
            backupHint.SetBounds(16, y + 46, 448, 40);
            var upd = Flat("Проверить обновления", false);
            upd.SetBounds(16, y + 92, 220, 34);
            upd.Click += (s, e) => CheckUpdate(true);
            about.SetBounds(16, y + 136, 448, 90);
            var gh = Flat("Открыть страницу проекта", false);
            gh.SetBounds(16, y + 230, 230, 34);
            gh.Click += (s, e) => System.Diagnostics.Process.Start("https://github.com/atomicpel/locman/releases");
            _settingsPage.AutoScroll = true;
            _settingsPage.Controls.AddRange(new Control[] { save, load, backupHint, upd, about, gh });

            // Журнал
            _log.Multiline = true;
            _log.ReadOnly = true;
            _log.ScrollBars = ScrollBars.Vertical;
            _log.BackColor = Theme.Surface;
            _log.ForeColor = Theme.Fg;
            _log.BorderStyle = BorderStyle.None;
            _log.Font = new Font("Consolas", 9);
            _log.Dock = DockStyle.Fill;
            _logPage.Controls.Add(_log);

            // Значок у часов
            _tray.Icon = Icon;
            _tray.Text = "Лоцман Lite";
            _tray.Visible = true;
            var menu = new ContextMenuStrip();
            menu.Items.Add("Открыть", null, (s, e) => ShowWindow());
            menu.Items.Add("Подключить / отключить", null, (s, e) => _e.Toggle());
            menu.Items.Add("Переключить узел", null, (s, e) => { if (_e.Phase == Phase.On) _e.Switch(); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Выход", null, (s, e) => ExitApp());
            _tray.ContextMenuStrip = menu;
            _tray.DoubleClick += (s, e) => ShowWindow();

            _e.Changed += () => Ui(Sync);
            _e.Rates += () => Ui(SyncNode);
            _e.NeedAdmin += () => Ui(() => AskAdmin(true));
            _e.Logged += line => Ui(() =>
            {
                _log.AppendText(line + Environment.NewLine);
                if (_log.TextLength > 200000) _log.Text = _log.Text.Substring(100000);
            });

            Show(_home);
            Sync();
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            if (_startHidden) Hide();
            _e.CleanupStale();
            Task.Run(() =>
            {
                _e.LoadCatalog();
                if (!_e.Candidates().Any()) _e.RefreshSources();
                else Task.Run(() => _e.RefreshSources());
                if (_connectOnStart) Ui(() => _e.ConnectAuto(null));
                CheckUpdate(false);
            });
        }

        static Icon LoadIcon()
        {
            try
            {
                using (var st = Assembly.GetExecutingAssembly().GetManifestResourceStream("app.ico"))
                    return new Icon(st);
            }
            catch { return SystemIcons.Application; }
        }

        static Button Flat(string text, bool primary)
        {
            var b = new Button
            {
                Text = text, FlatStyle = FlatStyle.Flat, Cursor = Cursors.Hand,
                BackColor = primary ? Theme.Accent : Theme.Surface,
                ForeColor = primary ? Theme.OnAccent : Theme.Fg,
                Font = Theme.F(10, primary ? FontStyle.Bold : FontStyle.Regular),
                Padding = new Padding(8, 2, 8, 2),
            };
            b.FlatAppearance.BorderColor = primary ? Theme.Accent : Theme.Border;
            return b;
        }

        static void SetupList(ListView lv, params object[] cols)
        {
            lv.View = View.Details;
            lv.FullRowSelect = true;
            lv.HideSelection = false;
            lv.BackColor = Theme.Surface;
            lv.ForeColor = Theme.Fg;
            lv.BorderStyle = BorderStyle.None;
            for (var i = 0; i < cols.Length; i += 2) lv.Columns.Add((string)cols[i], (int)cols[i + 1]);
        }

        void AddRow(Panel p, ref int y, string label, Control c)
        {
            var l = new Label { Text = label, ForeColor = Theme.Muted };
            l.SetBounds(16, y + 4, 80, 24);
            c.SetBounds(100, y, 364, 28);
            p.Controls.Add(l);
            p.Controls.Add(c);
            y += 40;
        }

        void AddCheck(Panel p, ref int y, string text, bool value, Action<bool> set)
        {
            var c = new CheckBox { Text = text, Checked = value, ForeColor = Theme.Fg, FlatStyle = FlatStyle.Flat };
            c.SetBounds(16, y, 448, 30);
            c.CheckedChanged += (s, e) => { set(c.Checked); _e.S.Save(); };
            p.Controls.Add(c);
            y += 34;
        }

        void Show(Panel page)
        {
            foreach (Control c in _pages.Controls) c.Visible = c == page;
            if (page == _nodesPage) FillNodes();
            if (page == _sourcesPage) FillSources();
        }

        void Ui(Action a)
        {
            if (IsDisposed) return;
            if (InvokeRequired) { try { BeginInvoke(a); } catch { } }
            else a();
        }

        void Sync()
        {
            var on = _e.Phase == Phase.On;
            var busy = _e.Phase == Phase.Seek;
            _power.Sync(on, busy);
            _status.Text = on ? "Подключено" : busy ? "Поиск…" : "Выключено";
            _status.ForeColor = on ? Theme.Accent : busy ? Theme.Fg : Theme.Muted;
            SyncNode();
            _switch.Enabled = on;
            _hint.Text = _e.S.Tun
                ? (Elevation.IsAdmin ? "Режим «весь трафик»: через VPN идут все программы компьютера." : "Режим «весь трафик» включён, но нужны права администратора.")
                : "Режим «системный прокси»: через VPN идут браузеры и программы, которые его используют.";
            for (var i = 0; i < Services.List.Length; i++)
            {
                Tuple<bool, string> r;
                if (_e.ServiceResults.TryGetValue(Services.List[i][0], out r))
                {
                    _svc[i].Text = (r.Item1 ? "✓ " : "✗ ") + r.Item2;
                    _svc[i].ForeColor = r.Item1 ? Theme.Accent : Theme.Danger;
                }
                else
                {
                    _svc[i].Text = _e.CheckingServices ? "проверяю…" : on ? "не проверяли" : "—";
                    _svc[i].ForeColor = Theme.Muted;
                }
            }
            _svcBtn.Enabled = on && !_e.CheckingServices;
            _again.Enabled = !busy;
            _tray.Text = on ? "Лоцман: подключено" : busy ? "Лоцман: поиск" : "Лоцман: выключено";
            if (_nodesPage.Visible) FillNodes();
            if (_sourcesPage.Visible) FillSources();
        }

        void SyncNode()
        {
            var on = _e.Phase == Phase.On;
            _node.Text = on && _e.Active != null
                ? $"{_e.Active.Name}\n{_e.Active.Label}{(_e.Latency.TryGetValue(_e.Active.Id, out var l) && l > 0 ? $" · {l} мс" : "")} · ↓ {Speed(_e.RateDown)}  ↑ {Speed(_e.RateUp)}"
                : _e.Status;
        }

        static string Speed(long bps)
        {
            if (bps >= 1024 * 1024) return (bps / 1048576.0).ToString("0.0") + " МБ/с";
            if (bps >= 1024) return (bps / 1024) + " КБ/с";
            return bps + " Б/с";
        }

        void FillNodes()
        {
            var nodes = _e.Candidates()
                .OrderBy(n => _e.Latency.TryGetValue(n.Id, out var l) ? (l > 0 ? l : 100000) : 50000)
                .Take(500).ToList();
            _nodes.BeginUpdate();
            _nodes.Items.Clear();
            foreach (var n in nodes)
            {
                var lat = _e.Latency.TryGetValue(n.Id, out var l) ? (l > 0 ? l + " мс" : "нет ответа") : "—";
                var it = new ListViewItem(new[] { n.Name, n.Label, lat }) { Tag = n };
                if (_e.Active?.Id == n.Id) it.ForeColor = Theme.Accent;
                else if (l < 0) it.ForeColor = Theme.Muted;
                _nodes.Items.Add(it);
            }
            _nodes.EndUpdate();
        }

        void FillSources()
        {
            _filling = true;
            _sources.BeginUpdate();
            _sources.Items.Clear();
            var list = _e.AllSources.Where(s => s.Mine || _e.Fits(s)).OrderBy(s => s.Mine ? 0 : 1).ThenByDescending(s => s.Recommended);
            foreach (var src in list)
            {
                var count = _e.NodesBySource.TryGetValue(src.Id, out var ns) ? ns.Count.ToString() : "—";
                var mode = src.Mine ? "свой" : src.Mode == "white" ? "БС" : src.Mode == "black" ? "обычный" : "любой";
                _sources.Items.Add(new ListViewItem(new[] { src.Title, mode, count }) { Tag = src, Checked = _e.IsEnabled(src), ToolTipText = src.Description });
            }
            _sources.EndUpdate();
            _filling = false;
        }

        ComboBox Combo(string[] items, int index)
        {
            var c = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, BackColor = Theme.Surface, ForeColor = Theme.Fg, FlatStyle = FlatStyle.Flat };
            c.Items.AddRange(items);
            c.SelectedIndex = index;
            return c;
        }

        /// <summary>Режим «весь трафик» без прав администратора: перезапускаемся с ними.</summary>
        void AskAdmin(bool connect)
        {
            var r = MessageBox.Show(this,
                "Режиму «весь трафик (TUN)» нужны права администратора: Windows создаёт виртуальный сетевой адаптер.\n\n" +
                "Перезапустить «Лоцман» с правами администратора?\n«Нет» — подключиться через системный прокси.",
                "Лоцман", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
            if (r == DialogResult.Yes)
            {
                if (Elevation.Relaunch(connect ? "--connect --restarted" : "--restarted")) { _exiting = true; _e.Disconnect(); _tray.Visible = false; _mutexRelease?.Invoke(); Close(); }
                else MessageBox.Show(this, "Права администратора не получены.", "Лоцман");
            }
            else if (r == DialogResult.No && connect)
            {
                _e.S.Tun = false;
                _e.S.Save();
                _e.ConnectAuto(null);
            }
        }

        public Action _mutexRelease;

        void SaveBackup()
        {
            using (var d = new SaveFileDialog { Filter = "Резервная копия (*.json)|*.json", FileName = "locman-backup-" + DateTime.Now.ToString("yyyy-MM-dd") + ".json" })
            {
                if (d.ShowDialog(this) != DialogResult.OK) return;
                try
                {
                    System.IO.File.WriteAllText(d.FileName, Backup.Make(_e.S), new System.Text.UTF8Encoding(false));
                    MessageBox.Show(this, "Копия сохранена. Храните файл как пароль.", "Лоцман");
                }
                catch (Exception ex) { MessageBox.Show(this, "Не удалось сохранить: " + ex.Message, "Лоцман"); }
            }
        }

        void LoadBackup()
        {
            using (var d = new OpenFileDialog { Filter = "Резервная копия (*.json)|*.json|Все файлы|*.*" })
            {
                if (d.ShowDialog(this) != DialogResult.OK) return;
                try
                {
                    var added = Backup.Restore(_e.S, System.IO.File.ReadAllText(d.FileName, System.Text.Encoding.UTF8));
                    MessageBox.Show(this, "Восстановлено. Добавлено своих подписок и наборов ключей: " + added, "Лоцман");
                    Task.Run(() => { _e.LoadCatalog(); _e.RefreshSources(); });
                }
                catch (Exception ex) { MessageBox.Show(this, "Не получилось: " + ex.Message, "Лоцман"); }
            }
        }

        void CheckUpdate(bool manual)
        {
            Task.Run(() =>
            {
                try
                {
                    var u = Updater.Check(_e.Phase == Phase.On ? _e.S.HttpPort : (int?)null);
                    Ui(() =>
                    {
                        _pending = u;
                        _update.Text = u != null ? "Обновить до " + u.Version : "Обновить";
                        _update.Visible = u != null;
                        if (manual) MessageBox.Show(this, u != null ? $"Есть версия {u.Version}:\n{u.Notes}" : "У вас последняя версия.", "Лоцман");
                    });
                }
                catch (Exception ex) { if (manual) Ui(() => MessageBox.Show(this, "Не удалось проверить: " + ex.Message, "Лоцман")); }
            });
        }

        void InstallUpdate()
        {
            var u = _pending;
            if (u == null) return;
            _update.Enabled = false;
            Task.Run(() =>
            {
                try
                {
                    var path = Updater.Download(u, _e.Phase == Phase.On ? _e.S.HttpPort : (int?)null, pct => Ui(() => _update.Text = "Качаю… " + pct + "%"));
                    Ui(() =>
                    {
                        System.Diagnostics.Process.Start(path);
                        ExitApp();
                    });
                }
                catch (Exception ex)
                {
                    Ui(() =>
                    {
                        _update.Enabled = true;
                        _update.Text = "Обновить до " + u.Version;
                        MessageBox.Show(this, "Обновление не скачалось: " + ex.Message, "Лоцман");
                    });
                }
            });
        }

        void ShowWindow()
        {
            Show();
            WindowState = FormWindowState.Normal;
            Activate();
        }

        void ExitApp()
        {
            _exiting = true;
            _e.Disconnect();
            _tray.Visible = false;
            Close();
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (!_exiting && _e.S.CloseToTray && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                Hide();
                _tray.ShowBalloonTip(2000, "Лоцман", "Работает у часов. Выход — через меню значка.", ToolTipIcon.Info);
                return;
            }
            _e.Disconnect();
            _tray.Visible = false;
            base.OnFormClosing(e);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Program.ShowMessage) ShowWindow();
            base.WndProc(ref m);
        }
    }
}
