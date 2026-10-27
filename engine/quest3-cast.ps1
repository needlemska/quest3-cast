#requires -Version 5.1
<#
  Quest 3 -> PC cast service: adb over Wi-Fi + scrcpy, auto-reconnect, auto-restart,
  keeps the headset display awake in between.

    .\quest3-cast.ps1 start       start the service (hidden daemon, visible mirror window)
    .\quest3-cast.ps1 stop        stop it and give the display back to the proximity sensor
    .\quest3-cast.ps1 status      daemon / device / scrcpy state
    .\quest3-cast.ps1 install     start automatically at Windows logon
    .\quest3-cast.ps1 shortcut    put a launcher on the desktop
    .\quest3-cast.ps1 calibrate   measure the horizon tilt and store it as rotateDeg
    .\quest3-cast.ps1 uninstall   remove the logon entry

  Settings: config.json next to this script.
  Runtime:  %LOCALAPPDATA%\quest3-cast (daemon.pid, scrcpy.pid, cast.log).
#>
param(
    [ValidateSet('start', 'stop', 'status', 'install', 'uninstall', 'shortcut', 'calibrate')]
    [string]$Action = 'start',
    [switch]$Daemon,
    # with -Action calibrate: skip the measurement and store this tilt as is
    [double]$Deg = [double]::NaN
)

$ErrorActionPreference = 'Stop'

$root      = Split-Path -Parent $PSCommandPath
$cfgPath   = Join-Path $root 'config.json'
# The GUI can point us at a state directory it is allowed to write (QUEST3CAST_STATE);
# a restricted caller otherwise fails with PermissionDenied on daemon.pid.
$stateDir  = if ($env:QUEST3CAST_STATE) { $env:QUEST3CAST_STATE } else { Join-Path $env:LOCALAPPDATA 'quest3-cast' }
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
$pidFile   = Join-Path $stateDir 'daemon.pid'
$scrcpyPid = Join-Path $stateDir 'scrcpy.pid'
$stopFlag  = Join-Path $stateDir 'stop.flag'
$logFile   = Join-Path $stateDir 'cast.log'
$scrcpyOut = Join-Path $stateDir 'scrcpy.out.log'
$scrcpyErr = Join-Path $stateDir 'scrcpy.err.log'
$statsFile = Join-Path $stateDir 'stats.json'
$runtimeFile = Join-Path $stateDir 'runtime.json'
$heartbeatFile = Join-Path $stateDir 'daemon.heartbeat'

# Command-line fingerprints. A bare script name is NOT safe: any shell whose command
# text mentions the file (an agent session, a taskbar shortcut, this very script when
# it is being edited) matches it too, and the sweeps below would kill that shell.
# Anchor on the real invocation: -File "<...>\quest3-cast.ps1" -Daemon
$daemonRx  = '-File\s+"?[^"\s]*quest3-cast\.ps1"?\s+-Daemon'
$overlayRx = '-File\s+"?[^"\s]*quest3-overlay\.ps1"'
$pumpErr   = Join-Path $stateDir 'pump.err.log'
$overlayPid = Join-Path $stateDir 'overlay.pid'
$overlayScript = Join-Path $root 'quest3-overlay.ps1'
$lnkPath   = Join-Path ([Environment]::GetFolderPath('Startup')) 'Quest3Cast.lnk'
$desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Quest 3 Cast.lnk'
$psExe     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

# ---------------------------------------------------------------- helpers

$defaults = [ordered]@{
    ip           = '192.168.1.100'
    port         = 5555
    eye          = 'left'
    maxSize      = 1440
    fps          = 60
    mbps         = 30
    angle        = 0
    lens         = $true         # undo the headset lens pre-distortion
    lensK1       = -0.4
    lensK2       = 0
    player       = 'mpv'         # mpv (GPU decode + GPU shader) | ffplay (CPU only)
    rotateDeg    = 0             # extra fine tilt, degrees; 0 = as captured
    guide        = $false        # draw the alignment line over the picture
    guideAngle   = 0             # angle of that line in output space, degrees
    audio        = 'none'        # none | mic  - the microphone is OFF by default
    audioBitrate = 128
    fullscreen   = $true
    overlay      = $true         # fps / cpu / gpu / net HUD in a screen corner
    overlayCorner = 'br'         # br | bl | tr | tl
    overlayOpacity = 0.62
    alwaysOnTop  = $false
    keepAwake    = $true
    autoRestart  = $true
    retrySeconds = 10
    maxUptimeHours = 0           # 0 = never recycle; >0 restarts the pipeline after N hours
    windowX      = $null
    windowY      = $null
}

function Write-Log([string]$Message) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # the daemon and a second script invocation (an operator or the GUI running
        # `stop`) can log at the same moment; Add-Content opens the file with a read
        # share only, so the loser gets "cannot write, file in use". Retry instead of
        # spilling an error record into the caller's output.
        $done = $false
        for ($i = 0; $i -lt 5 -and -not $done; $i++) {
            try {
                Add-Content -Path $logFile -Value $line -Encoding ASCII -ErrorAction Stop
                $done = $true
            }
            catch { Start-Sleep -Milliseconds 60 }
        }
        if (-not $done) { $ErrorActionPreference = 'SilentlyContinue' }
        if ($done -and (Get-Item $logFile).Length -gt 512KB) {
            Set-Content -Path $logFile -Value (Get-Content $logFile -Tail 400) -Encoding ASCII
        }
    }
    finally { $ErrorActionPreference = $prev }
}

function Invoke-Adb {
    param([string[]]$AdbArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & adb @AdbArgs 2>&1
        return [pscustomobject]@{ Code = $LASTEXITCODE; Output = @($out) }
    }
    finally { $ErrorActionPreference = $prev }
}

# config.json is hand-edited, and a typo there used to take the whole daemon down
# on start or, for the HUD, produce an endless respawn loop. Values are pushed
# back into range and the corrections are logged once.
function Repair-Config($cfg) {
    $notes = @()

    if (@('left', 'right', 'both') -notcontains [string]$cfg.eye) {
        $notes += "eye '$($cfg.eye)' -> left"; $cfg.eye = 'left'
    }
    if (@('mic', 'none') -notcontains [string]$cfg.audio) {
        $notes += "audio '$($cfg.audio)' -> none"; $cfg.audio = 'none'
    }
    if (@('br', 'bl', 'tr', 'tl') -notcontains [string]$cfg.overlayCorner) {
        $notes += "overlayCorner '$($cfg.overlayCorner)' -> br"; $cfg.overlayCorner = 'br'
    }
    if (@('mpv', 'ffplay') -notcontains [string]$cfg.player) {
        $notes += "player '$($cfg.player)' -> mpv"; $cfg.player = 'mpv'
    }

    $angle = 0
    if (-not [int]::TryParse([string]$cfg.angle, [ref]$angle) -or @(0, 90, 180, 270) -notcontains $angle) {
        $notes += "angle '$($cfg.angle)' -> 0"; $cfg.angle = 0
    }

    $numbers = @(
        @{ k = 'maxSize'; lo = 320; hi = 4128; def = 1440 },
        @{ k = 'fps'; lo = 10; hi = 120; def = 60 },
        @{ k = 'mbps'; lo = 1; hi = 200; def = 30 },
        @{ k = 'audioBitrate'; lo = 32; hi = 320; def = 128 },
        @{ k = 'retrySeconds'; lo = 3; hi = 300; def = 10 },
        @{ k = 'maxUptimeHours'; lo = 0; hi = 720; def = 0 },
        @{ k = 'overlayOpacity'; lo = 0.15; hi = 1.0; def = 0.62 },
        @{ k = 'rotateDeg'; lo = -180; hi = 180; def = 0 },
        @{ k = 'lensK1'; lo = -2; hi = 2; def = -0.4 },
        @{ k = 'lensK2'; lo = -2; hi = 2; def = 0 }
    )
    foreach ($n in $numbers) {
        $value = 0.0
        # invariant culture: on a Russian Windows TryParse("0.62") fails and the
        # value would be silently reset to the default on every start
        $okParse = [double]::TryParse(
            [string]$cfg.($n.k),
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref]$value)
        if (-not $okParse) {
            $notes += "$($n.k) not a number -> $($n.def)"
            $cfg.($n.k) = $n.def
            continue
        }
        if ($value -lt $n.lo -or $value -gt $n.hi) {
            $clamped = [math]::Min([math]::Max($value, $n.lo), $n.hi)
            $notes += "$($n.k) $value -> $clamped"
            $cfg.($n.k) = $clamped
        }
    }
    return $notes
}

function Get-Config {
    if (-not (Test-Path $cfgPath)) {
        $defaults | ConvertTo-Json | Set-Content -Path $cfgPath -Encoding UTF8
        Write-Log "config created: $cfgPath"
    }
    try {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    }
    catch {
        $broken = "$cfgPath.broken"
        Copy-Item $cfgPath $broken -Force -ErrorAction SilentlyContinue
        $defaults | ConvertTo-Json | Set-Content -Path $cfgPath -Encoding UTF8
        Write-Log "config was not valid JSON, rewritten with defaults (backup: $broken)"
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    }
    foreach ($k in $defaults.Keys) {
        if ($null -eq $cfg.$k -and $null -ne $defaults[$k]) {
            $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] -Force
        }
    }
    $notes = Repair-Config $cfg
    if ($notes.Count -gt 0) { Write-Log ('config repaired: ' + ($notes -join '; ')) }
    return $cfg
}

function Get-DeviceState([string]$Serial) {
    $r = Invoke-Adb @('-s', $Serial, 'get-state')
    if ($r.Code -ne 0) { return $null }
    $line = ($r.Output | Where-Object { $_ -is [string] -and $_.Trim() } | Select-Object -First 1)
    if ($line) { return $line.Trim() }
    return $null
}

function Connect-Device([string]$Serial) {
    $st = Get-DeviceStatus $Serial
    if ($st -eq 'device') { return $true }
    if ($st -eq 'unauthorized') {
        # the headset forgot this PC's adb key; only a tap inside the headset can
        # fix it, so hammering `adb connect` is pointless - report and wait
        return $false
    }
    # A headset that rebooted or dropped Wi-Fi leaves a zombie transport behind:
    # `adb connect` then answers "already connected" and the socket is never
    # reopened, so the daemon would wait forever. Drop it first.
    if ($st -eq 'offline' -or $st -eq '') { Invoke-Adb @('disconnect', $Serial) | Out-Null }
    Invoke-Adb @('connect', $Serial) | Out-Null
    Start-Sleep -Milliseconds 700
    return ((Get-DeviceStatus $Serial) -eq 'device')
}

function Get-DeviceStatus([string]$Serial) {
    # device | unauthorized | offline | '' (not in the list at all)
    $r = Invoke-Adb @('devices')
    if ($r.Code -ne 0) { return '' }
    foreach ($line in $r.Output) {
        if ($line -isnot [string]) { continue }
        $t = $line.Trim()
        if ($t -match '^(\S+)\s+(\S+)$' -and $Matches[1] -eq $Serial) { return $Matches[2] }
    }
    return ''
}

function Resolve-Scrcpy {
    $cmd = Get-Command scrcpy -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $found = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter scrcpy.exe -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $found) { throw 'scrcpy not found: winget install Genymobile.scrcpy' }
    return $found
}

function Resolve-Ffplay {
    $cmd = Get-Command ffplay -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $found = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter ffplay.exe -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $found) { throw 'ffplay not found: winget install Gyan.FFmpeg' }
    return $found
}

function Resolve-Mpv {
    $cmd = Get-Command mpv -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
            (Join-Path $env:ProgramFiles 'MPV Player\mpv.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'MPV Player\mpv.exe'),
            (Join-Path $env:LOCALAPPDATA 'Programs\mpv\mpv.exe'))) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    $found = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter mpv.exe -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $found) { throw 'mpv not found: winget install shinchiro.mpv' }
    return $found
}

function Resolve-Ffmpeg {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $found = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter ffmpeg.exe -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $found) { throw 'ffmpeg not found: winget install Gyan.FFmpeg' }
    return $found
}

function Resolve-Python {
    # only `calibrate` needs it: numpy does the angle histogram
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $bundled = Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'
    if (Test-Path $bundled) { return $bundled }
    $found = Get-ChildItem $env:LOCALAPPDATA -Filter python.exe -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $found) { throw 'python not found (needed only by `calibrate`)' }
    return $found
}

function Save-Config($cfg) {
    # write back through the defaults list so unknown keys cannot creep in and
    # the file keeps its documented key order
    $ordered = [ordered]@{}
    foreach ($k in $defaults.Keys) {
        if ($null -ne $cfg.$k) { $ordered[$k] = $cfg.$k } else { $ordered[$k] = $defaults[$k] }
    }
    $ordered | ConvertTo-Json | Set-Content -Path $cfgPath -Encoding UTF8
}

function New-ScrcpyArgs($cfg, [string]$Serial, [string]$PipeName) {
    $crop = @{ left = '2064:2208:0:0'; right = '2064:2208:2064:0'; both = $null }[$cfg.eye]
    $a = @(
        '-s', $Serial,
        '--display-id=0',
        "--max-size=$($cfg.maxSize)",
        "--max-fps=$($cfg.fps)",
        "--video-bit-rate=$($cfg.mbps)M",
        "--window-title=Quest3-$($cfg.eye)"
    )
    if ($cfg.audio -and $cfg.audio -ne 'none') {
        $a += "--audio-source=$($cfg.audio)"
        $a += "--audio-bit-rate=$($cfg.audioBitrate)k"
    }
    else {
        $a += '--no-audio'
    }
    if ($crop) { $a += "--crop=$crop" }
    if ($cfg.angle -ne 0) { $a += "--angle=$($cfg.angle)" }

    if ($PipeName) {
        # lens-correction mode: scrcpy renders nothing, it muxes the stream into a named pipe
        $a += '--no-window'
        $a += "--record=\\.\pipe\$PipeName"
        $a += '--record-format=mkv'
    }
    else {
        if ($cfg.fullscreen) { $a += '--fullscreen' }
        if ($cfg.alwaysOnTop) { $a += '--always-on-top' }
        if ($null -ne $cfg.windowX) { $a += "--window-x=$($cfg.windowX)" }
        if ($null -ne $cfg.windowY) { $a += "--window-y=$($cfg.windowY)" }
    }
    return $a
}

function New-FfplayArgs($cfg) {
    $vf = "lenscorrection=k1=$($cfg.lensK1):k2=$($cfg.lensK2):i=bilinear"
    if ($cfg.rotateDeg) {
        $rad = "($($cfg.rotateDeg)*PI/180)"
        $vf += ",rotate=${rad}:ow=rotw($rad):oh=roth($rad):c=black"
    }
    # showinfo: one stderr line per decoded frame -> the pump turns it into fps
    $vf += ',showinfo'
    $a = @(
        '-hide_banner', '-loglevel', 'info', '-nostats',
        '-f', 'matroska', '-i', 'pipe:0',
        '-window_title', "Quest3-$($cfg.eye)",
        '-vf', $vf,
        '-fflags', 'nobuffer',
        '-flags', 'low_delay',
        '-framedrop'
    )
    if ($cfg.fullscreen) { $a += '-fs' }
    if ($cfg.alwaysOnTop) { $a += '-alwaysontop' }
    return $a
}

# mpv does the lens correction in a fragment shader, so the distortion costs GPU
# time instead of a full-frame CPU resample. The template lives next to the
# scripts and the concrete shader is regenerated into the state dir on every
# pipeline start, so config.json stays the single source of truth.
function Write-LensShader($cfg) {
    $template = Join-Path $root 'lens-template.glsl'
    if (-not (Test-Path $template)) { throw "lens template missing: $template" }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $ang = [math]::Round([double]$cfg.rotateDeg * [math]::PI / 180.0, 6)
    $text = Get-Content $template -Raw
    $text = $text.Replace('@K1@', ([double]$cfg.lensK1).ToString($inv))
    $text = $text.Replace('@K2@', ([double]$cfg.lensK2).ToString($inv))
    $text = $text.Replace('@ANGLE@', $ang.ToString($inv))
    # alignment guide line: drawn in output space so it stays horizontal; the
    # client draws the twin line in the headset, aligning the two sets the tilt
    $guide = if ($cfg.PSObject.Properties['guide'] -and $cfg.guide) { 1 } else { 0 }
    $guideAng = 0.0
    if ($cfg.PSObject.Properties['guideAngle'] -and $cfg.guideAngle) {
        $guideAng = [math]::Round([double]$cfg.guideAngle * [math]::PI / 180.0, 6)
    }
    $text = $text.Replace('@GUIDE@', [string]$guide)
    $text = $text.Replace('@GUIDEANG@', $guideAng.ToString($inv))
    $out = Join-Path $stateDir 'lens.glsl'
    Set-Content -Path $out -Value $text -Encoding ASCII
    return $out
}

function New-MpvArgs($cfg, [string]$ShaderPath) {
    # the stream arrives on stdin (the pump copies the named pipe there)
    $a = @(
        '--no-config',
        '--vo=gpu',
        '--hwdec=d3d11va',
        "--title=Quest3-$($cfg.eye)",
        '--no-osc',
        '--input-terminal=no',
        '--input-default-bindings=no',
        # NOT --profile=low-latency: it makes mpv stop reporting
        # estimated-vf-fps, and then the HUD has no frame rate at all
        '--cache=no',
        '--demuxer-readahead-secs=0.4',
        # without this mpv suppresses status output when stdout is not a tty,
        # and the pump would never see a frame rate
        '--terminal=yes',
        # the pump parses this line for the HUD; no spaces in the template, or
        # argument joining splits it into two argv entries
        '--term-status-msg=STAT_fps=${estimated-vf-fps}',
        # the GUI talks to mpv over this pipe to swap the lens/tilt shader while
        # the pipeline keeps running (auto-levelling from the headset IMU)
        '--input-ipc-server=\\.\pipe\quest3cast-ipc',
        '-'
    )
    if ($ShaderPath) { $a += "--glsl-shaders=$ShaderPath" }
    if ($cfg.audio -eq 'none') { $a += '--no-audio' }
    if ($cfg.fullscreen) { $a += '--fs' }
    if ($cfg.alwaysOnTop) { $a += '--ontop' }
    if ($null -ne $cfg.windowX -or $null -ne $cfg.windowY) {
        $x = if ($null -ne $cfg.windowX) { [int]$cfg.windowX } else { 0 }
        $y = if ($null -ne $cfg.windowY) { [int]$cfg.windowY } else { 0 }
        $a += ('--geometry=+{0}+{1}' -f $x, $y)
    }
    return $a
}

function Test-AudioBlocked([string]$Path) {
    if (-not (Test-Path $Path)) { return $false }
    $tail = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $tail) { return $false }
    return [bool]($tail -match 'Cannot create AudioRecord|Could not capture audio playback|registerAudioPolicy')
}

function Set-Proximity([string]$Serial, [string]$Mode) {
    $r = Invoke-Adb @('-s', $Serial, 'shell', 'am', 'broadcast', '-a', "com.oculus.vrpowermanager.$Mode")
    return ($r.Code -eq 0)
}

function Test-Alive([int]$Id) {
    return [bool](Get-Process -Id $Id -ErrorAction SilentlyContinue)
}

# A pid file can be empty (crash between create and write) or hold a pid that the
# OS has since recycled for an unrelated process. Both used to throw or, worse,
# make `stop` kill a stranger, so every reader goes through here.
function Read-PidFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $raw = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { return $null }
    $id = 0
    if ([int]::TryParse($raw.Trim(), [ref]$id) -and $id -gt 0) { return $id }
    return $null
}

function Get-DaemonProcess {
    $id = Read-PidFile $pidFile
    if (-not $id) { return $null }
    # A heartbeat file is the only liveness signal that survives a restricted caller:
    # when this script is invoked by the GUI, the sandboxed child sees fewer than 40
    # processes, so Get-Process/CIM cannot see the daemon and every command degraded
    # into a bogus "not running". The daemon rewrites the file every poll.
    if (Test-Path $heartbeatFile) {
        $age = ((Get-Date) - (Get-Item $heartbeatFile).LastWriteTime).TotalSeconds
        if ($age -lt 8) { return [pscustomobject]@{ Id = $id; Name = 'powershell'; Heartbeat = $true } }
    }
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction SilentlyContinue).CommandLine
    if (-not $cmd -or $cmd -notmatch $daemonRx) { return $null }
    return $p
}

function Get-ScrcpyPid {
    return (Read-PidFile $scrcpyPid)
}

function Stop-Stragglers {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # scrcpy --record=\\.\pipe\quest3cast / --window-title=Quest3-*, players Quest3-*
        Get-CimInstance Win32_Process -Filter "Name='ffplay.exe' OR Name='scrcpy.exe' OR Name='mpv.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match 'quest3cast|Quest3-' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        # the HUD runs as its own hidden powershell
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match $overlayRx } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    finally { $ErrorActionPreference = $prev }
}

function Stop-Overlay {
    $id = Read-PidFile $overlayPid
    if ($id -and (Test-Alive $id)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    Remove-Item $overlayPid -ErrorAction SilentlyContinue
}

function Start-Overlay($cfg) {
    if (-not (Test-Path $overlayScript)) { return }
    $id = Read-PidFile $overlayPid
    if ($id -and (Test-Alive $id)) { return }
    $oargs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $overlayScript,
        '-StatsPath', $statsFile,
        '-PingHost', $cfg.ip,
        '-PingPort', [string]$cfg.port,
        '-Corner', [string]$cfg.overlayCorner,
        '-Opacity', [string]$cfg.overlayOpacity,
        '-MaxIdle', $(if ($cfg.lens) { '45' } else { '0' }),
        '-Mode', ('{0}p{1}/{2}/{3}' -f $cfg.maxSize, $cfg.fps, $cfg.audio, $cfg.player),
        '-GuidePath', (Join-Path $stateDir 'guide.json')
    )
    if ($cfg.audio -and $cfg.audio -ne 'none') { $oargs += '-Mic' }
    $o = Start-Process -FilePath $psExe -PassThru -WindowStyle Hidden -ArgumentList $oargs
    Set-Content -Path $overlayPid -Value $o.Id -Encoding ASCII
    Write-Log "hud up  pid=$($o.Id)  corner=$($cfg.overlayCorner)"
}

# Lost pid file (crash, manual cleanup, a copied state dir) used to make `stop`
# a no-op for the daemon itself: it only killed the cast tree and the daemon
# brought it straight back. This is `stop`'s own sweep, so it must never run
# inside the daemon - Stop-Stragglers is called from the daemon's finally block.
function Stop-OrphanDaemons {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -match $daemonRx
            } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    finally { $ErrorActionPreference = $prev }
}

function Stop-Tree([int]$Id) {
    # kill the pump and everything it spawned (scrcpy + ffplay)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & taskkill.exe /PID $Id /T /F 2>&1 | Out-Null
        Stop-Stragglers
    }
    finally { $ErrorActionPreference = $prev }
}

# prox_close is a persistent override on the headset: if the daemon is killed
# with -Force its finally block never runs and the panel would stay awake until
# the headset reboots. `stop` therefore releases the display unconditionally.
function Release-Display {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $cfg = Get-Config
        if (-not $cfg.keepAwake) { return }
        $serial = '{0}:{1}' -f $cfg.ip, $cfg.port
        if ((Get-DeviceState $serial) -eq 'device' -and (Set-Proximity $serial 'prox_open')) {
            Write-Log 'display released (prox_open, forced)'
        }
    }
    catch { }
    finally { $ErrorActionPreference = $prev }
}

# ---------------------------------------------------------------- daemon

function Write-Runtime($cfg, [bool]$UseLens, $PipelinePid, [int]$Restarts, [string]$Audio, $DaemonSince, $PipelineSince, [string]$Player) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        [ordered]@{
            daemonPid    = $PID
            daemonSince  = if ($DaemonSince) { ([datetime]$DaemonSince).ToString('o') } else { $null }
            pipelineSince = if ($PipelineSince) { ([datetime]$PipelineSince).ToString('o') } else { $null }
            mode         = if ($UseLens) { 'lens' } else { 'raw' }
            player       = $Player
            audio        = $Audio
            pipelinePid  = $PipelinePid
            restarts     = $Restarts
            eye          = $cfg.eye
            maxSize      = $cfg.maxSize
            fps          = $cfg.fps
        } | ConvertTo-Json | Set-Content -Path $runtimeFile -Encoding UTF8
    }
    finally { $ErrorActionPreference = $prev }
}

function Start-DaemonLoop {
    # a second daemon makes two scrcpy instances fight over the same named pipe and
    # two writers race for daemon.pid. The mutex below covers the common case, but
    # ownership of a Mutex is thread affine: if the runspace thread ends the mutex is
    # abandoned and a new daemon walks straight in. So also check the process table,
    # which cannot lie.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # cheapest and view-independent guard: the previous daemon left a fresh heartbeat
    $hbAge = -1
    if (Test-Path $heartbeatFile) {
        try { $hbAge = ((Get-Date) - (Get-Item $heartbeatFile).LastWriteTime).TotalSeconds } catch { $hbAge = -1 }
    }
    if ($hbAge -ge 0 -and $hbAge -lt 8) {
        try { Write-Log "another daemon is alive (heartbeat $([int]$hbAge)s old), exiting" } catch { }
        $ErrorActionPreference = $prev
        return
    }
    $rival = $null
    try {
        $rival = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.CommandLine -match $daemonRx
            } |
            Select-Object -First 1
    }
    catch { }
    finally { $ErrorActionPreference = $prev }
    if ($rival) {
        try { Write-Log "another daemon is already running (pid $($rival.ProcessId)), exiting" } catch { }
        return
    }

    $mutex = New-Object System.Threading.Mutex($false, 'quest3cast-daemon')
    if (-not $mutex.WaitOne(0)) {
        $prev2 = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { Write-Log 'another daemon already owns the pipe, exiting' } catch { }
        $ErrorActionPreference = $prev2
        return
    }

    $cfg = Get-Config
    $serial = '{0}:{1}' -f $cfg.ip, $cfg.port
    $scrcpy = Resolve-Scrcpy

    $pumpScript = Join-Path $root 'quest3-pump.ps1'
    $planFile = Join-Path $stateDir 'plan.json'
    $pipeName = 'quest3cast'
    # the pump is the default transport; the lens shader is optional on top of it
    $usePump = Test-Path $pumpScript
    $useLens = [bool]$cfg.lens -and $usePump
    # mpv decodes with d3d11va and warps on the GPU (0.25 core); ffplay does both
    # on the CPU (2.4 cores). mpv is the default, ffplay the fallback.
    $playerName = 'ffplay'
    $playerExe = $null
    # the player choice does not depend on the lens: mpv still decodes on the GPU
    # (0.2 core) when the shader is off, ffplay would burn 2.4 cores for the same frame
    if ([string]$cfg.player -eq 'mpv') {
        try { $playerExe = Resolve-Mpv; $playerName = 'mpv' }
        catch { Write-Log "mpv unavailable, falling back to ffplay: $($_.Exception.Message)" }
    }
    if (-not $playerExe) { $playerExe = Resolve-Ffplay; $playerName = 'ffplay' }

    Set-Content -Path $pidFile -Value $PID -Encoding ASCII
    Remove-Item $stopFlag -ErrorAction SilentlyContinue
    Write-Log "daemon up  pid=$PID  serial=$serial  eye=$($cfg.eye)"
    Write-Log "mode: $(if ($useLens) { "lens k1=$($cfg.lensK1) k2=$($cfg.lensK2) tilt=$($cfg.rotateDeg) player=$playerName" } else { 'raw' })"

    $sid = $null
    $mode = 'init'
    $audioBlocked = $false
    $lastKa = Get-Date
    $lastConn = [datetime]::MinValue
    $awake = $false
    $daemonUp = Get-Date
    $startedAt = $null
    $restarts = 0
    $failStreak = 0
    $lastAuthHint = [datetime]::MinValue
    $zeroStreak = 0

    try {
        while (-not (Test-Path $stopFlag)) {
          try {

            # --- liveness beacon for callers that cannot inspect processes ---
            try { Set-Content -Path $heartbeatFile -Value (Get-Date -Format 'o') -Encoding ASCII -ErrorAction Stop } catch { }

            # --- connection watchdog (probe every retrySeconds) ---
            if (((Get-Date) - $lastConn).TotalSeconds -ge $cfg.retrySeconds -or $mode -eq 'init') {
                $lastConn = Get-Date
                if (Connect-Device $serial) {
                    if ($mode -ne 'online') { Write-Log 'device online'; $mode = 'online' }
                }
                elseif ((Get-DeviceStatus $serial) -eq 'unauthorized') {
                    # only a tap inside the headset helps here; one hint per five minutes
                    if (((Get-Date) - $lastAuthHint).TotalMinutes -ge 5) {
                        Write-Log 'device is unauthorized: accept "Allow USB debugging" in the headset (always allow)'
                        $lastAuthHint = Get-Date
                    }
                    $mode = 'unauthorized'
                }
                elseif ($mode -ne 'offline') {
                    Write-Log 'device not reachable, waiting for it to come back'
                    $mode = 'offline'
                }
            }
            if ($mode -ne 'online') { Start-Sleep -Seconds 2; continue }

            # --- scrcpy supervision (poll every 2s) ---
            if (-not $sid -or -not (Test-Alive $sid)) {
                if ($sid) {
                    Write-Log "scrcpy pid=$sid exited"
                    if (Test-Path $pumpErr) {
                        $tail = (Get-Content $pumpErr -Tail 3 -ErrorAction SilentlyContinue) -join ' | '
                        if ($tail) { Write-Log "pump stderr: $tail" }
                    }
                    if (-not $audioBlocked -and $cfg.audio -ne 'none' -and (Test-AudioBlocked $scrcpyErr)) {
                        Write-Log "headset refused audio-source=$($cfg.audio) (Android policy) - switching to video-only"
                        $cfg.audio = 'none'
                        $audioBlocked = $true
                    }
                    # a pipeline that dies within seconds is a loop, not an incident:
                    # back off instead of hammering adb and scrcpy every 3 s
                    $lived = if ($startedAt) { ((Get-Date) - $startedAt).TotalSeconds } else { 3600 }
                    if ($lived -lt 20) { $failStreak++ } else { $failStreak = 0 }
                    $startedAt = $null
                    $sid = $null
                    Remove-Item $scrcpyPid -ErrorAction SilentlyContinue
                    if (-not $cfg.autoRestart) { Write-Log 'autoRestart disabled, daemon exiting'; break }
                    $delay = [int][math]::Min(3 * [math]::Pow(2, [math]::Max(0, $failStreak - 1)), 30)
                    if ($failStreak -gt 0) { Write-Log "restart backoff ${delay}s (fail streak $failStreak)" }
                    Start-Sleep -Seconds $delay
                    if (Test-Path $stopFlag) { break }
                }

                if ($cfg.keepAwake -and -not $awake) {
                    if (Set-Proximity $serial 'prox_close') { $awake = $true; Write-Log 'display kept awake (prox_close)' }
                }

                Remove-Item $scrcpyErr, $scrcpyOut, $statsFile -ErrorAction SilentlyContinue
                if ($usePump) {
                    $sargs = New-ScrcpyArgs $cfg $serial $pipeName
                    $shader = if ($useLens) { Write-LensShader $cfg } else { $null }
                    if ($playerName -eq 'mpv') {
                        $pargs = New-MpvArgs $cfg $shader
                    }
                    else {
                        $pargs = New-FfplayArgs $cfg
                    }
                    $plan = [ordered]@{
                        pipeName         = $pipeName
                        scrcpy           = $scrcpy
                        scrcpyArgs       = $sargs
                        scrcpyErr        = $scrcpyErr
                        player           = $playerName
                        playerExe        = $playerExe
                        playerArgs       = $pargs
                        statsPath        = $statsFile
                        # the GUI cannot open mpv's named pipe (it runs under a
                        # restricted token), so it drops the wanted tilt here and
                        # the pump - which owns mpv - does the shader swap
                        tiltPath         = (Join-Path $stateDir 'tilt.json')
                        lensTemplate     = (Join-Path $PSScriptRoot 'lens-template.glsl')
                        lensLive         = (Join-Path $stateDir 'lens-live.glsl')
                        connectTimeoutMs = 15000
                    }
                    $plan | ConvertTo-Json -Depth 4 | Set-Content -Path $planFile -Encoding UTF8
                    Write-Log "pump $($sargs -join ' ')"
                    $p = Start-Process -FilePath $psExe -PassThru -WindowStyle Hidden -ArgumentList @(
                        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $pumpScript, '-PlanPath', $planFile
                    ) -RedirectStandardOutput $scrcpyOut -RedirectStandardError $pumpErr
                }
                else {
                    $sargs = New-ScrcpyArgs $cfg $serial
                    Write-Log "scrcpy $($sargs -join ' ')"
                    $p = Start-Process -FilePath $scrcpy -ArgumentList $sargs -PassThru `
                        -RedirectStandardOutput $scrcpyOut -RedirectStandardError $scrcpyErr
                }
                $sid = $p.Id
                Set-Content -Path $scrcpyPid -Value $sid -Encoding ASCII
                $startedAt = Get-Date
                $restarts++
                Write-Runtime $cfg $useLens $sid $restarts $cfg.audio $daemonUp $startedAt $playerName
                if ($cfg.overlay) { Start-Overlay $cfg }
                $lastKa = Get-Date
            }

            # --- periodic keepalive so the panel does not nap ---
            if ($cfg.keepAwake -and ((Get-Date) - $lastKa).TotalSeconds -ge 60) {
                Set-Proximity $serial 'prox_close' | Out-Null
                $lastKa = Get-Date
            }

            # --- long-run hygiene: recycle the pipeline to bound drift and leaks ---
            if ($startedAt) {
                $upHours = ((Get-Date) - $startedAt).TotalHours
                if (((Get-Date) - $startedAt).TotalSeconds -ge 120) { $failStreak = 0 }
                if ($cfg.maxUptimeHours -gt 0 -and $upHours -ge $cfg.maxUptimeHours) {
                    Write-Log ('recycling pipeline after {0:N1} h uptime' -f $upHours)
                    if ($sid) { Stop-Tree $sid }
                    $sid = $null
                    $startedAt = $null
                    Remove-Item $scrcpyPid -ErrorAction SilentlyContinue
                    continue
                }
            }

            # --- frozen picture watchdog ---
            # the pump writes fps into stats.json every half second; a live process
            # that reports 0 fps for 20 s is wedged (blocked pipe, stuck decoder)
            # and only a restart of the whole pipeline helps
            if ($usePump -and $sid -and $startedAt -and (Test-Path $statsFile) -and ((Get-Item $statsFile).LastWriteTime -gt $startedAt)) {
                $age = 0
                try { $age = ((Get-Date) - (Get-Item $statsFile).LastWriteTime).TotalSeconds } catch { }
                $liveFps = -1
                try { $liveFps = [int](Get-Content $statsFile -Raw | ConvertFrom-Json).fps } catch { }
                $stallReason = $null
                if ($age -gt 25) {
                    # the pump itself is blocked (writing into a stuck ffplay)
                    $stallReason = "stats untouched for $([int]$age)s"
                }
                elseif ($liveFps -eq 0) {
                    $zeroStreak++
                    if ($zeroStreak -ge 10) { $stallReason = "0 fps for $($zeroStreak * 2)s" }
                }
                else { $zeroStreak = 0 }

                if ($stallReason) {
                    Write-Log "pipeline stalled ($stallReason), restarting"
                    Stop-Tree $sid
                    $sid = $null
                    $startedAt = $null
                    $zeroStreak = 0
                    Remove-Item $scrcpyPid -ErrorAction SilentlyContinue
                    continue
                }
            }

            # --- HUD watchdog: bring it back if it died ---
            if ($cfg.overlay) {
                $hud = $null
                if (Test-Path $overlayPid) { $hud = (Get-Content $overlayPid -Raw).Trim() }
                if (-not $hud -or -not (Test-Alive ([int]$hud))) { Start-Overlay $cfg }
            }

            Start-Sleep -Seconds 2
          }
          catch {
            # a single bad iteration must never take the supervisor down with it
            Write-Log "loop error: $($_.Exception.Message)"
            Start-Sleep -Seconds 5
          }
        }
    }
    finally {
        if ($sid -and (Test-Alive $sid)) { Stop-Tree $sid }
        Stop-Stragglers
        Stop-Overlay
        Remove-Item $statsFile, $runtimeFile -ErrorAction SilentlyContinue
        if ($cfg.keepAwake -and $awake) {
            Set-Proximity $serial 'prox_open' | Out-Null
            Write-Log 'display released (prox_open)'
        }
        Remove-Item $pidFile, $scrcpyPid, $stopFlag, $heartbeatFile -ErrorAction SilentlyContinue
        Write-Log 'daemon down'
        try { $mutex.ReleaseMutex() } catch { }
        try { $mutex.Dispose() } catch { }
    }
}

# ---------------------------------------------------------------- actions

function Find-DaemonByCommandLine {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # the pid file is written a moment after the daemon starts, so look for the
        # process itself too - otherwise `start` reports a failure while the cast
        # is in fact coming up
        $hit = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match $daemonRx } |
            Select-Object -First 1
        if ($hit) { return (Get-Process -Id $hit.ProcessId -ErrorAction SilentlyContinue) }
        return $null
    }
    finally { $ErrorActionPreference = $prev }
}

function Invoke-Start {
    $d = Get-DaemonProcess
    if ($d) { Write-Host "already running (daemon pid $($d.Id))"; return }

    $cfg = Get-Config
    Remove-Item $stopFlag, $scrcpyPid -ErrorAction SilentlyContinue
    Start-Process -FilePath $psExe -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Daemon'
    )
    # adb connect can take several seconds on a cold Wi-Fi link, so poll instead
    # of assuming the daemon is up after a fixed delay (the GUI used to report a
    # failed start while the cast was in fact coming up)
    $deadline = (Get-Date).AddSeconds(20)
    $d = $null
    while ((Get-Date) -lt $deadline) {
        $d = Get-DaemonProcess
        if (-not $d) { $d = Find-DaemonByCommandLine }
        if ($d) { break }
        Start-Sleep -Milliseconds 400
    }
    if (-not $d) {
        $hint = ''
        if (Test-Path $logFile) {
            $hint = (Get-Content $logFile -Tail 5 | Where-Object { $_ -match 'fatal|error|not found' } | Select-Object -Last 1)
        }
        $why = if ($hint) { " - $hint" } else { '' }
        throw "daemon failed to start$why, see $logFile"
    }
    if (-not (Test-Path $pidFile)) {
        Set-Content -Path $pidFile -Value $d.Id -Encoding ASCII
    }
    Write-Host "started  daemon pid=$($d.Id)  window=Quest3-$($cfg.eye)  log=$logFile"
}

function Invoke-Stop {
    $d = Get-DaemonProcess
    $sid = Get-ScrcpyPid

    if (-not $d) {
        if ($sid -and (Test-Alive $sid)) { Stop-Tree $sid }
        Stop-OrphanDaemons
        Stop-Stragglers
        Stop-Overlay
        Release-Display
        Remove-Item $pidFile, $scrcpyPid, $stopFlag, $statsFile, $runtimeFile, $heartbeatFile -ErrorAction SilentlyContinue
        Write-Host 'not running'
        return
    }

    Set-Content -Path $stopFlag -Value 'stop' -Encoding ASCII
    # do NOT kill the pump from here: the daemon's finally block stops its whole
    # tree (taskkill /T + command-line sweep). Killing the pump first orphans ffplay/scrcpy.

    # Wait for the daemon to shut itself down, judging it by its own files: a caller
    # that runs this script inside a sandbox cannot see the daemon process at all.
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $hbFresh = (Test-Path $heartbeatFile) -and (((Get-Date) - (Get-Item $heartbeatFile).LastWriteTime).TotalSeconds -lt 6)
        if (-not (Test-Path $pidFile) -and -not $hbFresh) { break }
        Start-Sleep -Milliseconds 300
    }
    $leftover = Read-PidFile $pidFile
    if ($leftover) { Stop-Process -Id $leftover -Force -ErrorAction SilentlyContinue }
    # the daemon removes its pid file in the finally block, so a surviving file
    # means it was killed and never got to release the display itself
    $cleanExit = -not (Test-Path $pidFile)
    Stop-OrphanDaemons
    Stop-Stragglers
    Stop-Overlay
    if (-not $cleanExit) { Release-Display }
    Remove-Item $pidFile, $scrcpyPid, $stopFlag, $statsFile, $runtimeFile, $heartbeatFile -ErrorAction SilentlyContinue
    Write-Host 'stopped'
}

function Invoke-Status {
    $cfg = Get-Config
    $serial = '{0}:{1}' -f $cfg.ip, $cfg.port
    $d = Get-DaemonProcess
    $state = Get-DeviceStatus $serial
    $sid = Get-ScrcpyPid
    $scrcpyState = 'not running'
    if ($sid -and (Test-Alive ([int]$sid))) { $scrcpyState = "running (pid $sid)" }

    'daemon    : ' + $(if ($d) { "running (pid $($d.Id))" } else { 'stopped' })
    'device    : ' + $serial + ' -> ' + $(if (-not $state) { 'not connected' } elseif ($state -eq 'unauthorized') { 'unauthorized (accept the prompt in the headset)' } else { $state })
    'cast      : ' + $scrcpyState + ' (pump -> ' + $cfg.player + ')'
    'options   : eye=' + $cfg.eye + ' size=' + $cfg.maxSize + ' fps=' + $cfg.fps + ' mbps=' + $cfg.mbps + ' angle=' + $cfg.angle + ' audio=' + $cfg.audio + '/' + $cfg.audioBitrate + 'k fullscreen=' + $cfg.fullscreen
    'lens      : ' + $(if ($cfg.lens) { "on  k1=$($cfg.lensK1) k2=$($cfg.lensK2) tilt=$($cfg.rotateDeg)" } else { 'off (no shader, GPU decode still on)' })
    'mic       : ' + $(if ($cfg.audio -eq 'mic') { "ON  ($($cfg.audioBitrate)k, headset microphone)" } else { 'OFF (default; nothing is recorded)' })
    $hudPid = Read-PidFile $overlayPid
    $hudState = 'off'
    if ($cfg.overlay) {
        if ($hudPid -and (Test-Alive $hudPid)) { $hudState = "running (pid $hudPid, corner=$($cfg.overlayCorner))" }
        else { $hudState = 'enabled, not running' }
    }
    'hud       : ' + $hudState

    # what the daemon is REALLY doing, as opposed to what config.json asks for
    if ($d -and (Test-Path $runtimeFile)) {
        try {
            $rt = Get-Content $runtimeFile -Raw | ConvertFrom-Json
            $up = ''
            if ($rt.daemonSince) {
                $span = (Get-Date) - ([datetime]$rt.daemonSince).ToLocalTime()
                $up = ' up=' + ('{0:hh\:mm\:ss}' -f $span)
            }
            $pipeUp = ''
            if ($rt.pipelineSince) {
                $pspan = (Get-Date) - ([datetime]$rt.pipelineSince).ToLocalTime()
                $pipeUp = ' pipeline=' + ('{0:hh\:mm\:ss}' -f $pspan)
            }
            'runtime   : mode=' + $rt.mode + ' player=' + $rt.player + ' audio=' + $rt.audio + ' restarts=' + $rt.restarts + $up + $pipeUp
        }
        catch { 'runtime   : unreadable (' + $_.Exception.Message + ')' }
    }
    'autostart : ' + $(if (Test-Path $lnkPath) { 'installed' } else { 'not installed' })
    'log       : ' + $logFile
    'scrcpy log: ' + $scrcpyErr
}

function Invoke-Install {
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($lnkPath)
    $lnk.TargetPath = $psExe
    $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Action start' -f $PSCommandPath
    $lnk.WorkingDirectory = $root
    $lnk.WindowStyle = 7
    $lnk.Description = 'Quest 3 cast to PC (adb + scrcpy)'
    $lnk.Save()
    Write-Host "autostart installed: $lnkPath"
}

function Invoke-Uninstall {
    if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force; Write-Host "autostart removed: $lnkPath" }
    else { Write-Host 'autostart was not installed' }
    if (Test-Path $desktopLnk) { Remove-Item $desktopLnk -Force; Write-Host "desktop shortcut removed: $desktopLnk" }
}

function Invoke-Shortcut {
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($desktopLnk)
    $lnk.TargetPath = $psExe
    $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Action start' -f $PSCommandPath
    $lnk.WorkingDirectory = $root
    $lnk.WindowStyle = 7
    $lnk.Description = 'Quest 3 cast: adb + scrcpy, lens-corrected, one eye'
    $lnk.IconLocation = "$env:SystemRoot\System32\shell32.dll,17"
    $lnk.Save()
    Write-Host "desktop shortcut created: $desktopLnk"
}

function Invoke-Calibrate {
    $cfg = Get-Config
    $tilt = $null

    if (-not [double]::IsNaN($Deg)) {
        $tilt = $Deg
        Write-Host "using the given tilt: $tilt deg"
    }
    else {
        $serial = '{0}:{1}' -f $cfg.ip, $cfg.port
        if ((Get-DeviceStatus $serial) -ne 'device') {
            if (-not (Connect-Device $serial)) { throw "headset not connected: $serial" }
        }
        $scrcpy = Resolve-Scrcpy
        $ffmpeg = Resolve-Ffmpeg
        $python = Resolve-Python
        $level = Join-Path $root 'level.py'
        if (-not (Test-Path $level)) { throw "level.py is missing next to this script: $level" }

        $mkv = Join-Path $stateDir 'calib.mkv'
        $raw = Join-Path $stateDir 'calib.raw'
        $calibErr = Join-Path $stateDir 'calib.err.log'
        Remove-Item $mkv, $raw, $calibErr -ErrorAction SilentlyContinue

        Write-Host 'measuring: hold the headset exactly as you will be watching it, 6 s...'
        # raw capture on purpose: no lens correction, no rotateDeg, so the number
        # is absolute and running calibrate twice does not stack corrections
        $recArgs = @(
            '-s', $serial, '--display-id=0', "--max-size=$($cfg.maxSize)",
            '--max-fps=30', '--no-audio'
        )
        $crop = @{ left = '2064:2208:0:0'; right = '2064:2208:2064:0'; both = $null }[$cfg.eye]
        if ($crop) { $recArgs += "--crop=$crop" }
        if ($cfg.angle -ne 0) { $recArgs += "--angle=$($cfg.angle)" }
        $recArgs += @('--no-window', "--record=$mkv", '--record-format=mkv', '--time-limit=6')
        Start-Process -FilePath $scrcpy -ArgumentList $recArgs -NoNewWindow -Wait -RedirectStandardError $calibErr | Out-Null
        if (-not (Test-Path $mkv)) {
            $why = ''
            if (Test-Path $calibErr) { $why = ' - ' + ((Get-Content $calibErr -Tail 3) -join ' ') }
            throw "recording failed$why"
        }

        & $ffmpeg -hide_banner -loglevel error -y -i $mkv -vf 'scale=512:548,format=gray' -frames:v 12 -f rawvideo $raw
        if (-not (Test-Path $raw)) { throw 'could not extract frames from the recording' }

        $out = (& $python $level $raw 512 548 '--crop' '0.15') -join ' '
        if ($out -notmatch 'roll=(-?\d+(?:\.\d+)?)\s+confidence=(\d+(?:\.\d+)?)') {
            throw "level.py could not read the frames: $out"
        }
        $roll = [double]$Matches[1]
        $conf = [double]$Matches[2]
        Write-Host ('measured horizon tilt {0} deg  (confidence {1})' -f $roll, $conf)
        if ($conf -lt 0.12) {
            Write-Host 'warning: almost no straight lines in view - aim at a wall corner, a desk edge or a monitor'
        }

        # the estimator reports the direction the content is rotated by, so the
        # filter needs the opposite sign to bring the horizon back to level
        $tilt = [math]::Round((-$roll) * 2) / 2
        Remove-Item $mkv, $raw -ErrorAction SilentlyContinue
    }

    $cfg.rotateDeg = $tilt
    Save-Config $cfg
    Write-Host ('rotateDeg = {0}  (config.json updated)' -f $tilt)

    $d = Get-DaemonProcess
    if ($d) {
        Invoke-Stop | Out-Null
        Start-Sleep -Seconds 1
        Invoke-Start
        Write-Host 'restarted with the new tilt'
    }
    else { Write-Host 'run `quest3-cast.ps1 start` to apply it' }
}

# ---------------------------------------------------------------- entry point

if ($Daemon) {
    try {
        Start-DaemonLoop
    }
    catch {
        # without this a missing scrcpy, a broken config or an adb hiccup killed
        # the daemon silently and `start` only said "failed to start"
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { Add-Content -Path $logFile -Value ('{0}  fatal: {1}' -f $stamp, $_.Exception.Message) -Encoding ASCII } catch { }
        $ErrorActionPreference = $prev
    }
    exit
}

switch ($Action) {
    'start'     { Invoke-Start }
    'stop'      { Invoke-Stop }
    'status'    { Invoke-Status }
    'install'   { Invoke-Install }
    'uninstall' { Invoke-Uninstall }
    'shortcut'  { Invoke-Shortcut }
    'calibrate' { Invoke-Calibrate }
}

# a native command inside the script (adb, taskkill, scrcpy launcher) leaves its
# own exit code behind; without this the caller saw success as failure
exit 0



