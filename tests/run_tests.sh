#!/bin/zsh
# Compile et lance les tests de logique (moteur, géométrie, traductions).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -swift-version 5 -target arm64-apple-macos15 -o build/tests Sources/Model.swift Sources/Engine.swift Sources/L10n.swift tests/main.swift
./build/tests
