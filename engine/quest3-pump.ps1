#requires -Version 5.1
<#
  Quest 3 cast - lens-corrected video pump.

  scrcpy cannot render post-processed frames itself, so the chain is:

      scrcpy --no-window --record=\\.\pipe\<name>   (mkv over a named pipe)
              |  this script (copies the pipe into the player's stdin)
              v
      mpv    --hwdec=d3d11va --glsl-shaders=<lens.glsl> -      (GPU decode + GPU warp)
      ffplay -f matroska -i pipe:0 -vf lenscorrection=...,showinfo   (fallback, CPU only)

  Besides moving bytes it measures the stream for the HUD. ffplay is tapped for
  showinfo lines (one per decoded frame), mpv for its `STAT fps=` status line, so
  stats.json carries the real display rate either way.

  Started and supervised by quest3-cast.ps1; reads its job from a JSON plan file.
#>
param([Parameter(Mandatory)][string]$PlanPath)

$ErrorActionPreference = 'Stop'

$job = Get-Content $PlanPath -Raw | ConvertFrom-Json

Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;

public class CastPlayer {
    private Process p;
    private static readonly Regex FrameRe = new Regex(@"\[Parsed_showinfo_\d+ @ [0-9a-f]+\][^\r\n]*\bn:\s*\d+");
    // no \b: mpv prints "STAT_fps=60.2" and '_' is a word character
    private static readonly Regex FpsRe = new Regex(@"fps=([0-9]+(?:\.[0-9]+)?)");
    private long frames;
    private double lastFps;

    public long Frames { get { return Interlocked.Read(ref frames); } }
    public double LastFps { get { return Volatile.Read(ref lastFps); } }
    public bool HasExited { get { try { return p.HasExited; } catch { return true; } } }
    public Stream Input { get { return p.StandardInput.BaseStream; } }

    public void Start(string exe, string args) {
        var psi = new ProcessStartInfo(exe, args);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardInput = true;
        // ffplay reports every decoded frame on stderr (showinfo), mpv prints
        // "STAT fps=" lines on stdout, so both streams are tapped
        psi.RedirectStandardError = true;
        psi.RedirectStandardOutput = true;
        p = new Process();
        p.StartInfo = psi;
        p.ErrorDataReceived += OnLine;
        p.OutputDataReceived += OnLine;
        p.Start();
        p.BeginErrorReadLine();
        p.BeginOutputReadLine();
    }

    private void OnLine(object sender, DataReceivedEventArgs e) {
        if (e.Data == null) return;
        if (FrameRe.IsMatch(e.Data)) { Interlocked.Increment(ref frames); return; }
        var m = FpsRe.Match(e.Data);
        if (m.Success) {
            double v;
            if (double.TryParse(m.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out v))
                Volatile.Write(ref lastFps, v);
        }
    }

    public void CloseInput() { try { p.StandardInput.BaseStream.Close(); } catch { } }
    public void WaitExit(int ms) { try { p.WaitForExit(ms); } catch { } }
    public void Kill() { try { if (!p.HasExited) p.Kill(); } catch { } }
}
"@

function Quote([string]$Value) {
    if ($Value -match '\s') { return '"' + $Value + '"' }
    return $Value
}

$pipe = New-Object System.IO.Pipes.NamedPipeServerStream(
    $job.pipeName,
    [System.IO.Pipes.PipeDirection]::In,
    1,
    [System.IO.Pipes.PipeTransmissionMode]::Byte,
    [System.IO.Pipes.PipeOptions]::Asynchronous)
$waitTask = $pipe.WaitForConnectionAsync()

$player = New-Object CastPlayer
$player.Start($job.playerExe, (($job.playerArgs | ForEach-Object { Quote $_ }) -join ' '))

$sc = Start-Process -FilePath $job.scrcpy -ArgumentList $job.scrcpyArgs -PassThru `
    -RedirectStandardError $job.scrcpyErr -WindowStyle Hidden

$prevFrames = [int64]0

function Write-Stats {
    param([double]$Seconds, [int64]$Bytes, [int64]$Frames)

    $fps = 0.0; $mbps = 0.0
    if ($Seconds -gt 0.2) {
        # mpv reports the real display rate; ffplay only gives us a frame count
        if ($player.LastFps -gt 0) { $fps = [math]::Round($player.LastFps, 0) }
        else { $fps = [math]::Round(($Frames - $script:prevFrames) / $Seconds, 0) }
        $mbps = [math]::Round(($Bytes * 8) / $Seconds / 1MB, 2)
    }
    $script:prevFrames = $Frames

    if (-not $job.statsPath) { return }
    $payload = [ordered]@{
        fps    = $fps
        mbps   = $mbps
        frames = $Frames
        ts     = (Get-Date).ToString('o')
    } | ConvertTo-Json -Compress
    # write-then-rename: the HUD reads this file twice a second and used to catch
    # half-written JSON, which made the numbers blink to "--"
    $tmp = "$($job.statsPath).tmp"
    try {
        Set-Content -Path $tmp -Value $payload -Encoding UTF8
        Move-Item -Path $tmp -Destination $job.statsPath -Force -ErrorAction Stop
    }
    catch { }
}

try {
    if (-not $waitTask.Wait([int]$job.connectTimeoutMs)) {
        throw 'scrcpy never connected to the named pipe'
    }

    $lastTilt = [datetime]::MinValue

    # The GUI regenerates the lens shader and drops its path here; the pipe to mpv
    # stays with us because the GUI runs under a token that cannot open it.
    function Apply-Shader([string]$Path) {
        if (-not $Path -or -not (Test-Path $Path)) { return }
        try {
            $pc = New-Object System.IO.Pipes.NamedPipeClientStream('.', 'quest3cast-ipc', [System.IO.Pipes.PipeDirection]::InOut)
            $pc.Connect(1200)
            $sw = New-Object System.IO.StreamWriter($pc)
            $sw.AutoFlush = $true
            $sw.WriteLine('{"command":["change-list","glsl-shaders","clr",""]}')
            $sw.WriteLine((@{ command = @('change-list','glsl-shaders','append', $Path) } | ConvertTo-Json -Compress))
            $sw.Dispose()
            $pc.Dispose()
        }
        catch { }
    }

    $buffer = New-Object byte[] 65536
    $stream = $player.Input
    $readTask = $null
    $windowStart = Get-Date
    $windowBytes = [int64]0

    while ($true) {
        if ($null -eq $readTask) { $readTask = $pipe.ReadAsync($buffer, 0, $buffer.Length) }

        if ($readTask.Wait(500)) {
            $count = $readTask.Result
            if ($count -le 0) { break }
            $stream.Write($buffer, 0, $count)
            $stream.Flush()
            $windowBytes += $count
            $readTask = $null
        }

        $elapsed = ((Get-Date) - $windowStart).TotalSeconds
        if ($elapsed -ge 0.5) {
            Write-Stats -Seconds $elapsed -Bytes $windowBytes -Frames $player.Frames
            $windowStart = Get-Date
            $windowBytes = [int64]0
        }

        # live horizon tilt: the GUI writes the shader, we hand it to mpv
        if ($job.tiltPath -and (Test-Path $job.tiltPath)) {
            $written = (Get-Item $job.tiltPath).LastWriteTime
            if ($written -gt $lastTilt) {
                $lastTilt = $written
                try {
                    $tj = Get-Content $job.tiltPath -Raw | ConvertFrom-Json
                    if ($tj.shader) { Apply-Shader $tj.shader }
                }
                catch { }
            }
        }

        if ($player.HasExited) { break }
    }
}
finally {
    $player.CloseInput()
    try { $pipe.Dispose() } catch { }
    if ($sc -and -not $sc.HasExited) { Stop-Process -Id $sc.Id -Force -ErrorAction SilentlyContinue }
    $player.WaitExit(1500)
    $player.Kill()
    if ($job.statsPath) {
        Remove-Item $job.statsPath -ErrorAction SilentlyContinue
        Remove-Item "$($job.statsPath).tmp" -ErrorAction SilentlyContinue
    }
}
