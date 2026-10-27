using System.IO;
using System.Windows;
using System.Windows.Threading;

namespace QuestCast;

public partial class App : Application
{
    private static string CrashLog => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "quest3-cast", "gui-error.log");

    private static int _logging;

    /// <summary>
    /// The engine keeps pid/heartbeat/runtime files in %LOCALAPPDATA%\quest3-cast.
    /// A caller that is itself restricted (a sandboxed launcher, a policy-managed
    /// desktop) cannot write there, and every command then dies with
    /// "PermissionDenied: daemon.pid". Probe the default once and switch the engine
    /// to a state directory under %APPDATA%\QuestCast that this process can write.
    /// </summary>
    private static void EnsureWritableStateDir()
    {
        if (Environment.GetEnvironmentVariable("QUEST3CAST_STATE") is { Length: > 0 }) return;

        // pick the first state directory this process can actually write; a launcher
        // that runs the GUI in a restricted job leaves %LOCALAPPDATA% read-only, and
        // the engine child inherits that, so probing once here is what keeps the
        // whole command chain alive
        var candidates = new[]
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "quest3-cast"),
            CastEngine.StateOverride,
            Path.Combine(Path.GetTempPath(), "quest3-cast"),
        };
        var report = new List<string>();
        foreach (var dir in candidates)
        {
            try
            {
                Directory.CreateDirectory(dir);
                var probe = Path.Combine(dir, ".write-probe");
                File.WriteAllText(probe, "x");
                File.Delete(probe);
                report.Add($"OK   {dir}");
                if (!string.Equals(dir, candidates[0], StringComparison.OrdinalIgnoreCase))
                    Environment.SetEnvironmentVariable("QUEST3CAST_STATE", dir);
                WriteProbeReport(report);
                return;
            }
            catch (Exception ex)
            {
                report.Add($"FAIL {dir} :: {ex.GetType().Name}: {ex.Message}");
            }
        }
        WriteProbeReport(report);
    }

    private static void WriteProbeReport(List<string> lines)
    {
        try
        {
            File.AppendAllText(Path.Combine(AppContext.BaseDirectory, "startup-probe.txt"),
                $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}{Environment.NewLine}{string.Join(Environment.NewLine, lines)}{Environment.NewLine}{Environment.NewLine}");
        }
        catch { }
    }

    private static void LogFatal(string where, Exception ex)
    {
        // a second exception raised while writing the log must not re-enter here:
        // a FirstChanceException hook plus AppendAllText used to recurse until the
        // stack overflowed (crash code 0xc00000fd)
        if (Interlocked.Exchange(ref _logging, 1) == 1) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(CrashLog)!);
            File.AppendAllText(CrashLog,
                $"{DateTime.Now:yyyy-MM-dd HH:mm:ss}  {where}: {ex.GetType().Name}: {ex.Message}{Environment.NewLine}{ex.StackTrace}{Environment.NewLine}");
        }
        catch { }
        finally { Interlocked.Exchange(ref _logging, 0); }
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        DispatcherUnhandledException += (_, args) =>
        {
            LogFatal("dispatcher", args.Exception);
            MessageBox.Show($"Ошибка: {args.Exception.Message}\n\nПодробности: {CrashLog}",
                "Quest Cast", MessageBoxButton.OK, MessageBoxImage.Error);
            args.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += (_, args) =>
        {
            if (args.ExceptionObject is Exception ex) LogFatal("appdomain", ex);
        };
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            LogFatal("task", args.Exception);
            args.SetObserved();
        };
        // NOTE: do NOT log FirstChanceException here. It fires for every exception
        // in the process - including the ArgumentException that Process.GetProcessById
        // throws twice a second for an exited pid - and logging inside it re-entered
        // the handler until the stack overflowed.

        try
        {
            EnsureWritableStateDir();

            var cfg = Settings.Load();
            var engineHome = new CastEngine(cfg).CastHome;
            if (!string.Equals(cfg.CastHome, engineHome, StringComparison.OrdinalIgnoreCase))
            {
                cfg.CastHome = engineHome;
                cfg.Save();
            }

            var win = new MainWindow(cfg);
            if (cfg.StartMinimized) win.WindowState = WindowState.Minimized;
            win.Show();
        }
        catch (Exception ex)
        {
            LogFatal("startup", ex);
            MessageBox.Show($"Не удалось запустить Quest Cast:\n{ex.Message}\n\nПодробности: {CrashLog}",
                "Quest Cast", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }
}
