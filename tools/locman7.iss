; Установщик «Лоцман Lite» для Windows 7 SP1 x64 (Inno Setup 6).
; Ставится в профиль пользователя — права администратора не нужны. Нужен .NET Framework 4.8.
; iscc /DAppVersion=1.9.0 /DSourceDir=out7 /DOutDir=dist tools\locman7.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{A7C3F1D2-4B5E-4F6A-9C1D-7E2B3A4C5D60}
AppName=Лоцман Lite
AppVersion={#AppVersion}
AppVerName=Лоцман Lite {#AppVersion}
AppPublisher=atomicpel
AppPublisherURL=https://github.com/atomicpel/locman
DefaultDirName={localappdata}\Programs\Locman7
DefaultGroupName=Лоцман Lite
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir={#OutDir}
OutputBaseFilename=Locman-Lite-{#AppVersion}-win7-x64-setup
SetupIconFile=..\windows-overlay\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\Locman7.exe
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=6.1.7601
CloseApplications=yes

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Значок на рабочем столе"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{group}\Лоцман Lite"; Filename: "{app}\Locman7.exe"
Name: "{userdesktop}\Лоцман Lite"; Filename: "{app}\Locman7.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Locman7.exe"; Description: "Запустить «Лоцман Lite»"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{cmd}"; Parameters: "/C taskkill /IM xray.exe /F"; Flags: runhidden; RunOnceId: "KillXray"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "Locman7"; Flags: uninsdeletevalue dontcreatekey

[Code]
function DotNet48: Boolean;
var
  Release: Cardinal;
begin
  Result := RegQueryDWordValue(HKLM, 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', 'Release', Release)
    and (Release >= 528040);
end;

function InitializeSetup: Boolean;
var
  Code: Integer;
begin
  Result := True;
  if not DotNet48 then
  begin
    if MsgBox('Для «Лоцман Lite» нужен .NET Framework 4.8 — его нет на этом компьютере.' + #13#10#13#10 +
      'Открыть страницу загрузки Microsoft? Установите «.NET Framework 4.8 Runtime», перезагрузите компьютер и запустите установку «Лоцмана» снова.',
      mbConfirmation, MB_YESNO) = IDYES then
      ShellExec('open', 'https://dotnet.microsoft.com/download/dotnet-framework/net48', '', '', SW_SHOWNORMAL, ewNoWait, Code);
    Result := False;
  end;
end;
