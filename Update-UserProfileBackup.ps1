#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$RepositoryUrl = '',
    [string]$Ref = 'main',
    [string]$InstallRoot = '',
    [switch]$CheckOnly,
    [switch]$Rollback,
    [string]$ExpectedCommit = '',
    [int]$WaitForProcessId = 0,
    [switch]$RestartGUI,
    [switch]$ShowResult,
    [string]$GuiSettingsPath = (Join-Path $env:LOCALAPPDATA 'UserProfileBackup\gui-settings.json')
)
if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = $PSScriptRoot }

function Get-BupUpdateFiles {
    @('Backup-UserProfile.ps1','Install-BackupTask.ps1','Restore-UserProfile.ps1',
      'Start-BackupGUI.ps1','Update-UserProfileBackup.ps1','New-UpdateManifest.ps1',
      'Test-Backup.ps1','Test-GUI.ps1','Test-Update.ps1','Test-OnlineUpdate.ps1','Test-FirstInstall.ps1','README.md')
}

function Get-BupRuntimeFiles {
    @('Backup-UserProfile.ps1','Install-BackupTask.ps1','Restore-UserProfile.ps1',
      'Start-BackupGUI.ps1','Update-UserProfileBackup.ps1')
}

function ConvertTo-BupRuntimeManifest($Manifest) {
    $null = Test-BupUpdateManifest $Manifest
    $runtimeNames = @(Get-BupRuntimeFiles)
    $runtime = [pscustomobject]@{ Format = 1; Version = $Manifest.Version; InstallationType = 'Runtime'; Files = @($Manifest.Files | Where-Object { $_.Name -cin $runtimeNames }) }
    return (Test-BupUpdateManifest $runtime)
}

function Assert-BupUpdateDirectory([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Unsicheres Programmverzeichnis: $cursor" }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-BupProgramLock([string]$InstallRoot) {
    $lockPath = Join-Path $InstallRoot '.program.lock'
    if ((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Programm-Lockdatei ist eine Verknuepfung.' }
}

function Get-BupRepository([string]$Url) {
    if ($Url -notmatch '^https://github\.com/([a-zA-Z0-9_.-]+)/([a-zA-Z0-9_.-]+?)(?:\.git)?/?$') {
        throw 'Bitte die URL eines oeffentlichen GitHub-Repositorys verwenden: https://github.com/Benutzer/Repository'
    }
    $owner = $Matches[1]; $name = $Matches[2]
    if ($owner -in @('.', '..') -or $name -in @('.', '..')) { throw 'Ungueltiges Repository.' }
    [pscustomobject]@{ Owner = $owner; Name = $name; Url = "https://github.com/$owner/$name" }
}

function Test-BupUpdateManifest($Manifest) {
    if ($null -eq $Manifest -or $Manifest.Format -ne 1 -or -not $Manifest.Version -or $null -eq $Manifest.Files) { throw 'Ungueltiges Update-Manifest.' }
    $version = [version]$Manifest.Version
    if ($version.Major -lt 1) { throw 'Version muss mindestens 1.0 sein.' }
    $known = @(Get-BupUpdateFiles)
    $names = @{}
    foreach ($entry in $Manifest.Files) {
        if ($entry.Name -cnotin $known -or $names.ContainsKey($entry.Name)) { throw "Nicht erlaubte oder doppelte Update-Datei: $($entry.Name)" }
        if ($entry.SHA256 -notmatch '^[a-fA-F0-9]{64}$' -or [long]$entry.Length -lt 1 -or [long]$entry.Length -gt 5MB) { throw "Ungueltige Pruefsumme/Dateigroesse: $($entry.Name)" }
        $names[$entry.Name] = $true
    }
    foreach ($required in @('Backup-UserProfile.ps1','Install-BackupTask.ps1','Restore-UserProfile.ps1','Start-BackupGUI.ps1','Update-UserProfileBackup.ps1')) {
        if (-not $names.ContainsKey($required)) { throw "Pflichtdatei fehlt im Update: $required" }
    }
    return $Manifest
}

function Read-BupUpdateManifest([string]$Path) {
    Test-BupUpdateManifest (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
}

function Test-BupUpdatePackage([string]$Path) {
    Assert-BupUpdateDirectory $Path
    $manifest = Read-BupUpdateManifest (Join-Path $Path 'update-manifest.json')
    foreach ($entry in $manifest.Files) {
        $file = Join-Path $Path $entry.Name
        $item = Get-Item -LiteralPath $file -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -ne [long]$entry.Length -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.SHA256) { throw "Integritaetsfehler: $($entry.Name)" }
        if ($item.Extension -eq '.ps1') {
            $tokens = $null; $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)
            if ($errors.Count) { throw "PowerShell-Syntaxfehler im Update: $($entry.Name)" }
        }
    }
    return $manifest
}

function Get-BupUpdateInfo([string]$RepositoryUrl, [string]$Ref, [string]$InstallRoot, [string]$ExpectedCommit = '') {
    $repository = Get-BupRepository $RepositoryUrl
    if ([string]::IsNullOrWhiteSpace($Ref)) { throw 'Branch/Tag darf nicht leer sein.' }
    if ($ExpectedCommit -and $ExpectedCommit -notmatch '^[a-fA-F0-9]{40}$') { throw 'Ungueltige Commit-ID.' }
    $headers = @{ 'User-Agent' = 'UserProfileBackup-Updater'; Accept = 'application/vnd.github+json' }
    $commitRef = $Ref
    if ($ExpectedCommit) { $commitRef = $ExpectedCommit }
    $encodedRef = [uri]::EscapeDataString($commitRef)
    $commit = Invoke-RestMethod -Uri "https://api.github.com/repos/$($repository.Owner)/$($repository.Name)/commits/$encodedRef" -Headers $headers -TimeoutSec 30 -ErrorAction Stop
    if ($commit.sha -notmatch '^[a-fA-F0-9]{40}$' -or ($ExpectedCommit -and $commit.sha -ne $ExpectedCommit)) { throw 'GitHub hat eine unerwartete Commit-ID geliefert.' }
    $rawRoot = "https://raw.githubusercontent.com/$($repository.Owner)/$($repository.Name)/$($commit.sha)"
    $manifest = Test-BupUpdateManifest (Invoke-RestMethod -Uri "$rawRoot/update-manifest.json" -Headers @{ 'User-Agent' = 'UserProfileBackup-Updater' } -TimeoutSec 30 -ErrorAction Stop)
    $installed = Read-BupUpdateManifest (Join-Path $InstallRoot 'update-manifest.json')
    if ($installed.PSObject.Properties['InstallationType'] -and $installed.InstallationType -eq 'Runtime') {
        $manifest = ConvertTo-BupRuntimeManifest $manifest
    }
    if ([version]$manifest.Version -lt [version]$installed.Version) { throw "Aeltere Remote-Version $($manifest.Version) wird nicht automatisch installiert." }
    $different = [version]$manifest.Version -gt [version]$installed.Version
    foreach ($entry in $manifest.Files) {
        $local = Join-Path $InstallRoot $entry.Name
        if (-not (Test-Path -LiteralPath $local -PathType Leaf) -or (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash -ne $entry.SHA256) { $different = $true }
    }
    [pscustomobject]@{ RepositoryUrl = $repository.Url; Ref = $Ref; Commit = $commit.sha; Version = $manifest.Version; InstalledVersion = $installed.Version; UpdateAvailable = $different; RawRoot = $rawRoot; Manifest = $manifest }
}

function Set-BupProgramFile([string]$Source, [string]$Destination) {
    if ((Test-Path -LiteralPath $Destination) -and ((Get-Item -LiteralPath $Destination -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Verknuepfung statt Programmdatei: $Destination" }
    $temporary = Join-Path (Split-Path -Parent $Destination) ('.program-update-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::Copy($Source, $temporary, $false)
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            try {
                if (Test-Path -LiteralPath $Destination) { [IO.File]::Replace($temporary, $Destination, [NullString]::Value) }
                else { [IO.File]::Move($temporary, $Destination) }
                break
            }
            catch [IO.IOException] {
                if ($attempt -eq 5) { throw }
                Start-Sleep -Milliseconds (100 * ($attempt + 1))
            }
        }
    }
    finally { if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) } }
}

function Restore-BupUpdateTransaction([string]$InstallRoot, $Transaction) {
    $updates = Join-Path ([IO.Path]::GetFullPath($InstallRoot)) '.updates'
    $backup = [IO.Path]::GetFullPath($Transaction.BackupPath)
    if ([IO.Path]::GetDirectoryName($backup) -ne $updates -or (Split-Path -Leaf $backup) -notmatch '^rollback-[a-f0-9]{32}$') { throw 'Unsicherer Rollback-Pfad.' }
    Assert-BupUpdateDirectory $backup
    $allowed = @(Get-BupUpdateFiles) + @('update-manifest.json')
    # Alles pruefen, bevor die erste Datei zurueckgesetzt wird.
    $seen = @{}
    foreach ($entry in $Transaction.Files) {
        if ($entry.Name -cnotin $allowed -or $seen.ContainsKey($entry.Name)) { throw 'Ungueltige Rollback-Dateiliste.' }
        $seen[$entry.Name] = $true
        $destination = Join-Path $InstallRoot $entry.Name
        if ((Test-Path -LiteralPath $destination) -and ((Get-Item -LiteralPath $destination -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Rollback auf Verknuepfung verweigert.' }
        if ($entry.Existed) {
            $source = Join-Path $backup $entry.Name
            $item = Get-Item -LiteralPath $source -Force -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $entry.SHA256) { throw "Beschaedigtes Rollback: $($entry.Name)" }
        }
    }
    foreach ($entry in $Transaction.Files) {
        $destination = Join-Path $InstallRoot $entry.Name
        if ($entry.Existed) {
            if ((Test-Path -LiteralPath $destination -PathType Leaf) -and (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $entry.SHA256) { continue }
            Set-BupProgramFile (Join-Path $backup $entry.Name) $destination
        }
        elseif (Test-Path -LiteralPath $destination) { [IO.File]::Delete($destination) }
    }
}

function Install-BupUpdatePackage([string]$InstallRoot, [string]$PackagePath, [string]$Commit = '') {
    $ErrorActionPreference = 'Stop'
    $InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
    Assert-BupUpdateDirectory $InstallRoot
    $manifest = Test-BupUpdatePackage $PackagePath
    $installed = Read-BupUpdateManifest (Join-Path $InstallRoot 'update-manifest.json')
    if ([version]$manifest.Version -lt [version]$installed.Version) { throw 'Downgrade verweigert; bei Bedarf ausdruecklich -Rollback verwenden.' }
    $updates = Join-Path $InstallRoot '.updates'
    Assert-BupUpdateDirectory $updates
    $null = New-Item -ItemType Directory -Path $updates -Force
    $pendingPath = Join-Path $updates 'pending.json'
    if (Test-Path -LiteralPath $pendingPath) { throw 'Unabgeschlossenes Update gefunden. Zuerst Update-UserProfileBackup.ps1 -Rollback ausfuehren.' }
    $programLock = $null
    try {
        Assert-BupProgramLock $InstallRoot
        $programLock = [IO.File]::Open((Join-Path $InstallRoot '.program.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $backup = Join-Path $updates ('rollback-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $backup
        $inventory = @()
        $names = @($manifest.Files | ForEach-Object { $_.Name }) + @('update-manifest.json')
        foreach ($name in $names) {
            $current = Join-Path $InstallRoot $name
            $exists = Test-Path -LiteralPath $current
            $hash = $null
            if ($exists) {
                $item = Get-Item -LiteralPath $current -Force
                if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsichere bestehende Programmdatei.' }
                [IO.File]::Copy($current, (Join-Path $backup $name), $false)
                $hash = (Get-FileHash -LiteralPath (Join-Path $backup $name) -Algorithm SHA256).Hash
            }
            $inventory += [pscustomobject]@{ Name = $name; Existed = $exists; SHA256 = $hash }
        }
        $transaction = [pscustomobject]@{ Format = 1; BackupPath = $backup; Commit = $Commit; Version = $manifest.Version; Files = $inventory }
        $transaction | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pendingPath -Encoding UTF8
        try {
            foreach ($name in $names) { Set-BupProgramFile (Join-Path $PackagePath $name) (Join-Path $InstallRoot $name) }
            $null = Test-BupUpdatePackage $InstallRoot
            Set-BupProgramFile $pendingPath (Join-Path $updates 'last-update.json')
            [IO.File]::Delete($pendingPath)
        }
        catch {
            $original = $_
            try { Restore-BupUpdateTransaction $InstallRoot $transaction; [IO.File]::Delete($pendingPath) }
            catch { throw "Update und automatischer Rollback fehlgeschlagen. pending.json bleibt zur Wiederherstellung erhalten. Update: $original / Rollback: $_" }
            throw "Update fehlgeschlagen; bisherige Version wiederhergestellt: $original"
        }
        [pscustomobject]@{ Status = 'Updated'; Version = $manifest.Version; Commit = $Commit; RollbackPath = $backup }
    }
    finally { if ($null -ne $programLock) { $programLock.Dispose() } }
}

function Undo-BupUpdate([string]$InstallRoot) {
    Assert-BupUpdateDirectory $InstallRoot
    $updates = Join-Path $InstallRoot '.updates'
    Assert-BupUpdateDirectory $updates
    $journal = Join-Path $updates 'pending.json'
    if (-not (Test-Path -LiteralPath $journal)) { $journal = Join-Path $updates 'last-update.json' }
    $transaction = Get-Content -LiteralPath $journal -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    Assert-BupProgramLock $InstallRoot
    $lock = [IO.File]::Open((Join-Path $InstallRoot '.program.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Restore-BupUpdateTransaction $InstallRoot $transaction
        [IO.File]::Delete($journal)
        # Bei Wiederherstellung eines abgebrochenen Updates keine veraltete Rueckgaengig-Aktion anbieten.
        $receipt = Join-Path $updates 'last-update.json'
        if (Test-Path -LiteralPath $receipt) { [IO.File]::Delete($receipt) }
        [pscustomobject]@{ Status = 'RolledBack'; Version = (Read-BupUpdateManifest (Join-Path $InstallRoot 'update-manifest.json')).Version }
    }
    finally { $lock.Dispose() }
}

function Invoke-BupUpdate {
    [CmdletBinding()]
    param([string]$RepositoryUrl, [string]$Ref = 'main', [string]$InstallRoot, [switch]$CheckOnly, [switch]$Rollback, [string]$ExpectedCommit = '', [int]$WaitForProcessId = 0)
    $ErrorActionPreference = 'Stop'
    if ($WaitForProcessId -eq $PID) { throw 'Der Updater kann nicht auf seinen eigenen Prozess warten.' }
    if ($WaitForProcessId -gt 0) {
        $process = Get-Process -Id $WaitForProcessId -ErrorAction SilentlyContinue
        if ($process -and -not $process.WaitForExit(120000)) { throw 'Die GUI wurde nach zwei Minuten noch nicht geschlossen.' }
    }
    if ($Rollback) { return (Undo-BupUpdate $InstallRoot) }
    $previousTls = [Net.ServicePointManager]::SecurityProtocol
    [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
    try {
        $info = Get-BupUpdateInfo $RepositoryUrl $Ref $InstallRoot $ExpectedCommit
        if ($CheckOnly -or -not $info.UpdateAvailable) {
            return ($info | Select-Object RepositoryUrl, Ref, Commit, Version, InstalledVersion, UpdateAvailable)
        }
        Assert-BupUpdateDirectory $InstallRoot
        $updates = Join-Path $InstallRoot '.updates'
        Assert-BupUpdateDirectory $updates
        $null = New-Item -ItemType Directory -Path $updates -Force
        $stage = Join-Path $updates ('stage-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $stage
        try {
            foreach ($entry in $info.Manifest.Files) {
                Invoke-WebRequest -UseBasicParsing -Uri ($info.RawRoot + '/' + $entry.Name) -OutFile (Join-Path $stage $entry.Name) -Headers @{ 'User-Agent' = 'UserProfileBackup-Updater' } -TimeoutSec 60 -ErrorAction Stop | Out-Null
            }
            $info.Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $stage 'update-manifest.json') -Encoding UTF8
            Install-BupUpdatePackage $InstallRoot $stage $info.Commit
        }
        finally {
            # Nur Dateien aus dem selbst erzeugten, flachen Staging-Verzeichnis entfernen.
            if (Test-Path -LiteralPath $stage) {
                foreach ($entry in Get-ChildItem -LiteralPath $stage -File -Force) { [IO.File]::Delete($entry.FullName) }
                [IO.Directory]::Delete($stage, $false)
            }
        }
    }
    finally { [Net.ServicePointManager]::SecurityProtocol = $previousTls }
}

if ($MyInvocation.InvocationName -ne '.') {
    $updateLog = Join-Path $env:LOCALAPPDATA 'UserProfileBackup\Updates'
    $null = New-Item -ItemType Directory -Path $updateLog -Force
    $logFile = Join-Path $updateLog ((Get-Date -Format 'yyyy-MM-dd') + '.log')
    try {
        if (-not $Rollback -and [string]::IsNullOrWhiteSpace($RepositoryUrl)) {
            $sourceFile = Join-Path (Split-Path -Parent $GuiSettingsPath) 'update-source.json'
            if (-not (Test-Path -LiteralPath $sourceFile)) { throw 'Noch keine Updatequelle gespeichert. -RepositoryUrl angeben oder die GUI unter Install > Updates verwenden.' }
            $source = Get-Content -LiteralPath $sourceFile -Raw | ConvertFrom-Json
            $RepositoryUrl = [string]$source.RepositoryUrl
            if (-not $PSBoundParameters.ContainsKey('Ref')) { $Ref = [string]$source.Ref }
        }
        $result = Invoke-BupUpdate -RepositoryUrl $RepositoryUrl -Ref $Ref -InstallRoot $InstallRoot -CheckOnly:$CheckOnly -Rollback:$Rollback -ExpectedCommit $ExpectedCommit -WaitForProcessId $WaitForProcessId
        if (-not $CheckOnly) { Add-Content -LiteralPath $logFile -Value ("$(Get-Date -Format o) " + ($result | ConvertTo-Json -Compress)) -Encoding UTF8 }
        $result
    }
    catch {
        Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format o) FEHLER: $_" -Encoding UTF8
        if ($ShowResult) {
            Add-Type -AssemblyName System.Windows.Forms
            $null = [Windows.Forms.MessageBox]::Show("Update fehlgeschlagen: $_`r`nProtokoll: $logFile", 'Benutzerprofil-Backup Update', 'OK', 'Error')
        }
        throw
    }
    finally {
        if ($RestartGUI -and -not $CheckOnly) {
            $gui = Join-Path $InstallRoot 'Start-BackupGUI.ps1'
            if ((Test-Path -LiteralPath $gui) -and -not (Test-Path -LiteralPath (Join-Path $InstallRoot '.updates\pending.json'))) {
                $launch = "& '" + $gui.Replace("'", "''") + "' -SettingsPath '" + $GuiSettingsPath.Replace("'", "''") + "'"
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launch))
                Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList "-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $encoded" -WindowStyle Hidden
            }
        }
    }
}
