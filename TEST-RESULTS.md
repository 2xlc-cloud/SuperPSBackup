# Veroeffentlichungs- und Testbericht 1.0.2

Datum: 17.11.2026 (Europe/Berlin).

Repository: https://github.com/2xlc-cloud/SuperPSBackup

Gepruefter Programmstand: `e44e6539b79c03aa000049bc144b6879f9d9d6b1`.
Programmversion laut Update-Manifest: **1.0.2**.
Testumgebung: Windows, Windows PowerShell **5.1.26100.9818**.

## Ergebnis

| Testsatz | Erfolgreich | Fehler |
|---|---:|---:|
| `Test-Backup.ps1` | 103 | 0 |
| `Test-GUI.ps1` mit Vorschau/Bedienereignissen | 49 | 0 |
| `Test-Update.ps1` | 35 | 0 |
| `Test-OnlineUpdate.ps1` gegen das oeffentliche GitHub-Repository | 10 | 0 |
| **Gesamt** | **197** | **0** |

Alle vier Testprozesse wurden mit Exitcode 0 beendet. Die Tests verwendeten
temporaere Testdaten; produktive Profilordner und geplante Aufgaben wurden
nicht veraendert. Erfolgreiche Testinstallationen wurden automatisch bereinigt.

## Pruefung vor der Veroeffentlichung

- Die erste Veroeffentlichung enthielt 14 explizit freigegebene Textdateien:
  Programm- und Testskripte, README, Update-Manifest, `.gitignore` und
  `.gitattributes`. Dieser Bericht ist die anschliessende Dokumentation.
- Dateiliste und Inhalte wurden auf Zugangsdaten, bekannte Tokenformate,
  private Schluessel und fest eingetragene Geheimnisse geprueft. Keine Treffer.
- Lokale Konfigurationen (`gui-settings.json`, `update-source.json`),
  Sicherungsdaten, Protokolle, `.program.lock`, Verknuepfungen, Vorschaubilder
  und `.updates` wurden nicht uebertragen.
- Das zentrale Sicherungsziel im veroeffentlichten Skript ist ungesetzt.
- Git-Commits verwenden die zum GitHub-Konto gehoerende Noreply-Adresse.
- Alle Dateien des Update-Pakets wurden vor dem Upload gegen Manifest,
  Dateigroesse, SHA-256 und PowerShell-Syntax geprueft.
- Git-Whitespacepruefung erfolgreich. Automatische Zeilenenden-Konvertierung
  ist unterbunden, damit GitHub exakt die geprueften Dateibytes ausliefert.

## Echter Online-Test

Eine isolierte Testinstallation mit Version 1.0.0 wurde ueber die oeffentliche
GitHub-Quelle auf **1.0.2** aktualisiert. Downloads erfolgten anonym ueber HTTPS;
die GitHub-Anmeldung wurde nur fuer Repository-Erstellung und Git-Push verwendet.

1. Branch/Commit und neue Version vom echten GitHub-Endpunkt gelesen.
2. CLI-Pruefung mit `-CheckOnly` ohne Austausch von Programmdateien ausgefuehrt.
3. Einen versteckten Hilfsprozess mit derselben Programmsperre wie die GUI
   gestartet. Der Updater wartete mit `-WaitForProcessId` auf dessen Ende.
4. Das Updateskript innerhalb der Testinstallation ausgefuehrt. Es lud den
   festgelegten Commit herunter und ersetzte dabei auch seine eigene Datei.
5. Alle installierten Dateien mit den Remote-SHA-256-Werten verglichen.
6. Unveraenderte lokale Konfigurations- und Sicherungsdateien nachgewiesen.
7. Erneute Onlinepruefung: kein weiteres Update erforderlich.
8. Aktualisierte GUI in einem neuen Windows-PowerShell-Prozess mit `-NoShow`
   erfolgreich aufgebaut.
9. Mit dem aktualisierten Backupskript eine neue Testdatei erfolgreich gesichert.
10. CLI-Rollback auf 1.0.0 ausgefuehrt und die vorherigen Programmdateien
    bytegenau wiederhergestellt. Keine offene Update-Transaktion und kein
    Verlust der Test-Sicherungsdateien.

## Fehlerfaelle und Grenzen

Bei der abschliessenden Codepruefung wurde eine moegliche Mehrfachausloesung der
GUI-Updatebestaetigung behoben: Der Ergebnistimer wird jetzt vor dem modalen
Dialog gestoppt. Ein zusaetzlicher Regressionstest prueft genau eine Rueckfrage
und das Beenden des Vorgangs ohne Installation bei Ablehnung. Anschliessend
wurde der echte Online-Test gegen Version 1.0.2 vollstaendig wiederholt.

Die Offline-Tests pruefen unter anderem falsche Pruefsummen, Syntaxfehler,
fehlende Dateien, nicht erlaubte Dateipfade, Downgrades, aktive Programmsperren,
Netzwerkabbruch, Fehler mitten im Dateiaustausch und Wiederherstellung aus
einem unterbrochenen Update-Journal.

Die GUI-Tests pruefen Darkmode, echte Button-Ereignisse, Navigation,
Hintergrundausfuehrung und Layoutbegrenzungen bei 100, 125, 150 und 200 Prozent
simulierter Layoutskalierung. Eine separate Windows-10-VM und ein echter
Monitorwechsel mit unterschiedlicher DPI-Skalierung waren nicht Bestandteil
dieser Veroeffentlichungspruefung.

Die interaktive Update-Rueckfrage und der sichtbare automatische GUI-Neustart
bleiben als manuelle Bedienungsnachpruefung offen. Geprueft sind deren erzeugte
Startbefehle sowie der Start der tatsaechlich aktualisierten GUI ohne sichtbares
Fenster. Es wurden keine sichtbaren Dialoge automatisch bestaetigt.

## Wiederholen

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Test-Backup.ps1
powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File .\Test-GUI.ps1 -PreviewPath "$env:TEMP\SuperPSBackup-GUI.png"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Test-Update.ps1
powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File .\Test-OnlineUpdate.ps1
```

Fuer den Online-Test kann `-SourceRef` auf die oben genannte Commit-ID gesetzt
werden. Der Testbericht ist Dokumentation und gehoert nicht zu den automatisch
ersetzten Programmdateien im Update-Manifest.

## Nachtrag Version 1.0.3 (2026-11-17)

Ausloeser: `FirstInstall.bat` meldete "Das Repository enthaelt noch keine geeignete Runtime-Version ab 1.0.3", weil auf GitHub nur 1.0.2 lag.

Veroeffentlicht: Commit `0f6007b`, Tag/Release `v1.0.3` mit Asset `FirstInstall.bat`.
Vor der Veroeffentlichung wurde nach Tokens, Passwoertern, Schluesseln und persoenlichen Pfaden gesucht (ohne Treffer);
`*.lnk`, `GUI-Preview*.png`, `.program.lock`, Einstellungen und Logs bleiben per `.gitignore` ausgeschlossen.

Beim Live-Test gefundene und behobene Fehler:
1. `Get-FileHash` wurde im Batch-Bootstrap (`-Command` + Scriptblock) nicht gefunden. Ersetzt durch .NET-SHA-256.
2. `Parser::ParseFile` und `Invoke-WebRequest -OutFile` werteten `[x]` im Ordnernamen als Platzhalter aus.
   Erstinstallation und Updater laden jetzt ueber `Save-BupDownload` (WebClient, woertliche Pfade) und pruefen per `ParseInput`.

| Test | Ergebnis |
|---|---|
| `Test-Update.ps1` | 35 / 35 |
| `Test-FirstInstall.ps1` (offline) | 11 / 11 |
| `Test-FirstInstall.ps1 -Online` (echtes GitHub, Pfad mit `[x]`, Selbstupdate, Rollback) | 19 / 19 |
| `Test-OnlineUpdate.ps1` (Update, Backup, CLI-Rollback) | 10 / 10 |
| `Test-Backup.ps1` | 104 / 104 |
| `FirstInstall.bat` aus dem Release-Download, danach `-CheckOnly` | Version 1.0.3, kein Update offen |
| `Test-GUI.ps1` | Bricht bei der 200-Prozent-Pruefung ab (Arbeitsbereich 1476x781 zu klein fuer den Kopfbereich); 100/125/150 Prozent bestehen. `Start-BackupGUI.ps1` ist unveraendert. |
## Nachtrag: FirstInstall.ps1 statt FirstInstall.bat (2026-11-17)

`FirstInstall.bat` wurde durch `FirstInstall.ps1` ersetzt (Release-Asset von `v1.0.3`, Commit `3826ae2`).
Neu: Zielordner-Pruefung vor allem anderen, Systemcheck (Windows 10+, Windows PowerShell 5.1, .NET Framework 4.7.2+,
Windows Forms, Zielordner beschreibbar, 100 MB frei, Verbindung zu GitHub), Nachinstallation von Git per winget
(`-InstallMissing` oder Rueckfrage J/N), `-CheckOnly`, `-SkipOptional`. Git ist empfohlen, nicht Pflicht; Fehler dabei sind nur eine Warnung.

Alle Systemzugriffe sind einzelne Funktionen und im Test ersetzbar. Dadurch pruefen die Tests jeden Zweig ohne Systemveraenderung.

| Test | Ergebnis |
|---|---|
| `Test-FirstInstall.ps1` offline (Pflichtpunkte einzeln, Git per winget, Rueckfragen, winget fehlt/Fehlercode, `-CheckOnly`, Pruefsumme, Netzwerk) | 38 / 38 |
| `Test-FirstInstall.ps1 -Online` (echter Systemcheck, echte Installation von GitHub in `[x]`-Ordner, GUI, Backup, Restore, Selbstupdate, Rollback) | 48 / 48 |
| `Test-OnlineUpdate.ps1` | 10 / 10 |
| `Test-Update.ps1` | 35 / 35 |
| `Test-Backup.ps1` | 105 / 105 |
| Release-Asset heruntergeladen (Hash identisch) und in leerem Ordner ausgefuehrt | Version 1.0.3, Exit 0 |
| `winget show --id Git.Git -e --source winget` | Paket gefunden (winget 1.29) |

Nicht real getestet: die tatsaechliche Git-Installation per winget (Git ist auf dem Testrechner bereits vorhanden, es wurde nichts
deinstalliert). Der winget-Aufruf ist durch Mocks (Argumente, Fehlercodes, fehlendes winget) abgedeckt.
`Test-GUI.ps1` verhaelt sich unveraendert (200-Prozent-Pruefung scheitert am kleinen Arbeitsbereich dieses Bildschirms).
## Nachtrag: Umbenennung in SuperPSBackup, Version 1.1.0 (2026-11-17)

GitHub-Repository `2xlc-cloud/SuperPSBackup` (alte Adresse leitet weiter), Release `v1.1.0`.
Neue Namen fuer Aufgaben, Datenordner, Verknuepfung und interne Bezeichner; Uebernahme bestehender Installationen
(Datenordner, gespeicherte Pfade, Updatequelle, Backup- und Update-Aufgabe, Reparatur nach Umbenennen des Programmordners).
Dateinamen `Backup-UserProfile.ps1`, `Restore-UserProfile.ps1`, `Update-UserProfileBackup.ps1` bleiben, damit aeltere Updater funktionieren.

| Test | Ergebnis |
|---|---|
| `Test-Migration.ps1` (temporaerer Datenordner, Testaufgaben: Verschieben, Zusammenfuehren, Pfade, Updatequelle, Aufgaben mit Sonderzeichen/Tageszeit/Deaktiviert, Reparatur, nicht uebernehmbare Aufgabe) | 19 / 19 |
| `Test-TaskDialog.ps1 -Online` (inkl. Update-Aufgabe "automatisch installieren" auf aelterer Minimalinstallation und im echten Aufgabenplaner) | 47 / 47 |
| `Test-FirstInstall.ps1 -Online` | 48 / 48 |
| `Test-OnlineUpdate.ps1` | 10 / 10 |
| `Test-Update.ps1` / `Test-FirstInstall.ps1` / `Test-Backup.ps1` | 35 / 38 / 107 |
| `Test-GUI.ps1` ohne 200-Prozent-Stufe | 37 (die 200-Prozent-Stufe scheitert weiter am kleinen Arbeitsbereich dieses Bildschirms) |
| Installation Stand 1.0.5 mit alter Repository-Adresse fuehrt Selbstupdate auf 1.1.0 aus | Updated, 5 Dateien, Inhalte identisch |
| Echte Aufgaben dieses Rechners (Backup und Update) migriert | beide Aufgaben unter neuem Namen, Datenordner verschoben |

Gefundene und behobene Probleme: (1) Aeltere Updater lehnen jede Datei ausserhalb ihrer eigenen Liste ab; `Test-Migration.ps1`
steht deshalb bewusst nicht im Manifest. (2) Der Updater berechnet SHA-256 per .NET (kein `Get-FileHash`), (3) Statusabfrage ohne
Aufgabe meldete im Hintergrund faelschlich einen Fehler. Hinweis zur Testumgebung: Ein von PowerShell 7 (Store-Version) geerbter
`PSModulePath` macht Windows PowerShell 5.1 unbrauchbar (es fehlen u. a. `Get-FileHash`, `Set-Content -Encoding`); die Tests laufen mit
dem normalen Modulpfad. Der anonyme GitHub-API-Zugriff ist auf 60 Anfragen pro Stunde begrenzt; viele Online-Testlaeufe hintereinander
koennen es ausschoepfen.