#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Update-UserProfileBackup.ps1')
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('SuperPSBackup-Update-Test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $sandbox
$script:updateChecks = 0
function Assert-Update([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "UPDATE-TEST FEHLGESCHLAGEN: $Message" }
    $script:updateChecks++
    Write-Output "OK $script:updateChecks - $Message"
}
function Write-FixtureManifest([string]$Path, [string]$Version) {
    $files = @(Get-BupUpdateFiles | ForEach-Object {
        $file = Join-Path $Path $_
        [pscustomobject]@{ Name = $_; Length = (Get-Item -LiteralPath $file).Length; SHA256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash }
    })
    [pscustomobject]@{ Format = 1; Version = $Version; Files = $files } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Path 'update-manifest.json') -Encoding UTF8
}
function New-UpdateFixture([string]$Name) {
    $root = Join-Path $sandbox $Name
    $null = New-Item -ItemType Directory -Path $root
    $old = Join-Path $root 'installed'; $new = Join-Path $root 'candidate'
    foreach ($path in @($old, $new)) {
        $null = New-Item -ItemType Directory -Path $path
        foreach ($file in Get-BupUpdateFiles) { [IO.File]::WriteAllText((Join-Path $path $file), "# $Name $(Split-Path -Leaf $path)`r`n") }
    }
    Write-FixtureManifest $old '1.0.0'; Write-FixtureManifest $new '1.1.0'
    [IO.File]::WriteAllText((Join-Path $old 'gui-settings.json'), 'private-settings')
    $null = New-Item -ItemType Directory -Path (Join-Path $old 'Backups')
    [IO.File]::WriteAllText((Join-Path $old 'Backups\personal.txt'), 'private-backup')
    [pscustomobject]@{ Installed = $old; Candidate = $new }
}
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { $null = & $Action } catch { $rejected = $true }
    Assert-Update $rejected $Message
}
$passed = $false
try {
    $repo = Get-BupRepository 'https://github.com/2xlc-cloud/SuperPSBackup.git'
    Assert-Update ($repo.Url -eq 'https://github.com/2xlc-cloud/SuperPSBackup') 'GitHub-URL einschliesslich .git normalisiert'
    foreach ($url in @('https://github.com/2xlc-cloud','http://github.com/a/b','https://example.org/a/b','file:///C:/temp','https://github.com/a/b/tree/main')) {
        Assert-Rejected { Get-BupRepository $url } "Unsichere oder unvollstaendige Quelle abgewiesen: $url"
    }
    $fixture = New-UpdateFixture 'success'
    $result = Install-BupUpdatePackage $fixture.Installed $fixture.Candidate ('a' * 40)
    Assert-Update ($result.Status -eq 'Updated' -and (Read-BupUpdateManifest (Join-Path $fixture.Installed 'update-manifest.json')).Version -eq '1.1.0') 'Gueltige neue Version installiert'
    Assert-Update ((Get-FileHash -LiteralPath (Join-Path $fixture.Installed 'Start-BackupGUI.ps1')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $fixture.Candidate 'Start-BackupGUI.ps1')).Hash) 'Installierte GUI entspricht dem geprueften Paket'
    Assert-Update ((Get-FileHash -LiteralPath (Join-Path $fixture.Installed 'Update-UserProfileBackup.ps1')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $fixture.Candidate 'Update-UserProfileBackup.ps1')).Hash) 'Updater aktualisiert auch seine eigene Datei'
    Assert-Update ([IO.File]::ReadAllText((Join-Path $fixture.Installed 'gui-settings.json')) -eq 'private-settings' -and [IO.File]::ReadAllText((Join-Path $fixture.Installed 'Backups\personal.txt')) -eq 'private-backup') 'Lokale Einstellungen und Backups unangetastet'
    $undo = Undo-BupUpdate $fixture.Installed
    Assert-Update ($undo.Status -eq 'RolledBack' -and $undo.Version -eq '1.0.0') 'Letztes Update manuell rueckgaengig gemacht'
    Assert-Update ([IO.File]::ReadAllText((Join-Path $fixture.Installed 'Backup-UserProfile.ps1')).Contains('installed')) 'Urspruengliche Programmdatei wiederhergestellt'

    $hashFailure = New-UpdateFixture 'hash'
    [IO.File]::AppendAllText((Join-Path $hashFailure.Candidate 'Backup-UserProfile.ps1'), '# changed')
    Assert-Rejected { Install-BupUpdatePackage $hashFailure.Installed $hashFailure.Candidate } 'Falsche Pruefsumme vor Aenderung installierter Dateien erkannt'
    Assert-Update ((Read-BupUpdateManifest (Join-Path $hashFailure.Installed 'update-manifest.json')).Version -eq '1.0.0') 'Bei Pruefsummenfehler bleibt alte Version erhalten'
    $syntaxFailure = New-UpdateFixture 'syntax'
    [IO.File]::WriteAllText((Join-Path $syntaxFailure.Candidate 'Start-BackupGUI.ps1'), 'function Invalid {')
    Write-FixtureManifest $syntaxFailure.Candidate '1.1.0'
    Assert-Rejected { Install-BupUpdatePackage $syntaxFailure.Installed $syntaxFailure.Candidate } 'Syntaxfehler trotz passender Pruefsumme erkannt'
    $missingFile = New-UpdateFixture 'missing-file'
    [IO.File]::Delete((Join-Path $missingFile.Candidate 'Restore-UserProfile.ps1'))
    Assert-Rejected { Install-BupUpdatePackage $missingFile.Installed $missingFile.Candidate } 'Unvollstaendiges Paket vor Installation abgewiesen'

    $pathFailure = New-UpdateFixture 'path'
    $badManifest = Read-BupUpdateManifest (Join-Path $pathFailure.Candidate 'update-manifest.json')
    $badManifest.Files[0].Name = '..\private.txt'
    Assert-Rejected { Test-BupUpdateManifest $badManifest } 'Pfad ausserhalb der Programmdateien abgewiesen'
    $badManifest.Files[0].Name = 'gui-settings.json'
    Assert-Rejected { Test-BupUpdateManifest $badManifest } 'Einstellungen duerfen nicht im Update-Paket stehen'
    $badManifest.Files[0].Name = $badManifest.Files[1].Name
    Assert-Rejected { Test-BupUpdateManifest $badManifest } 'Doppelte Dateinamen abgewiesen'
    Write-FixtureManifest $pathFailure.Candidate '0.9.0'
    Assert-Rejected { Install-BupUpdatePackage $pathFailure.Installed $pathFailure.Candidate } 'Unbeabsichtigtes Downgrade verhindert'

    $locked = New-UpdateFixture 'locked'
    $held = [IO.File]::Open((Join-Path $locked.Installed '.program.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try { Assert-Rejected { Install-BupUpdatePackage $locked.Installed $locked.Candidate } 'Laufende GUI/Sicherung sperrt den Dateiaustausch' }
    finally { $held.Dispose() }
    Assert-Update ((Read-BupUpdateManifest (Join-Path $locked.Installed 'update-manifest.json')).Version -eq '1.0.0') 'Sperrkonflikt veraendert keine Programmdatei'

    $failedWrite = New-UpdateFixture 'write-failure'
    $script:realSetter = ${function:Set-BupProgramFile}
    $script:writeCount = 0; $script:failOneWrite = $true
    function Set-BupProgramFile([string]$Source, [string]$Destination) {
        $script:writeCount++
        if ($script:failOneWrite -and $script:writeCount -eq 3) { $script:failOneWrite = $false; throw 'Test: Schreibfehler beim dritten Dateiaustausch.' }
        & $script:realSetter $Source $Destination
    }
    try { Assert-Rejected { Install-BupUpdatePackage $failedWrite.Installed $failedWrite.Candidate } 'Dateiaustauschfehler korrekt gemeldet' }
    finally { Set-Item -LiteralPath Function:\Set-BupProgramFile -Value $script:realSetter }
    Assert-Update ((Read-BupUpdateManifest (Join-Path $failedWrite.Installed 'update-manifest.json')).Version -eq '1.0.0' -and [IO.File]::ReadAllText((Join-Path $failedWrite.Installed 'Backup-UserProfile.ps1')).Contains('installed')) 'Automatischer Rollback nach teilweise erfolgtem Austausch'
    Assert-Update (-not (Test-Path -LiteralPath (Join-Path $failedWrite.Installed '.updates\pending.json'))) 'Erfolgreicher Fehler-Rollback hinterlaesst keinen offenen Vorgang'

    $interrupted = New-UpdateFixture 'interrupted'
    $null = Install-BupUpdatePackage $interrupted.Installed $interrupted.Candidate
    [IO.File]::Copy((Join-Path $interrupted.Installed '.updates\last-update.json'), (Join-Path $interrupted.Installed '.updates\pending.json'))
    [IO.File]::WriteAllText((Join-Path $interrupted.Installed 'Backup-UserProfile.ps1'), '# simulated interrupted update')
    Assert-Rejected { Install-BupUpdatePackage $interrupted.Installed $interrupted.Candidate } 'Offener Updatevorgang verhindert weiteres Update'
    $recovery = Undo-BupUpdate $interrupted.Installed
    Assert-Update ($recovery.Version -eq '1.0.0' -and -not (Test-Path -LiteralPath (Join-Path $interrupted.Installed '.updates\pending.json'))) 'Wiederherstellung aus Journal nach simuliertem Abbruch'

    # GitHub-Antworten und Downloads isoliert simulieren; kein fremder Code wird ausgefuehrt.
    $remote = New-UpdateFixture 'remote'
    $script:remotePackage = $remote.Candidate
    $script:requestedUrls = New-Object 'System.Collections.Generic.List[string]'
    function Invoke-RestMethod {
        [CmdletBinding()]
        param([string]$Uri, $Headers, [int]$TimeoutSec)
        $script:requestedUrls.Add($Uri)
        if ($Uri.Contains('/commits/')) { return [pscustomobject]@{ sha = ('a' * 40) } }
        Get-Content -LiteralPath (Join-Path $script:remotePackage 'update-manifest.json') -Raw | ConvertFrom-Json
    }
    function Save-BupDownload([string]$Uri,[string]$Path,$Headers) {
        $script:requestedUrls.Add($Uri)
        if ($script:simulateDownloadFailure -and $Uri.EndsWith('/Restore-UserProfile.ps1')) { throw 'Test: Netzwerkverbindung unterbrochen.' }
        [IO.File]::Copy((Join-Path $script:remotePackage ($Uri.Split('/')[-1])), $Path, $false)
    }
    $script:simulateDownloadFailure = $false
    try {
        $check = Invoke-BupUpdate -RepositoryUrl 'https://github.com/2xlc-cloud/SuperPSBackup' -InstallRoot $remote.Installed -CheckOnly
        Assert-Update ($check.UpdateAvailable -and $check.Commit -eq ('a' * 40) -and -not (Test-Path -LiteralPath (Join-Path $remote.Installed '.updates'))) 'Updatepruefung liefert Version/Commit ohne Installation'
        $downloaded = Invoke-BupUpdate -RepositoryUrl 'https://github.com/2xlc-cloud/SuperPSBackup' -InstallRoot $remote.Installed -ExpectedCommit ('a' * 40)
        Assert-Update ($downloaded.Status -eq 'Updated' -and $downloaded.Commit -eq ('a' * 40)) 'Vollstaendiger Download-, Pruef- und Installationsablauf'
        Assert-Update (@($script:requestedUrls | Where-Object { $_.Contains('raw.githubusercontent.com') -and -not $_.Contains('/' + ('a' * 40) + '/') }).Count -eq 0) 'Alle Dateien stammen aus demselben festgelegten Commit'
        $upToDate = Invoke-BupUpdate -RepositoryUrl 'https://github.com/2xlc-cloud/SuperPSBackup' -InstallRoot $remote.Installed -CheckOnly
        Assert-Update (-not $upToDate.UpdateAvailable) 'Aktuelle identische Installation wird erkannt'
        Assert-Rejected { Invoke-BupUpdate -RepositoryUrl 'https://github.com/2xlc-cloud/SuperPSBackup' -InstallRoot $remote.Installed -ExpectedCommit ('b' * 40) } 'Unerwartete Commit-Antwort wird abgewiesen'
        Assert-Rejected { Invoke-BupUpdate -InstallRoot $remote.Installed -WaitForProcessId $PID } 'Updater wartet nicht auf sich selbst'
        $network = New-UpdateFixture 'network-failure'
        $script:remotePackage = $network.Candidate
        $script:simulateDownloadFailure = $true
        Assert-Rejected { Invoke-BupUpdate -RepositoryUrl 'https://github.com/2xlc-cloud/SuperPSBackup' -InstallRoot $network.Installed } 'Downloadabbruch vor Dateiaustausch abgefangen'
        Assert-Update ((Read-BupUpdateManifest (Join-Path $network.Installed 'update-manifest.json')).Version -eq '1.0.0' -and @(Get-ChildItem -LiteralPath (Join-Path $network.Installed '.updates') -Directory -Filter 'stage-*').Count -eq 0) 'Netzwerkfehler belaesst alte Version und entfernt unvollstaendigen Download'
    }
    finally { Remove-Item -LiteralPath Function:\Invoke-RestMethod; Remove-Item -LiteralPath Function:\Save-BupDownload }
    $passed = $true
    Write-Output "ERFOLGREICH: $script:updateChecks Update-Pruefungen mit PowerShell $($PSVersionTable.PSVersion)."
}
finally {
    if ($passed) {
        . (Join-Path $PSScriptRoot 'Backup-UserProfile.ps1')
        $resolved = [IO.Path]::GetFullPath($sandbox)
        if (-not (Test-BupChild $resolved ([IO.Path]::GetTempPath())) -or (Split-Path -Leaf $resolved) -notmatch '^SuperPSBackup-Update-Test-[a-f0-9]{32}$') { throw 'Unsicherer Update-Testpfad.' }
        Remove-BupTree $resolved
    }
    else { Write-Output "Testdaten: $sandbox" }
}
