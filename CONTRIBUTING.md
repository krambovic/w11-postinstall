# Contributing

Keep runtime compatible with Windows PowerShell 5.1. Save PowerShell files containing non-ASCII as UTF-8 with BOM. No runtime dependency downloads, shell-evaluated JSON or unchecked remote script execution.

Run `powershell.exe -NoProfile -File tests/Test-Offline.ps1` before submitting. Tests must not mutate the host OS or install applications. Changes to native providers need command-generation tests and failure/reboot handling. Each live test needs an explicitly authorized disposable VM with a snapshot; never use a hosted CI runner as a debloat target.

App submissions need an official website, exact manager IDs, license and scope review, supported architecture, current release validation and documented silent behavior. Do not add unverified guessed IDs; leave unsupported providers empty. ArtCraft manual links are intentional.

New actions need a stable ID, RU/EN explanation, applicability, risk, exact target, detection, postcondition and honest recovery strategy. Keep critical dependencies protected. Add evidence of an observable benefit before calling an action a performance optimization.

Do not publish logs containing private user paths or machine identifiers. Keep changes focused and include a brief validation report.
