#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT_DIR/OfficeWord.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$ROOT_DIR/build/OfficeWord.iconset"

echo "🔨 Compilando OfficeWord.app (100% nativo Swift + AppKit)..."

rm -rf "$APP_DIR" "$ICONSET_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$ROOT_DIR/build"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

# Generar ícono nativo macOS (.icns)
swift "$ROOT_DIR/scripts/make-icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$RES_DIR/OfficeWord.icns"
rm -rf "$ICONSET_DIR"

# Copiar fuentes tipográficas libres con métrica equivalente a Microsoft Word
if [ -d "$ROOT_DIR/Resources/Fonts" ]; then
  rm -rf "$RES_DIR/Fonts"
  cp -R "$ROOT_DIR/Resources/Fonts" "$RES_DIR/Fonts"
fi

# Compilar binario macOS optimizado (-O) con AppKit, CoreText, Foundation, UniformTypeIdentifiers y zlib
swiftc -O \
  -framework Cocoa \
  -framework CoreText \
  -framework UniformTypeIdentifiers \
  -lz \
  "$ROOT_DIR/Sources/PureZip.swift" \
  "$ROOT_DIR/Sources/DocxEngine.swift" \
  "$ROOT_DIR/Sources/FormatConverters.swift" \
  "$ROOT_DIR/Sources/EditorTextView.swift" \
  "$ROOT_DIR/Sources/RibbonView.swift" \
  "$ROOT_DIR/Sources/MainWindowController.swift" \
  "$ROOT_DIR/Sources/main.swift" \
  -o "$MACOS_DIR/OfficeWord"

# Firma ad-hoc local para LaunchServices
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

APP_SIZE="$(du -sh "$APP_DIR" | awk '{print $1}')"
BIN_SIZE="$(du -sh "$MACOS_DIR/OfficeWord" | awk '{print $1}')"
echo "✅ OfficeWord.app lista en: $APP_DIR (Total: $APP_SIZE | Binario: $BIN_SIZE)"
