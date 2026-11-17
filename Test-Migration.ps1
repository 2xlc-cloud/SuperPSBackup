#requires -Version 5.1
# Prueft die Uebernahme der frueheren Version (UserProfileBackup) unter dem Namen SuperPSBackup:
# Datenordner, gespeicherte Pfade/Updatequelle und Windows-Aufgaben.
# Es werden nur Aufgaben mit eindeutigen Testnamen und ein temporaerer LOCALAPPDATA-Ordner verwendet;
# die echten Aufgaben und Daten des Benutzers bleiben unberuehrt.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'Install-BackupTask.ps1'
. (Join-Path $PSScriptRoot 'Start-BackupGUI.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('SuperPSBackup-Migration-Test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$names = @{ LegacyBackup = "SuperPSBackupTest-LB-$suffix"; LegacyUpdate = "SuperPSBackupTest-LU-$suffix"; Backup = "SuperPSBackupTest-B-$suffix"; Update = "SuperPSBackupTest-U-$suffix" }
$script:checks = 0
$realLocalAppData = $env:LOCALAPPDATA
function Assert-Migration([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "MIGRATION-TEST FEHLGESCHLAGEN: $Message" }
    $script:checks++
    Write-Output "OK $script:checks - $Message"
}
function Get-TestTask([string]$Name) { @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $Name })[0] }
function Get-TaskText($Task) {
    [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(([string]$Task.Actions[0].Arguments -split ' ')[-1]))
}
function Remove-TestTasks { foreach ($name in $names.Values) { if (Get-TestTask $name) { Unregister-ScheduledTask -TaskName $name -Confirm:$false } } }
function Invoke-Migration { & $installer -MigrateLegacy -NameOverride $names }
$testPassed = $false
try {
    # ---------- reine Pfadumsetzung der GUI
    $env:LOCALAPPDATA = Join-Path $testRoot 'Local'
    $null = New-Item -ItemType Directory -Path $env:LOCALAPPDATA
    $legacyData = Join-Path $env:LOCALAPPDATA 'UserProfileBackup'
    $newData = Join-Path $env:LOCALAPPDATA 'SuperPSBackup'
    Assert-Migration ((ConvertTo-BupCurrentSettingsPath (Join-Path $legacyData 'gui-settings.json')) -eq (Join-Path $newData 'gui-settings.json')) 'GUI-Start mit altem Einstellungspfad (alter Updater) nutzt den neuen Ordner'
    Assert-Migration ((ConvertTo-BupCurrentSettingsPath 'C:\Andere\gui.json') -eq 'C:\Andere\gui.json' -and (ConvertTo-BupCurrentSettingsPath (Join-Path $env:LOCALAPPDATA 'UserProfileBackupX\gui.json')) -eq (Join-Path $env:LOCALAPPDATA 'UserProfileBackupX\gui.json')) 'Fremde Pfade und aehnlich benannte Ordner bleiben unveraendert'

    # ---------- nichts vorhanden
    Assert-Migration ((Invoke-Migration) -eq 'Nichts zu uebernehmen.') 'Ohne fruehere Version meldet die Uebernahme nichts zu tun'

    # ---------- Datenordner und Einstellungen
    $target = Join-Path $testRoot "Ziel O'Brien"; $null = New-Item -ItemType Directory -Path $target
    $null = New-Item -ItemType Directory -Path (Join-Path $legacyData 'Logs'), (Join-Path $legacyData 'Updates')
    [IO.File]::WriteAllText((Join-Path $legacyData 'Logs\alt.log'), 'altes Protokoll')
    [IO.File]::WriteAllText((Join-Path $legacyData 'Updates\2026-01-01.log'), 'altes Updateprotokoll')
    @{ BackupRoot = $target; LogRoot = (Join-Path $legacyData 'Logs'); DelayMinutes = 5; DailyAt = '19:30'; RetentionDays = 14 } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $legacyData 'gui-settings.json') -Encoding UTF8
    @{ RepositoryUrl = 'https://github.com/2xlc-cloud/UserProfileBackup'; Ref = 'main' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $legacyData 'update-source.json') -Encoding UTF8

    # ---------- alte Aufgaben (mit Sonderzeichen, Tagestrigger, deaktiviert)
    $legacyLogs = Join-Path $legacyData 'Logs'
    $null = & $installer -BackupRoot $target -LogRoot $legacyLogs -DelayMinutes 6 -DailyAt '07:45' -RetentionDays 9 -RetentionMonths 11 -RetentionYears 4 -LogDays 21 -TaskName $names.LegacyBackup
    $null = & $installer -UpdateTask -UpdateRepositoryUrl 'https://github.com/2xlc-cloud/UserProfileBackup' -UpdateRef 'main' -UpdateMode Install -DelayMinutes 9 -LogRoot $legacyLogs -TaskName $names.LegacyUpdate
    Disable-ScheduledTask -TaskName $names.LegacyUpdate | Out-Null
    Assert-Migration ($null -ne (Get-TestTask $names.LegacyBackup) -and $null -ne (Get-TestTask $names.LegacyUpdate)) 'Testaufgaben der frueheren Version angelegt'

    $report = Invoke-Migration
    Assert-Migration ($report -match 'Datenordner uebernommen' -and -not (Test-Path -LiteralPath $legacyData) -and (Test-Path -LiteralPath (Join-Path $newData 'Logs\alt.log')) -and (Test-Path -LiteralPath (Join-Path $newData 'Updates\2026-01-01.log'))) 'Datenordner samt Protokollen in den neuen Ordner verschoben'
    $settings = Get-Content -LiteralPath (Join-Path $newData 'gui-settings.json') -Raw | ConvertFrom-Json
    $source = Get-Content -LiteralPath (Join-Path $newData 'update-source.json') -Raw | ConvertFrom-Json
    Assert-Migration ($settings.LogRoot -eq (Join-Path $newData 'Logs') -and $settings.BackupRoot -eq $target -and $settings.DelayMinutes -eq 5 -and $settings.RetentionDays -eq 14) 'Gespeicherter Protokollpfad zeigt auf den neuen Ordner, uebrige Einstellungen bleiben'
    Assert-Migration ($source.RepositoryUrl -eq 'https://github.com/2xlc-cloud/SuperPSBackup' -and $source.Ref -eq 'main') 'Gespeicherte Updatequelle zeigt auf das umbenannte Repository'

    $newBackup = Get-TestTask $names.Backup; $newUpdate = Get-TestTask $names.Update
    Assert-Migration ($null -ne $newBackup -and $null -ne $newUpdate -and $null -eq (Get-TestTask $names.LegacyBackup) -and $null -eq (Get-TestTask $names.LegacyUpdate)) 'Aufgaben unter neuem Namen angelegt, alte Aufgaben entfernt'
    $backupText = Get-TaskText $newBackup
    $backupLogon = @($newBackup.Triggers | Where-Object { $_.CimClass.CimClassName -match 'Logon' })[0]
    $backupDaily = @($newBackup.Triggers | Where-Object { $_.CimClass.CimClassName -match 'Daily|Time|Calendar' })[0]
    Assert-Migration ($backupText.Contains("Ziel O''Brien") -and $backupText.Contains((Join-Path $newData 'Logs')) -and $backupText.Contains('-RetentionDays 9 -RetentionMonths 11 -RetentionYears 4 -LogDays 21') -and $backupLogon.Delay -eq 'PT6M' -and ([datetime]$backupDaily.StartBoundary).ToString('HH:mm') -eq '07:45') 'Backup-Aufgabe behaelt Ziel (Sonderzeichen), Aufbewahrung, Verzoegerung und Tageszeit; Protokoll im neuen Ordner'
    $updateText = Get-TaskText $newUpdate
    $updateLogon = @($newUpdate.Triggers | Where-Object { $_.CimClass.CimClassName -match 'Logon' })[0]
    Assert-Migration ($updateText.Contains('https://github.com/2xlc-cloud/SuperPSBackup') -and -not $updateText.Contains('-CheckOnly') -and $updateText.Contains((Join-Path $newData 'Logs\update-task.log')) -and $updateLogon.Delay -eq 'PT9M' -and $newUpdate.Triggers.Count -eq 1) 'Update-Aufgabe behaelt Modus Installieren, Verzoegerung, nutzt neue Quelle und neues Protokoll'
    Assert-Migration ([string]$newUpdate.State -eq 'Disabled' -and [string]$newBackup.State -ne 'Disabled') 'Deaktivierter Zustand der alten Update-Aufgabe bleibt erhalten'
    Assert-Migration ((Invoke-Migration) -eq 'Nichts zu uebernehmen.') 'Zweiter Lauf ist ein Nullvorgang'

    # ---------- Datenordner zusammenfuehren, wenn beide existieren
    $null = New-Item -ItemType Directory -Path (Join-Path $legacyData 'Logs')
    [IO.File]::WriteAllText((Join-Path $legacyData 'extra.txt'), 'extra')
    [IO.File]::WriteAllText((Join-Path $legacyData 'gui-settings.json'), 'ALT-NICHT-UEBERSCHREIBEN')
    $report = Invoke-Migration
    Assert-Migration ($report -match 'zusammengefuehrt' -and (Test-Path -LiteralPath (Join-Path $newData 'extra.txt')) -and (Get-Content -LiteralPath (Join-Path $newData 'gui-settings.json') -Raw) -notmatch 'ALT-NICHT' -and (Test-Path -LiteralPath (Join-Path $legacyData 'gui-settings.json'))) 'Vorhandene neue Dateien werden beim Zusammenfuehren nie ueberschrieben'
    Remove-Item -LiteralPath $legacyData -Recurse -Force

    # ---------- alte Aufgabe, wenn die neue schon existiert
    $null = & $installer -BackupRoot $target -DelayMinutes 3 -TaskName $names.LegacyBackup
    $report = Invoke-Migration
    Assert-Migration ($report -match 'bereits unter neuem Namen' -and $null -eq (Get-TestTask $names.LegacyBackup) -and $null -ne (Get-TestTask $names.Backup)) 'Alte Aufgabe wird entfernt, wenn die neue bereits existiert; neue bleibt unveraendert'
    Remove-TestTasks

    # ---------- Aufgabe zeigt auf einen anderen Programmordner (Ordner umbenannt/verschoben)
    $oldHome = Join-Path $testRoot "Altes Programm 'X'"; $null = New-Item -ItemType Directory -Path $oldHome
    foreach ($name in 'Install-BackupTask.ps1', 'Backup-UserProfile.ps1', 'Update-UserProfileBackup.ps1') { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $oldHome }
    $null = & (Join-Path $oldHome 'Install-BackupTask.ps1') -BackupRoot $target -DelayMinutes 8 -TaskName $names.Backup
    $null = & (Join-Path $oldHome 'Install-BackupTask.ps1') -UpdateTask -DelayMinutes 11 -TaskName $names.Update
    Disable-ScheduledTask -TaskName $names.Update | Out-Null
    Assert-Migration ((Get-TaskText (Get-TestTask $names.Backup)).Contains($oldHome.Replace("'", "''")) -and -not (Get-TaskText (Get-TestTask $names.Backup)).Contains($PSScriptRoot)) 'Ausgangslage: Aufgaben zeigen auf einen anderen Programmordner'
    $report = Invoke-Migration
    $repBackup = Get-TestTask $names.Backup; $repUpdate = Get-TestTask $names.Update
    $repLogon = @($repBackup.Triggers | Where-Object { $_.CimClass.CimClassName -match 'Logon' })[0]
    Assert-Migration ($report -match 'zeigt jetzt auf den Programmordner' -and (Get-TaskText $repBackup).Contains((Join-Path $PSScriptRoot 'Backup-UserProfile.ps1')) -and (Get-TaskText $repUpdate).Contains((Join-Path $PSScriptRoot 'Update-UserProfileBackup.ps1')) -and $repLogon.Delay -eq 'PT8M' -and [string]$repUpdate.State -eq 'Disabled') 'Aufgaben werden auf den aktuellen Programmordner umgestellt; Verzoegerung und Deaktiviert bleiben erhalten'
    Assert-Migration ((Invoke-Migration) -eq 'Nichts zu uebernehmen.') 'Nach der Reparatur ist ein weiterer Lauf ein Nullvorgang'
    Remove-TestTasks
    # ---------- nicht uebernehmbare Aufgabe bleibt bestehen
    $missing = Join-Path $testRoot 'wird-geloescht'; $null = New-Item -ItemType Directory -Path $missing
    $null = & $installer -BackupRoot $missing -TaskName $names.LegacyBackup
    Remove-Item -LiteralPath $missing -Force
    $report = Invoke-Migration
    Assert-Migration ($report -match 'alte Aufgabe bleibt bestehen' -and $null -ne (Get-TestTask $names.LegacyBackup) -and $null -eq (Get-TestTask $names.Backup)) 'Nicht uebernehmbare Aufgabe (Ziel fehlt) bleibt unveraendert bestehen und wird gemeldet'
    Remove-TestTasks
    Assert-Migration ($null -eq (Get-TestTask $names.LegacyBackup) -and $null -eq (Get-TestTask $names.Backup) -and $null -eq (Get-TestTask $names.Update) -and $null -eq (Get-TestTask $names.LegacyUpdate)) 'Keine Testaufgaben im Aufgabenplaner zurueckgeblieben'
    $testPassed = $true
    Write-Output "ERFOLGREICH: $script:checks Migrations-Pruefungen."
}
finally {
    $env:LOCALAPPDATA = $realLocalAppData
    try { Remove-TestTasks } catch { Write-Warning "Testaufgaben konnten nicht entfernt werden: $_" }
    . (Join-Path $PSScriptRoot 'Backup-UserProfile.ps1')
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not (Test-BupChild $resolved ([IO.Path]::GetTempPath())) -or (Split-Path -Leaf $resolved) -notmatch '^SuperPSBackup-Migration-Test-[a-f0-9]{32}$') { throw 'Unsicherer Testpfad.' }
    for ($try = 1; $try -le 5; $try++) { try { Remove-BupTree $resolved; break } catch { if ($try -eq 5) { Write-Warning "Testordner nicht entfernt: $resolved" } else { Start-Sleep -Seconds 2 } } }
}
