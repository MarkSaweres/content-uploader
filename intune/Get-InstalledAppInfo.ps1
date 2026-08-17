#Requires -Version 5.1
<#
.SYNOPSIS
    Read the Add/Remove Programs entries on this machine so you can fill in
    detection rules and uninstall commands that cannot be derived from an
    installer file.

.DESCRIPTION
    Run this ON A TEST MACHINE, after installing the app manually with the
    silent switches from the command sheet. It reports, for each matching app:

      * the exact registry key Intune should detect on
      * DisplayVersion (the value to compare against)
      * QuietUninstallString / UninstallString
      * whether the entry lives in the 32-bit (WOW6432Node) hive, which decides
        the "Associated with a 32-bit app on 64-bit clients" toggle in Intune

    EXE installers almost always need this step - the ARP key name is only
    knowable after an install.

.PARAMETER Name
    Filter on DisplayName (wildcards OK). Omit to list everything.

.PARAMETER IncludeUser
    Also search HKCU, for apps that install per-user (Squirrel, some Chrome
    extensions-style installers). Those need USER install context in Intune.

.PARAMETER AsDetectionRule
    Print the ready-to-paste Intune detection rule fields for each match.

.EXAMPLE
    .\Get-InstalledAppInfo.ps1 -Name '*Notepad*' -AsDetectionRule

.EXAMPLE
    .\Get-InstalledAppInfo.ps1 -Name '*Zoom*' -IncludeUser
#>
[CmdletBinding()]
param(
    [string]$Name,
    [switch]$IncludeUser,
    [switch]$AsDetectionRule
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hives = @(
    [pscustomobject]@{
        Path     = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        Portal   = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        Is32Bit  = $false
        Scope    = 'Machine (64-bit)'
    }
    [pscustomobject]@{
        Path     = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        Portal   = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        Is32Bit  = $true
        Scope    = 'Machine (32-bit)'
    }
)

if ($IncludeUser) {
    $hives += [pscustomobject]@{
        Path     = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        Portal   = 'HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        Is32Bit  = $false
        Scope    = 'User'
    }
}

function Get-RegValue {
    param($Item, [string]$ValueName)
    $property = $Item.PSObject.Properties[$ValueName]
    if ($null -eq $property) { return $null }
    $property.Value
}

$foundApps = @()

foreach ($hive in $hives) {
    if (-not (Test-Path -LiteralPath $hive.Path)) { continue }

    $keys = Get-ChildItem -LiteralPath $hive.Path -ErrorAction SilentlyContinue
    foreach ($key in $keys) {
        $props = $null
        try { $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop }
        catch { continue }

        $displayName = Get-RegValue $props 'DisplayName'
        if (-not $displayName) { continue }

        # Skip update/patch entries - they are never the right detection target.
        $systemComponent = Get-RegValue $props 'SystemComponent'
        if ($systemComponent -eq 1) { continue }

        if ($Name -and ($displayName -notlike $Name)) { continue }

        $foundApps += [pscustomobject]@{
            DisplayName           = $displayName
            DisplayVersion        = Get-RegValue $props 'DisplayVersion'
            Publisher             = Get-RegValue $props 'Publisher'
            KeyName               = $key.PSChildName
            PortalKeyPath         = "$($hive.Portal)\$($key.PSChildName)"
            Scope                 = $hive.Scope
            Is32BitOn64           = $hive.Is32Bit
            UninstallString       = Get-RegValue $props 'UninstallString'
            QuietUninstallString  = Get-RegValue $props 'QuietUninstallString'
            InstallLocation       = Get-RegValue $props 'InstallLocation'
        }
    }
}

if ($foundApps.Count -eq 0) {
    Write-Host "No matching Add/Remove Programs entries found." -ForegroundColor Yellow
    if ($Name -and -not $IncludeUser) {
        Write-Host "Try -IncludeUser if the app installs per-user." -ForegroundColor DarkGray
    }
    exit 1
}

foreach ($entry in $foundApps) {
    Write-Host ''
    Write-Host $entry.DisplayName -ForegroundColor White
    Write-Host "  Version         : $($entry.DisplayVersion)"
    Write-Host "  Publisher       : $($entry.Publisher)"
    Write-Host "  Scope           : $($entry.Scope)"
    Write-Host "  Registry key    : $($entry.PortalKeyPath)"
    if ($entry.InstallLocation) { Write-Host "  Install location: $($entry.InstallLocation)" }

    $uninstall = $entry.QuietUninstallString
    if ($uninstall) {
        Write-Host "  Silent uninstall: $uninstall" -ForegroundColor Green
    }
    else {
        Write-Host "  Uninstall string: $($entry.UninstallString)" -ForegroundColor Yellow
        if ($entry.KeyName -match '^\{[0-9A-Fa-f-]{36}\}$') {
            Write-Host "  Suggested       : msiexec /x `"$($entry.KeyName)`" /qn /norestart" -ForegroundColor Green
        }
        else {
            Write-Host "  No QuietUninstallString - append the engine's silent switch by hand." -ForegroundColor DarkGray
        }
    }

    if ($AsDetectionRule) {
        $bit32 = 'No'
        if ($entry.Is32BitOn64) { $bit32 = 'Yes' }

        Write-Host ''
        Write-Host '  --- Intune detection rule ---' -ForegroundColor Cyan
        if ($entry.KeyName -match '^\{[0-9A-Fa-f-]{36}\}$' -and -not $entry.Is32BitOn64) {
            Write-Host "  Rule type                 : MSI"
            Write-Host "  MSI product code          : $($entry.KeyName)"
            Write-Host "  MSI product version check : Yes"
            Write-Host "  Operator                  : Greater than or equal to"
            Write-Host "  Value                     : $($entry.DisplayVersion)"
        }
        else {
            Write-Host "  Rule type                 : Registry"
            Write-Host "  Key path                  : $($entry.PortalKeyPath)"
            Write-Host "  Value name                : DisplayVersion"
            Write-Host "  Detection method          : String comparison"
            Write-Host "  Operator                  : Greater than or equal to"
            Write-Host "  Value                     : $($entry.DisplayVersion)"
            Write-Host "  Associated 32-bit app     : $bit32"
        }
    }
}

Write-Host ''
Write-Host "$($foundApps.Count) match(es)." -ForegroundColor Cyan
