# Intune Win32 app packaging

Batch-builds `.intunewin` packages and generates the install command, uninstall
command and detection rule for each app, so adding 20 apps to Intune is one
manifest edit and one command instead of 20 rounds of portal clicking.

This wraps Microsoft's official
[IntuneWinAppUtil.exe](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool),
so the packages are byte-for-byte what the supported tool produces. Nothing here
talks to Intune or Graph — you still create the apps in the portal, pasting in
values from the generated command sheet.

## Requirements

- Windows (the content prep tool is a Windows binary, and MSI inspection uses
  the `WindowsInstaller` COM object)
- Windows PowerShell 5.1 or PowerShell 7+

## Layout

```
intune/
  Inspect-Installers.ps1     # step 1: what are these installers?
  Build-IntuneApps.ps1       # step 2: build packages + command sheet
  Get-InstalledAppInfo.ps1   # step 3: run on a test VM to confirm detection
  apps.json                  # the manifest you edit
  lib/IntunePack.psm1        # shared logic
  installers/                # you create this - one folder per app (gitignored)
  tools/                     # IntuneWinAppUtil.exe lands here (gitignored)
  output/                    # packages + command sheet (gitignored)
```

Installers and packages are **not** committed — they are large binaries and
often licensed. Only the manifest and scripts belong in git.

## Workflow

### 1. Drop in the installers, one folder per app

```
intune\installers\
    7zip\7z2409-x64.msi
    notepadplusplus\npp.8.7.1.Installer.x64.exe
    acrobat\AcroRdrDC.exe
```

Everything in an app's folder goes into its `.intunewin`, so put transforms
(`.mst`), license files, config files and wrapper scripts alongside the setup
file.

### 2. Inspect them

```powershell
cd intune
.\Inspect-Installers.ps1
```

This fingerprints each installer's engine (MSI, Inno Setup, NSIS, WiX Burn,
InstallShield, Squirrel), pulls the MSI product code and version, and suggests
silent switches. To skip hand-writing 20 manifest entries:

```powershell
.\Inspect-Installers.ps1 -EmitManifest .\apps.json
```

Then review `apps.json` — check the names, versions and any app needing a
license key or extra arguments.

### 3. Build

```powershell
.\Build-IntuneApps.ps1 -DownloadTool
```

`-DownloadTool` fetches `IntuneWinAppUtil.exe` into `tools\` on first run; drop
it there yourself if the machine has no internet access.

Useful flags:

| Flag | Effect |
| --- | --- |
| `-Only '7-Zip','Notepad*'` | Build a subset (wildcards OK) |
| `-SkipPackaging` | Regenerate the command sheet without re-packaging |
| `-ManifestPath` / `-InstallerRoot` / `-OutputRoot` | Override the default paths |
| `-ToolPath` | Point at an existing IntuneWinAppUtil.exe |

Output lands in `output\`:

- `output\<App>\<App>_<Version>.intunewin` — upload this to Intune
- `output\<App>\app.json` — the resolved values for that one app
- `output\command-sheet.md` — every app's portal fields, ready to paste
- `output\command-sheet.csv` — same thing, for tracking progress across 20 apps

### 4. Confirm detection on a test VM

The build flags any app whose detection rule or uninstall command could not be
derived from the installer file alone, under **Needs review** in the command
sheet. That is normal and expected for EXE installers: the Add/Remove Programs
key name simply does not exist until the app is installed.

Install the app on a test machine using the generated install command, then:

```powershell
.\Get-InstalledAppInfo.ps1 -Name '*Notepad*' -AsDetectionRule
```

It prints the exact registry key, the `DisplayVersion` to compare against, the
real `QuietUninstallString`, and whether the entry is in the 32-bit hive (which
decides the "Associated with a 32-bit app on 64-bit clients" toggle). Paste
those back into `apps.json` as an override and re-run with `-SkipPackaging`.

## Filling in the Intune portal

For each app: **Apps → Windows → Add → Windows app (Win32)**, upload the
`.intunewin`, then map from the command sheet:

| Portal field | Source |
| --- | --- |
| Install command | `Install command` |
| Uninstall command | `Uninstall command` |
| Install behavior | `Install behavior` (System unless the app is per-user) |
| Device restart behavior | `Device restart behavior` |
| Detection rules → Manually configure | The `Detection rule fields` table |
| Return codes | The list at the top of the sheet |

Set return codes on every app: `0` and `1707` success, `3010` soft reboot,
`1641` hard reboot, `1618` retry.

## Notes that save time

- **Uninstall by product code, not by file.** For MSIs the generated uninstall
  uses `msiexec /x {ProductCode}`, which keeps working after the source file is
  gone. `msiexec /x package.msi` does not.
- **NSIS `/S` is case sensitive.** Lowercase `/s` silently opens the GUI, the
  install times out, and Intune reports a failure with no useful log.
- **Per-user installers need USER install context.** Squirrel-based apps (Teams
  classic, some Electron apps) install to `%LOCALAPPDATA%`; deploying them as
  SYSTEM installs them into the system profile where no one can see them.
- **Detect on a version, not just existence.** A detection rule that only checks
  a key exists will report the app installed forever, and the app will never
  update. Use `Greater than or equal to` against `DisplayVersion`.
- **Old InstallShield needs a response file.** Record one with
  `setup.exe /r /f1"C:\setup.iss"`, ship the `.iss` in the app folder, then
  install with `setup.exe /s /f1".\setup.iss"`.
- **Check the install works as SYSTEM, not just as you.** Test with
  `PsExec -s -i cmd.exe` before blaming Intune.
