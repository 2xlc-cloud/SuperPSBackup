#requires -Version 5.1
[CmdletBinding()]
param([switch]$Online)
$ErrorActionPreference = 'Stop'
$installerSource = Join-Path $PSScriptRoot 'FirstInstall.ps1'
$installerText = [IO.File]::ReadAllText($installerSource)
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('UserProfileBackup-FirstInstall-Test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $sandbox
$script:installChecks = 0; $testPassed = $false
function Assert-FirstInstall([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FIRSTINSTALL-TEST FEHLGESCHLAGEN: $Message" }
    $script:installChecks++
    Write-Output "OK $script:installChecks - $Message"
}
function New-FirstInstallFolder([string]$Name) {
    $path = Join-Path $sandbox $Name
    $null = New-Item -ItemType Directory -Path $path
    [IO.File]::Copy($installerSource,(Join-Path $path 'FirstInstall.ps1'))
    return $path
}
function Assert-InstallRejected([scriptblock]$Action,[string]$Message,[string]$Pattern = '') {
    $rejected = $false; $text = ''
    try { $null = & $Action 6>$null } catch { $rejected = $true; $text = [string]$_ }
    Assert-FirstInstall ($rejected -and ($Pattern -eq '' -or $text -match $Pattern)) $Message
}
function Get-InstallerFile([string]$Folder) { Join-Path $Folder 'FirstInstall.ps1' }

$tokens = $null; $errors = $null
$null = [Management.Automation.Language.Parser]::ParseInput($installerText,[ref]$tokens,[ref]$errors)
$bootstrapOk = ($errors.Count -eq 0)
if (-not $bootstrapOk) { throw 'FirstInstall.ps1 enthaelt Syntaxfehler.' }
. $installerSource -DefineOnly
. (Join-Path $PSScriptRoot 'Update-UserProfileBackup.ps1')
try {
    Assert-FirstInstall ($bootstrapOk -and $installerText -notmatch '[^\x00-\x7F]') 'FirstInstall.ps1 syntaktisch gueltig und reines ASCII (Windows PowerShell 5.1 sicher)'
    $package = Join-Path $sandbox 'package'
    $null = New-Item -ItemType Directory -Path $package
    foreach ($name in Get-BupRuntimeFiles) { [IO.File]::Copy((Join-Path $PSScriptRoot $name),(Join-Path $package $name)) }
    $null = & (Join-Path $PSScriptRoot 'New-UpdateManifest.ps1') -SourcePath $package -Version '1.0.3'
    $script:mockPackage = $package; $script:badHash = $false; $script:failDownload = $false; $script:downloads = 0
    # Netzwerk ersetzen
    function Invoke-RestMethod {
        [CmdletBinding()]
        param([string]$Uri,$Headers,[int]$TimeoutSec)
        if ($Uri.Contains('/commits/')) { return [pscustomobject]@{ sha = ('a' * 40) } }
        Get-Content -LiteralPath (Join-Path $script:mockPackage 'update-manifest.json') -Raw | ConvertFrom-Json
    }
    function Save-BupDownload([string]$Uri,[string]$Path,$Headers) {
        $script:downloads++
        if ($script:failDownload) { throw 'Test: Offline.' }
        [IO.File]::Copy((Join-Path $script:mockPackage $Uri.Split('/')[-1]),$Path)
        if ($script:badHash) { [IO.File]::AppendAllText($Path,'# tampered') }
    }
    # Systemabfragen ersetzen: gesundes System mit installiertem Git
    $script:os = [version]'10.0.26100'; $script:psExists = $true; $script:dotnet = 533320; $script:forms = $true
    $script:writable = $true; $script:freeMB = 5000; $script:networkOk = $true
    $script:gitPath = 'C:\Fake\Git\cmd\git.exe'; $script:gitAfterInstall = 'C:\Fake\Git\cmd\git.exe'
    $script:wingetPath = 'C:\Fake\winget.exe'; $script:wingetExit = 0; $script:wingetCalls = @()
    $script:interactive = $false; $script:confirmAnswer = $false; $script:confirmAsked = 0
    function Get-BupOsVersion { $script:os }
    function Get-BupWindowsPowerShellPath { if ($script:psExists) { Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' } else { 'C:\does-not-exist\powershell.exe' } }
    function Get-BupDotNetRelease { $script:dotnet }
    function Test-BupWindowsForms { $script:forms }
    function Test-BupWritable([string]$Directory) { $script:writable }
    function Get-BupFreeSpaceMB([string]$Path) { $script:freeMB }
    function Test-BupUrl([string]$Uri) { $script:networkOk }
    function Find-BupGit { $script:gitPath }
    function Get-BupWingetPath { $script:wingetPath }
    function Invoke-BupWinget([string[]]$Arguments) { $script:wingetCalls += ,$Arguments; $script:gitPath = $script:gitAfterInstall; return $script:wingetExit }
    function Update-BupSessionPath { }
    function Test-BupInteractive { $script:interactive }
    function Confirm-BupInstall([string]$Name) { $script:confirmAsked++; $script:confirmAnswer }
    function Reset-Mocks {
        $script:os = [version]'10.0.26100'; $script:psExists = $true; $script:dotnet = 533320; $script:forms = $true
        $script:writable = $true; $script:freeMB = 5000; $script:networkOk = $true
        $script:gitPath = 'C:\Fake\Git\cmd\git.exe'; $script:gitAfterInstall = 'C:\Fake\Git\cmd\git.exe'
        $script:wingetPath = 'C:\Fake\winget.exe'; $script:wingetExit = 0; $script:wingetCalls = @()
        $script:interactive = $false; $script:confirmAnswer = $false; $script:confirmAsked = 0
        $script:badHash = $false; $script:failDownload = $false; $script:downloads = 0
    }
    try {
        # --- Erstinstallation und Sonderzeichenpfad
        $installedRoot = New-FirstInstallFolder "offline [x] O'Brien & Co"
        $result = Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $installedRoot) -NoStart 6>$null
        Assert-FirstInstall ($result.Version -eq '1.0.3' -and $result.Files -eq 5) 'Installation nur mit den fuenf Laufzeit-Skripten'
        $manifest = Test-BupUpdatePackage $installedRoot
        Assert-FirstInstall ($manifest.InstallationType -eq 'Runtime' -and $manifest.Files.Count -eq 5 -and @(Get-ChildItem -LiteralPath $installedRoot -File).Count -eq 8) 'Runtime-Manifest, Installer und Verknuepfung ohne Entwicklungsdateien'
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut((Join-Path $installedRoot 'Benutzerprofil-Backup.lnk'))
        $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($link.Arguments -split ' ')[-1]))
        $null = [Management.Automation.Language.Parser]::ParseInput($command,[ref]$tokens,[ref]$errors)
        Assert-FirstInstall ($errors.Count -eq 0 -and $command.Contains("O''Brien & Co") -and $link.Arguments.Contains('-WindowStyle Hidden')) 'Startverknuepfung mit sicheren Sonderzeichenpfaden und versteckter Konsole'
        Assert-InstallRejected { Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $installedRoot) -NoStart } 'Erneute Erstinstallation ueberschreibt keine vorhandene Installation'

        # --- Zielordner
        Reset-Mocks; $script:gitPath = $null; $script:gitAfterInstall = 'C:\Fake\Git\cmd\git.exe'
        $nonempty = New-FirstInstallFolder 'nonempty'
        [IO.File]::WriteAllText((Join-Path $nonempty 'keep.txt'),'keep')
        Assert-InstallRejected { Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $nonempty) -NoStart -InstallMissing } 'Fremde Dateien im Zielordner verhindern Erstinstallation'
        Assert-FirstInstall ([IO.File]::ReadAllText((Join-Path $nonempty 'keep.txt')) -eq 'keep') 'Vorhandene fremde Datei unveraendert'
        Assert-FirstInstall ($script:wingetCalls.Count -eq 0 -and $script:downloads -eq 0) 'Bei ungueltigem Zielordner wird nichts nachinstalliert oder geladen'

        # --- Pflichtvoraussetzungen
        $cases = @(
            @{ Name = 'Windows 8.1'; Set = { $script:os = [version]'6.3.9600' }; Pattern = 'Windows 10' },
            @{ Name = 'fehlendes .NET Framework 4.7.2'; Set = { $script:dotnet = 394802 }; Pattern = '\.NET Framework' },
            @{ Name = 'fehlende Windows PowerShell'; Set = { $script:psExists = $false }; Pattern = 'Windows PowerShell' },
            @{ Name = 'nicht ladbare Windows Forms'; Set = { $script:forms = $false }; Pattern = 'Windows Forms' },
            @{ Name = 'nicht beschreibbarer Zielordner'; Set = { $script:writable = $false }; Pattern = 'beschreibbar' },
            @{ Name = 'zu wenig Speicherplatz'; Set = { $script:freeMB = 10 }; Pattern = 'frei' },
            @{ Name = 'fehlende GitHub-Verbindung'; Set = { $script:networkOk = $false }; Pattern = 'GitHub' }
        )
        $caseIndex = 0
        foreach ($case in $cases) {
            Reset-Mocks; & $case.Set
            $caseIndex++
            $folder = New-FirstInstallFolder ("required-$caseIndex")
            Assert-InstallRejected { Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $folder) -NoStart } ("Systemcheck weist ab: " + $case.Name) $case.Pattern
            Assert-FirstInstall ($script:downloads -eq 0 -and @(Get-ChildItem -LiteralPath $folder -Force).Count -eq 1) ("Nach Abweisung ($($case.Name)) nichts heruntergeladen oder angelegt")
        }

        # --- Git: fehlt, wird per winget nachinstalliert
        Reset-Mocks; $script:gitPath = $null
        $gitAuto = New-FirstInstallFolder 'git-auto'
        $result = Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $gitAuto) -NoStart -InstallMissing 6>$null
        $argLine = if ($script:wingetCalls.Count) { $script:wingetCalls[0] -join ' ' } else { '' }
        Assert-FirstInstall ($script:wingetCalls.Count -eq 1 -and $argLine -match 'install --id Git\.Git -e --source winget --silent --accept-package-agreements --accept-source-agreements' -and $result.InstalledComponents -eq 'git') 'Fehlendes Git wird mit -InstallMissing per winget nachinstalliert'
        Assert-FirstInstall ($result.Version -eq '1.0.3') 'Installation laeuft nach Git-Nachinstallation weiter'

        # --- Git: fehlt, nicht interaktiv und ohne -InstallMissing
        Reset-Mocks; $script:gitPath = $null; $script:interactive = $false
        $gitSkip = New-FirstInstallFolder 'git-noninteractive'
        $result = Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $gitSkip) -NoStart 6>$null
        Assert-FirstInstall ($script:wingetCalls.Count -eq 0 -and $result.Version -eq '1.0.3' -and [string]$result.InstalledComponents -eq '') 'Ohne Zustimmung wird Git nicht installiert, Programm trotzdem installiert'

        # --- Git: interaktive Rueckfrage
        Reset-Mocks; $script:gitPath = $null; $script:interactive = $true; $script:confirmAnswer = $true
        $gitYes = New-FirstInstallFolder 'git-yes'
        $result = Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $gitYes) -NoStart 6>$null
        Assert-FirstInstall ($script:confirmAsked -eq 1 -and $script:wingetCalls.Count -eq 1 -and $result.InstalledComponents -eq 'git') 'Interaktive Rueckfrage mit Ja installiert Git'
        Reset-Mocks; $script:gitPath = $null; $script:interactive = $true; $script:confirmAnswer = $false
        $gitNo = New-FirstInstallFolder 'git-no'
        $result = Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $gitNo) -NoStart 6>$null
        Assert-FirstInstall ($script:confirmAsked -eq 1 -and $script:wingetCalls.Count -eq 0 -and $result.Version -eq '1.0.3') 'Interaktive Rueckfrage mit Nein installiert Git nicht'

        # --- Git vorhanden / uebersprungen / Fehlerfaelle der Nachinstallation
        Reset-Mocks
        $gitHave = New-FirstInstallFolder 'git-present'
        $null = Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $gitHave) -NoStart -InstallMissing 6>$null
        Assert-FirstInstall ($script:wingetCalls.Count -eq 0 -and $script:confirmAsked -eq 0) 'Vorhandenes Git wird nicht erneut installiert'
        Reset-Mocks; $script:gitPath = $null
        $gitSkipOpt = New-FirstInstallFolder 'skip-optional'
        $null = Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $gitSkipOpt) -NoStart -InstallMissing -SkipOptional 6>$null
        Assert-FirstInstall ($script:wingetCalls.Count -eq 0) '-SkipOptional laesst Git unberuehrt'
        Reset-Mocks; $script:gitPath = $null; $script:wingetPath = $null
        $noWinget = New-FirstInstallFolder 'no-winget'
        $result = Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $noWinget) -NoStart -InstallMissing -WarningAction SilentlyContinue 6>$null
        Assert-FirstInstall ($result.Version -eq '1.0.3' -and [string]$result.InstalledComponents -eq '') 'Ohne winget scheitert nur die optionale Git-Installation, nicht das Programm'
        Reset-Mocks; $script:gitPath = $null; $script:wingetExit = 1
        $wingetFail = New-FirstInstallFolder 'winget-fail'
        $result = Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $wingetFail) -NoStart -InstallMissing -WarningAction SilentlyContinue 6>$null
        Assert-FirstInstall ($script:wingetCalls.Count -eq 1 -and $result.Version -eq '1.0.3' -and [string]$result.InstalledComponents -eq '') 'winget-Fehlercode wird gemeldet, Programminstallation laeuft weiter'
        Reset-Mocks; $script:gitPath = $null; $script:gitAfterInstall = $null
        $gitMissingAfter = New-FirstInstallFolder 'git-not-found-after'
        $result = Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $gitMissingAfter) -NoStart -InstallMissing -WarningAction SilentlyContinue 6>$null
        Assert-FirstInstall ([string]$result.InstalledComponents -eq '') 'Git nach winget nicht auffindbar wird nicht als installiert gemeldet'

        # --- nur Systemcheck
        Reset-Mocks; $script:gitPath = $null
        $checkOnly = New-FirstInstallFolder 'check-only'
        $checkResult = Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $checkOnly) -CheckOnly -InstallMissing 6>$null
        Assert-FirstInstall ($checkResult.CheckOnly -and $checkResult.Passed -and $script:wingetCalls.Count -eq 0 -and $script:downloads -eq 0 -and @(Get-ChildItem -LiteralPath $checkOnly -Force).Count -eq 1) '-CheckOnly installiert nichts und laedt nichts'
        Reset-Mocks; $script:dotnet = 0
        $checkFail = New-FirstInstallFolder 'check-only-fail'
        Assert-InstallRejected { Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $checkFail) -CheckOnly } '-CheckOnly meldet fehlende Pflichtvoraussetzung als Fehler' '\.NET'

        # --- Download-Fehler
        Reset-Mocks
        $tampered = New-FirstInstallFolder 'tampered'
        $script:badHash = $true
        Assert-InstallRejected { Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $tampered) -NoStart } 'Falsche Download-Pruefsumme verhindert Installation' 'Pruefsumme'
        Assert-FirstInstall (@(Get-ChildItem -LiteralPath $tampered -Force).Count -eq 1) 'Bei Pruefsummenfehler bleibt ausschliesslich der Installer erhalten'
        $script:badHash = $false; $script:failDownload = $true
        $offline = New-FirstInstallFolder 'network-error'
        Assert-InstallRejected { Invoke-BupFirstInstall -InstallerFile (Get-InstallerFile $offline) -NoStart } 'Netzwerkfehler sauber abgefangen'
        Assert-FirstInstall (@(Get-ChildItem -LiteralPath $offline -Force).Count -eq 1) 'Unvollstaendige Downloads entfernt'
    }
    finally {
        foreach ($fn in 'Invoke-RestMethod','Save-BupDownload','Get-BupOsVersion','Get-BupWindowsPowerShellPath','Get-BupDotNetRelease','Test-BupWindowsForms','Test-BupWritable','Get-BupFreeSpaceMB','Test-BupUrl','Find-BupGit','Get-BupWingetPath','Invoke-BupWinget','Update-BupSessionPath','Test-BupInteractive','Confirm-BupInstall','Reset-Mocks') {
            Remove-Item -LiteralPath "Function:\$fn" -ErrorAction SilentlyContinue
        }
    }

    if ($Online) {
        . $installerSource -DefineOnly   # echte Systemabfragen wiederherstellen
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $realRoot = New-FirstInstallFolder 'realcheck'
        $real = @(Get-BupSystemCheck -Root $realRoot)
        $failedReal = @($real | Where-Object { $_.Required -and -not $_.Ok })
        Assert-FirstInstall ($real.Count -ge 8 -and $failedReal.Count -eq 0) ('Echter Systemcheck dieses Rechners besteht alle Pflichtpunkte (' + (($real | ForEach-Object { "$($_.Id)=$($_.Ok)" }) -join ', ') + ')')
        Remove-Item -LiteralPath (Join-Path $realRoot 'FirstInstall.ps1')

        $checkRoot = New-FirstInstallFolder 'online-checkonly'
        $out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Get-InstallerFile $checkRoot) -CheckOnly -NoPause 2>&1 | Out-String
        Assert-FirstInstall ($LASTEXITCODE -eq 0 -and $out -match 'Systemcheck bestanden' -and @(Get-ChildItem -LiteralPath $checkRoot -Force).Count -eq 1) 'Echtes FirstInstall.ps1 -CheckOnly in Windows PowerShell 5.1'

        $onlineRoot = New-FirstInstallFolder "online [x] O'Brien & Co"
        $out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Get-InstallerFile $onlineRoot) -NoStart -NoPause 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw $out }
        Assert-FirstInstall ($LASTEXITCODE -eq 0 -and $out -match 'Installation erfolgreich') 'Echtes FirstInstall.ps1 installiert von GitHub'
        $onlineManifest = Test-BupUpdatePackage $onlineRoot
        Assert-FirstInstall ($onlineManifest.InstallationType -eq 'Runtime' -and $onlineManifest.Files.Count -eq 5 -and @(Get-ChildItem -LiteralPath $onlineRoot -File).Count -eq 8) 'Online-Erstinstallation enthaelt genau Runtime, Manifest, Verknuepfung und Installer'
        & $ps -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File (Join-Path $onlineRoot 'Start-BackupGUI.ps1') -SettingsPath (Join-Path $sandbox 'gui.json') -NoShow
        Assert-FirstInstall ($LASTEXITCODE -eq 0) 'Minimal installierte GUI startet ohne Entwicklungsdateien'
        $src = Join-Path $sandbox 'source'; $target = Join-Path $sandbox 'target'
        foreach ($path in @($src,$target)) { $null = New-Item -ItemType Directory -Path $path }
        [IO.File]::WriteAllText((Join-Path $src 'sample.txt'),'first-install-backup')
        . (Join-Path $onlineRoot 'Backup-UserProfile.ps1')
        $backupResult = Invoke-UserProfileBackup -BackupRoot $target -LogRoot (Join-Path $sandbox 'logs') -SourceFolders @{ Documents = $src }
        Assert-FirstInstall ($backupResult.Status -eq 'Complete') 'Minimal installierter Backupablauf erfolgreich'
        . (Join-Path $onlineRoot 'Restore-UserProfile.ps1') -SnapshotPath unused -DestinationPath unused
        $restored = Invoke-UserProfileRestore -SnapshotPath $backupResult.SnapshotPath -DestinationPath (Join-Path $sandbox 'restored') -NonInteractive
        Assert-FirstInstall ($restored.Errors -eq 0 -and [IO.File]::ReadAllText((Join-Path $sandbox 'restored\Documents\sample.txt')) -eq 'first-install-backup') 'Minimal installierte Wiederherstellung erfolgreich'
        # Einen aelteren Runtime-Stand simulieren und den echten Updateweg pruefen.
        [IO.File]::AppendAllText((Join-Path $onlineRoot 'Start-BackupGUI.ps1'),"`r`n# older runtime fixture`r`n")
        $onlineManifest.Version = '1.0.2'
        $guiEntry = @($onlineManifest.Files | Where-Object Name -eq 'Start-BackupGUI.ps1')[0]
        $guiEntry.Length = (Get-Item -LiteralPath (Join-Path $onlineRoot $guiEntry.Name)).Length
        $guiEntry.SHA256 = (Get-BupSha256 (Join-Path $onlineRoot $guiEntry.Name))
        $onlineManifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $onlineRoot 'update-manifest.json') -Encoding UTF8
        $updated = & (Join-Path $onlineRoot 'Update-UserProfileBackup.ps1') -RepositoryUrl 'https://github.com/2xlc-cloud/UserProfileBackup' -InstallRoot $onlineRoot
        $currentManifest = Test-BupUpdatePackage $onlineRoot
        Assert-FirstInstall ($updated.Status -eq 'Updated' -and $currentManifest.InstallationType -eq 'Runtime' -and $currentManifest.Files.Count -eq 5) 'Echtes Selbstupdate bleibt bei fuenf Runtime-Skripten'
        Assert-FirstInstall (@(Get-ChildItem -LiteralPath $onlineRoot -Filter 'Test-*.ps1').Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $onlineRoot 'New-UpdateManifest.ps1'))) 'Selbstupdate laedt keine Entwicklungs- oder Testdateien nach'
        $undo = & (Join-Path $onlineRoot 'Update-UserProfileBackup.ps1') -InstallRoot $onlineRoot -Rollback
        Assert-FirstInstall ($undo.Version -eq '1.0.2' -and (Read-BupUpdateManifest (Join-Path $onlineRoot 'update-manifest.json')).InstallationType -eq 'Runtime') 'Rollback funktioniert auch in Minimalinstallationen'
    }
    $testPassed = $true
    Write-Output "ERFOLGREICH: $script:installChecks FirstInstall-Pruefungen. Online=$Online"
}
finally {
    if ($testPassed) {
        . (Join-Path $PSScriptRoot 'Backup-UserProfile.ps1')
        $resolved = [IO.Path]::GetFullPath($sandbox)
        if (-not (Test-BupChild $resolved ([IO.Path]::GetTempPath())) -or (Split-Path -Leaf $resolved) -notmatch '^UserProfileBackup-FirstInstall-Test-[a-f0-9]{32}$') { throw 'Unsicherer FirstInstall-Testpfad.' }
        for ($try = 1; $try -le 5; $try++) { try { Remove-BupTree $resolved; break } catch { if ($try -eq 5) { throw }; Start-Sleep -Seconds 2 } }
    }
    else { Write-Output "Testdaten: $sandbox" }
}
