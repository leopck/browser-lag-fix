#Requires -Version 5.1
<#
.SYNOPSIS
    Detects sudden free-space dips on a drive (the signature of an OPFS truncate probe) and records
    what was going on, optionally saving a Windows Performance Recorder flight-recorder trace.

.DESCRIPTION
    Polls free space every -IntervalSeconds. When it falls -DropGB or more below the highest reading
    of the last five minutes, it logs a DIP START with recently written Chromium site-storage folders
    (mapped to their site origin) and, if -SaveTrace is given, stops/saves/re-arms a WPR trace that
    was started with diagnostics\opfs-guard.wprp in memory (flight-recorder) mode.

.EXAMPLE
    # Elevated, once:
    wpr -start .\diagnostics\opfs-guard.wprp
    .\diagnostics\Watch-FreeSpace.ps1 -SaveTrace -OutputDirectory $env:USERPROFILE\OpfsTraces

.NOTES
    Open saved .etl files in Windows Performance Analyzer: Storage > File I/O, filter Type = SetInfo /
    "Resize", sort by Size. Look for browser processes resizing files under "...\File System\NNN\t\".
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]$')][string]$Drive = $env:SystemDrive.TrimEnd(':'),
    [ValidateRange(1, 100000)][double]$DropGB = 50,
    [ValidateRange(1, 60)][int]$IntervalSeconds = 2,
    [string]$OutputDirectory = (Join-Path $env:USERPROFILE 'OpfsGuardDiagnostics'),
    [switch]$SaveTrace,
    [string]$WprProfile = (Join-Path $PSScriptRoot 'opfs-guard.wprp')
)

Set-StrictMode -Version Latest
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$log = Join-Path $OutputDirectory 'free-space.log'

function Write-WatchLog([string]$m) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $m
    Add-Content -LiteralPath $log -Value $line -Encoding utf8
    Write-Information $line -InformationAction Continue
}
function Get-FreeGB { [math]::Round((Get-PSDrive $Drive).Free / 1GB, 1) }

function Get-RecentSiteStorage {
    # Chromium keeps an "Origins" leveldb that maps the numbered folders to site origins.
    $roots = Get-ChildItem -Path $env:LOCALAPPDATA -Directory -Depth 3 -Filter 'User Data' -ErrorAction SilentlyContinue
    foreach ($ud in $roots) {
        foreach ($fsDir in Get-ChildItem -LiteralPath $ud.FullName -Directory -Depth 1 -Filter 'File System' -ErrorAction SilentlyContinue) {
            $map = @{}
            Get-ChildItem -LiteralPath (Join-Path $fsDir.FullName 'Origins') -File -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $fs = [IO.File]::Open($_.FullName, 'Open', 'Read', 'ReadWrite')
                    try { $ms = New-Object IO.MemoryStream; $fs.CopyTo($ms) } finally { $fs.Dispose() }
                    $text = [Text.Encoding]::ASCII.GetString($ms.ToArray())
                    foreach ($m in [regex]::Matches($text, 'ORIGIN:([\x20-\x7e]+?)[\x00-\x1f]{1,4}(\d{3})')) { $map[$m.Groups[2].Value] = $m.Groups[1].Value }
                } catch { Write-Verbose "origins read failed: $_" }
            }
            Get-ChildItem -LiteralPath $fsDir.FullName -Directory -ErrorAction SilentlyContinue | Where-Object Name -match '^\d{3}$' | ForEach-Object {
                $newest = Get-ChildItem -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($newest -and $newest.LastWriteTime -gt (Get-Date).AddMinutes(-5)) {
                    '{0}\{1} = {2} (written {3:HH:mm:ss})' -f $fsDir.Parent.Name, $_.Name, $(if ($map[$_.Name]) { $map[$_.Name] } else { '?' }), $newest.LastWriteTime
                }
            }
        }
    }
}

if ($SaveTrace -and -not (Test-Path -LiteralPath $WprProfile)) { throw "WPR profile not found: $WprProfile" }
Write-WatchLog "watching ${Drive}: (drop >= $DropGB GB), free=$(Get-FreeGB) GB"
$history = New-Object System.Collections.Generic.Queue[double]
$windowSamples = [int](300 / $IntervalSeconds)
$inDip = $false; $minFree = 0.0
while ($true) {
    $free = Get-FreeGB
    $baseline = if ($history.Count) { ($history | Measure-Object -Maximum).Maximum } else { $free }
    if (-not $inDip -and $free -le $baseline - $DropGB) {
        $inDip = $true; $minFree = $free
        Write-WatchLog "DIP START free=$free GB (baseline $baseline GB)"
        foreach ($s in Get-RecentSiteStorage) { Write-WatchLog "  site storage $s" }
        if ($SaveTrace) {
            $etl = Join-Path $OutputDirectory ('dip-{0:yyyyMMdd-HHmmss}.etl' -f (Get-Date))
            $out = & wpr.exe -stop $etl 'free-space dip' -skipPdbGen 2>&1
            Write-WatchLog "  trace: $etl ($($out | Select-Object -Last 1))"
            $null = & wpr.exe -start $WprProfile 2>&1
        }
    } elseif ($inDip) {
        $minFree = [math]::Min($minFree, $free)
        if ($free -ge $baseline - 5) { $inDip = $false; Write-WatchLog "DIP END free=$free GB (min $minFree GB)" }
    } else {
        $history.Enqueue($free); while ($history.Count -gt $windowSamples) { [void]$history.Dequeue() }
    }
    Start-Sleep -Seconds $IntervalSeconds
}
