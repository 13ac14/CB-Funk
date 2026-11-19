# CB-Funk: Prueft, ob dieser PC die App bauen kann (Windows-exe und Android-APK).
#
# Aufruf (im Projektordner, normale PowerShell, KEINE Adminrechte noetig):
#   powershell -ExecutionPolicy Bypass -File tools\build_check.ps1
#
# Ergebnis: Uebersicht im Fenster und ausfuehrlicher Bericht auf dem Desktop
# (CB-Funk-Buildcheck.txt). Den Bericht bei Problemen weitergeben.

$ErrorActionPreference = 'Continue'
$projekt = Split-Path -Parent $PSScriptRoot
$bericht = Join-Path ([Environment]::GetFolderPath('Desktop')) 'CB-Funk-Buildcheck.txt'
$zeilen = New-Object System.Collections.Generic.List[string]
$probleme = 0
$warnungen = 0

function Melde([string]$stufe, [string]$text, [string]$tipp = '') {
    $farbe = @{ OK = 'Green'; WARNUNG = 'Yellow'; FEHLER = 'Red'; INFO = 'Gray' }[$stufe]
    Write-Host ("[{0,-7}] {1}" -f $stufe, $text) -ForegroundColor $farbe
    $zeilen.Add(("[{0,-7}] {1}" -f $stufe, $text))
    if ($tipp) {
        Write-Host ("          -> {0}" -f $tipp) -ForegroundColor $farbe
        $zeilen.Add(("          -> {0}" -f $tipp))
    }
    if ($stufe -eq 'FEHLER') { $script:probleme++ }
    if ($stufe -eq 'WARNUNG') { $script:warnungen++ }
}

function Abschnitt([string]$titel) {
    Write-Host ''
    Write-Host "== $titel ==" -ForegroundColor Cyan
    $zeilen.Add('')
    $zeilen.Add("== $titel ==")
}

$sollFlutter = '3.41.1'
$sollNdk = '28.2.13676358'

# ---------------------------------------------------------------- System
Abschnitt 'System'
$os = Get-CimInstance Win32_OperatingSystem
Melde INFO ("Windows: {0} (Build {1})" -f $os.Caption, $os.BuildNumber)
$ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
if ($ramGb -lt 8) {
    Melde FEHLER "Arbeitsspeicher: $ramGb GB" 'Fuer den Android-Build sind mindestens 8 GB noetig.'
} elseif ($ramGb -lt 12) {
    Melde WARNUNG "Arbeitsspeicher: $ramGb GB" 'Beim APK-Bauen alle anderen Programme schliessen.'
} else {
    Melde OK "Arbeitsspeicher: $ramGb GB"
}
foreach ($lw in @($env:SystemDrive, (Split-Path -Qualifier $projekt)) | Select-Object -Unique) {
    $frei = [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$lw'").FreeSpace / 1GB)
    if ($frei -lt 15) { Melde FEHLER "Freier Platz auf $lw : $frei GB" 'Android-SDK, NDK und Gradle brauchen zusammen rund 15 GB.' }
    else { Melde OK "Freier Platz auf $lw : $frei GB" }
}
$lp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
if ($lp -eq 1) { Melde OK 'Lange Dateipfade (ueber 260 Zeichen) sind erlaubt' }
else { Melde WARNUNG 'Lange Dateipfade (ueber 260 Zeichen) sind NICHT erlaubt' 'Als Admin: reg add HKLM\SYSTEM\CurrentControlSet\Control\FileSystem /v LongPathsEnabled /t REG_DWORD /d 1 /f  (danach neu anmelden)' }

# ---------------------------------------------------------------- Pfade
Abschnitt 'Pfade'
Melde INFO "Projektordner: $projekt ($($projekt.Length) Zeichen)"
if ($projekt -match ' ') {
    Melde WARNUNG 'Der Projektordner enthaelt Leerzeichen' 'Empfehlung: Projekt nach C:\dev\cb_funk legen.'
}
if ($projekt.Length -gt 60) {
    Melde WARNUNG 'Der Projektordner liegt sehr tief' 'Beim Android-Build entstehen Pfade mit ueber 200 Zeichen. Kuerzer ist sicherer (z. B. C:\dev\cb_funk).'
}
$pubCache = if ($env:PUB_CACHE) { $env:PUB_CACHE } else { Join-Path $env:LOCALAPPDATA 'Pub\Cache' }
Melde INFO "Paket-Cache (PUB_CACHE): $pubCache"
if ($pubCache -match ' ') {
    Melde WARNUNG 'Der Paket-Cache liegt in einem Pfad mit Leerzeichen (Benutzername)' 'Empfehlung: Umgebungsvariable PUB_CACHE=C:\dev\pub-cache setzen, dann "flutter clean" und "flutter pub get".'
}
if ($env:USERPROFILE -match ' ') {
    Melde INFO "Der Benutzername enthaelt Leerzeichen ($env:USERPROFILE). Getestet: geht, aber die Pfade werden lang."
}

# ---------------------------------------------------------------- Flutter
Abschnitt 'Flutter'
# flutter und flutter.bat im selben Ordner sind EINE Installation
$flutterAlle = @(Get-Command flutter -All -ErrorAction SilentlyContinue | ForEach-Object { Split-Path -Parent $_.Source } | Select-Object -Unique)
if ($flutterAlle.Count -eq 0) {
    Melde FEHLER 'flutter wurde nicht gefunden (nicht im PATH)' 'Flutter installieren und den Ordner flutter\bin zum PATH hinzufuegen.'
} else {
    if ($flutterAlle.Count -gt 1) { Melde WARNUNG ("Mehrere Flutter-Installationen im PATH: " + ($flutterAlle -join ', ')) 'Nur eine behalten, sonst baut evtl. die falsche Version.' }
    $fv = (& flutter --version --machine 2>$null | Out-String)
    $ver = if ($fv -match '"frameworkVersion"\s*:\s*"([^"]+)"') { $Matches[1] } else { '?' }
    if ($ver -eq $sollFlutter) { Melde OK "Flutter $ver ($($flutterAlle[0]))" }
    else { Melde WARNUNG "Flutter $ver gefunden, das Projekt ist auf $sollFlutter abgestimmt" "Wechseln mit: cd <flutter-Ordner>; git fetch; git checkout $sollFlutter; flutter --version" }
    if ($flutterAlle[0] -match ' ') { Melde FEHLER 'Flutter liegt in einem Pfad mit Leerzeichen' 'Flutter nach C:\flutter verschieben.' }
}

# ---------------------------------------------------------------- Visual Studio (Windows-exe)
Abschnitt 'Visual Studio (fuer die Windows-exe)'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
    Melde FEHLER 'Visual Studio ist nicht installiert' 'Visual Studio 2022 Community mit der Workload "Desktopentwicklung mit C++" installieren (NICHT VS Code, das ist etwas anderes).'
} else {
    $vs = & $vswhere -all -prerelease -products * -format json | ConvertFrom-Json
    if (-not $vs) { Melde FEHLER 'Kein Visual Studio gefunden' 'Visual Studio 2022 Community mit "Desktopentwicklung mit C++" installieren.' }
    foreach ($i in $vs) {
        Melde INFO ("{0} {1} in {2}" -f $i.displayName, $i.installationVersion, $i.installationPath)
        if ($i.isComplete -eq $false) {
            Melde FEHLER 'Visual Studio meldet sich selbst als UNVOLLSTAENDIG' 'Flutter verweigert dann den Windows-Build ("Unable to find suitable Visual Studio toolchain"), obwohl alles installiert aussieht. Abhilfe: Visual Studio Installer oeffnen, dort "Aktualisieren" bzw. "Weitere > Reparieren" ausfuehren und den PC neu starten.'
        }
        if ($i.isLaunchable -eq $false) { Melde WARNUNG 'Visual Studio ist als nicht startbar markiert' 'Im Visual Studio Installer "Reparieren".' }
    }
    $cpp = & $vswhere -all -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($cpp) { Melde OK 'C++-Compiler (MSVC x64) vorhanden' }
    else { Melde FEHLER 'C++-Compiler fehlt' 'Im Visual Studio Installer "Aendern" > Workload "Desktopentwicklung mit C++" anhaken.' }
    $sdks = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\Include" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    if ($sdks) { Melde OK ("Windows SDK: " + ($sdks -join ', ')) } else { Melde FEHLER 'Kein Windows 10/11 SDK' 'Im Visual Studio Installer unter "Einzelne Komponenten" ein Windows 11 SDK anhaken.' }
}
$iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
if (Test-Path $iscc) { Melde OK 'Inno Setup 6 vorhanden (fuer den Installer)' }
else { Melde WARNUNG 'Inno Setup 6 fehlt' 'Nur fuer den Installer noetig: https://jrsoftware.org/isdl.php' }

# ---------------------------------------------------------------- Java (APK)
Abschnitt 'Java (fuer die APK)'
$javaExe = $null
$jdkCfg = (& flutter config --list 2>$null | Select-String 'jdk-dir:\s*(.+)$')
if ($jdkCfg) { $javaExe = Join-Path $jdkCfg.Matches[0].Groups[1].Value.Trim() 'bin\java.exe'; Melde INFO "Flutter nutzt das JDK aus 'flutter config --jdk-dir'" }
elseif ($env:JAVA_HOME) { $javaExe = Join-Path $env:JAVA_HOME 'bin\java.exe'; Melde INFO "JAVA_HOME = $env:JAVA_HOME" }
else {
    $as = Join-Path $env:ProgramFiles 'Android\Android Studio\jbr\bin\java.exe'
    if (Test-Path $as) { $javaExe = $as; Melde INFO 'Java von Android Studio (jbr)' }
    else { $j = Get-Command java -ErrorAction SilentlyContinue; if ($j) { $javaExe = $j.Source } }
}
if (-not $javaExe -or -not (Test-Path $javaExe)) {
    Melde FEHLER 'Kein Java (JDK) gefunden' 'JDK 17 oder 21 installieren (z. B. Microsoft Build of OpenJDK 17) oder Android Studio installieren.'
} else {
    $jv = (& $javaExe -version 2>&1 | Out-String)
    $major = if ($jv -match 'version "(\d+)') { [int]$Matches[1] } else { 0 }
    if ($major -eq 1) { $major = 8 }
    if ($major -ge 17 -and $major -le 21) { Melde OK "Java $major ($javaExe)" }
    elseif ($major -gt 21) { Melde WARNUNG "Java $major ($javaExe)" 'Getestet ist Java 17 bis 21. Bei Gradle-Fehlern JDK 17 nehmen: flutter config --jdk-dir "<Pfad zum JDK 17>"' }
    else { Melde FEHLER "Java $major ist zu alt ($javaExe)" 'Gebraucht wird JDK 17 oder neuer: flutter config --jdk-dir "<Pfad zum JDK 17>"' }
}
$gradleGlobal = Get-Command gradle -ErrorAction SilentlyContinue
if ($gradleGlobal) {
    Melde WARNUNG "Ein separates Gradle ist installiert ($($gradleGlobal.Source))" 'Nie "gradle ..." direkt aufrufen. Immer "flutter build apk" (oder android\gradlew). Das Projekt bringt seine passende Gradle-Version (8.14.3) selbst mit; ein fremdes Gradle 9.x passt nicht zum Android-Plugin.'
}

# ---------------------------------------------------------------- Android SDK
Abschnitt 'Android SDK (fuer die APK)'
$sdk = $null
$sdkCfg = (& flutter config --list 2>$null | Select-String 'android-sdk:\s*(.+)$')
if ($sdkCfg) { $sdk = $sdkCfg.Matches[0].Groups[1].Value.Trim() }
elseif ($env:ANDROID_HOME) { $sdk = $env:ANDROID_HOME }
elseif ($env:ANDROID_SDK_ROOT) { $sdk = $env:ANDROID_SDK_ROOT }
else { $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
if (-not (Test-Path $sdk)) {
    Melde FEHLER "Android SDK nicht gefunden ($sdk)" 'Android Studio installieren und einmal starten (richtet das SDK ein), dann "flutter doctor --android-licenses".'
} else {
    Melde OK "Android SDK: $sdk"
    if ($sdk -match ' ') { Melde WARNUNG 'Das Android SDK liegt in einem Pfad mit Leerzeichen' 'Getestet: geht. Bei C++-Fehlern das SDK nach C:\Android\sdk verschieben und "flutter config --android-sdk C:\Android\sdk".' }
    $plat = Get-ChildItem (Join-Path $sdk 'platforms') -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    if ($plat -contains 'android-36') { Melde OK 'Android-Plattform 36 vorhanden' } else { Melde INFO ("Plattformen: " + ($plat -join ', ') + ' (36 wird beim ersten Build nachgeladen)') }
    $ndks = Get-ChildItem (Join-Path $sdk 'ndk') -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
    if ($ndks -contains $sollNdk) { Melde OK "NDK $sollNdk vorhanden" }
    else { Melde INFO "NDK $sollNdk fehlt noch, wird beim ersten Build geladen (ca. 1 GB, dauert)" }
    $kaputt = Get-ChildItem (Join-Path $sdk 'ndk') -Directory -ErrorAction SilentlyContinue | Where-Object { -not (Test-Path (Join-Path $_.FullName 'source.properties')) }
    foreach ($k in $kaputt) { Melde FEHLER "Unvollstaendiges NDK: $($k.FullName)" 'Ordner loeschen (abgebrochener Download), beim naechsten Build wird es neu geladen.' }
    $lic = Get-ChildItem (Join-Path $sdk 'licenses') -ErrorAction SilentlyContinue
    if ($lic) { Melde OK 'Android-Lizenzen akzeptiert' } else { Melde FEHLER 'Android-Lizenzen nicht akzeptiert' 'flutter doctor --android-licenses  (alles mit y bestaetigen)' }
}

# ---------------------------------------------------------------- Virenscanner
Abschnitt 'Virenscanner'
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    if ($mp.RealTimeProtectionEnabled) {
        Melde INFO 'Windows Defender Echtzeitschutz ist an. Der erste Build kann dadurch deutlich laenger dauern (zehntausende kleine Dateien).'
        Melde INFO 'Optional (als Admin) Ausnahmen fuer Projektordner, Flutter-Ordner, Pub-Cache, Android-SDK und %USERPROFILE%\.gradle einrichten.'
    }
} catch { Melde INFO 'Status des Virenscanners nicht lesbar' }

# ---------------------------------------------------------------- flutter doctor
Abschnitt 'flutter doctor -v (Rohdaten)'
if ($flutterAlle.Count -gt 0) {
    Write-Host 'flutter doctor laeuft ...' -ForegroundColor Gray
    $doc = & flutter doctor -v 2>&1 | Out-String
    $zeilen.Add($doc)
    if ($doc -match 'Visual Studio[^\r\n]*\r?\n[\s\S]*?installation is incomplete') {
        Melde FEHLER 'flutter doctor: Visual Studio-Installation unvollstaendig' 'Visual Studio Installer > Reparieren, danach Neustart.'
    }
}

# ---------------------------------------------------------------- Ergebnis
Abschnitt 'Ergebnis'
if ($probleme -eq 0 -and $warnungen -eq 0) { Melde OK 'Alles bereit. Bauen mit: installer\build_installer.bat  bzw.  flutter build apk --release' }
else { Melde INFO "$probleme Fehler, $warnungen Warnungen. Zuerst die FEHLER beheben." }
$zeilen | Out-File -FilePath $bericht -Encoding utf8
Write-Host ''
Write-Host "Bericht gespeichert: $bericht" -ForegroundColor Cyan
