#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Unit tests run anywhere. Integration tests (Tag 'Integration') need an elevated session:
    they create a real 100 MB VHDX under $env:TEMP and remove it afterwards.
        Invoke-Pester tests/windows -Output Detailed                       # unit only
        Invoke-Pester tests/windows -Output Detailed -TagFilter Integration # elevated
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\..\windows\BrowserLagFix.Volume\BrowserLagFix.Volume.psd1'
    Import-Module $modulePath -Force

    function Initialize-FakeUserData {
        param([string]$Path, [string[]]$Profiles, [int]$FilesPerProfile = 3)
        foreach ($p in $Profiles) {
            $dir = Join-Path $Path $p
            New-Item -ItemType Directory -Force -Path (Join-Path $dir 'File System\000\t\00') | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'Preferences') -Value '{}'
            for ($i = 0; $i -lt $FilesPerProfile; $i++) {
                $bytes = [byte[]]::new(4096 * ($i + 1)); (New-Object Random $i).NextBytes($bytes)
                [IO.File]::WriteAllBytes((Join-Path $dir "File System\000\t\00\0000000$i"), $bytes)
            }
        }
        New-Item -ItemType Directory -Force -Path (Join-Path $Path 'Crashpad') | Out-Null  # not a profile
    }

    function Get-TreeHash {
        param([string]$Path)
        (Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
            '{0}|{1}' -f $_.FullName.Substring($Path.Length), (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        }) -join "`n"
    }
}

Describe 'Get-BrowserLagFixProfile' {
    BeforeEach {
        $script:ud = Join-Path $TestDrive ('ud-' + [guid]::NewGuid())
        $script:root = Join-Path $TestDrive ('root-' + [guid]::NewGuid())
        Initialize-FakeUserData -Path $ud -Profiles 'Default', 'Profile 1'
    }

    It 'finds only directories that contain a Preferences file' {
        $p = @(Get-BrowserLagFixProfile -UserDataRoot $ud -Root $root)
        $p.Profile | Sort-Object | Should -Be @('Default', 'Profile 1')
        $p.State | Select-Object -Unique | Should -Be 'Local'
        $p[0].Browser | Should -Be 'Custom'
    }

    It 'classifies a junction into the BrowserLagFix mount as Redirected' {
        $target = Join-Path $root 'mnt\x\Default\File System'
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Remove-Item -LiteralPath (Join-Path $ud 'Default\File System') -Recurse -Force
        New-Item -ItemType Junction -Path (Join-Path $ud 'Default\File System') -Target $target | Out-Null
        (Get-BrowserLagFixProfile -UserDataRoot $ud -Root $root | Where-Object Profile -eq 'Default').State | Should -Be 'Redirected'
    }

    It 'classifies a junction elsewhere as RedirectedElsewhere and leaves it to the user' {
        $other = Join-Path $TestDrive ('elsewhere-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $other | Out-Null
        Remove-Item -LiteralPath (Join-Path $ud 'Default\File System') -Recurse -Force
        New-Item -ItemType Junction -Path (Join-Path $ud 'Default\File System') -Target $other | Out-Null
        (Get-BrowserLagFixProfile -UserDataRoot $ud -Root $root | Where-Object Profile -eq 'Default').State | Should -Be 'RedirectedElsewhere'
    }

    It 'reports Missing for a profile that never used site file storage' {
        Remove-Item -LiteralPath (Join-Path $ud 'Profile 1\File System') -Recurse -Force
        (Get-BrowserLagFixProfile -UserDataRoot $ud -Root $root | Where-Object Profile -eq 'Profile 1').State | Should -Be 'Missing'
    }
}

Describe 'Get-BrowserLagFixProfileKey' {
    It 'is stable for a path and distinct across user-data roots' {
        InModuleScope BrowserLagFix.Volume {
            $a = [pscustomobject]@{ Browser = 'Edge'; Profile = 'Default'; UserDataRoot = 'C:\A\User Data' }
            $b = [pscustomobject]@{ Browser = 'Edge'; Profile = 'Default'; UserDataRoot = 'C:\B\User Data' }
            Get-BrowserLagFixProfileKey -ProfileInfo $a | Should -Be (Get-BrowserLagFixProfileKey -ProfileInfo $a)
            Get-BrowserLagFixProfileKey -ProfileInfo $a | Should -Not -Be (Get-BrowserLagFixProfileKey -ProfileInfo $b)
            Get-BrowserLagFixProfileKey -ProfileInfo $a | Should -Match '^Edge-[0-9a-f]{8}\\Default$'
        }
    }
}

Describe 'ConvertTo-LagFixLongPath' {
    It 'expands 8.3 short names, including in paths that do not exist yet' {
        $long = Join-Path $TestDrive 'a long directory name for short-name tests'
        New-Item -ItemType Directory -Path $long | Out-Null
        $short = (& cmd.exe /c "for %I in (""$long"") do @echo %~sI").Trim()
        if ($short -notmatch '~') { Set-ItResult -Skipped -Because '8.3 names are disabled on this volume'; return }
        InModuleScope BrowserLagFix.Volume -Parameters @{ Long = $long; Short = $short } {
            param($Long, $Short)
            $expected = ConvertTo-LagFixLongPath -Path $Long
            ConvertTo-LagFixLongPath -Path $Short | Should -Be $expected
            ConvertTo-LagFixLongPath -Path (Join-Path $Short 'mnt\x') | Should -Be (Join-Path $expected 'mnt\x')
            ConvertTo-LagFixLongPath -Path "$Long\" | Should -Be $expected
        }
    }
}

Describe 'Install / Reconcile / Uninstall lifecycle' -Tag 'Integration' {
    BeforeAll {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $script:skip = -not $isAdmin
        $base = Join-Path $env:TEMP ('browserlagfix-it-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $script:ud = Join-Path $base 'User Data'
        $script:root = Join-Path $base 'BrowserLagFix'
        Initialize-FakeUserData -Path $ud -Profiles 'Default', 'Profile 1' -FilesPerProfile 5
        $script:hashDefault = Get-TreeHash (Join-Path $ud 'Default\File System')
        $script:hashP1 = Get-TreeHash (Join-Path $ud 'Profile 1\File System')
    }
    AfterAll {
        if (-not $skip) {
            try { Uninstall-BrowserLagFixVolume -Root $root -Confirm:$false -ErrorAction SilentlyContinue } catch { Write-Verbose "cleanup: $_" }
            $vhd = Join-Path $root 'browserlagfix.vhdx'
            if (Test-Path $vhd) { Dismount-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue | Out-Null }
            Remove-Item -LiteralPath (Split-Path $ud) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'installs: creates the volume and redirects every profile without losing data' -Skip:$skip {
        Install-BrowserLagFixVolume -Root $root -SizeGB 0.1 -UserDataRoot $ud -SkipScheduledTasks -Confirm:$false | Out-Null
        $status = Get-BrowserLagFixStatus -Root $root
        $status.Attached | Should -BeTrue
        $status.Profiles.State | Select-Object -Unique | Should -Be 'Redirected'
        (Get-Item -LiteralPath (Join-Path $ud 'Default\File System') -Force).LinkType | Should -Be 'Junction'
        Get-TreeHash (Join-Path $ud 'Default\File System') | Should -Be $hashDefault
        Get-TreeHash (Join-Path $ud 'Profile 1\File System') | Should -Be $hashP1
    }

    It 'is idempotent when run again' -Skip:$skip {
        { Install-BrowserLagFixVolume -Root $root -SizeGB 0.1 -UserDataRoot $ud -SkipScheduledTasks -Confirm:$false | Out-Null } | Should -Not -Throw
        (Get-BrowserLagFixStatus -Root $root).Profiles.State | Select-Object -Unique | Should -Be 'Redirected'
    }

    It 'confines an oversized file to the virtual disk (the actual fix)' -Skip:$skip {
        $sysFreeBefore = (Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free
        $big = Join-Path $ud 'Default\File System\000\t\00\probe'
        $fs = [IO.File]::Open($big, 'CreateNew')
        try {
            { $fs.SetLength(1TB) } | Should -Throw  # what Chromium's truncate() does on Windows
            $fs.SetLength(50MB)                      # fits within the 100 MB volume
        } finally { $fs.Dispose(); Remove-Item -LiteralPath $big -Force }
        $sysFreeAfter = (Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free
        [math]::Abs($sysFreeBefore - $sysFreeAfter) | Should -BeLessThan 500MB
    }

    It 'reconcile redirects a profile created after install' -Skip:$skip {
        Initialize-FakeUserData -Path $ud -Profiles 'Profile 2' -FilesPerProfile 2
        Invoke-BrowserLagFixReconcile -Root $root -Confirm:$false
        (Get-BrowserLagFixProfile -UserDataRoot $ud -Root $root | Where-Object Profile -eq 'Profile 2').State | Should -Be 'Redirected'
    }

    It 'uninstalls: data back in place, no junctions, virtual disk gone' -Skip:$skip {
        Uninstall-BrowserLagFixVolume -Root $root -Confirm:$false
        (Get-Item -LiteralPath (Join-Path $ud 'Default\File System') -Force).LinkType | Should -BeNullOrEmpty
        Get-TreeHash (Join-Path $ud 'Default\File System') | Should -Be $hashDefault
        Get-TreeHash (Join-Path $ud 'Profile 1\File System') | Should -Be $hashP1
        Test-Path -LiteralPath $root | Should -BeFalse
    }
}
