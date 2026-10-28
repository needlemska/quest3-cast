using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace QuestCast;

/// <summary>Live view of the cast, assembled from the service state files.</summary>
public sealed record CastState
{
    public bool DaemonRunning { get; init; }
    public bool PipelineRunning { get; init; }
    public string Device { get; init; } = "unknown";
    public string Eye { get; init; } = "left";
    public bool Mic { get; init; }
    public bool Lens { get; init; }
    public double Tilt { get; init; }
    public int Fps { get; init; }
    public double Mbps { get; init; }
    public string Player { get; init; } = "mpv";
    public int Restarts { get; init; }
    public string DaemonUp { get; init; } = "";
    public string PipelineUp { get; init; } = "";
    public string LogTail { get; init; } = "";
    public bool Guide { get; init; }
    public double ImuRoll { get; init; } = double.NaN;
    public bool AutoLevel { get; init; }
    public double TrimResidual { get; init; } = double.NaN;

    public bool Running => DaemonRunning && PipelineRunning;
}

/// <summary>
/// Front-end over the proven PowerShell engine (quest3-cast.ps1): the exe owns the
/// UI, the LAN protocol and the config, the script owns the capture pipeline.
/// </summary>
public sealed class CastEngine
{
    private readonly Settings _settings;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private string? _adbPath;
    private DateTime _deviceAt = DateTime.MinValue;
    private string _device = "unknown";

    public string CastHome { get; }
    public string ScriptPath => Path.Combine(CastHome, "quest3-cast.ps1");
    public string ConfigPath => Path.Combine(CastHome, "config.json");
    /// <summary>Where the engine keeps its pid/heartbeat/runtime files. When the GUI is
    /// itself started in a restricted context it cannot write into %LOCALAPPDATA%,
    /// so it hands the engine a state directory it can write (see StateOverride).</summary>
    public static string StateOverride =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QuestCast", "state");

    public string StateDir => Environment.GetEnvironmentVariable("QUEST3CAST_STATE") is { Length: > 0 } dir
        ? dir
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "quest3-cast");
    public string LogPath => Path.Combine(StateDir, "cast.log");

    public CastEngine(Settings settings)
    {
        _settings = settings;
        CastHome = LocateCastHome(settings);
    }

    private static string LocateCastHome(Settings settings)
    {
        var candidates = new List<string>();
        if (!string.IsNullOrWhiteSpace(settings.CastHome)) candidates.Add(settings.CastHome);
        var env = Environment.GetEnvironmentVariable("QUEST3CAST_HOME");
        if (!string.IsNullOrWhiteSpace(env)) candidates.Add(env);
        // typical layout: repo\app\QuestCast\bin\<cfg>\app\cast or a "cast" folder next to the exe
        candidates.Add(Path.Combine(AppContext.BaseDirectory, "cast"));
        candidates.Add(Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "engine")));

        foreach (var dir in candidates)
        {
            if (File.Exists(Path.Combine(dir, "quest3-cast.ps1"))) return dir;
        }
        return candidates[^1];
    }

    // ---------------------------------------------------------------- config

    public JsonObject ReadConfig()
    {
        var json = File.Exists(ConfigPath) ? File.ReadAllText(ConfigPath) : "{}";
        return JsonNode.Parse(json) as JsonObject ?? new JsonObject();
    }

    private readonly object _cfgLock = new();

    private void PatchConfig(Action<JsonObject> patch)
    {
        // two threads patch the config at once (a LAN command and a UI click), and a
        // plain WriteAllText there can leave a truncated file behind. Serialise the
        // read-modify-write and swap the file atomically instead.
        lock (_cfgLock)
        {
            var cfg = ReadConfig();
            patch(cfg);
            var tmp = ConfigPath + ".tmp";
            File.WriteAllText(tmp, cfg.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            File.Move(tmp, ConfigPath, true);
        }
    }

    public string Eye => ReadConfig()["eye"]?.GetValue<string>() ?? "left";
    public bool Mic => (ReadConfig()["audio"]?.GetValue<string>() ?? "none") == "mic";
    public bool Lens => ReadConfig()["lens"]?.GetValue<bool>() ?? true;

    // --------------------------------------------------------------- actions

    public async Task<(bool ok, string text)> StartAsync()
    {
        var (code, output) = await RunAsync(new[] { "start" }, 60_000);
        // the daemon wipes guide.json on every start so a line left over from the
        // previous session cannot hang over the picture. That also wipes a line the
        // operator *asked* for, so put the remembered intent back explicitly.
        if (code == 0 && _settings.Guide)
        {
            try { SetGuide(true); }
            catch (Exception ex) { ELog($"start: guide restore failed ({ex.GetType().Name}: {ex.Message})"); }
        }
        return (code == 0, output.Trim());
    }

    public async Task<(bool ok, string text)> StopAsync()
    {
        var (code, output) = await RunAsync(new[] { "stop" }, 60_000);
        return (code == 0, output.Trim());
    }

    public async Task<(bool ok, string text)> RestartAsync()
    {
        await RunAsync(new[] { "stop" }, 60_000);
        return await StartAsync();
    }

    public async Task<(bool ok, string text)> CalibrateAsync(double? deg)
    {
        var args = deg is null ? new[] { "calibrate" } : new[] { "calibrate", "-Deg", deg.Value.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) };
        var (code, output) = await RunAsync(args, 120_000);
        if (code != 0) return (false, output.Trim());

        var text = output.Trim();
        // calibrate measures the picture, so it is also the right moment to re-base the
        // auto-level: the IMU pose that goes with this picture becomes the zero point
        var roll = LastRoll;
        var fresh = (DateTime.UtcNow - _tiltAt).TotalSeconds < 10;
        if (_settings.AutoLevel && fresh && !double.IsNaN(roll))
        {
            var tilt = ReadTiltFromRuntime();
            _settings.TiltBaseDeg = tilt;
            _settings.TiltBaseRoll = roll;
            _settings.Save();
            _lastAppliedDeg = double.NaN;
            text += $"\nбаза авто-горизонта: {tilt:0.0} deg при roll {roll:0.0} deg";
        }
        else if (_settings.AutoLevel)
        {
            text += "\nIMU молчит (нет данных за 10 с): база авто-горизонта не обновлена";
        }
        return (true, text);
    }

    /// <summary>Eye or mic or lens changed: the pipeline reads these at start, so restart it.</summary>
    public async Task<(bool ok, string text)> ApplyAndRestartAsync(string key, JsonNode? value)
    {
        PatchConfig(cfg => cfg[key] = value);
        return await RestartAsync();
    }

    /// <summary>
    /// Alignment guide: a line over the picture at the current rotation. The client
    /// draws its twin in the headset, so the operator can bring the two together and
    /// read the error straight off the screen instead of guessing.
    /// </summary>
    public (bool ok, string text) SetGuide(bool on)
    {
        _settings.Guide = on;
        _settings.Save();
        PatchConfig(cfg => cfg["guide"] = on);

        // The line itself is drawn by the HUD overlay window, not by the shader: the
        // player may ignore a shader swap mid-stream, while a topmost window always
        // shows. The shader keeps its own guide disabled so the two never disagree.
        try
        {
            var req = Path.Combine(StateDir, "guide.json");
            var tmp = req + ".tmp";
            // the guide angle must be the one the player is really showing: with
            // auto-level on, config.rotateDeg is only the base, not what is on screen
            var live = (DateTime.UtcNow - _lastApply).TotalSeconds < 5 && double.IsFinite(_lastAppliedDeg);
            File.WriteAllText(tmp, System.Text.Json.JsonSerializer.Serialize(new
            {
                on,
                deg = live ? _lastAppliedDeg : CurrentDeg(),
                ts = DateTime.UtcNow.ToString("o")
            }));
            File.Move(tmp, req, true);
        }
        catch (Exception ex)
        {
            ELog($"guide: write failed ({ex.GetType().Name}: {ex.Message})");
        }

        // no shader work here on purpose: the guide lives in the overlay window, and
        // rewriting tilt.json would fight the IMU driver with an out-of-date angle
        return (true, on ? "линия на стриме включена" : "линия на стриме выключена");
    }

    /// <summary>Nudge the streamed rotation by a step while the guide line is up.</summary>
    public (bool ok, string text) NudgeTilt(double delta)
    {
        var deg = CurrentDeg() + delta;
        if (deg > 180) deg -= 360;
        if (deg < -180) deg += 360;
        deg = Math.Round(deg * 2) / 2;
        PatchConfig(cfg => cfg["rotateDeg"] = deg);
        if (_settings.AutoLevel)
        {
            // keep tracking relative to the new picture tilt, otherwise the next IMU
            // sample would pull the frame back to the old base. If the client is not
            // sending tilt right now there is no roll to rebase on - keep the old one,
            // a NaN base would poison every later sample
            var roll = LastRoll;
            _settings.TiltBaseDeg = deg;
            if (double.IsFinite(roll)) _settings.TiltBaseRoll = roll;
            _settings.Save();
        }
        _lastAppliedDeg = double.NaN;
        _ = Task.Run(() => ApplyDegAsync(deg));
        return (true, $"{deg:0.0} deg");
    }

    private double CurrentDeg()
    {
        try
        {
            var cfg = ReadConfig();
            return cfg["rotateDeg"]?.GetValue<double>() ?? 0;
        }
        catch { return 0; }
    }

    /// <summary>Regenerate the shader for an explicit angle (used by the guide and nudges).</summary>
    private Task ApplyDegAsync(double deg)
    {
        try
        {
            var shader = WriteLiveShader(Math.Round(deg * 2) / 2);
            var req = Path.Combine(StateDir, "tilt.json");
            var tmp = req + ".tmp";
            File.WriteAllText(tmp, System.Text.Json.JsonSerializer.Serialize(new
            {
                shader,
                deg,
                ts = DateTime.UtcNow.ToString("o")
            }));
            File.Move(tmp, req, true);
            _lastAppliedDeg = deg;
            _lastApply = DateTime.UtcNow;
        }
        catch (Exception ex)
        {
            ELog($"guide: write failed ({ex.GetType().Name}: {ex.Message})");
        }
        return Task.CompletedTask;
    }

    // ------------------------------------------------- live horizon levelling

    private readonly object _tiltLock = new();
    private double _tiltRoll = double.NaN;
    private double _tiltPitch = double.NaN;
    private DateTime _tiltAt = DateTime.MinValue;
    private DateTime _lastApply = DateTime.MinValue;
    private double _lastAppliedDeg = double.NaN;

    public double LastRoll { get { lock (_tiltLock) return _tiltRoll; } }
    public double LastPitch { get { lock (_tiltLock) return _tiltPitch; } }

    /// <summary>Latest roll/pitch from the headset IMU (client pushes these).</summary>
    public void SubmitTilt(double roll, double pitch)
    {
        lock (_tiltLock)
        {
            _tiltRoll = roll;
            _tiltPitch = pitch;
            _tiltAt = DateTime.UtcNow;
            _rollTrack.Enqueue((_tiltAt, roll));
            while (_rollTrack.Count > 0 && (_tiltAt - _rollTrack.Peek().at).TotalSeconds > 3)
                _rollTrack.Dequeue();
        }
        if (!_settings.AutoLevel) return;
        _ = Task.Run(ApplyTiltAsync);
    }

    private readonly Queue<(DateTime at, double roll)> _rollTrack = new();

    /// <summary>
    /// Spread of the roll over the last couple of seconds, or NaN when the sample
    /// stream is too short to judge. A moving head must not be "corrected": the
    /// measurement would lag behind the pose and the trim would chase its tail.
    /// </summary>
    private double RollSpread()
    {
        lock (_tiltLock)
        {
            if (_rollTrack.Count < 4) return double.NaN;
            var lo = double.MaxValue;
            var hi = double.MinValue;
            foreach (var (at, roll) in _rollTrack)
            {
                if (!double.IsFinite(roll)) return double.NaN;
                lo = Math.Min(lo, roll);
                hi = Math.Max(hi, roll);
            }
            return hi - lo;
        }
    }

    public (bool ok, string text) SetAutoLevel(bool on)
    {
        if (on)
        {
            // base capture: remember what tilt the picture had, and what the IMU read then.
            // Without a recent IMU sample the base is useless - the level would drift with
            // a constant offset - so say it out loud instead of silently storing zero.
            var tilt = ReadTiltFromRuntime();
            var roll = LastRoll;
            var fresh = (DateTime.UtcNow - _tiltAt).TotalSeconds < 10;
            _settings.TiltBaseDeg = tilt;
            _settings.TiltBaseRoll = fresh && !double.IsNaN(roll) ? roll : 0;
            _settings.AutoLevel = true;
            _settings.Save();
            _lastAppliedDeg = double.NaN;
            if (!fresh) return (true, $"auto-level on, base: tilt {tilt:0.0} deg, IMU пока молчит (база по roll 0 - нажмите КАЛИБРОВКА в шлеме)");
            return (true, $"auto-level on, base: tilt {tilt:0.0} deg at imu roll {_settings.TiltBaseRoll:0.0} deg");
        }
        _settings.AutoLevel = false;
        _settings.Save();
        return (true, "auto-level off");
    }

    public (bool ok, string text) SetTiltSign(bool invert)
    {
        // some vendors report the gravity vector with the opposite handedness; when the
        // horizon leans the wrong way this flips the tracking direction in one click
        _settings.TiltSign = invert ? -1 : 1;
        _settings.Save();
        _lastAppliedDeg = double.NaN;
        return (true, invert ? "auto-level sign: inverted" : "auto-level sign: normal");
    }

    /// <summary>
    /// How much picture rotation one degree of head roll produces. The leftover lean the
    /// operator sees after a head turn is exactly a wrong gain: with 1.0 the picture
    /// lags the head, with 1.2 it overshoots.
    /// </summary>
    public (bool ok, string text) SetGain(double gain)
    {
        if (!double.IsFinite(gain)) return (false, "gain: не число");
        _settings.TiltGain = Math.Round(Math.Clamp(gain, 0.4, 1.8), 2);
        _settings.Save();
        _lastAppliedDeg = double.NaN;
        return (true, $"gain {_settings.TiltGain:0.00}");
    }

    public double TiltGain => _settings.TiltGain;

    private double ReadTiltFromRuntime()
    {
        try
        {
            var cfg = ReadConfig();
            return cfg["rotateDeg"]?.GetValue<double>() ?? 0;
        }
        catch { return 0; }
    }

    /// <summary>Rewrite lens/live.glsl and ask the running mpv to reload it.</summary>
    private async Task ApplyTiltAsync()
    {
        double roll;
        DateTime at;
        lock (_tiltLock) { roll = _tiltRoll; at = _tiltAt; }
        if (double.IsNaN(roll)) return;
        if ((DateTime.UtcNow - at).TotalSeconds > 2) return;          // stale sample
        if ((DateTime.UtcNow - _lastApply).TotalMilliseconds < 250) return;  // throttle

        var deg = _settings.TiltBaseDeg + _settings.TiltSign * _settings.TiltGain * (roll - _settings.TiltBaseRoll);
        deg = Math.Round(deg * 2) / 2;                                  // 0.5 deg steps
        if (!double.IsNaN(_lastAppliedDeg) && Math.Abs(deg - _lastAppliedDeg) < 0.4) return;

        try
        {
            var shader = WriteLiveShader(deg);
            _lastApply = DateTime.UtcNow;
            _lastAppliedDeg = deg;
            // the pump owns mpv's pipe (this process cannot open it), so the handover
            // is a two-field file: shader path + timestamp the pump watches
            var req = Path.Combine(StateDir, "tilt.json");
            var tmp = req + ".tmp";
            File.WriteAllText(tmp, System.Text.Json.JsonSerializer.Serialize(new
            {
                shader,
                deg,
                ts = DateTime.UtcNow.ToString("o")
            }));
            File.Move(tmp, req, true);
            LogTiltSample(roll, deg);
        }
        catch (Exception ex)
        {
            ELog($"tilt: write failed ({ex.GetType().Name}: {ex.Message}) at {StateDir}");
        }
    }

    private int _tiltLogLines;

    /// <summary>
    /// Session log of (IMU roll, applied tilt). It exists so the gain can be fitted from
    /// real data instead of guessed: a straight line through these points gives both the
    /// true degrees-per-degree and the offset of the base.
    /// </summary>
    private void LogTiltSample(double roll, double deg)
    {
        try
        {
            var path = Path.Combine(StateDir, "tiltlog.csv");
            if (_tiltLogLines == 0 || !File.Exists(path))
                File.WriteAllText(path, "iso,imu_roll,tilt_deg\n");
            File.AppendAllText(path, string.Create(
                System.Globalization.CultureInfo.InvariantCulture,
                $"{DateTime.UtcNow:o},{roll:0.00},{deg:0.00}\n"));
            if (++_tiltLogLines > 20000) _tiltLogLines = 0;
        }
        catch
        {
            // logging must never break the levelling itself
        }
    }

    // ------------------------------------------------- closed-loop trim

    /// <summary>What the optical check still measured, degrees (NaN = never measured).</summary>
    public double TrimResidual { get; private set; } = double.NaN;

    /// <summary>
    /// One correction step of the auto-level: measure what is left of the tilt on the
    /// frame that is actually displayed, then shift the base by exactly that amount.
    ///
    /// Why feedback and not just the IMU: one degree of head roll is not one degree of
    /// image roll. The panel is composited onto a curved surface, the lens correction
    /// is not the inverse of the pre-distortion, and the IMU axes are not exactly the
    /// panel axes. All three act as an unknown gain slightly off 1, which the naive
    /// mapping cannot cancel and the operator sees as a leftover lean. Closing the loop
    /// on the picture is the only way to make the residual actually zero.
    /// </summary>
    public async Task<(bool ok, string text)> TrimOnceAsync()
    {
        if (!_settings.TrimEnabled) return (false, "экспериментальная подстройка выключена");
        if (!_settings.AutoLevel) return (false, "auto-level выключен");

        var spread = RollSpread();
        if (double.IsNaN(spread)) return (false, "мало сэмплов IMU - включите авто-горизонт на шлеме");
        if (spread > 0.8) return (false, $"голова двигается (разброс {spread:0.0}°) - подстройка отложена");

        var eye = ReadConfig()["eye"]?.GetValue<string>() ?? "left";
        var gray = WindowProbe.GrabSquare($"Quest3-{eye}", 512);
        if (gray == null) return (false, "окно каста не отвечает - картинки нет");

        var python = ResolvePython();
        if (python == null) return (false, "python не найден: подстройка по картинке выключена");
        var level = Path.Combine(CastHome, "level.py");
        if (!File.Exists(level)) return (false, $"level.py отсутствует: {level}");

        var rawPath = Path.Combine(StateDir, "trim.raw");
        try
        {
            File.WriteAllBytes(rawPath, gray);
        }
        catch (Exception ex)
        {
            return (false, $"кадр не записался: {ex.Message}");
        }

        var (roll, conf) = await RunLevelAsync(python, level, rawPath);
        if (double.IsNaN(roll)) return (false, "замер остатка не удался");
        TrimResidual = roll;

        if (conf < 0.30) return (false, $"мало прямых линий (уверенность {conf:0.00}) - наведите на стену или стол");
        if (Math.Abs(roll) < 0.3) return (true, $"уже ровно (остаток {roll:+0.0;-0.0}°)");
        if (Math.Abs(roll) > 12) return (false, $"остаток {roll:0.0}° слишком велик - нужна КАЛИБРОВКА");

        _settings.TiltBaseDeg = Math.Round((_settings.TiltBaseDeg - roll) * 4) / 4;
        _settings.Save();
        _lastAppliedDeg = double.NaN;                 // let the forced apply through
        await ApplyDegAsync(_settings.TiltBaseDeg);
        return (true, $"база сдвинута на {-roll:+0.0;-0.0}° (остаток был {roll:+0.0;-0.0}°, уверенность {conf:0.00})");
    }

    private static async Task<(double roll, double conf)> RunLevelAsync(string python, string level, string raw)
    {
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo(python, $"\"{level}\" \"{raw}\" 512 512 --crop 0.10")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var p = System.Diagnostics.Process.Start(psi);
            if (p == null) return (double.NaN, 0);
            var outTask = p.StandardOutput.ReadToEndAsync();
            var errTask = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(20000))
            {
                try { p.Kill(true); } catch { }
                return (double.NaN, 0);
            }
            var text = await outTask;
            var err = await errTask;
            var m = System.Text.RegularExpressions.Regex.Match(
                text, @"roll=(-?\d+(?:\.\d+)?)\s+confidence=(\d+(?:\.\d+)?)");
            if (!m.Success)
            {
                ELog($"trim: level.py вернул '{text.Trim()}' {err.Trim()}");
                return (double.NaN, 0);
            }
            var inv = System.Globalization.CultureInfo.InvariantCulture;
            return (double.Parse(m.Groups[1].Value, inv), double.Parse(m.Groups[2].Value, inv));
        }
        catch (Exception ex)
        {
            ELog($"trim: level.py упал ({ex.GetType().Name}: {ex.Message})");
            return (double.NaN, 0);
        }
    }

    private string? ResolvePython()
    {
        var fromCfg = ReadConfig()["pythonPath"]?.GetValue<string>();
        if (!string.IsNullOrWhiteSpace(fromCfg) && File.Exists(fromCfg)) return fromCfg;
        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in path.Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(dir)) continue;
            var clean = dir.Trim();
            // the Microsoft Store alias lives in ...\WindowsApps and does nothing but
            // open the store page when spawned - skip it or trim silently "fails"
            if (clean.Contains("WindowsApps", StringComparison.OrdinalIgnoreCase)) continue;
            var exe = Path.Combine(clean, "python.exe");
            if (File.Exists(exe)) return exe;
        }
        return null;
    }

    private string WriteLiveShader(double deg)
    {
        // a NaN/inf angle would reach GLSL as `nan` and the shader would stop compiling,
        // leaving the player with a black frame - never hand it over
        if (!double.IsFinite(deg)) deg = 0;

        var cfg = ReadConfig();
        var k1 = cfg["lensK1"]?.GetValue<double>() ?? -0.4;
        var k2 = cfg["lensK2"]?.GetValue<double>() ?? 0;
        var lens = cfg["lens"]?.GetValue<bool>() ?? true;
        if (!lens) { k1 = 0; k2 = 0; }

        var tplPath = Path.Combine(CastHome, "lens-template.glsl");
        var tpl = File.ReadAllText(tplPath);
        var inv = System.Globalization.CultureInfo.InvariantCulture;
        var ang = (deg * Math.PI / 180.0).ToString("0.000000", inv);
        var src = tpl
            .Replace("@K1@", k1.ToString("0.####", inv))
            .Replace("@K2@", k2.ToString("0.####", inv))
            .Replace("@ANGLE@", ang)
            .Replace("@GUIDE@", "0")
            .Replace("@GUIDEANG@", "0.0");

        var outPath = Path.Combine(StateDir, "lens-live.glsl");
        File.WriteAllText(outPath, src);
        return outPath;
    }

    private static void ELog(string s)
    {
        var line = $"{DateTime.Now:HH:mm:ss} {s}{Environment.NewLine}";
        foreach (var dir in new[]
        {
            AppContext.BaseDirectory,
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QuestCast"),
        })
        {
            try
            {
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "engine.log"), line);
            }
            catch { }
        }
    }

    private async Task<(int code, string output)> RunAsync(string[] args, int timeoutMs)
    {
        await _gate.WaitAsync();
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe"),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = System.Text.Encoding.UTF8,
                StandardErrorEncoding = System.Text.Encoding.UTF8,
            };
            psi.ArgumentList.Add("-NoProfile");
            psi.ArgumentList.Add("-ExecutionPolicy");
            psi.ArgumentList.Add("Bypass");
            psi.ArgumentList.Add("-File");
            psi.ArgumentList.Add(ScriptPath);
            foreach (var a in args) psi.ArgumentList.Add(a);

            using var p = Process.Start(psi)!;
            ELog($"run {string.Join(' ', args)} script={ScriptPath} localappdata={Environment.GetEnvironmentVariable("LOCALAPPDATA")}");
            var stdout = p.StandardOutput.ReadToEndAsync();
            var stderr = p.StandardError.ReadToEndAsync();
            var exit = p.WaitForExitAsync();
            if (await Task.WhenAny(exit, Task.Delay(timeoutMs)) != exit)
            {
                try { p.Kill(true); } catch { }
                ELog("timeout");
                return (1, $"timeout after {timeoutMs / 1000}s");
            }
            await exit;
            var text = (await stdout) + (await stderr);
            ELog($"exit={p.ExitCode} out={text.Replace("\r", "").Replace("\n", " | ")}");
            return (p.ExitCode, text);
        }
        catch (Exception ex)
        {
            return (1, ex.Message);
        }
        finally
        {
            _gate.Release();
        }
    }

    // ----------------------------------------------------------------- state

    public async Task<CastState> ReadStateAsync()
    {
        var cfg = ReadConfig();
        var eye = cfg["eye"]?.GetValue<string>() ?? "left";
        var mic = (cfg["audio"]?.GetValue<string>() ?? "none") == "mic";
        var lens = cfg["lens"]?.GetValue<bool>() ?? true;
        var tilt = cfg["rotateDeg"]?.GetValue<double>() ?? 0;
        var ip = cfg["ip"]?.GetValue<string>() ?? "";
        var port = cfg["port"]?.GetValue<int>() ?? 5555;

        var daemonPid = ReadPid("daemon.pid");
        var pipelinePid = ReadPid("scrcpy.pid");

        var player = "mpv";
        var restarts = 0;
        string daemonUp = "", pipelineUp = "";
        string? runtimeAudio = null;
        try
        {
            var rtPath = Path.Combine(StateDir, "runtime.json");
            if (File.Exists(rtPath))
            {
                var rt = JsonNode.Parse(File.ReadAllText(rtPath))!;
                player = rt["player"]?.GetValue<string>() ?? player;
                restarts = rt["restarts"]?.GetValue<int>() ?? 0;
                runtimeAudio = rt["audio"]?.GetValue<string>();
                if (rt["daemonSince"] is JsonNode ds && DateTime.TryParse(ds.GetValue<string>(), out var d))
                    daemonUp = FormatSpan(DateTime.Now - d.ToLocalTime());
                if (rt["pipelineSince"] is JsonNode ps && DateTime.TryParse(ps.GetValue<string>(), out var pdt))
                    pipelineUp = FormatSpan(DateTime.Now - pdt.ToLocalTime());
            }
        }
        catch { }

        // the microphone indicator must show what is REALLY being captured, so the
        // daemon's runtime state wins over config.json until the next restart
        if (runtimeAudio is not null) mic = runtimeAudio == "mic";

        var fps = 0;
        var mbps = 0.0;
        try
        {
            var statsPath = Path.Combine(StateDir, "stats.json");
            if (File.Exists(statsPath))
            {
                var st = JsonNode.Parse(File.ReadAllText(statsPath))!;
                var ts = st["ts"]?.GetValue<string>();
                if (ts is not null && DateTime.TryParse(ts, out var when) && (DateTime.Now - when.ToLocalTime()).TotalSeconds < 4)
                {
                    fps = (int)Math.Round(st["fps"]?.GetValue<double>() ?? 0);
                    mbps = Math.Round(st["mbps"]?.GetValue<double>() ?? 0, 1);
                }
            }
        }
        catch { }

        var device = await GetDeviceAsync(ip, port);

        return new CastState
        {
            DaemonRunning = IsAlive(daemonPid),
            PipelineRunning = IsAlive(pipelinePid),
            Device = device,
            Eye = eye,
            Mic = mic,
            Lens = lens,
            Tilt = tilt,
            Fps = fps,
            Mbps = mbps,
            Player = player,
            Restarts = restarts,
            DaemonUp = daemonUp,
            PipelineUp = pipelineUp,
            LogTail = ReadLogTail(12),
            Guide = _settings.Guide,
            ImuRoll = LastRoll,
            AutoLevel = _settings.AutoLevel,
            TrimResidual = TrimResidual,
        };
    }

    private string ReadLogTail(int lines)
    {
        try
        {
            if (!File.Exists(LogPath)) return "";
            using var fs = new FileStream(LogPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var sr = new StreamReader(fs);
            var all = sr.ReadToEnd().Split('\n', StringSplitOptions.RemoveEmptyEntries);
            return string.Join('\n', all.TakeLast(lines));
        }
        catch { return ""; }
    }

    private static string FormatSpan(TimeSpan span) =>
        span.TotalHours >= 1 ? $"{(int)span.TotalHours:00}:{span.Minutes:00}:{span.Seconds:00}"
                              : $"{span.Minutes:00}:{span.Seconds:00}";

    private int ReadPid(string name)
    {
        try
        {
            // must follow StateDir: when the engine is pointed at an alternative state
            // directory the pid files are there, and reading the default one made the
            // GUI report "остановлен" while the pipeline was happily running
            var p = Path.Combine(StateDir, name);
            if (!File.Exists(p)) return 0;
            return int.TryParse(File.ReadAllText(p).Trim(), out var id) ? id : 0;
        }
        catch { return 0; }
    }

    private static bool IsAlive(int pid)
    {
        if (pid <= 0) return false;
        try
        {
            using var p = Process.GetProcessById(pid);
            return !p.HasExited;
        }
        catch { return false; }
    }

    // ---------------------------------------------------------------- device

    private async Task<string> GetDeviceAsync(string ip, int port)
    {
        if ((DateTime.Now - _deviceAt).TotalSeconds < 5) return _device;
        _deviceAt = DateTime.Now;
        if (string.IsNullOrEmpty(ip)) return _device;

        var adb = FindAdb();
        if (adb is null) return _device = "adb not found";
        try
        {
            var psi = new ProcessStartInfo(adb)
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            };
            psi.ArgumentList.Add("-s");
            psi.ArgumentList.Add($"{ip}:{port}");
            psi.ArgumentList.Add("get-state");
            using var p = Process.Start(psi)!;
            var outTask = p.StandardOutput.ReadToEndAsync();
            var errTask = p.StandardError.ReadToEndAsync();
            var done = await Task.WhenAny(p.WaitForExitAsync(), Task.Delay(3000));
            if (!p.HasExited)
            {
                try { p.Kill(true); } catch { }
                return _device = "no answer";
            }
            var text = ((await outTask) + (await errTask)).Trim().Split('\n')[0].Trim();
            return _device = string.IsNullOrEmpty(text) ? "offline" : text;
        }
        catch (Exception ex)
        {
            return _device = ex.GetType().Name;
        }
    }

    private string? FindAdb()
    {
        if (_adbPath is not null) return _adbPath.Length == 0 ? null : _adbPath;

        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var candidate = Path.Combine(dir, "adb.exe");
                if (File.Exists(candidate)) return _adbPath = candidate;
            }
            catch { }
        }

        // winget keeps adb out of PATH until the shell is restarted
        try
        {
            var winget = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Microsoft", "WinGet", "Packages");
            if (Directory.Exists(winget))
            {
                foreach (var hit in Directory.EnumerateFiles(winget, "adb.exe", SearchOption.AllDirectories))
                {
                    return _adbPath = hit;
                }
            }
        }
        catch { }

        _adbPath = "";
        return null;
    }

    public string ConfigIp =>
        (ReadConfig()["ip"]?.GetValue<string>() ?? "") + ":" + (ReadConfig()["port"]?.GetValue<int>() ?? 5555);
}
