#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceRepository = 'https://github.com/2xlc-cloud/SuperPSBackup',
    [string]$SourceRef = 'main',
    [switch]$KeepTestData
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Update-UserProfileBackup.ps1')
$caseRoot = Join-Path ([IO.Path]::GetTempPath()) ('SuperPSBackup-Online-Test-' + [guid]::NewGuid().ToString('N'))
$testInstallation = Join-Path $caseRoot 'program'
$null = New-Item -ItemType Directory -Path $testInstallation -Force
$script:onlineChecks = 0
$testPassed = $false; $oldGuiProcess = $null
function Assert-Online([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ONLINE-TEST FEHLGESCHLAGEN: $Message" }
    $script:onlineChecks++
    Write-Output "OK $script:onlineChecks - $Message"
}
try {
    foreach ($name in Get-BupUpdateFiles) {
        $sourceFile = Join-Path $PSScriptRoot $name
        if (Test-Path -LiteralPath $sourceFile) { [IO.File]::Copy($sourceFile, (Join-Path $testInstallation $name)) }
    }
    # Eine aeltere Version simulieren, ohne die produktive Installation zu veraendern.
    [IO.File]::AppendAllText((Join-Path $testInstallation 'Start-BackupGUI.ps1'), "`r`n# Isolierter aelterer Teststand.`r`n")
    $null = & (Join-Path $PSScriptRoot 'New-UpdateManifest.ps1') -SourcePath $testInstallation -Version '1.0.0'
    $baseline = Test-BupUpdatePackage $testInstallation
    $oldGuiHash = (Get-FileHash -LiteralPath (Join-Path $testInstallation 'Start-BackupGUI.ps1') -Algorithm SHA256).Hash
    [IO.File]::WriteAllText((Join-Path $testInstallation 'gui-settings.json'), 'local-config-sentinel')
    $null = New-Item -ItemType Directory -Path (Join-Path $testInstallation 'Backups')
    [IO.File]::WriteAllText((Join-Path $testInstallation 'Backups\keep.txt'), 'backup-sentinel')

    $info = Get-BupUpdateInfo $SourceRepository $SourceRef $testInstallation
    Assert-Online ($info.UpdateAvailable -and [version]$info.Version -gt [version]'1.0.0') 'Echte oeffentliche GitHub-Quelle liefert neuere Version und feste Commit-ID'
    $checked = & (Join-Path $testInstallation 'Update-UserProfileBackup.ps1') -RepositoryUrl $SourceRepository -Ref $SourceRef -InstallRoot $testInstallation -ExpectedCommit $info.Commit -CheckOnly
    Assert-Online ($checked.UpdateAvailable -and -not (Test-Path -LiteralPath (Join-Path $testInstallation '.updates'))) 'CLI-Onlinepruefung ohne Dateiaustausch'

    # Einen GUI-Prozess mit derselben Dateisperre simulieren. Kein sichtbares Fenster.
    $readyPath = Join-Path $caseRoot 'gui-lock-ready'
    $lockPath = Join-Path $testInstallation '.program.lock'
    $helperCommand = "`$guard = [IO.File]::Open('" + $lockPath.Replace("'", "''") + "', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite); try { [IO.File]::WriteAllText('" + $readyPath.Replace("'", "''") + "', 'ready'); Start-Sleep -Seconds 2 } finally { `$guard.Dispose() }"
    $helperEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($helperCommand))
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $oldGuiProcess = Start-Process -FilePath $windowsPowerShell -ArgumentList "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $helperEncoded" -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(15)
    while (-not (Test-Path -LiteralPath $readyPath)) {
        if ((Get-Date) -gt $deadline) { throw 'GUI-Sperrprozess wurde nicht bereit.' }
        Start-Sleep -Milliseconds 50
    }

    # Genau das Skript der Testinstallation aktualisiert hier auch seine eigene Datei.
    $installed = & (Join-Path $testInstallation 'Update-UserProfileBackup.ps1') -RepositoryUrl $SourceRepository -Ref $SourceRef -InstallRoot $testInstallation -ExpectedCommit $info.Commit -WaitForProcessId $oldGuiProcess.Id
    Assert-Online ($installed.Status -eq 'Updated' -and $installed.Commit -eq $info.Commit -and $oldGuiProcess.HasExited) 'Echter CLI-Updater wartet auf Prozessende und installiert den festgelegten Online-Commit'
    $verified = Test-BupUpdatePackage $testInstallation
    $allMatch = $true
    foreach ($entry in $info.Manifest.Files) {
        if ((Get-FileHash -LiteralPath (Join-Path $testInstallation $entry.Name) -Algorithm SHA256).Hash -ne $entry.SHA256) { $allMatch = $false }
    }
    Assert-Online ($allMatch -and $verified.Version -eq $info.Version) 'Alle heruntergeladenen Programmdateien entsprechen den SHA-256-Werten des Remote-Manifests'
    Assert-Online ([IO.File]::ReadAllText((Join-Path $testInstallation 'gui-settings.json')) -eq 'local-config-sentinel' -and [IO.File]::ReadAllText((Join-Path $testInstallation 'Backups\keep.txt')) -eq 'backup-sentinel') 'Onlineupdate behaelt lokale Einstellungen und Sicherungsdateien bei'
    $current = & (Join-Path $testInstallation 'Update-UserProfileBackup.ps1') -RepositoryUrl $SourceRepository -Ref $SourceRef -InstallRoot $testInstallation -ExpectedCommit $info.Commit -CheckOnly
    Assert-Online (-not $current.UpdateAvailable -and $current.InstalledVersion -eq $info.Version) 'Erneute Onlinepruefung erkennt die aktuelle Version'

    & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File (Join-Path $testInstallation 'Start-BackupGUI.ps1') -SettingsPath (Join-Path $caseRoot 'fresh-gui-settings.json') -NoShow
    Assert-Online ($LASTEXITCODE -eq 0) 'Aktualisierte GUI startet in Windows PowerShell ohne sichtbares Testfenster'

    $sampleSource = Join-Path $caseRoot 'source'
    $sampleTarget = Join-Path $caseRoot 'backup-target'
    foreach ($path in @($sampleSource,$sampleTarget)) { $null = New-Item -ItemType Directory -Path $path }
    [IO.File]::WriteAllText((Join-Path $sampleSource 'sample.txt'), 'backup-after-online-update')
    . (Join-Path $testInstallation 'Backup-UserProfile.ps1')
    $backupResult = Invoke-UserProfileBackup -BackupRoot $sampleTarget -LogRoot (Join-Path $caseRoot 'logs') -SourceFolders @{ Documents = $sampleSource }
    Assert-Online ($backupResult.Status -eq 'Complete' -and [IO.File]::ReadAllText((Join-Path $backupResult.SnapshotPath 'Documents\sample.txt')) -eq 'backup-after-online-update') 'Nach Onlineupdate ist eine neue Sicherung weiterhin erfolgreich'

    $rolledBack = & (Join-Path $testInstallation 'Update-UserProfileBackup.ps1') -InstallRoot $testInstallation -Rollback
    Assert-Online ($rolledBack.Status -eq 'RolledBack' -and $rolledBack.Version -eq '1.0.0' -and (Get-FileHash -LiteralPath (Join-Path $testInstallation 'Start-BackupGUI.ps1') -Algorithm SHA256).Hash -eq $oldGuiHash) 'Echter CLI-Rollback stellt die vorige Version bytegenau wieder her'
    $null = Test-BupUpdatePackage $testInstallation
    Assert-Online (-not (Test-Path -LiteralPath (Join-Path $testInstallation '.updates\pending.json')) -and [IO.File]::ReadAllText((Join-Path $testInstallation 'Backups\keep.txt')) -eq 'backup-sentinel') 'Rollback abgeschlossen; keine offene Transaktion und kein Verlust von Sicherungsdaten'
    $testPassed = $true
    Write-Output "ERFOLGREICH: $script:onlineChecks Online-Pruefungen. Version=$($info.Version) Commit=$($info.Commit)"
}
finally {
    if ($null -ne $oldGuiProcess) { $oldGuiProcess.Dispose() }
    if ($testPassed -and -not $KeepTestData) {
        . (Join-Path $PSScriptRoot 'Backup-UserProfile.ps1')
        $resolved = [IO.Path]::GetFullPath($caseRoot)
        if (-not (Test-BupChild $resolved ([IO.Path]::GetTempPath())) -or (Split-Path -Leaf $resolved) -notmatch '^SuperPSBackup-Online-Test-[a-f0-9]{32}$') { throw 'Unsicherer Online-Testpfad.' }
        Remove-BupTree $resolved
    }
    else { Write-Output "Testdaten: $caseRoot" }
}
