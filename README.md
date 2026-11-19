# CB-Funk (Flutter)

Android-APK und Windows-Installer (Windows 10 und 11, 64 Bit) aus einer Code-Basis.
Flutter-Version: 3.41.1 (im GitHub-Workflow fest eingestellt).

## Wichtigste Einstellung VOR dem Bauen
`lib/config/app_config.dart` -> `mqttHost` auf die IP/Domain des Linux-Servers setzen.
Auf dem Server (Mosquitto), z. B. /etc/mosquitto/conf.d/cbfunk.conf:

    listener 1883
    allow_anonymous true

## Bauen ohne lokale Entwicklungsumgebung (GitHub)
1. Diesen Ordner in ein GitHub-Repository hochladen (inkl. Ordner .github).
2. Reiter "Actions" -> "Build CB-Funk" -> "Run workflow".
3. Nach wenigen Minuten unter "Artifacts" herunterladen:
   - CB-Funk-apk                     -> CB-Funk.apk
   - CB-Funk-Windows-Installer       -> CB-Funk-Setup-<Version>.exe (Desktop-Verknuepfung waehlbar)
   - CB-Funk-windows-portable        -> Ordner ohne Installation

## Auf dem eigenen PC bauen

Zuerst pruefen, ob der PC bereit ist (zeigt Fehler mit Abhilfe, Bericht landet auf dem Desktop):

    powershell -ExecutionPolicy Bypass -File toolsuild_check.ps1

Was gebraucht wird:
- Flutter 3.41.1, am besten unter C:lutter (kein Pfad mit Leerzeichen)
- Fuer die exe: Visual Studio 2022 Community (NICHT VS Code) mit "Desktopentwicklung mit C++".
  Meldet der Visual Studio Installer die Installation als unvollstaendig, baut Flutter nicht
  ("Unable to find suitable Visual Studio toolchain"), obwohl alles installiert aussieht:
  im Installer "Reparieren", dann Neustart.
- Fuer die APK: Android Studio (bringt Android SDK und Java mit), danach einmal
  `flutter doctor --android-licenses`.
- Nie `gradle ...` direkt aufrufen, immer `flutter build apk`. Das Projekt bringt seine
  Gradle-Version (8.14.3) selbst mit; ein separat installiertes Gradle 9 passt nicht.

Empfehlungen:
- Projekt nach C:\dev\cb_funk legen. Beim APK-Build entstehen Pfade bis ca. 250 Zeichen,
  Windows erlaubt ohne Einstellung nur 260. Lange Pfade erlauben (als Admin):
  `reg add HKLM\SYSTEM\CurrentControlSet\Control\FileSystem /v LongPathsEnabled /t REG_DWORD /d 1 /f`
- Der erste APK-Build laedt 3-4 GB nach (Gradle, NDK, Pakete) und dauert entsprechend.
  Danach: APK ca. 2-5 Minuten, exe ca. 2 Minuten.
- Ohne eigene Entwicklungsumgebung: einfach auf GitHub pushen, der Workflow baut beides.

## Lokal bauen (Flutter + Inno Setup 6 vorhanden)
    installer\build_installer.bat       (Windows-Installer)
    flutter build apk --release         (Ergebnis: buildpp\outputslutter-apkpp-release.apk)

## Struktur
- lib/config      Server-Konstanten (fest im Code)
- lib/audio       MQTT-Audio, Squelch/Rauschen, Echo, Roger-Beep, Clarifier, Gateway-VOX
- lib/gateway     PTT-Treiber (seriell RTS/DTR, USB-HID CM108/AIOC)
- lib/services    MQTT
- lib/state       Zustand, Tasten
- lib/ui          Oberflaeche und Einstellungsdialog
- lib/platform    Windows-Fenster (ziehen, minimieren, schliessen)
- windows/runner  Nativer Windows-Teil (randloses Fenster, Kanal "de.cbfunk/window")
- android         Android-Projekt (MainActivity: USB-HID-PTT, Hintergrund-Ton-Dienst)
- installer       Inno-Setup-Skript
- assets/icons    App-Icon (Windows .ico, Android mipmaps)
- test            Einfache Tests (Kanaltabelle, mu-law, Paketformat)

## Hinweise
- Windows: Beim ersten Start Mikrofonzugriff erlauben (Einstellungen > Datenschutz > Mikrofon).
- Windows-Log: %LOCALAPPDATA%\CB-Funk\cb_funk_debug.log (wird ab 5 MB beim Start nach .old verschoben).
- Absturz-Abbilder (nur Installer-Version): %LOCALAPPDATA%\CB-Funk\crash\*.dmp
- Die Visual-C++-Laufzeit liegt im Programmordner, ein vc_redist ist nicht mehr noetig.
- Windows "N"-Ausgaben brauchen das "Media Feature Pack" (der Installer weist darauf hin).
- Android: Die APK ist mit dem Debug-Schluessel signiert (zum Installieren ausreichend;
  fuer den Play Store waere ein eigener Release-Schluessel noetig).
- Gateway: Die App muss im Vordergrund laufen; der Bildschirm bleibt dabei automatisch an.
- Einstellungen, Kanal, Regler und angelernte Tasten werden gespeichert.

## Aenderungen in 1.3.0 (Stabilitaet)
- Startet auch auf PCs ohne bzw. mit alter Visual-C++-Laufzeit (vorher: Start-Fehler oder
  Absturz in msvcp140.dll beim ersten Mikrofon-Zugriff).
- Fenster: wieder der Standard-Windows-Teil von Flutter, ohne Plugin window_manager.
  Verschieben/Minimieren macht Windows selbst; Fenster passt sich kleinen Bildschirmen an.
- Nur eine Instanz; ein zweiter Start holt das Fenster nach vorn.
- Sendetaste: Mikrofon-Start/-Stopp laufen nacheinander (schnelles Tippen fuehrte zu
  ueberlappenden Aufrufen im nativen Recorder).
- Einstellungen: es werden nur geaenderte Werte geschrieben; eine defekte Datei wird
  beiseitegelegt statt das Speichern dauerhaft zu blockieren.
- Beim Beenden (X, Alt+F4) wird eine laufende Sendung beendet und gespeichert.
- MQTT: Anzeige "Verbinde ..." waehrend automatischer Neuverbindung.
- COM-Port-Liste aus der Registry statt alle Ports zu oeffnen (haengt nicht mehr bei Bluetooth-Ports).
