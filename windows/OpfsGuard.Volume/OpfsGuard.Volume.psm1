#Requires -Version 5.1
<#
    OpfsGuard.Volume - confine Chromium site file storage to a small virtual disk.

    Chromium-based browsers keep each profile's sandboxed site files (Origin Private File System
    and the legacy webkitRequestFileSystem store) in "<User Data>\<Profile>\File System". On Windows
    a page can grow one of those files to ~60% of the system drive, and NTFS reserves the space
    immediately, briefly filling the drive and stalling all disk writes. This module moves that
    folder onto a dedicated, size-capped VHDX and leaves a junction in its place, so a probe can
    only ever fill the virtual disk.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StateFileName = 'opfsguard.json'
$script:AttachTaskName = 'OpfsGuard-Attach'
$script:ReconcileTaskName = 'OpfsGuard-Reconcile'
$script:TaskPath = '\OpfsGuard\'
$script:VolumeLabel = 'OpfsGuard'
$script:DefaultRoot = Join-Path $env:SystemDrive 'OpfsGuard'

# Known Chromium browsers: user-data root (relative to %LOCALAPPDATA%) and the process image name.
$script:KnownBrowsers = [ordered]@{
    'Edge'        = @{ Root = 'Microsoft\Edge\User Data';              Process = 'msedge' }
    'Edge Beta'   = @{ Root = 'Microsoft\Edge Beta\User Data';         Process = 'msedge' }
    'Edge Dev'    = @{ Root = 'Microsoft\Edge Dev\User Data';          Process = 'msedge' }
    'Edge Canary' = @{ Root = 'Microsoft\Edge SxS\User Data';          Process = 'msedge' }
    'Chrome'      = @{ Root = 'Google\Chrome\User Data';               Process = 'chrome' }
    'Chrome Beta' = @{ Root = 'Google\Chrome Beta\User Data';          Process = 'chrome' }
    'Chrome Dev'  = @{ Root = 'Google\Chrome Dev\User Data';           Process = 'chrome' }
    'Brave'       = @{ Root = 'BraveSoftware\Brave-Browser\User Data'; Process = 'brave' }
    'Vivaldi'     = @{ Root = 'Vivaldi\User Data';                     Process = 'vivaldi' }
}

#region helpers --------------------------------------------------------------------------------

function Write-OpfsLog {
    param([Parameter(Mandatory)][string]$Message, [string]$Root = $script:DefaultRoot, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    Write-Verbose $line
    if (Test-Path -LiteralPath $Root) {
        try { Add-Content -LiteralPath (Join-Path $Root 'opfsguard.log') -Value $line -Encoding utf8 } catch { Write-Verbose "log write failed: $_" }
    }
}

function Test-OpfsIsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-OpfsAdmin {
    if (-not (Test-OpfsIsAdmin)) { throw 'This operation needs an elevated (Run as administrator) PowerShell.' }
}

function Get-OpfsState {
    param([Parameter(Mandatory)][string]$Root)
    $p = Join-Path $Root $script:StateFileName
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
}

function Save-OpfsState {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)]$State)
    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Root $script:StateFileName) -Encoding utf8
}

function Get-OpfsItemStatistic {
    param([Parameter(Mandatory)][string]$Path)
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)
    [pscustomobject]@{ Count = $files.Count; Bytes = [long](($files | Measure-Object Length -Sum).Sum) }
}

function Get-OpfsLinkTarget {
    param([Parameter(Mandatory)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or -not $item.LinkType) { return $null }
    $t = $item.Target
    if ($t -is [array]) { $t = $t[0] }
    return ([string]$t) -replace '^\\\\\?\\', ''
}

function Move-OpfsDirectory {
    <# Moves a directory tree with verification; never deletes the source until the copy matches. #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    $before = Get-OpfsItemStatistic -Path $Source
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $null = & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed copying '$Source' (exit $LASTEXITCODE)." }
    $after = Get-OpfsItemStatistic -Path $Destination
    if ($after.Count -lt $before.Count -or $after.Bytes -lt $before.Bytes) {
        throw "Verification failed for '$Source': copied $($after.Count)/$($before.Count) files, $($after.Bytes)/$($before.Bytes) bytes. Source left untouched."
    }
    Remove-Item -LiteralPath $Source -Recurse -Force
    return $before
}

#endregion

#region discovery ------------------------------------------------------------------------------

function Get-OpfsBrowserProfile {
    <#
    .SYNOPSIS
        Lists Chromium browser profiles and where each one's site file storage lives.
    .PARAMETER Browser
        Limit to these browsers (names from the built-in list, e.g. 'Edge','Chrome'). Default: all installed.
    .PARAMETER UserDataRoot
        Inspect an explicit "User Data" directory instead (reported with Browser = 'Custom').
    .PARAMETER Root
        OpfsGuard install root, used to classify redirected profiles. Default: %SystemDrive%\OpfsGuard.
    .OUTPUTS
        Objects with Browser, Profile, UserDataRoot, FileSystemPath, State, Target.
        State is one of: Local, Redirected, RedirectedElsewhere, Missing.
    #>
    [CmdletBinding()]
    param([string[]]$Browser, [string[]]$UserDataRoot, [string]$Root = $script:DefaultRoot)

    $roots = @()
    if ($UserDataRoot) {
        # Recognise known browsers by exact path so process checks and labels stay correct.
        $roots = $UserDataRoot | ForEach-Object {
            $path = [IO.Path]::GetFullPath($_).TrimEnd('\')
            $known = $script:KnownBrowsers.Keys | Where-Object { (Join-Path $env:LOCALAPPDATA $script:KnownBrowsers[$_].Root) -ieq $path } | Select-Object -First 1
            if ($known) { [pscustomobject]@{ Browser = $known; Path = $path; Process = $script:KnownBrowsers[$known].Process } }
            else { [pscustomobject]@{ Browser = 'Custom'; Path = $path; Process = $null } }
        }
    } else {
        foreach ($name in $script:KnownBrowsers.Keys) {
            if ($Browser -and $name -notin $Browser) { continue }
            $p = Join-Path $env:LOCALAPPDATA $script:KnownBrowsers[$name].Root
            if (Test-Path -LiteralPath $p) { $roots += [pscustomobject]@{ Browser = $name; Path = $p; Process = $script:KnownBrowsers[$name].Process } }
        }
    }
    $mount = Join-Path $Root 'mnt'
    foreach ($r in $roots) {
        $profiles = Get-ChildItem -LiteralPath $r.Path -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Preferences') }
        foreach ($p in $profiles) {
            $fs = Join-Path $p.FullName 'File System'
            $target = Get-OpfsLinkTarget -Path $fs
            $state = if (-not (Test-Path -LiteralPath $fs)) { if ($target) { 'Redirected' } else { 'Missing' } }
                     elseif ($target) { if ($target.StartsWith($mount, [StringComparison]::OrdinalIgnoreCase)) { 'Redirected' } else { 'RedirectedElsewhere' } }
                     else { 'Local' }
            [pscustomobject]@{
                PSTypeName     = 'OpfsGuard.Profile'
                Browser        = $r.Browser
                Profile        = $p.Name
                UserDataRoot   = $r.Path
                FileSystemPath = $fs
                State          = $state
                Target         = $target
                Process        = $r.Process
            }
        }
    }
}

function Test-OpfsBrowserRunning {
    <# True if any process for the given browser profile set is running. Custom roots are never considered running. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Profiles)
    $names = @($Profiles | Where-Object Process | Select-Object -ExpandProperty Process -Unique)
    if (-not $names) { return $false }
    return [bool](Get-Process -Name $names -ErrorAction SilentlyContinue)
}

#endregion

#region volume ---------------------------------------------------------------------------------

function Mount-OpfsVolume {
    <#
    .SYNOPSIS
        Attaches the OpfsGuard VHDX and makes sure it is mounted at <Root>\mnt. Idempotent.
        Used by the startup scheduled task; needs administrator rights.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Root = $script:DefaultRoot)
    Assert-OpfsAdmin
    $state = Get-OpfsState -Root $Root
    if (-not $state) { throw "No OpfsGuard installation found at '$Root'." }
    $img = Get-DiskImage -ImagePath $state.VhdPath
    if (-not $img.Attached) {
        if ($PSCmdlet.ShouldProcess($state.VhdPath, 'Attach virtual disk')) {
            $img = Mount-DiskImage -ImagePath $state.VhdPath -NoDriveLetter -PassThru
            Write-OpfsLog -Root $Root "Attached $($state.VhdPath)"
        }
    }
    $part = $img | Get-Disk | Get-Partition | Where-Object Type -ne 'Reserved' | Select-Object -First 1
    $mount = Join-Path $Root 'mnt'
    $paths = @($part.AccessPaths) | ForEach-Object { $_.TrimEnd('\') }
    if ($mount -notin $paths -and $PSCmdlet.ShouldProcess($mount, 'Add mount point')) {
        New-Item -ItemType Directory -Force -Path $mount | Out-Null
        Add-PartitionAccessPath -InputObject $part -AccessPath "$mount\"
        Write-OpfsLog -Root $Root "Mounted volume at $mount"
    }
}

function New-OpfsVirtualDisk {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$VhdPath, [Parameter(Mandatory)][int]$SizeMB, [Parameter(Mandatory)][string]$MountPath)
    if (-not $PSCmdlet.ShouldProcess($VhdPath, "Create and format $SizeMB MB virtual disk")) { return }
    $script = Join-Path ([IO.Path]::GetTempPath()) ("opfsguard-create-{0}.txt" -f [guid]::NewGuid())
    "create vdisk file=`"$VhdPath`" maximum=$SizeMB type=expandable" | Set-Content -LiteralPath $script -Encoding ascii
    try {
        $out = & diskpart.exe /s $script
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $VhdPath)) { throw "diskpart could not create '$VhdPath':`n$($out -join "`n")" }
    } finally { Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue }
    $img = Mount-DiskImage -ImagePath $VhdPath -NoDriveLetter -PassThru
    $disk = $img | Get-Disk
    Initialize-Disk -InputObject $disk -PartitionStyle GPT -ErrorAction SilentlyContinue
    $part = New-Partition -InputObject $disk -UseMaximumSize
    $null = Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel $script:VolumeLabel -Confirm:$false
    New-Item -ItemType Directory -Force -Path $MountPath | Out-Null
    Add-PartitionAccessPath -InputObject $part -AccessPath "$MountPath\"
    # Marker proves the real volume (not the empty mount-point folder) is present.
    Set-Content -LiteralPath (Join-Path $MountPath '.opfsguard-volume') -Value 'OpfsGuard site-storage volume. Do not delete.' -Encoding ascii
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $null = & icacls.exe "$MountPath\" /grant "${user}:(OI)(CI)F" /Q
}

#endregion

#region profile moves --------------------------------------------------------------------------

function Get-OpfsProfileKey {
    <# Stable, collision-free folder name for a profile on the volume, e.g. "Edge-1a2b3c4d\Default". #>
    param([Parameter(Mandatory)]$ProfileInfo)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ProfileInfo.UserDataRoot.ToLowerInvariant()))[0..3] | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    $label = ($ProfileInfo.Browser -replace '[^A-Za-z0-9]', '')
    return Join-Path "$label-$hash" $ProfileInfo.Profile
}

function Test-OpfsVolumeMounted {
    param([Parameter(Mandatory)][string]$Root)
    return Test-Path -LiteralPath (Join-Path $Root 'mnt\.opfsguard-volume')
}

function Move-OpfsProfileToVolume {
    param([Parameter(Mandatory)]$ProfileInfo, [Parameter(Mandatory)][string]$Root)
    if (-not (Test-OpfsVolumeMounted -Root $Root)) { throw "The OpfsGuard volume is not mounted at '$Root\mnt'." }
    $dest = Join-Path (Join-Path (Join-Path $Root 'mnt') (Get-OpfsProfileKey -ProfileInfo $ProfileInfo)) 'File System'
    $src = $ProfileInfo.FileSystemPath
    if (Test-Path -LiteralPath $src) {
        $stats = Move-OpfsDirectory -Source $src -Destination $dest
    } else {
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        $stats = [pscustomobject]@{ Count = 0; Bytes = 0 }
    }
    try {
        New-Item -ItemType Junction -Path $src -Target $dest | Out-Null
    } catch {
        # Put the data back so the browser keeps working.
        Move-OpfsDirectory -Source $dest -Destination $src | Out-Null
        throw "Could not create junction at '$src': $_"
    }
    Write-OpfsLog -Root $Root "Redirected $($ProfileInfo.Browser)/$($ProfileInfo.Profile): $($stats.Count) files, $($stats.Bytes) bytes -> $dest"
    return $dest
}

function Restore-OpfsProfileFromVolume {
    param([Parameter(Mandatory)]$ProfileInfo, [Parameter(Mandatory)][string]$Root)
    $src = $ProfileInfo.FileSystemPath
    $target = $ProfileInfo.Target
    # Remove only the junction itself, never the target's contents.
    [IO.Directory]::Delete($src, $false)
    if ($target -and (Test-Path -LiteralPath $target)) {
        Move-OpfsDirectory -Source $target -Destination $src | Out-Null
    } else {
        New-Item -ItemType Directory -Force -Path $src | Out-Null
    }
    Write-OpfsLog -Root $Root "Restored $($ProfileInfo.Browser)/$($ProfileInfo.Profile) to $src"
}

#endregion

#region public commands ------------------------------------------------------------------------

function Install-OpfsGuardVolume {
    <#
    .SYNOPSIS
        Creates a size-capped virtual disk and moves Chromium site file storage onto it.
    .DESCRIPTION
        1. Creates <Root>\opfsguard.vhdx (dynamically expanding, NTFS) and mounts it at <Root>\mnt.
        2. Registers a startup task (SYSTEM) that re-attaches it on every boot, and a logon task that
           redirects profiles created later.
        3. For every profile of the selected browsers, moves "File System" onto the volume and leaves
           a junction in its place. Browsers must be closed.
        Safe to re-run: existing volume and already-redirected profiles are left alone.
    .PARAMETER SizeGB
        Capacity of the virtual disk. Bounds the largest file a site can create. Default 20.
    .EXAMPLE
        Install-OpfsGuardVolume -Browser Edge,Chrome
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [ValidateRange(0.1, 1024)][double]$SizeGB = 20,
        [string]$Root = $script:DefaultRoot,
        [string[]]$Browser,
        [string[]]$UserDataRoot,
        [switch]$SkipScheduledTasks
    )
    Assert-OpfsAdmin
    $Root = [IO.Path]::GetFullPath($Root)
    $profiles = @(Get-OpfsBrowserProfile -Browser $Browser -UserDataRoot $UserDataRoot -Root $Root)
    if (-not $profiles) { throw 'No Chromium browser profiles found.' }
    if (Test-OpfsBrowserRunning -Profiles $profiles) {
        throw "Close these browsers first (including background processes): $((($profiles | Where-Object Process).Browser | Select-Object -Unique) -join ', ')."
    }

    $vhd = Join-Path $Root 'opfsguard.vhdx'
    $mount = Join-Path $Root 'mnt'
    $state = Get-OpfsState -Root $Root
    if (-not $state) {
        if (-not $PSCmdlet.ShouldProcess($vhd, "Create $SizeGB GB virtual disk")) { return }
        New-Item -ItemType Directory -Force -Path $Root | Out-Null
        New-OpfsVirtualDisk -VhdPath $vhd -SizeMB ([int][math]::Ceiling($SizeGB * 1024)) -MountPath $mount
        $state = [pscustomobject]@{ Version = 1; VhdPath = $vhd; MountPath = $mount; SizeGB = $SizeGB; Created = (Get-Date).ToString('o'); UserDataRoots = @() }
        Write-OpfsLog -Root $Root "Created $vhd ($SizeGB GB) mounted at $mount"
    } else {
        Mount-OpfsVolume -Root $Root
    }
    $state.UserDataRoots = @(@($state.UserDataRoots) + @($profiles.UserDataRoot) | Select-Object -Unique)
    Save-OpfsState -Root $Root -State $state

    # Lock the install root down to SYSTEM, Administrators and the installing user. No /T, so the
    # change propagates by inheritance but never reaches through the mount point into the volume.
    $acl = "$env:USERDOMAIN\$env:USERNAME"
    $null = & icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "${acl}:(OI)(CI)F" /Q

    foreach ($p in $profiles) {
        switch ($p.State) {
            'Redirected'          { Write-Verbose "$($p.Browser)/$($p.Profile) already redirected" }
            'RedirectedElsewhere' { Write-Warning "$($p.Browser)/$($p.Profile): 'File System' is already a link to '$($p.Target)'; leaving it alone." }
            default {
                if ($PSCmdlet.ShouldProcess("$($p.Browser)/$($p.Profile)", 'Move site file storage onto the OpfsGuard volume')) {
                    $null = Move-OpfsProfileToVolume -ProfileInfo $p -Root $Root
                }
            }
        }
    }

    if (-not $SkipScheduledTasks -and $PSCmdlet.ShouldProcess('Task Scheduler', 'Register OpfsGuard tasks')) {
        Register-OpfsGuardTask -Root $Root
    }
    Get-OpfsGuardStatus -Root $Root
}

function Register-OpfsGuardTask {
    param([Parameter(Mandatory)][string]$Root)
    # Run the module from a copy inside the install root so tasks don't depend on where the repo lives.
    $modDest = Join-Path $Root 'module\OpfsGuard.Volume'
    New-Item -ItemType Directory -Force -Path $modDest | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot '*') -Destination $modDest -Recurse -Force
    $psd1 = Join-Path $modDest 'OpfsGuard.Volume.psd1'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $common = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    $attach = New-ScheduledTaskAction -Execute $ps -Argument "$common `"Import-Module '$psd1'; Mount-OpfsVolume -Root '$Root'`""
    Register-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:AttachTaskName -Action $attach -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Principal (New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest) -Settings $settings `
        -Description 'OpfsGuard: attach the site-storage virtual disk at boot.' -Force | Out-Null

    $user = "$env:USERDOMAIN\$env:USERNAME"
    $reconcile = New-ScheduledTaskAction -Execute $ps -Argument "$common `"Import-Module '$psd1'; Invoke-OpfsGuardReconcile -Root '$Root'`""
    Register-ScheduledTask -TaskPath $script:TaskPath -TaskName $script:ReconcileTaskName -Action $reconcile -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $user) `
        -Principal (New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest) -Settings $settings `
        -Description 'OpfsGuard: redirect site storage of browser profiles created since install.' -Force | Out-Null
    Write-OpfsLog -Root $Root 'Registered scheduled tasks'
}

function Invoke-OpfsGuardReconcile {
    <#
    .SYNOPSIS
        Redirects profiles created since install. Skips browsers that are running. Run at logon.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Root = $script:DefaultRoot)
    $state = Get-OpfsState -Root $Root
    if (-not $state) { throw "No OpfsGuard installation found at '$Root'." }
    if (-not (Test-OpfsVolumeMounted -Root $Root)) {
        if (Test-OpfsIsAdmin) { Mount-OpfsVolume -Root $Root } else { Write-OpfsLog -Root $Root -Level WARN 'Volume not mounted; skipping reconcile.'; return }
    }
    $profiles = @(Get-OpfsBrowserProfile -UserDataRoot $state.UserDataRoots -Root $Root)
    $pending = @($profiles | Where-Object { $_.State -in 'Local', 'Missing' })
    foreach ($group in ($pending | Group-Object Browser)) {
        if (Test-OpfsBrowserRunning -Profiles $group.Group) { Write-OpfsLog -Root $Root -Level WARN "$($group.Name) is running; will retry at next logon."; continue }
        foreach ($p in $group.Group) {
            if ($PSCmdlet.ShouldProcess("$($p.Browser)/$($p.Profile)", 'Redirect site file storage')) {
                try { $null = Move-OpfsProfileToVolume -ProfileInfo $p -Root $Root } catch { Write-OpfsLog -Root $Root -Level ERROR "$($p.Browser)/$($p.Profile): $_" }
            }
        }
    }
}

function Get-OpfsGuardStatus {
    <#
    .SYNOPSIS
        Shows whether the virtual disk is attached, its free space, scheduled tasks, and each profile's state.
    #>
    [CmdletBinding()]
    param([string]$Root = $script:DefaultRoot)
    $state = Get-OpfsState -Root $Root
    if (-not $state) { Write-Warning "OpfsGuard is not installed at '$Root'."; return }
    $img = Get-DiskImage -ImagePath $state.VhdPath -ErrorAction SilentlyContinue
    $vol = if ($img -and $img.Attached) { $img | Get-Disk | Get-Partition | Get-Volume -ErrorAction SilentlyContinue | Select-Object -First 1 }
    $tasks = @($script:AttachTaskName, $script:ReconcileTaskName) | ForEach-Object {
        $t = Get-ScheduledTask -TaskPath $script:TaskPath -TaskName $_ -ErrorAction SilentlyContinue
        '{0}={1}' -f $_, $(if ($t) { $t.State } else { 'missing' })
    }
    $profiles = @(Get-OpfsBrowserProfile -UserDataRoot $state.UserDataRoots -Root $Root)
    [pscustomobject]@{
        PSTypeName  = 'OpfsGuard.Status'
        Root        = $Root
        VhdPath     = $state.VhdPath
        Attached    = [bool]($img -and $img.Attached)
        MountPath   = $state.MountPath
        SizeGB      = if ($vol) { [math]::Round($vol.Size / 1GB, 2) } else { $state.SizeGB }
        FreeGB      = if ($vol) { [math]::Round($vol.SizeRemaining / 1GB, 2) } else { $null }
        Tasks       = $tasks -join ', '
        Profiles    = $profiles | Select-Object Browser, Profile, State, UserDataRoot
    }
}

function Uninstall-OpfsGuardVolume {
    <#
    .SYNOPSIS
        Moves site file storage back to each profile, removes tasks, detaches and deletes the virtual disk.
    .PARAMETER KeepVirtualDisk
        Detach but keep the .vhdx file and install folder.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([string]$Root = $script:DefaultRoot, [switch]$KeepVirtualDisk)
    Assert-OpfsAdmin
    $state = Get-OpfsState -Root $Root
    if (-not $state) { throw "No OpfsGuard installation found at '$Root'." }
    Mount-OpfsVolume -Root $Root
    $profiles = @(Get-OpfsBrowserProfile -UserDataRoot $state.UserDataRoots -Root $Root | Where-Object State -eq 'Redirected')
    if (Test-OpfsBrowserRunning -Profiles $profiles) { throw 'Close all browsers using OpfsGuard first.' }
    foreach ($p in $profiles) {
        if ($PSCmdlet.ShouldProcess("$($p.Browser)/$($p.Profile)", 'Move site file storage back')) { Restore-OpfsProfileFromVolume -ProfileInfo $p -Root $Root }
    }
    if ($PSCmdlet.ShouldProcess('Task Scheduler', 'Remove OpfsGuard tasks')) {
        foreach ($t in $script:AttachTaskName, $script:ReconcileTaskName) {
            Unregister-ScheduledTask -TaskPath $script:TaskPath -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    if ($PSCmdlet.ShouldProcess($state.VhdPath, 'Detach virtual disk')) {
        $img = Get-DiskImage -ImagePath $state.VhdPath
        $part = $img | Get-Disk | Get-Partition | Where-Object Type -ne 'Reserved' | Select-Object -First 1
        if ($part) { Remove-PartitionAccessPath -InputObject $part -AccessPath "$($state.MountPath)\" -ErrorAction SilentlyContinue }
        Dismount-DiskImage -ImagePath $state.VhdPath | Out-Null
    }
    if (-not $KeepVirtualDisk -and $PSCmdlet.ShouldProcess($Root, 'Delete install folder and virtual disk')) {
        Remove-Item -LiteralPath $Root -Recurse -Force
    }
}

#endregion

Export-ModuleMember -Function Install-OpfsGuardVolume, Uninstall-OpfsGuardVolume, Get-OpfsGuardStatus, Get-OpfsBrowserProfile, Mount-OpfsVolume, Invoke-OpfsGuardReconcile
