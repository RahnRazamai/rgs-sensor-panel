#define AppName "RGS Sensor Panel"
#define AppExeName "rgs_sensor_panel_flutter.exe"
#ifndef AppVersion
#define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6D6C42D2-9F6D-4DB2-9A84-78AD2205ACF8}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Rahn Gaming Studio
AppPublisherURL=https://github.com/RahnRazamai
AppSupportURL=https://github.com/sponsors/RahnRazamai
AppUpdatesURL=https://github.com/RahnRazamai/rgs-sensor-panel/releases
DefaultDirName={autopf}\Rahn Gaming Studio\RGS Sensor Panel
DefaultGroupName=Rahn Gaming Studio\RGS Sensor Panel
DisableProgramGroupPage=yes
OutputBaseFilename=RGS-Sensor-Panel-{#AppVersion}-Setup
SetupIconFile=..\flutter_desktop\assets\rgs-logo.ico
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "..\flutter_desktop\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\RGS Sensor Panel"; Filename: "{app}\{#AppExeName}"
Name: "{commondesktop}\RGS Sensor Panel"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch RGS Sensor Panel"; Flags: nowait postinstall skipifsilent
