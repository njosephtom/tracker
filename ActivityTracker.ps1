<#
.SYNOPSIS
  Personal activity tracker for Windows PowerShell 5.1+.
  - Track   : logs the foreground application every few seconds
  - Report  : shows time spent per app, grouped by date
  - History : exports browser history (Chrome, Edge, Brave, Firefox) grouped by date

.EXAMPLES
  .\ActivityTracker.ps1 -Mode Track                 # leave running in a PowerShell window
  .\ActivityTracker.ps1 -Mode Report -Days 7
  .\ActivityTracker.ps1 -Mode History -Days 3

.NOTES
  Run only on a PC you own / have permission to monitor.
  History needs sqlite3.exe; the script installs it via winget if missing.
  Manual install:  winget install SQLite.SQLite
  (close-the-browser is NOT required; the script works on a copy of the history file)
#>
param(
    [ValidateSet('Track','Report','History')]
    [string]$Mode = 'Report',
    [int]$IntervalSeconds = 10,      # Track: sampling interval
    [int]$IdleLimitSeconds = 300,   # Track: no keyboard/mouse for this long = idle (not counted)
    [int]$Days = 7,                 # Report/History: how many days back
    [string]$OutDir = "$env:USERPROFILE\ActivityLog"
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$since = (Get-Date).Date.AddDays(-($Days - 1))

function Quote-Sql($v) { if ($null -eq $v) { 'NULL' } else { "'" + ([string]$v).Replace("'", "''") + "'" } }

# ------------------------------------------------------------ SQLITE CHECK
# Returns $true if sqlite3.exe is usable, installing it with winget if missing.
function Initialize-Sqlite {
    if (Get-Command sqlite3.exe -ErrorAction SilentlyContinue) { return $true }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return $false }
    Write-Host "sqlite3.exe not found. Installing SQLite.SQLite with winget..." -ForegroundColor Yellow
    & winget.exe install --id SQLite.SQLite -e --silent --accept-package-agreements --accept-source-agreements | Out-Host
    # refresh PATH so the new install is visible in this session
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    if (Get-Command sqlite3.exe -ErrorAction SilentlyContinue) { return $true }
    # fallback: locate the exe inside winget's package folder
    $exe = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter sqlite3.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) { $env:Path += ";$($exe.DirectoryName)"; return $true }
    return $false
}

# ------------------------------------------------------------------ TRACK
# ----------------------------------------------------------- FIREBASE
# Upserts one doc per machine per day: activity/<machine>/days/<date> -> { apps: { name: seconds } }
# ponytail: whole-day overwrite every 5 min, no delta logic; rules must restrict writes or anyone with the key can write.
function Send-Day([string]$date) {
    $f = Join-Path $OutDir "usage_$date.csv"
    if (-not (Test-Path $f)) { return }
    $apps = @{}
    Import-Csv $f | ForEach-Object { $apps[$_.App] = [int]$apps[$_.App] + [int]$_.Seconds }
    $appFields = @{}
    foreach ($k in $apps.Keys) { $appFields[$k] = @{ integerValue = "$($apps[$k])" } }
    $body = @{ fields = @{
        machine = @{ stringValue = $env:COMPUTERNAME }
        date    = @{ stringValue = $date }
        updated = @{ timestampValue = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        apps    = @{ mapValue = @{ fields = $appFields } }
    } } | ConvertTo-Json -Depth 10
    $url = "https://firestore.googleapis.com/v1/projects/tracker-b6337/databases/(default)/documents/activity/$($env:COMPUTERNAME)/days/${date}?key=AIzaSyA3ECe1AN5m1C4XO4LszBc6wj9xRkxmkmA"
    Invoke-RestMethod -Method Patch -Uri $url -Body $body -ContentType 'application/json' | Out-Null
}

function Start-Tracking {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Win32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    public static double IdleSeconds() {
        LASTINPUTINFO l = new LASTINPUTINFO(); l.cbSize = (uint)Marshal.SizeOf(l);
        GetLastInputInfo(ref l);
        return ((uint)Environment.TickCount - l.dwTime) / 1000.0;
    }
}
"@
    [void][Win32]::SetProcessDPIAware()   # real pixel coords, so monitor centres map correctly on scaled displays
    # hide the console and keep a tray icon (right-click > Exit to stop)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -Namespace Native -Name Con -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
'@
    [void][Native.Con]::ShowWindow([Native.Con]::GetConsoleWindow(), 0)
    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$PSHOME\powershell.exe")
    $tray.Text = "Activity tracker"
    $tray.Visible = $true
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    [void]$menu.Items.Add('Exit', $null, { $tray.Visible = $false; $tray.Dispose(); [Environment]::Exit(0) })
    $tray.ContextMenuStrip = $menu

    # pump tray messages while waiting for the next sample
    $next = (Get-Date).AddSeconds($IntervalSeconds)
    while ($true) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 200
        if ((Get-Date) -lt $next) { continue }
        $next = (Get-Date).AddSeconds($IntervalSeconds)

        if ([Win32]::IdleSeconds() -gt $IdleLimitSeconds) { continue }

        # one row per monitor: the top-level window under each screen's centre
        # ponytail: samples the centre pixel only; a small window off-centre on a monitor is missed
        $now = Get-Date
        $fg = [Win32]::GetForegroundWindow()
        $mon = 0
        foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
            $mon++
            $pt = New-Object Win32+POINT
            $pt.X = $s.Bounds.X + [int]($s.Bounds.Width / 2)
            $pt.Y = $s.Bounds.Y + [int]($s.Bounds.Height / 2)
            $h = [Win32]::GetAncestor([Win32]::WindowFromPoint($pt), 2)   # 2 = GA_ROOT
            # minimized windows can't be focused, so this also covers "not focused and minimized"
            # ponytail: skips the row before CSV; Firebase is built from the CSV so it skips too
            if ($h -eq [IntPtr]::Zero -or [Win32]::IsIconic($h)) { continue }
            $procId = 0
            [void][Win32]::GetWindowThreadProcessId($h, [ref]$procId)
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if (-not $p) { continue }

            [pscustomobject]@{
                Date    = $now.ToString('yyyy-MM-dd')
                Time    = $now.ToString('HH:mm:ss')
                App     = $p.ProcessName
                Seconds = $IntervalSeconds
                Monitor = $mon
                Focused = ($h -eq $fg)
            } | Export-Csv -Path (Join-Path $OutDir "usage_$($now.ToString('yyyy-MM-dd')).csv") `
                           -Append -NoTypeInformation -Encoding UTF8
        }
        try { Send-Day $now.ToString('yyyy-MM-dd') } catch { Write-Warning "Firebase: $_" }
    }
}

# ----------------------------------------------------------------- REPORT
function Show-Report {
    $files = Get-ChildItem $OutDir -Filter 'usage_*.csv' -ErrorAction SilentlyContinue |
             Where-Object { [datetime]($_.BaseName -replace 'usage_','') -ge $since }
    if (-not $files) { Write-Warning "No usage data found. Run with -Mode Track first."; return }

    $rows = $files | ForEach-Object { Import-Csv $_.FullName }
    $summary = $rows | Group-Object Date, App | ForEach-Object {
        $secs = ($_.Group | Measure-Object Seconds -Sum).Sum
        [pscustomobject]@{
            Date        = $_.Group[0].Date
            App         = $_.Group[0].App
            TotalSeconds= [int]$secs
            TimeUsed    = [timespan]::FromSeconds($secs).ToString('hh\:mm\:ss')
        }
    } | Sort-Object Date, @{Expression='TotalSeconds';Descending=$true}

    foreach ($d in $summary | Group-Object Date) {
        # active time counts each sample once, not once per monitor
        $samples = $rows | Where-Object Date -eq $d.Name | Group-Object Time | ForEach-Object { [int]$_.Group[0].Seconds }
        $total = [timespan]::FromSeconds(($samples | Measure-Object -Sum).Sum)
        Write-Host "`n=== $($d.Name)   (active: $($total.ToString('hh\:mm\:ss'))) ===" -ForegroundColor Cyan
        $d.Group | Format-Table App, TimeUsed -AutoSize
    }
    $out = Join-Path $OutDir "app_usage_summary.csv"
    $summary | Export-Csv $out -NoTypeInformation -Encoding UTF8
    Write-Host "Summary saved: $out" -ForegroundColor Green
}

# ---------------------------------------------------------------- HISTORY
function Invoke-SqliteCopy($dbPath, $sql) {
    $tmpDir = Join-Path $env:TEMP ("hist_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpDir | Out-Null
    $name = Split-Path $dbPath -Leaf
    Copy-Item $dbPath (Join-Path $tmpDir $name)
    foreach ($ext in '-wal','-shm') {            # include recent, not-yet-flushed visits
        if (Test-Path "$dbPath$ext") { Copy-Item "$dbPath$ext" (Join-Path $tmpDir "$name$ext") }
    }
    try {
        $csv = $sql | & sqlite3.exe -csv -header (Join-Path $tmpDir $name)
        if ($csv) { $csv | ConvertFrom-Csv }
    } finally { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-BrowserHistory {
    if (-not (Initialize-Sqlite)) {
        throw "sqlite3.exe could not be found or installed. Install manually with:  winget install SQLite.SQLite"
    }
    $from = $since.ToString('yyyy-MM-dd')

    $chromiumSql = @"
SELECT datetime(v.visit_time/1000000-11644473600,'unixepoch','localtime') AS VisitTime,
       u.title AS Title, u.url AS Url
FROM visits v JOIN urls u ON u.id = v.url
WHERE date(v.visit_time/1000000-11644473600,'unixepoch','localtime') >= '$from'
ORDER BY v.visit_time;
"@
    $firefoxSql = @"
SELECT datetime(h.visit_date/1000000,'unixepoch','localtime') AS VisitTime,
       p.title AS Title, p.url AS Url
FROM moz_historyvisits h JOIN moz_places p ON p.id = h.place_id
WHERE date(h.visit_date/1000000,'unixepoch','localtime') >= '$from'
ORDER BY h.visit_date;
"@

    $chromium = @{
        Chrome = "$env:LOCALAPPDATA\Google\Chrome\User Data"
        Edge   = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
        Brave  = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
    }
    $all = @()
    foreach ($b in $chromium.GetEnumerator()) {
        if (-not (Test-Path $b.Value)) { continue }
        Get-ChildItem $b.Value -Directory | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } | ForEach-Object {
            $db = Join-Path $_.FullName 'History'
            if ((Test-Path $db) -and (Get-Item $db).Length -gt 0) {   # skip empty/unused profiles
                Invoke-SqliteCopy $db $chromiumSql | ForEach-Object {
                    $_ | Add-Member Browser $b.Key -PassThru
                } | ForEach-Object { $all += $_ }
            }
        }
    }
    $ffRoot = "$env:APPDATA\Mozilla\Firefox\Profiles"
    if (Test-Path $ffRoot) {
        Get-ChildItem $ffRoot -Directory | ForEach-Object {
            $db = Join-Path $_.FullName 'places.sqlite'
            if ((Test-Path $db) -and (Get-Item $db).Length -gt 0) {   # skip empty/unused profiles
                Invoke-SqliteCopy $db $firefoxSql | ForEach-Object {
                    $_ | Add-Member Browser 'Firefox' -PassThru
                } | ForEach-Object { $all += $_ }
            }
        }
    }
    $all
}

function Show-History {
    $hist = Get-BrowserHistory | ForEach-Object {
        $_ | Add-Member Date ($_.VisitTime.Substring(0,10)) -PassThru |
             Add-Member Domain ([uri]$_.Url).Host -PassThru
    } | Sort-Object VisitTime

    if (-not $hist) { Write-Warning "No history found for the last $Days day(s)."; return }

    foreach ($d in $hist | Group-Object Date) {
        Write-Host "`n=== $($d.Name)  -  $($d.Count) page visits ===" -ForegroundColor Cyan
        Write-Host "Top sites:" -ForegroundColor Yellow
        $d.Group | Group-Object Domain | Sort-Object Count -Descending | Select-Object -First 10 |
            Format-Table @{n='Visits';e={$_.Count}}, @{n='Domain';e={$_.Name}} -AutoSize
    }
    # Store in SQLite (dedupes on browser+time+url, so re-running is safe)
    $db = Join-Path $OutDir 'history.db'
    $sql = New-Object System.Text.StringBuilder
    [void]$sql.AppendLine("CREATE TABLE IF NOT EXISTS visits (browser TEXT, visit_time TEXT, date TEXT, domain TEXT, title TEXT, url TEXT, UNIQUE(browser, visit_time, url));")
    [void]$sql.AppendLine("BEGIN;")
    foreach ($h in $hist) {
        [void]$sql.AppendLine("INSERT OR IGNORE INTO visits VALUES ($(Quote-Sql $h.Browser),$(Quote-Sql $h.VisitTime),$(Quote-Sql $h.Date),$(Quote-Sql $h.Domain),$(Quote-Sql $h.Title),$(Quote-Sql $h.Url));")
    }
    [void]$sql.AppendLine("COMMIT;")
    $sql.ToString() | & sqlite3.exe $db
    if ($LASTEXITCODE -ne 0) { throw "sqlite3 failed writing $db" }
    Write-Host "`nHistory stored in SQLite: $db  (table: visits, $($hist.Count) rows read)" -ForegroundColor Green
}

switch ($Mode) {
    'Track'   { Start-Tracking }
    'Report'  { Show-Report }
    'History' { Show-History }
}
