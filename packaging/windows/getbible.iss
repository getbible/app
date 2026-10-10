; Inputs are supplied by scripts/release/package.py, after bundle validation.
; Install per user, including the app-local Microsoft CRT: no elevation or
; network download is required. Uninstall never touches private reader data.
[Setup]
AppId={{C4D87722-B27D-4A50-920F-A364762B19C8}
AppName=getBible.live
AppVersion={#AppVersion}
AppPublisher=Vast Development Method
AppPublisherURL=https://getbible.net/
AppSupportURL=https://github.com/getbible/app/issues
DefaultDirName={localappdata}\Programs\getBible.live
DefaultGroupName=getBible.live
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename={#OutputName}
VersionInfoVersion={#FileVersion}
SetupIconFile={#SourceRoot}\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\getbible_life.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
ChangesAssociations=yes

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\getBible.live"; Filename: "{app}\getbible_life.exe"

[Registry]
; Per-user protocol registration. Quote both executable and URI argument;
; the app validates the URI and never executes it through a command shell.
Root: HKCU; Subkey: "Software\Classes\getbible"; ValueType: string; ValueName: ""; ValueData: "URL:getBible passage"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\getbible"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\getbible\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\getbible_life.exe,0"
Root: HKCU; Subkey: "Software\Classes\getbible\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\getbible_life.exe"" ""%1"""

[Run]
Filename: "{app}\getbible_life.exe"; Description: "Open getBible.live"; Flags: nowait postinstall skipifsilent
