#Requires -Version 7.0
<#
.SYNOPSIS
    End-to-end test of the extension in a real Chromium browser, using throwaway profiles.

.DESCRIPTION
    Serves repro/probe.html locally and runs four scenarios against a browser started with the
    unpacked extension (--load-extension):
      A  fresh install, probe page opened at launch      (install race)
      B  browser restart, probe page opened at launch    (session-restore race)
      C  probe page opened in the running browser
      D  full 8 TiB probe with no delay
    Each scenario must converge on the configured cap (10 GiB). A/B/C start at 64 GiB, so a
    failure can never reserve more than 64 GiB. D starts at 8 TiB and only runs if A-C passed.

    Microsoft Edge honours --load-extension. Google Chrome stable (137+) ignores it; use
    Chrome for Testing or Chromium with -BrowserPath.

.EXAMPLE
    pwsh tests/e2e/Invoke-ExtensionE2E.ps1
#>
[CmdletBinding()]
param(
    [string]$BrowserPath = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    [int]$Port = 8799,
    [double]$ExpectedCapGiB = 10
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$ext = Join-Path $repo 'extension'
$work = Join-Path ([IO.Path]::GetTempPath()) ('opfsguard-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$results = Join-Path $work 'results.jsonl'
New-Item -ItemType Directory -Path $work | Out-Null
if (-not (Test-Path $BrowserPath)) { throw "Browser not found: $BrowserPath" }

$server = Start-Process -FilePath python -ArgumentList @((Join-Path $repo 'repro\serve.py'), '--port', $Port, '--results', $results) -PassThru -WindowStyle Hidden
$profileDir = Join-Path $work 'profile'

function Stop-TestBrowser {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess($profileDir, 'Stop test browser')) { return }
    Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -like "*$profileDir*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
}

function Invoke-Scenario([string]$Name, [string]$Query, [double]$CapGiB) {
    Remove-Item $results -ErrorAction SilentlyContinue
    $url = "http://127.0.0.1:$Port/probe.html?$Query"
    $argList = @("--user-data-dir=$profileDir", '--no-first-run', '--no-default-browser-check', "--load-extension=$ext", '--new-window', $url)
    Start-Process -FilePath $BrowserPath -ArgumentList $argList | Out-Null
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline -and -not ((Test-Path $results) -and (Select-String $results -Pattern '"op": "done"|"op": "fatal"' -Quiet))) { Start-Sleep 1 }
    if (-not (Test-Path $results)) { return [pscustomobject]@{ Scenario = $Name; LargestGiB = $null; Pass = $false; Steps = 'no result' } }
    $rows = Get-Content $results | ConvertFrom-Json
    $largest = ($rows | Where-Object op -eq 'done').largestAcceptedGiB
    [pscustomobject]@{
        Scenario   = $Name
        LargestGiB = $largest
        Pass       = ($largest -le $CapGiB -and $largest -ge $CapGiB * 0.98)
        Steps      = ($rows | Where-Object op -eq 'truncate' | ForEach-Object { '{0}{1}' -f $_.gib, $(if ($_.ok) { '+' } else { '-' }) }) -join ' '
    }
}

try {
    Start-Sleep 1
    $out = @()
    $out += Invoke-Scenario 'A fresh install, page at launch' 'start=64&delay=3000&s=a' $ExpectedCapGiB
    Stop-TestBrowser
    $out += Invoke-Scenario 'B restart, page at launch' 'start=64&delay=3000&s=b' $ExpectedCapGiB
    $out += Invoke-Scenario 'C page in running browser' 'start=64&delay=3000&s=c' $ExpectedCapGiB
    if (@($out | Where-Object { -not $_.Pass }).Count -eq 0) {
        $out += Invoke-Scenario 'D full 8 TiB probe, no delay' 's=d' $ExpectedCapGiB
    }
    $out | Format-Table -AutoSize -Wrap
    if (@($out | Where-Object { -not $_.Pass }).Count) { throw 'End-to-end test failed.' }
    Write-Information 'All scenarios converged on the cap.' -InformationAction Continue
} finally {
    Stop-TestBrowser
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
