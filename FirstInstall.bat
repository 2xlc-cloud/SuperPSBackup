@echo off
setlocal
set "UPB_INSTALLER=%~f0"
set "UPB_NO_START="
set "UPB_NO_PAUSE="
:arguments
if "%~1"=="" goto install
if /I "%~1"=="--no-start" set "UPB_NO_START=1"
if /I "%~1"=="--no-pause" set "UPB_NO_PAUSE=1"
shift
goto arguments
:install
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$text=[IO.File]::ReadAllText($env:UPB_INSTALLER); $mark='#==POWERSHELL==#'; & ([scriptblock]::Create($text.Substring($text.LastIndexOf($mark)+$mark.Length)))"
set "UPB_RESULT=%ERRORLEVEL%"
if "%UPB_RESULT%"=="0" goto finished
echo.
echo Installation fehlgeschlagen. Vorhandene Dateien werden nicht ueberschrieben.
if not defined UPB_NO_PAUSE pause
:finished
exit /b %UPB_RESULT%
#==POWERSHELL==#
param([switch]$DefineOnly)

function Get-BupSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') }
    finally { $stream.Dispose(); $sha.Dispose() }
}
function Invoke-BupFirstInstall {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallerFile, [switch]$NoStart)
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
    if (-not (Test-Path -LiteralPath $InstallerFile -PathType Leaf)) { throw 'FirstInstall.bat fehlt.' }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $lockId = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($root.ToUpperInvariant())))).Replace('-','') }
    finally { $hash.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Local\UserProfileBackup-FirstInstall-' + $lockId))
    $ownsMutex = $false; $stage = $null
    $createdFiles = New-Object 'System.Collections.Generic.List[string]'
    $installed = $false
    $oldTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw 'In diesem Ordner laeuft bereits eine Installation.' }
        $otherFiles = @(Get-ChildItem -LiteralPath $root -Force | Where-Object { $_.FullName -ne [IO.Path]::GetFullPath($InstallerFile) })
        if ($otherFiles.Count) { throw 'Bitte FirstInstall.bat allein in einen leeren Ordner legen. Fuer bestehende Installationen die Updatefunktion verwenden.' }
        [Net.ServicePointManager]::SecurityProtocol = $oldTls -bor [Net.SecurityProtocolType]::Tls12
        $runtimeNames = @('Backup-UserProfile.ps1','Install-BackupTask.ps1','Restore-UserProfile.ps1','Start-BackupGUI.ps1','Update-UserProfileBackup.ps1')
        $headers = @{ 'User-Agent' = 'UserProfileBackup-FirstInstall' }
        Write-Host 'Lade UserProfileBackup von GitHub ...'
        $commit = Invoke-RestMethod -Uri 'https://api.github.com/repos/2xlc-cloud/UserProfileBackup/commits/main' -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        if ($commit.sha -notmatch '^[a-fA-F0-9]{40}$') { throw 'Ungueltige GitHub-Commit-ID.' }
        $rawRoot = 'https://raw.githubusercontent.com/2xlc-cloud/UserProfileBackup/' + $commit.sha
        $manifest = Invoke-RestMethod -Uri ($rawRoot + '/update-manifest.json') -Headers $headers -TimeoutSec 30 -ErrorAction Stop
        if ($manifest.Format -ne 1 -or [version]$manifest.Version -lt [version]'1.0.3') { throw 'Das Repository enthaelt noch keine geeignete Runtime-Version ab 1.0.3.' }
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
            Invoke-WebRequest -UseBasicParsing -Uri ($rawRoot + '/' + $entry.Name) -OutFile $file -Headers $headers -TimeoutSec 60 -ErrorAction Stop | Out-Null
            if ((Get-Item -LiteralPath $file).Length -ne [long]$entry.Length -or (Get-BupSha256 $file) -ne $entry.SHA256) { throw "Pruefsummenfehler: $($entry.Name)" }
            $tokens = $null; $errors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
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
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $guiCommand = "& '" + (Join-Path $root 'Start-BackupGUI.ps1').Replace("'","''") + "'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($guiCommand))
        $arguments = "-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand $encoded"
        $shortcutPath = Join-Path $root 'Benutzerprofil-Backup.lnk'
        if (Test-Path -LiteralPath $shortcutPath) { throw 'Startverknuepfung existiert unerwartet bereits.' }
        $createdFiles.Add($shortcutPath)
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = $exe; $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = $root; $shortcut.WindowStyle = 7
        $shortcut.Description = 'Benutzerprofil-Backup starten'
        $shortcut.Save()
        if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) { throw 'Startverknuepfung konnte nicht angelegt werden.' }
        $installed = $true
        Write-Host ("Installation erfolgreich. Version: " + $manifest.Version)
        Write-Host 'Start kuenftig per Benutzerprofil-Backup.lnk. Sicherungsziel in der GUI einrichten.'
        if (-not $NoStart) {
            try { Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden }
            catch { Write-Warning "Programm wurde installiert, konnte aber nicht gestartet werden: $_" }
        }
        [pscustomobject]@{ Version = $manifest.Version; Commit = $commit.sha; InstallationType = 'Runtime'; Files = $runtimeNames.Count; Path = $root }
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
    try { Invoke-BupFirstInstall -InstallerFile $env:UPB_INSTALLER -NoStart:($env:UPB_NO_START -eq '1'); exit 0 }
    catch { Write-Host ("FEHLER: " + $_) -ForegroundColor Red; exit 1 }
}
