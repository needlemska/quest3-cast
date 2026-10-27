using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace QuestCast;

/// <summary>
/// LAN control channel for the Android client: one TCP port, newline-delimited
/// JSON, token handshake, server pushes state once per second.
/// </summary>
public sealed class ControlServer : IAsyncDisposable
{
    private readonly int _port;
    private readonly string _token;
    private readonly CastEngine _engine;
    private readonly Action<string> _log;
    private readonly ConcurrentDictionary<int, ConnectedClient> _clients = new();
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;
    private int _nextClientId;

    private sealed class ConnectedClient
    {
        public required TcpClient Tcp { get; init; }
        public required StreamWriter Out { get; init; }
        public bool Authed { get; set; }
        public required object WriteLock { get; init; }
    }

    public ControlServer(int port, string token, CastEngine engine, Action<string> log)
    {
        _port = port;
        _token = token;
        _engine = engine;
        _log = log;
    }

    public int ClientCount => _clients.Count;

    public IReadOnlyList<string> ListenAddresses()
    {
        var result = new List<string>();
        try
        {
            foreach (var ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                if (ni.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback) continue;
                foreach (var ua in ni.GetIPProperties().UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                    result.Add($"{ua.Address}:{_port}");
                }
            }
        }
        catch { }
        return result;
    }

    public void Start()
    {
        _cts = new CancellationTokenSource();
        _listener = new TcpListener(IPAddress.Any, _port);
        // a previous instance that was killed leaves the port in TIME_WAIT; without
        // reuse the GUI came up but its server silently never bound
        _listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        _listener.Start();
        _ = AcceptLoopAsync(_cts.Token);
        _ = StatePumpAsync(_cts.Token);
        _log($"LAN server listening on port {_port}");
    }

    private async Task AcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient tcp;
            try
            {
                tcp = await _listener!.AcceptTcpClientAsync(ct);
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex)
            {
                _log($"accept failed: {ex.Message}");
                await Task.Delay(500, CancellationToken.None);
                continue;
            }

            _ = HandleClientAsync(tcp, ct);
        }
    }

    private async Task HandleClientAsync(TcpClient tcp, CancellationToken ct)
    {
        var id = Interlocked.Increment(ref _nextClientId);
        var remote = tcp.Client.RemoteEndPoint?.ToString() ?? "?";
        var stream = tcp.GetStream();
        var reader = new StreamReader(stream, new UTF8Encoding(false));
        var writer = new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
        var client = new ConnectedClient { Tcp = tcp, Out = writer, WriteLock = new object() };
        _clients[id] = client;

        Send(client, new JsonObject { ["type"] = "hello", ["need"] = "token", ["app"] = "QuestCast", ["proto"] = 1 });
        _log($"client #{id} connected from {remote}");

        try
        {
            while (!ct.IsCancellationRequested && tcp.Connected)
            {
                var line = await reader.ReadLineAsync(ct);
                if (line is null) break;
                if (string.IsNullOrWhiteSpace(line)) continue;
                await HandleMessageAsync(client, id, line);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { _log($"client #{id}: {ex.Message}"); }
        finally
        {
            _clients.TryRemove(id, out _);
            try { tcp.Close(); } catch { }
            _log($"client #{id} disconnected");
        }
    }

    private async Task HandleMessageAsync(ConnectedClient client, int id, string line)
    {
        JsonObject? msg;
        try { msg = JsonNode.Parse(line) as JsonObject; }
        catch { Send(client, Err("bad json")); return; }
        if (msg is null) { Send(client, Err("bad json")); return; }

        var type = msg["type"]?.GetValue<string>() ?? "";

        if (type == "auth")
        {
            var token = msg["token"]?.GetValue<string>() ?? "";
            client.Authed = string.Equals(token, _token, StringComparison.OrdinalIgnoreCase);
            Send(client, new JsonObject { ["type"] = "auth", ["ok"] = client.Authed });
            if (client.Authed) await PushStateAsync(client);
            else _log($"client #{id}: wrong token");
            return;
        }

        if (!client.Authed)
        {
            Send(client, Err("auth required"));
            return;
        }

        if (type == "tilt")
        {
            // the client pushes IMU roll/pitch a few times per second; no ack, it
            // would double the traffic and the client ignores it anyway
            try
            {
                var roll = msg["roll"]?.GetValue<double>() ?? 0;
                var pitch = msg["pitch"]?.GetValue<double>() ?? 0;
                _engine.SubmitTilt(roll, pitch);
            }
            catch { }
            return;
        }

        if (type != "cmd") { Send(client, Err("unknown message type")); return; }

        try
        {
            await DispatchAsync(client, id, msg);
        }
        catch (Exception ex)
        {
            // a malformed value used to kill the connection silently, so the client sat
            // on an empty answer; answer with an error and keep the socket open
            Send(client, Err($"bad value: {ex.GetType().Name}: {ex.Message}"));
        }
    }

    private static bool AsBool(JsonNode? node, bool fallback)
    {
        if (node is null) return fallback;
        try
        {
            if (node is JsonValue v)
            {
                if (v.TryGetValue<bool>(out var b)) return b;
                if (v.TryGetValue<string>(out var s))
                {
                    if (string.Equals(s, "true", StringComparison.OrdinalIgnoreCase)) return true;
                    if (string.Equals(s, "false", StringComparison.OrdinalIgnoreCase)) return false;
                }
                if (v.TryGetValue<int>(out var i)) return i != 0;
            }
        }
        catch { }
        return fallback;
    }

    private async Task DispatchAsync(ConnectedClient client, int id, JsonObject msg)
    {
        var cmd = msg["cmd"]?.GetValue<string>() ?? "";
        var value = msg["value"];
        (bool ok, string text) result;

        switch (cmd)
        {
            case "start":
                result = await _engine.StartAsync();
                break;
            case "stop":
                result = await _engine.StopAsync();
                break;
            case "restart":
                result = await _engine.RestartAsync();
                break;
            case "eye":
            {
                var eye = value?.GetValue<string>() ?? "left";
                if (eye is not ("left" or "right" or "both")) { Send(client, Err("eye must be left|right|both")); return; }
                result = await _engine.ApplyAndRestartAsync("eye", eye);
                break;
            }
            case "mic":
            {
                var on = AsBool(value, false);
                result = await _engine.ApplyAndRestartAsync("audio", on ? "mic" : "none");
                break;
            }
            case "lens":
            {
                var on = AsBool(value, true);
                result = await _engine.ApplyAndRestartAsync("lens", on);
                break;
            }
            case "calibrate":
            {
                double? deg = value is null ? null : value.GetValue<double>();
                result = await _engine.CalibrateAsync(deg);
                break;
            }
            case "autolevel":
            {
                result = _engine.SetAutoLevel(AsBool(value, true));
                break;
            }
            case "tiltsign":
            {
                result = _engine.SetTiltSign(AsBool(value, true));
                break;
            }
            case "state":
                result = (true, "ok");
                break;
            default:
                Send(client, Err($"unknown cmd '{cmd}'"));
                return;
        }

        Send(client, new JsonObject
        {
            ["type"] = "ack",
            ["cmd"] = cmd,
            ["ok"] = result.ok,
            ["message"] = Shorten(result.text)
        });
        _log($"client #{id} cmd {cmd} -> {(result.ok ? "ok" : "failed")}");
        await PushStateAsync(client);
    }

    private static string Shorten(string text)
    {
        var first = text.Split('\n', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? "";
        first = first.Trim();
        return first.Length > 160 ? first[..160] : first;
    }

    private async Task StatePumpAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(1000, ct);
                if (_clients.IsEmpty) continue;
                CastState state;
                try { state = await _engine.ReadStateAsync(); }
                catch { continue; }
                foreach (var client in _clients.Values)
                {
                    if (client.Authed) await PushStateAsync(client, state);
                }
            }
            catch (OperationCanceledException) { return; }
            catch { }
        }
    }

    private async Task PushStateAsync(ConnectedClient client, CastState? known = null)
    {
        var state = known ?? await _engine.ReadStateAsync();
        Send(client, new JsonObject { ["type"] = "state", ["state"] = ToJson(state) });
    }

    public static JsonObject ToJson(CastState s) => new()
    {
        ["daemon"] = s.DaemonRunning,
        ["pipeline"] = s.PipelineRunning,
        ["running"] = s.Running,
        ["device"] = s.Device,
        ["eye"] = s.Eye,
        ["mic"] = s.Mic,
        ["lens"] = s.Lens,
        ["tilt"] = Math.Round(s.Tilt, 1),
        ["fps"] = s.Fps,
        ["mbps"] = s.Mbps,
        ["player"] = s.Player,
        ["restarts"] = s.Restarts,
        ["daemonUp"] = s.DaemonUp,
        ["pipelineUp"] = s.PipelineUp
    };

    private static JsonObject Err(string message) => new() { ["type"] = "error", ["message"] = message };

    private void Send(ConnectedClient client, JsonObject payload)
    {
        try
        {
            lock (client.WriteLock)
            {
                client.Out.WriteLine(payload.ToJsonString(new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
            }
        }
        catch
        {
            try { client.Tcp.Close(); } catch { }
        }
    }

    public async ValueTask DisposeAsync()
    {
        _cts?.Cancel();
        try { _listener?.Stop(); } catch { }
        await Task.CompletedTask;
    }
}
