using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;

namespace QuestCast;

public partial class MainWindow : Window
{
    private readonly Settings _cfg;
    private readonly CastEngine _engine;
    private readonly ControlServer _server;
    private readonly ObservableCollection<string> _appLog = new();
    private readonly DispatcherTimer _timer;
    private bool _refreshing;
    private bool _busy;
    private CastState? _last;

    public MainWindow(Settings cfg)
    {
        _cfg = cfg;
        InitializeComponent();

        _engine = new CastEngine(cfg);
        _server = new ControlServer(cfg.Port, cfg.Token, _engine, AppLog);

        var addresses = _server.ListenAddresses();
        TxtLan.Text = addresses.Count > 0
            ? string.Join("   ", addresses)
            : "нет активных сетевых адресов";
        TxtPort.Text = $"порт {cfg.Port} · токен обязателен · протокол: JSON построчно";
        TxtToken.Text = cfg.Token;
        TxtFoot.Text = $"движок: {_engine.ScriptPath}";

        try
        {
            _server.Start();
        }
        catch (Exception ex)
        {
            // never block the GUI behind a modal box: log it and keep the window usable
            AppLog($"сервер не поднялся на порту {cfg.Port}: {ex.Message}");
            TxtLan.Text = $"сервер не слушает порт {cfg.Port}";
        }

        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.5) };
        _timer.Tick += async (_, _) => await RefreshAsync();
        _timer.Start();
        Loaded += async (_, _) => await RefreshAsync();
        Closed += async (_, _) => await _server.DisposeAsync();
    }

    private void AppLog(string line)
    {
        Dispatcher.Invoke(() =>
        {
            _appLog.Add($"{DateTime.Now:HH:mm:ss}  {line}");
            while (_appLog.Count > 400) _appLog.RemoveAt(0);
            TxtLog.Text = string.Join(Environment.NewLine, _appLog);
            TxtLog.ScrollToEnd();
        });
    }

    private async Task RefreshAsync()
    {
        if (_refreshing) return;
        _refreshing = true;
        try
        {
            var st = await _engine.ReadStateAsync();
            Render(st);
        }
        catch (Exception ex)
        {
            TxtSub.Text = ex.Message;
        }
        finally
        {
            _refreshing = false;
        }
    }

    private void Render(CastState st)
    {
        _last = st;
        TxtDevice.Text = st.Device;
        TxtCast.Text = st.Running
            ? (st.Fps > 0 ? $"{st.Fps} fps · {st.Mbps} Mb/s" : "запущен")
            : (st.DaemonRunning ? "пауза" : "остановлен");

        TxtCast.Foreground = st.Running ? (Brush)FindResource("Ok")
            : st.DaemonRunning ? (Brush)FindResource("Warn") : (Brush)FindResource("Muted");

        // the microphone is the privacy-critical bit: never let it be ambiguous
        if (st.Mic)
        {
            TxtMic.Text = "ON";
            TxtMic.Foreground = (Brush)FindResource("Bad");
            MicChip.Background = new SolidColorBrush(Color.FromRgb(0x5A, 0x1C, 0x22));
            MicChip.BorderBrush = new SolidColorBrush(Color.FromRgb(0xB3, 0x3A, 0x46));
            BtnMic.Content = "ВЫКЛЮЧИТЬ МИК";
        }
        else
        {
            TxtMic.Text = "OFF";
            TxtMic.Foreground = (Brush)FindResource("Muted");
            MicChip.Background = (Brush)FindResource("Card");
            MicChip.BorderBrush = (Brush)FindResource("Line");
            BtnMic.Content = "МИКРОФОН ВКЛ";
        }

        BtnLens.Content = st.Lens ? "ЛИНЗА ВКЛ" : "ЛИНЗА ВЫКЛ";
        if (RbLeft.IsChecked != true && st.Eye == "left") RbLeft.IsChecked = true;
        RbLeft.IsChecked = st.Eye == "left" ? true : RbLeft.IsChecked;
        if (st.Eye == "right") RbRight.IsChecked = true;
        else if (st.Eye == "both") RbBoth.IsChecked = true;
        else if (st.Eye == "left") RbLeft.IsChecked = true;

        TxtSub.Text = $"daemon {(st.DaemonRunning ? st.DaemonUp : "—")} · конвейер {(st.PipelineRunning ? st.PipelineUp : "—")} · {st.Player} · перезапусков {st.Restarts} · наклон {st.Tilt:0.0}°"
            + (st.AutoLevel ? $" · IMU {(double.IsNaN(st.ImuRoll) ? "—" : st.ImuRoll.ToString("0.0"))}°" : "")
            + (st.Guide ? $" · линия вкл" : "");
        BtnAuto.Content = _cfg.AutoLevel ? "АВТО ВКЛ" : "АВТО-ГОРИЗОНТ";
        BtnSign.Content = _cfg.TiltSign >= 0 ? "ЗНАК КРЕНА: ОБЫЧНЫЙ" : "ЗНАК КРЕНА: ПЕРЕВЁРНУТ";
        BtnGuide.Content = st.Guide ? "ЛИНИЯ ВКЛ" : "ЛИНИЯ";

        if (!_busy)
        {
            TxtBusy.Text = _server.ClientCount > 0 ? $"клиентов Android: {_server.ClientCount}" : "";
        }
    }

    private void SetBusy(string what)
    {
        _busy = true;
        TxtBusy.Text = what;
        foreach (var b in new[] { BtnStart, BtnStop, BtnRestart, BtnMic, BtnLens, BtnCalib, BtnAuto, BtnSign, BtnGuide, BtnMinus, BtnPlus })
            b.IsEnabled = false;
        foreach (var r in new[] { RbLeft, RbRight, RbBoth }) r.IsEnabled = false;
    }

    private void ClearBusy()
    {
        _busy = false;
        TxtBusy.Text = "";
        foreach (var b in new[] { BtnStart, BtnStop, BtnRestart, BtnMic, BtnLens, BtnCalib, BtnAuto, BtnSign, BtnGuide, BtnMinus, BtnPlus })
            b.IsEnabled = true;
        foreach (var r in new[] { RbLeft, RbRight, RbBoth }) r.IsEnabled = true;
    }

    private async Task RunActionAsync(string what, Func<Task<(bool ok, string text)>> action)
    {
        if (_busy) return;
        SetBusy(what);
        AppLog(what);
        try
        {
            var (ok, text) = await action();
            AppLog((ok ? "ok   " : "fail ") + text.Replace("\r", "").Replace("\n", " | "));
        }
        catch (Exception ex)
        {
            AppLog("fail  " + ex.Message);
        }
        finally
        {
            ClearBusy();
            await RefreshAsync();
        }
    }

    private async void Start_Click(object sender, RoutedEventArgs e) =>
        await RunActionAsync("запуск каста…", () => _engine.StartAsync());

    private async void Stop_Click(object sender, RoutedEventArgs e) =>
        await RunActionAsync("остановка…", () => _engine.StopAsync());

    private async void Restart_Click(object sender, RoutedEventArgs e) =>
        await RunActionAsync("перезапуск…", () => _engine.RestartAsync());

    private async void Mic_Click(object sender, RoutedEventArgs e) =>
        await RunActionAsync(_engine.Mic ? "выключаю микрофон…" : "включаю микрофон…",
            () => _engine.ApplyAndRestartAsync("audio", _engine.Mic ? "none" : "mic"));

    private async void Lens_Click(object sender, RoutedEventArgs e) =>
        await RunActionAsync(_engine.Lens ? "выключаю линзу…" : "включаю линзу…",
            () => _engine.ApplyAndRestartAsync("lens", !_engine.Lens));

    private async void Calib_Click(object sender, RoutedEventArgs e) =>
        await RunActionAsync("калибровка наклона (6 с, шлем не двигать)…", () => _engine.CalibrateAsync(null));

    private void Auto_Click(object sender, RoutedEventArgs e)
    {
        var on = !_cfg.AutoLevel;
        var (ok, text) = _engine.SetAutoLevel(on);
        AppLog((ok ? "ok   " : "fail ") + text);
        BtnAuto.Content = on ? "АВТО ВКЛ" : "АВТО-ГОРИЗОНТ";
    }

    private void Sign_Click(object sender, RoutedEventArgs e)
    {
        var invert = _cfg.TiltSign >= 0;
        var (ok, text) = _engine.SetTiltSign(invert);
        _cfg.TiltSign = invert ? -1 : 1;
        AppLog((ok ? "ok   " : "fail ") + text);
        BtnSign.Content = invert ? "ЗНАК КРЕНА: ПЕРЕВЁРНУТ" : "ЗНАК КРЕНА: ОБЫЧНЫЙ";
    }

    /// <summary>Alignment line: the headset draws the reference, the stream draws its twin.</summary>
    private void Guide_Click(object sender, RoutedEventArgs e)
    {
        // the line can also be switched from the headset, so the truth is the last
        // state we saw, not the copy of the config this window loaded at startup
        var current = _last?.Guide ?? _cfg.Guide;
        var on = !current;
        var (ok, text) = _engine.SetGuide(on);
        _cfg.Guide = on;
        AppLog((ok ? "ok   " : "fail ") + text);
        BtnGuide.Content = on ? "ЛИНИЯ ВКЛ" : "ЛИНИЯ";
    }

    private void Minus_Click(object sender, RoutedEventArgs e) => Nudge(-0.5);

    private void Plus_Click(object sender, RoutedEventArgs e) => Nudge(0.5);

    private void Nudge(double delta)
    {
        var (ok, text) = _engine.NudgeTilt(delta);
        AppLog((ok ? "ok   " : "fail ") + "наклон " + text);
    }

    private async void Eye_Click(object sender, RoutedEventArgs e)
    {
        string eye = RbRight.IsChecked == true ? "right" : RbBoth.IsChecked == true ? "both" : "left";
        await RunActionAsync($"переключаю на глаз: {eye}…", () => _engine.ApplyAndRestartAsync("eye", eye));
    }

    /// <summary>
    /// Windows blocks inbound connections to a listening app unless a firewall rule
    /// exists, and the rule cannot be created without elevation. Hand the job to the
    /// bundled script, which asks for admin rights itself.
    /// </summary>
    private void Firewall_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var helper = System.IO.Path.Combine(_cfg.CastHome ?? AppContext.BaseDirectory, "..", "allow-firewall.cmd");
            helper = System.IO.Path.GetFullPath(helper);
            if (!System.IO.File.Exists(helper))
            {
                helper = System.IO.Path.Combine(AppContext.BaseDirectory, "allow-firewall.cmd");
            }
            if (!System.IO.File.Exists(helper))
            {
                AppLog("allow-firewall.cmd не найден рядом с приложением");
                return;
            }

            var psi = new System.Diagnostics.ProcessStartInfo(helper, _cfg.Port.ToString())
            {
                UseShellExecute = true,
                Verb = "runas",
                WorkingDirectory = System.IO.Path.GetDirectoryName(helper)!,
            };
            System.Diagnostics.Process.Start(psi);
            AppLog("запрос прав администратора для правила брандмауэра…");
        }
        catch (Exception ex)
        {
            AppLog("firewall: " + ex.Message);
        }
    }

    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var text = $"{string.Join(",", _server.ListenAddresses())}  token={_cfg.Token}";
            Clipboard.SetText(text);
            AppLog("адрес и токен скопированы");
        }
        catch (Exception ex)
        {
            AppLog("clipboard: " + ex.Message);
        }
    }
}

