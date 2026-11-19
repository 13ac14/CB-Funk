; Inno Setup Skript fuer CB-Funk (Windows 10 und 11, 64 Bit)
; Aufruf (aus dem Projektordner):
;   ISCC.exe /DAppVersion=1.3.0 installer\cbfunk.iss
; Voraussetzung: "flutter build windows --release" wurde vorher ausgefuehrt.
;
; Die Visual-C++-Laufzeit (msvcp140.dll usw.) liegt seit 1.3.0 direkt im
; Programmordner (siehe windows/CMakeLists.txt). Ein separates
; vc_redist-Paket ist nicht mehr noetig.

#define AppName "CB-Funk"
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppExe "cb_funk.exe"
#define SourceDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{4B1C33F2-63C4-4100-8688-0F36D60F0972}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=CB-Funk
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=Output
OutputBaseFilename=CB-Funk-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Flutter unterstuetzt nur noch Windows 10 und neuer
MinVersion=10.0
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
CloseApplications=yes

[Languages]
Name: "german"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; Reste aelterer Versionen (Fenster-Plugins wurden in 1.3.0 ersetzt)
Type: files; Name: "{app}\window_manager_plugin.dll"
Type: files; Name: "{app}\screen_retriever_windows_plugin.dll"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Registry]
; Bei einem Absturz legt Windows ein Speicherabbild nach
; %LOCALAPPDATA%\CB-Funk\crash (dort liegt auch cb_funk_debug.log).
; Damit laesst sich spaeter sehen, WO es abgestuerzt ist.
Root: HKLM; Subkey: "SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\{#AppExe}"; Flags: uninsdeletekey
Root: HKLM; Subkey: "SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\{#AppExe}"; ValueType: expandsz; ValueName: "DumpFolder"; ValueData: "%LOCALAPPDATA%\CB-Funk\crash"
Root: HKLM; Subkey: "SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\{#AppExe}"; ValueType: dword; ValueName: "DumpCount"; ValueData: "5"
Root: HKLM; Subkey: "SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\{#AppExe}"; ValueType: dword; ValueName: "DumpType"; ValueData: "1"

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[Code]
// Windows "N"/"KN"-Editionen haben ohne "Media Feature Pack" kein
// Media Foundation (mfplat.dll). Das Mikrofon-Plugin braucht es, ohne
// startet CB-Funk gar nicht.
function InitializeSetup: Boolean;
begin
  Result := True;
  if not FileExists(ExpandConstant('{sys}\mfplat.dll')) then
  begin
    MsgBox('Auf diesem PC fehlt die Windows-Medienunterstützung (Media Foundation).' + #13#10 + #13#10 +
      'Das ist bei Windows-Ausgaben mit "N" im Namen der Fall. Ohne sie startet CB-Funk nicht.' + #13#10 + #13#10 +
      'Abhilfe: Einstellungen > Apps > Optionale Features > Feature hinzufügen > "Media Feature Pack" installieren und den PC neu starten.' + #13#10 + #13#10 +
      'Die Installation wird trotzdem fortgesetzt.',
      mbInformation, MB_OK);
  end;
end;
