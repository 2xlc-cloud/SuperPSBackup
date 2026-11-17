#requires -Version 5.1
<#
.SYNOPSIS
Erstinstallation von SuperPSBackup (Runtime) aus GitHub.

.DESCRIPTION
Pruefung des Zielordners und des Systems, optionale Nachinstallation fehlender Komponenten
(z. B. Git ueber winget), Download der fuenf Programmdateien mit SHA-256-Pruefung und
Anlegen der Startverknuepfung. Bestehende Dateien werden nie ueberschrieben.

Start:  powershell -NoProfile -ExecutionPolicy Bypass -File .\FirstInstall.ps1
Die Datei muss allein in einem leeren Zielordner liegen.

.PARAMETER CheckOnly
Nur den Systemcheck ausfuehren, nichts installieren.
.PARAMETER InstallMissing
Fehlende nachinstallierbare Komponenten (Git) ohne Rueckfrage per winget installieren.
.PARAMETER SkipOptional
Empfohlene, aber nicht notwendige Komponenten weder pruefen noch anbieten.
.PARAMETER NoStart
Programm nach der Installation nicht starten.
.PARAMETER NoPause
Am Ende nicht auf eine Taste warten.
#>
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$InstallMissing,
    [switch]$SkipOptional,
    [switch]$NoStart,
    [switch]$NoPause,
    [switch]$DefineOnly
)

$script:BupRepository = '2xlc-cloud/SuperPSBackup'
$script:BupMinimumVersion = '1.1.0'
$script:BupMinimumDotNetRelease = 461808   # .NET Framework 4.7.2
$script:BupMinimumFreeMB = 100

# ---------------------------------------------------------------------------
# Kleine Systemabfragen. Jede ist eine eigene Funktion, damit Tests sie ersetzen koennen.
# ---------------------------------------------------------------------------
function Get-BupOsVersion { [Environment]::OSVersion.Version }
function Get-BupWindowsPowerShellPath { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
function Get-BupDotNetRelease {
    try { [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction Stop).Release }
    catch { 0 }
}
function Test-BupWindowsForms {
    try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; return $true } catch { return $false }
}
function Test-BupUrl([string]$Uri) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $request = [Net.WebRequest]::Create($Uri)
        $request.Timeout = 15000
        $request.UserAgent = 'SuperPSBackup-FirstInstall'
        $response = $request.GetResponse()
        $response.Close()
        return $true
    }
    catch [Net.WebException] { return ($null -ne $_.Exception.Response) }   # HTTP-Fehlercode heisst: Server erreichbar
    catch { return $false }
}
function Get-BupFreeSpaceMB([string]$Path) {
    try {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path))
        if ($root.StartsWith('\\')) { return -1 }
        return [long]([IO.DriveInfo]::new($root).AvailableFreeSpace / 1MB)
    }
    catch { return -1 }
}
function Test-BupWritable([string]$Directory) {
    $probe = Join-Path $Directory ('.write-test-' + [guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($probe,'x'); [IO.File]::Delete($probe); return $true }
    catch { return $false }
}
function Find-BupCommand([string]$Name) {
    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}
function Find-BupGit {
    $found = Find-BupCommand 'git'
    if ($found) { return $found }
    foreach ($candidate in @((Join-Path $env:ProgramFiles 'Git\cmd\git.exe'), (Join-Path $env:LocalAppData 'Programs\Git\cmd\git.exe'))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}
function Get-BupWingetPath { Find-BupCommand 'winget' }
function Invoke-BupWinget([string[]]$Arguments) {
    $winget = Get-BupWingetPath
    if (-not $winget) { throw 'winget ist nicht verfuegbar.' }
    $process = Start-Process -FilePath $winget -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    return $process.ExitCode
}
function Update-BupSessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path','Machine')
    $user = [Environment]::GetEnvironmentVariable('Path','User')
    $env:Path = (@($machine,$user) | Where-Object { $_ }) -join ';'
}
function Test-BupInteractive {
    return ([Environment]::UserInteractive -and -not ([Environment]::GetCommandLineArgs() -contains '-NonInteractive'))
}
function Confirm-BupInstall([string]$Name) {
    $answer = Read-Host "$Name jetzt per winget installieren? (J/N)"
    return ($answer -match '^(j|ja|y|yes)$')
}
function Save-BupDownload([string]$Uri,[string]$Path,$Headers) {
    # WebClient nimmt Pfade woertlich; Invoke-WebRequest -OutFile wertet [x] als Platzhalter aus.
    $client = New-Object Net.WebClient
    try {
        foreach ($key in $Headers.Keys) { $client.Headers.Add([string]$key,[string]$Headers[$key]) }
        $client.DownloadFile($Uri,$Path)
    }
    finally { $client.Dispose() }
}
function Get-BupSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') }
    finally { $stream.Dispose(); $sha.Dispose() }
}

# ---------------------------------------------------------------------------
# Systemcheck und Komponenten
# ---------------------------------------------------------------------------
function New-BupCheck([string]$Id,[string]$Name,[bool]$Required,[bool]$Ok,[string]$Detail,[bool]$Installable = $false) {
    [pscustomobject]@{ Id = $Id; Name = $Name; Required = $Required; Ok = $Ok; Detail = $Detail; Installable = $Installable }
}

function Get-BupSystemCheck {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [switch]$SkipOptional)
    $checks = New-Object 'System.Collections.Generic.List[object]'

    $os = Get-BupOsVersion
    $checks.Add((New-BupCheck 'os' 'Windows 10 oder neuer' $true ($os.Major -ge 10) ("Version $os")))

    $psPath = Get-BupWindowsPowerShellPath
    $psOk = (Test-Path -LiteralPath $psPath -PathType Leaf)
    $checks.Add((New-BupCheck 'powershell' 'Windows PowerShell 5.1' $true $psOk $(if ($psOk) { $psPath } else { 'powershell.exe fehlt' })))

    $release = Get-BupDotNetRelease
    $checks.Add((New-BupCheck 'dotnet' '.NET Framework 4.7.2 oder neuer' $true ($release -ge $script:BupMinimumDotNetRelease) $(if ($release) { "Release $release" } else { 'nicht gefunden' })))

    $forms = Test-BupWindowsForms
    $checks.Add((New-BupCheck 'forms' 'Windows Forms (Programmoberflaeche)' $true $forms $(if ($forms) { 'verfuegbar' } else { 'System.Windows.Forms nicht ladbar' })))

    $writable = Test-BupWritable $Root
    $checks.Add((New-BupCheck 'writable' 'Zielordner beschreibbar' $true $writable $Root))

    $free = Get-BupFreeSpaceMB $Root
    $checks.Add((New-BupCheck 'space' "Mindestens $script:BupMinimumFreeMB MB frei" $true ($free -lt 0 -or $free -ge $script:BupMinimumFreeMB) $(if ($free -lt 0) { 'nicht ermittelbar (Netzwerkpfad)' } else { "$free MB frei" })))

    $apiOk = Test-BupUrl 'https://api.github.com/'
    $rawOk = Test-BupUrl 'https://raw.githubusercontent.com/'
    $checks.Add((New-BupCheck 'network' 'Verbindung zu GitHub (HTTPS)' $true ($apiOk -and $rawOk) $(if ($apiOk -and $rawOk) { 'api.github.com und raw.githubusercontent.com erreichbar' } else { 'GitHub nicht erreichbar (Internet, Proxy oder Firewall pruefen)' })))

    if (-not $SkipOptional) {
        $git = Find-BupGit
        $detail = if ($git) { $git } else { 'nicht installiert (fuer den Betrieb nicht noetig, nur zum Klonen/Entwickeln)' }
        $checks.Add((New-BupCheck 'git' 'Git (empfohlen)' $false ([bool]$git) $detail $true))
    }
    return ,$checks.ToArray()
}

function Write-BupCheckResult($Checks) {
    foreach ($check in $Checks) {
        $state = if ($check.Ok) { '[ OK ]' } elseif ($check.Required) { '[FEHLT]' } else { '[HINWEIS]' }
        $color = if ($check.Ok) { 'Green' } elseif ($check.Required) { 'Red' } else { 'Yellow' }
        Write-Host ("{0,-9}{1} - {2}" -f $state,$check.Name,$check.Detail) -ForegroundColor $color
    }
}

function Install-BupComponent([Parameter(Mandatory)][string]$Id) {
    switch ($Id) {
        'git' {
            if (-not (Get-BupWingetPath)) { throw 'winget (App-Installer) ist nicht verfuegbar. Git bitte manuell von https://git-scm.com/download/win installieren.' }
            Write-Host 'Installiere Git ueber winget (ggf. erscheint eine Windows-Rueckfrage) ...'
            $code = Invoke-BupWinget @('install','--id','Git.Git','-e','--source','winget','--silent','--accept-package-agreements','--accept-source-agreements')
            if ($code -ne 0 -and $code -ne -1978335189) { throw "winget meldete Fehlercode $code bei der Git-Installation." }
            Update-BupSessionPath
            if (-not (Find-BupGit)) { throw 'Git wurde installiert, ist aber in dieser Sitzung noch nicht auffindbar. Bitte danach ein neues Fenster oeffnen.' }
        }
        default { throw "Unbekannte Komponente: $Id" }
    }
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------
function Invoke-BupFirstInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallerFile,
        [switch]$NoStart, [switch]$CheckOnly, [switch]$InstallMissing, [switch]$SkipOptional
    )
    $ErrorActionPreference = 'Stop'
    $root = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($InstallerFile))
    $cursor = $root
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Installationsordner darf keine Verknuepfung sein.' }
        $parent = [IO.Path]::GetDirectoryName($cursor.TrimEnd('\'))
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    if (-not (Test-Path -LiteralPath $InstallerFile -PathType Leaf)) { throw 'FirstInstall.ps1 fehlt.' }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $lockId = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToUpperInvariant())))).Replace('-','') }
    finally { $hash.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Local\SuperPSBackup-FirstInstall-' + $lockId))
    $ownsMutex = $false; $stage = $null
    $createdFiles = New-Object 'System.Collections.Generic.List[string]'
    $installed = $false
    $oldTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw 'In diesem Ordner laeuft bereits eine Installation.' }

        # 1. Zielordner pruefen, bevor irgendetwas auf dem System installiert wird.
        $otherFiles = @(Get-ChildItem -LiteralPath $root -Force | Where-Object { $_.FullName -ne [IO.Path]::GetFullPath($InstallerFile) })
        if ($otherFiles.Count) { throw 'Bitte FirstInstall.ps1 allein in einen leeren Ordner legen. Fuer bestehende Installationen die Updatefunktion verwenden.' }

        # 2. Systemcheck
        Write-Host 'Systemcheck:'
        $checks = Get-BupSystemCheck -Root $root -SkipOptional:$SkipOptional
        Write-BupCheckResult $checks

        # 3. Fehlende Komponenten nachinstallieren
        $installedComponents = @()
        foreach ($check in @($checks | Where-Object { -not $_.Ok -and $_.Installable })) {
            if ($CheckOnly) { continue }
            $doInstall = $false
            if ($InstallMissing) { $doInstall = $true }
            elseif (Test-BupInteractive) { $doInstall = [bool](Confirm-BupInstall $check.Name) }
            if (-not $doInstall) { Write-Host "$($check.Name) wird nicht installiert."; continue }
            try { Install-BupComponent $check.Id; $installedComponents += $check.Id; $check.Ok = $true; $check.Detail = 'nachinstalliert' }
            catch {
                if ($check.Required) { throw }
                Write-Warning "$($check.Name) konnte nicht nachinstalliert werden: $_"
            }
        }

        $failed = @($checks | Where-Object { $_.Required -and -not $_.Ok })
        if ($failed.Count) { throw ('Systemvoraussetzungen nicht erfuellt: ' + (($failed | ForEach-Object { $_.Name }) -join '; ')) }
        if ($CheckOnly) {
            Write-Host 'Systemcheck bestanden. Es wurde nichts installiert.'
            return [pscustomobject]@{ CheckOnly = $true; Passed = $true; Checks = $checks }
        }

        # 4. Download und Installation
        [Net.ServicePointManager]::SecurityProtocol = $oldTls -bor [Net.SecurityProtocolType]::Tls12
        $runtimeNames = @('Backup-UserProfile.ps1','Install-BackupTask.ps1','Restore-UserProfile.ps1','Start-BackupGUI.ps1','Update-UserProfileBackup.ps1')
        $headers = @{ 'User-Agent' = 'SuperPSBackup-FirstInstall' }
        Write-Host 'Lade SuperPSBackup von GitHub ...'
        $commit = Invoke-RestMethod -Uri "https://api.github.com/repos/$script:BupRepository/commits/main" -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        if ($commit.sha -notmatch '^[a-fA-F0-9]{40}$') { throw 'Ungueltige GitHub-Commit-ID.' }
        $rawRoot = "https://raw.githubusercontent.com/$script:BupRepository/" + $commit.sha
        $manifest = Invoke-RestMethod -Uri ($rawRoot + '/update-manifest.json') -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        if ($manifest.Format -ne 1 -or [version]$manifest.Version -lt [version]$script:BupMinimumVersion) { throw "Das Repository enthaelt noch keine geeignete Runtime-Version ab $script:BupMinimumVersion." }
        $selected = @()
        foreach ($name in $runtimeNames) {
            $entries = @($manifest.Files | Where-Object { $_.Name -ceq $name })
            if ($entries.Count -ne 1 -or $entries[0].SHA256 -notmatch '^[a-fA-F0-9]{64}$' -or [long]$entries[0].Length -lt 1 -or [long]$entries[0].Length -gt 5MB) { throw "Fehlender oder ungueltiger Programmeintrag: $name" }
            $selected += $entries[0]
        }
        $stage = Join-Path $root ('.firstinstall-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $stage -ErrorAction Stop
        foreach ($entry in $selected) {
            $file = Join-Path $stage $entry.Name
            Save-BupDownload ($rawRoot + '/' + $entry.Name) $file $headers
            if ((Get-Item -LiteralPath $file).Length -ne [long]$entry.Length -or (Get-BupSha256 $file) -ne $entry.SHA256) { throw "Pruefsummenfehler: $($entry.Name)" }
            $tokens = $null; $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($file),[ref]$tokens,[ref]$errors)
            if ($errors.Count) { throw "PowerShell-Syntaxfehler: $($entry.Name)" }
        }
        $runtime = [pscustomobject]@{ Format = 1; Version = $manifest.Version; InstallationType = 'Runtime'; Files = $selected }
        $json = ($runtime | ConvertTo-Json -Depth 6).Replace("`r`n","`n") + "`n"
        [IO.File]::WriteAllText((Join-Path $stage 'update-manifest.json'), $json, (New-Object Text.UTF8Encoding($false)))
        foreach ($name in ($runtimeNames + @('update-manifest.json'))) {
            $destination = Join-Path $root $name
            [IO.File]::Move((Join-Path $stage $name),$destination)
            $createdFiles.Add($destination)
        }
        $exe = Get-BupWindowsPowerShellPath
        $guiCommand = "& '" + (Join-Path $root 'Start-BackupGUI.ps1').Replace("'","''") + "'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($guiCommand))
        $arguments = "-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $shortcutPath = Join-Path $root 'SuperPSBackup.lnk'
        if (Test-Path -LiteralPath $shortcutPath) { throw 'Startverknuepfung existiert unerwartet bereits.' }
        $createdFiles.Add($shortcutPath)
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $exe; $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $root; $shortcut.WindowStyle = 7
        $shortcut.Description = 'SuperPSBackup starten'
        $shortcut.Save()
        if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) { throw 'Startverknuepfung konnte nicht angelegt werden.' }
        $installed = $true
        Write-Host ("Installation erfolgreich. Version: " + $manifest.Version)
        Write-Host 'Start kuenftig per SuperPSBackup.lnk. Sicherungsziel in der GUI einrichten.'
        if (-not $NoStart) {
            try { Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden }
            catch { Write-Warning "Programm wurde installiert, konnte aber nicht gestartet werden: $_" }
        }
        [pscustomobject]@{ Version = $manifest.Version; Commit = $commit.sha; InstallationType = 'Runtime'; Files = $runtimeNames.Count; Path = $root; InstalledComponents = ($installedComponents -join ',') }
    }
    finally {
        if (-not $installed) { foreach ($file in $createdFiles) { if (Test-Path -LiteralPath $file -PathType Leaf) { [IO.File]::Delete($file) } } }
        if ($null -ne $stage -and (Test-Path -LiteralPath $stage)) {
            foreach ($file in Get-ChildItem -LiteralPath $stage -File -Force) { [IO.File]::Delete($file.FullName) }
            [IO.Directory]::Delete($stage,$false)
        }
        [Net.ServicePointManager]::SecurityProtocol = $oldTls
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if (-not $DefineOnly) {
    $exitCode = 0
    try {
        $result = Invoke-BupFirstInstall -InstallerFile $PSCommandPath -NoStart:$NoStart -CheckOnly:$CheckOnly -InstallMissing:$InstallMissing -SkipOptional:$SkipOptional
        if (-not $CheckOnly) { $result | Format-List | Out-Host }
    }
    catch {
        Write-Host ("FEHLER: " + $_) -ForegroundColor Red
        Write-Host 'Installation fehlgeschlagen. Vorhandene Dateien werden nicht ueberschrieben.'
        $exitCode = 1
    }
    if (-not $NoPause -and (Test-BupInteractive)) {
        Write-Host 'Beliebige Taste zum Beenden ...'
        try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
    }
    exit $exitCode
}
