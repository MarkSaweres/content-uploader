#Requires -Version 5.1
<#
    IntunePack - shared helpers for packaging Win32 apps for Microsoft Intune.

    Nothing in here talks to Intune or Graph. It inspects installers, derives
    silent install/uninstall commands and detection rules, and drives Microsoft's
    IntuneWinAppUtil.exe.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# Installer engine profiles
#
# Switches below are the ones that actually work unattended in a SYSTEM
# context. Where an engine has no reliable generic uninstall, Uninstall is
# left empty and the caller is expected to fall back to the registry
# QuietUninstallString captured from a test machine.
# --------------------------------------------------------------------------
$script:EngineProfiles = [ordered]@{
    'MSI' = @{
        Display   = 'Windows Installer (MSI)'
        Install   = '/qn /norestart'
        Uninstall = '/qn /norestart'
        Notes     = 'Uninstall by ProductCode is stable across versions of the same product family.'
    }
    'InnoSetup' = @{
        Display   = 'Inno Setup'
        Install   = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
        Uninstall = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
        Notes     = 'Uninstaller is unins000.exe in the install dir; prefer the registry QuietUninstallString.'
    }
    'NSIS' = @{
        Display   = 'Nullsoft (NSIS)'
        Install   = '/S'
        Uninstall = '/S'
        Notes     = 'Switch is case sensitive (/S, not /s). Some NSIS packages need /D=<path> LAST and unquoted.'
    }
    'WiXBurn' = @{
        Display   = 'WiX Burn bundle'
        Install   = '/quiet /norestart'
        Uninstall = '/uninstall /quiet /norestart'
        Notes     = 'Bundle registers its own ARP entry; detect on the bundle GUID, not the inner MSI.'
    }
    'InstallShield' = @{
        Display   = 'InstallShield'
        Install   = '/s /v"/qn REBOOT=ReallySuppress"'
        Uninstall = ''
        Notes     = 'Legacy InstallScript builds need a recorded response file: setup.exe /r /f1"C:\setup.iss" then /s /f1"...". Verify per app.'
    }
    'Squirrel' = @{
        Display   = 'Squirrel'
        Install   = '--silent'
        Uninstall = '--uninstall --silent'
        Notes     = 'Installs per-user under %LOCALAPPDATA% by default - usually a USER context app in Intune.'
    }
    'SevenZipSfx' = @{
        Display   = '7-Zip self-extracting archive'
        Install   = '-y'
        Uninstall = ''
        Notes     = 'SFX wrappers vary wildly. Extract it and package the real installer inside instead.'
    }
    'Unknown' = @{
        Display   = 'Unknown / custom'
        Install   = ''
        Uninstall = ''
        Notes     = 'Could not identify the installer engine. Try <setup>.exe /? and confirm on a test VM.'
    }
}

# Byte markers used to fingerprint an installer engine, in priority order.
$script:EngineMarkers = [ordered]@{
    'InnoSetup'     = @('Inno Setup Setup Data', 'Inno Setup Messages', 'JR.Inno.Setup')
    'NSIS'          = @('NullsoftInst', 'Nullsoft Install System')
    'WiXBurn'       = @('.wixburn', 'WixBundleOriginalSource')
    'InstallShield' = @('InstallShield', 'ISSetupPrerequisite')
    'Squirrel'      = @('Squirrel.Windows', 'SquirrelSetup')
    'SevenZipSfx'   = @('7-Zip SFX', '7zSFX')
}

# Exit codes Intune should treat as something other than a hard failure.
$script:StandardReturnCodes = @(
    [pscustomobject]@{ Code = 0;    Type = 'Success' }
    [pscustomobject]@{ Code = 1707; Type = 'Success' }
    [pscustomobject]@{ Code = 3010; Type = 'Soft reboot' }
    [pscustomobject]@{ Code = 1641; Type = 'Hard reboot' }
    [pscustomobject]@{ Code = 1618; Type = 'Retry' }
)

function Get-IntuneReturnCode {
    <#
    .SYNOPSIS
        The return codes every Win32 app in Intune should be configured with.
    #>
    [CmdletBinding()]
    param()
    $script:StandardReturnCodes
}

function Get-EngineProfile {
    <#
    .SYNOPSIS
        Look up the silent-switch profile for a known installer engine.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Engine)

    if ($script:EngineProfiles.Contains($Engine)) { return $script:EngineProfiles[$Engine] }
    $script:EngineProfiles['Unknown']
}

# --------------------------------------------------------------------------
# Binary inspection
# --------------------------------------------------------------------------

function Find-BinaryMarker {
    <#
    .SYNOPSIS
        Stream a file looking for ASCII/UTF-16 marker strings.
    .DESCRIPTION
        Reads in bounded chunks with an overlap window so a marker straddling a
        chunk boundary is still found, without pulling a 700 MB installer into
        memory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Marker,
        [int]$MaxBytes = 33554432   # 32 MB is plenty; engine headers sit near the front
    )

    $found = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $chunkSize = 1048576
    $overlap = 512

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] ($chunkSize + $overlap)
        $consumed = 0
        $carry = 0

        while ($consumed -lt $MaxBytes) {
            $read = $stream.Read($buffer, $carry, $chunkSize)
            if ($read -le 0) { break }

            $length = $carry + $read
            $ascii = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $length)
            $utf16 = [System.Text.Encoding]::Unicode.GetString($buffer, 0, $length)

            foreach ($m in $Marker) {
                if ($found.Contains($m)) { continue }
                if ($ascii.IndexOf($m, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    $utf16.IndexOf($m, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    [void]$found.Add($m)
                }
            }

            $consumed += $read
            $carry = [Math]::Min($overlap, $length)
            [Array]::Copy($buffer, $length - $carry, $buffer, 0, $carry)
        }
    }
    finally {
        $stream.Dispose()
    }

    , [string[]]$found
}

function Get-InstallerEngine {
    <#
    .SYNOPSIS
        Fingerprint which installer engine built an .exe (or identify an .msi).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path
    switch ($item.Extension.ToLowerInvariant()) {
        '.msi'  { return 'MSI' }
        '.msix' { return 'MSIX' }
        '.appx' { return 'MSIX' }
    }

    $allMarkers = @()
    foreach ($key in $script:EngineMarkers.Keys) { $allMarkers += $script:EngineMarkers[$key] }

    $hits = Find-BinaryMarker -Path $item.FullName -Marker $allMarkers

    foreach ($engine in $script:EngineMarkers.Keys) {
        foreach ($marker in $script:EngineMarkers[$engine]) {
            if ($hits -contains $marker) { return $engine }
        }
    }

    'Unknown'
}

function Get-MsiProperty {
    <#
    .SYNOPSIS
        Read a single Property table value out of an MSI database.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Database,
        [Parameter(Mandatory)][string]$Name
    )

    $view = $null
    try {
        $query = "SELECT Value FROM Property WHERE Property = '$Name'"
        $view = $Database.GetType().InvokeMember(
            'OpenView', 'InvokeMethod', $null, $Database, @($query))
        [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if ($null -eq $record) { return $null }
        $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
    }
    catch {
        $null
    }
    finally {
        if ($null -ne $view) {
            [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
        }
    }
}

function Get-MsiInfo {
    <#
    .SYNOPSIS
        Extract ProductCode, ProductVersion and friends from an MSI.
    .NOTES
        Windows only - uses the WindowsInstaller COM object.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    $installer = $null
    $database = $null

    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        # 0 = msiOpenDatabaseModeReadOnly
        $database = $installer.GetType().InvokeMember(
            'OpenDatabase', 'InvokeMethod', $null, $installer, @($full, 0))

        [pscustomobject]@{
            ProductCode    = Get-MsiProperty -Database $database -Name 'ProductCode'
            ProductName    = Get-MsiProperty -Database $database -Name 'ProductName'
            ProductVersion = Get-MsiProperty -Database $database -Name 'ProductVersion'
            Manufacturer   = Get-MsiProperty -Database $database -Name 'Manufacturer'
            UpgradeCode    = Get-MsiProperty -Database $database -Name 'UpgradeCode'
            AllUsers       = Get-MsiProperty -Database $database -Name 'ALLUSERS'
        }
    }
    finally {
        if ($null -ne $database)  { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($database) }
        if ($null -ne $installer) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer) }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}

function Get-InstallerInfo {
    <#
    .SYNOPSIS
        Inspect an installer and report everything needed to fill in an Intune app.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path
    $engine = Get-InstallerEngine -Path $item.FullName
    $engineProfile = Get-EngineProfile -Engine $engine

    $msi = $null
    if ($engine -eq 'MSI') {
        try { $msi = Get-MsiInfo -Path $item.FullName }
        catch { Write-Warning "Could not read MSI properties from '$($item.Name)': $($_.Exception.Message)" }
    }

    $fileVersion = $null
    $productName = $null
    try {
        $vi = $item.VersionInfo
        if ($vi) {
            $fileVersion = $vi.FileVersion
            $productName = $vi.ProductName
        }
    }
    catch { }

    $productCode = $null
    $manufacturer = $null
    $upgradeCode = $null
    if ($msi) {
        $productCode = $msi.ProductCode
        $manufacturer = $msi.Manufacturer
        $upgradeCode = $msi.UpgradeCode
        if ($msi.ProductName)    { $productName = $msi.ProductName }
        if ($msi.ProductVersion) { $fileVersion = $msi.ProductVersion }
    }

    [pscustomobject]@{
        Path              = $item.FullName
        FileName          = $item.Name
        SizeMB            = [Math]::Round($item.Length / 1MB, 2)
        Engine            = $engine
        EngineDisplay     = $engineProfile.Display
        InstallSwitches   = $engineProfile.Install
        UninstallSwitches = $engineProfile.Uninstall
        EngineNotes       = $engineProfile.Notes
        ProductCode       = $productCode
        ProductName       = $productName
        ProductVersion    = $fileVersion
        Manufacturer      = $manufacturer
        UpgradeCode       = $upgradeCode
    }
}

# --------------------------------------------------------------------------
# Command + detection rule generation
# --------------------------------------------------------------------------

function New-InstallCommand {
    <#
    .SYNOPSIS
        Build the Intune "Install command" line for an installer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SetupFile,
        [Parameter(Mandatory)][string]$Engine,
        [string]$ExtraArguments
    )

    $engineProfile = Get-EngineProfile -Engine $Engine
    $switches = (@($engineProfile.Install, $ExtraArguments) | Where-Object { $_ }) -join ' '

    if ($Engine -eq 'MSI') {
        return ('msiexec /i "{0}" {1}' -f $SetupFile, $switches).Trim()
    }
    if ($Engine -eq 'MSIX') {
        return ('powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Add-AppxProvisionedPackage -Online -PackagePath ''{0}'' -SkipLicense"' -f $SetupFile)
    }

    ('"{0}" {1}' -f $SetupFile, $switches).Trim()
}

function New-UninstallCommand {
    <#
    .SYNOPSIS
        Build the Intune "Uninstall command" line for an installer.
    .DESCRIPTION
        MSI packages get a ProductCode uninstall, which is the only form that
        survives the source file being gone. Everything else falls back to the
        engine's uninstall switches, and the caller is told to confirm against
        the registry QuietUninstallString on a test machine.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SetupFile,
        [Parameter(Mandatory)][string]$Engine,
        [string]$ProductCode
    )

    $engineProfile = Get-EngineProfile -Engine $Engine

    if ($Engine -eq 'MSI') {
        if ($ProductCode) {
            return ('msiexec /x "{0}" {1}' -f $ProductCode, $engineProfile.Uninstall).Trim()
        }
        return ('msiexec /x "{0}" {1}' -f $SetupFile, $engineProfile.Uninstall).Trim()
    }

    if (-not $engineProfile.Uninstall) {
        return "TODO: no generic uninstall for $Engine - run Get-InstalledAppInfo.ps1 on a test machine and use its QuietUninstallString."
    }

    ('"{0}" {1}' -f $SetupFile, $engineProfile.Uninstall).Trim()
}

function New-DetectionRule {
    <#
    .SYNOPSIS
        Produce the detection rule to enter in the Intune portal.
    .DESCRIPTION
        MSI installers get a proper MSI product-code rule. Anything else gets a
        registry rule against the ARP uninstall key - flagged as unconfirmed,
        because the key name is only knowable after a test install.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Engine,
        [string]$ProductCode,
        [string]$Version,
        [string]$AppName
    )

    if ($Engine -eq 'MSI' -and $ProductCode) {
        $versionCheck = 'No'
        $operator = ''
        $summary = "MSI product code $ProductCode"
        if ($Version) {
            $versionCheck = 'Yes'
            $operator = 'Greater than or equal to'
            $summary = "$summary (version >= $Version)"
        }

        return [pscustomobject]@{
            Type      = 'MSI'
            Confirmed = $true
            Summary   = $summary
            Detail    = [ordered]@{
                'Rule type'                 = 'MSI'
                'MSI product code'          = $ProductCode
                'MSI product version check' = $versionCheck
                'Operator'                  = $operator
                'Value'                     = $Version
            }
        }
    }

    [pscustomobject]@{
        Type      = 'Registry'
        Confirmed = $false
        Summary   = "Registry uninstall key for '$AppName' - CONFIRM the key name on a test machine"
        Detail    = [ordered]@{
            'Rule type'          = 'Registry'
            'Key path'           = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\<TODO: key name or {GUID}>'
            'Value name'         = 'DisplayVersion'
            'Detection method'   = 'String comparison'
            'Operator'           = 'Greater than or equal to'
            'Value'              = $Version
            'Associated 32-bit'  = 'No  (set to Yes only if the app writes to WOW6432Node)'
        }
    }
}

# --------------------------------------------------------------------------
# IntuneWinAppUtil.exe
# --------------------------------------------------------------------------

function Resolve-ContentPrepTool {
    <#
    .SYNOPSIS
        Locate IntuneWinAppUtil.exe, optionally downloading it.
    #>
    [CmdletBinding()]
    param(
        [string]$ToolPath,
        [string]$DefaultDirectory,
        [switch]$Download
    )

    if ($ToolPath) {
        if (-not (Test-Path -LiteralPath $ToolPath)) {
            throw "IntuneWinAppUtil.exe not found at '$ToolPath'."
        }
        return (Resolve-Path -LiteralPath $ToolPath).ProviderPath
    }

    if ($DefaultDirectory) {
        $candidate = Join-Path $DefaultDirectory 'IntuneWinAppUtil.exe'
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
    }

    $onPath = Get-Command 'IntuneWinAppUtil.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    if ($Download -and $DefaultDirectory) {
        $url = 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe'
        $target = Join-Path $DefaultDirectory 'IntuneWinAppUtil.exe'
        if (-not (Test-Path -LiteralPath $DefaultDirectory)) {
            [void](New-Item -ItemType Directory -Path $DefaultDirectory -Force)
        }
        Write-Host "Downloading IntuneWinAppUtil.exe from $url" -ForegroundColor Cyan
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing
        return (Resolve-Path -LiteralPath $target).ProviderPath
    }

    throw @"
IntuneWinAppUtil.exe not found.

Fix it with either:
  * re-run with -DownloadTool, or
  * download it from https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool
    and drop IntuneWinAppUtil.exe in '$DefaultDirectory'.
"@
}

function Invoke-ContentPrep {
    <#
    .SYNOPSIS
        Run IntuneWinAppUtil.exe over one source folder and return the package path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ToolPath,
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$SetupFile,
        [Parameter(Mandatory)][string]$OutputFolder,
        [string]$PackageName
    )

    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        [void](New-Item -ItemType Directory -Path $OutputFolder -Force)
    }

    # The tool names its output after the setup file, and silently reuses an
    # existing file, so clear the expected name first.
    $defaultName = [System.IO.Path]::GetFileNameWithoutExtension($SetupFile) + '.intunewin'
    $defaultPath = Join-Path $OutputFolder $defaultName
    if (Test-Path -LiteralPath $defaultPath) { Remove-Item -LiteralPath $defaultPath -Force }

    & $ToolPath -c $SourceFolder -s $SetupFile -o $OutputFolder -q
    $exit = $LASTEXITCODE

    if ($exit -ne 0) {
        throw "IntuneWinAppUtil.exe exited with code $exit for '$SetupFile'."
    }
    if (-not (Test-Path -LiteralPath $defaultPath)) {
        throw "IntuneWinAppUtil.exe reported success but '$defaultPath' was not created."
    }

    if ($PackageName) {
        $finalPath = Join-Path $OutputFolder $PackageName
        if ($finalPath -ne $defaultPath) {
            if (Test-Path -LiteralPath $finalPath) { Remove-Item -LiteralPath $finalPath -Force }
            Move-Item -LiteralPath $defaultPath -Destination $finalPath
        }
        return (Resolve-Path -LiteralPath $finalPath).ProviderPath
    }

    (Resolve-Path -LiteralPath $defaultPath).ProviderPath
}

function ConvertTo-SafeFileName {
    <#
    .SYNOPSIS
        Strip characters that are illegal in a Windows file name.
    .NOTES
        The Windows-invalid set is pinned explicitly rather than taken from
        [System.IO.Path]::GetInvalidFileNameChars(), which returns only '/' when
        the script happens to run on Linux/macOS. These names always end up on a
        Windows file share, so the host platform must not change the result.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $invalid = [char[]]('<', '>', ':', '"', '/', '\', '|', '?', '*', ' ')
    $invalid += [System.IO.Path]::GetInvalidFileNameChars()

    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) {
        if ($invalid -contains $ch -or [int]$ch -lt 32) { [void]$sb.Append('_') }
        else { [void]$sb.Append($ch) }
    }

    # Windows silently strips trailing dots and spaces; do it deliberately.
    $result = $sb.ToString().TrimEnd('.', '_')
    if (-not $result) { $result = 'app' }
    $result
}

Export-ModuleMember -Function @(
    'Get-IntuneReturnCode'
    'Get-EngineProfile'
    'Find-BinaryMarker'
    'Get-InstallerEngine'
    'Get-MsiProperty'
    'Get-MsiInfo'
    'Get-InstallerInfo'
    'New-InstallCommand'
    'New-UninstallCommand'
    'New-DetectionRule'
    'Resolve-ContentPrepTool'
    'Invoke-ContentPrep'
    'ConvertTo-SafeFileName'
)
