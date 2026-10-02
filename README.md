# IEM-AppInstaller

*[Deutsche Version weiter unten / German version further below](#iem-appinstaller-deutsch)*

A PowerShell script for interactively managing apps and firmware on Siemens Industrial Edge devices via [`iectl`](https://docs.industrial-operations-x.siemens.cloud/r/en-us/latest/industrial-edge-platform-operation-apis-references/industrial-edge-control-iectl), the command-line interface of the Industrial Edge Management (IEM).

> **Note:** This is a private, self-developed script and **not an official Siemens product**. It is provided without warranty and is primarily intended as an **example of how to build automations around `iectl`**. Review the code and adapt it to your own environment before any production use.

## What the script can do

- **Manage apps:** Install, update, downgrade and uninstall apps on multiple edge devices at once (batch mode), including live progress display and verification after completion.
- **Update firmware:** Automatically determines the next compatible firmware step per device (never skips versions) and runs the update with progress display.
- **Two API generations:** Supports both the established `iem` and the newer `iem-v2` API of `iectl`, with the choice left open at startup.
- **Device selection with online detection:** Shows the online/offline status per device; devices without a reliable online status are locked by default and can be selectively unlocked.
- **Configuration management:** Select existing `iectl` configurations, create new ones, or delete ones no longer needed - directly from the script menu.

## Prerequisites

| Component | Requirement |
|---|---|
| Operating system | Windows - **Linux is currently not supported** (see note below) |
| PowerShell | [Version 7.0](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows?view=powershell-7.6) or newer (`pwsh`) - **not** Windows PowerShell 5.1 |
| `iectl` | Installed and available in `PATH` (see below) |
| Credentials | URL, username and password of the IEM |

> **Linux:** The script is currently developed and tested for Windows only. PowerShell 7 is available for Linux, but running the script there is not supported.

No further input (e.g. IP addresses of individual edge devices) is needed - the script determines everything else itself via the IEM API.

## Installing `iectl`

`iectl` is Siemens' official command-line tool for Industrial Edge and is distributed via the [**Industrial Edge Hub**](https://iehub.eu1.edge.siemens.cloud) / the Industrial Edge download center. The complete, up-to-date documentation (command reference, configuration, release notes) can be found here:

[`iectl` documentation (Siemens Industrial Operations X)](https://docs.industrial-operations-x.siemens.cloud/r/en-us/latest/industrial-edge-platform-operation-apis-references/industrial-edge-control-iectl)

The matching `iectl` release for Windows can be obtained from the Industrial Edge Hub of the respective IEM (*Downloads*/*Developer tools* section).

### Windows

1. Download the Windows release of `iectl` and unpack it.
2. Place `iectl.exe` in a permanent location, e.g. `C:\Tools\iectl\iectl.exe`.
3. Add this folder to the system-wide `PATH` in an **admin PowerShell**:

   ```powershell
   [Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\Tools\iectl", "Machine")
   ```

4. Open a new shell and verify the installation:

   ```powershell
   iectl version
   ```

## Usage

Two variants of the script are available:

- **`DE-IEM-AppInstaller.ps1`** - console output in German only.
- **`EN-IEM-AppInstaller.ps1`** - identical functionality, console output in English only.

### Windows (recommended)

Simply double-click the matching launcher in Explorer, or run it from a shell:

- **`Start-EN.cmd`** - starts the English version
- **`Start-DE.cmd`** - starts the German version

```powershell
.\Start-EN.cmd
```

The launchers call PowerShell 7 with `-ExecutionPolicy Bypass` for this one process only. This avoids the error *"running scripts is disabled on this system"* on default Windows installations, without changing any system settings.

**Batch size:** All jobs (apps and firmware) are processed in batches of max. **10 devices** by default; batches run one after another. To change this, edit the line `set BATCHSIZE=10` in the launcher (allowed: 1-100), or pass `-BatchSize <n>` when starting the script manually.

### Manual start

```powershell
pwsh -ExecutionPolicy Bypass -File .\EN-IEM-AppInstaller.ps1
```

The script then guides you interactively through: API choice -> IEM configuration -> mode (app or firmware) -> selection -> confirmation -> execution -> verification. At every selection step, `q` goes back one step.

## License

This project is licensed under the [MIT License](LICENSE).

---

# IEM-AppInstaller (Deutsch)

*[English version further above](#iem-appinstaller)*

Ein PowerShell-Skript zur interaktiven Verwaltung von Apps und Firmware auf Siemens Industrial Edge Devices über [`iectl`](https://docs.industrial-operations-x.siemens.cloud/r/en-us/latest/industrial-edge-platform-operation-apis-references/industrial-edge-control-iectl), das Command-Line-Interface des Industrial Edge Management (IEM).

> **Hinweis:** Dies ist ein privates, selbst entwickeltes Skript und **kein offizielles Siemens-Produkt**. Es wird ohne Gewähr bereitgestellt und dient in erster Linie als **Beispiel dafür, wie sich Automatisierungen rund um `iectl` umsetzen lassen**. Vor dem produktiven Einsatz sollte der Code geprüft und an die eigene Umgebung angepasst werden.

## Was das Skript kann

- **Apps verwalten:** Installieren, Updaten, Downgraden und Deinstallieren von Apps auf mehreren Edge Devices gleichzeitig (Batch-Betrieb), inklusive Live-Fortschrittsanzeige und Verifikation nach Abschluss.
- **Firmware aktualisieren:** Ermittelt pro Gerät automatisch den nächsten kompatiblen Firmware-Schritt (kein Versionssprung) und führt das Update mit Fortschrittsanzeige aus.
- **Zwei API-Generationen:** Unterstützt sowohl die etablierte `iem`- als auch die aktuellere `iem-v2`-API von `iectl` und lässt zu Beginn die Wahl offen.
- **Geräteauswahl mit Online-Erkennung:** Zeigt den Online-/Offline-Status je Gerät; Geräte ohne sicheren Online-Status sind standardmäßig gesperrt und lassen sich gezielt freischalten.
- **Konfigurationsverwaltung:** Vorhandene `iectl`-Konfigurationen auswählen, neue anlegen oder nicht mehr benötigte löschen – direkt aus dem Skriptmenü.

## Voraussetzungen

| Komponente | Anforderung |
|---|---|
| Betriebssystem | Windows – **Linux wird derzeit nicht unterstützt** (siehe Hinweis unten) |
| PowerShell | [Version 7.0](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows?view=powershell-7.6) oder neuer (`pwsh`) – **nicht** Windows PowerShell 5.1 |
| `iectl` | Installiert und im `PATH` verfügbar (siehe unten) |
| Zugangsdaten | URL, Benutzername und Passwort des IEM |

> **Linux:** Das Skript wird derzeit nur für Windows entwickelt und getestet. PowerShell 7 gibt es zwar auch für Linux, die Ausführung dort wird aber nicht unterstützt.

Weitere Angaben (z. B. IP-Adressen einzelner Edge Devices) sind nicht nötig – das Skript ermittelt alles Weitere selbst über die IEM-API.

## `iectl` installieren

`iectl` ist das offizielle Kommandozeilen-Tool von Siemens für Industrial Edge und wird über den [**Industrial Edge Hub**](https://iehub.eu1.edge.siemens.cloud) bzw. das Industrial Edge Downloadcenter bereitgestellt. Die vollständige, aktuelle Dokumentation (Befehlsreferenz, Konfiguration, Versionshinweise) findet sich hier:

[`iectl`-Dokumentation (Siemens Industrial Operations X)](https://docs.industrial-operations-x.siemens.cloud/r/en-us/latest/industrial-edge-platform-operation-apis-references/industrial-edge-control-iectl)

Das passende `iectl`-Release für Windows lässt sich über den Industrial Edge Hub des jeweiligen IEM beziehen (Bereich *Downloads*/*Developer tools*).

### Windows

1. Das Windows-Release von `iectl` herunterladen und entpacken.
2. `iectl.exe` an einen dauerhaften Ort legen, z. B. `C:\Tools\iectl\iectl.exe`.
3. Diesen Ordner in einer **Admin-PowerShell** dem systemweiten `PATH` hinzufügen:

   ```powershell
   [Environment]::SetEnvironmentVariable("Path", $env:Path + ";C:\Tools\iectl", "Machine")
   ```

4. Neue Shell öffnen und die Installation prüfen:

   ```powershell
   iectl version
   ```

## Verwendung

Es gibt zwei Varianten des Skripts:

- **`DE-IEM-AppInstaller.ps1`** - Konsolenausgabe nur auf Deutsch.
- **`EN-IEM-AppInstaller.ps1`** - identische Funktionalität, Konsolenausgabe nur auf Englisch.

### Windows (empfohlen)

Einfach die passende Startdatei im Explorer doppelklicken oder aus einer Shell aufrufen:

- **`Start-DE.cmd`** - startet die deutsche Version
- **`Start-EN.cmd`** - startet die englische Version

```powershell
.\Start-DE.cmd
```

Die Startdateien rufen PowerShell 7 mit `-ExecutionPolicy Bypass` nur für diesen einen Prozess auf. Dadurch entfällt auf Standard-Windows-Installationen der Fehler *„Die Ausführung von Skripts ist auf diesem System deaktiviert“*, ohne dass Systemeinstellungen geändert werden.

**Batch-Größe:** Alle Aufträge (Apps und Firmware) werden standardmäßig in Batches à max. **10 Geräte** abgearbeitet, die Batches laufen nacheinander. Zum Ändern in der Startdatei die Zeile `set BATCHSIZE=10` anpassen (erlaubt: 1–100) oder beim manuellen Start `-BatchSize <n>` angeben.

### Manueller Start

```powershell
pwsh -ExecutionPolicy Bypass -File .\DE-IEM-AppInstaller.ps1
```

Das Skript führt anschließend interaktiv durch: API-Wahl → IEM-Konfiguration → Modus (App oder Firmware) → Auswahl → Bestätigung → Ausführung → Verifikation. An jeder Auswahlstelle führt `q` einen Schritt zurück.

## Lizenz

Dieses Projekt steht unter der [MIT-Lizenz](LICENSE).
