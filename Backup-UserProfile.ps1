#requires -Version 5.1
[CmdletBinding()]
param(
    # Zentrale Konfiguration: vorhandenen Ordner auf lokalem/USB-Laufwerk oder UNC setzen.
    [string]$BackupRoot = '',
    [string]$LogRoot = (Join-Path $env:LOCALAPPDATA 'UserProfileBackup\Logs'),
    [switch]$ForceSnapshot,
    [ValidateRange(1,36500)][int]$RetentionDays = 7,
    [ValidateRange(1,1200)][int]$RetentionMonths = 12,
    [ValidateRange(1,100)][int]$RetentionYears = 5,
    [ValidateRange(1,3650)][int]$LogDays = 30
)

Set-StrictMode -Version 2.0

function Get-BupIdentity {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    [pscustomobject]@{ Sid = $sid; Name = $env:USERNAME; Folder = (($env:USERNAME -replace '[^a-zA-Z0-9_.-]', '_') + '-' + $sid) }
}

function Get-BupSources {
    # User Shell Folders ist die Windows-Konfiguration einschliesslich OneDrive/Umleitung.
    if (-not $env:USERPROFILE) { throw 'USERPROFILE fehlt.' }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders')
    if ($null -eq $key) { throw 'Windows-Konfiguration der Benutzerordner fehlt.' }
    try {
        $map = [ordered]@{
            Desktop = @('Desktop', 'DesktopDirectory')
            Documents = @('Personal', 'MyDocuments')
            Pictures = @('My Pictures', 'MyPictures')
            Music = @('My Music', 'MyMusic')
            Videos = @('My Video', 'MyVideos')
            Downloads = @('{374DE290-123F-4565-9164-39C4925E467B}', '')
            Favorites = @('Favorites', 'Favorites')
        }
        $result = [ordered]@{}
        foreach ($name in $map.Keys) {
            $value = $key.GetValue($map[$name][0], $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($value) { $path = [Environment]::ExpandEnvironmentVariables([string]$value) }
            elseif ($map[$name][1]) { $path = [Environment]::GetFolderPath([Environment+SpecialFolder]$map[$name][1]) }
            else { throw "Windows kennt keinen Pfad fuer $name." }
            if (-not $path) { throw "Leerer Windows-Ordnerpfad: $name" }
            $result[$name] = $path
        }
        return $result
    }
    finally { $key.Dispose() }
}

function Write-BupLog($Context, [string]$Level, [string]$Message) {
    $line = '{0} [{1}] User={2} Target={3} {4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Context.Identity.Sid, $Context.Target, $Message
    Add-Content -LiteralPath $Context.LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
}

function Test-BupChild([string]$Path, [string]$Parent) {
    $p = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $r = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return ($p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Get-BupSafePath([string]$Root, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':') -or $Relative -match '(^|[\\/])\.\.?([\\/]|$)') {
        throw "Unsicherer relativer Pfad: $Relative"
    }
    $path = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not (Test-BupChild $path $Root)) { throw "Pfad ausserhalb der Sicherung: $Relative" }
    return $path
}

function Assert-BupPlainDirectory([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Sicherungsverzeichnis darf keine Verknuepfung sein: $Path"
    }
}

function Get-BupManifest([string]$Path, [string]$Sid) {
    try {
        Assert-BupPlainDirectory $Path
        $file = Join-Path $Path '.snapshot.json'
        $item = Get-Item -LiteralPath $file -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $null }
        $m = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($m.Format -ne 1 -or $m.Status -ne 'Complete' -or $m.UserSid -ne $Sid) { return $null }
        $null = [datetime]::ParseExact($m.Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        if ($null -eq $m.Files -or $null -eq $m.Categories) { return $null }
        foreach ($entry in $m.Files) {
            $null = Get-BupSafePath $Path $entry.Path
            # PowerShell 7 wandelt ISO-Zeitstempel beim JSON-Lesen automatisch um.
            if ($entry.LastWriteUtc -is [datetime]) { $entry.LastWriteUtc = $entry.LastWriteUtc.ToUniversalTime().ToString('o') }
        }
        return $m
    }
    catch { return $null }
}

function Get-BupHash([string]$Path) {
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '') }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Copy-BupOrLink([string]$Previous, [string]$Destination) {
    # Rueckgabewert: true bei Hardlink, false bei unabhaengiger Kopie.
    try {
        $linkTarget = $Previous
        if ($PSVersionTable.PSVersion.Major -le 5) { $linkTarget = [Management.Automation.WildcardPattern]::Escape($Previous) }
        $null = New-Item -ItemType HardLink -Path $Destination -Value $linkTarget -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) { throw 'Hardlink wurde nicht erstellt.' }
        return $true
    }
    catch {
        if (Test-Path -LiteralPath $Destination) { throw }
        [IO.File]::Copy($Previous, $Destination, $false)
        return $false
    }
}

function Remove-BupTree([string]$Path) {
    Assert-BupPlainDirectory $Path
    $links = @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($links.Count) { throw "Bereinigung verweigert: Verknuepfung in $Path" }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}

function New-BupArchive($Context, [string]$Daily, [string]$Tier, [string]$Name, $Manifest) {
    $parent = Join-Path $Context.Target $Tier
    $dest = Join-Path $parent $Name
    if (Test-Path -LiteralPath $dest) {
        $existing = Get-BupManifest $dest $Context.Identity.Sid
        if ($null -eq $existing -or -not $existing.Date.StartsWith($Name)) { throw "Vorhandener Archivstand ist ungueltig: $dest" }
        return
    }
    $stage = Join-Path $Context.Target ('.incomplete-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $stage -ErrorAction Stop
    try {
        foreach ($category in $Manifest.Categories) { $null = New-Item -ItemType Directory -Path (Get-BupSafePath $stage $category.Name) -Force -ErrorAction Stop }
        foreach ($dir in $Manifest.Directories) { $null = New-Item -ItemType Directory -Path (Get-BupSafePath $stage $dir) -Force -ErrorAction Stop }
        foreach ($entry in $Manifest.Files) {
            $source = Get-BupSafePath $Daily $entry.Path
            $destination = Get-BupSafePath $stage $entry.Path
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force -ErrorAction Stop
            if ((Get-BupHash $source) -ne $entry.Hash) { throw "Archivquelle wurde veraendert: $source" }
            if (-not (Copy-BupOrLink $source $destination)) { $Context.Stats.ArchiveBytes += [long]$entry.Length }
        }
        $Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stage '.snapshot.json') -Encoding UTF8 -ErrorAction Stop
        [IO.Directory]::Move($stage, $dest)
        Write-BupLog $Context INFO "Archiv angelegt: $Tier\$Name"
    }
    finally { if (Test-Path -LiteralPath $stage) { Remove-BupTree $stage } }
}

function Remove-BupExpired($Context, [datetime]$AsOf, [int]$RetentionDays, [int]$RetentionMonths, [int]$RetentionYears) {
    $rules = @(
        @{ Tier = 'Daily'; Pattern = '^\d{4}-\d{2}-\d{2}(?:_\d{9}_[a-f0-9]{32})?$'; DateLength = 10; Format = 'yyyy-MM-dd'; Cutoff = $AsOf.Date.AddDays(1 - $RetentionDays) },
        @{ Tier = 'Monthly'; Pattern = '^\d{4}-\d{2}$'; DateLength = 7; Format = 'yyyy-MM'; Cutoff = (Get-Date -Year $AsOf.Year -Month $AsOf.Month -Day 1).Date.AddMonths(1 - $RetentionMonths) },
        @{ Tier = 'Yearly'; Pattern = '^\d{4}$'; DateLength = 4; Format = 'yyyy'; Cutoff = (Get-Date -Year $AsOf.Year -Month 1 -Day 1).Date.AddYears(1 - $RetentionYears) }
    )
    # Zuerst alle Kandidaten pruefen, erst danach entfernen.
    $expired = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rule in $rules) {
        foreach ($dir in Get-ChildItem -LiteralPath (Join-Path $Context.Target $rule.Tier) -Directory -Force -ErrorAction Stop) {
            if ($dir.Name -notmatch $rule.Pattern) { continue }
            $m = Get-BupManifest $dir.FullName $Context.Identity.Sid
            if ($null -eq $m) { throw "Rotation verweigert: ungueltiger Stand $($dir.FullName)" }
            $period = $dir.Name.Substring(0, $rule.DateLength)
            if (-not $m.Date.StartsWith($period)) { throw 'Ordnerdatum stimmt nicht mit Manifest ueberein.' }
            $date = [datetime]::ParseExact($period, $rule.Format, [Globalization.CultureInfo]::InvariantCulture)
            if ($date -lt $rule.Cutoff) {
                $links = @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
                if ($links.Count) { throw 'Rotation verweigert: Verknuepfung gefunden.' }
                $expired.Add($dir.FullName)
            }
        }
    }
    foreach ($path in $expired) { Remove-BupTree $path; Write-BupLog $Context INFO "Abgelaufenen Stand entfernt: $path" }
}

function Invoke-UserProfileBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$LogRoot,
        # Nur fuer isolierte Tests; der normale Einstieg verwendet Windows-Benutzerordner.
        [System.Collections.IDictionary]$SourceFolders,
        [datetime]$AsOf = (Get-Date),
        [switch]$ForceSnapshot,
        [ValidateRange(1,36500)][int]$RetentionDays = 7,
        [ValidateRange(1,1200)][int]$RetentionMonths = 12,
        [ValidateRange(1,100)][int]$RetentionYears = 5,
        [ValidateRange(1,3650)][int]$LogDays = 30
    )
    $ErrorActionPreference = 'Stop'
    $identity = Get-BupIdentity
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $stats = [pscustomobject]@{ Copied = 0; Skipped = 0; Errors = 0; Bytes = [long]0; ArchiveBytes = [long]0 }
    $context = [pscustomobject]@{ Identity = $identity; Target = $BackupRoot; LogFile = ''; Stats = $stats }
    $status = 'Failed'; $stage = $null; $lock = $null; $mutex = $null; $ownsMutex = $false; $programReadLock = $null
    try {
        $programLockPath = Join-Path $PSScriptRoot '.program.lock'
        if ((Test-Path -LiteralPath $programLockPath) -and ((Get-Item -LiteralPath $programLockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Programm-Lockdatei ist eine Verknuepfung.' }
        $programReadLock = [IO.File]::Open($programLockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
        if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.updates\pending.json')) { throw 'Unabgeschlossenes Programmupdate. Zuerst Update-UserProfileBackup.ps1 -Rollback ausfuehren.' }
        $null = New-Item -ItemType Directory -Path $LogRoot -Force
        $context.LogFile = Join-Path $LogRoot ((Get-Date -Format 'yyyy-MM-dd') + '.log')
        Write-BupLog $context INFO 'Start'
        foreach ($log in Get-ChildItem -LiteralPath $LogRoot -File -Filter '*.log') {
            if ($log.BaseName -match '^\d{4}-\d{2}-\d{2}$') {
                $logDate = [datetime]::ParseExact($log.BaseName, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
                if ($logDate -lt (Get-Date).Date.AddDays(1 - $LogDays)) { Remove-Item -LiteralPath $log.FullName -Force }
            }
        }
        $mutex = New-Object Threading.Mutex($false, ('Local\UserProfileBackup-' + $identity.Sid))
        try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { $status = 'Busy'; Write-BupLog $context INFO 'Ein Sicherungslauf ist bereits aktiv.' }
        else {
            if ([string]::IsNullOrWhiteSpace($BackupRoot) -or -not [IO.Path]::IsPathRooted($BackupRoot)) { throw 'BackupRoot muss ein konfigurierter absoluter Pfad sein.' }
            if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) { throw "Sicherungsziel nicht erreichbar: $BackupRoot" }
            $BackupRoot = [IO.Path]::GetFullPath($BackupRoot)
            Assert-BupPlainDirectory $BackupRoot
            if ($null -eq $SourceFolders) { $SourceFolders = Get-BupSources }
            if ($SourceFolders.Count -eq 0) { throw 'Keine Quellordner.' }
            foreach ($name in $SourceFolders.Keys) {
                if ($name -notmatch '^[a-zA-Z][a-zA-Z0-9_-]*$') { throw 'Ungueltiger Kategoriename.' }
                $source = [IO.Path]::GetFullPath($SourceFolders[$name])
                if ((Test-BupChild $BackupRoot $source) -or (Test-BupChild $source $BackupRoot)) { throw "Quelle und Ziel ueberlappen: $source" }
                if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Quellordner fehlt oder ist nicht erreichbar: $source" }
            }
            $context.Target = Join-Path $BackupRoot $identity.Folder
            $null = New-Item -ItemType Directory -Path $context.Target -Force
            Assert-BupPlainDirectory $context.Target
            # Exklusive Datei sperrt auch andere Sitzungen/Computer am selben Ziel.
            $lockPath = Join-Path $context.Target '.backup.lock'
            if ((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Lockdatei ist eine Verknuepfung.' }
            $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            # Reale Schreibprobe, auch wenn heute schon ein Backup existiert.
            $probe = Join-Path $context.Target ('.write-test-' + [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($probe, 'probe'); [IO.File]::Delete($probe)
            foreach ($tier in @('Daily', 'Monthly', 'Yearly')) {
                $dir = Join-Path $context.Target $tier
                $null = New-Item -ItemType Directory -Path $dir -Force
                Assert-BupPlainDirectory $dir
            }
            $day = $AsOf.ToString('yyyy-MM-dd')
            $dailyName = $day
            if ($ForceSnapshot) { $dailyName += '_' + $AsOf.ToString('HHmmssfff') + '_' + [guid]::NewGuid().ToString('N') }
            $daily = Join-Path (Join-Path $context.Target 'Daily') $dailyName
            $manifest = Get-BupManifest $daily $identity.Sid
            $candidates = @(Get-ChildItem -LiteralPath (Join-Path $context.Target 'Daily') -Directory | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}(?:_\d{9}_[a-f0-9]{32})?$' -and $_.Name.Substring(0,10).CompareTo($day) -le 0 } | Sort-Object Name -Descending)
            if (-not $ForceSnapshot) {
                foreach ($candidate in $candidates) {
                    if ($candidate.Name.Substring(0,10) -ne $day) { break }
                    $existing = Get-BupManifest $candidate.FullName $identity.Sid
                    if ($null -ne $existing) { $daily = $candidate.FullName; $manifest = $existing; break }
                }
            }
            if (Test-Path -LiteralPath $daily) {
                if ($null -eq $manifest) { throw "Ungueltiger Tagesstand wird nicht ueberschrieben: $daily" }
                $status = 'AlreadyComplete'
                $stats.Skipped = @($manifest.Files).Count
                Write-BupLog $context INFO 'Heute bereits erfolgreich gesichert; Quellen werden nicht erneut gelesen.'
            }
            else {
                $previous = $null; $previousManifest = $null
                foreach ($candidate in $candidates) {
                    $previousManifest = Get-BupManifest $candidate.FullName $identity.Sid
                    if ($null -ne $previousManifest) { $previous = $candidate.FullName; break }
                }
                $index = @{}
                if ($null -ne $previousManifest) { foreach ($entry in $previousManifest.Files) { $index[$entry.Path] = $entry } }
                $stage = Join-Path $context.Target ('.incomplete-' + [guid]::NewGuid().ToString('N'))
                $null = New-Item -ItemType Directory -Path $stage
                $files = New-Object 'System.Collections.Generic.List[object]'
                $directories = New-Object 'System.Collections.Generic.List[string]'
                $categories = New-Object 'System.Collections.Generic.List[object]'
                foreach ($name in $SourceFolders.Keys) {
                    $sourceRoot = [IO.Path]::GetFullPath($SourceFolders[$name]).TrimEnd('\')
                    $categories.Add([pscustomobject]@{ Name = $name; Source = $sourceRoot })
                    $null = New-Item -ItemType Directory -Path (Join-Path $stage $name)
                    $pending = New-Object 'System.Collections.Generic.Stack[string]'
                    $pending.Push($sourceRoot)
                    while ($pending.Count) {
                        $folder = $pending.Pop()
                        try { $children = @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction Stop) }
                        catch { $stats.Errors++; Write-BupLog $context ERROR "Ordner nicht lesbar: $folder : $_"; continue }
                        foreach ($item in $children) {
                            if (($item.Attributes -band [IO.FileAttributes]::System) -or ($item.Attributes -band [IO.FileAttributes]::Temporary)) { continue }
                            $relative = $name + '\' + $item.FullName.Substring($sourceRoot.Length + 1)
                            $destination = Get-BupSafePath $stage $relative
                            if ($item.PSIsContainer) {
                                # Cloud-Verzeichnisse sind ReparsePoints ohne LinkType; Junctions/Symlinks nicht verfolgen.
                                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.LinkType) { Write-BupLog $context INFO "Verzeichnisverknuepfung ausgelassen: $($item.FullName)"; continue }
                                $null = New-Item -ItemType Directory -Path $destination -Force
                                $directories.Add($relative)
                                $pending.Push($item.FullName)
                                continue
                            }
                            if ($item.Extension -in @('.tmp', '.temp') -or $item.Name -in @('desktop.ini', 'Thumbs.db')) { continue }
                            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.LinkType) { Write-BupLog $context INFO "Dateiverknuepfung ausgelassen: $($item.FullName)"; continue }
                            $stream = $null; $sha = $null
                            try {
                                # Kein gleichzeitiger Schreibzugriff: gesperrte Dateien fuehren zu einem unvollstaendigen Lauf.
                                $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                                $length = $stream.Length
                                $stamp = [IO.File]::GetLastWriteTimeUtc($item.FullName)
                                $sha = [Security.Cryptography.SHA256]::Create()
                                $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
                                $old = $index[$relative]; $reused = $false
                                if ($null -ne $old -and $old.Hash -eq $hash -and [long]$old.Length -eq $length -and $old.LastWriteUtc -eq $stamp.ToString('o')) {
                                    $oldPath = Get-BupSafePath $previous $relative
                                    if ((Get-BupHash $oldPath) -eq $hash) {
                                        $linked = Copy-BupOrLink $oldPath $destination
                                        if ($linked) { $stats.Skipped++ } else { $stats.Copied++; $stats.Bytes += $length }
                                        $reused = $true
                                    }
                                }
                                if (-not $reused) {
                                    $stream.Position = 0
                                    $output = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                                    try { $stream.CopyTo($output); $output.Flush($true) } finally { $output.Dispose() }
                                    [IO.File]::SetLastWriteTimeUtc($destination, $stamp)
                                    $stats.Copied++; $stats.Bytes += $length
                                }
                                $files.Add([pscustomobject]@{ Path = $relative; Length = $length; LastWriteUtc = $stamp.ToString('o'); Hash = $hash })
                            }
                            catch { $stats.Errors++; Write-BupLog $context ERROR "Datei nicht gesichert: $($item.FullName) : $_" }
                            finally { if ($null -ne $sha) { $sha.Dispose() }; if ($null -ne $stream) { $stream.Dispose() } }
                        }
                    }
                }
                if ($stats.Errors -gt 0) { throw "$($stats.Errors) Datei-/Ordnerfehler; kein neuer Wiederherstellungspunkt und keine Rotation." }
                $manifest = [pscustomobject]@{ Format = 1; Status = 'Complete'; UserSid = $identity.Sid; Date = $day; CreatedUtc = [datetime]::UtcNow.ToString('o'); Categories = @($categories.ToArray()); Directories = @($directories.ToArray()); Files = @($files.ToArray()) }
                $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stage '.snapshot.json') -Encoding UTF8
                [IO.Directory]::Move($stage, $daily)
                $stage = $null
                $status = 'Complete'
                Write-BupLog $context INFO "Tagesstand freigegeben: $daily"
            }
            New-BupArchive $context $daily Monthly $AsOf.ToString('yyyy-MM') $manifest
            New-BupArchive $context $daily Yearly $AsOf.ToString('yyyy') $manifest
            Remove-BupExpired $context $AsOf $RetentionDays $RetentionMonths $RetentionYears
        }
    }
    catch {
        $status = 'Failed'
        if ($stats.Errors -eq 0) { $stats.Errors++ }
        if ($context.LogFile) { try { Write-BupLog $context ERROR ([string]$_) } catch { Write-Warning ([string]$_) } }
        else { Write-Warning ([string]$_) }
    }
    finally {
        if ($null -ne $stage -and (Test-Path -LiteralPath $stage)) {
            try { Remove-BupTree $stage } catch { if ($context.LogFile) { Write-BupLog $context WARN "Unvollstaendigen Arbeitsordner manuell pruefen: $stage : $_" } }
        }
        if ($null -ne $lock) { $lock.Dispose() }
        if ($null -ne $programReadLock) { $programReadLock.Dispose() }
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
        $timer.Stop()
        if ($context.LogFile) {
            try { Write-BupLog $context INFO ("Ende Status=$status Kopiert=$($stats.Copied) Uebersprungen=$($stats.Skipped) Fehler=$($stats.Errors) Bytes=$($stats.Bytes) ArchivBytes=$($stats.ArchiveBytes) Sekunden=$($timer.Elapsed.TotalSeconds.ToString('F2'))") } catch { $status = 'Failed'; Write-Warning "Protokoll nicht beschreibbar: $_" }
        }
    }
    $snapshotPath = $null
    if ($status -in @('Complete', 'AlreadyComplete')) { $snapshotPath = $daily }
    [pscustomobject]@{ Status = $status; Target = $context.Target; SnapshotPath = $snapshotPath; Copied = $stats.Copied; Skipped = $stats.Skipped; Errors = $stats.Errors; Bytes = $stats.Bytes; ArchiveBytes = $stats.ArchiveBytes; Seconds = $timer.Elapsed.TotalSeconds }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($BackupRoot)) { Write-Error 'Bitte BackupRoot im Skript konfigurieren oder als Parameter angeben.'; exit 1 }
    $result = Invoke-UserProfileBackup -BackupRoot $BackupRoot -LogRoot $LogRoot -ForceSnapshot:$ForceSnapshot -RetentionDays $RetentionDays -RetentionMonths $RetentionMonths -RetentionYears $RetentionYears -LogDays $LogDays
    $result
    if ($result.Status -eq 'Failed') { exit 1 }
    exit 0
}
