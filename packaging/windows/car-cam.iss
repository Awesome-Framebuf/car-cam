; Car Cam for Windows: Inno Setup script. Built in CI (.github/workflows/desktop.yml):
;   flutter build windows --release
;   ISCC.exe /DAppVersion=x.y.z packaging\windows\car-cam.iss
; Output: packaging\windows\Output\CarCamSetup.exe
;
; This installer installs NO Wi-Fi driver. The AIC8800D80 dongle driver is the
; separate WiFi-Dongle-Install package.

#ifndef AppVersion
  #define AppVersion "2.0.0"
#endif

[Setup]
AppId={{6F2B8C1E-4C1D-4E7A-9B0E-CA7C0A36CA01}
AppName=Car Cam
AppVersion={#AppVersion}
AppPublisher=Awesome-Framebuf
AppPublisherURL=https://github.com/Awesome-Framebuf/car-cam
DefaultDirName={autopf}\Car Cam
DefaultGroupName=Car Cam
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=Output
OutputBaseFilename=CarCamSetup
SetupIconFile=car-cam.ico
UninstallDisplayIcon={app}\car_cam.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Car Cam"; Filename: "{app}\car_cam.exe"
Name: "{group}\Uninstall Car Cam"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Car Cam"; Filename: "{app}\car_cam.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\car_cam.exe"; Description: "{cm:LaunchProgram,Car Cam}"; Flags: nowait postinstall skipifsilent

[Code]
// Counts the Wi-Fi adapters ("Name : ..." lines of netsh wlan show interfaces).
function WifiAdapterCount(): Integer;
var
  TmpFile: String;
  Lines: TArrayOfString;
  I, Code: Integer;
  Line: String;
begin
  Result := 0;
  TmpFile := ExpandConstant('{tmp}\wlan.txt');
  if not Exec(ExpandConstant('{cmd}'), '/C netsh wlan show interfaces > "' + TmpFile + '"',
              '', SW_HIDE, ewWaitUntilTerminated, Code) then
    Exit;
  if not LoadStringsFromFile(TmpFile, Lines) then
    Exit;
  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    Line := Trim(Lines[I]);
    if (Pos('Name', Line) = 1) and (Pos(':', Line) > 0) then
      Result := Result + 1;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Code: Integer;
begin
  if CurStep <> ssPostInstall then
    Exit;

  // The car's DHCP offers itself as gateway: give dongle adapters a high
  // metric now so the car never becomes the internet route.
  Exec('powershell.exe',
       '-NoProfile -NonInteractive -Command "Get-NetAdapter | Where-Object { $_.InterfaceDescription -match ''AIC|8800'' } | ForEach-Object { Set-NetIPInterface -InterfaceIndex $_.ifIndex -InterfaceMetric 9000 }"',
       '', SW_HIDE, ewWaitUntilTerminated, Code);

  // Never fail the install over this: only a hint.
  if (WifiAdapterCount() < 2) and not WizardSilent() then
    MsgBox('Car Cam needs a second Wi-Fi adapter for the car, such as a USB dongle. ' +
           'For the AIC8800D80 (AX900) dongle, run WiFi-Dongle-Install first, ' +
           'or the setup program on the dongle''s own CD drive.',
           mbInformation, MB_OK);
end;
