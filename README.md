# W11 PostInstall

**A PowerShell CLI for Windows 11 post-install setup.** Debloat, privacy and interface tweaks, selectable applications, Chocolatey / WinGet, preview plans and registry rollback.

[Русская документация](README.ru.md) · [Usage](docs/usage.md) · [Compatibility](docs/compatibility.md) · [Recovery](docs/recovery.md) · [Roadmap](docs/roadmap.md)

## Status: 0.2.0-preview

This is an initial implementation, **not a Windows-version-certified optimizer**. Only offline, mocked tests have been run. No installers, Windows settings or security services were changed on the development machine. All compatibility entries are `Unverified`; live Apply requires explicit acknowledgement.

- Windows PowerShell 5.1; no extra runtime or module installation.
- Color wizard in Russian and English: profile and app choices, one final confirmation, automatic execution. Advanced menu remains available via `-Mode Menu`.
- **Chocolatey (recommended)** is the default when present. The wizard uses WinGet when it is the only available provider and asks which to use when both are present.
- 104 app choices across browsers, editors, communication, gaming, office, creative and AI tools, including 19 ArtCraft entries. Package mappings are **candidates**, not validated installation results.
- 15 current-user registry tweaks and 13 exact current-user Appx removal actions.
- Read-only planning, plan integrity checks, state-drift detection, intent journals, registry recovery with conflict detection.
- Defender status inspection. **Defender removal is blocked** until a method passes isolated VM validation. Acceptance flags cannot enable it.

## Start

Download [W11PostInstall.ps1](https://github.com/krambovic/w11-postinstall/releases/download/v0.2.0-preview/W11PostInstall.ps1). It includes the engine, catalogs, profiles and translations. No adjacent files are required.

```powershell
.\W11PostInstall.ps1 -Language en-US -WhatIf  # noninteractive preview
.\W11PostInstall.ps1 -Language en-US          # guided setup
.\W11PostInstall.ps1 -Mode Menu -Language en-US
```

The wizard defaults to Balanced and Firefox, 7-Zip, VLC and Notepad++. After confirmation it applies the plan and requests UAC only if app installation requires elevation. No package-manager bootstrap or ExecutionPolicy bypass is included. In a source checkout, `Start.ps1` provides the same commands.

Planning is read-only unless you explicitly request an output file:

```powershell
.\Start.ps1 -Mode Plan -Profile Balanced
.\Start.ps1 -Mode Plan -Profile Custom -Provider Choco -Apps firefox,vlc,7zip -OutFile .\plan.json
.\Start.ps1 -Mode Plan -Profile Custom -Provider Winget -Apps zen,localsend,photocraft
.\Start.ps1 -Mode Apply -PlanFile .\plan.json -WhatIf
```

The ArtCraft lineup links to official sources for manual installation. Package availability and unattended behavior have not been confirmed, so the tool does not invent package IDs or silently fall back to another manager.

Actual Apply changes Windows and can download/install selected apps. Read [usage](docs/usage.md) first. There is no automatic package-manager bootstrap, no automatic upgrade of existing apps, and no automatic reboot requested by this script. Third-party installers can still have their own behavior.

## Offline tests

```powershell
powershell.exe -NoProfile -File .\tests\Test-Offline.ps1
# Optional, only if already installed:
pwsh.exe -NoProfile -File .\tests\Test-Offline.ps1
```

The dependency-free harness parses scripts/JSON and simulates providers entirely in memory. It does not run Chocolatey, WinGet, installers, registry writes, Appx removal, network access or VM creation. GitHub Actions runs the same harness; it does not apply Windows tweaks.

## Limits

Target releases: Windows 11 21H2–26H2, including a separate 26H1 entry. Preview Apply is restricted to listed x64 Home/Pro editions from a 64-bit process; this detection does not constitute compatibility testing. ARM64, Enterprise, LTSC, N and other editions need separate validation.

Automatic restore covers original registry **values**. Removed app data is not backed up; Appx apps require reinstalling, installed applications require manual removal. There is no full-system transaction or image backup. See [recovery](docs/recovery.md).

MIT license for this project. Third-party software retains its own licenses.
