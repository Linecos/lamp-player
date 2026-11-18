; Lamp Player 的 Windows 安装包（Inno Setup 6.3+）
;
; 手动编译：ISCC.exe installer\lamp_player.iss /DMyAppVersion=0.1.0
; 常规做法：.\scripts\package.ps1 —— 它会先 flutter build，再带版本号调这里
;
; 产物落在 dist\LampPlayer-<版本>-setup.exe。装的是 build\windows\x64\runner\Release
; 整个目录（exe + flutter_windows.dll + rust_lib_lamp_player.dll + data\ + BASS 系列 dll），
; 与便携 zip 里的内容完全一致，只是多一套开始菜单 / 卸载。

#define MyAppName "Lamp Player"
#define MyAppExeName "lamp_player.exe"
#define MyAppPublisher "Linecos"
#define MyAppUrl "https://github.com/Linecos/lamp-player"
#define BuildDir "..\build\windows\x64\runner\Release"

; 版本号由调用方传进来（package.ps1 从 pubspec.yaml 读）；单独编译时退回占位
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

; 资源里的「文件版本」必须是四段纯数字，AppVersion 是给人看的字符串。
; 不传就退化成 0.0.0.0（属性 → 详细信息里就看不到版本了）
#ifndef MyAppVersionQuad
  #define MyAppVersionQuad "0.0.0.0"
#endif

[Setup]
; AppId 决定「这是同一个产品」：升级时认它来覆盖旧版，**发布后不要再改**
AppId={{6C1D7A61-2E0B-4F2E-9E0B-2A1D4C8B7A31}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppUrl}
AppSupportURL={#MyAppUrl}/issues
AppUpdatesURL={#MyAppUrl}/releases

; 装到 %LOCALAPPDATA%\Programs\Lamp Player：曲库和设置本来就在 %APPDATA%，
; 没必要为了装一个播放器要管理员权限
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog

ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0

OutputDir=..\dist
OutputBaseFilename=LampPlayer-{#MyAppVersion}-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}
LicenseFile=..\LICENSE

; 41MB 的 Release 目录压完约 20MB：lzma2 + solid 是这里最划算的一档
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern

; 让 exe 的版本资源有内容：不写这几行，右键属性 → 详细信息里版本是空的，
; 按版本号做升级判断的部署工具也认不出来
VersionInfoVersion={#MyAppVersionQuad}
VersionInfoProductVersion={#MyAppVersion}
VersionInfoProductTextVersion={#MyAppVersion}
VersionInfoTextVersion={#MyAppVersion}

; 覆盖安装时如果程序还开着，先请求关闭（用户数据在 %APPDATA%，不会被碰）
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 只搬 Release 目录，别把 .pdb / 临时产物带进去
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[Code]
// 卸载时问一句要不要连曲库一起删。默认是「否」：曲库是用户的资产，
// 卸载器顺手删掉会很难受（library.db 里还有收藏、歌单、播放历史）
//
// 静默卸载（/VERYSILENT）不问：没人能回答，问了会卡住自动化脚本。
// 那种情况下按「不删」处理。
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir: String;
begin
  if CurUninstallStep <> usPostUninstall then
    Exit;
  if UninstallSilent then
    Exit;
  DataDir := ExpandConstant('{userappdata}\Lamp Player');
  if not DirExists(DataDir) then
    Exit;
  if MsgBox('是否同时删除曲库、设置与封面缓存？' + #13#10 + #13#10 +
            DataDir + #13#10 + #13#10 +
            '选「否」会保留，下次重装接着用。',
            mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    DelTree(DataDir, True, True, True);
end;
