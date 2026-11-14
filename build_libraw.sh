#!/bin/zsh
# Compile LibRaw (décodage RAW) sans OpenMP, en bibliothèque statique : build/vendor/libraw.a + en-têtes.
# Les sources viennent de Homebrew (brew fetch libraw) ; licence LibRaw : CDDL 1.0. Sans OpenMP, plusieurs fichiers
# se décodent en parallèle sans risque (chaque instance de LibRaw est indépendante).
set -euo pipefail
cd "$(dirname "$0")"
OUT="build/vendor"
[ -f "$OUT/libraw.a" ] && [ -f "$OUT/include/libraw/libraw.h" ] && exit 0
brew fetch --build-from-source libraw >/dev/null 2>&1 || true
TARBALL="$(brew --cache --build-from-source libraw)"
[ -f "$TARBALL" ] || { echo "Sources de LibRaw introuvables : brew install libraw" >&2; exit 1; }
W="build/libraw-src"; rm -rf "$W" "$OUT"; mkdir -p "$W" "$OUT/obj" "$OUT/include"
tar xf "$TARBALL" -C "$W" --strip-components=1
cp -R "$W/libraw" "$OUT/include/libraw"
# Même liste de fichiers que le Makefile officiel de LibRaw (certains .cpp sont inclus par d'autres).
NAMES=$(awk '/^LIB_OBJECTS/,/^$/' "$W/Makefile.dist" | grep -o 'object/[A-Za-z0-9_]*\.o' | sed 's#object/##; s#\.o$##')
FILES=()
for nm in ${=NAMES}; do
  f=$(find "$W/src" -name "$nm.cpp" | head -1)
  [ -n "$f" ] && FILES+=("$f")
done
n=0
for f in "${FILES[@]}"; do
  n=$((n + 1))
  clang++ -O3 -mcpu=apple-m1 -std=c++14 -w -DUSE_JPEG -DUSE_ZLIB -DLIBRAW_NODLL \
    -I"$W" -I/opt/homebrew/include -c "$f" -o "$OUT/obj/$n.o" &
  (( n % 8 == 0 )) && wait
done
wait
ar rcs "$OUT/libraw.a" "$OUT"/obj/*.o
rm -rf "$OUT/obj" "$W"
echo "LibRaw compilée : $OUT/libraw.a"
