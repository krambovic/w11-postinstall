#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Menu', 'Diagnose', 'Catalog', 'Plan', 'Apply', 'Restore', 'Report', 'Defender')][string]$Mode = 'Menu',
    [ValidateSet('Balanced', 'Minimal', 'Gaming', 'Privacy', 'Laptop', 'Custom')][string]$Profile = 'Balanced',
    [string]$ProfileFile,
    [ValidateSet('Choco', 'Winget')][string]$Provider = 'Choco',
    [string[]]$Actions = @(), [string[]]$Apps = @(),
    [string]$PlanFile, [string]$OutFile, [string]$RunId,
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'W11PostInstall'),
    [ValidateSet('ru-RU', 'en-US')][string]$Language = 'ru-RU',
    [switch]$NonInteractive, [switch]$AcceptAgreements, [switch]$AcceptRisk, [switch]$AllowUnverified
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'src/Wpi.psm1') -Force
    . (Join-Path $PSScriptRoot 'src/Menu.ps1')
    $exitCode = 0
    switch ($Mode) {
        Menu {
            if ($NonInteractive) { throw 'Menu is not available in NonInteractive mode. Select Plan, Apply or another explicit mode.' }
            if ($WhatIfPreference) { throw 'For a non-interactive dry run use -Mode Apply -WhatIf, not Menu.' }
            Show-WpiMenu -Language $Language -DataRoot $DataRoot
        }
        Diagnose { Get-WpiSystem | Format-List }
        Catalog {
            $catalog = Get-WpiCatalog
            $catalog.Apps | Select-Object Id, Name, Category, Choco, Winget, Verification | Format-Table -AutoSize
            $catalog.Actions | Select-Object Id, NameRu, Kind, Risk | Format-Table -AutoSize
        }
        { $_ -in @('Plan', 'Apply') } {
            if ($PlanFile) {
                if ($PSBoundParameters.ContainsKey('Profile') -or $ProfileFile -or $Actions.Count -or $Apps.Count -or $PSBoundParameters.ContainsKey('Provider')) {
                    throw 'Do not combine PlanFile with profile/provider/action overrides. Create a new plan instead.'
                }
                $plan = Read-WpiJson $PlanFile
            } else {
                $options = @{ Profile = $Profile; Actions = $Actions; Apps = $Apps }
                if ($ProfileFile) { $options.ProfileFile = $ProfileFile }
                if ($PSBoundParameters.ContainsKey('Provider') -or -not $ProfileFile) { $options.Provider = $Provider }
                $plan = New-WpiPlan @options
            }
            $plan.Payload.Entries | Select-Object Id, Status, Target, Reason | Format-Table -Wrap
            if ($Mode -eq 'Plan') {
                if ($OutFile) {
                    if ($PSCmdlet.ShouldProcess($OutFile, 'Write plan JSON')) { Write-WpiJson $OutFile $plan }
                }
                Write-Host 'Preview compatibility: UNVERIFIED. No system changes have been made.'
            } else {
                $processOptions = @{ WhatIf = $WhatIfPreference }
                if ($PSBoundParameters.ContainsKey('Confirm')) { $processOptions.Confirm = $PSBoundParameters['Confirm'] }
                if ($NonInteractive -and $processOptions.ContainsKey('Confirm') -and $processOptions.Confirm) { throw 'NonInteractive cannot be combined with Confirm.' }
                $result = Invoke-WpiPlan -Plan $plan -DataRoot $DataRoot -AcceptAgreements:$AcceptAgreements -AcceptRisk:$AcceptRisk -AllowUnverified:$AllowUnverified @processOptions
                $result | Select-Object Status, RunId, JournalPath | Format-List
                $exitCode = $result.ExitCode
            }
        }
        Restore {
            if (-not $RunId) { throw 'Restore requires -RunId.' }
            $processOptions = @{ WhatIf = $WhatIfPreference }
            if ($PSBoundParameters.ContainsKey('Confirm')) { $processOptions.Confirm = $PSBoundParameters['Confirm'] }
            if ($NonInteractive -and $processOptions.ContainsKey('Confirm') -and $processOptions.Confirm) { throw 'NonInteractive cannot be combined with Confirm.' }
            $result = Restore-WpiRun -DataRoot $DataRoot -RunId $RunId @processOptions
            $result | Format-List
            $exitCode = $result.ExitCode
        }
        Report {
            if (-not $RunId) { throw 'Report requires -RunId.' }
            $run = Get-WpiRun $DataRoot $RunId
            $run | Select-Object RunId, CreatedUtc, Status, Build | Format-List
            $run.Entries | Select-Object Id, Status, NativeExitCode, Error | Format-Table -Wrap
            if ($OutFile -and $PSCmdlet.ShouldProcess($OutFile, 'Export local report (contains SID/state; redact before sharing)')) { Write-WpiJson $OutFile $run }
        }
        Defender { Get-WpiDefender | Format-List }
    }
    exit $exitCode
} catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
