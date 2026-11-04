#!/bin/zsh
# Construit « mSIZER.app » dans le dossier du projet, la signe (certificat local stable) puis l'installe dans
# ~/Applications/Applications Personnelles. NO_INSTALL=1 : ne pas installer ; NO_OPEN=1 : ne pas lancer.
set -euo pipefail
cd "$(dirname "$0")"
APP="mSIZER.app"
DEST="$HOME/Applications/Applications Personnelles"
rm -rf "$APP" build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Puces Apple Silicon uniquement : code natif arm64 réglé pour la famille M (apple-m1 et suivantes).
# libwebp (Homebrew : brew install webp) est liée statiquement : rien à installer chez l'utilisateur.
WEBP="$(brew --prefix libwebp 2>/dev/null || echo /opt/homebrew)"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos15 -Xcc -mcpu=apple-m1 -target-cpu apple-m1 \
  -Xlinker -w -import-objc-header Sources/Bridge.h -Xcc -I"$WEBP/include" \
  -o "$APP/Contents/MacOS/mSIZER" Sources/*.swift "$WEBP/lib/libwebp.a" "$WEBP/lib/libsharpyuv.a"

# Icône : sources dans assets/ (régénérer avec « swift assets/make_icon.swift assets/icon-1024.png » puis iconutil).
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"

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
