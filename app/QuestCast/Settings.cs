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

    private static string Dir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "QuestCast");

    private static string FilePath => Path.Combine(Dir, "settings.json");

    /// <summary>Fallback used when the profile folder is not writable for this process.</summary>
    private static string FallbackPath
    {
        get
        {
            var state = Environment.GetEnvironmentVariable("QUEST3CAST_STATE");
            var dir = string.IsNullOrWhiteSpace(state)
                ? Path.Combine(AppContext.BaseDirectory, "state")
                : state;
            return Path.Combine(dir, "settings.json");
        }
    }

    private static IEnumerable<string> Candidates()
    {
        // the state folder is tried first: when the profile copy is not writable the
        // newer settings live there, and an older %APPDATA% file must not shadow them
        yield return FallbackPath;
        yield return FilePath;
    }

    public static Settings Load()
    {
        foreach (var path in Candidates())
        {
            try
            {
                if (!File.Exists(path)) continue;
                var s = JsonSerializer.Deserialize<Settings>(File.ReadAllText(path));
                if (s is null) continue;
                if (string.IsNullOrWhiteSpace(s.Token)) s.Token = NewToken();
                if (s.Port is < 1024 or > 65535) s.Port = 47801;
                return s;
            }
            catch
            {
                // a broken settings file must never block the app: try the next one
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
            catch
            {
                // the profile folder is denied for a process started from a sandboxed
                // parent; fall through to the state folder, which is writable
            }
        }
    }

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
