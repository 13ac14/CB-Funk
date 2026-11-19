@echo off
REM Lokaler Build des Windows-Installers (Flutter und Inno Setup 6 muessen installiert sein)
REM Ergebnis: installer\Output\CB-Funk-Setup-<Version>.exe und CB-Funk-<Version>-portable.zip
cd /d "%~dp0\.."
if not exist windows\runner (
  flutter create --platforms=android,windows --project-name cb_funk --org de.cbfunk .
)
copy /Y assets\icons\app_icon.ico windows\runner\resources\app_icon.ico
call flutter pub get || exit /b 1
call flutter build windows --release || exit /b 1

REM Version aus pubspec.yaml lesen (z. B. "version: 1.3.0+30" -> 1.3.0)
for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "(Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value"`) do set APPVER=%%v
echo Version: %APPVER%

"%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" /DAppVersion=%APPVER% installer\cbfunk.iss || exit /b 1
powershell -NoProfile -Command "Compress-Archive -Path 'build\windows\x64\runner\Release\*' -DestinationPath 'installer\Output\CB-Funk-%APPVER%-portable.zip' -Force" || exit /b 1
echo Fertig: installer\Output\
