#define MyAppName "局域快传"
#ifndef MyAppVersion
  #define MyAppVersion "1.1.1"
#endif
#define MyAppPublisher "laincarl"
#define MyAppExeName "lanlink.exe"

[Setup]
AppId={{88A47F1B-E416-4D4A-8D87-970A13B197F3}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\..\dist
OutputBaseFilename=局域快传-windows-x64-setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
CloseApplications=yes
ChangesAssociations=yes

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式："; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; IconIndex: 0
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; IconIndex: 0; Tasks: desktopicon

[Run]
Filename: "{cmd}"; Parameters: "/C netsh advfirewall firewall delete rule name=""局域快传 UDP 发现"" >nul 2>&1 & netsh advfirewall firewall add rule name=""局域快传 UDP 发现"" dir=in action=allow protocol=UDP localport=45678 program=""{app}\{#MyAppExeName}"""; Flags: runhidden
Filename: "{cmd}"; Parameters: "/C netsh advfirewall firewall delete rule name=""局域快传 TCP 传输"" >nul 2>&1 & netsh advfirewall firewall add rule name=""局域快传 TCP 传输"" dir=in action=allow protocol=TCP localport=45679 program=""{app}\{#MyAppExeName}"""; Flags: runhidden

[UninstallRun]
Filename: "{cmd}"; Parameters: "/C netsh advfirewall firewall delete rule name=""局域快传 UDP 发现"""; Flags: runhidden; RunOnceId: "RemoveUdpFirewallRule"
Filename: "{cmd}"; Parameters: "/C netsh advfirewall firewall delete rule name=""局域快传 TCP 传输"""; Flags: runhidden; RunOnceId: "RemoveTcpFirewallRule"
