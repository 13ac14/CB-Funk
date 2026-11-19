@echo off
REM Lokaler Build des Windows-Installers (Flutter und Inno Setup 6 muessen installiert sein)
cd /d "%~dp0\.."
if not exist windows\runner (
  flutter create --platforms=android,windows --project-name cb_funk --org de.cbfunk .
)
copy /Y assets\icons\app_icon.ico windows\runner\resources\app_icon.ico
call flutter pub get || exit /b 1
call flutter build windows --release || exit /b 1
if not exist installer\vc_redist.x64.exe (
  powershell -Command "Invoke-WebRequest https://aka.ms/vs/17/release/vc_redist.x64.exe -OutFile installer\vc_redist.x64.exe"
)
"%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe" /DAppVersion=1.2.6 installer\cbfunk.iss || exit /b 1
echo Fertig: installer\Output\
