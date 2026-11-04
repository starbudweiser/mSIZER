#!/bin/zsh
# Construit « mSIZER.app » dans le dossier du projet, la signe (certificat local stable) puis l'installe dans
# ~/Applications/Applications Personnelles. NO_INSTALL=1 : ne pas installer ; NO_OPEN=1 : ne pas lancer.
set -euo pipefail
cd "$(dirname "$0")"
APP="mSIZER.app"
DEST="$HOME/Applications/Applications Personnelles"
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon.iconset

# Puces Apple Silicon uniquement : code natif arm64 réglé pour la famille M (apple-m1 et suivantes).
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15 -Xcc -mcpu=apple-m1 -target-cpu apple-m1 \
  -o "$APP/Contents/MacOS/mSIZER" Sources/*.swift

swift Resources/make_icon.swift build/icon-1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out build/icon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
rm -rf build

SIGN="/Volumes/SKYRIM/TOOLS/MAC/_tools/sign_app.sh"
if [ -x "$SIGN" ]; then "$SIGN" "$APP"; else codesign --force --deep -s - "$APP"; fi

if [ -z "${NO_INSTALL:-}" ]; then
  mkdir -p "$DEST"
  # Jamais d'installation pendant un traitement : l'appli installée serait arrêtée en plein lot.
  if [ -z "${FORCE:-}" ] && pgrep -x mSIZER >/dev/null && [ -f "$HOME/.msizer-busy" ]; then
    echo "Traitement en cours : installation annulée (l'appli compilée est dans $PWD/$APP). FORCE=1 pour passer outre." >&2
    exit 2
  fi
  pkill -x mSIZER 2>/dev/null || true
  rm -rf "$DEST/$APP"
  cp -R "$APP" "$DEST/$APP"
  echo "Installée : $DEST/$APP"
fi
echo "OK : $APP"
