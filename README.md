# Benutzerprofil-Backup

Versionierte Dateisicherung fuer Windows 10/11 mit dem mitgelieferten Windows
PowerShell 5.1. Keine Zusatzsoftware, Module, Administratorrechte oder laufenden
Hilfsdienste erforderlich. PowerShell 7 ist ebenfalls getestet.

## Dateien

| Datei | Zweck |
|---|---|
| `Backup-UserProfile.ps1` | Sicherung, Versionierung, Aufbewahrung, Protokolle |
| `Install-BackupTask.ps1` | Anmeldeaufgabe fuer den aktuellen Benutzer |
| `Restore-UserProfile.ps1` | Wiederherstellung mit Inhaltspruefung und Ueberschreibschutz |
| `Test-Backup.ps1` | Automatisierte Tests ohne Testframework |
| `Start-BackupGUI.ps1` | Grafische Oberflaeche fuer Install, Backup, Taskplanung und Restore |
| `Test-GUI.ps1` | Isolierte Tests der Oberflaeche und ihrer Hintergrundvorgaenge |
| `Update-UserProfileBackup.ps1` | Programmupdate aus oeffentlichem GitHub-Repository und Rollback |
| `New-UpdateManifest.ps1` | Version und Dateipruefsummen fuer eine Veroeffentlichung erzeugen |
| `update-manifest.json` | Versionsstand und erlaubte Programmdateien mit SHA-256 |
| `Test-Update.ps1` | Isolierte Tests von Download, Austausch, Sperren und Rollback |
| `Test-OnlineUpdate.ps1` | Echter Download, Installation und Rollback in temporaerer Testinstallation |

## Grafische Oberflaeche

Falls lokal vorhanden, `Benutzerprofil-Backup.lnk` in diesem Projektordner
doppelklicken. Die Verknuepfung startet die GUI ohne zusaetzliches Konsolenfenster.
Nach einem erstmaligen Download aus GitHub oder alternativ:

```powershell
powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "$env:USERPROFILE\UserProfileBackup\Start-BackupGUI.ps1"
```

Die Oberflaeche verwendet Windows Forms und die bestehenden PowerShell-Skripte.
Zusaetzliche Software ist nicht erforderlich.

Die GUI und der Einstellungsdialog starten standardmaessig im Darkmode, mit
dunklen Eingabefeldern, heller Schrift und eigener dunkler Navigation. Die
Oberflaeche verwendet eine feste 96-DPI-Entwurfsbasis und skaliert erst den
vollstaendig aufgebauten Fensterinhalt. Der Einstellungsbutton liegt getrennt
von den Textlabels; diese koennen ihn nicht mehr verdecken.

- **Install:** Vorhandenes Sicherungsziel und Protokollpfad waehlen, Einstellungen
  speichern und die Windows-Aufgabe installieren bzw. aktualisieren. Es wird die
  Aufgabe des aktuellen Benutzers eingerichtet; die Programmdateien bleiben hier.
- **Backup:** Jeder Klick auf **Backup starten** erstellt einen neuen Stand mit
  Datum und Uhrzeit, auch mehrmals am selben Tag. Bisherige Staende bleiben
  erhalten; unveraenderte Dateien werden weiterhin per Hardlink geteilt, sofern
  moeglich. Ausserdem kann der Protokollordner geoeffnet werden.
- **Taskplanung:** Anmeldeverzoegerung (0 bis 60 Minuten, Standard 2) und optionalen
  Tagesstart mit Uhrzeit einstellen. Mit **Plan speichern** die Aufgabe aktualisieren.
  Status abrufen, Aufgabe aktivieren/deaktivieren oder nach Bestaetigung entfernen.
  Der Tagesstart verwendet ebenfalls eine angemeldete Sitzung.
- **Restore:** **Staende laden** zeigt gueltige Tages-/Monats-/Jahresstaende des
  aktuellen Benutzers am angegebenen Sicherungsziel. Alternativ einen datierten
  Stand direkt auswaehlen. Zielordner und Kategorie waehlen und wiederherstellen.
  Bereits vorhandene Zieldateien werden immer ausgelassen. Zum Ersetzen bestehender
  Dateien kann weiterhin das separate Restore-Skript mit Einzelbestaetigung genutzt
  werden. Im Ziel entstehen die Kategorieordner wie `Documents`.

Die GUI speichert ihre Einstellungen unter
`%LOCALAPPDATA%\UserProfileBackup\gui-settings.json`. **Einstellungen speichern**
aendert allein die GUI-Konfiguration; die Aufgabe wird erst durch **Installieren /
aktualisieren** oder **Plan speichern** angepasst. Ein direkter CLI-Start des
Backupskripts liest diese GUI-Datei nicht; dafuer weiterhin `-BackupRoot` angeben.
Das GUI-Fenster zeigt Ergebnisse und Fehler unten an. Langsame Datei- und
Netzwerkvorgaenge laufen in einem eigenen PowerShell-Runspace. Waehrenddessen sind
weitere Aktionen und das Schliessen des Fensters gesperrt, damit kein Backup
versehentlich abgebrochen wird. Es gibt keine erzwungene Abbrechen-Schaltflaeche.

### Einstellungen und Aufbewahrung

Oben rechts oeffnet **Einstellungen ...** den Dialog fuer Tages-, Monats-, Jahres-
und Protokollaufbewahrung. Standard sind weiterhin **7 Tage / 12 Monate / 5 Jahre**
und **30 Tage Protokolle**. Die Werte muessen mindestens 1 betragen. Unterstuetzte
Obergrenzen: 36500 Tage, 1200 Monate, 100 Jahre und 3650 Protokolltage.

**Speichern** uebernimmt die Werte fuer kuenftige manuelle Backups und speichert
sie in der GUI-Konfiguration. Fuer geplante Backups anschliessend unter
**Taskplanung → Plan speichern** die Aufgabe aktualisieren. Die Aufgabe erhaelt
die Werte als ausdrueckliche Parameter; eine alleinige Aenderung der GUI-Datei
veraendert eine bereits registrierte Aufgabenaktion nicht.

Die Aufbewahrung zaehlt Kalenderzeitraeume, nicht Sicherungsordner. Bei 7 Tagen
bleiben also alle manuellen und automatischen Staende der letzten 7 Kalendertage
erhalten. Eine verkuerzte Frist entfernt beim Speichern noch keine Backups;
die Bereinigung erfolgt erst nach einer erfolgreichen Sicherung. Monats- und
Jahresstaende werden durch weitere manuelle Tagesstaende nicht ueberschrieben.

## Erstinstallation (FirstInstall.ps1)

`FirstInstall.ps1` installiert die fuenf Laufzeit-Skripte aus GitHub in einen **leeren Ordner**, in dem
nur diese Datei liegt (Release-Asset von [v1.0.3](https://github.com/2xlc-cloud/UserProfileBackup/releases/latest)).
Es werden keine Test- oder Entwicklungsdateien geladen, vorhandene Dateien nie ueberschrieben.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\FirstInstall.ps1
# Nur das System pruefen, nichts installieren:
powershell -NoProfile -ExecutionPolicy Bypass -File .\FirstInstall.ps1 -CheckOnly
# Fehlende Komponenten (Git) ohne Rueckfrage per winget nachinstallieren:
powershell -NoProfile -ExecutionPolicy Bypass -File .\FirstInstall.ps1 -InstallMissing
```

Ablauf: 1. Zielordner pruefen (erst dann wird irgendetwas installiert), 2. Systemcheck, 3. fehlende Komponenten
nachinstallieren, 4. Download mit SHA-256-Pruefung, 5. Startverknuepfung `Benutzerprofil-Backup.lnk`.

| Pruefpunkt | Art | Bei Fehler |
|---|---|---|
| Windows 10 oder neuer | Pflicht | Abbruch |
| Windows PowerShell 5.1 (`powershell.exe`) | Pflicht | Abbruch |
| .NET Framework 4.7.2 oder neuer | Pflicht | Abbruch (manuell nachinstallieren) |
| Windows Forms ladbar | Pflicht | Abbruch |
| Zielordner beschreibbar, mind. 100 MB frei | Pflicht | Abbruch |
| Verbindung zu `api.github.com` und `raw.githubusercontent.com` | Pflicht | Abbruch |
| Git | empfohlen | Rueckfrage (J/N) oder `-InstallMissing`; Installation per `winget install --id Git.Git` |

Git wird fuer den Betrieb und das Selbstupdate nicht benoetigt, nur zum Klonen oder Weiterentwickeln des Repositorys.
Scheitert die Git-Installation (kein winget, Fehlercode), wird gewarnt und das Programm trotzdem installiert.
Wurde die Datei im Browser geladen und blockiert Windows sie, vorher `Unblock-File .\FirstInstall.ps1` ausfuehren
oder den Aufruf mit `-ExecutionPolicy Bypass` wie oben verwenden.
## Einrichtung

1. Diesen Projektordner dauerhaft an seinem Platz lassen. Die Aufgabe verweist auf
   das Hauptskript in diesem Ordner.
2. Einen vorhandenen Sicherungsordner waehlen, beispielsweise `E:\ProfilBackups`
   oder `\\server\freigabe\ProfilBackups`. Den Ordner vorher selbst anlegen. Ein
   nicht erreichbares Ziel wird vom Backup absichtlich nicht neu angelegt.
3. In `Backup-UserProfile.ps1` oben den Standardwert von `$BackupRoot = ''` auf den
   gewuenschten Pfad setzen. Alternativ bei jedem direkten Start `-BackupRoot`
   verwenden. Im Installationsskript ist der Parameter immer erforderlich; sein
   Wert wird zentral in der Aufgabenaktion gespeichert und hat Vorrang vor dem
   Standardwert im Hauptskript.
4. In einem normalen, nicht erhoehten PowerShell-Fenster ausfuehren:

```powershell
Set-Location (Join-Path $env:USERPROFILE 'UserProfileBackup')
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-BackupTask.ps1 -BackupRoot 'E:\ProfilBackups'
```

Dadurch entsteht `UserProfileBackup-<Benutzer-SID>` in der Windows-Aufgabenplanung.
Eine erneute Installation aktualisiert dieselbe Aufgabe. Es wird kein Kennwort
gespeichert und keine UAC-Erhoehung angefordert. Unternehmensrichtlinien koennen
die Registrierung oder Skriptausfuehrung dennoch untersagen; das Skript meldet
diesen Fehler und versucht keine Rechteerhoehung.

Die Aufgabe startet **zwei Minuten nach jeder Anmeldung dieses Benutzers**, mit
`InteractiveToken`, `LeastPrivilege`, `-NoProfile`, `-NonInteractive` und
`-WindowStyle Hidden`. Sie laeuft auch im Akkubetrieb, ohne feste Zeitbegrenzung.
Die automatische Aufgabe erzeugt pro Kalendertag hoechstens einen neuen Tagesstand.
Auch ein bereits manuell erzeugter Stand zaehlt als erfolgreiche Tagessicherung. Bei weiteren
Anmeldungen werden die Quellen an diesem Tag nicht erneut gelesen. Fehlgeschlagene
Laeufe koennen am selben Tag erneut gestartet werden.

Standardmaessig gibt es keinen zusaetzlichen Tagestrigger: Bei einer ueber mehrere Tage
durchgehend offenen Sitzung erfolgt erst bei der naechsten Anmeldung bzw. einem
manuellen Start eine neue Sicherung. Ein bei Anmeldung fehlendes USB-/Netzwerkziel
wird protokolliert; nach dem Anschliessen den Lauf manuell nachholen.

Optionaler Tagestrigger und andere Anmeldeverzoegerung auch per CLI:

```powershell
.\Install-BackupTask.ps1 -BackupRoot 'E:\ProfilBackups' -DelayMinutes 2 -DailyAt '19:30'
```

Auch dann erzeugt die automatische Aufgabe hoechstens einen Tagesstand pro Tag.
Manuelle Starts ueber die GUI koennen jederzeit weitere Staende erstellen. Ohne `-DailyAt` wird die
Aufgabe wieder ausschliesslich mit Anmeldetrigger eingerichtet.

Manueller Start:

```powershell
.\Backup-UserProfile.ps1 -BackupRoot 'E:\ProfilBackups'

# Zusaetzlichen Stand anlegen, auch wenn heute bereits gesichert wurde:
.\Backup-UserProfile.ps1 -BackupRoot 'E:\ProfilBackups' -ForceSnapshot

# Eigene Fristen fuer einen direkten Start:
.\Backup-UserProfile.ps1 -BackupRoot 'E:\ProfilBackups' -ForceSnapshot -RetentionDays 14 -RetentionMonths 24 -RetentionYears 8 -LogDays 30
```

UNC-Ziele verwenden die bestehenden Zugriffsrechte des angemeldeten Benutzers.
Fuer die Aufgabe sind UNC-Pfade verlaesslicher als gemappte Laufwerksbuchstaben.
Es werden weder Netzwerkkennwoerter abgefragt noch Verbindungen eingerichtet.

## Quellen und Zielstruktur

Das Skript prueft `$env:USERPROFILE` und liest die tatsaechlichen Windows-Pfade
aus `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders`.
Wo moeglich dient die Windows-SpecialFolder-API als Rueckfall. Die sieben
Kategorien heissen im Backup unabhaengig von der Windows-Sprache:

`Desktop`, `Documents`, `Pictures`, `Music`, `Videos`, `Downloads`, `Favorites`.

Damit werden auch Ordnerumleitungen und OneDrive-Pfade beruecksichtigt. Fehlende
oder nicht lesbare Quellordner gelten als Fehler, damit keine unvollstaendige
Sicherung stillschweigend als vollstaendig erscheint.

```text
E:\ProfilBackups\ben-S-1-5-21-...\
  Daily\2026-11-17\Documents\...
  Daily\2026-11-17_153012123_<eindeutige-ID>\Documents\...
  Monthly\2026-11\Documents\...
  Yearly\2026\Documents\...
  .backup.lock
```

Jeder Stand enthaelt ausserdem `.snapshot.json` mit Dateiliste, SHA-256-Pruefsummen,
Zeitstempeln, Quellpfaden und Benutzer-SID. Dieses Manifest nicht bearbeiten.
Ordner mit `.incomplete-...` sind Arbeitsordner und keine Wiederherstellungspunkte.
Nach einem normalen Fehler werden sie entfernt. Nach Stromausfall oder hartem
Abbruch koennen sie zurueckbleiben; sie werden nie fuer Wiederherstellung oder
Rotation verwendet. Nach Ende aller Sicherungslaeufe duerfen solche Arbeitsordner
manuell entfernt werden.

AppData, Betriebssystem- und Profilverwaltungsdateien liegen ausserhalb der
ausgewaehlten Quellen. Innerhalb der Quellen werden System-/Temporary-Attribute,
`*.tmp`, `*.temp`, `desktop.ini` und `Thumbs.db` ausgeschlossen. Beliebige eigene
Dateien werden nicht allein wegen eines Ordnernamens wie `Cache` verworfen.
Symbolische Links und Junctions werden mit Protokolleintrag ausgelassen, damit
keine Schleifen oder fremden Verzeichnisbaeume eingelesen werden. OneDrive-
Cloudordner werden durchlaufen; reine Onlinedateien werden beim Lesen ggf.
heruntergeladen. Ist der Inhalt nicht abrufbar, schlaegt der Lauf sicher fehl.

Quelle und Ziel duerfen nicht ineinander liegen. Sicherungsverzeichnisse selbst
duerfen keine Junctions oder symbolischen Links sein.

## Versionierung und Aufbewahrung

Die Quelle wird nur gelesen. Fuer neue und geaenderte Dateien wird eine neue
Datei im Arbeitsstand angelegt. Unveraenderte Dateien werden anhand von Inhalt,
Laenge und Aenderungszeit erkannt. Auch bei gleicher Laenge und gleichem Datum
werden inhaltliche Aenderungen erkannt. Dazu werden die Quelldateien einmal pro
neuem Tagesstand komplett fuer SHA-256 gelesen; unveraenderte Dateien des letzten
Tagesstands werden vor ihrer Wiederverwendung ebenfalls geprueft.

Auf einem unterstuetzten Dateisystem werden unveraenderte Dateien durch Hardlinks
mit dem letzten Tagesstand geteilt. Es gibt niemals Hardlinks zur Quelle. Falls
Hardlinks nicht moeglich sind, etwa auf exFAT/FAT oder bestimmten SMB-Servern,
wird aus dem vorhandenen Sicherungsstand kopiert. Vollstaendig durchsuchbare
Ordnerstaende benoetigen dann entsprechend mehr Platz und Schreibzugriffe.
Monats-/Jahresstaende verwenden dasselbe Verfahren.

**Dateien im Backup nicht direkt bearbeiten.** Wegen der Hardlinks koennte eine
Bearbeitung mehrere Staende veraendern. Vor dem Bearbeiten immer in einen anderen
Ordner wiederherstellen bzw. kopieren.

| Typ | Standard-Aufbewahrungsfenster einschliesslich aktuellem Zeitraum |
|---|---|
| Daily | Heute und die vorherigen 6 Kalendertage |
| Monthly | Aktueller Monat und die vorherigen 11 Kalendermonate |
| Yearly | Aktuelles Jahr und die vorherigen 4 Kalenderjahre |

Diese Vorgaben sind ueber den Einstellungsdialog oder die Parameter
`-RetentionDays`, `-RetentionMonths`, `-RetentionYears` anpassbar. Dieselben
Parameter und `-LogDays` werden auch von `Install-BackupTask.ps1` unterstuetzt.

Beim ersten erfolgreichen Stand eines Monats/Jahres entstehen die entsprechenden
Archive. Vorhandene Monats-/Jahresstaende werden nie ueberschrieben. Die Archive
sind unabhaengig von den Tagesordnern; deren Loeschung entfernt die Archivdaten
nicht. Es werden keine fehlenden Zeitraeume kuenstlich aufgefuellt. Geloeschte
Quelldateien bleiben in aelteren Staenden bis zum Ablauf ihrer Aufbewahrung.

Erst nach fehlerfreier Dateisicherung wird der Arbeitsordner in einen gueltigen
Tagesstand umbenannt. Die Aufbewahrungsbereinigung beginnt erst nach erfolgreicher
Erzeugung bzw. Pruefung der Monats-/Jahresstaende. Bei Datei-, Zugriffs- oder
Archivierungsfehlern findet keine Rotation statt. Falls der Tagesstand bereits
fertig war, ein Archiv aber scheitert, bleibt der Tagesstand gueltig und der
naechste Lauf versucht die fehlenden Archive erneut. Unbekannte Ordnernamen
werden nicht geloescht; ungueltige datierte Staende stoppen die Rotation.

Die Aufgabe verhindert parallele Instanzen. Zusaetzlich sichern ein benutzerbezogener
Mutex und eine exklusiv geoeffnete Lockdatei das Skript auch bei manuellen oder
sitzungsuebergreifenden Starts ab. Die Lockdatei darf nach dem Lauf bestehen
bleiben; entscheidend ist der vom Betriebssystem verwaltete Dateihandle.

## Protokolle und Fehler

Standard: `%LOCALAPPDATA%\UserProfileBackup\Logs\yyyy-MM-dd.log`.
Ein anderes Verzeichnis laesst sich mit `-LogRoot` beim Backup und bei der
Aufgabeninstallation waehlen. Standardmaessig werden die letzten 30 Kalendertage
aufbewahrt; mit dem Einstellungsdialog bzw. `-LogDays` ist die Frist anpassbar.
Die Protokolle bleiben lokal verfuegbar, auch wenn das Sicherungsziel fehlt.

Jede Zeile nennt Datum, Uhrzeit, Benutzer-SID und Ziel. Die Abschlusszeile enthaelt
Status, kopierte/uebersprungene/fehlerhafte Dateien, Datenvolumen und Laufzeit.
`Bytes` zaehlt Dateikopien im Tagesstand, `ArchivBytes` zusaetzliche Kopien fuer
Monats-/Jahresstaende; Hardlinks zaehlen nicht als uebertragene Dateiinhalte.
Ordnerfehler werden ebenfalls in `Fehler` mitgezaehlt.

Exitcode `0`: erfolgreich, heute schon erledigt oder bereits laufende Instanz.
Exitcode `1`: Fehler. Einzelne Dateifehler werden protokolliert, die restlichen
Dateien werden trotzdem verarbeitet; der gesamte Arbeitsstand wird anschliessend
verworfen. Gesperrte Dateien werden nicht mit Schattenkopien umgangen. Nach dem
Schliessen der betreffenden Anwendung kann erneut gesichert werden.

Die Sicherung erfasst Dateiinhalte, leere Ordner und Dateiaenderungszeiten.
NTFS-Berechtigungen, Besitzer, alternative Datenstroeme und EFS-Verschluesselung
werden nicht als Metadatenabbild uebertragen. Das Ziel muss daher fuer die
persoenlichen Daten angemessen geschuetzt sein. Es handelt sich um eine laufende
Dateisicherung ohne VSS; mehrere gleichzeitig geaenderte Dateien bilden keinen
gemeinsamen Anwendungstransaktionsstand. Nicht unterstuetzte lange Pfade oder
Dateisystemgrenzen fuehren zu protokollierten Fehlern statt stillen Auslassungen.

## Wiederherstellung

Dateien koennen direkt mit dem Explorer aus einem datierten Ordner kopiert werden.
Das Wiederherstellungsskript prueft zusaetzlich die SHA-256-Pruefsummen und schreibt
Dateien zuerst in temporaere Dateien. Vorhandene Dateien werden nur nach einer
einzelnen ausdruecklichen Bestaetigung ersetzt.

```powershell
# <Benutzerordner> durch den tatsaechlichen Namen einschliesslich SID ersetzen.
.\Restore-UserProfile.ps1 -SnapshotPath 'E:\ProfilBackups\<Benutzerordner>\Daily\2026-11-17' -DestinationPath 'C:\Wiederhergestellt'

# Nur Dokumente; bestehende Dateien unbeaufsichtigt auslassen:
.\Restore-UserProfile.ps1 -SnapshotPath 'E:\ProfilBackups\<Benutzerordner>\Monthly\2026-11' -DestinationPath 'C:\Wiederhergestellt' -Categories Documents -NonInteractive

# Nur Vorschau, keine Schreibzugriffe:
.\Restore-UserProfile.ps1 -SnapshotPath 'E:\ProfilBackups\<Benutzerordner>\Yearly\2026' -DestinationPath 'C:\Wiederhergestellt' -WhatIf
```

Im Ziel entstehen die Kategorieordner, z. B. `C:\Wiederhergestellt\Documents`.
Danach die benoetigten Dateien in den gewuenschten Benutzerordner kopieren.
`-NonInteractive` ueberschreibt grundsaetzlich keine vorhandenen Dateien.
Das Skript kann auch einen Sicherungsstand mit einer anderen Benutzer-SID lesen,
sofern der aktuelle Benutzer die erforderlichen Dateizugriffsrechte hat.

## Tests

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Test-Backup.ps1
```

Die Tests verwenden ausschliesslich einen zufaelligen Unterordner von `%TEMP%`,
simulierte Kalenderdaten und kleine Testdateien. Sie greifen nicht schreibend auf
persoenliche Quelldateien zu und installieren keine Aufgabe. Die Aufgaben-XML
wird mit `TASK_VALIDATE_ONLY` durch Windows selbst validiert. Bei Erfolg werden
die Testdaten entfernt, bei Fehlern fuer die Diagnose behalten. Optional
`-KeepTestData` angeben.

Abgedeckt sind Erstlauf, unveraenderte/geaenderte/geloeschte Dateien, echte
Hardlinks, Kopier-Rueckfall, alte Versionen, Ueberschreibschutz, beschaedigte
Dateien, fehlendes Ziel, Dateisperren, Parallelzugriff, identischer Kalendertag,
Logrotation sowie Tages-/Monats-/Jahresrotation ueber mehrere simulierte Jahre.
Der Kopier-Rueckfall wird durch gezieltes Ablehnen der Hardlink-Erstellung
simuliert. Reale USB-, SMB- und OneDrive-Verbindungen sowie die naechste echte
Benutzeranmeldung sind von der jeweils vorhandenen Umgebung abhaengig und werden
durch diese lokalen Tests nicht vorgetaeuscht.

Die GUI-Tests koennen separat ausgefuehrt werden:

```powershell
powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File .\Test-GUI.ps1
```

Optional `-PreviewPath 'C:\Temp\GUI.png'` mit einem vorhandenen Zielordner angeben:
Dann werden alle vier Tabs ausserhalb des sichtbaren Bildschirmbereichs gerendert
und automatisch geschlossen. Zusaetzlich werden echte Button-Ereignisse, der
GUI-Timer und der Schutz vor Schliessen waehrend eines Vorgangs geprueft. Es bleibt
kein manuell zu schliessendes Testfenster offen. Die Tests installieren oder
veraendern keine produktive Aufgabe.

Pruefstand vom 17.11.2026: **103 Backup-Pruefungen**, **49 GUI-Pruefungen** und
**35 Update-Pruefungen**
erfolgreich unter Windows PowerShell **5.1.26100.9818**. PowerShell **7.7.0** ist
ebenfalls mit dem automatisierten Testsatz geprueft (GUI ohne optionale Vorschau).
Die GUI-Pruefungen enthalten Ueberlagerungs- und Begrenzungspruefungen bei
100, 125, 150 und 200 Prozent Layoutskalierung sowie Darkmode und Navigation.

## Aufgabe entfernen

```powershell
$taskName = 'UserProfileBackup-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Unregister-ScheduledTask -TaskName $taskName -Confirm
```

Sicherungsdaten und Protokolle bleiben dabei erhalten.

## Selbstupdate aus GitHub

Die Updatefunktion ist fuer **oeffentliche GitHub-Repositories** vorbereitet.
Ein installiertes Git, GitHub CLI, Zugangstoken oder weitere Module sind auf den
Backup-Rechnern nicht erforderlich. GitLab, selbst gehostete Git-Server und
private Repositories werden von dieser Version nicht angesprochen.

Quelle: `https://github.com/2xlc-cloud/UserProfileBackup`, Branch `main`.
Die Adresse `https://github.com/2xlc-cloud` allein ist ein Benutzerprofil,
keine Updatequelle. Der Updater laedt ausschliesslich veroeffentlichte Dateien;
er legt selbst keine GitHub-Repositories an.

### Update in der GUI

Unter **Install → Updates ...** Repository-URL und Branch/Tag eintragen und
**Auf Updates pruefen** anklicken. Die Quelle wird separat unter
`%LOCALAPPDATA%\UserProfileBackup\update-source.json` gespeichert. Eine andere
GUI-Konfiguration mit `-SettingsPath` verwendet deren uebergeordneten Ordner.

Die Pruefung zeigt installierte und verfuegbare Version sowie die Commit-ID.
Bei einem verfuegbaren Update wird die konkrete Version zur Installation
angeboten. Nach Bestaetigung startet ein versteckter Updaterprozess. Die GUI
schliesst sich; der Updater wartet auf ihr Prozessende, installiert genau den
zuvor geprueften Commit und startet die GUI mit derselben Einstellungsdatei neu.
Bei einem normalen Updatefehler wird die bisherige Version wiederhergestellt.

Es gibt keine automatische Updateinstallation beim Anmelden. Nur das Backup
startet nach dem gespeicherten Zeitplan. Updates werden ausdruecklich ueber den
Button oder das folgende Skript ausgeloest.

### Update per PowerShell

Vor der Installation alle GUI-Fenster schliessen und laufende Sicherungen abwarten.

```powershell
# Nur pruefen, keine Programmdateien austauschen:
.\Update-UserProfileBackup.ps1 -RepositoryUrl 'https://github.com/2xlc-cloud/UserProfileBackup' -Ref main -CheckOnly

# Pruefen und bei einer neuen Version installieren:
.\Update-UserProfileBackup.ps1 -RepositoryUrl 'https://github.com/2xlc-cloud/UserProfileBackup' -Ref main

# Nach Speichern einer Updatequelle in der GUI sind RepositoryUrl/Ref optional:
.\Update-UserProfileBackup.ps1 -CheckOnly
.\Update-UserProfileBackup.ps1

# Letztes erfolgreiches oder unterbrochenes Update zuruecksetzen:
.\Update-UserProfileBackup.ps1 -Rollback
```

Das Programmverzeichnis muss fuer den aktuellen Benutzer beschreibbar sein.
GUI, Backup und Aufgabeninstallation halten eine gemeinsame Programmsperre.
Solange eine dieser Aktionen aktiv ist, verweigert der Updater den Dateiaustausch;
umgekehrt beginnen keine neuen Aktionen waehrend des Austauschs.
Bestehende Aufgaben behalten ihre Pfade und Einstellungen. Die Sicherungsziele,
persoenlichen Quelldateien, lokale Einstellungen, Verknuepfungen und Protokolle
stehen nicht auf der Update-Dateiliste und werden nicht ersetzt.

### Pruefung, Rueckfall und Grenzen

Der Updater loest Branch/Tag zuerst in eine konkrete GitHub-Commit-ID auf und
laedt Manifest und Programmdateien ueber HTTPS aus genau diesem Commit. Er
akzeptiert nur fest vorgegebene Dateinamen, prueft Dateigroessen und SHA-256,
validiert alle PowerShell-Dateien mit dem Parser und verhindert unbeabsichtigte
Downgrades. Unterstuetzt werden die kleinen Programmdateien bis jeweils 5 MiB.
Ein gleicher Versionsname mit geaenderten Dateiinhalten wird ebenfalls erkannt.

Die Pruefsummen sichern die Konsistenz des Downloads; sie sind keine unabhaengige
Signatur des Herausgebers. Wer Schreibzugriff auf die gewaehlte Quelle hat, kann
Programmcode ausliefern. Deshalb nur ein selbst kontrolliertes bzw.
vertrauenswuerdiges Repository eintragen. Es werden keine heruntergeladenen
Installations-Hooks oder Tests ungeprueft ausgefuehrt.

Vor dem Austausch speichert das Skript die bisher betroffenen Programmdateien
unter `.updates\rollback-<ID>` im Programmverzeichnis. Dateien werden einzeln
atomar ersetzt. Falls ein Dateiaustausch scheitert, setzt es die bereits
geaenderten Dateien zurueck. Kurzzeitige Dateisperren werden begrenzt erneut
versucht. Diese Programmkopien sind getrennt von den Benutzerprofil-Backups und
werden nicht durch deren Aufbewahrungsrotation entfernt.

Bei Stromausfall kann eine Mischung aus Programmversionen zurueckbleiben:
`.updates\pending.json` kennzeichnet den offenen Vorgang. Die GUI und Backups
verweigern dann den Start. Mit `-Rollback` wird die alte Version aus dem
geprueften Journal wiederhergestellt. Falls das aktuelle Updateskript selbst
beschaedigt ist, liegt seine alte Datei im genannten Rollback-Ordner; sie kann
mit `-InstallRoot '<urspruenglicher Programmordner>' -Rollback` verwendet werden.
Bei beschaedigten Rollback-Dateien wird die Wiederherstellung mit Fehler beendet,
ohne diese als gueltig auszugeben. Vorherige Rollback-Ordner bleiben zur Diagnose
erhalten; `-Rollback` verwendet den letzten Vorgang.

Update-Protokolle: `%LOCALAPPDATA%\UserProfileBackup\Updates\yyyy-MM-dd.log`.
Die Offline-Tests pruefen den Updateablauf mit lokalen Paketen und simulierten
GitHub-Antworten. Der echte Onlineablauf ist separat wiederholbar:

```powershell
powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File .\Test-OnlineUpdate.ps1
```

Dieser Test arbeitet in einer temporaeren Installation und verwendet echte,
oeffentliche HTTPS-Downloads ohne GitHub-Anmeldung. Er prueft Versionsvergleich,
Commitbindung, Warten auf eine aktive Programmsperre, CLI-Selbstupdate,
Dateipruefsummen, GUI-Start ohne sichtbares Fenster, anschliessende Sicherung und
CLI-Rollback. Die produktive Installation und persoenliche Quelldateien werden
nicht veraendert. Die interaktive Rueckfrage und der sichtbare GUI-Neustart werden
dadurch nicht als manueller Bedienungstest vorgetaeuscht. Die Ergebnisse der
Veroeffentlichungspruefung stehen in `TEST-RESULTS.md`.

### Version auf GitHub veroeffentlichen

1. Ein oeffentliches Repository `2xlc-cloud/UserProfileBackup` mit Branch `main`
   anlegen. Die Programmdateien gehoeren ins Repository-Hauptverzeichnis.
2. Aenderungen entwickeln und die drei Tests ausfuehren:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Test-Backup.ps1
powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File .\Test-GUI.ps1
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Test-Update.ps1
```

3. **Nach der letzten Dateiaenderung** die neue Version eintragen und Manifest
   erzeugen. Beispiel fuer die naechste Version:

```powershell
.\New-UpdateManifest.ps1 -Version '1.1.0'
```

4. Die im Manifest aufgefuehrten Programmdateien, `update-manifest.json` und
   `.gitignore` gemeinsam committen und auf GitHub veroeffentlichen. Niemals
   Sicherungsdateien, `gui-settings.json`, `update-source.json`, `.updates`,
   Verknuepfungen oder lokale Protokolle hochladen. `.gitignore` schliesst die
   ueblichen lokalen Artefakte aus; die Veroeffentlichungsliste trotzdem pruefen.

Das Manifest gilt nur fuer exakt diese Dateiinhalte. Spaetere Aenderungen muessen
erneut durch `New-UpdateManifest.ps1` erfasst und mit dem Manifest veroeffentlicht
werden. GitHub-Limits oder fehlende Internetverbindung werden als Updatefehler
angezeigt; die installierte Version bleibt dabei nutzbar.
`.gitattributes` unterbindet automatische Zeilenenden-Konvertierung, damit die
veroeffentlichten Bytes mit den SHA-256-Werten uebereinstimmen.
