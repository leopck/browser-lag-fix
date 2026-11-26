@{
    RootModule           = 'BrowserLagFix.Volume.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '7c3a2b1e-5d4f-4a8e-9b61-2f0c9e8d4a17'
    Author               = 'Browser Lag Fix contributors'
    CompanyName          = 'Community'
    Copyright            = '(c) Browser Lag Fix contributors. MIT License.'
    Description          = 'Confines Chromium site file storage (OPFS) to a size-capped virtual disk so websites cannot fill the system drive.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @('Install-BrowserLagFixVolume', 'Uninstall-BrowserLagFixVolume', 'Get-BrowserLagFixStatus', 'Get-BrowserLagFixProfile', 'Mount-BrowserLagFixVolume', 'Invoke-BrowserLagFixReconcile')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('Windows', 'Chromium', 'Edge', 'Chrome', 'OPFS', 'Storage', 'Privacy', 'Performance')
            LicenseUri = 'https://github.com/leopck/browser-lag-fix/blob/main/LICENSE'
            ProjectUri = 'https://github.com/leopck/browser-lag-fix'
        }
    }
}
