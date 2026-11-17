#requires -Version 5.1
[CmdletBinding()]
param([string]$PreviewPath = '')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Start-BackupGUI.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('UserProfileBackup-GUI-Test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$script:guiChecks = 0
function Assert-Gui([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "GUI-TEST FEHLGESCHLAGEN: $Message" }
    $script:guiChecks++
    Write-Output "OK $script:guiChecks - $Message"
}
function Wait-GuiWork($Window) {
    $deadline = (Get-Date).AddSeconds(30)
    while ($null -ne $Window.Worker) {
        [Windows.Forms.Application]::DoEvents()
        Complete-BupGuiWork $Window
        if ((Get-Date) -gt $deadline) { throw 'Zeitlimit fuer Hintergrundvorgang erreicht.' }
        Start-Sleep -Milliseconds 25
    }
}
$gui = $null
try {
    [Windows.Forms.Application]::EnableVisualStyles()
    $gui = New-BupGuiWindow (Join-Path $testRoot 'config.json')
    # Handles erstellen, aber kein Fenster anzeigen; Timer/Event-Schleife bleibt testbar.
    $null = $gui.Form.Handle
    Assert-Gui ($gui.Controls.Tabs.TabPages.Count -eq 4) 'Vier Bereiche Install, Backup, Taskplanung, Restore'
    Assert-Gui (-not $gui.Form.Visible -and $gui.Controls.Delay.Value -eq 2) 'Unsichtbarer Testaufbau, Standardverzoegerung zwei Minuten'
    $updateDialog = New-BupUpdateDialog $gui
    try {
        Assert-Gui ($updateDialog.BackColor.R -lt 50 -and $updateDialog.Tag.Repository.Text -eq 'https://github.com/2xlc-cloud/UserProfileBackup' -and $updateDialog.Tag.Branch.Text -eq 'main') 'Dunkler Updatedialog mit vorbereiteter GitHub-Quelle'
    }
    finally { $updateDialog.Dispose() }
    $fakeInfo = [pscustomobject]@{ RepositoryUrl = 'https://github.com/2xlc-cloud/UserProfileBackup'; Ref = "release/O'Brien"; Commit = ('a' * 40) }
    $launch = Get-BupUpdateLaunch $gui $fakeInfo
    $launchText = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($launch.Arguments -split ' ')[-1]))
    $launchTokens = $null; $launchErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($launchText, [ref]$launchTokens, [ref]$launchErrors)
    Assert-Gui ($launchErrors.Count -eq 0 -and $launchText.Contains("O''Brien") -and $launchText.Contains('-ExpectedCommit') -and $launchText.Contains("-WaitForProcessId $PID") -and $launch.Arguments.Contains('-WindowStyle Hidden')) 'Sicherer versteckter Updaterstart mit Commitbindung und Warten auf GUI-Ende'
    $script:realUpdateConfirmation = ${function:Confirm-BupProgramUpdate}
    $script:confirmationCalls = 0
    $script:timerStoppedBeforeConfirmation = $false
    function Confirm-BupProgramUpdate($Window, $Info) {
        $script:confirmationCalls++
        $script:timerStoppedBeforeConfirmation = -not $Window.Timer.Enabled
        return $false
    }
    $completedUpdateCheck = [PowerShell]::Create()
    $null = $completedUpdateCheck.AddScript({ [pscustomobject]@{ UpdateAvailable = $true; Version = '1.0.2'; InstalledVersion = '1.0.1'; RepositoryUrl = 'https://github.com/2xlc-cloud/UserProfileBackup'; Commit = ('a' * 40) } })
    $completedHandle = $completedUpdateCheck.BeginInvoke()
    while (-not $completedHandle.IsCompleted) { Start-Sleep -Milliseconds 10 }
    $gui.Worker = [pscustomobject]@{ PowerShell = $completedUpdateCheck; Handle = $completedHandle; Action = 'UpdateCheck' }
    $gui.Timer.Start()
    try { Complete-BupGuiWork $gui }
    finally { Set-Item -LiteralPath Function:\Confirm-BupProgramUpdate -Value $script:realUpdateConfirmation }
    Assert-Gui ($script:confirmationCalls -eq 1 -and $script:timerStoppedBeforeConfirmation -and $null -eq $gui.Worker) 'Updatebestaetigung einmalig bei gestopptem Timer; Ablehnen beendet den Vorgang ohne Installation'
    Assert-Gui ($gui.Form.BackColor.R -lt 50 -and $gui.Form.ForeColor.R -gt 200 -and $gui.Controls.Root.BackColor.R -lt 50 -and $gui.Controls.Output.BackColor.R -lt 50) 'Darkmode standardmaessig fuer Fenster, Eingaben und Ergebnisse aktiv'
    foreach ($scale in @(1.0, 1.25, 1.5, 2.0)) {
        $layout = New-BupGuiWindow (Join-Path $testRoot 'layout-settings.json')
        try {
            if ($scale -ne 1.0) { $layout.Form.Scale((New-Object Drawing.SizeF($scale, $scale))) }
            $layout.Form.PerformLayout()
            $settingsBounds = $layout.Controls.SettingsButton.Bounds
            $overlapping = @($layout.Form.Controls | Where-Object { $_ -ne $layout.Controls.SettingsButton -and $_.Bounds.IntersectsWith($settingsBounds) })
            Assert-Gui ($overlapping.Count -eq 0) "Einstellungsbutton ohne ueberlagernde Texte bei $([int]($scale * 100)) Prozent Layoutskalierung"
            $headerButtons = @($layout.Buttons | Where-Object { $_.Tag -in @('Settings','BrowseRoot','BrowseLogs') })
            $outside = @($headerButtons | Where-Object { -not $layout.Form.ClientRectangle.Contains($_.Bounds) })
            Assert-Gui ($outside.Count -eq 0) "Kopfbereich vollstaendig innerhalb des Fensters bei $([int]($scale * 100)) Prozent"
        }
        finally { $layout.Timer.Dispose(); $layout.Form.Dispose() }
    }
    $settingsDialog = New-BupSettingsDialog $gui
    try {
        Assert-Gui ($settingsDialog.BackColor.R -lt 50 -and $settingsDialog.Tag.Values.RetentionDays.BackColor.R -lt 50) 'Darkmode auch im Aufbewahrungsdialog'
        Assert-Gui ($settingsDialog.Tag.Values.RetentionDays.Value -eq 7 -and $settingsDialog.Tag.Values.LogDays.Value -eq 30) 'Einstellungsdialog mit sicheren Standardfristen'
        $settingsDialog.Tag.Values.RetentionDays.Value = 14
        $settingsDialog.Tag.Values.RetentionMonths.Value = 24
        $settingsDialog.Tag.Values.RetentionYears.Value = 8
        $settingsDialog.Tag.Values.LogDays.Value = 10
        Save-BupRetentionDialog $settingsDialog
        $retentionSaved = Read-BupGuiSettings $gui.SettingsPath
        Assert-Gui ($settingsDialog.DialogResult -eq 'OK' -and $retentionSaved.RetentionDays -eq 14 -and $retentionSaved.RetentionMonths -eq 24 -and $retentionSaved.RetentionYears -eq 8 -and $retentionSaved.LogDays -eq 10) 'Aufbewahrungsdialog speichert auch vor Auswahl des Sicherungsziels'
        Assert-Gui ($gui.Controls.RetentionLabel.Text.Contains('14 Tage') -and $gui.Retention.LogDays -eq 10) 'Aufbewahrung in der Oberflaeche aktualisiert'
    }
    finally { $settingsDialog.Dispose() }
    $cancelDialog = New-BupSettingsDialog $gui
    $cancelDialog.Tag.Values.RetentionDays.Value = 99
    $cancelDialog.Dispose()
    Assert-Gui ($gui.Retention.RetentionDays -eq 14 -and (Read-BupGuiSettings $gui.SettingsPath).RetentionDays -eq 14) 'Abbrechen veraendert keine Einstellungen'
    $legacyPath = Join-Path $testRoot 'legacy-settings.json'
    @{ BackupRoot = ''; LogRoot = (Join-Path $testRoot 'legacy-logs'); DelayMinutes = 2; DailyAt = '' } | ConvertTo-Json | Set-Content -LiteralPath $legacyPath -Encoding UTF8
    $legacy = Read-BupGuiSettings $legacyPath
    Assert-Gui ($legacy.RetentionDays -eq 7 -and $legacy.RetentionMonths -eq 12 -and $legacy.RetentionYears -eq 5 -and $legacy.LogDays -eq 30) 'Bisherige GUI-Einstellungen ohne Aufbewahrungsfelder kompatibel'
    $reopened = New-BupGuiWindow $gui.SettingsPath
    try { Assert-Gui ($reopened.Retention.RetentionDays -eq 14 -and $reopened.Retention.RetentionMonths -eq 24 -and $reopened.Retention.RetentionYears -eq 8 -and $reopened.Retention.LogDays -eq 10) 'Gespeicherte Aufbewahrung nach erneutem GUI-Start geladen' }
    finally { $reopened.Timer.Dispose(); $reopened.Form.Dispose() }
    $source = Join-Path $testRoot 'source'
    $target = Join-Path $testRoot "backup [x] O'Brien"
    $logs = Join-Path $testRoot 'logs'
    foreach ($path in @($source, $target)) { $null = New-Item -ItemType Directory -Path $path }
    [IO.File]::WriteAllText((Join-Path $source 'test.txt'), 'gui-backup-data')
    $gui.Controls.Root.Text = $target
    $gui.Controls.Logs.Text = $logs
    $gui.Controls.Delay.Value = 5
    $gui.Controls.Daily.Checked = $true
    $gui.Controls.Time.Text = '19:30'
    $gui.Controls.Time.Text = '29:99'
    $invalidTimeRejected = $false
    try { $null = Get-BupGuiRequest $gui } catch { $invalidTimeRejected = $true }
    Assert-Gui $invalidTimeRejected 'Ungueltige Zeit im dunklen Uhrzeitfeld abgewiesen'
    $gui.Controls.Time.Text = '19:30'
    Invoke-BupGuiClick $gui Save
    $saved = Read-BupGuiSettings $gui.SettingsPath
    Assert-Gui ($saved.BackupRoot -eq $target -and $saved.DelayMinutes -eq 5 -and $saved.DailyAt -eq '19:30') 'GUI-Konfiguration speichern und laden'
    Invoke-BupGuiClick $gui Save
    Assert-Gui (-not $gui.LastError) "Bestehende Konfiguration atomar aktualisiert: $($gui.LastError)"
    $data = Get-BupGuiRequest $gui
    [xml]$xml = & (Join-Path $PSScriptRoot 'Install-BackupTask.ps1') @data -PassThruXml
    Assert-Gui ($xml.Task.Triggers.LogonTrigger.Delay -eq 'PT5M' -and $xml.Task.Triggers.CalendarTrigger.StartBoundary.EndsWith('T19:30:00')) 'GUI-Plan mit Anmeldung und taeglicher Uhrzeit'
    $taskCommand = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($xml.Task.Actions.Exec.Arguments -split ' ')[-1]))
    Assert-Gui ($taskCommand.Contains('-RetentionDays 14 -RetentionMonths 24 -RetentionYears 8 -LogDays 10') -and -not $taskCommand.Contains('ForceSnapshot')) 'Geplante Backups erhalten Aufbewahrung, jedoch keine manuelle Mehrfachausfuehrung'
    $scheduler = New-Object -ComObject Schedule.Service
    $scheduler.Connect()
    $null = $scheduler.GetFolder('\').RegisterTask('UserProfileBackup-GUI-ValidateOnly', $xml.OuterXml, 1, $null, $null, 3, $null)
    Assert-Gui $true 'Erweiterte Aufgaben-XML von Windows validiert, keine Aufgabe angelegt'
    $data.SourceFolders = @{ Documents = $source }
    Start-BupGuiWork $gui Backup $data
    Assert-Gui ($null -ne $gui.Worker -and @($gui.Buttons | Where-Object Enabled).Count -eq 0) 'Backup asynchron gestartet, parallele GUI-Aktionen gesperrt'
    $secondRejected = $false
    try { Start-BupGuiWork $gui Backup $data } catch { $secondRejected = $true }
    Assert-Gui $secondRejected 'Zweiter gleichzeitiger Vorgang abgewiesen'
    Wait-GuiWork $gui
    Assert-Gui (-not $gui.LastError -and $gui.Controls.Output.Text.Contains('Complete')) 'Backup im GUI-Hintergrund erfolgreich'
    Assert-Gui (@($gui.Buttons | Where-Object { -not $_.Enabled }).Count -eq 0) 'Bedienung nach Abschluss wieder freigegeben'
    Invoke-BupGuiClick $gui Snapshots
    Wait-GuiWork $gui
    Assert-Gui (-not $gui.LastError -and $gui.Controls.Snapshots.Items.Count -eq 3) 'Gueltige Tages-, Monats- und Jahresstaende geladen'
    $firstGuiSnapshot = [string]$gui.Controls.Snapshots.Items[0].Path
    [IO.File]::WriteAllText((Join-Path $source 'test.txt'), 'gui-backup-updated')
    Start-BupGuiWork $gui Backup $data
    Wait-GuiWork $gui
    Invoke-BupGuiClick $gui Snapshots
    Wait-GuiWork $gui
    Assert-Gui (-not $gui.LastError -and $gui.Controls.Snapshots.Items.Count -eq 4 -and [IO.File]::ReadAllText((Join-Path $firstGuiSnapshot 'Documents\test.txt')) -eq 'gui-backup-data') 'Zweiter GUI-Backupstart am selben Tag erstellt neuen Stand und behaelt alten Inhalt'
    [IO.File]::WriteAllText((Join-Path $source 'test.txt'), 'gui-backup-data')
    Start-BupGuiWork $gui Backup $data
    Wait-GuiWork $gui
    Invoke-BupGuiClick $gui Snapshots
    Wait-GuiWork $gui
    Assert-Gui ($gui.Controls.Snapshots.Items.Count -eq 5) 'Dritter GUI-Backupstart am selben Tag ebenfalls erfolgreich'
    $snapshot = [string]$gui.Controls.Snapshots.Items[0].Path
    $gui.Controls.Snapshot.Text = $snapshot
    $destination = Join-Path $testRoot 'restored'
    $gui.Controls.Destination.Text = $destination
    Invoke-BupGuiClick $gui Restore
    Wait-GuiWork $gui
    Assert-Gui (-not $gui.LastError -and [IO.File]::ReadAllText((Join-Path $destination 'Documents\test.txt')) -eq 'gui-backup-data') 'Wiederherstellung aus GUI erfolgreich'
    [IO.File]::WriteAllText((Join-Path $destination 'Documents\test.txt'), 'preserve-existing')
    Invoke-BupGuiClick $gui Restore
    Wait-GuiWork $gui
    Assert-Gui (-not $gui.LastError -and [IO.File]::ReadAllText((Join-Path $destination 'Documents\test.txt')) -eq 'preserve-existing') 'GUI-Restore ueberschreibt keine vorhandenen Dateien'
    $gui.Controls.Destination.Text = ''
    Invoke-BupGuiClick $gui Restore
    Assert-Gui ($gui.LastError -and $null -eq $gui.Worker) 'Ungueltige Restore-Eingabe vor Start abgefangen'
    Start-BupGuiWork $gui Backup @{ BackupRoot = (Join-Path $testRoot 'missing'); LogRoot = $logs; SourceFolders = @{ Documents = $source } }
    Wait-GuiWork $gui
    Assert-Gui ($gui.LastError -and $gui.Controls.Status.Text.Contains('fehlgeschlagen')) "Hintergrundfehler sichtbar gemeldet, GUI weiter bedienbar: $($gui.LastError) / $($gui.Controls.Status.Text)"
    $gui.Controls.Root.Text = ''
    Invoke-BupGuiClick $gui Save
    Assert-Gui ($gui.LastError -and (Read-BupGuiSettings $gui.SettingsPath).BackupRoot -eq $target) 'Ungueltige Konfiguration ersetzt keine gueltigen Einstellungen'
    if ($PreviewPath) {
        # Offscreen anzeigen und automatisch schliessen: native Controls korrekt rendern,
        # ohne sichtbares Testfenster oder manuellen Eingriff.
        $gui.Form.StartPosition = 'Manual'
        $gui.Form.Location = New-Object Drawing.Point(-32000, -32000)
        $gui.Form.ShowInTaskbar = $false
        $gui.Form.Show()
        [Windows.Forms.Application]::DoEvents()
        Start-BupGuiWork $gui Backup $data
        $gui.Form.Close()
        Assert-Gui (-not $gui.Form.IsDisposed -and $gui.Controls.Status.Text.Contains('laeuft noch')) 'Schliessen waehrend laufender Sicherung verhindert'
        $timerDeadline = (Get-Date).AddSeconds(20)
        while ($null -ne $gui.Worker) {
            [Windows.Forms.Application]::DoEvents()
            if ((Get-Date) -gt $timerDeadline) { throw 'GUI-Timer hat den Hintergrundvorgang nicht abgeschlossen.' }
            Start-Sleep -Milliseconds 25
        }
        Assert-Gui (-not $gui.LastError) 'Nativer GUI-Timer uebernimmt Ergebnis ohne manuelles Polling'
        $gui.Controls.Root.Text = $target
        $saveButton = @($gui.Buttons | Where-Object Tag -eq 'Save')[0]
        $saveButton.PerformClick()
        Assert-Gui ($gui.Controls.Status.Text.StartsWith('Einstellungen gespeichert')) 'Echter Button-Click erreicht GUI-Ereignisbehandlung'
        $gui.Controls.Root.Text = 'E:\ProfilBackups'
        $gui.Controls.Logs.Text = '%LOCALAPPDATA%\UserProfileBackup\Logs'
        $gui.Controls.Output.Text = 'Bereit. Waehlen Sie ein Sicherungsziel und installieren Sie die Aufgabe.'
        $gui.Controls.Status.Text = 'Bereit.'
        $gui.Form.CreateControl()
        $gui.Form.PerformLayout()
        foreach ($tab in $gui.Controls.Tabs.TabPages) {
            $index = $gui.Controls.Tabs.TabPages.IndexOf($tab)
            $gui.Navigation[$index].PerformClick()
            [Windows.Forms.Application]::DoEvents()
            Assert-Gui ($gui.Controls.Tabs.SelectedTab -eq $tab -and $gui.Navigation[$index].BackColor.B -eq 96) "Dunkle Navigation fuer $($tab.Text) bedienbar und markiert"
            $bitmap = New-Object Drawing.Bitmap($gui.Form.Width, $gui.Form.Height)
            $imagePath = $PreviewPath
            if ($tab.Text -ne 'Install') { $imagePath = Join-Path (Split-Path -Parent $PreviewPath) (([IO.Path]::GetFileNameWithoutExtension($PreviewPath)) + '-' + $tab.Text + '.png') }
            try { $gui.Form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $gui.Form.Width, $gui.Form.Height))); $bitmap.Save($imagePath, [Drawing.Imaging.ImageFormat]::Png) }
            finally { $bitmap.Dispose() }
        }
        $gui.Controls.Root.Text = $target
        $gui.Controls.Logs.Text = $logs
        $settingsPreview = New-BupSettingsDialog $gui
        try {
            $settingsPreview.StartPosition = 'Manual'
            $settingsPreview.Location = New-Object Drawing.Point(-32000, -32000)
            $settingsPreview.Show()
            [Windows.Forms.Application]::DoEvents()
            $settingsPreview.Tag.Values.RetentionDays.Value = 21
            $settingsPreview.Tag.SaveButton.PerformClick()
            Assert-Gui ($gui.Retention.RetentionDays -eq 21 -and (Read-BupGuiSettings $gui.SettingsPath).RetentionDays -eq 21) 'Echter Speichern-Button im Einstellungsdialog uebernimmt die Aufbewahrung'
            $bitmap = New-Object Drawing.Bitmap($settingsPreview.Width, $settingsPreview.Height)
            $settingsImagePath = Join-Path (Split-Path -Parent $PreviewPath) (([IO.Path]::GetFileNameWithoutExtension($PreviewPath)) + '-Settings.png')
            try { $settingsPreview.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $settingsPreview.Width, $settingsPreview.Height))); $bitmap.Save($settingsImagePath, [Drawing.Imaging.ImageFormat]::Png) }
            finally { $bitmap.Dispose() }
        }
        finally { $settingsPreview.Dispose() }
        $updatePreview = New-BupUpdateDialog $gui
        try {
            $updatePreview.StartPosition = 'Manual'
            $updatePreview.Location = New-Object Drawing.Point(-32000,-32000)
            $updatePreview.Show()
            [Windows.Forms.Application]::DoEvents()
            $updatePreview.Tag.Repository.Text = 'https://github.com/2xlc-cloud'
            $updatePreview.Tag.CheckButton.PerformClick()
            Assert-Gui ($updatePreview.DialogResult -ne 'OK' -and $updatePreview.Tag.ErrorLabel.Text.Length -gt 0) 'GitHub-Profil allein wird im Updatedialog nicht als Repository gespeichert'
            $updatePreview.Tag.Repository.Text = 'https://github.com/2xlc-cloud/UserProfileBackup'
            $updatePreview.Tag.CheckButton.PerformClick()
            $savedSource = Get-Content -LiteralPath (Get-BupUpdateSourcePath $gui.SettingsPath) -Raw | ConvertFrom-Json
            Assert-Gui ($updatePreview.DialogResult -eq 'OK' -and $savedSource.RepositoryUrl -eq 'https://github.com/2xlc-cloud/UserProfileBackup' -and $savedSource.Ref -eq 'main') 'Updatequelle gespeichert, ohne einen Download oder eine Installation zu starten'
            $bitmap = New-Object Drawing.Bitmap($updatePreview.Width,$updatePreview.Height)
            try {
                $updatePreview.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$updatePreview.Width,$updatePreview.Height)))
                $bitmap.Save((Join-Path (Split-Path -Parent $PreviewPath) (([IO.Path]::GetFileNameWithoutExtension($PreviewPath)) + '-Update.png')), [Drawing.Imaging.ImageFormat]::Png)
            }
            finally { $bitmap.Dispose() }
        }
        finally { $updatePreview.Dispose() }
        $gui.Form.Hide()
    }
    Write-Output "ERFOLGREICH: $script:guiChecks GUI-Pruefungen mit PowerShell $($PSVersionTable.PSVersion)."
}
finally {
    if ($null -ne $gui) { $gui.Timer.Stop(); if ($null -ne $gui.Worker) { $gui.Worker.PowerShell.Stop(); $gui.Worker.PowerShell.Dispose() }; $gui.Timer.Dispose(); $gui.Form.Dispose() }
    # Nur der selbst erzeugte, gepruefte Testordner wird durch den bestehenden Helper entfernt.
    . (Join-Path $PSScriptRoot 'Backup-UserProfile.ps1')
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not (Test-BupChild $resolved ([IO.Path]::GetTempPath())) -or (Split-Path -Leaf $resolved) -notmatch '^UserProfileBackup-GUI-Test-[a-f0-9]{32}$') { throw 'Unsicherer GUI-Testpfad.' }
    Remove-BupTree $resolved
}
