; Inno Setup Skript fuer CB-Funk (Windows 8, 10, 11, 64 Bit)
; Aufruf (aus dem Projektordner):
;   ISCC.exe /DAppVersion=1.2.6 installer\cbfunk.iss
; Voraussetzung: "flutter build windows --release" wurde vorher ausgefuehrt.

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
; Windows 8 (6.2) und neuer
MinVersion=6.2
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
CloseApplications=yes

[Languages]
Name: "german"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Dirs]
Name: "{app}"; Permissions: users-full

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
#if FileExists("vc_redist.x64.exe")
Source: "vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall; Check: VCRedistNeeded
#endif

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
#if FileExists("vc_redist.x64.exe")
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Visual-C++-Laufzeit wird installiert ..."; Check: VCRedistNeeded
#endif
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[Code]
function VCRedistNeeded: Boolean;
var
  Installed: Cardinal;
begin
  Result := not (RegQueryDWordValue(HKLM64,
    'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', Installed)
    and (Installed = 1));
end;
