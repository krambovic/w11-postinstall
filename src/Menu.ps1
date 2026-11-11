function Get-WpiText {
    param([string]$Key)
    $script:Text.$Key
}

function Show-WpiMenu {
    param([string]$Language, [string]$DataRoot)
    $script:Text = Read-WpiAsset "locales/$Language.json"
    $profile = 'Balanced'; $provider = 'Choco'
    $selectedApps = @(); $selectedActions = @()
    $catalog = Get-WpiCatalog
    while ($true) {
        Write-Host "`nW11 PostInstall 0.2.0-preview" -ForegroundColor Cyan
        Write-Host (Get-WpiText 'Preview')
        Write-Host ("{0}: {1} | {2}: {3}" -f (Get-WpiText 'Profile'), $profile, (Get-WpiText 'Provider'), $provider)
        Write-Host ("{0}: {1} | {2}: {3}" -f (Get-WpiText 'SelectedApps'), $selectedApps.Count, (Get-WpiText 'SelectedActions'), $selectedActions.Count)
        Write-Host (Get-WpiText 'MainMenu')
        $choice = Read-Host (Get-WpiText 'Choose')
        try {
            switch ($choice) {
                '1' { Get-WpiSystem | Format-List | Out-Host }
                '2' {
                    $names = @('Balanced', 'Minimal', 'Gaming', 'Privacy', 'Laptop', 'Custom')
                    for ($i = 0; $i -lt $names.Count; $i++) { Write-Host ("{0}. {1}" -f ($i + 1), $names[$i]) }
                    $value = Read-Host (Get-WpiText 'Choose')
                    if ($value -match '^[1-6]$') { $profile = $names[[int]$value - 1] }
                }
                '3' {
                    foreach ($item in $catalog.Actions) {
                        $name = $item.NameEn; if ($Language -eq 'ru-RU') { $name = $item.NameRu }
                        Write-Host ("{0} | {1} | {2} | {3}" -f $item.Id, $name, $item.Risk, $item.Undo)
                        $note = $item.NotesEn; if ($Language -eq 'ru-RU') { $note = $item.NotesRu }
                        Write-Host ('  ' + $note)
                    }
                    $value = Read-Host (Get-WpiText 'ActionIds')
                    $ids = @($value -split '[,\s]+' | Where-Object { $_ })
                    foreach ($id in $ids) { if ($id -notin $catalog.Actions.Id) { throw "Unknown action: $id" } }
                    $selectedActions = $ids
                }
                '4' {
                    $filter = Read-Host (Get-WpiText 'Search')
                    $list = @($catalog.Apps | Where-Object { -not $filter -or ($_.Name + ' ' + $_.Category + ' ' + ($_.Tags -join ' ')).IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
                    foreach ($app in $list) {
                        $id = $app.$provider
                        $availability = $provider + ': ' + $id
                        if (-not $id) { $availability = (Get-WpiText 'Manual') + ': ' + $app.Website }
                        $mark = ' '; if ($app.Id -in $selectedApps) { $mark = '*' }
                        Write-Host ("[{0}] {1} | {2} | {3} | {4}" -f $mark, $app.Id, $app.Name, $app.Category, $availability)
                    }
                    $value = Read-Host (Get-WpiText 'AppIds')
                    foreach ($id in @($value -split '[,\s]+' | Where-Object { $_ })) {
                        if ($id -notin $catalog.Apps.Id) { throw "Unknown app: $id" }
                        if ($id -in $selectedApps) { $selectedApps = @($selectedApps | Where-Object { $_ -ne $id }) }
                        else { $selectedApps += $id }
                    }
                }
                '5' {
                    Write-Host '1. Chocolatey (recommended)'
                    Write-Host '2. WinGet'
                    $value = Read-Host (Get-WpiText 'Choose')
                    if ($value -eq '1') { $provider = 'Choco' }; if ($value -eq '2') { $provider = 'Winget' }
                }
                { $_ -in @('6', '7') } {
                    $plan = New-WpiPlan -Profile $profile -Provider $provider -Actions $selectedActions -Apps $selectedApps
                    $plan.Payload.Entries | Select-Object Id, Status, Target, Reason | Format-Table -Wrap | Out-Host
                    if ($choice -eq '6') {
                        $path = Read-Host (Get-WpiText 'SavePlan')
                        if ($path) { Write-WpiJson $path $plan }
                    } else {
                        Write-Host (Get-WpiText 'ApplyNotice') -ForegroundColor Yellow
                        if ((Read-Host (Get-WpiText 'ConfirmApply')) -cne 'APPLY') { continue }
                        $agreements = $false; $risk = $false
                        if (@($plan.Payload.Entries | Where-Object { $_.Kind -eq 'App' -and $_.Status -eq 'Planned' }).Count) {
                            $agreements = (Read-Host (Get-WpiText 'Agreements')) -ceq 'YES'
                        }
                        if (@($plan.Payload.Entries | Where-Object { $_.Kind -eq 'Appx' -and $_.Status -eq 'Planned' }).Count) {
                            $risk = (Read-Host (Get-WpiText 'DataLoss')) -ceq 'YES'
                        }
                        $result = Invoke-WpiPlan -Plan $plan -DataRoot $DataRoot -AcceptAgreements:$agreements -AcceptRisk:$risk -AllowUnverified -Confirm:$false
                        $result | Format-List | Out-Host
                    }
                }
                '8' {
                    if (Test-Path -LiteralPath $DataRoot) {
                        Get-ChildItem -LiteralPath $DataRoot -Filter '*.json' | Select-Object Name, LastWriteTime | Format-Table | Out-Host
                    }
                    $id = Read-Host (Get-WpiText 'RestoreId')
                    if ($id -and (Read-Host (Get-WpiText 'ConfirmRestore')) -ceq 'RESTORE') { Restore-WpiRun -DataRoot $DataRoot -RunId $id -Confirm:$false | Format-List | Out-Host }
                }
                '9' { Get-WpiDefender | Format-List | Out-Host }
                '0' { return }
                default { Write-Host (Get-WpiText 'Invalid') }
            }
        } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    }
}
