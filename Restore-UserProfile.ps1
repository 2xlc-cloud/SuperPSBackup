#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SnapshotPath,
    [Parameter(Mandatory)][string]$DestinationPath,
    [string[]]$Categories,
    [switch]$NonInteractive
)

. (Join-Path $PSScriptRoot 'Backup-UserProfile.ps1')

function Assert-RestorePlainAncestors([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Verknuepfung im Wiederherstellungspfad: $cursor" }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Invoke-UserProfileRestore {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SnapshotPath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string[]]$Categories,
        [switch]$NonInteractive
    )
    $ErrorActionPreference = 'Stop'
    $SnapshotPath = [IO.Path]::GetFullPath($SnapshotPath)
    $DestinationPath = [IO.Path]::GetFullPath($DestinationPath)
    Assert-RestorePlainAncestors $SnapshotPath
    Assert-RestorePlainAncestors $DestinationPath
    if ((Test-BupChild $DestinationPath $SnapshotPath) -or (Test-BupChild $SnapshotPath $DestinationPath)) { throw 'Wiederherstellungsziel und Sicherungsstand duerfen nicht ueberlappen.' }
    $raw = Get-Content -LiteralPath (Join-Path $SnapshotPath '.snapshot.json') -Raw | ConvertFrom-Json
    $manifest = Get-BupManifest $SnapshotPath $raw.UserSid
    if ($null -eq $manifest) { throw 'Kein vollstaendiger, gueltiger Sicherungsstand.' }
    $validNames = @($manifest.Categories | ForEach-Object { $_.Name })
    if (-not $Categories) { $Categories = $validNames }
    foreach ($name in $Categories) { if ($name -notin $validNames -or $name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*$') { throw "Unbekannte Kategorie: $name" } }
    $copied = 0; $skipped = 0; $errors = 0
    foreach ($dir in (@($Categories) + @($manifest.Directories))) {
        if (($dir -split '[\\/]')[0] -notin $Categories) { continue }
        $dest = Get-BupSafePath $DestinationPath $dir
        Assert-RestorePlainAncestors $dest
        if ($PSCmdlet.ShouldProcess($dest, 'Ordner anlegen')) { $null = New-Item -ItemType Directory -Path $dest -Force }
    }
    foreach ($entry in $manifest.Files) {
        if (($entry.Path -split '[\\/]')[0] -notin $Categories) { continue }
        $temporary = $null; $stream = $null; $sha = $null
        try {
            $source = Get-BupSafePath $SnapshotPath $entry.Path
            $dest = Get-BupSafePath $DestinationPath $entry.Path
            Assert-RestorePlainAncestors $source
            Assert-RestorePlainAncestors $dest
            $exists = Test-Path -LiteralPath $dest
            if (-not $PSCmdlet.ShouldProcess($dest, 'Datei wiederherstellen')) { $skipped++; continue }
            if ($exists) {
                if ($NonInteractive) { $skipped++; Write-Warning "Vorhandene Datei ausgelassen: $dest"; continue }
                if (-not $PSCmdlet.ShouldContinue("Vorhandene Datei ersetzen: $dest", 'Ueberschreiben bestaetigen')) { $skipped++; continue }
            }
            $stream = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $sha = [Security.Cryptography.SHA256]::Create()
            $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
            if ($hash -ne $entry.Hash -or $stream.Length -ne [long]$entry.Length) { throw "Integritaetspruefung fehlgeschlagen: $source" }
            $parent = Split-Path -Parent $dest
            $null = New-Item -ItemType Directory -Path $parent -Force
            $temporary = Join-Path $parent ('.restore-' + [guid]::NewGuid().ToString('N'))
            $output = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $stream.Position = 0; $stream.CopyTo($output); $output.Flush($true) } finally { $output.Dispose() }
            [IO.File]::SetLastWriteTimeUtc($temporary, [datetime]::Parse($entry.LastWriteUtc).ToUniversalTime())
            if ($exists) { [IO.File]::Replace($temporary, $dest, [NullString]::Value) }
            else { [IO.File]::Move($temporary, $dest) }
            $temporary = $null
            $copied++
        }
        catch { $errors++; Write-Warning "Wiederherstellung fehlgeschlagen: $($entry.Path) : $_" }
        finally {
            if ($null -ne $sha) { $sha.Dispose() }
            if ($null -ne $stream) { $stream.Dispose() }
            if ($null -ne $temporary -and (Test-Path -LiteralPath $temporary)) { [IO.File]::Delete($temporary) }
        }
    }
    [pscustomobject]@{ Copied = $copied; Skipped = $skipped; Errors = $errors }
}

if ($MyInvocation.InvocationName -ne '.') {
    $arguments = @{ SnapshotPath = $SnapshotPath; DestinationPath = $DestinationPath; NonInteractive = $NonInteractive; WhatIf = [bool]$WhatIfPreference }
    if ($Categories) { $arguments.Categories = $Categories }
    $programReadLock = [IO.File]::Open((Join-Path $PSScriptRoot '.program.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try {
        if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.updates\pending.json')) { throw 'Unabgeschlossenes Programmupdate. Zuerst Update-UserProfileBackup.ps1 -Rollback ausfuehren.' }
        $result = Invoke-UserProfileRestore @arguments
    }
    finally { $programReadLock.Dispose() }
    $result
    if ($result.Errors) { exit 1 }
    exit 0
}
