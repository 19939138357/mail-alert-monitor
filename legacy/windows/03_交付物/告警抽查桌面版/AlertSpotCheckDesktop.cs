// Apple-inspired desktop layout; native AntdUI controls, no custom button painting.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Management;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Button = AntdUI.Button;

internal static class AlertSpotCheckDesktopProgram
{
    [STAThread]
    private static void Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        AntdUI.Config.Mode = AntdUI.TMode.Light;
        AntdUI.Config.Animation = false;
        if (args.Length >= 2 && args[0] == "--preview")
        {
            // Render this form's own controls for visual QA; never start or send in this path.
            using (var form = new AlertSpotCheckForm(true))
            {
                int width = args.Length > 2 ? int.Parse(args[2]) : 1000;
                int height = args.Length > 3 ? int.Parse(args[3]) : 710;
                form.ClientSize = new Size(width, height);
                form.StartPosition = FormStartPosition.Manual;
                form.Location = new Point(-2400, -1800);
                form.ShowInTaskbar = false;
                form.Opacity = 0;
                form.Show();
                form.PerformLayout();
                Application.DoEvents();
                using (var bitmap = new Bitmap(form.Width, form.Height))
                {
                    form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size));
                    bitmap.Save(args[1], System.Drawing.Imaging.ImageFormat.Png);
                }
            }
            return;
        }
        if (args.Length >= 3 && args[0] == "--visual-check") { var check = new AlertSpotCheckForm(true); check.ClientSize = new Size(int.Parse(args[1]), int.Parse(args[2])); Application.Run(check); return; }
        var app = new AlertSpotCheckForm(false);
        if (args.Length > 0 && args[0] == "--system-login") app.Shown += delegate { app.OpenSystemLogin(); };
        Application.Run(app);
    }
}

internal sealed class AlertSpotCheckForm : Form
{
    private readonly string _projectRoot;
    private readonly string _monitorScript;
    private readonly string _configFile;
    private readonly string _logFile;
    private readonly bool _preview;
    private Process _monitorProcess;
    private readonly EdgeSystemLogin _systemLogin = new EdgeSystemLogin();
    private Label _loginStatusLabel;
    private Timer _refreshTimer;
    private Label _statusLabel;
    private Label _lastEventLabel;
    private Label _dependencyLabel;
    private Label _processLabel;
    private Label _updatedLabel;
    private Label _channelLabel;
    private Label _ruleLabel;
    private Label _intervalLabel;
    private FlowLayoutPanel _logBox;
    private Button _startButton;
    private Button _stopButton;
    private int _externalMonitorPid;
    private string _lastTail = null;
    private DateTime _logWriteAt = DateTime.MinValue;
    private long _logLength = -1;
    private string _cachedTail = "";
    private string _configurationSignature = "";
    private string _notificationSettingsPath;
    private readonly List<string> _sessionMessages = new List<string>();
    private string _lastProcessError = "";

    public AlertSpotCheckForm(bool preview)
    {
        _preview = preview;
        _projectRoot = FindProjectRoot();
        _monitorScript = Path.Combine(_projectRoot, "Monitor-WindowKeywords.ps1");
        _configFile = Path.Combine(_projectRoot, "monitor_config.json");
        _logFile = Path.Combine(_projectRoot, "monitor.log");
        _notificationSettingsPath = Path.Combine(_projectRoot, @"04_资料\私密配置\notification_settings.json");
        AutoScaleDimensions = new SizeF(96F, 96F);
        AutoScaleMode = AutoScaleMode.Dpi;
        Text = "屏幕告警手机推送";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(960, 654);
        MinimumSize = new Size(900, 640);
        Font = new Font(DesktopTheme.UiFont, 9.5F);
        BackColor = DesktopTheme.Surface;
        string iconPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "assets", "screen-alert.ico");
        if (File.Exists(iconPath)) Icon = new Icon(iconPath);
        DoubleBuffered = true;
        BuildUi();
        RefreshStatus();
        if (!preview)
        {
            _refreshTimer = new Timer { Interval = 2000 };
            _refreshTimer.Tick += delegate { RefreshStatus(); };
            _refreshTimer.Start();
        }
    }

    private void BuildUi()
    {
        SuspendLayout();
        var shell = Grid(3, 1, DesktopTheme.Surface);
        shell.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 190));
        shell.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 1));
        shell.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        shell.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        Controls.Add(shell);

        var sidebar = Grid(1, 7, DesktopTheme.Canvas);
        sidebar.Padding = new Padding(18, 26, 18, 18);
        sidebar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        foreach (int h in new int[] { 74, 28, 40, 46, 40 }) sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, h));
        sidebar.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        sidebar.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        var identity = Grid(2, 1, DesktopTheme.Canvas);
        identity.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 48));
        identity.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        var logo = new PictureBox { Dock = DockStyle.Top, Height = 42, SizeMode = PictureBoxSizeMode.Zoom, Margin = new Padding(0, 1, 6, 0), TabStop = false };
        string logoPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "assets", "screen-alert-256.png");
        if (File.Exists(logoPath)) { using (var source = Image.FromFile(logoPath)) logo.Image = new Bitmap(source); }
        identity.Controls.Add(logo, 0, 0);
        var brand = Grid(1, 2, DesktopTheme.Canvas);
        brand.RowStyles.Add(new RowStyle(SizeType.Absolute, 27));
        brand.RowStyles.Add(new RowStyle(SizeType.Absolute, 20));
        brand.Controls.Add(NewLabel("告警助手", 13, FontStyle.Bold, DesktopTheme.Ink), 0, 0);
        brand.Controls.Add(NewLabel("手机推送", 9, FontStyle.Regular, DesktopTheme.Muted), 0, 1);
        brand.Dock = DockStyle.Top; brand.Height = 47; identity.Controls.Add(brand, 1, 0);
        sidebar.Controls.Add(identity, 0, 0);
        var overview = NavigationButton("监控概览", DesktopTheme.MonitorSvg, true);
        overview.Click += delegate { RefreshStatus(); };
        sidebar.Controls.Add(overview, 0, 2);
        var settings = NavigationButton("通知设置", DesktopTheme.SettingsSvg, false);
        settings.Margin = new Padding(0, 6, 0, 0);
        settings.Click += delegate { RunPowerShellVisible("Configure-PhoneNotification.ps1"); };
        sidebar.Controls.Add(settings, 0, 3);
        var logs = NavigationButton("运行日志", DesktopTheme.LogSvg, false);
        logs.Click += delegate { OpenPath(_logFile); };
        sidebar.Controls.Add(logs, 0, 4);
        var quickAccess = Grid(1, 4, DesktopTheme.Canvas);
        quickAccess.Dock = DockStyle.Top;
        quickAccess.Height = 153;
        quickAccess.Padding = new Padding(0, 28, 0, 0);
        quickAccess.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
        quickAccess.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        quickAccess.RowStyles.Add(new RowStyle(SizeType.Absolute, 22));
        quickAccess.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        quickAccess.Controls.Add(NewLabel("示例企业系统", 9, FontStyle.Regular, DesktopTheme.Muted), 0, 0);
        var loginButton = NewButton("一键登录系统", false);
        loginButton.BackColor = DesktopTheme.Surface;
        loginButton.ForeColor = DesktopTheme.Accent;
        loginButton.Click += delegate { OpenSystemLogin(); };
        quickAccess.Controls.Add(loginButton, 0, 1);
        quickAccess.Controls.Add(NewLabel("在 Edge 浏览器中打开", 8.5F, FontStyle.Regular, DesktopTheme.Muted), 0, 2);
        _loginStatusLabel = NewLabel("", 8.5F, FontStyle.Regular, DesktopTheme.Muted);
        _loginStatusLabel.TextAlign = ContentAlignment.TopLeft;
        quickAccess.Controls.Add(_loginStatusLabel, 0, 3);
        sidebar.Controls.Add(quickAccess, 0, 5);
        var health = Grid(1, 2, DesktopTheme.Canvas);
        health.RowStyles.Add(new RowStyle(SizeType.Absolute, 20));
        health.RowStyles.Add(new RowStyle(SizeType.Absolute, 20));
        _dependencyLabel = NewLabel("", 8.5F, FontStyle.Regular, DesktopTheme.Muted);
        _processLabel = NewLabel("", 8, FontStyle.Regular, DesktopTheme.Muted);
        health.Controls.Add(_dependencyLabel, 0, 0);
        health.Controls.Add(_processLabel, 0, 1);
        sidebar.Controls.Add(health, 0, 6);
        shell.Controls.Add(sidebar, 0, 0);
        shell.Controls.Add(new Panel { Dock = DockStyle.Fill, BackColor = DesktopTheme.Border, Margin = Padding.Empty }, 1, 0);

        var main = Grid(1, 7, DesktopTheme.Surface);
        main.Padding = new Padding(32, 20, 32, 16);
        main.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        foreach (int h in new int[] { 56, 145, 126, 40, 43 }) main.RowStyles.Add(new RowStyle(SizeType.Absolute, h));
        main.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        main.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        shell.Controls.Add(main, 2, 0);

        var header = Grid(2, 1, DesktopTheme.Surface);
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 38));
        header.Controls.Add(NewLabel("屏幕监控", 18, FontStyle.Bold, DesktopTheme.Ink), 0, 0);
        var more = NewButton("", false);
        more.IconSvg = DesktopTheme.MoreSvg.Replace("currentColor", "#6E6E73");
        more.AccessibleName = "更多选项";
        more.Margin = new Padding(0, 10, 0, 10);
        more.DefaultBack = DesktopTheme.Canvas;
        more.BorderWidth = 0;
        var menu = new ContextMenuStrip { Font = new Font(DesktopTheme.UiFont, 9.5F) };
        menu.Items.Add("打开监控配置", null, delegate { OpenPath(_configFile); });
        menu.Items.Add("打开程序目录", null, delegate { OpenPath(_projectRoot); });
        more.Click += delegate { menu.Show(more, new Point(0, more.Height)); };
        header.Controls.Add(more, 1, 0);
        main.Controls.Add(header, 0, 0);

        var status = Grid(2, 1, DesktopTheme.Surface);
        status.Padding = new Padding(0, 20, 0, 20);
        status.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        status.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 146));
        var statusText = Grid(1, 2, DesktopTheme.Surface);
        statusText.Margin = new Padding(0, 0, 24, 0);
        statusText.RowStyles.Add(new RowStyle(SizeType.Absolute, 48));
        statusText.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        _statusLabel = NewLabel("准备就绪", 23, FontStyle.Regular, DesktopTheme.Ink);
        _lastEventLabel = NewLabel("", 10, FontStyle.Regular, DesktopTheme.Muted);
        _lastEventLabel.TextAlign = ContentAlignment.TopLeft;
        _lastEventLabel.Padding = new Padding(0, 8, 0, 0);
        statusText.Controls.Add(_statusLabel, 0, 0);
        statusText.Controls.Add(_lastEventLabel, 0, 1);
        status.Controls.Add(statusText, 0, 0);
        var actions = Grid(1, 3, DesktopTheme.Surface);
        actions.Padding = new Padding(0, 8, 0, 0);
        actions.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        actions.RowStyles.Add(new RowStyle(SizeType.Absolute, 10));
        actions.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        _startButton = NewButton("一键启动", true);
        _startButton.IconSvg = DesktopTheme.PlaySvg.Replace("currentColor", "#FFFFFF");
        _startButton.IconSize = new Size(15, 15);
        _startButton.Click += delegate { StartMonitor(); };
        _stopButton = NewButton("停止监控", false);
        _stopButton.Click += delegate { StopMonitor(); };
        actions.Controls.Add(_startButton, 0, 0);
        actions.Controls.Add(_stopButton, 0, 2);
        status.Controls.Add(actions, 1, 0);
        main.Controls.Add(status, 0, 1);

        var preferences = new AntdUI.Panel { Dock = DockStyle.Fill, Radius = 12, Back = DesktopTheme.Canvas, BackColor = DesktopTheme.Surface, BorderWidth = 0, Shadow = 0, Padding = new Padding(18, 4, 18, 4), Margin = Padding.Empty };
        var prefs = Grid(2, 3, DesktopTheme.Canvas);
        prefs.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 92));
        prefs.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (int i = 0; i < 3; i++) prefs.RowStyles.Add(new RowStyle(SizeType.Percent, 33.333F));
        prefs.Controls.Add(NewLabel("手机提醒", 10, FontStyle.Regular, DesktopTheme.Ink), 0, 0);
        _channelLabel = NewLabel("读取提醒方式…", 10, FontStyle.Regular, DesktopTheme.Ink);
        _channelLabel.TextAlign = ContentAlignment.MiddleRight;
        prefs.Controls.Add(_channelLabel, 1, 0);
        prefs.Controls.Add(NewLabel("检查间隔", 10, FontStyle.Regular, DesktopTheme.Ink), 0, 1);
        _intervalLabel = NewLabel("约 30 秒", 10, FontStyle.Regular, DesktopTheme.Muted);
        _intervalLabel.TextAlign = ContentAlignment.MiddleRight;
        prefs.Controls.Add(_intervalLabel, 1, 1);
        prefs.Controls.Add(NewLabel("验证码", 10, FontStyle.Regular, DesktopTheme.Ink), 0, 2);
        _ruleLabel = NewLabel("告警 6 位 / 电话 4 位", 10, FontStyle.Regular, DesktopTheme.Muted);
        _ruleLabel.TextAlign = ContentAlignment.MiddleRight;
        prefs.Controls.Add(_ruleLabel, 1, 2);
        preferences.Controls.Add(prefs);
        main.Controls.Add(preferences, 0, 2);
        var notifyActions = Grid(2, 1, DesktopTheme.Surface);
        notifyActions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        notifyActions.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 116));
        notifyActions.Controls.Add(NewLabel("识别新告警后，直接提醒到手机。", 9, FontStyle.Regular, DesktopTheme.Muted), 0, 0);
        var test = NewLink("发送测试通知");
        test.LinkClicked += delegate { RunPowerShellVisible("Test-VerificationPhone.ps1"); };
        notifyActions.Controls.Add(test, 1, 0);
        main.Controls.Add(notifyActions, 0, 3);

        var logHeading = Grid(2, 1, DesktopTheme.Surface);
        logHeading.Padding = new Padding(0, 9, 0, 0);
        logHeading.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        logHeading.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 112));
        logHeading.Controls.Add(NewLabel("最近活动", 11, FontStyle.Bold, DesktopTheme.Ink), 0, 0);
        var rawLog = NewLink("查看完整日志");
        rawLog.LinkClicked += delegate { OpenPath(_logFile); };
        logHeading.Controls.Add(rawLog, 1, 0);
        main.Controls.Add(logHeading, 0, 4);
        _logBox = new FlowLayoutPanel { Dock = DockStyle.Fill, BackColor = DesktopTheme.Surface, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Margin = new Padding(0, 8, 0, 0), AccessibleName = "最近活动" };
        _logBox.SizeChanged += delegate { ResizeLogEntries(); };
        main.Controls.Add(_logBox, 0, 5);
        var footer = Grid(1, 2, DesktopTheme.Surface);
        footer.RowStyles.Add(new RowStyle(SizeType.Absolute, 26));
        footer.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        footer.Controls.Add(NewLabel("保持目标画面在前台，鼠标键盘空闲 2 秒后开始识别。", 9, FontStyle.Regular, DesktopTheme.Muted), 0, 0);
        _updatedLabel = NewLabel("", 8, FontStyle.Regular, DesktopTheme.Muted);
        footer.Controls.Add(_updatedLabel, 0, 1);
        main.Controls.Add(footer, 0, 6);
        ResumeLayout(true);
    }

    private static TableLayoutPanel Grid(int columns, int rows, Color background)
    {
        return new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = columns, RowCount = rows, BackColor = background, Margin = Padding.Empty, Padding = Padding.Empty };
    }

    private static Label NewLabel(string text, float size, FontStyle style, Color color)
    {
        return new Label { Text = text, Font = new Font(DesktopTheme.UiFont, size, style), ForeColor = color, BackColor = Color.Transparent, Dock = DockStyle.Fill, AutoSize = false, AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft, Margin = Padding.Empty };
    }

    private static LinkLabel NewLink(string text)
    {
        return new LinkLabel { Text = text, Font = new Font(DesktopTheme.UiFont, 9), Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleRight, LinkBehavior = LinkBehavior.HoverUnderline, LinkColor = DesktopTheme.Accent, ActiveLinkColor = DesktopTheme.AccentPressed, VisitedLinkColor = DesktopTheme.Accent, Margin = Padding.Empty, AccessibleName = text };
    }

    private static Button NewButton(string text, bool primary)
    {
        return new Button { Text = text, Type = primary ? AntdUI.TTypeMini.Primary : AntdUI.TTypeMini.Default, BackColor = primary ? DesktopTheme.Accent : DesktopTheme.Surface, DefaultBack = DesktopTheme.Surface, BackHover = primary ? DesktopTheme.AccentHover : DesktopTheme.Canvas, BackActive = primary ? DesktopTheme.AccentPressed : DesktopTheme.Border, ForeColor = primary ? Color.White : DesktopTheme.Ink, Radius = 8, WaveSize = 0, BorderWidth = primary ? 0 : 1, Dock = DockStyle.Fill, Margin = Padding.Empty, Font = new Font(DesktopTheme.UiFont, 10), TabStop = true, AccessibleRole = AccessibleRole.PushButton, AccessibleName = text };
    }

    private static Button NavigationButton(string text, string icon, bool selected)
    {
        var button = NewButton(text, false);
        button.IconSvg = icon.Replace("currentColor", selected ? "#007AFF" : "#4B4B50");
        button.TextAlign = ContentAlignment.MiddleLeft;
        button.IconSize = new Size(18, 18);
        button.Padding = new Padding(12, 0, 8, 0);
        button.BorderWidth = 0;
        button.BackColor = selected ? DesktopTheme.AccentSoft : DesktopTheme.Canvas;
        button.DefaultBack = selected ? DesktopTheme.AccentSoft : DesktopTheme.Canvas;
        button.ForeColor = selected ? DesktopTheme.Accent : DesktopTheme.Ink;
        button.Font = new Font(DesktopTheme.UiFont, 10, selected ? FontStyle.Bold : FontStyle.Regular);
        button.BackHover = DesktopTheme.AccentSoft;
        return button;
    }
    internal void OpenSystemLogin()
    {
        if (_preview) return;
        _systemLogin.Open(_projectRoot, SetLoginStatus);
    }

    private void SetLoginStatus(string message)
    {
        if (IsDisposed || Disposing) return;
        if (InvokeRequired)
        {
            try { BeginInvoke(new Action<string>(SetLoginStatus), message); }
            catch (InvalidOperationException) { }
            return;
        }
        _loginStatusLabel.Text = message;
        try {
            string folder = Path.Combine(_projectRoot, @"04_资料\私密配置");
            Directory.CreateDirectory(folder);
            File.WriteAllText(Path.Combine(folder, "system-login-status.json"), new JavaScriptSerializer().Serialize(new { message = message, updatedAt = DateTime.Now.ToString("s") }), Encoding.UTF8);
        } catch { }
    }
    private void StartMonitor()
    {
        if (_preview) return;
        if (!File.Exists(_monitorScript))
        {
            ShowError("找不到主监控脚本：" + _monitorScript);
            return;
        }

        int existingPid = FindMonitorPid();
        if (existingPid > 0)
        {
            _externalMonitorPid = existingPid;
            RefreshStatus();
            return;
        }

        try
        {
            _lastProcessError = "";
            var info = new ProcessStartInfo
            {
                FileName = GetWindowsPowerShellPath(),
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File " + Quote(_monitorScript),
                WorkingDirectory = _projectRoot,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            _monitorProcess = Process.Start(info);
            if (_monitorProcess == null)
            {
                throw new InvalidOperationException("无法启动监控进程。");
            }

            _monitorProcess.OutputDataReceived += OnProcessOutput;
            _monitorProcess.ErrorDataReceived += OnProcessError;
            _monitorProcess.BeginOutputReadLine();
            _monitorProcess.BeginErrorReadLine();
            _externalMonitorPid = _monitorProcess.Id;
            AppendLog("[桌面版] 已启动主监控，PID=" + _monitorProcess.Id);
            RefreshStatus();
        }
        catch (Exception ex)
        {
            ShowError("启动监控失败：" + ex.Message);
        }
    }

    private void StopMonitor()
    {
        if (_preview) return;
        var pids = new List<int>();
        int currentPid = FindMonitorPid();
        if (currentPid > 0) pids.Add(currentPid);
        if (_monitorProcess != null && !_monitorProcess.HasExited && !pids.Contains(_monitorProcess.Id)) pids.Add(_monitorProcess.Id);

        if (pids.Count == 0)
        {
            RefreshStatus();
            return;
        }

        foreach (int pid in pids)
        {
            KillProcessTree(pid);
        }

        AppendLog("[桌面版] 已请求停止监控进程。");
        _externalMonitorPid = 0;
        RefreshStatus();
    }

    private void OnProcessOutput(object sender, DataReceivedEventArgs e)
    {
        if (!string.IsNullOrWhiteSpace(e.Data)) AppendLog(e.Data);
    }

    private void OnProcessError(object sender, DataReceivedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(e.Data) || IsDisposed) return;
        if (InvokeRequired)
        {
            try { BeginInvoke(new Action<object, DataReceivedEventArgs>(OnProcessError), sender, e); }
            catch (InvalidOperationException) { }
            return;
        }
        _lastProcessError = e.Data;
        AppendLog(e.Data);
    }

    private void RefreshStatus()
    {
        try
        {
            string nextStatus;
            string nextHint;
            Color nextStatusColor;
            int pid = FindMonitorPid();
            bool running = pid > 0;
            if (_monitorProcess != null && _monitorProcess.HasExited && !running)
            {
                _monitorProcess.Dispose();
                _monitorProcess = null;
            }
            _startButton.Enabled = !running;
            _startButton.Text = running ? "监控已启动" : "一键启动";
            _startButton.AccessibleName = _startButton.Text;
            _stopButton.Enabled = running;
            string tail = ReadLogTail(160);
            if (!string.Equals(tail, _lastTail, StringComparison.Ordinal))
            {
                _lastTail = tail;
                PopulateLog(tail);
            }
            string lastLine = LastNonEmptyLine(tail);
            var match = Regex.Match(lastLine, @"\[(?<state>[A-Za-z]+)\]\s*$");
            string state = match.Success ? match.Groups["state"].Value : "";
            nextStatusColor = DesktopTheme.Success;
            nextStatus = "正在监控";
            nextHint = "持续检查目标画面，发现新的有效告警后推送到手机。";
            if (!running)
            {
                nextStatus = "准备就绪";
                nextStatusColor = DesktopTheme.Ink;
                nextHint = "启动后自动识别屏幕告警，\n有新验证码时推送到手机。";
                if (!string.IsNullOrWhiteSpace(_lastProcessError))
                {
                    nextStatus = "监控已中断";
                    nextStatusColor = DesktopTheme.Danger;
                    nextHint = "请查看下方错误记录，检查后重新启动。";
                }
            }
            else if (state == "WaitingForTarget" || state == "WaitingForIdle")
            {
                nextStatus = "等待目标窗口";
                nextStatusColor = DesktopTheme.Warning;
                nextHint = "监控已启动。将目标窗口切到前台，停止操作鼠标键盘 2 秒。";
            }
            else if (state == "PermanentFailure" || state == "Uncertain")
            {
                nextStatus = state == "PermanentFailure" ? "请检查推送设置" : "推送结果待确认";
                nextStatusColor = DesktopTheme.Danger;
                nextHint = state == "PermanentFailure" ? "通知发送被拒绝，请打开“通知设置”检查手机提醒渠道。" : "本次推送尚未确认成功，请查看手机；程序不会重复发送。";
            }
            else if (state == "OpenedNewMail" || state == "ReadingPreview" || state == "WaitingForPreview" || state == "ConfirmingRow")
            {
                nextStatus = "正在识别告警";
                nextStatusColor = DesktopTheme.Accent;
                nextHint = "正在核对新告警与验证码，确认一致后推送。";
            }
            else if (state == "Sent")
            {
                nextStatus = "推送服务已受理";
                nextHint = "请以手机实际收件为准，监控继续运行。";
            }
            else if (state == "WaitingForCompleteSubject" || state == "OcrRetry" || state == "RetryableFailure" || state == "NoCode" || state == "Expired")
            {
                nextStatus = state == "NoCode" ? "请手动查看本次告警" : "等待核对告警";
                nextStatusColor = DesktopTheme.Warning;
                nextHint = FriendlyMessage(lastLine);
            }
            _processLabel.Text = running ? "后台运行中" : "监控未启动";
            _dependencyLabel.Text = BuildDependencyText();
            if (!File.Exists(_monitorScript) || !File.Exists(_configFile))
            {
                _startButton.Enabled = false;
                nextStatus = "请检查程序文件";
                nextStatusColor = DesktopTheme.Danger;
                nextHint = "请通过桌面快捷方式打开 D 盘项目中的完整程序。";
            }
            // Assign only the final state; intermediate labels caused visible repaint flicker.
            _statusLabel.Text = nextStatus;
            _statusLabel.ForeColor = nextStatusColor;
            _lastEventLabel.Text = nextHint;
            RefreshConfigurationSummary();
            _updatedLabel.Text = "状态更新 " + DateTime.Now.ToString("HH:mm:ss");
        }
        catch
        {
            _statusLabel.Text = "正在重新连接";
            _statusLabel.ForeColor = DesktopTheme.Warning;
            _lastEventLabel.Text = "稍后自动重试，可通过完整日志查看详细信息。";
        }
    }

    private string BuildDependencyText()
    {
        bool ready = File.Exists(_configFile) && File.Exists(_monitorScript) && File.Exists(GetWindowsPowerShellPath());
        return ready ? "运行环境已就绪" : "部分程序文件缺失";
    }

    private void RefreshConfigurationSummary()
    {
        string settingsPath = _notificationSettingsPath;
        DateTime changed = File.GetLastWriteTimeUtc(_configFile);
        string signature = changed.Ticks + "/" + File.GetLastWriteTimeUtc(settingsPath).Ticks;
        if (_configurationSignature == signature) return;
        int interval = 30;
        string provider = "";
        try
        {
            var serializer = new JavaScriptSerializer();
            var config = serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(_configFile, Encoding.UTF8));
            object value;
            if (config.TryGetValue("mailConfirmationListCheckIntervalSeconds", out value)) interval = Convert.ToInt32(value);
            if (config.TryGetValue("notificationSettingsFile", out value))
            {
                string configuredPath = Convert.ToString(value);
                settingsPath = Path.IsPathRooted(configuredPath) ? configuredPath : Path.Combine(_projectRoot, configuredPath);
            }
            if (File.Exists(settingsPath))
            {
                var settings = serializer.Deserialize<Dictionary<string, object>>(File.ReadAllText(settingsPath, Encoding.UTF8));
                if (settings.TryGetValue("provider", out value)) provider = Convert.ToString(value);
            }
        }
        catch { provider = ""; }
        _notificationSettingsPath = settingsPath;
        _configurationSignature = changed.Ticks + "/" + File.GetLastWriteTimeUtc(settingsPath).Ticks;
        _channelLabel.Text = provider == "wechat" ? "微信推送" : provider == "qqmail" ? "邮箱提醒" : provider == "dingtalk" ? "钉钉提醒" : "查看通知设置";
        _intervalLabel.Text = "约 " + interval + " 秒";
        _ruleLabel.Text = "告警 6 位 / 电话 4 位";
    }

    private string ReadLogTail(int maxLines)
    {
        if (!File.Exists(_logFile)) return "";
        try
        {
            var info = new FileInfo(_logFile);
            if (info.LastWriteTimeUtc == _logWriteAt && info.Length == _logLength) return _cachedTail;
            using (var stream = new FileStream(_logFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                long offset = Math.Max(0, stream.Length - 65536);
                stream.Seek(offset, SeekOrigin.Begin);
                using (var reader = new StreamReader(stream, Encoding.UTF8, true))
                {
                    if (offset > 0) reader.ReadLine();
                    string[] lines = reader.ReadToEnd().Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
                    int start = Math.Max(0, lines.Length - maxLines);
                    _cachedTail = string.Join(Environment.NewLine, lines, start, lines.Length - start);
                }
            }
            _logWriteAt = info.LastWriteTimeUtc;
            _logLength = info.Length;
            return _cachedTail;
        }
        catch (IOException) { return _cachedTail; }
    }

    private sealed class LogEntry
    {
        public string Time;
        public string Message;
        public int Count;
    }

    private void PopulateLog(string tail)
    {
        var entries = new List<LogEntry>();
        foreach (string line in tail.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var match = Regex.Match(line, @"^\[(?<time>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\s*(?<message>.*)$");
            string time = match.Success ? match.Groups["time"].Value : "";
            string message = FriendlyMessage(match.Success ? match.Groups["message"].Value : line);
            if (entries.Count > 0 && entries[entries.Count - 1].Message == message)
            {
                entries[entries.Count - 1].Time = time;
                entries[entries.Count - 1].Count++;
            }
            else entries.Add(new LogEntry { Time = time, Message = message, Count = 1 });
        }
        foreach (string line in _sessionMessages)
        {
            var match = Regex.Match(line, @"^\[(?<time>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]\s*(?<message>.*)$");
            if (match.Success)
            {
                string message = match.Groups["message"].Value;
                bool alsoInFile = false;
                foreach (string fileLine in tail.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
                    if (fileLine == message) { alsoInFile = true; break; }
                if (!alsoInFile) entries.Add(new LogEntry { Time = match.Groups["time"].Value, Message = FriendlyMessage(message), Count = 1 });
            }
        }
        entries.Sort(delegate(LogEntry a, LogEntry b) { return string.Compare(a.Time, b.Time, StringComparison.Ordinal); });
        _logBox.SuspendLayout();
        while (_logBox.Controls.Count > 0)
        {
            Control old = _logBox.Controls[0];
            _logBox.Controls.RemoveAt(0);
            old.Dispose();
        }
        if (entries.Count == 0)
        {
            entries.Add(new LogEntry { Time = "还没有运行记录", Message = "点击“一键启动”后，这里会显示最新状态。", Count = 1 });
        }
        for (int i = entries.Count - 1; i >= Math.Max(0, entries.Count - 5); i--)
        {
            var entry = entries[i];
            var row = new TableLayoutPanel { ColumnCount = 1, RowCount = 2, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Margin = new Padding(0, 0, 0, 14), Padding = Padding.Empty };
            row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            row.RowStyles.Add(new RowStyle(SizeType.Absolute, 23));
            row.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            var time = NewLabel((entry.Time.Length >= 19 ? entry.Time.Substring(5) : entry.Time) + (entry.Count > 1 ? "    已合并 " + entry.Count + " 条相同状态" : ""), 8.5F, FontStyle.Regular, DesktopTheme.Muted);
            var message = new Label { Text = entry.Message, AutoSize = true, Font = new Font(DesktopTheme.UiFont, 9.5F), ForeColor = DesktopTheme.Ink, Margin = Padding.Empty, Dock = DockStyle.Top };
            row.Controls.Add(time, 0, 0);
            row.Controls.Add(message, 0, 1);
            _logBox.Controls.Add(row);
        }
        ResizeLogEntries();
        _logBox.AutoScrollPosition = Point.Empty;
        _logBox.ResumeLayout(true);
    }

    private void ResizeLogEntries()
    {
        if (_logBox == null) return;
        int width = Math.Max(100, _logBox.ClientSize.Width - SystemInformation.VerticalScrollBarWidth - 4);
        foreach (Control row in _logBox.Controls)
        {
            row.Width = width;
            row.MinimumSize = new Size(width, 0);
            row.MaximumSize = new Size(width, 0);
            foreach (Control label in row.Controls) label.MaximumSize = new Size(width, 0);
        }
    }

    private static string FriendlyMessage(string line)
    {
        string text = Regex.Replace(line, @"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]\s*", "");
        var code = Regex.Match(text, @"\[(?<state>[A-Za-z]+)\]\s*$");
        if (code.Success)
        {
            switch (code.Groups["state"].Value)
            {
                case "WaitingForTarget": return "等待目标画面回到前台，并保持鼠标键盘空闲 2 秒。";
                case "WaitingForIdle": return "等待操作结束或目标窗口恢复。";
                case "Watching": return "正在检查目标画面，等待新的告警。";
                case "BaselineReady": return "已记住当前已有记录，开始检查后续新告警。";
                case "Sent": return "验证码推送已被服务受理，请以手机收件为准。";
                case "OpenedNewMail": return "已打开新告警，正在核对正文中的验证码。";
                case "ReadingPreview": return "正在核对告警类型、时间和验证码。";
                case "NoCode": return "未能核对验证码；手动查看提醒已被服务受理。";
                case "OcrRetry": return "本轮画面未识别成功，稍后自动重试。";
                case "DryRun": return "只读检查完成，未点击、未发送。";
            }
            text = Regex.Replace(text, @"\s*\[[A-Za-z]+\]\s*$", "");
        }
        if (text.StartsWith("自动取确认码已启动")) return "监控已启动，开始检查新告警。";
        if (text == "Auto mail confirmation stopped.") return "本次监控已停止。";
        return text.Replace("自动取确认码：", "");
    }
    private void RunPowerShellVisible(string scriptName)
    {
        if (_preview) return;
        string script = Path.Combine(_projectRoot, scriptName);
        if (!File.Exists(script))
        {
            ShowError("找不到脚本：" + script);
            return;
        }

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = GetWindowsPowerShellPath(),
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File " + Quote(script),
                WorkingDirectory = _projectRoot,
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Normal
            });
        }
        catch (Exception ex)
        {
            ShowError("打开功能失败：" + ex.Message);
        }
    }

    private void OpenPath(string path)
    {
        if (_preview) return;
        try
        {
            Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
        }
        catch (Exception ex)
        {
            ShowError("无法打开路径：" + ex.Message);
        }
    }

    private int FindMonitorPid()
    {
        string needle = _monitorScript.Replace("'", "''");
        try
        {
            using (var searcher = new ManagementObjectSearcher("SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='powershell.exe' OR Name='pwsh.exe'"))
            using (ManagementObjectCollection processes = searcher.Get())
            {
                foreach (ManagementObject process in processes)
                {
                    string commandLine = Convert.ToString(process["CommandLine"]);
                    if (string.IsNullOrWhiteSpace(commandLine)) continue;
                    if (Regex.IsMatch(commandLine, @"(?:^|\s)-File\s+", RegexOptions.IgnoreCase) && commandLine.IndexOf("Monitor-WindowKeywords.ps1", StringComparison.OrdinalIgnoreCase) >= 0 &&
                        commandLine.IndexOf(Path.GetFileName(_projectRoot), StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        return Convert.ToInt32(process["ProcessId"]);
                    }
                }
            }
        }
        catch
        {
            if (_monitorProcess != null && !_monitorProcess.HasExited) return _monitorProcess.Id;
        }
        return 0;
    }

    private static void KillProcessTree(int pid)
    {
        try
        {
            foreach (int child in GetChildProcessIds(pid)) KillProcessTree(child);
        }
        catch { }

        try
        {
            using (Process process = Process.GetProcessById(pid))
            {
                if (!process.HasExited) process.Kill();
            }
        }
        catch { }
    }

    private static IEnumerable<int> GetChildProcessIds(int parentPid)
    {
        var result = new List<int>();
        using (var searcher = new ManagementObjectSearcher("SELECT ProcessId FROM Win32_Process WHERE ParentProcessId = " + parentPid))
        using (ManagementObjectCollection processes = searcher.Get())
        {
            foreach (ManagementObject process in processes)
            {
                result.Add(Convert.ToInt32(process["ProcessId"]));
            }
        }
        return result;
    }

    private static string FindProjectRoot()
    {
        string current = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
        string probe = current;
        for (int i = 0; i < 5 && !string.IsNullOrWhiteSpace(probe); i++)
        {
            if (File.Exists(Path.Combine(probe, "Monitor-WindowKeywords.ps1"))) return probe;
            DirectoryInfo parent = Directory.GetParent(probe);
            probe = parent == null ? null : parent.FullName;
        }

        return current;
    }

    private static string GetWindowsPowerShellPath()
    {
        string windir = Environment.GetEnvironmentVariable("WINDIR");
        if (string.IsNullOrWhiteSpace(windir)) windir = @"C:\Windows";
        return Path.Combine(windir, @"System32\WindowsPowerShell\v1.0\powershell.exe");
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private void AppendLog(string line)
    {
        if (IsDisposed) return;
        if (InvokeRequired)
        {
            try { BeginInvoke(new Action<string>(AppendLog), line); }
            catch (InvalidOperationException) { }
            return;
        }
        if (string.IsNullOrWhiteSpace(line) || ReadLogTail(160).IndexOf(line, StringComparison.Ordinal) >= 0) return;
        string entry = "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + line;
        _sessionMessages.Add(entry);
        if (_sessionMessages.Count > 12) _sessionMessages.RemoveAt(0);
        _lastTail = null;
        RefreshStatus();
    }

    private static string LastNonEmptyLine(string value)
    {
        string[] lines = value.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
        return lines.Length == 0 ? string.Empty : lines[lines.Length - 1].Trim();
    }

    private static string TrimForLabel(string value, int length)
    {
        return value.Length <= length ? value : value.Substring(0, length - 1) + "…";
    }

    private static void ShowError(string message)
    {
        MessageBox.Show(message, "屏幕告警手机推送", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (_preview) { base.OnFormClosing(e); return; }
        _refreshTimer.Stop();
        int pid = FindMonitorPid();
        if (pid > 0)
        {
            DialogResult result = MessageBox.Show(
                "监控仍在运行。选择“是”同时停止监控，选择“否”仅关闭桌面窗口并保持后台监控。",
                "退出桌面版",
                MessageBoxButtons.YesNoCancel,
                MessageBoxIcon.Question);
            if (result == DialogResult.Cancel)
            {
                e.Cancel = true;
                _refreshTimer.Start();
                return;
            }
            if (result == DialogResult.Yes) KillProcessTree(pid);
        }
        base.OnFormClosing(e);
    }
}
