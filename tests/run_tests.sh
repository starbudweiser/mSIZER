#!/bin/zsh
# Compile et lance les tests de logique (moteur, géométrie, traductions).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
WEBP="$(brew --prefix libwebp 2>/dev/null || echo /opt/homebrew)"
./build_libraw.sh
swiftc -O -swift-version 5 -target arm64-apple-macos15 -Xlinker -w -import-objc-header Sources/Bridge.h -Xcc -I"$WEBP/include" -Xcc -Ibuild/vendor/include \
  -o build/tests Sources/Model.swift Sources/Engine.swift Sources/L10n.swift Sources/L10nRaw.swift Sources/WebPEncoder.swift Sources/RawDecoder.swift Sources/DNGWriter.swift Sources/RawEngine.swift tests/main.swift \
  "$WEBP/lib/libwebp.a" "$WEBP/lib/libsharpyuv.a" build/vendor/libraw.a /opt/homebrew/lib/libjpeg.a -lc++ -lz
./build/tests
