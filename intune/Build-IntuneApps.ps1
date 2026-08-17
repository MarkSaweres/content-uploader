#Requires -Version 5.1
<#
.SYNOPSIS
    Build .intunewin packages for every app in a manifest and emit a command
    sheet to paste into the Intune portal.

.DESCRIPTION
    Wraps Microsoft's IntuneWinAppUtil.exe. For each app in apps.json it:

      1. inspects the installer (engine fingerprint, MSI product code, version)
      2. derives the silent install command, uninstall command and detection rule
      3. runs IntuneWinAppUtil.exe to produce <Name>_<Version>.intunewin
      4. writes command-sheet.md / command-sheet.csv covering every app

    Anything set explicitly in the manifest wins over the derived value.

.PARAMETER ManifestPath
    Path to apps.json. Defaults to the copy next to this script.

.PARAMETER InstallerRoot
    Folder the manifest's relative sourceFolder values resolve against.
    Defaults to .\installers next to this script.

.PARAMETER OutputRoot
    Where packages and the command sheet land. Defaults to .\output.

.PARAMETER ToolPath
    Full path to IntuneWinAppUtil.exe. If omitted the script looks in
    .\tools, then PATH, then honours -DownloadTool.

.PARAMETER DownloadTool
    Fetch IntuneWinAppUtil.exe from Microsoft's GitHub repo into .\tools
    if it is not already present.

.PARAMETER Only
    Build just these apps, matched against the manifest 'name' (wildcards OK).

.PARAMETER SkipPackaging
    Regenerate the command sheet without re-running IntuneWinAppUtil.exe.
    Useful while iterating on commands and detection rules.

.EXAMPLE
    .\Build-IntuneApps.ps1 -DownloadTool

.EXAMPLE
    .\Build-IntuneApps.ps1 -Only '7-Zip','Notepad*'

.EXAMPLE
    .\Build-IntuneApps.ps1 -SkipPackaging
#>
[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$InstallerRoot,
    [string]$OutputRoot,
    [string]$ToolPath,
    [switch]$DownloadTool,
    [string[]]$Only,
    [switch]$SkipPackaging
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'IntunePack.psm1') -Force

if (-not $ManifestPath)   { $ManifestPath   = Join-Path $PSScriptRoot 'apps.json' }
if (-not $InstallerRoot)  { $InstallerRoot  = Join-Path $PSScriptRoot 'installers' }
if (-not $OutputRoot)     { $OutputRoot     = Join-Path $PSScriptRoot 'output' }
$toolDirectory = Join-Path $PSScriptRoot 'tools'

function Get-Field {
    <#
        Safe property read off a ConvertFrom-Json object. Under StrictMode a
        missing property throws, and null/empty should fall back to the default.
    #>
    param($Object, [string]$Name, $Default = $null)

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    $value = $property.Value
    if ($null -eq $value) { return $Default }
    if ($value -is [string] -and $value.Trim() -eq '') { return $Default }
    $value
}

function Write-Step {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host $Message -ForegroundColor $Color
}

function Get-DetailPair {
    <#
        Enumerate a detection rule's fields as ordered Key/Value pairs.

        Detail is an [ordered] dictionary when derived by New-DetectionRule, but
        a PSCustomObject when it came from a manifest override via
        ConvertFrom-Json. PSObject.Properties on a dictionary yields the .NET
        members (Count, Keys, Values...), not the entries, so the two cases have
        to be enumerated differently.
    #>
    param($Detail)

    if ($null -eq $Detail) { return @() }

    if ($Detail -is [System.Collections.IDictionary]) {
        return @($Detail.GetEnumerator() | ForEach-Object {
            [pscustomobject]@{ Key = $_.Key; Value = $_.Value }
        })
    }

    @($Detail.PSObject.Properties | ForEach-Object {
        [pscustomobject]@{ Key = $_.Name; Value = $_.Value }
    })
}

# --------------------------------------------------------------------------
# Load manifest
# --------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Manifest not found at '$ManifestPath'."
}

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$defaults = Get-Field $manifest 'defaults'
$defaultContext = Get-Field $defaults 'installContext' 'system'
$defaultRestart = Get-Field $defaults 'restartBehavior' 'suppress'

$allApps = @(Get-Field $manifest 'apps' @())
if ($allApps.Count -eq 0) { throw "Manifest '$ManifestPath' contains no apps." }

$apps = $allApps | Where-Object {
    $name = Get-Field $_ 'name'
    if (-not $name) { return $false }
    if (Get-Field $_ 'skip' $false) { return $false }
    if (-not $Only) { return $true }
    foreach ($pattern in $Only) { if ($name -like $pattern) { return $true } }
    $false
}
$apps = @($apps)

if ($apps.Count -eq 0) {
    throw "No apps selected. Check -Only and the 'skip' flags in the manifest."
}

Write-Step "Manifest : $ManifestPath"
Write-Step "Sources  : $InstallerRoot"
Write-Step "Output   : $OutputRoot"
Write-Step "Apps     : $($apps.Count) selected"
Write-Host ''

# --------------------------------------------------------------------------
# Locate the content prep tool (unless we are only regenerating the sheet)
# --------------------------------------------------------------------------
$tool = $null
if (-not $SkipPackaging) {
    $tool = Resolve-ContentPrepTool -ToolPath $ToolPath -DefaultDirectory $toolDirectory -Download:$DownloadTool
    Write-Step "Tool     : $tool"
    Write-Host ''
}

if (-not (Test-Path -LiteralPath $OutputRoot)) {
    [void](New-Item -ItemType Directory -Path $OutputRoot -Force)
}

# --------------------------------------------------------------------------
# Process each app
# --------------------------------------------------------------------------
$results = @()
$failures = @()

foreach ($app in $apps) {
    $name = Get-Field $app 'name'
    Write-Step "=== $name" 'White'

    try {
        $version      = Get-Field $app 'version'
        $publisher    = Get-Field $app 'publisher'
        $setupFile    = Get-Field $app 'setupFile'
        $sourceFolder = Get-Field $app 'sourceFolder'
        $context      = Get-Field $app 'installContext' $defaultContext
        $restart      = Get-Field $app 'restartBehavior' $defaultRestart
        $extraArgs    = Get-Field $app 'extraArguments'
        $notes        = Get-Field $app 'notes'

        if (-not $setupFile) { throw "'setupFile' is required." }
        if (-not $sourceFolder) { $sourceFolder = (ConvertTo-SafeFileName -Name $name) }

        # Resolve the source folder: absolute wins, otherwise relative to InstallerRoot.
        $resolvedSource = $sourceFolder
        if (-not [System.IO.Path]::IsPathRooted($sourceFolder)) {
            $resolvedSource = Join-Path $InstallerRoot $sourceFolder
        }
        if (-not (Test-Path -LiteralPath $resolvedSource)) {
            throw "Source folder not found: '$resolvedSource'."
        }
        $resolvedSource = (Resolve-Path -LiteralPath $resolvedSource).ProviderPath

        $setupPath = Join-Path $resolvedSource $setupFile
        if (-not (Test-Path -LiteralPath $setupPath)) {
            throw "Setup file not found: '$setupPath'."
        }
        $setupPath = (Resolve-Path -LiteralPath $setupPath).ProviderPath

        # ------------------------------------------------------------------
        # Inspect
        # ------------------------------------------------------------------
        Write-Host "    inspecting $setupFile ..."
        $info = Get-InstallerInfo -Path $setupPath
        Write-Host "    engine: $($info.EngineDisplay)"

        if (-not $version -and $info.ProductVersion) {
            $version = $info.ProductVersion
            Write-Host "    version from installer: $version"
        }
        if ($info.ProductCode) { Write-Host "    product code: $($info.ProductCode)" }

        # ------------------------------------------------------------------
        # Commands
        # ------------------------------------------------------------------
        $installCommand = Get-Field $app 'installCommand'
        if (-not $installCommand) {
            $installCommand = New-InstallCommand -SetupFile $setupFile -Engine $info.Engine -ExtraArguments $extraArgs
        }

        $uninstallCommand = Get-Field $app 'uninstallCommand'
        if (-not $uninstallCommand) {
            $uninstallCommand = New-UninstallCommand -SetupFile $setupFile -Engine $info.Engine -ProductCode $info.ProductCode
        }

        # ------------------------------------------------------------------
        # Detection rule
        # ------------------------------------------------------------------
        $detectionOverride = Get-Field $app 'detection'
        if ($detectionOverride) {
            $detection = [pscustomobject]@{
                Type      = Get-Field $detectionOverride 'type' 'Custom'
                Confirmed = $true
                Summary   = Get-Field $detectionOverride 'summary' 'Manual detection rule from manifest'
                Detail    = Get-Field $detectionOverride 'detail'
            }
        }
        else {
            $detection = New-DetectionRule -Engine $info.Engine -ProductCode $info.ProductCode `
                                           -Version $version -AppName $name
        }

        # ------------------------------------------------------------------
        # Package
        # ------------------------------------------------------------------
        $safeName = ConvertTo-SafeFileName -Name $name
        $appOutput = Join-Path $OutputRoot $safeName
        $packageName = if ($version) { "${safeName}_$(ConvertTo-SafeFileName -Name $version).intunewin" }
                       else { "$safeName.intunewin" }
        $packagePath = Join-Path $appOutput $packageName

        if ($SkipPackaging) {
            Write-Host "    packaging skipped"
        }
        else {
            Write-Host "    packaging -> $packageName"
            $packagePath = Invoke-ContentPrep -ToolPath $tool -SourceFolder $resolvedSource `
                                              -SetupFile $setupPath -OutputFolder $appOutput `
                                              -PackageName $packageName
            $sizeMB = [Math]::Round((Get-Item -LiteralPath $packagePath).Length / 1MB, 2)
            Write-Host "    done ($sizeMB MB)" -ForegroundColor Green
        }

        $result = [pscustomobject]@{
            Name             = $name
            Publisher        = $publisher
            Version          = $version
            Engine           = $info.EngineDisplay
            SetupFile        = $setupFile
            SourceFolder     = $resolvedSource
            PackagePath      = $packagePath
            PackageName      = $packageName
            InstallCommand   = $installCommand
            UninstallCommand = $uninstallCommand
            InstallContext   = $context
            RestartBehavior  = $restart
            Detection        = $detection
            ProductCode      = $info.ProductCode
            EngineNotes      = $info.EngineNotes
            Notes            = $notes
            NeedsReview      = (-not $detection.Confirmed) -or ($uninstallCommand -like 'TODO:*')
        }

        # Per-app sidecar so a single app can be re-checked without a full run.
        if (-not (Test-Path -LiteralPath $appOutput)) {
            [void](New-Item -ItemType Directory -Path $appOutput -Force)
        }
        $result | ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath (Join-Path $appOutput 'app.json') -Encoding UTF8

        $results += $result
    }
    catch {
        Write-Host "    FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $failures += [pscustomobject]@{ Name = $name; Error = $_.Exception.Message }
    }

    Write-Host ''
}

if ($results.Count -eq 0) {
    throw "No apps were processed successfully."
}

# --------------------------------------------------------------------------
# Command sheet
# --------------------------------------------------------------------------
Write-Step 'Writing command sheet ...'

$returnCodes = (Get-IntuneReturnCode | ForEach-Object { "$($_.Code) = $($_.Type)" }) -join ', '

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine('# Intune Win32 app command sheet')
[void]$md.AppendLine()
[void]$md.AppendLine("Generated by ``Build-IntuneApps.ps1`` from ``$(Split-Path -Leaf $ManifestPath)``.")
[void]$md.AppendLine()
[void]$md.AppendLine("Apply these return codes to every app: $returnCodes")
[void]$md.AppendLine()

$review = @($results | Where-Object { $_.NeedsReview })
if ($review.Count -gt 0) {
    [void]$md.AppendLine('## Needs review before deploying')
    [void]$md.AppendLine()
    [void]$md.AppendLine('These could not be fully derived from the installer. Install each one on a')
    [void]$md.AppendLine('test machine, run `Get-InstalledAppInfo.ps1`, and fill in the gaps.')
    [void]$md.AppendLine()
    foreach ($item in $review) {
        [void]$md.AppendLine("- **$($item.Name)**")
    }
    [void]$md.AppendLine()
}

[void]$md.AppendLine('## Apps')
[void]$md.AppendLine()

foreach ($item in $results) {
    [void]$md.AppendLine("### $($item.Name)")
    [void]$md.AppendLine()
    [void]$md.AppendLine('| Field | Value |')
    [void]$md.AppendLine('| --- | --- |')
    [void]$md.AppendLine("| Publisher | $($item.Publisher) |")
    [void]$md.AppendLine("| Version | $($item.Version) |")
    [void]$md.AppendLine("| Installer engine | $($item.Engine) |")
    [void]$md.AppendLine("| Package | ``$($item.PackageName)`` |")
    [void]$md.AppendLine("| Install command | ``$($item.InstallCommand)`` |")
    [void]$md.AppendLine("| Uninstall command | ``$($item.UninstallCommand)`` |")
    [void]$md.AppendLine("| Install behavior | $($item.InstallContext) |")
    [void]$md.AppendLine("| Device restart behavior | $($item.RestartBehavior) |")
    [void]$md.AppendLine("| Detection | $($item.Detection.Summary) |")
    [void]$md.AppendLine()

    $detailPairs = Get-DetailPair $item.Detection.Detail
    if ($detailPairs.Count -gt 0) {
        [void]$md.AppendLine('Detection rule fields:')
        [void]$md.AppendLine()
        [void]$md.AppendLine('| Portal field | Value |')
        [void]$md.AppendLine('| --- | --- |')
        foreach ($pair in $detailPairs) {
            if ($null -eq $pair.Value -or "$($pair.Value)".Trim() -eq '') { continue }
            [void]$md.AppendLine("| $($pair.Key) | $($pair.Value) |")
        }
        [void]$md.AppendLine()
    }

    if ($item.EngineNotes) { [void]$md.AppendLine("> Engine note: $($item.EngineNotes)"); [void]$md.AppendLine() }
    if ($item.Notes)       { [void]$md.AppendLine("> Note: $($item.Notes)"); [void]$md.AppendLine() }
}

$mdPath = Join-Path $OutputRoot 'command-sheet.md'
$md.ToString() | Set-Content -LiteralPath $mdPath -Encoding UTF8

$csvPath = Join-Path $OutputRoot 'command-sheet.csv'
$results |
    Select-Object Name, Publisher, Version, Engine, PackageName,
                  InstallCommand, UninstallCommand, InstallContext, RestartBehavior,
                  @{ Name = 'Detection'; Expression = { $_.Detection.Summary } },
                  ProductCode, NeedsReview, Notes |
    Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
Write-Host ''
Write-Step "Packaged   : $($results.Count)" 'Green'
Write-Step "Needs review: $($review.Count)" $(if ($review.Count -gt 0) { 'Yellow' } else { 'Green' })
Write-Step "Sheet      : $mdPath"
Write-Step "CSV        : $csvPath"

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Step "Failed: $($failures.Count)" 'Red'
    foreach ($failure in $failures) {
        Write-Host "  $($failure.Name): $($failure.Error)" -ForegroundColor Red
    }
    exit 1
}

exit 0
