#requires -Version 5.1
Set-StrictMode -Version Latest
$script:Root = Split-Path -Parent $PSScriptRoot

function Read-WpiJson {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}

function Read-WpiAsset {
    param([Parameter(Mandatory)][string]$Name)
    $embedded = Get-Variable -Name WpiAssets -Scope Script -ErrorAction SilentlyContinue
    if ($embedded) {
        if (-not $embedded.Value.ContainsKey($Name)) { throw "Missing bundled asset: $Name" }
        return ($embedded.Value[$Name] | ConvertFrom-Json -ErrorAction Stop)
    }
    Read-WpiJson (Join-Path $script:Root $Name)
}

function Get-WpiCatalog {
    $apps = Read-WpiAsset 'catalog/apps.json'
    $actions = Read-WpiAsset 'catalog/actions.json'
    [pscustomobject]@{ Apps = @($apps.Apps); Actions = @($actions.Actions) }
}

function Get-WpiHash {
    param([Parameter(Mandatory)]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 40 -Compress
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-WpiFingerprint {
    $embedded = Get-Variable -Name WpiBundledFingerprint -Scope Script -ErrorAction SilentlyContinue
    if ($embedded) { return $embedded.Value }
    $parts = foreach ($name in @('catalog/actions.json', 'catalog/apps.json', 'catalog/compatibility.json', 'src/Wpi.psm1')) {
        (Get-FileHash -LiteralPath (Join-Path $script:Root $name) -Algorithm SHA256).Hash
    }
    Get-WpiHash @($parts)
}

function Get-WpiSystem {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion')
    try {
        $build = [int]$key.GetValue('CurrentBuildNumber')
        $release = [string]$key.GetValue('DisplayVersion')
        $edition = [string]$key.GetValue('EditionID')
        $ubr = [int]$key.GetValue('UBR', 0)
    } finally { if ($key) { $key.Dispose() } }
    $compat = Read-WpiAsset 'catalog/compatibility.json'
    $known = @($compat.Builds | Where-Object { $_.Build -eq $build })
    $arch = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432')
    if (-not $arch) { $arch = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE') }
    $providers = [ordered]@{}
    foreach ($name in @('Choco', 'Winget')) {
        $cmd = Get-Command ($name.ToLowerInvariant() + '.exe') -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $providers[$name] = [bool]$cmd
    }
    [pscustomobject][ordered]@{
        Build = $build; UBR = $ubr; Release = $release; Edition = $edition; Architecture = $arch
        Sid = $identity.User.Value; IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Is64BitProcess = [Environment]::Is64BitProcess
        KnownBuild = ($known.Count -eq 1); PreviewSupported = ($known.Count -eq 1 -and $arch -in $compat.Architectures -and $edition -in $compat.Editions)
        Validation = 'Unverified'; Providers = [pscustomobject]$providers
    }
}

function Get-WpiInstalledApps {
    # Read-only ARP inventory. Never use Win32_Product: it can trigger MSI repair.
    foreach ($hive in @([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryHive]::CurrentUser)) {
        foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
            try {
                $uninstall = $base.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall')
                if (-not $uninstall) { continue }
                try {
                    foreach ($sub in $uninstall.GetSubKeyNames()) {
                        $app = $uninstall.OpenSubKey($sub)
                        try {
                            $name = [string]$app.GetValue('DisplayName', '')
                            if ($name) { [pscustomobject]@{ Name = $name; Version = [string]$app.GetValue('DisplayVersion', '') } }
                        } finally { if ($app) { $app.Dispose() } }
                    }
                } finally { $uninstall.Dispose() }
            } finally { $base.Dispose() }
        }
    }
}

function Get-WpiRegistryState {
    param($Action)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Action.Key)
    try {
        $exists = $null -ne $key -and $Action.ValueName -in $key.GetValueNames()
        $kind = $null; $value = $null
        if ($exists) {
            $kind = $key.GetValueKind($Action.ValueName).ToString()
            $value = $key.GetValue($Action.ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
        [pscustomobject][ordered]@{ KeyExists = ($null -ne $key); Exists = $exists; Kind = $kind; Value = $value }
    } finally { if ($key) { $key.Dispose() } }
}

function Set-WpiRegistryState {
    param($Action, $State)
    if ($State.Exists) {
        if ($State.Kind -notin @('DWord', 'QWord', 'String', 'ExpandString', 'MultiString', 'Binary')) { throw 'Invalid registry value kind.' }
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Action.Key)
        try {
            $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind], $State.Kind)
            $value = $State.Value
            switch ($State.Kind) {
                DWord { $value = [int]$value }
                QWord { $value = [long]$value }
                Binary { $value = [byte[]]$value }
                MultiString { $value = [string[]]$value }
            }
            $key.SetValue($Action.ValueName, $value, $kind)
        } finally { $key.Dispose() }
    } else {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Action.Key, $true)
        if ($key) {
            try { $key.DeleteValue($Action.ValueName, $false) }
            finally { $key.Dispose() }
        }
        # Delete only an empty leaf that this run created. Never recurse through a shared key.
        if (-not $State.KeyExists) {
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Action.Key)
            $empty = $false
            if ($key) {
                try { $empty = $key.SubKeyCount -eq 0 -and $key.ValueCount -eq 0 }
                finally { $key.Dispose() }
            }
            if ($empty) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($Action.Key, $false) }
        }
    }
}

function Get-WpiDesiredState {
    param($Action)
    [pscustomobject][ordered]@{ KeyExists = $true; Exists = $true; Kind = $Action.ValueKind; Value = $Action.Value }
}

function Test-WpiStateEqual {
    param($Left, $Right)
    if ([bool]$Left.Exists -ne [bool]$Right.Exists) { return $false }
    if (-not $Left.Exists) { return $true }
    ($Left.Kind -eq $Right.Kind) -and ((Get-WpiHash $Left.Value) -eq (Get-WpiHash $Right.Value))
}

function Get-WpiItemState {
    param($Item, $Inventory)
    switch ($Item.Kind) {
        Registry { Get-WpiRegistryState $Item }
        Appx {
            $packages = @(Get-AppxPackage -Name $Item.Package -ErrorAction Stop | Where-Object { $_.Name -eq $Item.Package })
            [pscustomobject][ordered]@{ Packages = @($packages | Select-Object -ExpandProperty PackageFullName | Sort-Object) }
        }
        App {
            [pscustomobject][ordered]@{ Installed = @($Inventory | Where-Object { $_.Name -match $Item.DetectPattern }).Count -gt 0 }
        }
        Unsupported { [pscustomobject]@{ Unsupported = $true } }
        default { throw 'Unknown item kind.' }
    }
}

function Get-WpiItem {
    param([string]$Id, $Catalog)
    if ($Id.StartsWith('app.')) {
        $found = @($Catalog.Apps | Where-Object { ('app.' + $_.Id) -eq $Id })
        if ($found.Count -ne 1) { throw "Unknown app: $Id" }
        $copy = $found[0] | Select-Object *
        $copy | Add-Member NoteProperty Kind 'App'
        return $copy
    }
    $found = @($Catalog.Actions | Where-Object { $_.Id -eq $Id })
    if ($found.Count -ne 1) { throw "Unknown action: $Id" }
    $found[0]
}

function New-WpiPlan {
    [CmdletBinding()]
    param(
        [ValidateSet('Balanced', 'Minimal', 'Gaming', 'Privacy', 'Laptop', 'Custom')][string]$Profile = 'Balanced',
        [string]$ProfileFile,
        [ValidateSet('Choco', 'Winget')][string]$Provider = 'Choco',
        [string[]]$Actions = @(), [string[]]$Apps = @()
    )
    $catalog = Get-WpiCatalog
    if ($ProfileFile) { $config = Read-WpiJson $ProfileFile } else { $config = Read-WpiAsset "profiles/$Profile.json" }
    if ($config.SchemaVersion -ne 1) { throw 'Unsupported profile schema.' }
    foreach ($prop in $config.PSObject.Properties.Name) {
        if ($prop -notin @('SchemaVersion', 'Name', 'Provider', 'Actions', 'Apps')) { throw "Unknown profile field: $prop" }
    }
    if ($ProfileFile -and -not $PSBoundParameters.ContainsKey('Provider')) { $Provider = $config.Provider }
    if ($Provider -notin @('Choco', 'Winget')) { throw 'Invalid provider.' }
    $ids = @(@($config.Actions) + @($Actions) + @(@($config.Apps) + @($Apps) | ForEach-Object { 'app.' + $_ }) | Where-Object { $_ } | Select-Object -Unique)
    if ($ids.Count -gt 200) { throw 'Plan is too large.' }
    $system = Get-WpiSystem
    $inventory = @(Get-WpiInstalledApps)
    $entries = foreach ($id in $ids) {
        $item = Get-WpiItem $id $catalog
        $state = Get-WpiItemState $item $inventory
        $status = 'Planned'; $reason = ''
        switch ($item.Kind) {
            Registry { if (Test-WpiStateEqual $state (Get-WpiDesiredState $item)) { $status = 'AlreadyCompliant' } }
            Appx { if (@($state.Packages).Count -eq 0) { $status = 'AlreadyCompliant' } }
            App {
                if ($state.Installed) { $status = 'AlreadyCompliant' }
                elseif (-not $item.$Provider) { $status = 'Manual'; $reason = $item.Website }
                elseif (-not $system.Providers.$Provider) { $status = 'Blocked'; $reason = "$Provider not installed; no bootstrap is performed." }
            }
            Unsupported { $status = 'Unsupported'; $reason = $item.NotesEn }
        }
        $target = ''; $website = ''; $recovery = ''
        if ($item.Kind -eq 'App') { $target = $item.$Provider; $website = $item.Website; $recovery = 'Manual uninstall' }
        elseif ($item.Kind -eq 'Registry') { $target = 'HKCU\' + $item.Key + '\' + $item.ValueName; $recovery = 'Exact original value' }
        elseif ($item.Kind -eq 'Appx') { $target = $item.Package; $recovery = 'Manual reinstall; app data is not backed up' }
        [pscustomobject][ordered]@{ Id = $id; Kind = $item.Kind; Target = $target; Website = $website; Recovery = $recovery; Status = $status; Reason = $reason; Before = $state }
    }
    $payload = [pscustomobject][ordered]@{
        SchemaVersion = 1; CreatedUtc = [DateTime]::UtcNow.ToString('o'); CatalogHash = Get-WpiFingerprint
        System = $system; Provider = $Provider; Profile = [string]$config.Name; Entries = @($entries)
    }
    [pscustomobject][ordered]@{ Payload = $payload; Digest = Get-WpiHash $payload }
}

function Assert-WpiPlan {
    param($Plan)
    if ($Plan.Payload.SchemaVersion -ne 1) { throw 'Unsupported plan schema.' }
    if ((Get-WpiHash $Plan.Payload) -ne $Plan.Digest) { throw 'Plan checksum mismatch.' }
    if ($Plan.Payload.CatalogHash -ne (Get-WpiFingerprint)) { throw 'Code/catalog changed. Create a fresh plan.' }
    if ($Plan.Payload.Provider -notin @('Choco', 'Winget')) { throw 'Invalid plan provider.' }
    $catalog = Get-WpiCatalog
    $seen = @{}
    foreach ($entry in @($Plan.Payload.Entries)) {
        if ($seen.ContainsKey($entry.Id)) { throw 'Duplicate plan entry.' }
        $seen[$entry.Id] = $true
        $item = Get-WpiItem $entry.Id $catalog
        if ($item.Kind -ne $entry.Kind) { throw 'Plan item kind mismatch.' }
        if ($entry.Status -notin @('Planned', 'AlreadyCompliant', 'Blocked', 'Unsupported', 'Manual')) { throw 'Invalid plan status.' }
    }
    $system = Get-WpiSystem
    foreach ($name in @('Sid', 'Build', 'UBR', 'Edition', 'Architecture')) {
        if ($system.$name -ne $Plan.Payload.System.$name) { throw "System changed ($name). Create a fresh plan." }
    }
    $system
}

function Write-WpiJson {
    param([string]$Path, $Value)
    # Atomic replacement; journals use an ACL-protected parent directory.
    $full = [IO.Path]::GetFullPath($Path)
    $temp = $full + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 40), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($full)) { [IO.File]::Replace($temp, $full, $null) }
        else { [IO.File]::Move($temp, $full) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Open-WpiState {
    param([string]$DataRoot)
    $full = [IO.Path]::GetFullPath($DataRoot)
    if ((Test-Path -LiteralPath $full) -and -not (Test-Path -LiteralPath (Join-Path $full '.wpi-state'))) {
        throw 'Refusing to change ACLs on an existing directory not owned by WPI. Use a new dedicated DataRoot.'
    }
    $null = [IO.Directory]::CreateDirectory($full)
    $dir = Get-Item -LiteralPath $full -Force
    if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'State directory must not be a reparse point.' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($sid)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($account in @($sid, (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')), (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($account, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $full -AclObject $acl -ErrorAction Stop
    [IO.File]::WriteAllText((Join-Path $full '.wpi-state'), 'W11PostInstall state v1')
    # A FileShare.None handle, rather than an existence check, prevents concurrent mutation.
    $lock = [IO.File]::Open((Join-Path $full 'run.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    [pscustomobject]@{ Root = $full; Lock = $lock }
}

function Invoke-WpiNative {
    param([string]$Executable, [string[]]$Arguments, [int]$TimeoutSeconds = 1800)
    # Every argument is generated internally from fixed flags and validated IDs. No shell.
    foreach ($arg in $Arguments) { if ($arg -match '[\s"`\r\n]') { throw 'Unexpected character in native argument.' } }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $start.Arguments = $Arguments -join ' '
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Could not start package manager.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            throw 'Package manager timeout; child installer state is unknown. Stop and inspect before retrying.'
        }
        $process.WaitForExit()
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result; ErrorOutput = $stderr.Result }
    } finally { $process.Dispose() }
}

function Get-WpiInstallCommand {
    param($App, [ValidateSet('Choco', 'Winget')][string]$Provider)
    $id = [string]$App.$Provider
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9.+_-]*$' -or $id -in @('all', 'packages.config')) { throw 'Invalid or missing package ID.' }
    if ($Provider -eq 'Choco') {
        return [pscustomobject]@{ Name = 'choco.exe'; Arguments = @('install', $id, '--yes', '--no-progress', '--limit-output', '--use-package-exit-codes', '--source=https://community.chocolatey.org/api/v2') }
    }
    [pscustomobject]@{ Name = 'winget.exe'; Arguments = @('install', '--id', $id, '--exact', '--source', 'winget', '--silent', '--no-upgrade', '--disable-interactivity', '--accept-package-agreements', '--accept-source-agreements') }
}

function Test-WpiManagedApp {
    param($App, [string]$Provider, [string]$Executable)
    if ($Provider -eq 'Choco') {
        $result = Invoke-WpiNative $Executable @('list', '--limit-output') 60
        if ($result.ExitCode -ne 0) { throw "Chocolatey list failed: $($result.ExitCode)" }
        return [bool]($result.Output -match ('(?im)^' + [regex]::Escape($App.Choco) + '\|[^\r\n]+'))
    }
    $result = Invoke-WpiNative $Executable @('list', '--id', $App.Winget, '--exact', '--disable-interactivity', '--accept-source-agreements') 60
    if ($result.ExitCode -eq -1978335212) { return $false } # APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND
    if ($result.ExitCode -ne 0) { throw "WinGet list failed: $($result.ExitCode)" }
    [bool]($result.Output -match ('(?im)(?:^|\s)' + [regex]::Escape($App.Winget) + '(?:\s|$)'))
}

function Get-WpiProviderExecutable {
    param([string]$Provider)
    $command = Get-Command ($Provider.ToLowerInvariant() + '.exe') -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $version = Invoke-WpiNative $command.Source @('--version') 30
    if ($version.ExitCode -ne 0) { throw 'Could not read package manager version.' }
    if ($Provider -eq 'Choco') {
        if ($version.Output -notmatch '^\s*(\d+)\.' -or [int]$Matches[1] -lt 2) { throw 'Chocolatey 2+ is required. Update it manually.' }
    }
    if ($Provider -eq 'Winget' -and $version.Output -notmatch 'v?(\d+)\.(\d+)') { throw 'Unknown WinGet version.' }
    if ($Provider -eq 'Winget' -and ([int]$Matches[1] -lt 1 -or ([int]$Matches[1] -eq 1 -and [int]$Matches[2] -lt 6))) { throw 'WinGet 1.6+ is required.' }
    $command.Source
}

function Invoke-WpiItem {
    param($Item, $Entry, [string]$Provider, [string]$Executable)
    switch ($Item.Kind) {
        Registry {
            Set-WpiRegistryState $Item (Get-WpiDesiredState $Item)
            if (-not (Test-WpiStateEqual (Get-WpiRegistryState $Item) (Get-WpiDesiredState $Item))) { throw 'Registry verification failed (possibly managed by policy).' }
            [pscustomobject]@{ Status = 'Verified'; NativeExitCode = $null }
        }
        Appx {
            foreach ($package in @($Entry.Before.Packages)) { Remove-AppxPackage -Package $package -ErrorAction Stop }
            if (@((Get-WpiItemState $Item @()).Packages).Count -gt 0) { throw 'Appx removal verification failed.' }
            [pscustomobject]@{ Status = 'Verified'; NativeExitCode = $null }
        }
        App {
            $command = Get-WpiInstallCommand $Item $Provider
            $result = Invoke-WpiNative $Executable $command.Arguments
            $code = $result.ExitCode
            # Chocolatey/WinGet use different exit-code namespaces. Pending reboot is not verified installation.
            $rebootCodes = @(3010, 1641)
            if ($Provider -eq 'Choco') { $rebootCodes += @(350, 1604) }
            else { $rebootCodes += @(-1978334967, -1978334966, -1978334965) } # 0x8A150109..10B
            if ($code -ne 0 -and $code -notin $rebootCodes) {
                $errorRecord = New-Object InvalidOperationException("Package manager failed (exit $code). Installer may have made partial changes.")
                $errorRecord.Data['NativeExitCode'] = $code
                throw $errorRecord
            }
            if ($code -in $rebootCodes) { return [pscustomobject]@{ Status = 'RebootRequired'; NativeExitCode = $code } }
            if (-not (Test-WpiManagedApp $Item $Provider $Executable)) { throw 'Install returned success but installed package was not detected.' }
            [pscustomobject]@{ Status = 'Verified'; NativeExitCode = $code }
        }
        default { throw 'Unsupported operation.' }
    }
}

function Invoke-WpiPlan {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$DataRoot,
        [switch]$AcceptAgreements, [switch]$AcceptRisk, [switch]$AllowUnverified, [switch]$ShowProgress)
    $system = Assert-WpiPlan $Plan
    # Dry run returns before package-manager calls, locks, directories or journal creation.
    if ($WhatIfPreference) {
        foreach ($entry in $Plan.Payload.Entries) { $null = $PSCmdlet.ShouldProcess($entry.Id, 'Apply planned operation') }
        return [pscustomobject]@{ Status = 'Preview'; ExitCode = 0; RunId = $null; Entries = $Plan.Payload.Entries }
    }
    if (-not $system.PreviewSupported -or -not $system.Is64BitProcess) { throw 'Preview Apply supports known x64 Home/Pro builds from a 64-bit process only.' }
    if (-not $AllowUnverified) { throw 'No live VM tests have been run. Preview Apply requires -AllowUnverified.' }
    $catalog = Get-WpiCatalog
    $inventory = @(Get-WpiInstalledApps)
    $pending = @($Plan.Payload.Entries | Where-Object { $_.Status -eq 'Planned' })
    $executable = $null
    foreach ($entry in @($Plan.Payload.Entries)) {
        $item = Get-WpiItem $entry.Id $catalog
        $current = Get-WpiItemState $item $inventory
        if ((Get-WpiHash $current) -ne (Get-WpiHash $entry.Before)) { throw "State drift for $($entry.Id); create a new plan." }
    }
    foreach ($entry in $pending) {
        $item = Get-WpiItem $entry.Id $catalog
        if ($item.Kind -eq 'Appx' -and -not $AcceptRisk) { throw 'Appx removal may lose app data. Requires -AcceptRisk.' }
        if ($item.Kind -eq 'App') {
            if (-not $AcceptAgreements) { throw 'Installing apps requires explicit -AcceptAgreements.' }
            if (-not $system.IsAdmin) { throw 'Preview app installation requires an elevated terminal. User tweaks can run without elevation.' }
            if (-not $executable) { $executable = Get-WpiProviderExecutable $Plan.Payload.Provider }
        }
    }
    if (-not $PSCmdlet.ShouldProcess('Windows / selected apps', ('Apply {0} operations' -f $pending.Count))) {
        return [pscustomobject]@{ Status = 'Cancelled'; ExitCode = 3; RunId = $null }
    }
    $state = Open-WpiState $DataRoot
    try {
        $runId = [Guid]::NewGuid().ToString('N')
        $journal = [pscustomobject][ordered]@{
            SchemaVersion = 1; RunId = $runId; Sid = $system.Sid; Build = $system.Build
            CatalogHash = $Plan.Payload.CatalogHash; CreatedUtc = [DateTime]::UtcNow.ToString('o')
            Plan = $Plan; Status = 'Applying'; Entries = @()
        }
        $path = Join-Path $state.Root ($runId + '.json')
        Write-WpiJson $path $journal
        foreach ($entry in $Plan.Payload.Entries) {
            $item = Get-WpiItem $entry.Id $catalog
            $record = [pscustomobject][ordered]@{ Id = $entry.Id; Kind = $entry.Kind; Before = $entry.Before; Status = $entry.Status; IntentWritten = $false; Error = $entry.Reason; NativeExitCode = $null }
            $journal.Entries = @($journal.Entries) + @($record)
            if ($entry.Status -ne 'Planned') { Write-WpiJson $path $journal; continue }
            if ($ShowProgress) { Write-Host ('  [{0}/{1}]  {2}' -f $journal.Entries.Count, $Plan.Payload.Entries.Count, $entry.Id) -ForegroundColor Cyan }
            try {
                # Re-check after acquiring the lock, immediately before writing intent.
                $fresh = Get-WpiItemState $item @(Get-WpiInstalledApps)
                if ((Get-WpiHash $fresh) -ne (Get-WpiHash $entry.Before)) { throw 'State changed before execution; no operation performed.' }
                if ($item.Kind -eq 'App' -and (Test-WpiManagedApp $item $Plan.Payload.Provider $executable)) {
                    $record.Status = 'AlreadyCompliant'; Write-WpiJson $path $journal; continue
                }
                $record.Status = 'Applying'; $record.IntentWritten = $true; Write-WpiJson $path $journal
                $result = Invoke-WpiItem $item $entry $Plan.Payload.Provider $executable
                $record.Status = $result.Status; $record.NativeExitCode = $result.NativeExitCode
                Write-WpiJson $path $journal
                if ($record.Status -eq 'RebootRequired') { break }
            } catch {
                $record.Status = 'Failed'; $record.Error = $_.Exception.Message
                if ($_.Exception.Data.Contains('NativeExitCode')) { $record.NativeExitCode = $_.Exception.Data['NativeExitCode'] }
                Write-WpiJson $path $journal
                break # Unknown installer/partial removal state: never blindly retry or continue.
            }
        }
        foreach ($entry in $Plan.Payload.Entries) {
            if ($entry.Id -notin @($journal.Entries | ForEach-Object { $_.Id })) {
                $journal.Entries += [pscustomobject][ordered]@{ Id = $entry.Id; Kind = $entry.Kind; Before = $entry.Before; Status = 'Skipped'; IntentWritten = $false; Error = 'Stopped after a failed operation or reboot request. Create a fresh plan to continue.'; NativeExitCode = $null }
            }
        }
        $hasFailure = @($journal.Entries | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0
        $hasReboot = @($journal.Entries | Where-Object { $_.Status -eq 'RebootRequired' }).Count -gt 0
        $hasBlocked = @($Plan.Payload.Entries | Where-Object { $_.Status -in @('Blocked', 'Unsupported', 'Manual') }).Count -gt 0
        $code = 0; $journal.Status = 'Completed'
        if ($hasReboot) { $code = 3010; $journal.Status = 'RebootRequired' }
        elseif ($hasFailure -or $hasBlocked) { $code = 2; $journal.Status = 'Partial' }
        Write-WpiJson $path $journal
        [pscustomobject]@{ Status = $journal.Status; ExitCode = $code; RunId = $runId; JournalPath = $path; Entries = $journal.Entries }
    } finally { $state.Lock.Dispose() }
}

function Get-WpiRun {
    param([string]$DataRoot, [string]$RunId)
    if ($RunId -notmatch '^[a-f0-9]{32}$') { throw 'RunId must be a 32-character lowercase hex GUID.' }
    $journal = Read-WpiJson (Join-Path $DataRoot ($RunId + '.json'))
    if ($journal.SchemaVersion -ne 1 -or $journal.RunId -ne $RunId) { throw 'Invalid journal.' }
    $journal
}

function Restore-WpiRun {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$DataRoot, [string]$RunId)
    $journal = Get-WpiRun $DataRoot $RunId
    $system = Get-WpiSystem
    if ($system.Sid -ne $journal.Sid -or $system.Build -ne $journal.Build) { throw 'Restore must use the original user and Windows build.' }
    if ($journal.CatalogHash -ne (Get-WpiFingerprint)) { throw 'Restore requires the original code/catalog release.' }
    $catalog = Get-WpiCatalog
    if ($WhatIfPreference) {
        foreach ($entry in $journal.Entries) { $null = $PSCmdlet.ShouldProcess($entry.Id, 'Restore original registry value (other kinds need manual recovery)') }
        return [pscustomobject]@{ Status = 'Preview'; ExitCode = 0 }
    }
    if (-not $PSCmdlet.ShouldProcess($RunId, 'Restore original registry values')) { return [pscustomobject]@{ Status = 'Cancelled'; ExitCode = 3 } }
    $state = Open-WpiState $DataRoot
    try {
        $journal = Get-WpiRun $DataRoot $RunId
        $entries = @($journal.Entries); [array]::Reverse($entries)
        foreach ($entry in $entries) {
            if (-not $entry.IntentWritten -or $entry.Status -notin @('Verified', 'Applying', 'Failed', 'RebootRequired', 'Conflict', 'RestoreFailed')) { continue }
            $item = Get-WpiItem $entry.Id $catalog
            if ($item.Kind -ne 'Registry') { $entry.Error = 'Manual recovery: reinstall removed apps; uninstall newly installed apps separately.'; continue }
            try {
                $current = Get-WpiRegistryState $item
                if (Test-WpiStateEqual $current $entry.Before) { $entry.Status = 'Restored' }
                elseif (-not (Test-WpiStateEqual $current (Get-WpiDesiredState $item))) { $entry.Status = 'Conflict'; $entry.Error = 'Value changed since Apply; left untouched.' }
                else {
                    Set-WpiRegistryState $item $entry.Before
                    if (-not (Test-WpiStateEqual (Get-WpiRegistryState $item) $entry.Before)) { throw 'Restore verification failed.' }
                    $entry.Status = 'Restored'; $entry.Error = ''
                }
            } catch { $entry.Status = 'RestoreFailed'; $entry.Error = $_.Exception.Message }
            Write-WpiJson (Join-Path $state.Root ($RunId + '.json')) $journal
        }
        $remaining = @($journal.Entries | Where-Object { $_.Status -in @('Verified', 'Applying', 'Failed', 'RebootRequired', 'Conflict', 'RestoreFailed') }).Count
        $journal.Status = 'Restored'; $code = 0
        if ($remaining -gt 0) { $journal.Status = 'PartialRestore'; $code = 2 }
        Write-WpiJson (Join-Path $state.Root ($RunId + '.json')) $journal
        [pscustomobject]@{ Status = $journal.Status; ExitCode = $code; Entries = $journal.Entries }
    } finally { $state.Lock.Dispose() }
}

function Get-WpiDefender {
    $status = Get-MpComputerStatus -ErrorAction Stop
    [pscustomobject]@{
        AMRunningMode = $status.AMRunningMode; AntivirusEnabled = $status.AntivirusEnabled
        RealTimeProtectionEnabled = $status.RealTimeProtectionEnabled; IsTamperProtected = $status.IsTamperProtected
        AMProductVersion = $status.AMProductVersion; Removal = 'Unsupported in preview: VM validation required'
    }
}

Export-ModuleMember -Function Get-WpiCatalog, Get-WpiSystem, New-WpiPlan, Read-WpiJson, Read-WpiAsset, Write-WpiJson, Invoke-WpiPlan, Restore-WpiRun, Get-WpiRun, Get-WpiDefender
