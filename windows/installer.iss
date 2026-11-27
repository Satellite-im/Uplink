; Uplink for Windows: the installer (Matt, 2026-11-14: "Add a mac and windows build to ghost-sms.com").
; Built by .github/workflows/messaging-windows.yml after `flutter build windows`, with the version passed in:
;   iscc /DAppVersion=0.7.21 /DSource=build\windows\x64\runner\Release windows\installer.iss
; and, where it signs, /DSign "/Sghost=pwsh -NoProfile -File <messaging>\windows\sign.ps1 $f" as well.
; It installs for the person alone (no administrator), into their own Programs folder, with a Start menu entry and
; an uninstaller; running a newer one over it updates it in place, which the app does itself (silently, then
; reopened) when the person chooses Restart to update. The AppId stays the same for every version.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef Source
  #define Source "build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{B97205D6-26C4-4B1D-B648-5E26BB43325D}
AppName=Uplink
AppVersion={#AppVersion}
AppVerName=Uplink {#AppVersion}
AppPublisher=MattsSoftware
AppPublisherURL=https://gogho.st
AppSupportURL=https://gogho.st
; The folder keeps the app's earlier name (it was Ghost Messaging until 0.12.50): an install is found there by its
; own update (lib/desktop/updates.dart), and a new one goes where an old one is.
DefaultDirName={localappdata}\Programs\Ghost Messaging
DefaultGroupName=Uplink
; The Start menu's entry under the new name, whatever group an earlier install chose.
UsePreviousGroup=no
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\build\windows-installer
OutputBaseFilename=ghost-messaging-setup
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\ghost_messaging.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
; Signed where the build has the Azure signing account (/DSign, with /Sghost=… naming windows\sign.ps1): the installer
; and the uninstaller it writes, so neither says "Unknown publisher".
#ifdef Sign
SignTool=ghost
SignedUninstaller=yes
#endif

[Tasks]
Name: "desktopicon"; Description: "Put Uplink on the desktop"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "..\{#Source}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; The shortcuts an install under the earlier name left: the Start menu's group and the desktop's.
Type: filesandordirs; Name: "{userprograms}\Ghost Messaging"
Type: files; Name: "{userdesktop}\Ghost Messaging.lnk"

[Icons]
Name: "{group}\Uplink"; Filename: "{app}\ghost_messaging.exe"
Name: "{userdesktop}\Uplink"; Filename: "{app}\ghost_messaging.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\ghost_messaging.exe"; Description: "Open Uplink"; Flags: nowait postinstall skipifsilent
; The app's own update (lib/desktop/updates.dart, WindowsUpdateHost) runs this silently with /RELAUNCH and quits:
; open it again. Any other silent install (the build's own check) leaves it closed.
Filename: "{app}\ghost_messaging.exe"; Flags: nowait runasoriginaluser; Check: Relaunch

[Code]
function Relaunch: Boolean;
begin
  Result := WizardSilent and (Pos('/RELAUNCH', Uppercase(GetCmdTail)) > 0);
end;
