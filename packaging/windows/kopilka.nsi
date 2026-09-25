; NSIS-скрипт установщика Kopilka для Windows (D-08).
; Вызывается релизным workflow (и вручную локально при установленном NSIS):
;
;   makensis /DPRODUCT_VERSION=0.1.0 /DOUTFILE=Kopilka-setup-v0.1.0.exe packaging/windows/kopilka.nsi
;
; Источник — готовая сборка flutter build windows --release
; (build/windows/x64/runner/Release).

!ifndef PRODUCT_VERSION
  !define PRODUCT_VERSION "0.0.0"
!endif
!ifndef OUTFILE
  !define OUTFILE "Kopilka-setup.exe"
!endif

!define PRODUCT_NAME "Kopilka"
!define EXE_NAME "kopilka.exe"
!define UNINSTALLER "uninstall.exe"

Name "${PRODUCT_NAME} ${PRODUCT_VERSION}"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\${PRODUCT_NAME}"
; Права пользователя: установка без админа (per-user), UAC не требуется.
RequestExecutionLevel user
SetCompressor /SOLID lzma

; Modern UI 2: стандартные страницы, язык — по системе.
!include "MUI2.nsh"
!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "Russian"

Section "Install"
  SetOutPath "$INSTDIR"

  ; Вся папка Release: exe, dll, data\. Путь ОТНОСИТЕЛЬНО КАТАЛОГА СКРИПТА
  ; (makensis разрешает относительные пути File от каталога .nsi, а не от
  ; рабочей папки — подтверждено прогонами CI 2026-09-25 и локально):
  ; скрипт лежит в packaging\windows\, сборка — в build\... от корня репо.
  File /r "..\..\build\windows\x64\runner\Release\*.*"

  ; Ярлыки и запись «Удаление».
  CreateDirectory "$SMPROGRAMS\${PRODUCT_NAME}"
  CreateShortcut "$SMPROGRAMS\${PRODUCT_NAME}\${PRODUCT_NAME}.lnk" "$INSTDIR\${EXE_NAME}"
  CreateShortcut "$DESKTOP\${PRODUCT_NAME}.lnk" "$INSTDIR\${EXE_NAME}"

  WriteUninstaller "$INSTDIR\${UNINSTALLER}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" \
    "DisplayName" "${PRODUCT_NAME} ${PRODUCT_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" \
    "UninstallString" "$INSTDIR\${UNINSTALLER}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}" \
    "DisplayVersion" "${PRODUCT_VERSION}"
SectionEnd

Section "Uninstall"
  ; Данные пользователя (каталог поддержки с БД и бэкапами) НЕ удаляются:
  ; в них деньги пользователя.
  RMDir /r "$INSTDIR"
  Delete "$SMPROGRAMS\${PRODUCT_NAME}\${PRODUCT_NAME}.lnk"
  RMDir "$SMPROGRAMS\${PRODUCT_NAME}"
  Delete "$DESKTOP\${PRODUCT_NAME}.lnk"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT_NAME}"
SectionEnd
