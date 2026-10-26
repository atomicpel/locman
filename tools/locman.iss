; Установщик «Лоцмана» для Windows 10/11 (Inno Setup 6).
; Ставится в профиль пользователя — права администратора для установки не нужны.
; iscc /DAppVersion=1.4.0 /DSourceDir=build\windows\x64\runner\Release /DOutDir=dist tools\locman.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6E0F3A52-6B1D-4C35-9A5C-4C6F63A1D0A1}
AppName=Лоцман
AppVersion={#AppVersion}
AppVerName=Лоцман {#AppVersion}
AppPublisher=atomicpel
AppPublisherURL=https://github.com/atomicpel/locman
AppSupportURL=https://github.com/atomicpel/locman/issues
DefaultDirName={localappdata}\Programs\Locman
DefaultGroupName=Лоцман
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir={#OutDir}
OutputBaseFilename=Locman-{#AppVersion}-windows-x64-setup
SetupIconFile=..\windows-overlay\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\locman.exe
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
CloseApplications=force
RestartApplications=no
WizardStyle=modern
LicenseFile=..\LICENSE

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Значок на рабочем столе"; GroupDescription: "Дополнительно:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Лоцман"; Filename: "{app}\locman.exe"
Name: "{autodesktop}\Лоцман"; Filename: "{app}\locman.exe"; Tasks: desktopicon

[Registry]
; Ссылки locman://import?… открывают «Лоцман»
Root: HKCU; Subkey: "Software\Classes\locman"; ValueType: string; ValueData: "URL:Лоцман"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\locman"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\locman\DefaultIcon"; ValueType: string; ValueData: """{app}\locman.exe"",0"
Root: HKCU; Subkey: "Software\Classes\locman\shell\open\command"; ValueType: string; ValueData: """{app}\locman.exe"" ""%1"""

[Run]
Filename: "{app}\locman.exe"; Description: "Запустить «Лоцман»"; Flags: nowait postinstall

[UninstallRun]
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN Locman /F"; Flags: runhidden; RunOnceId: "DelTask"

[UninstallDelete]
Type: filesandordirs; Name: "{localappdata}\Locman"

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RegDeleteValue(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Run', 'Locman');
end;
