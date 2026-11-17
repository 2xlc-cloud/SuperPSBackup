#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Backup')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Backup')][string]$BackupRoot,
    # Richtet statt der Backup-Aufgabe die Aufgabe fuer Programmupdates ein.
    [Parameter(Mandatory, ParameterSetName = 'Update')][switch]$UpdateTask,
    [Parameter(ParameterSetName = 'Update')][string]$UpdateRepositoryUrl = 'https://github.com/2xlc-cloud/SuperPSBackup',
    [Parameter(ParameterSetName = 'Update')][string]$UpdateRef = 'main',
    # CheckOnly: nur pruefen und protokollieren. Install: gefundene Updates ohne Rueckfrage installieren.
    [Parameter(ParameterSetName = 'Update')][ValidateSet('CheckOnly', 'Install')][string]$UpdateMode = 'CheckOnly',
    # Uebernimmt Aufgaben, Datenordner und Einstellungen der frueheren Version (UserProfileBackup) unter den neuen Namen.
    [Parameter(Mandatory, ParameterSetName = 'Migrate')][switch]$MigrateLegacy,
    # Nur fuer Tests: Namen der alten und neuen Aufgaben (LegacyBackup, LegacyUpdate, Backup, Update).
    [Parameter(ParameterSetName = 'Migrate')][hashtable]$NameOverride,
    # Nur fuer Tests: abweichender Aufgabenname. Standard sind die benutzerbezogenen Namen.
    [ValidatePattern('^[A-Za-z0-9._-]{1,100}$')][string]$TaskName = '',
    [string]$LogRoot = (Join-Path $env:LOCALAPPDATA 'SuperPSBackup\Logs'),
    # Standard: Backup 2 Minuten, Update 10 Minuten nach der Anmeldung.
    [ValidateRange(0,60)][int]$DelayMinutes = 2,
    # Optionaler taeglicher Trigger zusaetzlich zur Anmeldung, Format HH:mm.
    [string]$DailyAt = '',
    [ValidateRange(1,36500)][int]$RetentionDays = 7,
    [ValidateRange(1,1200)][int]$RetentionMonths = 12,
    [ValidateRange(1,100)][int]$RetentionYears = 5,
    [ValidateRange(1,3650)][int]$LogDays = 30,
    # Liefert nur die XML-Definition; legt keine Aufgabe an.
    [switch]$PassThruXml
)
$ErrorActionPreference = 'Stop'
$programLockPath = Join-Path $PSScriptRoot '.program.lock'
if ((Test-Path -LiteralPath $programLockPath) -and ((Get-Item -LiteralPath $programLockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Programm-Lockdatei ist eine Verknuepfung.' }
$programReadLock = [IO.File]::Open($programLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
try {
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.updates\pending.json')) { throw 'Unabgeschlossenes Programmupdate. Zuerst Update-UserProfileBackup.ps1 -Rollback ausfuehren.' }
$isUpdate = ($PSCmdlet.ParameterSetName -eq 'Update')
if ($PSCmdlet.ParameterSetName -eq 'Migrate') {
    $report = New-Object 'System.Collections.Generic.List[string]'
    $migSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $names = @{ LegacyBackup = 'UserProfileBackup-' + $migSid; LegacyUpdate = 'UserProfileBackupUpdate-' + $migSid; Backup = 'SuperPSBackup-' + $migSid; Update = 'SuperPSBackupUpdate-' + $migSid }
    if ($NameOverride) { foreach ($key in @($NameOverride.Keys)) { $names[[string]$key] = [string]$NameOverride[$key] } }
    $oldData = Join-Path $env:LOCALAPPDATA 'UserProfileBackup'
    $newData = Join-Path $env:LOCALAPPDATA 'SuperPSBackup'
    $mapPath = { param([string]$Path) if ($Path -and $Path.StartsWith($oldData + '\', [StringComparison]::OrdinalIgnoreCase)) { $newData + $Path.Substring($oldData.Length) } else { $Path } }
    $mapUrl = { param([string]$Url) $Url -replace '^(https://github\.com/[^/]+/)UserProfileBackup(\.git)?/?$', '$1SuperPSBackup' }
    $unquote = { param([string]$Text) $Text.Replace("''", "'") }

    # 1. Datenordner (Einstellungen, Protokolle, Updateprotokolle)
    if (Test-Path -LiteralPath $oldData -PathType Container) {
        if ((Get-Item -LiteralPath $oldData -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { $report.Add('Alter Datenordner ist eine Verknuepfung und wird nicht uebernommen.') }
        elseif (-not (Test-Path -LiteralPath $newData)) { Move-Item -LiteralPath $oldData -Destination $newData -ErrorAction Stop; $report.Add("Datenordner uebernommen: $oldData -> $newData") }
        else {
            $moved = 0
            foreach ($child in Get-ChildItem -LiteralPath $oldData -Force) {
                $target = Join-Path $newData $child.Name
                if (-not (Test-Path -LiteralPath $target)) { Move-Item -LiteralPath $child.FullName -Destination $target -ErrorAction Stop; $moved++ }
            }
            if (-not @(Get-ChildItem -LiteralPath $oldData -Force).Count) { Remove-Item -LiteralPath $oldData -ErrorAction Stop }
            $report.Add("Datenordner zusammengefuehrt: $moved Eintraege uebernommen.")
        }
    }
    # 2. gespeicherte Pfade und Updatequelle
    foreach ($entry in @(@{ File = 'gui-settings.json'; Name = 'LogRoot'; Map = $mapPath }, @{ File = 'update-source.json'; Name = 'RepositoryUrl'; Map = $mapUrl })) {
        $file = Join-Path $newData $entry.File
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        try {
            $json = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if (-not $json.PSObject.Properties[$entry.Name]) { continue }
            $current = [string]$json.($entry.Name); $mapped = & $entry.Map $current
            if ($mapped -ne $current) {
                $json.($entry.Name) = $mapped
                [IO.File]::WriteAllText($file, ($json | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
                $report.Add("$($entry.File): $($entry.Name) aktualisiert.")
            }
        }
        catch { $report.Add("$($entry.File) konnte nicht aktualisiert werden: $_") }
    }
    # 3. Windows-Aufgaben unter neuem Namen anlegen, danach die alten entfernen
    $find = { param([string]$Name) @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -eq $Name })[0] }
    foreach ($kind in @('Backup', 'Update')) {
        $legacyName = $names["Legacy$kind"]; $newName = $names[$kind]
        $label = if ($kind -eq 'Backup') { 'Backup-Aufgabe' } else { 'Update-Aufgabe' }
        $legacy = & $find $legacyName
        if ($null -eq $legacy) { continue }
        if ($null -ne (& $find $newName)) {
            Unregister-ScheduledTask -TaskName $legacyName -Confirm:$false
            $report.Add("$label bereits unter neuem Namen vorhanden; alte Aufgabe entfernt.")
            continue
        }
        try {
            $arguments = [string]$legacy.Actions[0].Arguments
            $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($arguments -split ' ')[-1]))
            $logon = @($legacy.Triggers | Where-Object { $_.CimClass.CimClassName -match 'Logon' })[0]
            $calendar = @($legacy.Triggers | Where-Object { $_.CimClass.CimClassName -match 'Daily|Time|Calendar' })[0]
            $plan = @{ TaskName = $newName; DelayMinutes = $(if ($logon -and [string]$logon.Delay -match '^PT(\d+)M$') { [int]$Matches[1] } else { 2 }) }
            if ($calendar -and $calendar.StartBoundary) { $plan.DailyAt = ([datetime]$calendar.StartBoundary).ToString('HH:mm') }
            if ($kind -eq 'Backup') {
                if ($command -notmatch "-BackupRoot '((?:[^']|'')*)'") { throw 'Sicherungsziel in der alten Aufgabe nicht gefunden.' }
                $plan.BackupRoot = & $unquote $Matches[1]
                if ($command -match "-LogRoot '((?:[^']|'')*)'") { $plan.LogRoot = & $mapPath (& $unquote $Matches[1]) }
                foreach ($key in @('RetentionDays', 'RetentionMonths', 'RetentionYears', 'LogDays')) { if ($command -match "-$key (\d+)") { $plan[$key] = [int]$Matches[1] } }
            }
            else {
                if ($command -notmatch "-RepositoryUrl '((?:[^']|'')*)'") { throw 'Updatequelle in der alten Aufgabe nicht gefunden.' }
                $plan.UpdateTask = $true
                $plan.UpdateRepositoryUrl = & $mapUrl (& $unquote $Matches[1])
                if ($command -match "-Ref '((?:[^']|'')*)'") { $plan.UpdateRef = & $unquote $Matches[1] }
                $plan.UpdateMode = $(if ($command -match ' -CheckOnly') { 'CheckOnly' } else { 'Install' })
                if ($command -match "\`$log = '((?:[^']|'')*)'") { $plan.LogRoot = & $mapPath (Split-Path -Parent (& $unquote $Matches[1])) }
            }
            $null = & $PSCommandPath @plan
            if ([string]$legacy.State -eq 'Disabled') { Disable-ScheduledTask -TaskName $newName | Out-Null }
            Unregister-ScheduledTask -TaskName $legacyName -Confirm:$false
            $report.Add("$label uebernommen: $legacyName -> $newName")
        }
        catch { $report.Add("$label konnte nicht uebernommen werden (alte Aufgabe bleibt bestehen): $_") }
    }
    if (-not $report.Count) { $report.Add('Nichts zu uebernehmen.') }
    return ($report.ToArray() -join "`n")
}
$scriptPath = Join-Path $PSScriptRoot 'Backup-UserProfile.ps1'
if (-not $isUpdate -and -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Hauptskript fehlt: $scriptPath" }
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if (-not [IO.Path]::IsPathRooted($LogRoot)) { throw 'LogRoot muss ein absoluter Pfad sein.' }
if ($isUpdate) {
    if (-not $PSBoundParameters.ContainsKey('DelayMinutes')) { $DelayMinutes = 10 }
    if ($UpdateRepositoryUrl -notmatch '^https://github\.com/([a-zA-Z0-9_.-]+)/([a-zA-Z0-9_.-]+?)(?:\.git)?/?$' -or $Matches[1] -in @('.','..') -or $Matches[2] -in @('.','..')) { throw 'UpdateRepositoryUrl muss die URL eines oeffentlichen GitHub-Repositorys sein: https://github.com/Benutzer/Repository' }
    $UpdateRepositoryUrl = "https://github.com/$($Matches[1])/$($Matches[2])"
    if ($UpdateRef -notmatch '^[A-Za-z0-9._/-]{1,100}$') { throw 'UpdateRef enthaelt ungueltige Zeichen.' }
    $updaterPath = Join-Path $PSScriptRoot 'Update-UserProfileBackup.ps1'
    if (-not (Test-Path -LiteralPath $updaterPath -PathType Leaf)) { throw "Update-Skript fehlt: $updaterPath" }
    $taskName = if ($TaskName) { $TaskName } else { 'SuperPSBackupUpdate-' + $sid }
}
else {
    if (-not [IO.Path]::IsPathRooted($BackupRoot) -or -not (Test-Path -LiteralPath $BackupRoot -PathType Container)) { throw 'BackupRoot muss ein vorhandenes, erreichbares absolutes Verzeichnis sein.' }
    $BackupRoot = [IO.Path]::GetFullPath($BackupRoot)
    $taskName = if ($TaskName) { $TaskName } else { 'SuperPSBackup-' + $sid }
}
$dailyTrigger = ''
if ($DailyAt) {
    $clock = [datetime]::ParseExact($DailyAt, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $boundary = (Get-Date).Date.Add($clock.TimeOfDay).ToString('yyyy-MM-ddTHH:mm:ss')
    $dailyTrigger = "<CalendarTrigger><StartBoundary>$boundary</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>"
}
# EncodedCommand vermeidet fehlerhafte Auswertung von Leerzeichen, Apostrophen und Sonderzeichen.
$quote = { param([string]$Text) $Text.Replace("'", "''") }
if ($isUpdate) {
    $updateLog = Join-Path $LogRoot 'update-task.log'
    $checkOnlyArgument = if ($UpdateMode -eq 'CheckOnly') { ' -CheckOnly' } else { '' }
    $command = @(
        ('$log = ''' + (& $quote $updateLog) + ''''),
        '$null = New-Item -ItemType Directory -Path (Split-Path -Parent $log) -Force',
        'if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 262144) { Remove-Item -LiteralPath $log -Force }',
        ('try { $out = (& ''' + (& $quote $updaterPath) + ''' -RepositoryUrl ''' + (& $quote $UpdateRepositoryUrl) + ''' -Ref ''' + (& $quote $UpdateRef) + ''' -InstallRoot ''' + (& $quote $PSScriptRoot) + '''' + $checkOnlyArgument + ' | Out-String).Trim(); Add-Content -LiteralPath $log -Value ((Get-Date -Format s) + '' '' + $out) -Encoding UTF8 }'),
        'catch { Add-Content -LiteralPath $log -Value ((Get-Date -Format s) + '' FEHLER: '' + $_) -Encoding UTF8; exit 1 }'
    ) -join "`r`n"
    $description = 'Prueft auf Programmupdates fuer SuperPSBackup und installiert sie je nach Einstellung.'
}
else {
    $command = "& '" + (& $quote $scriptPath) + "' -BackupRoot '" + (& $quote $BackupRoot) + "' -LogRoot '" + (& $quote $LogRoot) + "'"
    $command += " -RetentionDays $RetentionDays -RetentionMonths $RetentionMonths -RetentionYears $RetentionYears -LogDays $LogDays"
    $description = 'Versionierte Sicherung persoenlicher Benutzerordner.'
}
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$exe = [Security.SecurityElement]::Escape((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>$([Security.SecurityElement]::Escape($description))</Description></RegistrationInfo>
  <Triggers><LogonTrigger><Enabled>true</Enabled><Delay>PT${DelayMinutes}M</Delay><UserId>$sid</UserId></LogonTrigger>$dailyTrigger</Triggers>
  <Principals><Principal id="User"><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate><StartWhenAvailable>true</StartWhenAvailable>
    <Enabled>true</Enabled><Hidden>true</Hidden><ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
  </Settings>
  <Actions Context="User"><Exec><Command>$exe</Command><Arguments>-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $encoded</Arguments></Exec></Actions>
</Task>
"@
if ($PassThruXml) { return $xml }
if ($PSCmdlet.ShouldProcess($taskName, 'Windows-Aufgabe fuer aktuellen Benutzer anlegen/aktualisieren')) {
    Register-ScheduledTask -TaskName $taskName -Xml $xml -Force -ErrorAction Stop | Out-Null
    $kind = if ($isUpdate) { "Update-Aufgabe (Modus $UpdateMode)" } else { 'Backup-Aufgabe' }
    Write-Output "$kind eingerichtet: $taskName. Start $DelayMinutes Minuten nach Anmeldung. Zusaetzliche Tageszeit: $DailyAt"
}
}
finally { $programReadLock.Dispose() }
