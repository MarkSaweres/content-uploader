#Requires -Version 5.1
<#
.SYNOPSIS
    Inspect a folder of installers and print what each one is, plus a ready-made
    apps.json block you can paste into the manifest.

.DESCRIPTION
    Run this first, before building anything. It fingerprints each installer's
    engine, pulls the MSI product code and version where available, and suggests
    the silent switches. Use it to bootstrap the manifest for a batch of apps
    instead of hand-writing 20 entries.

    Expects one folder per app under -InstallerRoot:

        installers\
            7zip\7z2409-x64.msi
            notepadplusplus\npp.8.7.1.Installer.x64.exe

    A flat folder of installers also works; each file is then treated as its
    own app.

.PARAMETER InstallerRoot
    Folder to scan. Defaults to .\installers next to this script.

.PARAMETER EmitManifest
    Write the suggested manifest to this path instead of printing it.

.EXAMPLE
    .\Inspect-Installers.ps1

.EXAMPLE
    .\Inspect-Installers.ps1 -InstallerRoot D:\Packaging -EmitManifest .\apps.generated.json
#>
[CmdletBinding()]
param(
    [string]$InstallerRoot,
    [string]$EmitManifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Join-Path $PSScriptRoot 'lib') 'IntunePack.psm1') -Force

if (-not $InstallerRoot) { $InstallerRoot = Join-Path $PSScriptRoot 'installers' }
if (-not (Test-Path -LiteralPath $InstallerRoot)) {
    throw "Installer root not found: '$InstallerRoot'. Create it and drop one folder per app inside."
}
$InstallerRoot = (Resolve-Path -LiteralPath $InstallerRoot).ProviderPath

$extensions = @('.msi', '.exe', '.msix', '.appx')

$candidates = Get-ChildItem -LiteralPath $InstallerRoot -Recurse -File |
    Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() }

if (-not $candidates) {
    throw "No .msi/.exe/.msix files found under '$InstallerRoot'."
}

Write-Host "Scanning $($candidates.Count) installer(s) under $InstallerRoot" -ForegroundColor Cyan
Write-Host ''

$entries = @()
$report = @()

foreach ($file in $candidates) {
    Write-Host "  $($file.Name)" -ForegroundColor White

    try {
        $info = Get-InstallerInfo -Path $file.FullName
    }
    catch {
        Write-Host "    FAILED: $($_.Exception.Message)" -ForegroundColor Red
        continue
    }

    # Folder name is the best guess at the app grouping; fall back to the file.
    $parent = Split-Path -Parent $file.FullName
    $relativeFolder = $parent.Substring($InstallerRoot.Length).TrimStart('\', '/')
    if (-not $relativeFolder) { $relativeFolder = '.' }

    $appName = $info.ProductName
    if (-not $appName) {
        if ($relativeFolder -ne '.') { $appName = Split-Path -Leaf $parent }
        else { $appName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
    }

    $installCommand = New-InstallCommand -SetupFile $file.Name -Engine $info.Engine
    $uninstallCommand = New-UninstallCommand -SetupFile $file.Name -Engine $info.Engine -ProductCode $info.ProductCode

    Write-Host "    engine     : $($info.EngineDisplay)"
    Write-Host "    version    : $($info.ProductVersion)"
    if ($info.ProductCode) { Write-Host "    productcode: $($info.ProductCode)" }
    Write-Host "    install    : $installCommand"
    Write-Host "    uninstall  : $uninstallCommand"
    if ($info.EngineNotes) { Write-Host "    note       : $($info.EngineNotes)" -ForegroundColor DarkGray }
    Write-Host ''

    $report += [pscustomobject]@{
        Name        = $appName
        Engine      = $info.Engine
        Version     = $info.ProductVersion
        ProductCode = $info.ProductCode
        SizeMB      = $info.SizeMB
        File        = $file.Name
    }

    # Ordered so the emitted JSON matches the shape documented in apps.json.
    $entries += [ordered]@{
        name             = $appName
        publisher        = $info.Manufacturer
        version          = $info.ProductVersion
        sourceFolder     = $relativeFolder
        setupFile        = $file.Name
        installCommand   = $null
        uninstallCommand = $null
        extraArguments   = $null
        installContext   = 'system'
        restartBehavior  = 'suppress'
        detection        = $null
        notes            = $info.EngineNotes
        skip             = $false
    }
}

if ($entries.Count -eq 0) { throw 'Nothing could be inspected.' }

Write-Host 'Summary' -ForegroundColor Cyan
$report | Format-Table -AutoSize

$manifest = [ordered]@{
    defaults = [ordered]@{
        installContext  = 'system'
        restartBehavior = 'suppress'
    }
    apps = $entries
}

$json = $manifest | ConvertTo-Json -Depth 6

if ($EmitManifest) {
    $json | Set-Content -LiteralPath $EmitManifest -Encoding UTF8
    Write-Host "Suggested manifest written to $EmitManifest" -ForegroundColor Green
    Write-Host 'Review it, then point Build-IntuneApps.ps1 at it with -ManifestPath.' -ForegroundColor DarkGray
}
else {
    Write-Host 'Suggested manifest:' -ForegroundColor Cyan
    Write-Host ''
    Write-Host $json
}
