; Car Cam for Windows: Inno Setup script. Built in CI (.github/workflows/desktop.yml):
;   flutter build windows --release
;   ISCC.exe /DAppVersion=x.y.z packaging\windows\car-cam.iss
; Output: packaging\windows\Output\CarCamSetup.exe
;
; Installs the camera app only: no Wi-Fi driver, no network changes, no
; questions about adapters. Car Cam works with any Wi-Fi adapter.

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
