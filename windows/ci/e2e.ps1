# End-to-end test on a real Windows desktop (GitHub windows runner).
# Starts Ogen with a prepared state and checks that it really blocks.
param([Parameter(Mandatory)][string]$Exe, [string]$Out = "release/windows/shots")

$ErrorActionPreference = 'Stop'
$Exe = (Resolve-Path $Exe).Path
New-Item -ItemType Directory -Force $Out | Out-Null
$data = Join-Path $env:RUNNER_TEMP 'ogen-data'
New-Item -ItemType Directory -Force $data | Out-Null
$env:OGEN_DATA = $data
$state = Join-Path $data 'state.txt'
$report = [System.Collections.Generic.List[string]]::new()
$failed = 0

Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] struct MI { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] struct IN { public uint type; public MI mi; }
  [DllImport("user32.dll")] static extern uint SendInput(uint n, IN[] i, int size);
  public static void Wiggle() { var i = new IN[] { new IN { type = 0, mi = new MI { dx = 1, flags = 1 } }, new IN { type = 0, mi = new MI { dx = -1, flags = 1 } } }; SendInput(2, i, Marshal.SizeOf(typeof(IN))); }
}
"@

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    $line = ($(if ($ok) { 'PASS' } else { 'FAIL' })) + "  $name  $detail"
    Write-Host $line
    $report.Add($line)
    if (-not $ok) { $script:failed++ }
}

function Shot([string]$name) {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $bmp.Save((Join-Path $Out "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
}

# limit/used in minutes (-1 = no limit), social 1/0, allowed = comma list of process names,
# checkIn 1/0, session = minutes left in an active session (0 = none)
function Set-State([long]$limit, [long]$used, [int]$social, [string]$allowed = '', [int]$checkIn = 0, [long]$session = 0) {
    Get-Process Ogen -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    $today = [DateTimeOffset]::new([DateTime]::Today).ToUnixTimeMilliseconds()
    $l = if ($limit -lt 0) { -1 } else { $limit * 60000 }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $boot = $now - [Environment]::TickCount64
    $end = if ($session -gt 0) { $now + $session * 60000 } else { 0 }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('test'))
    $text = "ogen-state 1`n1`n0`n0`n-1`nw2`n$l`n$($used * 60000)`n$today`n$social`n$allowed`n$checkIn`n$now`n$end`n$boot`n$b64`n$b64`n"
    [IO.File]::WriteAllText($state, $text)
    Start-Process $Exe -ArgumentList '--no-install', '--background'
    Start-Sleep -Seconds 3
}

function Used-Minutes {
    $lines = [IO.File]::ReadAllText($state) -split "`n"
    return [double]$lines[7] / 60000
}

# a local page whose title looks like YouTube: no network needed
$page = Join-Path $env:RUNNER_TEMP 'yt.html'
[IO.File]::WriteAllText($page, '<html><head><title>Funny cats - YouTube</title></head><body><h1>video</h1></body></html>')
$chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1

# ---- 1. social site in a browser: the tab is closed ----
Set-State -1 0 1
if ($chrome) {
    $profileDir = Join-Path $env:RUNNER_TEMP 'chrome-profile'
    Start-Process $chrome -ArgumentList "--user-data-dir=$profileDir", '--no-first-run', '--no-default-browser-check', '--new-window', "file:///$($page -replace '\\','/')"
    Start-Sleep -Seconds 6
    Shot 'e2e-01-site-blocked'
    $open = Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match 'YouTube' }
    Check 'YouTube tab is closed in Chrome' (-not $open) ($open | ForEach-Object MainWindowTitle | Out-String).Trim()
    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
} else {
    $report.Add('SKIP  Chrome not installed')
}

# ---- 2. a normal app is fine without a limit ----
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 3
$np.Refresh()
Check 'Notepad stays open with no limit' (-not [W]::IsIconic($np.MainWindowHandle))
$np | Stop-Process -Force

# ---- 3. time is up: other apps are minimized and covered ----
Set-State 30 30 1
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 4
$np.Refresh()
Shot 'e2e-02-time-up-cover'
Check 'Notepad is minimized when time is up' ([W]::IsIconic($np.MainWindowHandle))
$np | Stop-Process -Force

# ---- 4. ... unless it is "always open" ----
Set-State 30 30 1 'notepad'
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 4
$np.Refresh()
Check 'An always-open app keeps working when time is up' (-not [W]::IsIconic($np.MainWindowHandle))
$np | Stop-Process -Force

# ---- 5. screen time counts down while an app is used ----
Set-State 60 0 1
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 1
$np.Refresh()
[W]::SetForegroundWindow($np.MainWindowHandle) | Out-Null
for ($i = 0; $i -lt 36; $i++) { [W]::Wiggle(); Start-Sleep -Seconds 1 }
$used = Used-Minutes
Check 'Usage is counted while using an app' ($used -ge 0.4) ("used {0:N2} min" -f $used)
$np | Stop-Process -Force

# ---- 6. check-in: nothing works until you answer ----
Set-State -1 0 1 '' 1 0
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 4
$np.Refresh()
Shot 'e2e-04-checkin'
Check 'Without a session, apps are put away behind the question' ([W]::IsIconic($np.MainWindowHandle))
$np | Stop-Process -Force

# ---- 7. ... and with a session running, they work ----
Set-State -1 0 1 '' 1 30
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 4
$np.Refresh()
Check 'During a session, apps work' (-not [W]::IsIconic($np.MainWindowHandle))
$np | Stop-Process -Force

# ---- 8. a blocked site whose tab title doesn't name it: caught by the address bar ----
if ($chrome) {
    Set-State -1 0 1
    $profileDir = Join-Path $env:RUNNER_TEMP 'chrome-profile2'
    Start-Process $chrome -ArgumentList "--user-data-dir=$profileDir", '--no-first-run', '--no-default-browser-check', '--new-window',
        '--host-resolver-rules="MAP www.reddit.com 127.0.0.1:9"', 'https://www.reddit.com/'
    Start-Sleep -Seconds 10
    $open = Get-Process chrome -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match 'reddit' }
    Check 'Address-bar check closes a reddit tab with a plain title' (-not $open) ($open | ForEach-Object MainWindowTitle | Out-String).Trim()
    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
}

# ---- 9. the window opens and shows the remaining time ----
Start-Process $Exe -ArgumentList '--no-install'
Start-Sleep -Seconds 3
Shot 'e2e-03-window'
$win = Get-Process Ogen | Where-Object { $_.MainWindowHandle -ne 0 }
Check 'Main window opens' ([bool]$win)

Get-Process Ogen -ErrorAction SilentlyContinue | Stop-Process -Force
if (Test-Path (Join-Path $data 'log.txt')) { Copy-Item (Join-Path $data 'log.txt') (Join-Path $Out 'e2e-log.txt') }
$report | Set-Content (Join-Path $Out 'e2e-report.txt')
if ($failed -gt 0) { Write-Host "$failed check(s) failed"; exit 1 }
