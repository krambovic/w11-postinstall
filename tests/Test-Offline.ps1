#requires -Version 5.1
# Offline harness: no dependency installation, package manager, network or Windows mutations.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = 0
$checks = 0
function Assert-Test {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if (-not $Condition) { $script:failures++; Write-Host "FAIL: $Message" -ForegroundColor Red }
}

# The parser inspects source without executing entry points.
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') }) {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert-Test ($errors.Count -eq 0) ("Syntax: {0}: {1}" -f $file.Name, (@($errors | ForEach-Object { $_.Message }) -join '; '))
}
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Filter '*.json' -File) {
    try { $null = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; Assert-Test $true "JSON: $($file.Name)" }
    catch { Assert-Test $false "JSON: $($file.Name)" }
}
Import-Module (Join-Path $root 'src/Wpi.psm1') -Force
$catalog = Get-WpiCatalog
Assert-Test ($catalog.Apps.Count -ge 100) 'Expanded app catalog'
Assert-Test (@($catalog.Apps.Id | Select-Object -Unique).Count -eq $catalog.Apps.Count) 'Unique app IDs'
Assert-Test (@($catalog.Actions.Id | Select-Object -Unique).Count -eq $catalog.Actions.Count) 'Unique action IDs'
Assert-Test (@($catalog.Apps | Where-Object { $_.Category -eq 'ArtCraft' }).Count -ge 18) 'ArtCraft lineup'
foreach ($app in $catalog.Apps) {
    Assert-Test ($app.Id -match '^[a-z0-9-]+$') "App slug $($app.Id)"
    Assert-Test ($app.Website -match '^https://') "Official HTTPS link $($app.Id)"
    foreach ($provider in @('Choco', 'Winget')) {
        Assert-Test (-not $app.$provider -or $app.$provider -match '^[A-Za-z0-9][A-Za-z0-9.+_-]*$') "Package ID $($app.Id) / $provider"
    }
}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'profiles') -Filter '*.json') {
    $profile = Read-WpiJson $file.FullName
    foreach ($id in $profile.Actions) { Assert-Test ($id -in $catalog.Actions.Id) "Profile action $id" }
    foreach ($id in $profile.Apps) { Assert-Test ($id -in $catalog.Apps.Id) "Profile app $id" }
    Assert-Test ('defender.remove' -notin $profile.Actions) 'No implicit Defender removal'
}
$ru = Read-WpiJson (Join-Path $root 'locales/ru-RU.json')
$en = Read-WpiJson (Join-Path $root 'locales/en-US.json')
Assert-Test (($ru.PSObject.Properties.Name -join '|') -eq ($en.PSObject.Properties.Name -join '|')) 'Locale parity'

$module = Get-Module Wpi
$results = & $module {
    $script:Assertions = @()
    function Check { param([bool]$Condition, [string]$Message); $script:Assertions += [pscustomobject]@{ Passed = $Condition; Message = $Message } }
    function Throws {
        param([scriptblock]$Block, [string]$Message)
        $thrown = $false
        try { & $Block | Out-Null } catch { $thrown = $true }
        Check $thrown $Message
    }
    $script:FakeSystem = [pscustomobject]@{
        Build = 26100; UBR = 1; Release = '24H2'; Edition = 'Professional'; Architecture = 'AMD64'
        Sid = 'S-1-5-21-OFFLINE-TEST'; IsAdmin = $true; Is64BitProcess = $true
        KnownBuild = $true; PreviewSupported = $true; Validation = 'Unverified'
        Providers = [pscustomobject]@{ Choco = $true; Winget = $true }
    }
    $script:Registry = @{}; $script:Appx = @{}; $script:Installed = $false
    $script:Writes = @(); $script:NativeCalls = 0; $script:OpenCalls = 0; $script:RegistryWrites = 0
    $script:NativeCode = 0
    function script:Get-WpiSystem { $script:FakeSystem }
    function script:Get-WpiInstalledApps { @() }
    function script:Get-WpiRegistryState {
        param($Action)
        if ($script:Registry.ContainsKey($Action.Id)) { return $script:Registry[$Action.Id] }
        [pscustomobject][ordered]@{ KeyExists = $true; Exists = $false; Kind = $null; Value = $null }
    }
    function script:Set-WpiRegistryState { param($Action, $State); $script:RegistryWrites++; $script:Registry[$Action.Id] = $State }
    function script:Get-AppxPackage {
        param($Name, $ErrorAction)
        if ($script:Appx.ContainsKey($Name)) { $script:Appx[$Name] }
    }
    function script:Remove-AppxPackage { param($Package, $ErrorAction); $script:Appx.Clear() }
    function script:Open-WpiState {
        param($DataRoot)
        $script:OpenCalls++
        $lock = New-Object psobject
        $lock | Add-Member ScriptMethod Dispose { }
        [pscustomobject]@{ Root = $DataRoot; Lock = $lock }
    }
    function script:Write-WpiJson {
        param($Path, $Value)
        $script:Writes += ,($Value | ConvertTo-Json -Depth 40 | ConvertFrom-Json)
    }
    function script:Get-WpiRun { param($DataRoot, $RunId); $script:Writes[-1] }
    function script:Get-WpiProviderExecutable { param($Provider); 'offline-fake.exe' }
    function script:Test-WpiManagedApp { param($App, $Provider, $Executable); $script:Installed }
    function script:Invoke-WpiNative {
        param($Executable, $Arguments, $TimeoutSeconds)
        $script:NativeCalls++
        $script:Installed = ($script:NativeCode -eq 0)
        [pscustomobject]@{ ExitCode = $script:NativeCode; Output = ''; ErrorOutput = '' }
    }

    $plan = New-WpiPlan -Profile Custom -Actions @('explorer.extensions', 'explorer.extensions') -Apps @('firefox', 'photocraft')
    Check (@($plan.Payload.Entries).Count -eq 3) 'Planner deduplicates explicit IDs'
    Check ($plan.Payload.Provider -eq 'Choco') 'Chocolatey is the default'
    Check (@($plan.Payload.Entries | Where-Object { $_.Id -eq 'app.photocraft' -and $_.Status -eq 'Manual' }).Count -eq 1) 'Unverified ArtCraft IDs are manual'
    Check ($script:NativeCalls -eq 0 -and $script:OpenCalls -eq 0 -and $script:RegistryWrites -eq 0) 'Plan performs no writes or native execution'
    $dry = Invoke-WpiPlan -Plan $plan -DataRoot 'D:\OFFLINE-TEST-NEVER-CREATED' -WhatIf
    Check ($dry.Status -eq 'Preview') 'WhatIf returns preview'
    Check ($script:NativeCalls -eq 0 -and $script:OpenCalls -eq 0 -and $script:Writes.Count -eq 0 -and $script:RegistryWrites -eq 0) 'WhatIf has zero side effects'
    Throws { New-WpiPlan -Profile Custom -Apps @('unknown') } 'Unknown app rejected'
    Throws { New-WpiPlan -Profile Custom -Actions @('bogus') } 'Unknown action rejected'
    $roundtrip = $plan | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $null = Assert-WpiPlan $roundtrip
    Check $true 'JSON round-trip retains plan digest'
    $roundtrip.Payload.Provider = 'Winget'
    Throws { Assert-WpiPlan $roundtrip } 'Tampered plan rejected'
    $roundtrip = $plan | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $roundtrip.Payload.CatalogHash = 'old'
    $roundtrip.Digest = Get-WpiHash $roundtrip.Payload
    Throws { Assert-WpiPlan $roundtrip } 'Catalog drift rejected'
    $script:FakeSystem.Sid = 'another-user'
    Throws { Assert-WpiPlan $plan } 'Cross-user plan rejected'
    $script:FakeSystem.Sid = 'S-1-5-21-OFFLINE-TEST'
    $script:FakeSystem.UBR = 2
    Throws { Assert-WpiPlan $plan } 'Windows servicing drift rejected'
    $script:FakeSystem.UBR = 1
    Throws { Invoke-WpiPlan -Plan $plan -DataRoot 'D:\FAKE' -Confirm:$false } 'Apply requires unverified compatibility acknowledgement'
    Throws { Invoke-WpiPlan -Plan $plan -DataRoot 'D:\FAKE' -AllowUnverified -Confirm:$false } 'App installation requires license acceptance'
    $script:FakeSystem.PreviewSupported = $false
    Throws { Invoke-WpiPlan -Plan $plan -DataRoot 'D:\FAKE' -AllowUnverified -AcceptAgreements -Confirm:$false } 'Unknown platform blocked'
    $script:FakeSystem.PreviewSupported = $true
    $script:Registry['explorer.extensions'] = [pscustomobject][ordered]@{ KeyExists = $true; Exists = $true; Kind = 'DWord'; Value = 99 }
    Throws { Invoke-WpiPlan -Plan $plan -DataRoot 'D:\FAKE' -AllowUnverified -AcceptAgreements -Confirm:$false } 'State drift blocks entire plan'
    $script:Registry.Clear()
    $registryPlan = New-WpiPlan -Profile Custom -Actions @('explorer.extensions')
    $applied = Invoke-WpiPlan -Plan $registryPlan -DataRoot 'D:\FAKE' -AllowUnverified -Confirm:$false
    Check ($applied.Status -eq 'Completed' -and $applied.Entries[0].Status -eq 'Verified') 'Registry apply and verify'
    Check (@($script:Writes | Where-Object { @($_.Entries | Where-Object { $_.Status -eq 'Applying' }).Count -gt 0 }).Count -gt 0) 'Intent persisted before action'
    $repeat = New-WpiPlan -Profile Custom -Actions @('explorer.extensions')
    Check ($repeat.Payload.Entries[0].Status -eq 'AlreadyCompliant') 'Idempotent repeat'
    $restored = Restore-WpiRun -DataRoot 'D:\FAKE' -RunId $applied.RunId -Confirm:$false
    Check ($restored.Status -eq 'Restored' -and -not $script:Registry['explorer.extensions'].Exists) 'Restore absent original value'

    $script:Registry['explorer.extensions'] = [pscustomobject][ordered]@{ KeyExists = $true; Exists = $true; Kind = 'DWord'; Value = 1 }
    $existingPlan = New-WpiPlan -Profile Custom -Actions @('explorer.extensions')
    $applied = Invoke-WpiPlan -Plan $existingPlan -DataRoot 'D:\FAKE' -AllowUnverified -Confirm:$false
    $script:Registry['explorer.extensions'] = [pscustomobject][ordered]@{ KeyExists = $true; Exists = $true; Kind = 'DWord'; Value = 77 }
    $conflict = Restore-WpiRun -DataRoot 'D:\FAKE' -RunId $applied.RunId -Confirm:$false
    Check ($conflict.Status -eq 'PartialRestore' -and $script:Registry['explorer.extensions'].Value -eq 77) 'Restore preserves subsequent external change'

    $script:Appx['Clipchamp.Clipchamp'] = [pscustomobject]@{ Name = 'Clipchamp.Clipchamp'; PackageFullName = 'FAKE-PACKAGE' }
    $remove = New-WpiPlan -Profile Custom -Actions @('debloat.clipchamp')
    Throws { Invoke-WpiPlan -Plan $remove -DataRoot 'D:\FAKE' -AllowUnverified -Confirm:$false } 'Appx removal requires explicit risk consent'
    $removed = Invoke-WpiPlan -Plan $remove -DataRoot 'D:\FAKE' -AllowUnverified -AcceptRisk -Confirm:$false
    Check ($removed.Entries[0].Status -eq 'Verified' -and $script:Appx.Count -eq 0) 'Exact current-user Appx removal simulation'
    $manual = Restore-WpiRun -DataRoot 'D:\FAKE' -RunId $removed.RunId -Confirm:$false
    Check ($manual.Status -eq 'PartialRestore') 'Appx restore is honestly manual'

    $defender = New-WpiPlan -Profile Custom -Actions @('defender.remove')
    Check ($defender.Payload.Entries[0].Status -eq 'Unsupported') 'Defender removal cannot be enabled by acceptance flags'
    $app = (Get-WpiCatalog).Apps | Where-Object { $_.Id -eq 'firefox' }
    $choco = Get-WpiInstallCommand $app Choco
    $winget = Get-WpiInstallCommand $app Winget
    Check ($choco.Arguments[0] -eq 'install' -and $choco.Arguments[1] -eq 'firefox') 'Chocolatey exact package command'
    Check ('--source=https://community.chocolatey.org/api/v2' -in $choco.Arguments) 'Explicit Chocolatey source'
    Check ('--no-upgrade' -in $winget.Arguments -and '--exact' -in $winget.Arguments) 'WinGet does not upgrade existing apps'
    Check ('--force' -notin $choco.Arguments -and '--ignore-security-hash' -notin $winget.Arguments) 'No integrity bypass'
    Throws { Get-WpiInstallCommand ([pscustomobject]@{ Choco = 'x;calc' }) Choco } 'Shell-like package ID rejected'
    Throws { Get-WpiInstallCommand ([pscustomobject]@{ Choco = 'all' }) Choco } 'Chocolatey all keyword rejected'
    $install = New-WpiPlan -Profile Custom -Apps @('firefox')
    $script:NativeCode = 0; $script:Installed = $false
    $result = Invoke-WpiPlan -Plan $install -DataRoot 'D:\FAKE' -AllowUnverified -AcceptAgreements -Confirm:$false
    Check ($result.Entries[0].Status -eq 'Verified') 'App provider apply/verify simulation'
    $script:Installed = $false; $script:NativeCode = 3010
    $reboot = Invoke-WpiPlan -Plan $install -DataRoot 'D:\FAKE' -AllowUnverified -AcceptAgreements -Confirm:$false
    Check ($reboot.ExitCode -eq 3010) 'Reboot required is distinct from success'
    $script:Installed = $false; $script:NativeCode = 1
    $failed = Invoke-WpiPlan -Plan $install -DataRoot 'D:\FAKE' -AllowUnverified -AcceptAgreements -Confirm:$false
    Check ($failed.ExitCode -eq 2 -and $failed.Entries[0].Status -eq 'Failed') 'Installer failure returns partial result'
    Check ($failed.Entries[0].NativeExitCode -eq 1) 'Raw installer error code is retained'
    $twoApps = New-WpiPlan -Profile Custom -Apps @('firefox', 'vlc')
    $stopped = Invoke-WpiPlan -Plan $twoApps -DataRoot 'D:\FAKE' -AllowUnverified -AcceptAgreements -Confirm:$false
    Check ($stopped.Entries.Count -eq 2 -and $stopped.Entries[1].Status -eq 'Skipped') 'Failure journals remaining actions as skipped'
    $wingetPlan = New-WpiPlan -Profile Custom -Provider Winget -Apps @('firefox')
    $script:NativeCode = -1978334967
    $reboot = Invoke-WpiPlan -Plan $wingetPlan -DataRoot 'D:\FAKE' -AllowUnverified -AcceptAgreements -Confirm:$false
    Check ($reboot.ExitCode -eq 3010 -and $reboot.Entries[0].NativeExitCode -eq -1978334967) 'WinGet HRESULT reboot mapping'
    $script:FakeSystem.Providers.Choco = $false
    $missing = New-WpiPlan -Profile Custom -Apps @('firefox')
    Check ($missing.Payload.Entries[0].Status -eq 'Blocked') 'Missing provider is blocked without bootstrap'
    . (Join-Path $script:Root 'src/Wizard.ps1')
    $script:WizardCalls = 0; $script:WizardPrompts = 0; $script:WizardElevations = 0
    $script:WizardAnswers = [Collections.Generic.Queue[string]]::new()
    function Read-Host {
        param([string]$Prompt)
        $script:WizardPrompts++
        if (-not $script:WizardAnswers.Count) { throw "Unexpected wizard prompt: $Prompt" }
        $script:WizardAnswers.Dequeue()
    }
    function Invoke-WpiPlan {
        param($Plan, $DataRoot, [switch]$AllowUnverified, [switch]$AcceptAgreements, [switch]$AcceptRisk, [switch]$ShowProgress, [switch]$Confirm)
        $script:WizardCalls++
        $script:WizardPlan = $Plan
        $script:WizardConsent = $AllowUnverified -and $AcceptAgreements -and $AcceptRisk
        [pscustomobject]@{ Status = 'Completed'; ExitCode = 0; RunId = $null }
    }
    function Invoke-WpiElevatedPlan {
        param($Plan, $DataRoot, $EntryScript, $Language, [switch]$AcceptRisk)
        $script:WizardElevations++
        0
    }
    $wizardArgs = @{ Profile = 'Balanced'; Apps = @(); Actions = @(); Language = 'en-US'; DataRoot = 'D:\FAKE'; EntryScript = 'D:\FAKE.ps1' }
    $preview = Invoke-WpiWizard @wizardArgs -Preview
    Check ($preview -eq 0 -and $script:WizardCalls -eq 0 -and $script:WizardPrompts -eq 0 -and $script:WizardElevations -eq 0) 'Wizard preview prompts for nothing and makes no changes'
    $script:Appx['Microsoft.Getstarted'] = [pscustomobject]@{ Name = 'Microsoft.Getstarted'; PackageFullName = 'FAKE-PACKAGE' }
    foreach ($answer in @('', '', 'y')) { $script:WizardAnswers.Enqueue($answer) }
    $run = Invoke-WpiWizard @wizardArgs
    Check ($run -eq 0 -and $script:WizardCalls -eq 1 -and $script:WizardPrompts -eq 3) 'Wizard selects defaults then applies once after one combined consent'
    Check ($script:WizardPlan.Payload.Provider -eq 'Winget' -and $script:WizardConsent) 'Wizard falls back to installed WinGet and passes app and Appx consent'
    Check (@($script:WizardPlan.Payload.Entries | Where-Object { $_.Kind -eq 'App' }).Count -eq 4) 'Wizard defaults to the four essential apps'
    foreach ($answer in @('', '')) { $script:WizardAnswers.Enqueue($answer) }
    $cancel = Invoke-WpiWizard @wizardArgs -ProfileFixed
    Check ($cancel -eq 3 -and $script:WizardCalls -eq 1) 'Declining confirmation leaves Windows untouched'
    Throws { Invoke-WpiWizard @wizardArgs -NonInteractive } 'Unattended wizard requires explicit consent flags'
    $script:FakeSystem.IsAdmin = $false
    foreach ($answer in @('', 'y')) { $script:WizardAnswers.Enqueue($answer) }
    $elevated = Invoke-WpiWizard @wizardArgs -ProfileFixed
    Check ($elevated -eq 0 -and $script:WizardElevations -eq 1 -and $script:WizardCalls -eq 1) 'Approved app setup requests elevation once'
    $script:Assertions
}
foreach ($result in $results) { Assert-Test $result.Passed $result.Message }
Write-Host ("{0} checks; {1} failures. No network, installations or Windows changes." -f $checks, $failures)
if ($failures -gt 0) { exit 1 }
