#!/usr/bin/env bash
# Собирает Kopilka.AppDir из готовой сборки flutter build linux --release.
# Вызывается CI на шаге AppImage (и вручную локально на Linux):
#
#   ./packaging/linux/make_appdir.sh 0.1.0
#
# На Windows-хосте проверялся только bash-синтаксис (bash -n); рабочий
# запуск — в CI на ubuntu-latest.
set -euo pipefail

VERSION="${1:?usage: make_appdir.sh <version>}"
BUILD_DIR="build/linux/x64/release/bundle"
APP_DIR="Kopilka.AppDir"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/usr/bin" "$APP_DIR/usr/lib/kopilka"

cp -r "$BUILD_DIR"/. "$APP_DIR/usr/lib/kopilka/"
ln -sf /usr/lib/kopilka/kopilka "$APP_DIR/usr/bin/kopilka"

# .desktop по спецификации AppDir (AppImageKit ищет его в корне).
# Иконка указывается ТОЛЬКО если файл есть: appimagetool падает с exit 1
# на «defined in desktop file but not found», когда Icon= ссылается
# на отсутствующий файл (фирменного лого пока нет).
if [ -f "assets/icon/kopilka.png" ]; then
  cp "assets/icon/kopilka.png" "$APP_DIR/kopilka.png"
fi
{
  echo "[Desktop Entry]"
  echo "Type=Application"
  echo "Name=Kopilka"
  echo "Comment=Local personal finance tracker"
  echo "Exec=usr/bin/kopilka"
  if [ -f "$APP_DIR/kopilka.png" ]; then
    echo "Icon=kopilka"
  fi
  echo "Categories=Office;Finance;"
} > "$APP_DIR/kopilka.desktop"

# Метаданные версии — AppStream-файл необязателен для MVP.
echo "Kopilka.AppDir собран (v$VERSION): $(find "$APP_DIR" -type f | wc -l) файлов"
