#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$folder = Join-Path ([IO.Path]::GetTempPath()) ('WPI standalone ' + [Guid]::NewGuid().ToString('N'))
$file = Join-Path $folder 'W11PostInstall.ps1'
try {
    $null = & (Join-Path $root 'tools/Build-Standalone.ps1') -OutputPath $file
    $exe = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
    Push-Location -LiteralPath $folder
    try { $catalog = (& (Join-Path $PSHOME $exe) -NoProfile -NonInteractive -File $file -Mode Catalog) -join "`n"; $code = $LASTEXITCODE }
    finally { Pop-Location }
    if ($code -ne 0 -or $catalog -notmatch 'PhotoCraft' -or $catalog -notmatch 'Firefox' -or $catalog -notmatch 'defender.remove') {
        throw "Standalone catalog failed with code $code. $catalog"
    }
    if (@(Get-ChildItem -LiteralPath $folder -Force).Count -ne 1) { throw 'Standalone Catalog created unexpected files.' }
    Write-Host 'Standalone script loads its embedded catalog in an otherwise empty directory.'
} finally {
    if ([IO.File]::Exists($file)) { [IO.File]::Delete($file) }
    if ([IO.Directory]::Exists($folder)) { [IO.Directory]::Delete($folder) }
}
