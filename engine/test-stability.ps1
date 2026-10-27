# fault injection for quest3-cast: measures how fast the supervisor recovers
param([string]$Serial)
$ErrorActionPreference = 'Continue'
$here     = Split-Path -Parent $PSCommandPath
$stateDir = if ($env:QUEST3CAST_STATE) { $env:QUEST3CAST_STATE } else { Join-Path $env:LOCALAPPDATA 'quest3-cast' }
$runtime  = Join-Path $stateDir 'runtime.json'
$overlayPidFile = Join-Path $stateDir 'overlay.pid'
$adb = (Get-Command adb).Source
if (-not $Serial) {
    $cfgPath = Join-Path $here 'config.json'
    if (Test-Path $cfgPath) {
        $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
        $Serial = '{0}:{1}' -f $cfg.ip, $cfg.port
    }
}
if (-not $Serial) { throw 'serial unknown: set ip in config.json or pass -Serial host:port' }

function Get-Rt {
    if (-not (Test-Path $runtime)) { return $null }
    try { return Get-Content $runtime -Raw | ConvertFrom-Json } catch { return $null }
}

function Wait-NewPipeline([int]$OldPid, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $rt = Get-Rt
        if ($rt -and $rt.pipelinePid -ne $OldPid -and (Get-Process -Id $rt.pipelinePid -ErrorAction SilentlyContinue)) {
            Start-Sleep -Seconds 2
            return $rt
        }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

function Wait-Alive([int]$Id, [int]$TimeoutSec) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Get-Process -Id $Id -ErrorAction SilentlyContinue) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

$results = @()

# --- T1: kill scrcpy inside the pump ---
$rt = Get-Rt
$old = [int]$rt.pipelinePid
$sc = Get-Process scrcpy -ErrorAction SilentlyContinue | Select-Object -First 1
if ($sc) {
    $t0 = Get-Date
    Stop-Process -Id $sc.Id -Force
    $new = Wait-NewPipeline $old 90
    $sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    $results += "T1 kill scrcpy        : recovered=$([bool]$new) in ${sec}s newpid=$($new.pipelinePid)"
    $old = [int]$new.pipelinePid
}

# --- T2: kill ffplay inside the pump ---
$ff = Get-Process ffplay -ErrorAction SilentlyContinue | Select-Object -First 1
if ($ff) {
    $t0 = Get-Date
    Stop-Process -Id $ff.Id -Force
    $new = Wait-NewPipeline $old 90
    $sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    $results += "T2 kill ffplay        : recovered=$([bool]$new) in ${sec}s newpid=$($new.pipelinePid)"
}

# --- T3: kill the HUD ---
$hudPid = 0
if (Test-Path $overlayPidFile) { $hudPid = [int](Get-Content $overlayPidFile -Raw).Trim() }
if ($hudPid) {
    $t0 = Get-Date
    Stop-Process -Id $hudPid -Force -ErrorAction SilentlyContinue
    $ok = $false
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $overlayPidFile) {
            $cand = 0
            [void][int]::TryParse((Get-Content $overlayPidFile -Raw).Trim(), [ref]$cand)
            if ($cand -and $cand -ne $hudPid -and (Get-Process -Id $cand -ErrorAction SilentlyContinue)) { $ok = $true; break }
        }
        Start-Sleep -Milliseconds 300
    }
    $sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
    $results += "T3 kill HUD           : respawned=$ok in ${sec}s"
}

# --- T4: adb transport dropped ---
& $adb disconnect $Serial | Out-Null
$t0 = Get-Date
$offlineSeen = $false
$onlineSeen = $false
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline) {
    $tail = (Get-Content (Join-Path $stateDir 'cast.log') -Tail 12) -join "`n"
    if (-not $offlineSeen -and $tail -match 'device not reachable') { $offlineSeen = $true }
    if ($offlineSeen -and $tail -match 'device online') { $onlineSeen = $true; break }
    Start-Sleep -Milliseconds 500
}
$sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
$results += "T4 adb disconnect     : offlineSeen=$offlineSeen backOnline=$onlineSeen in ${sec}s"

$results | ForEach-Object { $_ }
"--- tail of cast.log ---"
Get-Content (Join-Path $stateDir 'cast.log') -Tail 8
