; Установщик «Лоцман Lite» для Windows 7 SP1 x64 (Inno Setup 6).
; Ставится в профиль пользователя — права администратора не нужны. Нужен .NET Framework 4.8.
; iscc /DAppVersion=1.9.0 /DSourceDir=out7 /DOutDir=dist tools\locman7.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef DotNetDir
  #define DotNetDir "dotnet"
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
Filename: "{app}\Locman7.exe"; Description: "Запустить «Лоцман Lite»"; Flags: nowait postinstall skipifsilent; Check: NotRestarting

[UninstallRun]
Filename: "{cmd}"; Parameters: "/C taskkill /IM xray.exe /F"; Flags: runhidden; RunOnceId: "KillXray"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "Locman7"; Flags: uninsdeletevalue dontcreatekey

[Files]
; Офлайн-установщик .NET Framework 4.8 от Microsoft и корневой сертификат Microsoft 2011
; (без него на Windows 7 без обновлений установка .NET падает с ошибкой цепочки сертификатов).
; Распаковываются во временную папку, только если .NET 4.8 нет.
Source: "{#DotNetDir}\ndp48-x86-x64-allos-enu.exe"; Flags: dontcopy
Source: "{#DotNetDir}\MicrosoftRootCertificateAuthority2011.cer"; Flags: dontcopy

[Code]
var
  RestartNeeded: Boolean;

function DotNet48: Boolean;
var
  Release: Cardinal;
begin
  Result := RegQueryDWordValue(HKLM, 'SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', 'Release', Release)
    and (Release >= 528040);
end;

function InitializeSetup: Boolean;
begin
  Result := True;
  if not DotNet48 then
    Result := MsgBox('Для «Лоцман Lite» нужен .NET Framework 4.8 — его нет на этом компьютере.' + #13#10#13#10 +
      'Он есть внутри этого установщика и поставится сейчас, интернет не нужен. Windows попросит права ' +
      'администратора, установка займёт 5–10 минут, после неё может понадобиться перезагрузка.' + #13#10#13#10 +
      'Продолжить?', mbConfirmation, MB_YESNO) = IDYES;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
  Cmd: String;
begin
  Result := '';
  if DotNet48 then Exit;
  WizardForm.PreparingLabel.Caption := 'Устанавливаю .NET Framework 4.8 — это может занять несколько минут…';
  WizardForm.PreparingLabel.Visible := True;
  ExtractTemporaryFile('ndp48-x86-x64-allos-enu.exe');
  ExtractTemporaryFile('MicrosoftRootCertificateAuthority2011.cer');
  // Один запрос прав: сначала сертификат в доверенные корневые, потом сам .NET (с окном прогресса).
  Cmd := '/C certutil -addstore Root "' + ExpandConstant('{tmp}\MicrosoftRootCertificateAuthority2011.cer') + '" & "' +
    ExpandConstant('{tmp}\ndp48-x86-x64-allos-enu.exe') + '" /passive /norestart';
  if not ShellExec('runas', ExpandConstant('{cmd}'), Cmd, ExpandConstant('{tmp}'), SW_HIDE, ewWaitUntilTerminated, Code) then
  begin
    Result := 'Не удалось запустить установку .NET Framework 4.8 (нет прав администратора?).';
    Exit;
  end;
  if (Code = 3010) or (Code = 1641) then
    RestartNeeded := True
  else if (Code <> 0) and not DotNet48 then
    Result := 'Установка .NET Framework 4.8 завершилась с кодом ' + IntToStr(Code) + '.' + #13#10 +
      'Установите обновления Windows 7 SP1 и попробуйте снова.';
  NeedsRestart := RestartNeeded;
end;

function NeedRestart: Boolean;
begin
  Result := RestartNeeded;
end;

function NotRestarting: Boolean;
begin
  Result := not RestartNeeded;
end;
