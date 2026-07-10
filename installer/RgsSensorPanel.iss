#define AppName "RGS Sensor Panel"
#define AppExeName "rgs_sensor_panel_flutter.exe"
#define BackendTaskName "RGS Sensor Panel Hardware Sensor Backend"
#define BackendProcessName "rgs-sensor-backend.exe"
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
Source: "..\flutter_desktop\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.exp,*.lib,*.pdb"

[Icons]
Name: "{group}\RGS Sensor Panel"; Filename: "{app}\{#AppExeName}"
Name: "{commondesktop}\RGS Sensor Panel"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch RGS Sensor Panel"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"
Type: filesandordirs; Name: "{localappdata}\RahnGamingStudio\SensorPanel"
Type: files; Name: "{userstartup}\RGS Sensor Panel.lnk"
Type: files; Name: "{commonstartup}\RGS Sensor Panel.lnk"

[Code]
procedure RunHidden(FileName, Parameters: string);
var
  ResultCode: Integer;
begin
  Exec(FileName, Parameters, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure StopBackendRuntime();
begin
  RunHidden(ExpandConstant('{sys}\schtasks.exe'), '/End /TN "{#BackendTaskName}"');
  RunHidden(ExpandConstant('{sys}\taskkill.exe'), '/F /IM "{#AppExeName}"');
  RunHidden(ExpandConstant('{sys}\taskkill.exe'), '/F /IM "{#BackendProcessName}"');
end;

procedure DeleteBackendTask();
begin
  RunHidden(ExpandConstant('{sys}\schtasks.exe'), '/Delete /TN "{#BackendTaskName}" /F');
end;

procedure DeleteStartupEntries();
begin
  RunHidden(ExpandConstant('{sys}\reg.exe'), 'delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "RGS Sensor Panel" /f');
  RunHidden(ExpandConstant('{sys}\reg.exe'), 'delete "HKLM\Software\Microsoft\Windows\CurrentVersion\Run" /v "RGS Sensor Panel" /f');
end;

procedure WipeLocalRuntimeData();
var
  StudioDir: string;
begin
  DelTree(ExpandConstant('{localappdata}\RahnGamingStudio\SensorPanel'), True, True, True);
  StudioDir := ExpandConstant('{localappdata}\RahnGamingStudio');
  RemoveDir(StudioDir);
  DeleteFile(AddBackslash(GetEnv('TEMP')) + 'rgs-sensor-backend.log');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    StopBackendRuntime();
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
  begin
    StopBackendRuntime();
    DeleteBackendTask();
    DeleteStartupEntries();
    WipeLocalRuntimeData();
  end;
end;
