#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$BackupRoot,
    [string]$LogRoot = (Join-Path $env:LOCALAPPDATA 'UserProfileBackup\Logs'),
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
$scriptPath = Join-Path $PSScriptRoot 'Backup-UserProfile.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Hauptskript fehlt: $scriptPath" }
if (-not [IO.Path]::IsPathRooted($BackupRoot) -or -not (Test-Path -LiteralPath $BackupRoot -PathType Container)) { throw 'BackupRoot muss ein vorhandenes, erreichbares absolutes Verzeichnis sein.' }
$BackupRoot = [IO.Path]::GetFullPath($BackupRoot)
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$taskName = 'UserProfileBackup-' + $sid
$dailyTrigger = ''
if ($DailyAt) {
    $clock = [datetime]::ParseExact($DailyAt, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $boundary = (Get-Date).Date.Add($clock.TimeOfDay).ToString('yyyy-MM-ddTHH:mm:ss')
    $dailyTrigger = "<CalendarTrigger><StartBoundary>$boundary</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>"
}
# EncodedCommand vermeidet fehlerhafte Auswertung von Leerzeichen, Apostrophen und Sonderzeichen.
$command = "& '" + $scriptPath.Replace("'", "''") + "' -BackupRoot '" + $BackupRoot.Replace("'", "''") + "' -LogRoot '" + $LogRoot.Replace("'", "''") + "'"
$command += " -RetentionDays $RetentionDays -RetentionMonths $RetentionMonths -RetentionYears $RetentionYears -LogDays $LogDays"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$exe = [Security.SecurityElement]::Escape((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Versionierte Sicherung persoenlicher Benutzerordner.</Description></RegistrationInfo>
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
    Write-Output "Aufgabe eingerichtet: $taskName. Start $DelayMinutes Minuten nach Anmeldung. Zusaetzliche Tageszeit: $DailyAt"
}
}
finally { $programReadLock.Dispose() }
