@{
    RootModule           = 'OpfsGuard.Volume.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '7c3a2b1e-5d4f-4a8e-9b61-2f0c9e8d4a17'
    Author               = 'OPFS Guard contributors'
    CompanyName          = 'Community'
    Copyright            = '(c) OPFS Guard contributors. MIT License.'
    Description          = 'Confines Chromium site file storage (OPFS) to a size-capped virtual disk so websites cannot fill the system drive.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @('Install-OpfsGuardVolume', 'Uninstall-OpfsGuardVolume', 'Get-OpfsGuardStatus', 'Get-OpfsBrowserProfile', 'Mount-OpfsVolume', 'Invoke-OpfsGuardReconcile')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('Windows', 'Chromium', 'Edge', 'Chrome', 'OPFS', 'Storage', 'Privacy', 'Performance')
            LicenseUri = 'https://github.com/leopck/opfs-guard/blob/main/LICENSE'
            ProjectUri = 'https://github.com/leopck/opfs-guard'
        }
    }
}
