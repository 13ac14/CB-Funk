# CB-Funk (Flutter) - Final (Schritt 6)

Android-APK und Windows-Installer (Windows 8, 10, 11, 64 Bit) aus einer Code-Basis.

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

## Lokal bauen (Flutter + Inno Setup 6 vorhanden)
    installer\build_installer.bat       (Windows-Installer)
    flutter build apk --release         (nach "flutter create ..." wie im Workflow)

## Struktur
- lib/config      Server-Konstanten (fest im Code)
- lib/audio       MQTT-Audio, Squelch/Rauschen, Echo, Roger-Beep, Clarifier, Gateway-VOX
- lib/gateway     PTT-Treiber (seriell RTS/DTR, USB-HID CM108/AIOC)
- lib/services    MQTT
- lib/state       Zustand, Tasten
- lib/ui          Oberflaeche und Einstellungsdialog
- android_native  Kotlin-Code fuer USB-HID (Android), wird im Workflow eingebaut
- installer       Inno-Setup-Skript
- assets/icons    App-Icon (Windows .ico, Android mipmaps)
- test            Einfache Tests (Kanaltabelle, mu-law, Paketformat)

## Hinweise
- Windows: Beim ersten Start Mikrofonzugriff erlauben (Einstellungen > Datenschutz > Mikrofon).
- Android: Die APK ist mit dem Debug-Schluessel signiert (zum Installieren ausreichend;
  fuer den Play Store waere ein eigener Release-Schluessel noetig).
- Gateway: Die App muss im Vordergrund laufen; der Bildschirm bleibt dabei automatisch an.
- Einstellungen, Kanal, Regler und angelernte Tasten werden gespeichert.
