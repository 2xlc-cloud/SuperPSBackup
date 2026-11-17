#requires -Version 5.1
# Prueft den Dialog "Aufgaben einrichten" (Backup- und Update-Aufgabe) und die Aufgabenerstellung.
# Echte Aufgaben werden nur unter eindeutigen Testnamen angelegt und am Ende entfernt;
# die Aufgaben des Benutzers bleiben unberuehrt. -Online fuehrt zusaetzlich die Update-Aufgabe gegen GitHub aus.
[CmdletBinding()]
param([switch]$Online)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Start-BackupGUI.ps1')
$installer = Join-Path $PSScriptRoot 'Install-BackupTask.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('SuperPSBackup-TaskDialog-Test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$testNames = @{ Backup = "SuperPSBackupTest-B-$suffix"; Update = "SuperPSBackupTest-U-$suffix" }
$script:checks = 0
function Assert-Task([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "TASKDIALOG-TEST FEHLGESCHLAGEN: $Message" }
    $script:checks++
    Write-Output "OK $script:checks - $Message"
}
function Assert-Rejected([scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { $null = & $Action } catch { $rejected = $true }
    Assert-Task $rejected $Message
}
function Wait-GuiWork($Window) {
    $deadline = (Get-Date).AddSeconds(60)
    while ($null -ne $Window.Worker) {
        [Windows.Forms.Application]::DoEvents()
        Complete-BupGuiWork $Window
        if ((Get-Date) -gt $deadline) { throw 'Zeitlimit fuer Hintergrundvorgang erreicht.' }
        Start-Sleep -Milliseconds 25
    }
}
function Get-TestTask([string]$Kind) { Get-ScheduledTask -TaskName $testNames[$Kind] -ErrorAction SilentlyContinue }
function Get-TaskCommand($Task) {
    $arguments = [string]$Task.Actions[0].Arguments
    [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($arguments -split ' ')[-1]))
}
function Get-XmlCommand($Xml) { [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($Xml.Task.Actions.Exec.Arguments -split ' ')[-1])) }
function Show-OffScreen($Dialog) {
    $Dialog.StartPosition = 'Manual'; $Dialog.Location = New-Object Drawing.Point(-32000, -32000)
    $Dialog.Show(); [Windows.Forms.Application]::DoEvents()
}
function Remove-TestTasks {
    foreach ($name in $testNames.Values) {
        if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $name -Confirm:$false }
    }
}
$gui = $null; $testPassed = $false
try {
    $target = Join-Path $testRoot 'target'; $logs = Join-Path $testRoot "O'Brien Logs"
    foreach ($path in @($target, $logs)) { $null = New-Item -ItemType Directory -Path $path }

    # ---------- Aufgaben-XML (Update-Aufgabe)
    [xml]$xml = & $installer -UpdateTask -LogRoot $logs -DailyAt '07:15' -PassThruXml
    $command = Get-XmlCommand $xml
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($command, [ref]$tokens, [ref]$errors)
    Assert-Task ($xml.Task.Triggers.LogonTrigger.Delay -eq 'PT10M' -and $xml.Task.Triggers.CalendarTrigger.StartBoundary.EndsWith('T07:15:00')) 'Update-Aufgabe: Standard 10 Minuten nach Anmeldung plus taegliche Uhrzeit'
    Assert-Task ($errors.Count -eq 0 -and $command.Contains("O''Brien") -and $command.Contains('-CheckOnly') -and $command.Contains('update-task.log') -and $command.Contains('Update-UserProfileBackup.ps1') -and -not $command.Contains('Backup-UserProfile.ps1')) 'Update-Aufgabe: Standardmodus nur pruefen, sichere Pfade, eigenes Protokoll'
    Assert-Task ($xml.Task.RegistrationInfo.Description -match 'Update' -and $xml.Task.Settings.Hidden -eq 'true' -and $xml.Task.Principals.Principal.RunLevel -eq 'LeastPrivilege') 'Update-Aufgabe: versteckt, ohne erhoehte Rechte, eigene Beschreibung'
    [xml]$installXml = & $installer -UpdateTask -UpdateMode Install -DelayMinutes 3 -LogRoot $logs -PassThruXml
    $installCommand = Get-XmlCommand $installXml
    Assert-Task (-not $installCommand.Contains('-CheckOnly') -and $installXml.Task.Triggers.LogonTrigger.Delay -eq 'PT3M' -and -not $installXml.Task.Triggers.CalendarTrigger) 'Update-Aufgabe: Modus Install ohne -CheckOnly, eigene Verzoegerung, ohne Tagestrigger'
    $scheduler = New-Object -ComObject Schedule.Service
    $scheduler.Connect()
    foreach ($candidate in @($xml, $installXml)) { $null = $scheduler.GetFolder('\').RegisterTask('SuperPSBackup-TaskDialog-ValidateOnly', $candidate.OuterXml, 1, $null, $null, 3, $null) }
    Assert-Task $true 'Update-Aufgaben-XML von Windows validiert, keine Aufgabe angelegt'
    Assert-Rejected { & $installer -UpdateTask -UpdateRepositoryUrl 'https://evil.example/x/y' -PassThruXml } 'Fremde Updatequelle (kein GitHub) abgewiesen'
    Assert-Rejected { & $installer -UpdateTask -UpdateRepositoryUrl 'https://github.com/../x' -PassThruXml } 'Repository mit Pfadsprung abgewiesen'
    Assert-Rejected { & $installer -UpdateTask -UpdateRef 'a b;c' -PassThruXml } 'Branch mit Sonderzeichen abgewiesen'
    Assert-Rejected { & $installer -UpdateTask -LogRoot 'relativ\pfad' -PassThruXml } 'Relativer Protokollpfad abgewiesen'
    Assert-Rejected { & $installer -UpdateTask -BackupRoot $target -PassThruXml } 'Backup- und Update-Modus schliessen sich aus'
    [xml]$backupXml = & $installer -BackupRoot $target -LogRoot $logs -PassThruXml
    Assert-Task ($backupXml.Task.Triggers.LogonTrigger.Delay -eq 'PT2M' -and (Get-XmlCommand $backupXml).Contains('Backup-UserProfile.ps1') -and $backupXml.Task.RegistrationInfo.Description -match 'Sicherung') 'Backup-Aufgabe unveraendert: 2 Minuten, Backup-Skript'
    Assert-Rejected { & $installer -BackupRoot (Join-Path $testRoot 'gibt-es-nicht') -PassThruXml } 'Backup-Aufgabe ohne vorhandenes Ziel weiterhin abgewiesen'

    # ---------- Echte Registrierung im Aufgabenplaner (Testnamen)
    $message = & $installer -UpdateTask -UpdateMode CheckOnly -DelayMinutes 4 -DailyAt '06:30' -LogRoot $logs -TaskName $testNames.Update
    $task = Get-TestTask Update
    Assert-Task ($null -ne $task -and $message -match 'Update-Aufgabe' -and $task.Triggers.Count -eq 2 -and $task.Settings.Hidden -and [string]$task.Principal.RunLevel -eq 'Limited') 'Update-Aufgabe im Windows-Aufgabenplaner angelegt'
    $null = & $installer -UpdateTask -UpdateMode Install -DelayMinutes 5 -LogRoot $logs -TaskName $testNames.Update
    $task = Get-TestTask Update
    Assert-Task (@(Get-ScheduledTask -TaskName $testNames.Update).Count -eq 1 -and $task.Triggers.Count -eq 1 -and -not (Get-TaskCommand $task).Contains('-CheckOnly')) 'Erneutes Einrichten aktualisiert dieselbe Aufgabe statt eine zweite anzulegen'
    Unregister-ScheduledTask -TaskName $testNames.Update -Confirm:$false
    Assert-Task ($null -eq (Get-TestTask Update)) 'Update-Aufgabe entfernbar'

    # ---------- GUI-Dialog
    [Windows.Forms.Application]::EnableVisualStyles()
    $gui = New-BupGuiWindow (Join-Path $testRoot 'config.json')
    $null = $gui.Form.Handle
    $gui.TaskNames = $testNames
    $gui.Controls.Root.Text = $target; $gui.Controls.Logs.Text = $logs
    $taskPage = $gui.Controls.Tabs.TabPages | Where-Object Text -eq 'Taskplanung'
    $taskButton = @($gui.Buttons | Where-Object Tag -eq 'Tasks')[0]
    Assert-Task ($null -ne $taskButton -and $taskButton.Parent -eq $taskPage -and $taskButton.Bounds.Bottom -le $gui.Controls.Tabs.Parent.ClientSize.Height -and $taskButton.Bounds.Right -le $gui.Controls.Tabs.Parent.ClientSize.Width -and $taskButton.Text -match 'Aufgaben einrichten') 'Button "Aufgaben einrichten ..." auf der Seite Taskplanung vorhanden und sichtbar platziert'
    $realTaskNames = Get-BupTaskNames
    Assert-Task ($realTaskNames.Backup -like 'SuperPSBackup-S-*' -and $realTaskNames.Update -like 'SuperPSBackupUpdate-S-*') 'Standardnamen der beiden Aufgaben sind benutzerbezogen'

    $dialog = New-BupTaskDialog $gui
    try {
        $s = $dialog.Tag
        Assert-Task ($dialog.BackColor.R -lt 50 -and $s.BackupEnabled.Checked -and -not $s.UpdateEnabled.Checked -and $s.BackupState.Text -match 'nicht eingerichtet' -and $s.UpdateState.Text -match 'nicht eingerichtet') 'Dialog dunkel; ohne vorhandene Aufgaben ist nur die Backup-Aufgabe vorausgewaehlt'
        Assert-Task ($s.UpdateMode.SelectedIndex -eq 0 -and $s.UpdateDelay.Value -eq 10 -and -not $s.UpdateDaily.Checked -and $s.UpdateUrl.Text -eq 'https://github.com/2xlc-cloud/SuperPSBackup' -and $s.UpdateBranch.Text -eq 'main') 'Update-Standardwerte: nur pruefen, 10 Minuten, offizielle Quelle, main'
        Assert-Task (-not $s.UpdateUrl.Enabled -and -not $s.UpdateMode.Enabled -and $s.BackupDelay.Enabled -and -not $s.BackupTime.Enabled) 'Eingabefelder folgen den Haken'
        $s.UpdateEnabled.Checked = $true; $s.BackupDaily.Checked = $true
        Assert-Task ($s.UpdateUrl.Enabled -and $s.UpdateMode.Enabled -and $s.UpdateDelay.Enabled -and -not $s.UpdateTime.Enabled -and $s.BackupTime.Enabled) 'Haken aktiviert Felder und Uhrzeitfelder'
        Show-OffScreen $dialog
        $s.UpdateUrl.Text = 'https://github.com/2xlc-cloud'; $s.OkButton.PerformClick()
        Assert-Task ($dialog.DialogResult -ne 'OK' -and $s.ErrorLabel.Text.Length -gt 0) 'Dialog weist GitHub-Profil ohne Repository ab'
        $s.UpdateUrl.Text = 'https://github.com/2xlc-cloud/SuperPSBackup'; $s.UpdateBranch.Text = 'a b'; $s.ErrorLabel.Text = ''; $s.OkButton.PerformClick()
        Assert-Task ($dialog.DialogResult -ne 'OK' -and $s.ErrorLabel.Text.Length -gt 0) 'Dialog weist ungueltigen Branch ab'
        $s.UpdateBranch.Text = 'main'; $s.UpdateDaily.Checked = $true; $s.UpdateTime.Text = '29:99'; $s.ErrorLabel.Text = ''; $s.OkButton.PerformClick()
        Assert-Task ($dialog.DialogResult -ne 'OK' -and $s.ErrorLabel.Text.Length -gt 0) 'Dialog weist ungueltige Update-Uhrzeit ab'
        $s.UpdateTime.Text = '04:45'; $gui.Controls.Root.Text = (Join-Path $testRoot 'fehlt'); $s.ErrorLabel.Text = ''; $s.OkButton.PerformClick()
        Assert-Task ($dialog.DialogResult -ne 'OK' -and $s.ErrorLabel.Text.Length -gt 0 -and -not (Test-Path -LiteralPath (Get-BupUpdateTaskSettingsPath $gui.SettingsPath))) 'Fehlendes Sicherungsziel verhindert Uebernehmen; nichts wurde gespeichert'
        $gui.Controls.Root.Text = $target
        $s.BackupDelay.Value = 7; $s.BackupTime.Text = '20:15'
        $s.UpdateMode.SelectedIndex = 1; $s.UpdateDelay.Value = 12; $s.ErrorLabel.Text = ''
        $s.OkButton.PerformClick()
        $plan = $s.Result
        Assert-Task ($dialog.DialogResult -eq 'OK' -and $plan.Backup.Enabled -and $plan.Backup.Arguments.DelayMinutes -eq 7 -and $plan.Backup.Arguments.DailyAt -eq '20:15' -and $plan.Backup.Arguments.BackupRoot -eq $target) 'Uebernehmen liefert den Backup-Plan'
        Assert-Task ($plan.Update.Enabled -and $plan.Update.Arguments.UpdateTask -and $plan.Update.Arguments.UpdateMode -eq 'Install' -and $plan.Update.Arguments.DelayMinutes -eq 12 -and $plan.Update.Arguments.DailyAt -eq '04:45' -and $plan.Update.Arguments.LogRoot -eq $logs -and $plan.Update.Arguments.UpdateRef -eq 'main') 'Uebernehmen liefert den Update-Plan'
        Assert-Task ($gui.Controls.Delay.Value -eq 7 -and $gui.Controls.Daily.Checked -and $gui.Controls.Time.Text -eq '20:15') 'Backup-Werte werden in die Taskplanung-Seite uebernommen'
        $saved = Read-BupGuiSettings $gui.SettingsPath
        $savedUpdate = Read-BupUpdateTaskSettings $gui.SettingsPath
        $savedSource = Get-Content -LiteralPath (Get-BupUpdateSourcePath $gui.SettingsPath) -Raw | ConvertFrom-Json
        Assert-Task ($saved.DelayMinutes -eq 7 -and $saved.DailyAt -eq '20:15' -and $savedUpdate.Mode -eq 'Install' -and $savedUpdate.DelayMinutes -eq 12 -and $savedUpdate.DailyAt -eq '04:45' -and $savedSource.RepositoryUrl -eq 'https://github.com/2xlc-cloud/SuperPSBackup') 'Backup- und Update-Einstellungen gespeichert'
    }
    finally { $dialog.Dispose() }

    # ---------- Aufgaben ueber den Hintergrundvorgang anlegen
    Start-BupGuiWork $gui ApplyTasks $plan
    Wait-GuiWork $gui
    $backupTask = Get-TestTask Backup; $updateTask = Get-TestTask Update
    Assert-Task (-not $gui.LastError -and $null -ne $backupTask -and $null -ne $updateTask -and $gui.Controls.Output.Text -match 'Backup-Aufgabe eingerichtet' -and $gui.Controls.Output.Text -match 'Update-Aufgabe \(Modus Install\) eingerichtet') 'Beide Aufgaben werden im Hintergrund angelegt'
    $backupLogon = @($backupTask.Triggers | Where-Object { $_.CimClass.CimClassName -match 'Logon' })[0]
    $updateLogon = @($updateTask.Triggers | Where-Object { $_.CimClass.CimClassName -match 'Logon' })[0]
    Assert-Task ($backupLogon.Delay -eq 'PT7M' -and $updateLogon.Delay -eq 'PT12M' -and $backupTask.Triggers.Count -eq 2 -and $updateTask.Triggers.Count -eq 2 -and -not (Get-TaskCommand $updateTask).Contains('-CheckOnly') -and (Get-TaskCommand $backupTask).Contains('Backup-UserProfile.ps1')) 'Angelegte Aufgaben tragen die Dialogwerte (Verzoegerung, Tagestrigger, Modus)'

    $gui.Controls.Output.Clear()
    Start-BupGuiWork $gui TaskStatus @{}
    Wait-GuiWork $gui
    Assert-Task (-not $gui.LastError -and $gui.Controls.Output.Text.Contains($testNames.Backup) -and $gui.Controls.Output.Text.Contains($testNames.Update)) 'Status zeigt Backup- und Update-Aufgabe'
    Start-BupGuiWork $gui Disable @{}
    Wait-GuiWork $gui
    Assert-Task ([string](Get-TestTask Backup).State -eq 'Disabled' -and [string](Get-TestTask Update).State -eq 'Disabled') 'Deaktivieren betrifft Backup- und Update-Aufgabe'
    Start-BupGuiWork $gui Enable @{}
    Wait-GuiWork $gui
    Assert-Task ([string](Get-TestTask Backup).State -ne 'Disabled' -and [string](Get-TestTask Update).State -ne 'Disabled') 'Aktivieren betrifft Backup- und Update-Aufgabe'

    $reopened = New-BupTaskDialog $gui
    try {
        $r = $reopened.Tag
        Assert-Task ($r.BackupEnabled.Checked -and $r.UpdateEnabled.Checked -and $r.BackupState.Text -eq 'Aktuell: eingerichtet' -and $r.UpdateState.Text -eq 'Aktuell: eingerichtet' -and $r.UpdateMode.SelectedIndex -eq 1 -and $r.UpdateDelay.Value -eq 12 -and $r.UpdateDaily.Checked -and $r.UpdateTime.Text -eq '04:45' -and $r.BackupDelay.Value -eq 7) 'Erneutes Oeffnen zeigt vorhandene Aufgaben und gespeicherte Werte'
    }
    finally { $reopened.Dispose() }

    # ---------- Button-Pfad: Dialog -> Hintergrundvorgang (Dialog wird automatisch bedient)
    $script:realTaskDialog = ${function:New-BupTaskDialog}
    $script:dialogMode = 'Cancel'
    function New-BupTaskDialog($Window) {
        $d = & $script:realTaskDialog $Window
        $d.StartPosition = 'Manual'; $d.Location = New-Object Drawing.Point(-32000, -32000)
        $d.Add_Shown({
            switch ($script:dialogMode) {
                'Cancel' { $this.Tag.CancelButton.PerformClick() }
                'Status' { $this.Tag.StatusButton.PerformClick() }
                'RemoveUpdate' { $this.Tag.UpdateEnabled.Checked = $false; $this.Tag.OkButton.PerformClick() }
                'RemoveBoth' { $this.Tag.UpdateEnabled.Checked = $false; $this.Tag.BackupEnabled.Checked = $false; $this.Tag.OkButton.PerformClick() }
            }
        })
        return $d
    }
    try {
        $script:dialogMode = 'Cancel'
        Invoke-BupGuiClick $gui Tasks
        Assert-Task ($null -eq $gui.Worker -and $null -ne (Get-TestTask Backup) -and $null -ne (Get-TestTask Update)) 'Abbrechen im Dialog aendert nichts'
        $gui.Controls.Output.Clear(); $script:dialogMode = 'Status'
        Invoke-BupGuiClick $gui Tasks
        Wait-GuiWork $gui
        Assert-Task ($gui.Controls.Output.Text.Contains($testNames.Update) -and $gui.Controls.Output.Text.Contains($testNames.Backup)) 'Schaltflaeche "Status anzeigen" im Dialog startet die Statusabfrage'
        $script:dialogMode = 'RemoveUpdate'
        Invoke-BupGuiClick $gui Tasks
        Wait-GuiWork $gui
        Assert-Task (-not $gui.LastError -and $null -eq (Get-TestTask Update) -and $null -ne (Get-TestTask Backup) -and $gui.Controls.Output.Text -match 'Update-Aufgabe entfernt') 'Ohne Haken wird nur die Update-Aufgabe entfernt, Backup-Aufgabe bleibt'
        $script:dialogMode = 'RemoveBoth'
        Invoke-BupGuiClick $gui Tasks
        Wait-GuiWork $gui
        Assert-Task (-not $gui.LastError -and $null -eq (Get-TestTask Update) -and $null -eq (Get-TestTask Backup)) 'Ohne beide Haken werden beide Aufgaben entfernt'
        $gui.Controls.Output.Clear()
        Start-BupGuiWork $gui ApplyTasks @{ Backup = @{ Enabled = $false; Arguments = @{} }; Update = @{ Enabled = $false; Arguments = @{} } }
        Wait-GuiWork $gui
        Assert-Task (-not $gui.LastError -and $gui.Controls.Output.Text -match 'Backup-Aufgabe ist nicht eingerichtet' -and $gui.Controls.Output.Text -match 'Update-Aufgabe ist nicht eingerichtet') 'Entfernen nicht vorhandener Aufgaben ist fehlerfrei'
    }
    finally { Set-Item -LiteralPath Function:\New-BupTaskDialog -Value $script:realTaskDialog }
    # Bisheriger Knopf "Aufgabe entfernen" betrifft weiterhin nur die Backup-Aufgabe.
    Start-BupGuiWork $gui ApplyTasks $plan
    Wait-GuiWork $gui
    Start-BupGuiWork $gui RemoveTask @{}
    Wait-GuiWork $gui
    Assert-Task ($null -eq (Get-TestTask Backup) -and $null -ne (Get-TestTask Update)) '"Aufgabe entfernen" auf der Taskplanung-Seite entfernt nur die Backup-Aufgabe'
    Remove-TestTasks

    # ---------- Online: Update-Aufgabe gegen echtes GitHub
    if ($Online) {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $onlineLogs = Join-Path $testRoot 'online-logs'
        [xml]$onlineXml = & $installer -UpdateTask -UpdateMode CheckOnly -LogRoot $onlineLogs -PassThruXml
        $encoded = ($onlineXml.Task.Actions.Exec.Arguments -split ' ')[-1]
        & $ps -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $encoded
        $logFile = Join-Path $onlineLogs 'update-task.log'
        $logText = if (Test-Path -LiteralPath $logFile) { [IO.File]::ReadAllText($logFile) } else { '' }
        Assert-Task ($LASTEXITCODE -eq 0 -and $logText -match 'Version' -and $logText -match 'UpdateAvailable' -and $logText -notmatch 'FEHLER') 'Befehl der Update-Aufgabe prueft echtes GitHub und protokolliert das Ergebnis'

        [xml]$badXml = & $installer -UpdateTask -UpdateRepositoryUrl 'https://github.com/2xlc-cloud/gibt-es-sicher-nicht-xyz' -LogRoot $onlineLogs -PassThruXml
        & $ps -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand (($badXml.Task.Actions.Exec.Arguments -split ' ')[-1]) 2>$null
        Assert-Task ($LASTEXITCODE -eq 1 -and [IO.File]::ReadAllText($logFile) -match 'FEHLER') 'Fehlgeschlagene Pruefung wird protokolliert und mit Fehlercode beendet'

        # Hinweis: Variablennamen wie $InstallRoot gehoeren dem per Dot-Sourcing geladenen Updater und werden dort ueberschrieben.
        # Automatische Installation: echte Minimalinstallation auf aelteren Stand setzen, dann den Befehl der Update-Aufgabe ausfuehren.
        $autoRoot = Join-Path $testRoot "auto-install [x]"
        $null = New-Item -ItemType Directory -Path $autoRoot
        [IO.File]::Copy((Join-Path $PSScriptRoot 'FirstInstall.ps1'), (Join-Path $autoRoot 'FirstInstall.ps1'))
        $firstOutput = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $autoRoot 'FirstInstall.ps1') -NoStart -NoPause -SkipOptional 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw $firstOutput }
        . (Join-Path $PSScriptRoot 'Update-UserProfileBackup.ps1')
        $installedManifest = Test-BupUpdatePackage $autoRoot
        $currentVersion = [version]$installedManifest.Version
        $guiFile = Join-Path $autoRoot 'Start-BackupGUI.ps1'
        [IO.File]::AppendAllText($guiFile, "`r`n# older runtime fixture`r`n")
        $installedManifest.Version = '1.0.2'
        $guiEntry = @($installedManifest.Files | Where-Object Name -eq 'Start-BackupGUI.ps1')[0]
        $guiEntry.Length = (Get-Item -LiteralPath $guiFile).Length
        $guiEntry.SHA256 = (Get-BupFileSha256 $guiFile)
        $installedManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $autoRoot 'update-manifest.json') -Encoding UTF8
        $autoLogs = Join-Path $testRoot 'auto-logs'
        [xml]$autoXml = & (Join-Path $autoRoot 'Install-BackupTask.ps1') -UpdateTask -UpdateMode Install -LogRoot $autoLogs -PassThruXml
        & $ps -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand (($autoXml.Task.Actions.Exec.Arguments -split ' ')[-1])
        $autoExit = $LASTEXITCODE
        $autoLog = Join-Path $autoLogs 'update-task.log'
        $autoManifest = Test-BupUpdatePackage $autoRoot
        Write-Output ("Info: Exit=$autoExit Version=$($autoManifest.Version) (vorher $currentVersion) Typ=$($autoManifest.InstallationType) Dateien=$($autoManifest.Files.Count) Log=" + $(if (Test-Path -LiteralPath $autoLog) { ([IO.File]::ReadAllText($autoLog)).Trim() } else { 'kein Log' }))
        Assert-Task ($autoExit -eq 0 -and [version]$autoManifest.Version -ge $currentVersion -and $autoManifest.InstallationType -eq 'Runtime' -and $autoManifest.Files.Count -eq 5 -and (Test-Path -LiteralPath $autoLog) -and [IO.File]::ReadAllText($autoLog) -match 'Updated') 'Update-Aufgabe (automatisch installieren) aktualisiert eine aeltere Minimalinstallation und bleibt bei fuenf Runtime-Dateien'
        Assert-Task (-not ([IO.File]::ReadAllText($guiFile)).Contains('older runtime fixture')) 'Die aktualisierte Datei stammt wieder aus GitHub'
        $taskLogs = Join-Path $testRoot 'task-logs'
        $null = & $installer -UpdateTask -UpdateMode CheckOnly -LogRoot $taskLogs -TaskName $testNames.Update
        $before = (Get-ScheduledTaskInfo -TaskName $testNames.Update).LastRunTime
        Start-ScheduledTask -TaskName $testNames.Update
        $deadline = (Get-Date).AddSeconds(120)
        do {
            Start-Sleep -Seconds 2
            $info = Get-ScheduledTaskInfo -TaskName $testNames.Update
            $finished = ($info.LastRunTime -gt $before -or $before -lt (Get-Date '2000-01-01')) -and [string](Get-ScheduledTask -TaskName $testNames.Update).State -eq 'Ready' -and $info.LastRunTime -gt (Get-Date).AddMinutes(-5)
        } until ($finished -or (Get-Date) -gt $deadline)
        $taskLog = Join-Path $taskLogs 'update-task.log'
        Assert-Task ($finished -and $info.LastTaskResult -eq 0 -and (Test-Path -LiteralPath $taskLog) -and [IO.File]::ReadAllText($taskLog) -match 'Version') 'Update-Aufgabe laeuft im echten Windows-Aufgabenplaner und schreibt ihr Protokoll'
        Remove-TestTasks
    }
    Assert-Task ($null -eq (Get-TestTask Backup) -and $null -eq (Get-TestTask Update)) 'Keine Testaufgaben im Aufgabenplaner zurueckgeblieben'
    $testPassed = $true
    Write-Output "ERFOLGREICH: $script:checks Aufgaben-Pruefungen. Online=$Online"
}
finally {
    try { Remove-TestTasks } catch { Write-Warning "Testaufgaben konnten nicht entfernt werden: $_" }
    if ($null -ne $gui) { $gui.Timer.Stop(); if ($null -ne $gui.Worker) { $gui.Worker.PowerShell.Stop(); $gui.Worker.PowerShell.Dispose() }; $gui.Timer.Dispose(); $gui.Form.Dispose() }
    . (Join-Path $PSScriptRoot 'Backup-UserProfile.ps1')
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not (Test-BupChild $resolved ([IO.Path]::GetTempPath())) -or (Split-Path -Leaf $resolved) -notmatch '^SuperPSBackup-TaskDialog-Test-[a-f0-9]{32}$') { throw 'Unsicherer Testpfad.' }
    for ($try = 1; $try -le 5; $try++) { try { Remove-BupTree $resolved; break } catch { if ($try -eq 5) { Write-Warning "Testordner nicht entfernt: $resolved" } else { Start-Sleep -Seconds 2 } } }
}
