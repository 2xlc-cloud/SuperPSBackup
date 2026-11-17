#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(?:\.\d+)?$')][string]$Version = '1.0.0',
    [string]$SourcePath = ''
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SourcePath)) { $SourcePath = $PSScriptRoot }
. (Join-Path $PSScriptRoot 'Update-UserProfileBackup.ps1')
$entries = @()
foreach ($name in Get-BupUpdateFiles) {
    $file = Join-Path $SourcePath $name
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        $entries += [pscustomobject]@{ Name = $name; Length = (Get-Item -LiteralPath $file).Length; SHA256 = (Get-BupFileSha256 $file) }
    }
}
$manifest = [pscustomobject]@{ Format = 1; Version = $Version; Files = $entries }
$null = Test-BupUpdateManifest $manifest
$json = ($manifest | ConvertTo-Json -Depth 6).Replace("`r`n", "`n") + "`n"
[IO.File]::WriteAllText((Join-Path $SourcePath 'update-manifest.json'), $json, (New-Object Text.UTF8Encoding($false)))
$null = Test-BupUpdatePackage $SourcePath
Write-Output "Manifest erstellt und geprueft: $Version"
