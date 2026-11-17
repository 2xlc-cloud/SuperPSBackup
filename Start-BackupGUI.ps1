#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path $env:LOCALAPPDATA 'UserProfileBackup\gui-settings.json'),
    [switch]$NoShow
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Set-BupDarkTheme([Windows.Forms.Control]$Root) {
    $background = [Drawing.Color]::FromArgb(18, 22, 30)
    $surface = [Drawing.Color]::FromArgb(26, 32, 43)
    $input = [Drawing.Color]::FromArgb(13, 17, 24)
    $text = [Drawing.Color]::FromArgb(231, 237, 246)
    $border = [Drawing.Color]::FromArgb(65, 79, 99)
    $Root.ForeColor = $text
    $Root.BackColor = $background
    if ($Root -is [Windows.Forms.TabPage]) { $Root.BackColor = $surface; $Root.UseVisualStyleBackColor = $false }
    elseif ($Root -is [Windows.Forms.Button]) {
        $Root.UseVisualStyleBackColor = $false
        $Root.FlatStyle = 'Flat'; $Root.BackColor = $surface
        $Root.FlatAppearance.BorderColor = $border
        $Root.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(43, 57, 76)
        $Root.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(48, 77, 112)
    }
    elseif ($Root -is [Windows.Forms.TextBoxBase]) { $Root.BackColor = $input; $Root.BorderStyle = 'FixedSingle' }
    elseif ($Root -is [Windows.Forms.ComboBox]) {
        $Root.BackColor = $input; $Root.FlatStyle = 'Flat'; $Root.DrawMode = 'OwnerDrawFixed'
        $Root.Add_DrawItem({
            param($sender, $eventArgs)
            if ($eventArgs.Index -lt 0) { return }
            $color = [Drawing.Color]::FromArgb(13, 17, 24)
            if ($eventArgs.State -band [Windows.Forms.DrawItemState]::Selected) { $color = [Drawing.Color]::FromArgb(43, 66, 96) }
            $brush = New-Object Drawing.SolidBrush($color)
            try { $eventArgs.Graphics.FillRectangle($brush, $eventArgs.Bounds) } finally { $brush.Dispose() }
            $label = $sender.GetItemText($sender.Items[$eventArgs.Index])
            [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics, $label, $eventArgs.Font, $eventArgs.Bounds, [Drawing.Color]::FromArgb(231,237,246), ([Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis))
            $eventArgs.DrawFocusRectangle()
        })
    }
    elseif ($Root -is [Windows.Forms.NumericUpDown]) { $Root.BackColor = $input; $Root.BorderStyle = 'FixedSingle' }
    elseif ($Root -is [Windows.Forms.Label] -or $Root -is [Windows.Forms.CheckBox]) { $Root.BackColor = $Root.Parent.BackColor }
    elseif ($Root -is [Windows.Forms.TabControl]) {
        $Root.DrawMode = 'OwnerDrawFixed'
        $Root.Add_DrawItem({
            param($sender, $eventArgs)
            $color = [Drawing.Color]::FromArgb(26,32,43)
            if ($sender.SelectedIndex -eq $eventArgs.Index) { $color = [Drawing.Color]::FromArgb(43,66,96) }
            $brush = New-Object Drawing.SolidBrush($color)
            try { $eventArgs.Graphics.FillRectangle($brush, $eventArgs.Bounds) } finally { $brush.Dispose() }
            [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics, $sender.TabPages[$eventArgs.Index].Text, $sender.Font, $eventArgs.Bounds, [Drawing.Color]::FromArgb(231,237,246), ([Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::VerticalCenter))
        })
    }
    foreach ($child in $Root.Controls) { Set-BupDarkTheme $child }
}

function Update-BupNavigation($Window) {
    foreach ($button in $Window.Navigation) {
        $button.BackColor = [Drawing.Color]::FromArgb(26,32,43)
        if ([int]$button.Tag -eq $Window.Controls.Tabs.SelectedIndex) { $button.BackColor = [Drawing.Color]::FromArgb(43,66,96) }
    }
}

function Get-BupUpdateSourcePath([string]$SettingsPath) {
    Join-Path (Split-Path -Parent $SettingsPath) 'update-source.json'
}

function New-BupUpdateDialog($Window) {
    $dialog = New-Object Windows.Forms.Form
    $dialog.SuspendLayout(); $dialog.Font = $Window.Form.Font
    $dialog.AutoScaleDimensions = New-Object Drawing.SizeF(96,96); $dialog.AutoScaleMode = 'Dpi'
    $dialog.Text = 'Programm aktualisieren'; $dialog.ClientSize = New-Object Drawing.Size(660,330)
    $dialog.FormBorderStyle = 'FixedDialog'; $dialog.MaximizeBox = $false; $dialog.MinimizeBox = $false
    $dialog.StartPosition = 'CenterParent'; $dialog.ShowInTaskbar = $false
    $intro = New-Object Windows.Forms.Label
    $intro.Text = 'Oeffentliches GitHub-Repository mit diesen Programmdateien und update-manifest.json. Die Quelle muss vertrauenswuerdig sein: Updates enthalten ausfuehrbaren Code.'
    $intro.SetBounds(20,18,620,62); $dialog.Controls.Add($intro)
    $label = New-Object Windows.Forms.Label
    $label.Text = 'Repository-URL'; $label.SetBounds(20,95,140,28); $dialog.Controls.Add($label)
    $url = New-Object Windows.Forms.TextBox
    $url.Text = 'https://github.com/2xlc-cloud/UserProfileBackup'
    $url.SetBounds(170,92,465,28); $dialog.Controls.Add($url)
    $label = New-Object Windows.Forms.Label
    $label.Text = 'Branch / Tag'; $label.SetBounds(20,140,140,28); $dialog.Controls.Add($label)
    $branch = New-Object Windows.Forms.TextBox
    $branch.Text = 'main'; $branch.SetBounds(170,137,465,28); $dialog.Controls.Add($branch)
    $errorLabel = New-Object Windows.Forms.Label
    $errorLabel.SetBounds(20,185,620,65); $dialog.Controls.Add($errorLabel)
    $check = New-Object Windows.Forms.Button
    $check.Text = 'Auf Updates pruefen'; $check.SetBounds(286,270,200,36); $dialog.Controls.Add($check)
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Abbrechen'; $cancel.SetBounds(498,270,138,36); $cancel.DialogResult = 'Cancel'; $dialog.Controls.Add($cancel)
    $dialog.Tag = @{ Window = $Window; Repository = $url; Branch = $branch; ErrorLabel = $errorLabel; CheckButton = $check }
    $check.Add_Click({
        $d = $this.FindForm(); $s = $d.Tag
        try {
            . (Join-Path $s.Window.Project 'Update-UserProfileBackup.ps1')
            $repository = Get-BupRepository $s.Repository.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($s.Branch.Text)) { throw 'Bitte einen Branch oder Tag angeben.' }
            $source = @{ RepositoryUrl = $repository.Url; Ref = $s.Branch.Text.Trim() }
            Save-BupGuiSettings (Get-BupUpdateSourcePath $s.Window.SettingsPath) $source
            $d.DialogResult = 'OK'
        }
        catch { $s.ErrorLabel.Text = [string]$_ }
    })
    $dialog.AcceptButton = $check; $dialog.CancelButton = $cancel
    try {
        $sourcePath = Get-BupUpdateSourcePath $Window.SettingsPath
        if (Test-Path -LiteralPath $sourcePath) {
            $source = Get-Content -LiteralPath $sourcePath -Raw | ConvertFrom-Json
            $url.Text = $source.RepositoryUrl; $branch.Text = $source.Ref
        }
    }
    catch { $errorLabel.Text = "Updatequelle konnte nicht geladen werden: $_" }
    Set-BupDarkTheme $dialog; $errorLabel.ForeColor = [Drawing.Color]::FromArgb(255,140,140)
    $dialog.ResumeLayout($true)
    return $dialog
}

function Get-BupUpdateLaunch($Window, $Info) {
    # Exakt den bereits geprueften Commit installieren; kein Branchwechsel zwischen Pruefung und Installation.
    $command = "& '" + (Join-Path $Window.Project 'Update-UserProfileBackup.ps1').Replace("'", "''") + "'"
    $command += " -RepositoryUrl '" + $Info.RepositoryUrl.Replace("'", "''") + "' -Ref '" + $Info.Ref.Replace("'", "''") + "' -ExpectedCommit '" + $Info.Commit + "'"
    $command += " -WaitForProcessId $PID -RestartGUI -ShowResult -GuiSettingsPath '" + $Window.SettingsPath.Replace("'", "''") + "'"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    [pscustomobject]@{ FilePath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'); Arguments = "-NoLogo -NoProfile -NonInteractive -STA -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $encoded" }
}

function Read-BupGuiSettings([string]$Path) {
    $settings = @{ BackupRoot = ''; LogRoot = (Join-Path $env:LOCALAPPDATA 'UserProfileBackup\Logs'); DelayMinutes = 2; DailyAt = ''; RetentionDays = 7; RetentionMonths = 12; RetentionYears = 5; LogDays = 30 }
    if (Test-Path -LiteralPath $Path) {
        $saved = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($name in @('BackupRoot', 'LogRoot', 'DelayMinutes', 'DailyAt', 'RetentionDays', 'RetentionMonths', 'RetentionYears', 'LogDays')) {
            if ($saved.PSObject.Properties[$name]) { $settings[$name] = $saved.$name }
        }
    }
    return $settings
}

function Save-BupGuiSettings([string]$Path, $Settings) {
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'Konfigurationspfad muss absolut sein.' }
    $parent = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop
    $temporary = Join-Path $parent ('.settings-' + [guid]::NewGuid().ToString('N'))
    try {
        $Settings | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8 -ErrorAction Stop
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
}

function Get-BupGuiRequest($Window, [switch]$AllowMissingTarget) {
    $c = $Window.Controls
    $root = $c.Root.Text.Trim()
    $logs = $c.Logs.Text.Trim()
    if (-not $AllowMissingTarget -and (-not [IO.Path]::IsPathRooted($root) -or -not (Test-Path -LiteralPath $root -PathType Container))) { throw 'Bitte ein vorhandenes, erreichbares absolutes Sicherungsziel angeben.' }
    if (-not [IO.Path]::IsPathRooted($logs)) { throw 'Bitte einen absoluten Protokollpfad angeben.' }
    $daily = ''
    if ($c.Daily.Checked) {
        $daily = $c.Time.Text
        $null = [datetime]::ParseExact($daily, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    }
    $request = @{ BackupRoot = $root; LogRoot = $logs; DelayMinutes = [int]$c.Delay.Value; DailyAt = $daily }
    foreach ($key in $Window.Retention.Keys) { $request[$key] = [int]$Window.Retention[$key] }
    return $request
}

function Update-BupGuiRetentionLabel($Window) {
    $r = $Window.Retention
    $Window.Controls.RetentionLabel.Text = "Aufbewahrung: $($r.RetentionDays) Tage / $($r.RetentionMonths) Monate / $($r.RetentionYears) Jahre. Protokolle: $($r.LogDays) Tage."
}

function Save-BupRetentionDialog($Dialog) {
    $state = $Dialog.Tag
    try {
        $data = Get-BupGuiRequest $state.Window -AllowMissingTarget
        foreach ($key in $state.Values.Keys) { $data[$key] = [int]$state.Values[$key].Value }
        Save-BupGuiSettings $state.Window.SettingsPath $data
        foreach ($key in $state.Values.Keys) { $state.Window.Retention[$key] = [int]$state.Values[$key].Value }
        Update-BupGuiRetentionLabel $state.Window
        $state.Window.Controls.Status.Text = 'Aufbewahrung gespeichert. Fuer geplante Backups bitte einmal Plan speichern anklicken.'
        $Dialog.DialogResult = 'OK'
    }
    catch { $state.ErrorLabel.Text = [string]$_ }
}

function New-BupSettingsDialog($Window) {
    $dialog = New-Object Windows.Forms.Form
    $dialog.SuspendLayout()
    $dialog.Font = $Window.Form.Font
    $dialog.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
    $dialog.AutoScaleMode = 'Dpi'
    $dialog.Text = 'Einstellungen - Aufbewahrung'
    $dialog.ClientSize = New-Object Drawing.Size(620, 420)
    $dialog.FormBorderStyle = 'FixedDialog'; $dialog.MaximizeBox = $false; $dialog.MinimizeBox = $false
    $dialog.StartPosition = 'CenterParent'; $dialog.ShowInTaskbar = $false
    $state = @{ Window = $Window; Values = @{}; ErrorLabel = $null; SaveButton = $null }
    $dialog.Tag = $state
    $intro = New-Object Windows.Forms.Label
    # ASCII-Zeichen halten das Skript auch ohne BOM mit Windows PowerShell lesbar.
    $intro.Text = 'Kalenderzeitraeume einschliesslich des aktuellen Tages, Monats oder Jahres.'
    $intro.SetBounds(20, 18, 580, 45); $dialog.Controls.Add($intro)
    $rows = @(
        @{ Key = 'RetentionDays'; Text = 'Tagesstaende (Kalendertage)'; Max = 36500 },
        @{ Key = 'RetentionMonths'; Text = 'Monatsstaende (Kalendermonate)'; Max = 1200 },
        @{ Key = 'RetentionYears'; Text = 'Jahresstaende (Kalenderjahre)'; Max = 100 },
        @{ Key = 'LogDays'; Text = 'Protokolle (Kalendertage)'; Max = 3650 }
    )
    $y = 74
    foreach ($row in $rows) {
        $label = New-Object Windows.Forms.Label
        $label.Text = $row.Text; $label.SetBounds(20, $y, 390, 28); $dialog.Controls.Add($label)
        $input = New-Object Windows.Forms.NumericUpDown
        $input.Minimum = 1; $input.Maximum = $row.Max; $input.Value = $Window.Retention[$row.Key]
        $input.SetBounds(450, $y - 2, 120, 30); $dialog.Controls.Add($input); $state.Values[$row.Key] = $input
        $y += 45
    }
    $note = New-Object Windows.Forms.Label
    $note.Text = 'Manuelle Staende eines Tages bleiben gemeinsam im Tagesfenster erhalten. Bereinigung erst nach erfolgreichem Backup. Fuer geplante Backups anschliessend Plan speichern.'
    $note.SetBounds(20, 260, 580, 60); $dialog.Controls.Add($note)
    $state.ErrorLabel = New-Object Windows.Forms.Label
    $state.ErrorLabel.ForeColor = [Drawing.Color]::Firebrick; $state.ErrorLabel.SetBounds(20, 320, 580, 40); $dialog.Controls.Add($state.ErrorLabel)
    $save = New-Object Windows.Forms.Button
    $save.Text = 'Speichern'; $save.SetBounds(316, 370, 130, 34)
    $save.Add_Click({ Save-BupRetentionDialog $this.FindForm() }); $dialog.Controls.Add($save); $state.SaveButton = $save
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Abbrechen'; $cancel.SetBounds(458, 370, 130, 34); $cancel.DialogResult = 'Cancel'; $dialog.Controls.Add($cancel)
    $dialog.AcceptButton = $save; $dialog.CancelButton = $cancel
    Set-BupDarkTheme $dialog
    $state.ErrorLabel.ForeColor = [Drawing.Color]::FromArgb(255, 140, 140)
    $dialog.ResumeLayout($true)
    return $dialog
}

function Start-BupGuiWork($Window, [string]$Action, [hashtable]$Data) {
    if ($null -ne $Window.Worker) { throw 'Ein Vorgang laeuft bereits.' }
    $job = [PowerShell]::Create()
    # Eigener Runspace: keine blockierenden Datei-/Netzwerkzugriffe im UI-Thread.
    $null = $job.AddScript({
        param($Project, $Action, $Data)
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $taskName = 'UserProfileBackup-' + $sid
        switch ($Action) {
            'UpdateCheck' {
                & (Join-Path $Project 'Update-UserProfileBackup.ps1') -RepositoryUrl $Data.RepositoryUrl -Ref $Data.Ref -InstallRoot $Project -CheckOnly
            }
            'Backup' {
                . (Join-Path $Project 'Backup-UserProfile.ps1')
                $arguments = @{ BackupRoot = $Data.BackupRoot; LogRoot = $Data.LogRoot; ForceSnapshot = $true }
                foreach ($key in @('RetentionDays', 'RetentionMonths', 'RetentionYears', 'LogDays')) { if ($Data.ContainsKey($key)) { $arguments[$key] = $Data[$key] } }
                if ($Data.ContainsKey('SourceFolders')) { $arguments.SourceFolders = $Data.SourceFolders }
                $result = Invoke-UserProfileBackup @arguments
                if ($result.Status -eq 'Failed') { throw "Sicherung fehlgeschlagen. Details: $($Data.LogRoot)" }
                $result
            }
            'Install' {
                $arguments = @{ BackupRoot = $Data.BackupRoot; LogRoot = $Data.LogRoot; DelayMinutes = $Data.DelayMinutes; DailyAt = $Data.DailyAt }
                foreach ($key in @('RetentionDays', 'RetentionMonths', 'RetentionYears', 'LogDays')) { if ($Data.ContainsKey($key)) { $arguments[$key] = $Data[$key] } }
                & (Join-Path $Project 'Install-BackupTask.ps1') @arguments
            }
            'TaskStatus' {
                $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if ($null -eq $task) { 'Keine Backup-Aufgabe fuer diesen Benutzer eingerichtet.'; break }
                $info = Get-ScheduledTaskInfo -TaskName $taskName
                [pscustomobject]@{ Aufgabe = $task.TaskName; Status = [string]$task.State; LetzterStart = $info.LastRunTime; NaechsterStart = $info.NextRunTime; LetztesErgebnis = $info.LastTaskResult }
                foreach ($trigger in $task.Triggers) { $trigger | Select-Object @{Name='Trigger';Expression={$_.CimClass.CimClassName}}, Delay, StartBoundary, Enabled }
            }
            'Enable' { Enable-ScheduledTask -TaskName $taskName | Out-Null; 'Aufgabe aktiviert.' }
            'Disable' { Disable-ScheduledTask -TaskName $taskName | Out-Null; 'Aufgabe deaktiviert. Ein bereits laufendes Backup wird fortgesetzt.' }
            'RemoveTask' { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false; 'Aufgabe entfernt. Sicherungsdateien bleiben erhalten.' }
            'Snapshots' {
                . (Join-Path $Project 'Backup-UserProfile.ps1')
                $userRoot = Join-Path $Data.BackupRoot (Get-BupIdentity).Folder
                foreach ($tier in @('Daily', 'Monthly', 'Yearly')) {
                    $parent = Join-Path $userRoot $tier
                    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { continue }
                    Assert-BupPlainDirectory $parent
                    foreach ($dir in Get-ChildItem -LiteralPath $parent -Directory | Sort-Object Name -Descending) {
                        $manifest = Get-BupManifest $dir.FullName $sid
                        if ($null -ne $manifest) { [pscustomobject]@{ Label = "$tier / $($dir.Name)"; Path = $dir.FullName } }
                    }
                }
            }
            'Restore' {
                . (Join-Path $Project 'Restore-UserProfile.ps1') -SnapshotPath unused -DestinationPath unused
                $arguments = @{ SnapshotPath = $Data.Snapshot; DestinationPath = $Data.Destination; NonInteractive = $true }
                if ($Data.Category -ne 'Alle') { $arguments.Categories = @($Data.Category) }
                $result = Invoke-UserProfileRestore @arguments
                if ($result.Errors) { throw "Wiederherstellung mit $($result.Errors) Fehlern beendet. Kopiert: $($result.Copied), ausgelassen: $($result.Skipped)." }
                $result
            }
            default { throw "Unbekannter Vorgang: $Action" }
        }
    }).AddArgument($Window.Project).AddArgument($Action).AddArgument($Data)
    try { $handle = $job.BeginInvoke() }
    catch { $job.Dispose(); throw }
    $Window.LastError = $null
    $Window.Worker = [pscustomobject]@{ PowerShell = $job; Handle = $handle; Action = $Action }
    foreach ($button in $Window.Buttons) { $button.Enabled = $false }
    $Window.Controls.Progress.BackColor = [Drawing.Color]::FromArgb(81,154,255)
    $Window.Controls.Status.Text = "Vorgang laeuft: $Action"
    $Window.Controls.Output.AppendText("`r`n[$(Get-Date -Format 'HH:mm:ss')] Start: $Action`r`n")
    $Window.Timer.Start()
}

function Complete-BupGuiWork($Window) {
    if ($null -eq $Window.Worker -or -not $Window.Worker.Handle.IsCompleted) { return }
    $job = $Window.Worker
    $acceptedUpdate = $null
    try {
        $results = @($job.PowerShell.EndInvoke($job.Handle))
        if ($job.PowerShell.HadErrors) { throw ($job.PowerShell.Streams.Error | Out-String) }
        if ($job.Action -eq 'Snapshots') {
            $Window.Controls.Snapshots.Items.Clear()
            foreach ($entry in $results) { $null = $Window.Controls.Snapshots.Items.Add($entry) }
            if ($results.Count) { $Window.Controls.Snapshots.SelectedIndex = 0 }
            $Window.Controls.Output.AppendText("$($results.Count) gueltige Sicherungsstaende gefunden.`r`n")
        }
        else { $Window.Controls.Output.AppendText(($results | Format-List | Out-String)) }
        if ($job.Action -eq 'UpdateCheck' -and $results.Count -eq 1 -and $results[0].UpdateAvailable) {
            $info = $results[0]
            $message = "Version $($info.InstalledVersion) -> $($info.Version)`r`nQuelle: $($info.RepositoryUrl)`r`nCommit: $($info.Commit)`r`n`r`nJetzt installieren? Die GUI wird geschlossen und danach neu gestartet. Einstellungen und Sicherungsdaten bleiben erhalten."
            if ([Windows.Forms.MessageBox]::Show($Window.Form, $message, 'Programmupdate verfuegbar', 'YesNo', 'Question') -eq 'Yes') { $acceptedUpdate = $info }
        }
        foreach ($warning in $job.PowerShell.Streams.Warning) { $Window.Controls.Output.AppendText("Hinweis: $warning`r`n") }
        $Window.Controls.Status.Text = 'Vorgang abgeschlossen.'
    }
    catch {
        $Window.LastError = [string]$_
        $Window.Controls.Output.AppendText("FEHLER: $_`r`n")
        $Window.Controls.Status.Text = 'Vorgang fehlgeschlagen. Details im Ergebnisfeld.'
    }
    finally {
        $job.PowerShell.Dispose()
        $Window.Worker = $null
        $Window.Timer.Stop()
        $Window.Controls.Progress.BackColor = [Drawing.Color]::FromArgb(40,50,65)
        foreach ($button in $Window.Buttons) { $button.Enabled = $true }
    }
    if ($null -ne $acceptedUpdate) {
        try {
            $launch = Get-BupUpdateLaunch $Window $acceptedUpdate
            Start-Process -FilePath $launch.FilePath -ArgumentList $launch.Arguments -WindowStyle Hidden
            $Window.Form.Close()
        }
        catch { $Window.LastError = [string]$_; $Window.Controls.Output.AppendText("Update konnte nicht gestartet werden: $_`r`n") }
    }
}

function New-BupGuiWindow([string]$ConfigurationPath) {
    $form = New-Object Windows.Forms.Form
    $form.SuspendLayout()
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)
    # Alle Bounds sind fuer 96 DPI entworfen; erst den fertigen Baum skalieren.
    $form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
    $form.AutoScaleMode = 'Dpi'
    $form.Text = 'Benutzerprofil-Backup'
    $form.ClientSize = New-Object Drawing.Size(900, 740)
    $form.MinimumSize = $form.Size
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = [Drawing.Color]::FromArgb(245, 247, 250)
    $state = [pscustomobject]@{ Form = $form; Project = $PSScriptRoot; SettingsPath = $ConfigurationPath; Controls = @{}; Navigation = (New-Object 'System.Collections.Generic.List[object]'); Retention = @{ RetentionDays = 7; RetentionMonths = 12; RetentionYears = 5; LogDays = 30 }; Buttons = (New-Object 'System.Collections.Generic.List[object]'); Worker = $null; Timer = (New-Object Windows.Forms.Timer); LastError = $null }
    $form.Tag = $state

    function Add-Label($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width = 750, [int]$Height = 28) {
        $control = New-Object Windows.Forms.Label
        $control.Text = $Text; $control.SetBounds($X, $Y, $Width, $Height)
        $Parent.Controls.Add($control)
        return $control
    }
    function Add-TextBox($Parent, [int]$X, [int]$Y, [int]$Width) {
        $control = New-Object Windows.Forms.TextBox
        $control.SetBounds($X, $Y, $Width, 28); $Parent.Controls.Add($control)
        return $control
    }
    function Add-Button($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [string]$Action) {
        $control = New-Object Windows.Forms.Button
        $control.Text = $Text; $control.SetBounds($X, $Y, $Width, 36)
        $control.FlatStyle = 'Flat'; $control.BackColor = [Drawing.Color]::White
        $control.Tag = $Action
        $control.Add_Click({ Invoke-BupGuiClick $this.FindForm().Tag ([string]$this.Tag) })
        $Parent.Controls.Add($control); $state.Buttons.Add($control)
        return $control
    }
    $heading = Add-Label $form 'Persoenliche Dateien. Sicher versioniert.' 22 16 850 34
    $heading.Font = New-Object Drawing.Font('Segoe UI', 18, [Drawing.FontStyle]::Bold)
    # Kein ueberbreites Label vor dem Button: Labels liegen in WinForms im Vordergrund.
    $null = Add-Label $form 'Installieren, sichern, planen und wiederherstellen.' 24 56 650
    $state.Controls.SettingsButton = Add-Button $form 'Einstellungen ...' 700 52 175 'Settings'
    $state.Controls.SettingsButton.Anchor = 'Top,Right'
    $null = Add-Label $form 'Sicherungsziel' 24 98 150
    $state.Controls.Root = Add-TextBox $form 180 96 550
    $null = Add-Button $form 'Auswaehlen ...' 740 94 135 'BrowseRoot'
    $null = Add-Label $form 'Protokollordner' 24 140 150
    $state.Controls.Logs = Add-TextBox $form 180 138 550
    $null = Add-Button $form 'Auswaehlen ...' 740 136 135 'BrowseLogs'

    # Eigene dunkle Navigation; native Tab-Rahmen/Tab-Leiste liegen ausserhalb
    # des sichtbaren Panels, damit kein heller Systemstreifen zurueckbleibt.
    $navigation = New-Object Windows.Forms.FlowLayoutPanel
    $navigation.SetBounds(24, 190, 852, 40); $navigation.Anchor = 'Top,Left,Right'; $navigation.WrapContents = $false
    $form.Controls.Add($navigation); $state.Controls.Navigation = $navigation
    $viewport = New-Object Windows.Forms.Panel
    $viewport.SetBounds(24, 230, 852, 260); $viewport.Anchor = 'Top,Left,Right'
    $form.Controls.Add($viewport)
    $tabs = New-Object Windows.Forms.TabControl
    $tabs.SetBounds(-4, -26, 860, 290); $tabs.Anchor = 'Top,Bottom,Left,Right'
    $viewport.Controls.Add($tabs); $state.Controls.Tabs = $tabs
    $pages = @{}
    foreach ($name in @('Install', 'Backup', 'Taskplanung', 'Restore')) {
        $page = New-Object Windows.Forms.TabPage
        $page.Text = $name; $page.BackColor = [Drawing.Color]::White
        $tabs.TabPages.Add($page); $pages[$name] = $page
        $navButton = New-Object Windows.Forms.Button
        $navButton.Text = $name; $navButton.Tag = $tabs.TabPages.Count - 1
        $navButton.Size = New-Object Drawing.Size(135, 36)
        $navButton.Margin = New-Object Windows.Forms.Padding(0,0,8,0)
        $navButton.Add_Click({ $this.FindForm().Tag.Controls.Tabs.SelectedIndex = [int]$this.Tag })
        $navigation.Controls.Add($navButton); $state.Navigation.Add($navButton)
    }
    $tabs.Add_SelectedIndexChanged({ Update-BupNavigation $this.FindForm().Tag })
    $null = Add-Label $pages.Install '1. Vorhandenes Sicherungsziel auswaehlen (lokal, USB oder UNC).' 18 22
    $null = Add-Label $pages.Install '2. Unter Taskplanung die gewuenschten Startzeiten einstellen.' 18 58
    $null = Add-Label $pages.Install '3. Einstellungen speichern und die Aufgabe fuer diesen Benutzer einrichten.' 18 94
    $null = Add-Button $pages.Install 'Einstellungen speichern' 18 148 225 'Save'
    $null = Add-Button $pages.Install 'Installieren / aktualisieren' 255 148 260 'Install'
    $null = Add-Button $pages.Install 'Updates ...' 530 148 180 'Updates'
    $null = Add-Label $pages.Install 'Keine Administratorrechte erforderlich. Bestehende Backups bleiben erhalten.' 18 210 780 42
    $null = Add-Label $pages.Backup 'Jetzt sichern' 18 22
    $null = Add-Label $pages.Backup 'Sichert die sieben persoenlichen Windows-Ordner mit Versionierung.' 18 58
    $null = Add-Label $pages.Backup 'Jeder Klick erstellt einen neuen Stand mit Uhrzeit. Vorhandene Staende bleiben erhalten.' 18 94 800
    $null = Add-Button $pages.Backup 'Backup starten' 18 148 220 'Backup'
    $null = Add-Button $pages.Backup 'Protokollordner oeffnen' 250 148 240 'OpenLogs'
    $state.Controls.RetentionLabel = Add-Label $pages.Backup '' 18 210 800
    Update-BupGuiRetentionLabel $state

    $null = Add-Label $pages.Taskplanung 'Bei Anmeldung starten, Verzoegerung (Minuten):' 18 22 435
    $state.Controls.Delay = New-Object Windows.Forms.NumericUpDown
    $state.Controls.Delay.SetBounds(465, 20, 75, 30); $state.Controls.Delay.Minimum = 0; $state.Controls.Delay.Maximum = 60
    $pages.Taskplanung.Controls.Add($state.Controls.Delay)
    $state.Controls.Daily = New-Object Windows.Forms.CheckBox
    $state.Controls.Daily.Text = 'Zusaetzlich taeglich um'; $state.Controls.Daily.SetBounds(18, 65, 265, 30)
    $pages.Taskplanung.Controls.Add($state.Controls.Daily)
    $state.Controls.Time = New-Object Windows.Forms.MaskedTextBox
    $state.Controls.Time.Mask = '00:00'
    $state.Controls.Time.SetBounds(295, 65, 100, 30); $pages.Taskplanung.Controls.Add($state.Controls.Time)
    $state.Controls.Daily.Add_CheckedChanged({ $this.FindForm().Tag.Controls.Time.Enabled = $this.Checked })
    $null = Add-Label $pages.Taskplanung 'Automatisch maximal ein Tagesstand; manuelle Backups sind jederzeit moeglich.' 18 106 790 30
    $null = Add-Button $pages.Taskplanung 'Plan speichern' 18 150 170 'Install'
    $null = Add-Button $pages.Taskplanung 'Status abrufen' 200 150 170 'TaskStatus'
    $null = Add-Button $pages.Taskplanung 'Aktivieren' 382 150 150 'Enable'
    $null = Add-Button $pages.Taskplanung 'Deaktivieren' 544 150 150 'Disable'
    $null = Add-Button $pages.Taskplanung 'Aufgabe entfernen' 18 200 190 'RemoveTask'

    $state.Controls.Snapshots = New-Object Windows.Forms.ComboBox
    $state.Controls.Snapshots.DropDownStyle = 'DropDownList'; $state.Controls.Snapshots.DisplayMember = 'Label'
    $state.Controls.Snapshots.SetBounds(18, 18, 440, 30); $pages.Restore.Controls.Add($state.Controls.Snapshots)
    $state.Controls.Snapshots.Add_SelectedIndexChanged({ $s = $this.FindForm().Tag; if ($null -ne $this.SelectedItem) { $s.Controls.Snapshot.Text = $this.SelectedItem.Path } })
    $null = Add-Button $pages.Restore 'Staende laden' 470 15 170 'Snapshots'
    $null = Add-Label $pages.Restore 'Sicherungsstand' 18 65 160
    $state.Controls.Snapshot = Add-TextBox $pages.Restore 180 62 455
    $null = Add-Button $pages.Restore 'Auswaehlen ...' 647 59 165 'BrowseSnapshot'
    $null = Add-Label $pages.Restore 'Wiederherstellungsziel' 18 108 160
    $state.Controls.Destination = Add-TextBox $pages.Restore 180 105 455
    $null = Add-Button $pages.Restore 'Auswaehlen ...' 647 102 165 'BrowseDestination'
    $state.Controls.Category = New-Object Windows.Forms.ComboBox
    $state.Controls.Category.DropDownStyle = 'DropDownList'; $state.Controls.Category.SetBounds(18, 153, 190, 30)
    foreach ($name in @('Alle', 'Desktop', 'Documents', 'Pictures', 'Music', 'Videos', 'Downloads', 'Favorites')) { $null = $state.Controls.Category.Items.Add($name) }
    $state.Controls.Category.SelectedIndex = 0; $pages.Restore.Controls.Add($state.Controls.Category)
    $null = Add-Button $pages.Restore 'Wiederherstellen' 225 148 220 'Restore'
    $null = Add-Label $pages.Restore 'Vorhandene Dateien werden ausgelassen. Inhalte werden vor dem Kopieren geprueft.' 18 208 790 40

    $state.Controls.Status = Add-Label $form 'Bereit.' 24 505 850 26
    $state.Controls.Status.Anchor = 'Top,Left,Right'
    $state.Controls.Progress = New-Object Windows.Forms.Panel
    $state.Controls.Progress.SetBounds(24, 535, 852, 4); $state.Controls.Progress.Anchor = 'Top,Left,Right'
    $form.Controls.Add($state.Controls.Progress)
    $state.Controls.Output = New-Object Windows.Forms.RichTextBox
    $state.Controls.Output.DetectUrls = $false
    $state.Controls.Output.Multiline = $true; $state.Controls.Output.ReadOnly = $true; $state.Controls.Output.ScrollBars = 'Vertical'
    $state.Controls.Output.WordWrap = $false; $state.Controls.Output.Font = New-Object Drawing.Font('Consolas', 9)
    $state.Controls.Output.SetBounds(24, 555, 852, 160); $state.Controls.Output.Anchor = 'Top,Bottom,Left,Right'
    $state.Controls.Output.BackColor = [Drawing.Color]::White; $form.Controls.Add($state.Controls.Output)
    $state.Timer.Interval = 200
    $timerState = $state
    $completionHandler = ${function:Complete-BupGuiWork}
    $state.Timer.Add_Tick({ & $completionHandler $timerState }.GetNewClosure())
    $form.Add_FormClosing({
        if ($null -ne $this.Tag.Worker) {
            $_.Cancel = $true
            $this.Tag.Controls.Status.Text = 'Vorgang laeuft noch. Bitte bis zum Abschluss warten.'
        }
    })
    $form.Add_FormClosed({ $this.Tag.Timer.Dispose() })
    try {
        $settings = Read-BupGuiSettings $ConfigurationPath
        foreach ($key in @($state.Retention.Keys)) { $state.Retention[$key] = [int]$settings[$key] }
        # Zahlenbereiche vor Anzeige/Verwendung ueber die numerischen Dialogfelder pruefen.
        $validationDialog = New-BupSettingsDialog $state
        $validationDialog.Dispose()
        Update-BupGuiRetentionLabel $state
        $state.Controls.Root.Text = [string]$settings.BackupRoot
        $state.Controls.Logs.Text = [string]$settings.LogRoot
        $state.Controls.Delay.Value = [Math]::Max(0, [Math]::Min(60, [int]$settings.DelayMinutes))
        $state.Controls.Time.Text = '18:00'
        if ($settings.DailyAt) { $null = [datetime]::ParseExact($settings.DailyAt, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture); $state.Controls.Time.Text = $settings.DailyAt; $state.Controls.Daily.Checked = $true }
        $state.Controls.Time.Enabled = $state.Controls.Daily.Checked
    }
    catch {
        $state.Retention = @{ RetentionDays = 7; RetentionMonths = 12; RetentionYears = 5; LogDays = 30 }
        Update-BupGuiRetentionLabel $state
        $state.Controls.Output.Text = "Einstellungen konnten nicht geladen werden: $_"
        $state.Controls.Logs.Text = Join-Path $env:LOCALAPPDATA 'UserProfileBackup\Logs'
    }
    Set-BupDarkTheme $form
    Update-BupNavigation $state
    $state.Controls.Progress.BackColor = [Drawing.Color]::FromArgb(40,50,65)
    $form.ResumeLayout($true)
    $form.MinimumSize = $form.Size
    return $state
}

function Invoke-BupGuiClick($Window, [string]$Action) {
    try {
        if ($Action -like 'Browse*') {
            $key = $Action.Substring(6)
            if ($key -eq 'Root' -or $key -eq 'Logs' -or $key -eq 'Snapshot' -or $key -eq 'Destination') {
                $dialog = New-Object Windows.Forms.FolderBrowserDialog
                $dialog.Description = 'Ordner auswaehlen (UNC-Pfade koennen auch direkt eingegeben werden).'
                $dialog.ShowNewFolderButton = $key -in @('Logs', 'Destination')
                try { if ($dialog.ShowDialog($Window.Form) -eq 'OK') { $Window.Controls[$key].Text = $dialog.SelectedPath } }
                finally { $dialog.Dispose() }
            }
            return
        }
        switch ($Action) {
            'Updates' {
                $dialog = New-BupUpdateDialog $Window
                try {
                    if ($dialog.ShowDialog($Window.Form) -eq 'OK') {
                        $source = Get-Content -LiteralPath (Get-BupUpdateSourcePath $Window.SettingsPath) -Raw | ConvertFrom-Json
                        Start-BupGuiWork $Window UpdateCheck @{ RepositoryUrl = [string]$source.RepositoryUrl; Ref = [string]$source.Ref }
                    }
                }
                finally { $dialog.Dispose() }
            }
            'Settings' {
                $dialog = New-BupSettingsDialog $Window
                try { $null = $dialog.ShowDialog($Window.Form) } finally { $dialog.Dispose() }
            }
            'Save' {
                Save-BupGuiSettings $Window.SettingsPath (Get-BupGuiRequest $Window)
                $Window.Controls.Status.Text = 'Einstellungen gespeichert. Eine vorhandene Aufgabe wird erst mit Installieren / Plan speichern aktualisiert.'
            }
            'Install' {
                $data = Get-BupGuiRequest $Window
                Save-BupGuiSettings $Window.SettingsPath $data
                Start-BupGuiWork $Window Install $data
            }
            'Backup' { Start-BupGuiWork $Window Backup (Get-BupGuiRequest $Window) }
            'Snapshots' { Start-BupGuiWork $Window Snapshots (Get-BupGuiRequest $Window) }
            'Restore' {
                $snapshot = $Window.Controls.Snapshot.Text.Trim()
                $destination = $Window.Controls.Destination.Text.Trim()
                if (-not [IO.Path]::IsPathRooted($snapshot) -or -not (Test-Path -LiteralPath $snapshot -PathType Container)) { throw 'Bitte einen vorhandenen Sicherungsstand auswaehlen.' }
                if (-not [IO.Path]::IsPathRooted($destination)) { throw 'Bitte ein absolutes Wiederherstellungsziel angeben.' }
                Start-BupGuiWork $Window Restore @{ Snapshot = $snapshot; Destination = $destination; Category = [string]$Window.Controls.Category.SelectedItem }
            }
            'OpenLogs' {
                $path = $Window.Controls.Logs.Text.Trim()
                if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'Protokollordner existiert noch nicht.' }
                Start-Process -FilePath explorer.exe -ArgumentList ('"' + $path + '"')
            }
            'RemoveTask' {
                if ([Windows.Forms.MessageBox]::Show($Window.Form, 'Backup-Aufgabe fuer diesen Benutzer entfernen? Die Sicherungsdateien bleiben erhalten.', 'Aufgabe entfernen', 'YesNo', 'Question') -eq 'Yes') { Start-BupGuiWork $Window RemoveTask @{} }
            }
            default { Start-BupGuiWork $Window $Action @{} }
        }
    }
    catch { $Window.LastError = [string]$_; $Window.Controls.Output.AppendText("FEHLER: $_`r`n"); $Window.Controls.Status.Text = 'Eingabe oder Vorgang fehlgeschlagen. Details im Ergebnisfeld.' }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $NoShow -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Bitte die GUI mit powershell.exe -STA -File Start-BackupGUI.ps1 starten.' }
    [Windows.Forms.Application]::EnableVisualStyles()
    $programReadLock = [IO.File]::Open((Join-Path $PSScriptRoot '.program.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
    try {
        if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.updates\pending.json')) { throw 'Unabgeschlossenes Programmupdate. Bitte Update-UserProfileBackup.ps1 -Rollback ausfuehren.' }
        $window = New-BupGuiWindow $SettingsPath
        try { if (-not $NoShow) { $null = $window.Form.ShowDialog() } }
        finally { $window.Timer.Dispose(); $window.Form.Dispose() }
    }
    finally { $programReadLock.Dispose() }
}
