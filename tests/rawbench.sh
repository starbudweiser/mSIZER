#!/bin/zsh
# Compile le banc d'essai RAW → DNG (LibRaw, libomp, lcms2, libjpeg liés statiquement).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
./build_libraw.sh
WEBP="$(brew --prefix libwebp 2>/dev/null || echo /opt/homebrew)"
swiftc -O -swift-version 5 -target arm64-apple-macos15 -Xcc -mcpu=apple-m1 -Xlinker -w \
  -import-objc-header Sources/Bridge.h -Xcc -I"$WEBP/include" -Xcc -Ibuild/vendor/include \
  -o build/rawbench Sources/RawDecoder.swift Sources/DNGWriter.swift Sources/RawEngine.swift Sources/L10n.swift Sources/L10nRaw.swift tests/bench/main.swift \
  build/vendor/libraw.a /opt/homebrew/lib/libjpeg.a -lc++ -lz
