# soak sampler: one CSV row every 15 s; memory drift and fps drops become visible
param([int]$Minutes = 10, [string]$Out = "$env:TEMP\quest3-soak.csv")
$ErrorActionPreference = 'Continue'
$stateDir = Join-Path $env:LOCALAPPDATA 'quest3-cast'
$log = Join-Path $stateDir 'cast.log'
$deadline = (Get-Date).AddMinutes($Minutes)
"t;fps;mbps;restarts;pipeline;scrcpy_mb;ffplay_mb;pump_mb;hud_mb;ffplay_cpu;pump_cpu;logKB;device" |
    Set-Content $Out -Encoding ASCII
while ((Get-Date) -lt $deadline) {
    $fps = ''; $mbps = ''
    try {
        $s = Get-Content (Join-Path $stateDir 'stats.json') -Raw | ConvertFrom-Json
        $fps = $s.fps; $mbps = $s.mbps
    }
    catch { }
    $rt = $null
    try { $rt = Get-Content (Join-Path $stateDir 'runtime.json') -Raw | ConvertFrom-Json } catch { }

    $sp = 0; $fp = 0; $fcpu = 0; $pp = 0; $pcpu = 0
    Get-Process scrcpy -ErrorAction SilentlyContinue | ForEach-Object { $sp += $_.WorkingSet64 }
    Get-Process ffplay -ErrorAction SilentlyContinue | ForEach-Object { $fp += $_.WorkingSet64; $fcpu += $_.CPU }
    if ($rt) {
        $pr = Get-Process -Id $rt.pipelinePid -ErrorAction SilentlyContinue
        if ($pr) { $pp = $pr.WorkingSet64; $pcpu = $pr.CPU }
    }
    $hp = 0
    try {
        $hid = [int](Get-Content (Join-Path $stateDir 'overlay.pid') -Raw).Trim()
        $hp = (Get-Process -Id $hid -ErrorAction SilentlyContinue).WorkingSet64
    }
    catch { }
    $kb = 0
    if (Test-Path $log) { $kb = [int]((Get-Item $log).Length / 1KB) }
    $dev = 'absent'
    $line = (& adb devices 2>$null | Select-String '192\.168\.88\.120')
    if ($line) { $dev = ($line.ToString().Trim() -split '\s+')[-1] }

    $row = '{0};{1};{2};{3};{4};{5};{6};{7};{8};{9};{10};{11};{12}' -f (Get-Date -Format 'HH:mm:ss'), $fps, $mbps,
        $(if ($rt) { $rt.restarts } else { '' }), $(if ($rt) { $rt.pipelinePid } else { '' }),
        [int]($sp / 1MB), [int]($fp / 1MB), [int]($pp / 1MB), [int]($hp / 1MB),
        [math]::Round($fcpu, 1), [math]::Round($pcpu, 1), $kb, $dev
    Add-Content -Path $Out -Value $row -Encoding ASCII
    Start-Sleep -Seconds 15
}
'SOAK DONE'
