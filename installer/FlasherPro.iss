[Setup]
AppId={{8D2A4B68-0B54-4D1C-9A11-F1A5E2B31000}}
AppName=FlasherPro
AppVersion=1.0.0
AppPublisher=FlasherPro
DefaultDirName={localappdata}\Programs\FlasherPro
DefaultGroupName=FlasherPro
DisableProgramGroupPage=yes
OutputDir=.
OutputBaseFilename=FlasherPro-Setup-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\FlasherPro.exe

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\FlasherPro"; Filename: "{app}\FlasherPro.exe"
Name: "{autodesktop}\FlasherPro"; Filename: "{app}\FlasherPro.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\FlasherPro.exe"; Description: "Launch FlasherPro"; Flags: postinstall nowait skipifsilent
