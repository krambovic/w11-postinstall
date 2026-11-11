function Read-WpiWizardChoice {
    param([string]$Prompt, [string[]]$Valid, [string]$Default)
    while ($true) {
        $answer = (Read-Host "$Prompt [$Default]").Trim()
        if (-not $answer) { return $Default }
        if ($answer -in $Valid) { return $answer }
        Write-Host ('  ' + ($Valid -join ' / ')) -ForegroundColor Yellow
    }
}

function Show-WpiWizardResult {
    param($Result, $Text)
    $color = if ($Result.ExitCode -eq 0) { 'Green' } elseif ($Result.ExitCode -eq 3 -or $Result.ExitCode -eq 3010) { 'Yellow' } else { 'Red' }
    Write-Host ''
    Write-Host ('  ' + $Text.Result + '  /  ' + $Result.Status) -ForegroundColor $color
    if ($Result.RunId) {
        Write-Host ('  ' + $Text.Journal + ': ' + $Result.JournalPath) -ForegroundColor DarkCyan
        foreach ($entry in $Result.Entries | Where-Object { $_.Status -in @('Failed','Blocked','Unsupported','Manual','Skipped') }) {
            Write-Host ('  {0,-11} {1}  {2}' -f $entry.Status, $entry.Id, $entry.Error) -ForegroundColor Yellow
        }
    }
}

function Invoke-WpiElevatedPlan {
    param($Plan, [string]$DataRoot, [string]$EntryScript, [string]$Language, [switch]$AcceptRisk)
    # Pass the approved plan as data. Apply revalidates it and requires the original SID.
    $planFile = Join-Path ([IO.Path]::GetTempPath()) ('wpi-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        Write-WpiJson $planFile $Plan
        $exe = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
        $scriptPath = [IO.Path]::GetFullPath($EntryScript)
        $statePath = [IO.Path]::GetFullPath($DataRoot) -replace '(\\+)$', '$1$1'
        if ($scriptPath.Contains('"') -or $statePath.Contains('"') -or $planFile.Contains('"')) { throw 'Unexpected quote in elevation path.' }
        $arguments = @('-NoProfile', '-NonInteractive', '-File', ('"{0}"' -f $scriptPath), '-Mode', 'Apply',
            '-PlanFile', ('"{0}"' -f $planFile), '-DataRoot', ('"{0}"' -f $statePath), '-Language', $Language,
            '-AllowUnverified', '-AcceptAgreements', '-ShowProgress')
        if ($AcceptRisk) { $arguments += '-AcceptRisk' }
        try {
            $process = Start-Process -FilePath (Join-Path $PSHOME $exe) -Verb RunAs -ArgumentList $arguments -Wait -PassThru
            return $process.ExitCode
        } catch {
            if ($_.Exception -is [ComponentModel.Win32Exception] -and $_.Exception.NativeErrorCode -eq 1223) { return 3 }
            throw
        }
    } finally {
        if ([IO.File]::Exists($planFile)) { [IO.File]::Delete($planFile) }
    }
}

function Invoke-WpiWizard {
    param([string]$Profile, [string]$Provider, [string[]]$Apps, [string[]]$Actions, [string]$Language,
        [string]$DataRoot, [string]$EntryScript, [switch]$NonInteractive, [switch]$Preview,
        [switch]$ProfileFixed, [switch]$AppsFixed, [switch]$AcceptAgreements, [switch]$AcceptRisk, [switch]$AllowUnverified)
    $text = Read-WpiAsset "locales/wizard-$Language.json"
    $system = Get-WpiSystem
    $interactive = -not ($NonInteractive -or $Preview)
    Write-Host ''
    Write-Host '  +--------------------------------------------------+' -ForegroundColor DarkCyan
    Write-Host '  |  W11  /  P O S T I N S T A L L      0.2 PREVIEW  |' -ForegroundColor Cyan
    Write-Host '  +--------------------------------------------------+' -ForegroundColor DarkCyan
    Write-Host ('     Windows {0}  /  {1}.{2}  /  {3}' -f $system.Release, $system.Build, $system.UBR, $system.Edition) -ForegroundColor Gray
    Write-Host ''

    if ($interactive -and -not $ProfileFixed) {
        $profiles = @('Balanced', 'Minimal', 'Gaming', 'Privacy', 'Laptop')
        Write-Host ('  01  /  ' + $text.Profile) -ForegroundColor Magenta
        for ($i = 0; $i -lt $profiles.Count; $i++) {
            Write-Host ('     {0}  {1,-10} {2}' -f ($i + 1), $profiles[$i], $text.($profiles[$i])) -ForegroundColor Gray
        }
        $choice = Read-WpiWizardChoice $text.Choose @('1','2','3','4','5') '1'
        $Profile = $profiles[[int]$choice - 1]
    }

    if (-not $AppsFixed) {
        $Apps = @('firefox', '7zip', 'vlc', 'notepadpp')
        if ($interactive) {
            Write-Host ''
            Write-Host ('  02  /  ' + $text.Apps) -ForegroundColor Magenta
            foreach ($line in $text.Packs) { Write-Host ('     ' + $line) -ForegroundColor Gray }
            $choice = Read-WpiWizardChoice $text.Choose @('1','2','3','4') '1'
            switch ($choice) {
                '2' { $Apps += @('telegram', 'discord') }
                '3' { $Apps = @() }
                '4' {
                    $catalog = Get-WpiCatalog
                    foreach ($group in $catalog.Apps | Group-Object Category) {
                        Write-Host ('     ' + $group.Name) -ForegroundColor Cyan
                        Write-Host ('       ' + (($group.Group | ForEach-Object { $_.Id }) -join ', ')) -ForegroundColor Gray
                    }
                    do {
                        $Apps = @((Read-Host $text.AppIds) -split '[,\s]+' | Where-Object { $_ })
                        $unknown = @($Apps | Where-Object { $_ -notin $catalog.Apps.Id })
                        if ($unknown.Count) { Write-Host ($text.Unknown + ': ' + ($unknown -join ', ')) -ForegroundColor Yellow }
                    } while ($unknown.Count)
                }
            }
        }
    }

    if (-not $Provider) {
        $Provider = if ($system.Providers.Choco -or -not $system.Providers.Winget) { 'Choco' } else { 'Winget' }
        if ($interactive -and $Apps.Count -and $system.Providers.Choco -and $system.Providers.Winget) {
            Write-Host '     1  Chocolatey (recommended)   2  WinGet' -ForegroundColor Gray
            if ((Read-WpiWizardChoice $text.Manager @('1','2') '1') -eq '2') { $Provider = 'Winget' }
        }
    }
    $plan = New-WpiPlan -Profile $Profile -Provider $Provider -Apps $Apps -Actions $Actions
    Write-Host ''
    Write-Host ('  03  /  {0}  ::  {1} + {2}' -f $text.Plan, $Profile, $Provider) -ForegroundColor Magenta
    $pending = @($plan.Payload.Entries | Where-Object { $_.Status -eq 'Planned' })
    foreach ($entry in $plan.Payload.Entries) {
        $color = switch ($entry.Status) { Planned { 'Cyan' } AlreadyCompliant { 'DarkGreen' } default { 'Yellow' } }
        $detail = if ($entry.Reason) { $entry.Reason } elseif ($entry.Kind -eq 'App') { $entry.Target } else { '' }
        Write-Host ('     {0,-17} {1,-28} {2}' -f $entry.Status, $entry.Id, $detail) -ForegroundColor $color
    }
    if ($Preview) {
        Write-Host ('  ' + $text.DryRun) -ForegroundColor Green
        return 0
    }
    if (-not $pending.Count) {
        Write-Host ('  ' + $text.Nothing) -ForegroundColor Yellow
        if (@($plan.Payload.Entries | Where-Object { $_.Status -in @('Blocked','Unsupported','Manual') }).Count) { return 2 }
        return 0
    }
    if (-not $system.PreviewSupported -or -not $system.Is64BitProcess) { throw $text.Unsupported }
    $needsApps = @($pending | Where-Object { $_.Kind -eq 'App' }).Count -gt 0
    $needsRisk = @($pending | Where-Object { $_.Kind -eq 'Appx' }).Count -gt 0
    if ($interactive) {
        Write-Host ('  ' + $text.PreviewNotice) -ForegroundColor Yellow
        if ($needsApps) { Write-Host ('  ' + $text.Agreements) -ForegroundColor Yellow }
        if ($needsRisk) { Write-Host ('  ' + $text.Risk) -ForegroundColor Yellow }
        if ((Read-WpiWizardChoice $text.Confirm @('y','n') 'n') -ne 'y') {
            Write-Host ('  ' + $text.Cancelled) -ForegroundColor Yellow
            return 3
        }
        $AllowUnverified = $true
        $AcceptAgreements = $needsApps
        $AcceptRisk = $needsRisk
    }
    if (-not $AllowUnverified) { throw 'NonInteractive preview apply requires -AllowUnverified.' }
    if ($needsApps -and -not $AcceptAgreements) { throw 'App installation requires -AcceptAgreements.' }
    if ($needsRisk -and -not $AcceptRisk) { throw 'Appx removal requires -AcceptRisk.' }
    if ($needsApps -and -not $system.IsAdmin) {
        if ($NonInteractive) { throw 'Run from an elevated terminal for unattended app installation.' }
        Write-Host ('  ' + $text.Elevate) -ForegroundColor Cyan
        $code = Invoke-WpiElevatedPlan -Plan $plan -DataRoot $DataRoot -EntryScript $EntryScript -Language $Language -AcceptRisk:$AcceptRisk
        $color = if ($code -eq 0) { 'Green' } else { 'Yellow' }
        Write-Host ('  {0}: {1}' -f $text.ExitCode, $code) -ForegroundColor $color
        return $code
    }
    $result = Invoke-WpiPlan -Plan $plan -DataRoot $DataRoot -AllowUnverified:$AllowUnverified -AcceptAgreements:$AcceptAgreements -AcceptRisk:$AcceptRisk -ShowProgress -Confirm:$false
    Show-WpiWizardResult $result $text
    return $result.ExitCode
}
