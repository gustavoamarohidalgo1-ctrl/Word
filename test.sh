#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$ROOT_DIR/build"

swiftc -O \
  -framework Cocoa \
  -framework CoreText \
  -framework UniformTypeIdentifiers \
  -lz \
  "$ROOT_DIR/Sources/PureZip.swift" \
  "$ROOT_DIR/Sources/DocxEngine.swift" \
  "$ROOT_DIR/Sources/FormatConverters.swift" \
  "$ROOT_DIR/Sources/EditorTextView.swift" \
  "$ROOT_DIR/Tests/DocxEngineTests.swift" \
  -o "$ROOT_DIR/build/officeword-tests"

"$ROOT_DIR/build/officeword-tests"
