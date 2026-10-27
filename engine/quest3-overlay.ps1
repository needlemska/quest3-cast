#requires -Version 5.1
<#
  Quest 3 cast - lightweight HUD.

  A small always-on-top, click-through, semi-transparent strip in a screen corner:

      fps 58   drop 0.4/s
      cpu 24%  gpu 6%
      net 41 Mb/s  ram 46%
      ping 12 ms  vid 30 Mb/s

  fps / drop / vid come from stats.json written by quest3-pump.ps1, the rest is
  read straight from performance counters (no WMI polling in the hot loop).
#>
param(
    [string]$StatsPath = "$env:LOCALAPPDATA\quest3-cast\stats.json",
    [string]$PingHost = '192.168.1.100',
    [int]$PingPort = 5555,
    [ValidateSet('br', 'bl', 'tr', 'tl')][string]$Corner = 'br',
    [double]$Opacity = 0.62,
    [string]$Mode = '',
    [int]$MaxIdle = 45,
    [switch]$Mic,
    [string]$GuidePath = ''
)

# The microphone is off unless the cast was explicitly started with it, so the
# HUD says so out loud: this is the privacy indicator, not a decoration.
$micText = if ($Mic) { 'MIC ON' } else { 'MIC OFF' }

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class HudNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
}
"@

$GWL_EXSTYLE = -20
$WS_EX_LAYERED = 0x80000
$WS_EX_TRANSPARENT = 0x20
$WS_EX_TOOLWINDOW = 0x80
$WS_EX_NOACTIVATE = 0x08000000

$font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Regular)
$brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 235, 235))
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.StartPosition = 'Manual'
$form.BackColor = [System.Drawing.Color]::Black
$form.Opacity = $Opacity
$form.AutoScaleMode = 'None'
$form.Text = 'Quest3 HUD'

$label = New-Object System.Windows.Forms.Label
$label.AutoSize = $true
$label.Font = $font
$label.ForeColor = [System.Drawing.Color]::FromArgb(235, 235, 235)
$label.BackColor = [System.Drawing.Color]::Transparent
$label.Location = New-Object System.Drawing.Point(10, 6)
$label.Text = 'fps --  vid --' + [Environment]::NewLine + 'cpu --  ram --' + [Environment]::NewLine +
              'gpu --  ping --' + [Environment]::NewLine + $micText + [Environment]::NewLine + '--'
$form.Controls.Add($label)

# ------------------------------------------------------- horizon guide line
# A dead straight line across the whole screen, drawn by the PC next to the
# streamed picture. The client draws its twin in the headset, so the operator
# brings the two together instead of guessing an angle. Kept in a separate
# always-on-top window so it does not depend on the player's shaders at all.
$guideForm = $null
if ($GuidePath) {
    $guideForm = New-Object System.Windows.Forms.Form
    $guideForm.FormBorderStyle = 'None'
    $guideForm.ShowInTaskbar = $false
    $guideForm.TopMost = $true
    $guideForm.StartPosition = 'Manual'
    $guideForm.BackColor = [System.Drawing.Color]::FromArgb(40, 240, 255)
    $guideForm.Opacity = 0.9
    $guideForm.Text = 'Quest3 Guide'
    $guideForm.Visible = $false
}

# ------------------------------------------------------------ metrics setup

$gpuCounters = @{}
$gpuRefreshAt = [datetime]::MinValue

function Update-GpuCounters {
    try {
        $cat = New-Object System.Diagnostics.PerformanceCounterCategory('GPU Engine')
        $names = @($cat.GetInstanceNames() | Where-Object { $_ -like '*engtype_3D*' })
    } catch { $names = @() }

    $stale = @($gpuCounters.Keys | Where-Object { $names -notcontains $_ })
    foreach ($key in $stale) { $gpuCounters.Remove($key) }

    foreach ($name in $names) {
        if ($gpuCounters.ContainsKey($name)) { continue }
        try {
            $counter = New-Object System.Diagnostics.PerformanceCounter('GPU Engine', 'Utilization Percentage', $name)
            $null = $counter.NextValue()
            $gpuCounters[$name] = $counter
        } catch { }
    }
}

# Localised Windows breaks the English performance-counter paths, so cpu and
# ram are measured off the cast processes themselves - locale independent.
function Get-ChainCpuSec {
    $sum = 0.0
    foreach ($pr in @(Get-Process scrcpy, ffplay, mpv -ErrorAction SilentlyContinue)) {
        try { $sum += $pr.TotalProcessorTime.TotalSeconds } catch { }
    }
    return $sum
}

function Get-ChainRamMb {
    $sum = [int64]0
    foreach ($pr in @(Get-Process scrcpy, ffplay, mpv -ErrorAction SilentlyContinue)) {
        try { $sum += $pr.WorkingSet64 } catch { }
    }
    return [math]::Round($sum / 1MB, 0)
}

# ---------------------------------------------------------------- the loop

$cpuPrev = Get-ChainCpuSec
$cpuPrevAt = Get-Date
$pingMs = -1
$pingAt = [datetime]::MinValue
$startedAt = Get-Date
$script:seenStats = $false

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500

$render = {
    $now = Get-Date

    # ---- stream numbers from the pump
    $fpsText = '--'; $vidText = '--'
    if (Test-Path $StatsPath) {
        try {
            $stats = Get-Content $StatsPath -Raw -ErrorAction Stop | ConvertFrom-Json
            $age = ($now - [datetime]$stats.ts).TotalSeconds
            if ($age -lt 4) {
                $script:seenStats = $true
                $fpsText = '{0:0}' -f $stats.fps
                $vidText = '{0:0} Mb/s' -f $stats.mbps
            }
        } catch { }
    }

    # ---- cpu / ram of the cast chain
    $cpuText = '--'
    $cpuNow = Get-ChainCpuSec
    $dtc = ($now - $cpuPrevAt).TotalSeconds
    if ($dtc -ge 0.4) {
        $cpu = 100 * ($cpuNow - $cpuPrev) / $dtc / [Environment]::ProcessorCount
        $cpuText = '{0:0}%' -f [math]::Max($cpu, 0)
        $cpuPrev = $cpuNow
        $cpuPrevAt = $now
    }
    $ramMb = Get-ChainRamMb
    $ramText = if ($ramMb -gt 0) { '{0:0} MB' -f $ramMb } else { '--' }

    # ---- gpu
    if (($now - $gpuRefreshAt).TotalSeconds -gt 30) { Update-GpuCounters; $gpuRefreshAt = $now }
    $gpuTotal = 0.0
    foreach ($counter in @($gpuCounters.Values)) {
        try { $gpuTotal += $counter.NextValue() } catch { }
    }
    $gpuText = if ($gpuCounters.Count -gt 0) { '{0:0}%' -f [math]::Min($gpuTotal, 100) } else { '--' }

    # ---- adb reachability, every 2 s
    if (($now - $pingAt).TotalSeconds -ge 2) {
        $pingAt = $now
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync($PingHost, $PingPort)
            if ($task.Wait(500) -and $client.Connected) { $pingMs = [int]$watch.ElapsedMilliseconds } else { $pingMs = -1 }
        }
        catch { $pingMs = -1 }
        finally { try { $client.Close() } catch { } ; $watch.Stop() }
    }
    $pingText = if ($pingMs -ge 0) { "$pingMs ms" } else { 'no link' }

    $lines = @(
        ('fps {0,-4}  vid {1}' -f $fpsText, $vidText),
        ('cpu {0,-4}  ram {1,-7}' -f $cpuText, $ramText),
        ('gpu {0,-4}  ping {1}' -f $gpuText, $pingText),
        ('{0}  {1}' -f $micText, $Mode)
    )
    $label.Text = $lines -join [Environment]::NewLine

    # keep the panel exactly around the text
    $size = [System.Windows.Forms.TextRenderer]::MeasureText($label.Text, $font)
    $form.Width = $size.Width + 24
    $form.Height = $size.Height + 14

    # stick to the chosen corner (re-evaluated every tick: the video window
    # may switch the display mode, and working area moves with the taskbar)
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $margin = 14
    $x = switch ($Corner) { 'br' { $area.Right - $form.Width - $margin } 'bl' { $area.Left + $margin } 'tr' { $area.Right - $form.Width - $margin } 'tl' { $area.Left + $margin } }
    $y = switch ($Corner) { 'br' { $area.Bottom - $form.Height - $margin } 'bl' { $area.Bottom - $form.Height - $margin } 'tr' { $area.Top + $margin } 'tl' { $area.Top + $margin } }
    if ($form.Location.X -ne $x -or $form.Location.Y -ne $y) {
        $form.Location = New-Object System.Drawing.Point($x, $y)
    }

    # idle guard: nothing to watch any more -> quit. 0 disables it, which is what
    # the raw (lens:false) pipeline passes: there is no stats producer there, and
    # a self-closing HUD would just be respawned by the daemon again and again.
    if ($MaxIdle -gt 0 -and -not $script:seenStats -and ($now - $startedAt).TotalSeconds -gt $MaxIdle) { $form.Close() }

    # ---- horizon guide line is driven by its own timer, see $guideTick
}

$timer.Add_Tick($render)

# The guide line has its own timer: Show()/Hide() on state change is reliable,
# while flipping Form.Visible from a deep timer handler is not.
$script:guideShown = $false
$guideTick = {
    if (-not $guideForm) { return }
    try {
    $want = $false
    if (Test-Path $GuidePath) {
        try {
            $g = Get-Content $GuidePath -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($g.on -eq $true) { $want = $true }
        } catch { $want = $false }
    }
    if ($want -eq $script:guideShown) { return }

    if ($want) {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $guideForm.Width = [int]$screen.Width
        $guideForm.Height = 3
        $midY = [int]([int]$screen.Top + ([int]$screen.Height / 2) - 1)
        $guideForm.Location = New-Object System.Drawing.Point -ArgumentList @([int]$screen.Left, $midY)
        $guideForm.Show()
        $guideForm.TopMost = $true
        $guideForm.BringToFront()
    } else {
        $guideForm.Hide()
    }
    $script:guideShown = $want
    } catch {
        $errFile = Join-Path ([System.IO.Path]::GetTempPath()) 'quest3-guide-error.log'
        try { [System.IO.File]::AppendAllText($errFile, ((Get-Date).ToString('o') + ' ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.ScriptLineNumber + "`r`n")) } catch { }
    }
}
$guideTimer = New-Object System.Windows.Forms.Timer
$guideTimer.Interval = 250
$guideTimer.Add_Tick($guideTick)

$form.add_Shown({
    $handle = $form.Handle
    $ex = [HudNative]::GetWindowLong($handle, $GWL_EXSTYLE)
    # WS_EX_LAYERED is added by WinForms for Opacity < 1; setting it by hand here
    # makes the window render fully transparent, so only the flags below are ours.
    $null = [HudNative]::SetWindowLong($handle, $GWL_EXSTYLE,
        $ex -bor $WS_EX_TRANSPARENT -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE)

    if ($guideForm) {
        # click-through as well, otherwise the line would eat mouse clicks over
        # the player window. Keep it created but hidden until the guide is asked for.
        $guideForm.Show()
        $guideForm.Hide()
        $gh = $guideForm.Handle
        $gex = [HudNative]::GetWindowLong($gh, $GWL_EXSTYLE)
        $null = [HudNative]::SetWindowLong($gh, $GWL_EXSTYLE,
            $gex -bor $WS_EX_TRANSPARENT -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE)
        $guideTimer.Start()
    }

    $render.Invoke()
    $timer.Start()
})

[void]$form.ShowDialog()

