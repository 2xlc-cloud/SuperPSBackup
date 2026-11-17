#requires -Version 5.1
[CmdletBinding()]
param([switch]$Online)
$ErrorActionPreference = 'Stop'
$installerSource = Join-Path $PSScriptRoot 'FirstInstall.bat'
$installerText = [IO.File]::ReadAllText($installerSource)
$marker = '#==POWERSHELL==#'
$bootstrapText = $installerText.Substring($installerText.LastIndexOf($marker) + $marker.Length)
$bootstrap = [scriptblock]::Create($bootstrapText)
. $bootstrap -DefineOnly
. (Join-Path $PSScriptRoot 'Update-UserProfileBackup.ps1')
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
    [IO.File]::Copy($installerSource,(Join-Path $path 'FirstInstall.bat'))
    return $path
}
function Assert-InstallRejected([scriptblock]$Action,[string]$Message) {
    $rejected = $false
    try { $null = & $Action } catch { $rejected = $true }
    Assert-FirstInstall $rejected $Message
}
try {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($bootstrapText,[ref]$tokens,[ref]$errors)
    Assert-FirstInstall ($errors.Count -eq 0) 'Eingebetteter PowerShell-Bootstrap syntaktisch gueltig'
    $package = Join-Path $sandbox 'package'
    $null = New-Item -ItemType Directory -Path $package
    foreach ($name in Get-BupRuntimeFiles) { [IO.File]::Copy((Join-Path $PSScriptRoot $name),(Join-Path $package $name)) }
    $null = & (Join-Path $PSScriptRoot 'New-UpdateManifest.ps1') -SourcePath $package -Version '1.0.3'
    $script:mockPackage = $package; $script:badHash = $false; $script:failDownload = $false
    function Invoke-RestMethod {
        [CmdletBinding()]
        param([string]$Uri,$Headers,[int]$TimeoutSec)
        if ($Uri.Contains('/commits/')) { return [pscustomobject]@{ sha = ('a' * 40) } }
        Get-Content -LiteralPath (Join-Path $script:mockPackage 'update-manifest.json') -Raw | ConvertFrom-Json
    }
    function Invoke-WebRequest {
        [CmdletBinding()]
        param([switch]$UseBasicParsing,[string]$Uri,[string]$OutFile,$Headers,[int]$TimeoutSec)
        if ($script:failDownload) { throw 'Test: Offline.' }
        [IO.File]::Copy((Join-Path $script:mockPackage $Uri.Split('/')[-1]),$OutFile)
        if ($script:badHash) { [IO.File]::AppendAllText($OutFile,'# tampered') }
    }
    try {
        $installedRoot = New-FirstInstallFolder "offline [x] O'Brien & Co"
        $result = Invoke-BupFirstInstall -InstallerFile (Join-Path $installedRoot 'FirstInstall.bat') -NoStart
        Assert-FirstInstall ($result.Version -eq '1.0.3' -and $result.Files -eq 5) 'Installation nur mit den fuenf Laufzeit-Skripten'
        $manifest = Test-BupUpdatePackage $installedRoot
        Assert-FirstInstall ($manifest.InstallationType -eq 'Runtime' -and $manifest.Files.Count -eq 5 -and @(Get-ChildItem -LiteralPath $installedRoot -File).Count -eq 8) 'Runtime-Manifest, Batch und Verknuepfung ohne Entwicklungsdateien'
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut((Join-Path $installedRoot 'Benutzerprofil-Backup.lnk'))
        $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($link.Arguments -split ' ')[-1]))
        $null = [Management.Automation.Language.Parser]::ParseInput($command,[ref]$tokens,[ref]$errors)
        Assert-FirstInstall ($errors.Count -eq 0 -and $command.Contains("O''Brien & Co") -and $link.Arguments.Contains('-WindowStyle Hidden')) 'Startverknuepfung mit sicheren Sonderzeichenpfaden und versteckter Konsole'
        Assert-InstallRejected { Invoke-BupFirstInstall -InstallerFile (Join-Path $installedRoot 'FirstInstall.bat') -NoStart } 'Erneute Erstinstallation ueberschreibt keine vorhandene Installation'
        $nonempty = New-FirstInstallFolder 'nonempty'
        [IO.File]::WriteAllText((Join-Path $nonempty 'keep.txt'),'keep')
        Assert-InstallRejected { Invoke-BupFirstInstall -InstallerFile (Join-Path $nonempty 'FirstInstall.bat') -NoStart } 'Fremde Dateien im Zielordner verhindern Erstinstallation'
        Assert-FirstInstall ([IO.File]::ReadAllText((Join-Path $nonempty 'keep.txt')) -eq 'keep') 'Vorhandene fremde Datei unveraendert'
        $tampered = New-FirstInstallFolder 'tampered'
        $script:badHash = $true
        Assert-InstallRejected { Invoke-BupFirstInstall -InstallerFile (Join-Path $tampered 'FirstInstall.bat') -NoStart } 'Falsche Download-Pruefsumme verhindert Installation'
        Assert-FirstInstall (@(Get-ChildItem -LiteralPath $tampered -Force).Count -eq 1) 'Bei Pruefsummenfehler bleibt ausschliesslich die Batch erhalten'
        $script:badHash = $false; $script:failDownload = $true
        $offline = New-FirstInstallFolder 'network-error'
        Assert-InstallRejected { Invoke-BupFirstInstall -InstallerFile (Join-Path $offline 'FirstInstall.bat') -NoStart } 'Netzwerkfehler sauber abgefangen'
        Assert-FirstInstall (@(Get-ChildItem -LiteralPath $offline -Force).Count -eq 1) 'Unvollstaendige Downloads entfernt'
    }
    finally { Remove-Item -LiteralPath Function:\Invoke-RestMethod; Remove-Item -LiteralPath Function:\Invoke-WebRequest }

    if ($Online) {
        $onlineRoot = New-FirstInstallFolder "online [x] O'Brien & Co"
        $processInfo = New-Object Diagnostics.ProcessStartInfo
        $processInfo.FileName = $env:ComSpec
        $processInfo.Arguments = '/d /c ""' + (Join-Path $onlineRoot 'FirstInstall.bat') + '" --no-start --no-pause"'
        $processInfo.UseShellExecute = $false; $processInfo.CreateNoWindow = $true
        $processInfo.RedirectStandardOutput = $true; $processInfo.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($processInfo)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(60000)) { $process.Kill(); throw 'Zeitlimit fuer Erstinstallation ueberschritten.' }
            if ($process.ExitCode -ne 0) { throw ($stdout.Result + $stderr.Result) }
            Assert-FirstInstall ($process.ExitCode -eq 0) 'Echte Batch startet ueber cmd.exe und installiert von GitHub'
        }
        finally { $process.Dispose() }
        $onlineManifest = Test-BupUpdatePackage $onlineRoot
        Assert-FirstInstall ($onlineManifest.InstallationType -eq 'Runtime' -and $onlineManifest.Files.Count -eq 5 -and @(Get-ChildItem -LiteralPath $onlineRoot -File).Count -eq 8) 'Online-Erstinstallation enthaelt genau Runtime, Manifest, Verknuepfung und Batch'
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
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
        $guiEntry.SHA256 = (Get-FileHash -LiteralPath (Join-Path $onlineRoot $guiEntry.Name) -Algorithm SHA256).Hash
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
        Remove-BupTree $resolved
    }
    else { Write-Output "Testdaten: $sandbox" }
}
