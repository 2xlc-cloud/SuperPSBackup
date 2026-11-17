# Veroeffentlichungs- und Testbericht 1.0.1

Datum: 17.11.2026 (Europe/Berlin).

Repository: https://github.com/2xlc-cloud/UserProfileBackup

Gepruefter Programmstand: `e0a65245f314c7a94a656ceeaf9ad3fde6457bb2`.
Programmversion laut Update-Manifest: **1.0.1**.
Testumgebung: Windows, Windows PowerShell **5.1.26100.9818**.

## Ergebnis

| Testsatz | Erfolgreich | Fehler |
|---|---:|---:|
| `Test-Backup.ps1` | 103 | 0 |
| `Test-GUI.ps1` mit Vorschau/Bedienereignissen | 48 | 0 |
| `Test-Update.ps1` | 35 | 0 |
| `Test-OnlineUpdate.ps1` gegen das oeffentliche GitHub-Repository | 10 | 0 |
| **Gesamt** | **196** | **0** |

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
GitHub-Quelle auf **1.0.1** aktualisiert. Downloads erfolgten anonym ueber HTTPS;
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
powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File .\Test-GUI.ps1 -PreviewPath "$env:TEMP\UserProfileBackup-GUI.png"
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Test-Update.ps1
powershell.exe -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File .\Test-OnlineUpdate.ps1
```

Fuer den Online-Test kann `-SourceRef` auf die oben genannte Commit-ID gesetzt
werden. Der Testbericht ist Dokumentation und gehoert nicht zu den automatisch
ersetzten Programmdateien im Update-Manifest.
