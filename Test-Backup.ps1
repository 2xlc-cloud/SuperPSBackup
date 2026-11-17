#requires -Version 5.1
[CmdletBinding()]
param([switch]$KeepTestData)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Backup-UserProfile.ps1')
. (Join-Path $PSScriptRoot 'Restore-UserProfile.ps1') -SnapshotPath unused -DestinationPath unused
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('UserProfileBackup-Test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $sandbox
$script:checks = 0
function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "TEST FEHLGESCHLAGEN: $Message (Daten: $sandbox)" }
    $script:checks++
    Write-Output "OK $script:checks - $Message"
}
function New-TestEnvironment([string]$Name) {
    $caseRoot = Join-Path $sandbox $Name
    $source = Join-Path $caseRoot 'source'
    $target = Join-Path $caseRoot "target [x] O'Brien"
    $logs = Join-Path $caseRoot 'logs'
    foreach ($p in @($source, $target, $logs)) { $null = New-Item -ItemType Directory -Path $p -Force }
    [pscustomobject]@{ Source = $source; Root = $target; Logs = $logs; Target = (Join-Path $target (Get-BupIdentity).Folder) }
}
function Invoke-TestBackup($Env, [string]$Date) {
    Invoke-UserProfileBackup -BackupRoot $Env.Root -LogRoot $Env.Logs -SourceFolders ([ordered]@{ Documents = $Env.Source }) -AsOf ([datetime]::ParseExact($Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture))
}
function Write-TestFile([string]$Path, [string]$Content) { [IO.File]::WriteAllText($Path, $Content) }
function Read-TestFile([string]$Path) { [IO.File]::ReadAllText($Path) }
function Get-TestSnapshot($Env, [string]$Tier, [string]$Name) { Join-Path (Join-Path $Env.Target $Tier) $Name }

$passed = $false
try {
    foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1') {
        $tokens = $null; $parseErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        Assert-Test ($parseErrors.Count -eq 0) "Syntax: $($file.Name)"
    }
    $envTest = New-TestEnvironment 'basic'
    $alpha = Join-Path $envTest.Source 'a [1].txt'
    $deleted = Join-Path $envTest.Source 'deleted.txt'
    Write-TestFile $alpha 'version-one'
    Write-TestFile $deleted 'keep-me'
    $null = New-Item -ItemType Directory -Path (Join-Path $envTest.Source 'empty')
    Write-TestFile (Join-Path $envTest.Source 'cache.tmp') 'excluded'
    $first = Invoke-TestBackup $envTest '2026-01-01'
    Assert-Test ($first.Status -eq 'Complete' -and $first.Copied -eq 2 -and $first.Errors -eq 0) 'Erster vollstaendiger Lauf'
    $day1 = Get-TestSnapshot $envTest Daily '2026-01-01'
    Assert-Test (Test-Path -LiteralPath (Join-Path $day1 'Documents\empty') -PathType Container) 'Leere Ordner bleiben erhalten'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $day1 'Documents\cache.tmp'))) 'Temporaere Dateien ausgeschlossen'
    $second = Invoke-TestBackup $envTest '2026-01-02'
    Assert-Test ($second.Status -eq 'Complete' -and $second.Copied -eq 0 -and $second.Skipped -eq 2 -and $second.Bytes -eq 0) 'Unveraenderte Dateien mit Hardlinks, keine Kopien'
    $day2 = Get-TestSnapshot $envTest Daily '2026-01-02'
    # Windows PowerShell 5.1 LinkType hat Probleme mit eckigen Klammern im Pfad.
    # Die gemeinsame Dateireferenz direkt in den isolierten Testdaten nachweisen.
    Write-TestFile (Join-Path $day2 'Documents\a [1].txt') 'hardlink-probe'
    Assert-Test ((Read-TestFile (Join-Path $day1 'Documents\a [1].txt')) -eq 'hardlink-probe') 'Tatsaechliche NTFS-Hardlinks verwendet'
    Write-TestFile (Join-Path $day2 'Documents\a [1].txt') 'version-one'
    [IO.File]::SetLastWriteTimeUtc((Join-Path $day2 'Documents\a [1].txt'), [IO.File]::GetLastWriteTimeUtc($alpha))
    $originalStamp = [IO.File]::GetLastWriteTimeUtc($alpha)
    Write-TestFile $alpha 'version-two'
    [IO.File]::SetLastWriteTimeUtc($alpha, $originalStamp)
    [IO.File]::Delete($deleted)
    $third = Invoke-TestBackup $envTest '2026-01-03'
    Assert-Test ($third.Status -eq 'Complete' -and $third.Copied -eq 1) 'Geaenderter Inhalt trotz gleicher Laenge/Zeit erkannt'
    $day3 = Get-TestSnapshot $envTest Daily '2026-01-03'
    Assert-Test ((Read-TestFile (Join-Path $day1 'Documents\a [1].txt')) -eq 'version-one') 'Alte Version durch Aenderung nicht beschaedigt'
    Assert-Test ((Read-TestFile (Join-Path $day3 'Documents\a [1].txt')) -eq 'version-two') 'Neue Dateiversion gesichert'
    Assert-Test ((Test-Path -LiteralPath (Join-Path $day1 'Documents\deleted.txt')) -and -not (Test-Path -LiteralPath (Join-Path $day3 'Documents\deleted.txt'))) 'Loeschung verschwindet nur im neuen Stand'
    $month = Get-TestSnapshot $envTest Monthly '2026-01'
    Assert-Test ((Read-TestFile (Join-Path $month 'Documents\a [1].txt')) -eq 'version-one') 'Erster Monatsstand wird nicht ueberschrieben'
    $sameDay = Invoke-TestBackup $envTest '2026-01-03'
    Assert-Test ($sameDay.Status -eq 'AlreadyComplete' -and $sameDay.Copied -eq 0) 'Mehrfache Anmeldung am selben Tag kopiert nichts'
    $restorePath = Join-Path $sandbox 'restored'
    $restored = Invoke-UserProfileRestore -SnapshotPath $day1 -DestinationPath $restorePath -NonInteractive
    Assert-Test ($restored.Copied -eq 2 -and $restored.Errors -eq 0 -and (Read-TestFile (Join-Path $restorePath 'Documents\a [1].txt')) -eq 'version-one') 'Aeltere Version vollstaendig wiederhergestellt'
    Write-TestFile (Join-Path $restorePath 'Documents\a [1].txt') 'do-not-overwrite'
    $restoreAgain = Invoke-UserProfileRestore -SnapshotPath $day1 -DestinationPath $restorePath -NonInteractive -WarningAction SilentlyContinue
    Assert-Test ($restoreAgain.Skipped -eq 2 -and (Read-TestFile (Join-Path $restorePath 'Documents\a [1].txt')) -eq 'do-not-overwrite') 'Keine Ueberschreibung ohne Bestaetigung'
    $whatIf = Join-Path $sandbox 'whatif'
    $null = Invoke-UserProfileRestore -SnapshotPath $day1 -DestinationPath $whatIf -WhatIf
    Assert-Test (-not (Test-Path -LiteralPath $whatIf)) 'Restore -WhatIf schreibt nichts'
    $missing = Invoke-UserProfileBackup -BackupRoot (Join-Path $sandbox 'missing') -LogRoot $envTest.Logs -SourceFolders @{ Documents = $envTest.Source }
    Assert-Test ($missing.Status -eq 'Failed' -and -not (Test-Path -LiteralPath (Join-Path $sandbox 'missing'))) 'Nicht erreichbares Ziel wird protokolliert und nicht angelegt'
    $before = @(Get-ChildItem -LiteralPath (Join-Path $envTest.Target 'Daily') -Directory).Count
    $held = [IO.File]::Open($alpha, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { $failed = Invoke-TestBackup $envTest '2026-02-15' } finally { $held.Dispose() }
    Assert-Test ($failed.Status -eq 'Failed' -and $failed.Errors -ge 1) 'Gesperrte Datei erkannt'
    Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $envTest.Target 'Daily') -Directory).Count -eq $before) 'Fehler: kein neuer Tagesstand und keine Loeschung alter Staende'
    Assert-Test (-not (Test-Path -LiteralPath (Get-TestSnapshot $envTest Monthly '2026-02'))) 'Fehler: kein Monatsstand'
    Assert-Test (@(Get-ChildItem -LiteralPath $envTest.Target -Directory -Force | Where-Object Name -like '.incomplete-*').Count -eq 0) 'Unvollstaendige Arbeitsordner entfernt'
    $retry = Invoke-TestBackup $envTest '2026-02-15'
    Assert-Test ($retry.Status -eq 'Complete') 'Wiederholung nach Sperrfreigabe erfolgreich'
    $targetLock = [IO.File]::Open((Join-Path $envTest.Target '.backup.lock'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { $locked = Invoke-TestBackup $envTest '2026-02-16' } finally { $targetLock.Dispose() }
    Assert-Test ($locked.Status -eq 'Failed' -and -not (Test-Path -LiteralPath (Get-TestSnapshot $envTest Daily '2026-02-16'))) 'Exklusive Zielsperre verhindert Parallelzugriff'
    $oldLog = Join-Path $envTest.Logs ((Get-Date).Date.AddDays(-30).ToString('yyyy-MM-dd') + '.log')
    $keepLog = Join-Path $envTest.Logs ((Get-Date).Date.AddDays(-29).ToString('yyyy-MM-dd') + '.log')
    Write-TestFile $oldLog 'old'; Write-TestFile $keepLog 'keep'
    $null = Invoke-TestBackup $envTest '2026-02-16'
    Assert-Test (-not (Test-Path -LiteralPath $oldLog) -and (Test-Path -LiteralPath $keepLog)) 'Logrotation: maximal 30 Kalendertage'

    $fallback = New-TestEnvironment 'fallback'
    Write-TestFile (Join-Path $fallback.Source 'file.txt') 'fallback-data'
    # Nur Hardlink-Erstellung gezielt ablehnen, alle anderen New-Item-Aufrufe unveraendert.
    function New-Item {
        [CmdletBinding()]
        param([string]$Path, [string]$Name, [string]$ItemType, $Value, [switch]$Force)
        if ($ItemType -eq 'HardLink') { throw 'Test: Dateisystem unterstuetzt keine Hardlinks.' }
        Microsoft.PowerShell.Management\New-Item @PSBoundParameters
    }
    try {
        $fallbackFirst = Invoke-TestBackup $fallback '2026-01-01'
        $fallbackSecond = Invoke-TestBackup $fallback '2026-01-02'
    }
    finally { Remove-Item -LiteralPath Function:\New-Item }
    Assert-Test ($fallbackFirst.Status -eq 'Complete' -and $fallbackFirst.ArchiveBytes -eq 26 -and $fallbackSecond.Status -eq 'Complete' -and $fallbackSecond.Copied -eq 1) 'Ziel ohne Hardlinks: automatische vollstaendige Dateikopien'
    Assert-Test ((Read-TestFile (Join-Path (Get-TestSnapshot $fallback Monthly '2026-01') 'Documents\file.txt')) -eq 'fallback-data') 'Kopie im Monatsarchiv lesbar'
    # Beschaedigte Archivquelle darf niemals alte Staende zur Rotation freigeben.
    $damagedDaily = Get-TestSnapshot $fallback Daily '2026-01-02'
    Write-TestFile (Join-Path $damagedDaily 'Documents\file.txt') 'damaged'
    $null = Rename-Item -LiteralPath (Get-TestSnapshot $fallback Monthly '2026-01') -NewName 'saved-month'
    $archiveFailure = Invoke-TestBackup $fallback '2026-01-02'
    Assert-Test ($archiveFailure.Status -eq 'Failed' -and (Test-Path -LiteralPath (Get-TestSnapshot $fallback Daily '2026-01-01'))) 'Integritaetsfehler bei Archivierung: keine Rotation'
    $badRestore = Invoke-UserProfileRestore -SnapshotPath $damagedDaily -DestinationPath (Join-Path $sandbox 'bad-restore') -NonInteractive -WarningAction SilentlyContinue
    Assert-Test ($badRestore.Errors -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $sandbox 'bad-restore\Documents\file.txt'))) 'Beschaedigte Datei wird nicht wiederhergestellt'

    $empty = New-TestEnvironment 'empty'
    $emptyRun = Invoke-TestBackup $empty '2026-01-01'
    Assert-Test ($emptyRun.Status -eq 'Complete' -and $emptyRun.Copied -eq 0) 'Leere Benutzerordner ergeben gueltigen Stand'
    $overlap = Invoke-UserProfileBackup -BackupRoot $empty.Source -LogRoot $empty.Logs -SourceFolders @{ Documents = $empty.Source }
    Assert-Test ($overlap.Status -eq 'Failed') 'Ueberlappende Quelle und Ziel abgewiesen'

    $manual = New-TestEnvironment 'manual'
    $manualSource = Join-Path $manual.Source 'file.txt'
    Write-TestFile $manualSource 'version-1'
    $base = Invoke-TestBackup $manual '2026-01-10'
    Write-TestFile $manualSource 'version-2'
    $manualArgs = @{ BackupRoot = $manual.Root; LogRoot = $manual.Logs; SourceFolders = @{ Documents = $manual.Source }; AsOf = [datetime]'2026-01-10T12:34:56'; ForceSnapshot = $true }
    $forced1 = Invoke-UserProfileBackup @manualArgs
    $forced2 = Invoke-UserProfileBackup @manualArgs
    Assert-Test ($forced1.Status -eq 'Complete' -and $forced2.Status -eq 'Complete' -and $forced1.SnapshotPath -ne $forced2.SnapshotPath) 'Manuell mehrmals am selben Tag: eindeutige neue Staende auch bei identischer Uhrzeit'
    Assert-Test ($forced2.Copied -eq 0 -and $forced2.Skipped -eq 1) 'Unveraenderte Dateien auch bei manuellem Zusatzstand nicht neu kopiert'
    Assert-Test ((Read-TestFile (Join-Path $base.SnapshotPath 'Documents\file.txt')) -eq 'version-1' -and (Read-TestFile (Join-Path $forced1.SnapshotPath 'Documents\file.txt')) -eq 'version-2') 'Alter Tagesstand und neue manuelle Version bleiben unabhaengig lesbar'
    Assert-Test ((Read-TestFile (Join-Path (Get-TestSnapshot $manual Monthly '2026-01') 'Documents\file.txt')) -eq 'version-1') 'Manuelle Zusatzstaende ueberschreiben keinen Monatsstand'
    $autoAgain = Invoke-TestBackup $manual '2026-01-10'
    Assert-Test ($autoAgain.Status -eq 'AlreadyComplete' -and @(Get-ChildItem -LiteralPath (Join-Path $manual.Target 'Daily') -Directory).Count -eq 3) 'Automatischer Lauf nach manuellen Zusatzstaenden legt keinen weiteren Stand an'
    $manualRestore = Invoke-UserProfileRestore -SnapshotPath $forced1.SnapshotPath -DestinationPath (Join-Path $sandbox 'manual-restored') -NonInteractive
    Assert-Test ($manualRestore.Copied -eq 1 -and $manualRestore.Errors -eq 0) 'Manueller Stand mit Zeitstempel wiederherstellbar'
    $heldManual = [IO.File]::Open($manualSource, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { $forcedFailure = Invoke-UserProfileBackup @manualArgs -RetentionDays 1 } finally { $heldManual.Dispose() }
    Assert-Test ($forcedFailure.Status -eq 'Failed' -and @(Get-ChildItem -LiteralPath (Join-Path $manual.Target 'Daily') -Directory).Count -eq 3) 'Fehlgeschlagener manueller Zusatzlauf laesst alle bestehenden Staende erhalten'
    $retainAll = Invoke-UserProfileBackup -BackupRoot $manual.Root -LogRoot $manual.Logs -SourceFolders @{ Documents = $manual.Source } -AsOf ([datetime]'2026-01-11') -RetentionDays 2
    Assert-Test ($retainAll.Status -eq 'Complete' -and @(Get-ChildItem -LiteralPath (Join-Path $manual.Target 'Daily') -Directory).Count -eq 4) 'Tagesfrist zaehlt Kalendertage statt Anzahl manueller Sicherungsstaende'
    $manualRotation = Invoke-UserProfileBackup -BackupRoot $manual.Root -LogRoot $manual.Logs -SourceFolders @{ Documents = $manual.Source } -AsOf ([datetime]'2026-01-12') -RetentionDays 2
    Assert-Test ($manualRotation.Status -eq 'Complete' -and @(Get-ChildItem -LiteralPath (Join-Path $manual.Target 'Daily') -Directory).Count -eq 2 -and -not (Test-Path -LiteralPath $forced1.SnapshotPath) -and -not (Test-Path -LiteralPath $forced2.SnapshotPath)) 'Eigene Tagesfrist entfernt auch abgelaufene manuelle Staende'
    $manualOnly = New-TestEnvironment 'manual-first'
    Write-TestFile (Join-Path $manualOnly.Source 'file.txt') 'first-manual'
    $only = Invoke-UserProfileBackup -BackupRoot $manualOnly.Root -LogRoot $manualOnly.Logs -SourceFolders @{ Documents = $manualOnly.Source } -AsOf ([datetime]'2026-01-10') -ForceSnapshot
    $autoAfterManual = Invoke-TestBackup $manualOnly '2026-01-10'
    Assert-Test ($only.Status -eq 'Complete' -and $autoAfterManual.Status -eq 'AlreadyComplete' -and @(Get-ChildItem -LiteralPath (Join-Path $manualOnly.Target 'Daily') -Directory).Count -eq 1) 'Automatische Tagespruefung erkennt auch ausschliesslich manuelle Sicherung'

    $custom = New-TestEnvironment 'custom-retention'
    Write-TestFile (Join-Path $custom.Source 'file.txt') 'custom-calendar'
    $customArgs = @{ BackupRoot = $custom.Root; LogRoot = $custom.Logs; SourceFolders = @{ Documents = $custom.Source }; RetentionDays = 2; RetentionMonths = 2; RetentionYears = 2; LogDays = 3 }
    foreach ($date in @('2023-01-01', '2024-01-01', '2025-01-01', '2026-01-01', '2026-02-01', '2026-03-01', '2026-03-02', '2026-03-03')) {
        $customResult = Invoke-UserProfileBackup @customArgs -AsOf ([datetime]$date)
        Assert-Test ($customResult.Status -eq 'Complete') "Eigene Aufbewahrung: $date erfolgreich"
    }
    Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $custom.Target 'Daily') -Directory).Count -eq 2 -and @(Get-ChildItem -LiteralPath (Join-Path $custom.Target 'Monthly') -Directory).Count -eq 2 -and @(Get-ChildItem -LiteralPath (Join-Path $custom.Target 'Yearly') -Directory).Count -eq 2) 'Eigene Tages-, Monats- und Jahresfristen eingehalten'
    $expiredCustomLog = Join-Path $custom.Logs ((Get-Date).Date.AddDays(-3).ToString('yyyy-MM-dd') + '.log')
    $retainedCustomLog = Join-Path $custom.Logs ((Get-Date).Date.AddDays(-2).ToString('yyyy-MM-dd') + '.log')
    Write-TestFile $expiredCustomLog 'expired'; Write-TestFile $retainedCustomLog 'retained'
    $null = Invoke-UserProfileBackup @customArgs -AsOf ([datetime]'2026-03-03')
    Assert-Test (-not (Test-Path -LiteralPath $expiredCustomLog) -and (Test-Path -LiteralPath $retainedCustomLog)) 'Eigene Protokollfrist statt festem 30-Tage-Wert'
    $rejectedRetention = $false
    try { $null = Invoke-UserProfileBackup @manualArgs -RetentionDays 0 } catch { $rejectedRetention = $true }
    Assert-Test $rejectedRetention 'Aufbewahrung null vor Dateizugriff abgewiesen'

    $calendar = New-TestEnvironment 'calendar'
    Write-TestFile (Join-Path $calendar.Source 'file.txt') 'calendar-data'
    foreach ($year in 2020..2025) {
        $r = Invoke-TestBackup $calendar ("$year-01-15")
        Assert-Test ($r.Status -eq 'Complete') "Jahreslauf $year erfolgreich"
    }
    $monthStart = [datetime]'2025-10-01'
    foreach ($offset in 0..13) {
        $date = $monthStart.AddMonths($offset).AddDays(2).ToString('yyyy-MM-dd')
        $r = Invoke-TestBackup $calendar $date
        Assert-Test ($r.Status -eq 'Complete') "Monatslauf $date erfolgreich"
    }
    foreach ($n in 4..17) {
        $r = Invoke-TestBackup $calendar (('2026-11-{0:d2}' -f $n))
        Assert-Test ($r.Status -eq 'Complete') "Tageslauf November $n erfolgreich"
    }
    $days = @(Get-ChildItem -LiteralPath (Join-Path $calendar.Target 'Daily') -Directory | Sort-Object Name)
    $months = @(Get-ChildItem -LiteralPath (Join-Path $calendar.Target 'Monthly') -Directory | Sort-Object Name)
    $years = @(Get-ChildItem -LiteralPath (Join-Path $calendar.Target 'Yearly') -Directory | Sort-Object Name)
    Assert-Test ($days.Count -eq 7 -and $days[0].Name -eq '2026-11-11' -and $days[-1].Name -eq '2026-11-17') 'Taeglich: letzte sieben Kalendertage'
    Assert-Test ($months.Count -eq 12 -and $months[0].Name -eq '2025-12' -and $months[-1].Name -eq '2026-11') 'Monatlich: letzte zwoelf Kalendermonate'
    Assert-Test ($years.Count -eq 5 -and $years[0].Name -eq '2022' -and $years[-1].Name -eq '2026') 'Jaehrlich: letzte fuenf Kalenderjahre'
    Assert-Test ((Read-TestFile (Join-Path (Get-TestSnapshot $calendar Yearly '2022') 'Documents\file.txt')) -eq 'calendar-data') 'Archivdateien nach Loeschen der Tagesstaende lesbar'
    $jan2026 = Get-BupManifest (Get-TestSnapshot $calendar Yearly '2026') (Get-BupIdentity).Sid
    Assert-Test ($jan2026.Date -eq '2026-01-03') 'Erster erfolgreicher Stand des Jahres bleibt erhalten'

    $xmlText = & (Join-Path $PSScriptRoot 'Install-BackupTask.ps1') -BackupRoot $envTest.Root -LogRoot $envTest.Logs -PassThruXml
    [xml]$definition = $xmlText
    Assert-Test ($definition.Task.Triggers.LogonTrigger.Delay -eq 'PT2M' -and $definition.Task.Principals.Principal.RunLevel -eq 'LeastPrivilege') 'Aufgabe: zwei Minuten Verzoegerung, keine erhoehten Rechte'
    Assert-Test ($definition.Task.Settings.MultipleInstancesPolicy -eq 'IgnoreNew' -and $definition.Task.Principals.Principal.LogonType -eq 'InteractiveToken') 'Aufgabe: Benutzerkontext und Parallelitaetsschutz'
    $argsText = $definition.Task.Actions.Exec.Arguments
    $commandText = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($argsText -split ' ')[-1]))
    $tokens = $null; $commandErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($commandText, [ref]$tokens, [ref]$commandErrors)
    Assert-Test ($commandErrors.Count -eq 0 -and $commandText.Contains("O''Brien") -and $argsText.Contains('-WindowStyle Hidden') -and $argsText.Contains('-NonInteractive')) 'Aufgabe: unsichtbarer Start und sichere Pfadquotierung'
    # TASK_VALIDATE_ONLY=1 prueft das Windows-Aufgabenschema, ohne eine Aufgabe anzulegen.
    $scheduler = New-Object -ComObject 'Schedule.Service'
    $scheduler.Connect()
    $taskFolder = $scheduler.GetFolder('\')
    $null = $taskFolder.RegisterTask('UserProfileBackup-ValidationOnly', $xmlText, 1, $null, $null, 3, $null)
    Assert-Test $true 'Aufgaben-XML durch Windows-Aufgabenplanung validiert (ohne Registrierung)'
    $sources = Get-BupSources
    Assert-Test ($sources.Count -eq 7 -and $sources.Downloads -and $sources.Documents) 'Sieben persoenliche Ordner aus Windows ermittelt'
    $passed = $true
    Write-Output "ERFOLGREICH: $script:checks Pruefungen mit PowerShell $($PSVersionTable.PSVersion)."
}
finally {
    if ($passed -and -not $KeepTestData) {
        # Ausschliesslich den zuvor erzeugten, absoluten Testordner unter TEMP loeschen.
        $resolved = [IO.Path]::GetFullPath($sandbox)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not (Test-BupChild $resolved $tempRoot) -or (Split-Path -Leaf $resolved) -notlike 'UserProfileBackup-Test-*') { throw 'Unsicherer Testbereinigungspfad.' }
        Remove-BupTree $resolved
    }
    else { Write-Output "Testdaten: $sandbox" }
}
