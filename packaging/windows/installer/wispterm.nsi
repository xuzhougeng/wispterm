; WispTerm per-user Windows installer (NSIS 3, Modern UI 2).
;
; Built by packaging/windows/build-installer.ps1 from an already-signed
; zig-out\dist\portable tree, so the payload binaries keep their eSigner
; signatures; the setup exe itself is signed afterwards with
; sign-esigner.ps1 -File. Installs the same files as the portable zip into
; %LOCALAPPDATA%\Programs\WispTerm (the folder replace-install.ps1 uses), so
; the in-place updater (src/update_inplace.zig), Replace-WispTerm.cmd, and
; Add-Context-Menu.cmd all keep working on an installed copy.
;
; The uninstaller runs the shipped uninstall.ps1, which unregisters the
; Explorer context menu, removes the Start-menu shortcut, and deletes the
; payload while preserving the user's configuration and plugins; Setup only
; adds and removes its own Add/Remove Programs entry on top of that.
;
; Defines passed by build-installer.ps1:
;   PAYLOAD_DIR  absolute path of the portable tree to package
;   OUT_FILE     absolute path of the setup exe to write
;   ICON_FILE    absolute path of assets\wispterm.ico
;   VERSION      display version, e.g. 1.45.0
;   VERSION4     optional four-part version for the exe resource, e.g. 1.45.0.0
;
; Command line: /S silent, /D=<dir> install folder (last argument, unquoted),
; /MENU also registers the Explorer context menu, /DESKTOP adds a desktop
; shortcut. Uninstall.exe /S removes silently.

Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"

!ifndef PAYLOAD_DIR
  !error "PAYLOAD_DIR is required (-DPAYLOAD_DIR=<portable tree>)"
!endif
!ifndef OUT_FILE
  !error "OUT_FILE is required (-DOUT_FILE=<setup exe>)"
!endif
!ifndef ICON_FILE
  !error "ICON_FILE is required (-DICON_FILE=<assets\wispterm.ico>)"
!endif
!ifndef VERSION
  !define VERSION "dev"
!endif

!define APP_NAME "WispTerm"
!define APP_EXE "wispterm.exe"
!define APP_URL "https://github.com/xuzhougeng/wispterm"
!define APP_REGKEY "Software\WispTerm"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\WispTerm"

Name "${APP_NAME}"
OutFile "${OUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\WispTerm"
InstallDirRegKey HKCU "${APP_REGKEY}" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
BrandingText "${APP_NAME} ${VERSION}"

!ifdef VERSION4
  VIProductVersion "${VERSION4}"
  VIAddVersionKey /LANG=1033 "ProductName" "${APP_NAME}"
  VIAddVersionKey /LANG=1033 "FileDescription" "${APP_NAME} Setup"
  VIAddVersionKey /LANG=1033 "FileVersion" "${VERSION}"
  VIAddVersionKey /LANG=1033 "ProductVersion" "${VERSION}"
  VIAddVersionKey /LANG=1033 "LegalCopyright" "WispTerm contributors"
!endif

!define MUI_ABORTWARNING
!define MUI_ICON "${ICON_FILE}"
!define MUI_UNICON "${ICON_FILE}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_COMPONENTSPAGE_SMALLDESC

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

; The first language is the fallback; NSIS picks the system UI language.
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "SimpChinese"

LangString SEC_APP_NAME ${LANG_ENGLISH} "WispTerm (required)"
LangString SEC_APP_NAME ${LANG_SIMPCHINESE} "WispTerm（必需）"
LangString SEC_APP_DESC ${LANG_ENGLISH} "The terminal, its SSH helper, and the bundled skills. Adds a Start menu shortcut."
LangString SEC_APP_DESC ${LANG_SIMPCHINESE} "终端程序、SSH 辅助程序和内置技能，并添加开始菜单快捷方式。"
LangString SEC_MENU_NAME ${LANG_ENGLISH} "Explorer context menu"
LangString SEC_MENU_NAME ${LANG_SIMPCHINESE} "资源管理器右键菜单"
LangString SEC_MENU_DESC ${LANG_ENGLISH} "Adds 'Open in WispTerm' to the right-click menu of folders. Can be added or removed later with Add-Context-Menu.cmd / Remove-Context-Menu.cmd."
LangString SEC_MENU_DESC ${LANG_SIMPCHINESE} "在文件夹右键菜单中添加“在 WispTerm 中打开”。之后也可用 Add-Context-Menu.cmd / Remove-Context-Menu.cmd 添加或移除。"
LangString SEC_DESKTOP_NAME ${LANG_ENGLISH} "Desktop shortcut"
LangString SEC_DESKTOP_NAME ${LANG_SIMPCHINESE} "桌面快捷方式"
LangString SEC_DESKTOP_DESC ${LANG_ENGLISH} "Puts a WispTerm shortcut on the desktop."
LangString SEC_DESKTOP_DESC ${LANG_SIMPCHINESE} "在桌面上放置 WispTerm 快捷方式。"
LangString MSG_RUNNING ${LANG_ENGLISH} "WispTerm is running from $INSTDIR. Close it, then run Setup again."
LangString MSG_RUNNING ${LANG_SIMPCHINESE} "$INSTDIR 中的 WispTerm 正在运行。请先关闭它，再重新运行安装程序。"
LangString MSG_MENU_FAILED ${LANG_ENGLISH} "WispTerm was installed, but the Explorer context menu could not be registered. You can try again later with Add-Context-Menu.cmd in the install folder."
LangString MSG_MENU_FAILED ${LANG_SIMPCHINESE} "WispTerm 已安装，但资源管理器右键菜单注册失败。之后可在安装目录运行 Add-Context-Menu.cmd 重试。"
LangString MSG_UNINSTALL_FAILED ${LANG_ENGLISH} "WispTerm could not be removed from $INSTDIR. Close WispTerm and try again, or run Uninstall-WispTerm.cmd in that folder for details."
LangString MSG_UNINSTALL_FAILED ${LANG_SIMPCHINESE} "无法从 $INSTDIR 移除 WispTerm。请关闭 WispTerm 后重试，或在该目录运行 Uninstall-WispTerm.cmd 查看详情。"

Var MenuWanted

; Windows refuses write access to a running exe, so a failed open means the
; copy in $INSTDIR is running. Same rule replace-install.ps1 relies on.
!macro ABORT_IF_RUNNING
  ${If} ${FileExists} "$INSTDIR\${APP_EXE}"
    ClearErrors
    FileOpen $0 "$INSTDIR\${APP_EXE}" a
    ${If} ${Errors}
      MessageBox MB_ICONSTOP|MB_OK "$(MSG_RUNNING)" /SD IDOK
      Abort "$(MSG_RUNNING)"
    ${EndIf}
    FileClose $0
  ${EndIf}
!macroend

Section "$(SEC_APP_NAME)" SecApp
  SectionIn RO
  !insertmacro ABORT_IF_RUNNING

  SetOutPath "$INSTDIR"
  SetOverwrite on
  File /r "${PAYLOAD_DIR}\*"

  ; Leftovers of an in-place update (src/update_inplace.zig) are not needed
  ; once Setup has written a complete copy.
  Delete "$INSTDIR\*.wispterm-old"
  Delete "$INSTDIR\*.wispterm-old-*"
  RMDir /r "$INSTDIR\.update"

  ; Same shortcut file replace-install.ps1 writes and uninstall.ps1 removes;
  ; the manual flow finds the install folder through it.
  CreateShortcut "$SMPROGRAMS\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0 SW_SHOWNORMAL "" "${APP_NAME}"

  ; A context menu registered by an earlier copy in this folder must point at
  ; the new extension payload. Refresh is a no-op when none is registered.
  ${If} ${FileExists} "$INSTDIR\context-menu.ps1"
    nsExec::ExecToLog 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\context-menu.ps1" -Action Refresh -InstallDir "$INSTDIR"'
    Pop $0
  ${EndIf}

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKCU "${APP_REGKEY}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "WispTerm"
  WriteRegStr HKCU "${UNINST_KEY}" "URLInfoAbout" "${APP_URL}"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\${APP_EXE}"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""
  WriteRegStr HKCU "${UNINST_KEY}" "QuietUninstallString" "$\"$INSTDIR\Uninstall.exe$\" /S"
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINST_KEY}" "EstimatedSize" "$0"
SectionEnd

Section /o "$(SEC_MENU_NAME)" SecMenu
  ${If} ${FileExists} "$INSTDIR\context-menu.ps1"
    nsExec::ExecToLog 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\context-menu.ps1" -Action Install -InstallDir "$INSTDIR"'
    Pop $0
    ${If} $0 != 0
      MessageBox MB_ICONEXCLAMATION|MB_OK "$(MSG_MENU_FAILED)" /SD IDOK
    ${EndIf}
  ${EndIf}
SectionEnd

Section /o "$(SEC_DESKTOP_NAME)" SecDesktop
  CreateShortcut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}" "" "$INSTDIR\${APP_EXE}" 0 SW_SHOWNORMAL "" "${APP_NAME}"
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecApp} "$(SEC_APP_DESC)"
  !insertmacro MUI_DESCRIPTION_TEXT ${SecMenu} "$(SEC_MENU_DESC)"
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} "$(SEC_DESKTOP_DESC)"
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; After the sections: ${SecMenu} / ${SecDesktop} are defined by them.
Function .onInit
  StrCpy $MenuWanted 0
  ${GetParameters} $R0
  ClearErrors
  ${GetOptions} $R0 "/MENU" $R1
  ${IfNot} ${Errors}
    StrCpy $MenuWanted 1
  ${EndIf}
  ClearErrors
  ${GetOptions} $R0 "/DESKTOP" $R1
  ${IfNot} ${Errors}
    SectionSetFlags ${SecDesktop} ${SF_SELECTED}
  ${EndIf}
  ${If} $MenuWanted == 1
    SectionSetFlags ${SecMenu} ${SF_SELECTED}
  ${EndIf}
FunctionEnd

Section "Uninstall"
  ; uninstall.ps1 refuses while this copy runs, unregisters the context menu,
  ; removes the Start-menu shortcut it owns, and deletes the payload while
  ; keeping the user's configuration and plugins.
  IfFileExists "$INSTDIR\uninstall.ps1" 0 fallback
    nsExec::ExecToLog 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\uninstall.ps1"'
    Pop $0
    ${If} $0 != 0
      MessageBox MB_ICONSTOP|MB_OK "$(MSG_UNINSTALL_FAILED)" /SD IDOK
      Abort "$(MSG_UNINSTALL_FAILED)"
    ${EndIf}
    Goto cleanup
  fallback:
    ; An install whose uninstall.ps1 is gone: remove what Setup knows about.
    Delete "$SMPROGRAMS\${APP_NAME}.lnk"
    Delete "$INSTDIR\${APP_EXE}"
    Delete "$INSTDIR\wispterm-ssh-askpass.exe"
    Delete "$INSTDIR\wispterm-ssh-proxy.exe"
    Delete "$INSTDIR\version.txt"
    Delete "$INSTDIR\WebView2Loader.dll"
    Delete "$INSTDIR\conpty.dll"
    Delete "$INSTDIR\OpenConsole.exe"
    Delete "$INSTDIR\Replace-WispTerm.cmd"
    Delete "$INSTDIR\replace-install.ps1"
    Delete "$INSTDIR\Add-Context-Menu.cmd"
    Delete "$INSTDIR\Remove-Context-Menu.cmd"
    Delete "$INSTDIR\context-menu.ps1"
    RMDir /r "$INSTDIR\shell-integration"
  cleanup:
    Delete "$DESKTOP\${APP_NAME}.lnk"
    Delete "$INSTDIR\uninstall.ps1"
    Delete "$INSTDIR\Uninstall-WispTerm.cmd"
    Delete "$INSTDIR\*.wispterm-old"
    Delete "$INSTDIR\*.wispterm-old-*"
    RMDir /r "$INSTDIR\.update"
    Delete "$INSTDIR\Uninstall.exe"
    ; Only an empty folder goes: user plugins or a portable config stay.
    RMDir "$INSTDIR"

    DeleteRegKey HKCU "${UNINST_KEY}"
    DeleteRegValue HKCU "${APP_REGKEY}" "InstallDir"
    DeleteRegKey /ifempty HKCU "${APP_REGKEY}"
SectionEnd
