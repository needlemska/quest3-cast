using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace QuestCast;

/// <summary>Per-user settings of the control app (never the cast config itself).</summary>
public sealed class Settings
{
    public int Port { get; set; } = 47801;
    public string Token { get; set; } = "";
    public bool StartMinimized { get; set; }

    /// <summary>Folder holding quest3-cast.ps1; auto-detected on first run.</summary>
    public string CastHome { get; set; } = "";

    /// <summary>Live horizon levelling from the headset IMU streamed by the client.</summary>
    public bool AutoLevel { get; set; }

    /// <summary>Tilt (deg) that was active when the base roll was captured.</summary>
    public double TiltBaseDeg { get; set; }

    /// <summary>IMU roll (deg) captured at the same moment as TiltBaseDeg.</summary>
    public double TiltBaseRoll { get; set; }

    /// <summary>+1 / -1: the IMU axis may point the other way, so the user can flip it.</summary>
    public int TiltSign { get; set; } = 1;

    /// <summary>
    /// How many degrees of picture rotation one degree of measured head roll actually
    /// produces. It is not 1.0: the panel is composited on a curved surface, the lens
    /// correction is not an exact inverse of the pre-distortion, and the IMU axes are
    /// not the panel axes. Everything together behaves as an unknown gain, which is
    /// exactly the "крен остаётся" symptom; the value is fitted from tiltlog.csv.
    /// </summary>
    public double TiltGain { get; set; } = 1.0;

    /// <summary>Experimental optical trim (needs python + a still picture).</summary>
    public bool TrimEnabled { get; set; }

    /// <summary>Alignment line over the streamed picture (the headset draws its twin).</summary>
    public bool Guide { get; set; }

    private static string Dir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QuestCast");

    private static string FilePath => Path.Combine(Dir, "settings.json");

    /// <summary>
    /// Fallbacks for the case when the profile copy is not writable for this process.
    /// A scheduled task started "without stored password" gets a restricted token that
    /// is denied on %APPDATA%\QuestCast, so the app has to live somewhere else - and
    /// that somewhere must not be the build output, which a rebuild wipes.
    /// </summary>
    private static string MidPath
    {
        get
        {
            var state = Environment.GetEnvironmentVariable("QUEST3CAST_STATE");
            if (!string.IsNullOrWhiteSpace(state)) return Path.Combine(state, "settings.json");
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(local, "QuestCast", "state", "settings.json");
        }
    }

    private static string FallbackPath => Path.Combine(AppContext.BaseDirectory, "state", "settings.json");

    private static IEnumerable<string> Candidates()
    {
        // the profile copy is the real home: it survives a rebuild and a clean, and it
        // is where a user looks for it. The others are fallbacks, in order of how
        // likely they are to survive the next build.
        yield return FilePath;
        yield return MidPath;
        yield return FallbackPath;
    }

    public static Settings Load()
    {
        // newest wins: when the fallback was in use for a while, its file is newer than
        // the profile one, and a plain "first existing" would silently roll the
        // settings - and the token - back to an older copy
        string? best = null;
        var bestAt = DateTime.MinValue;
        foreach (var path in Candidates())
        {
            try
            {
                if (!File.Exists(path)) continue;
                var at = File.GetLastWriteTimeUtc(path);
                if (at > bestAt) { bestAt = at; best = path; }
            }
            catch
            {
                // unreadable timestamp: just try the next candidate
            }
        }

        if (best is not null)
        {
            try
            {
                var s = JsonSerializer.Deserialize<Settings>(File.ReadAllText(best));
                if (s is not null)
                {
                    if (string.IsNullOrWhiteSpace(s.Token)) s.Token = NewToken();
                    if (s.Port is < 1024 or > 65535) s.Port = 47801;
                    // loaded from the fallback while the profile is writable again:
                    // copy it back so the next rebuild does not lose these settings
                    if (!string.Equals(best, FilePath, StringComparison.OrdinalIgnoreCase)) s.Save();
                    return s;
                }
            }
            catch
            {
                // a broken settings file must never block the app: fall through
            }
        }

        var fresh = new Settings { Token = NewToken() };
        fresh.Save();
        return fresh;
    }

    public void Save()
    {
        var json = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
        foreach (var path in Candidates())
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path, json);
                return;
            }
            catch (Exception ex)
            {
                // the profile folder is denied for a process started from a sandboxed
                // parent; fall through to the state folder, which is writable.
                // The reason is recorded: swallowing it silently once hid a real
                // failure and made settings look like they were saving fine.
                LastSaveError = $"{path}: {ex.GetType().Name}: {ex.Message}";
                try
                {
                    var log = Path.Combine(Path.GetTempPath(), "questcast-settings.log");
                    File.AppendAllText(log, $"{DateTime.Now:HH:mm:ss} {LastSaveError}{Environment.NewLine}");
                }
                catch { }
            }
        }
    }

    /// <summary>Diagnostics of the last failed write, shown by the GUI when needed.</summary>
    public static string LastSaveError { get; private set; } = "";

    public static string NewToken()
    {
        // no 0/O/1/I: the token is typed by hand on the headset
        const string alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        var rnd = Random.Shared;
        var chars = new char[8];
        for (var i = 0; i < chars.Length; i++) chars[i] = alphabet[rnd.Next(alphabet.Length)];
        return new string(chars);
    }
}
