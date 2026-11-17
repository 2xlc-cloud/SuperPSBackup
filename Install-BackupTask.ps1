#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Backup')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Backup')][string]$BackupRoot,
    # Richtet statt der Backup-Aufgabe die Aufgabe fuer Programmupdates ein.
    [Parameter(Mandatory, ParameterSetName = 'Update')][switch]$UpdateTask,
    [Parameter(ParameterSetName = 'Update')][string]$UpdateRepositoryUrl = 'https://github.com/2xlc-cloud/UserProfileBackup',
    [Parameter(ParameterSetName = 'Update')][string]$UpdateRef = 'main',
    # CheckOnly: nur pruefen und protokollieren. Install: gefundene Updates ohne Rueckfrage installieren.
    [Parameter(ParameterSetName = 'Update')][ValidateSet('CheckOnly', 'Install')][string]$UpdateMode = 'CheckOnly',
    # Nur fuer Tests: abweichender Aufgabenname. Standard sind die benutzerbezogenen Namen.
    [ValidatePattern('^[A-Za-z0-9._-]{1,100}$')][string]$TaskName = '',
    [string]$LogRoot = (Join-Path $env:LOCALAPPDATA 'UserProfileBackup\Logs'),
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
    $taskName = if ($TaskName) { $TaskName } else { 'UserProfileBackupUpdate-' + $sid }
}
else {
    if (-not [IO.Path]::IsPathRooted($BackupRoot) -or -not (Test-Path -LiteralPath $BackupRoot -PathType Container)) { throw 'BackupRoot muss ein vorhandenes, erreichbares absolutes Verzeichnis sein.' }
    $BackupRoot = [IO.Path]::GetFullPath($BackupRoot)
    $taskName = if ($TaskName) { $TaskName } else { 'UserProfileBackup-' + $sid }
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
    $description = 'Prueft auf Programmupdates fuer UserProfileBackup und installiert sie je nach Einstellung.'
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
