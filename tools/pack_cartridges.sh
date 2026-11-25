#!/usr/bin/env bash
# tools/pack_cartridges.sh [NAME...]: each package packages/build.sh has
# built (build/packages/NAME/dest), also as a squared cartridge, 3.0 (the
# spec's Appendix B.2: kind "package"), in build/packages/cartridges/
# NAME-VERSION.sq. Offline. A package already packed at its key is skipped.
#
# The packer, tools/cartridge (sqterm-pack), is built first by sqmake, for this
# machine, from third_party/sqcart: clang 23 and libc++ with `import std`
# (LLVM_BIN, default /usr/lib/llvm-23/bin; in sqterm, pkg install llvm).
#
# Not part of any package's key: the archives come from the same installs.
# While the pkg already on phones reads only .tar.zst, the release carries
# both (decided 2026-11-19).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
WORK=$ROOT/build/packages
OUT=$WORK/cartridges
TOOL=$WORK/cartridge-tool
SQ_PREFIX=/data/data/dev.squared.sqterm/files/usr
LLVM_BIN=${LLVM_BIN:-/usr/lib/llvm-23/bin}
say() { printf '== %s\n' "$*"; }
fail() { printf 'pack_cartridges: %s\n' "$*" >&2; exit 1; }

[ -x "$LLVM_BIN/clang++" ] || fail "no clang 23 at $LLVM_BIN (set LLVM_BIN)"
SQMAKE=${SQMAKE:-sqmake}
command -v "$SQMAKE" >/dev/null || fail "needs sqmake, on PATH or as SQMAKE (in sqterm, pkg install sqmake)"
# Built by tools/cartridge/build.lua, from the root (quiet unless it fails).
mkdir -p "$WORK"
CXX="$LLVM_BIN/clang++" CC="$LLVM_BIN/clang" SQ_OUT="$TOOL" "$SQMAKE" -C "$ROOT" -f tools/cartridge/build.lua \
  >"$WORK/cartridge-tool.log" 2>&1 || { cat "$WORK/cartridge-tool.log" >&2; fail "sqterm-pack did not build"; }
mkdir -p "$OUT"

wanted=" $* "
while read -r name version key bundled; do
  [ $# -eq 0 ] || [[ $wanted == *" $name "* ]] || continue
  here=$WORK/$name install=$WORK/$name/dest$SQ_PREFIX archive=$OUT/$name-$version.sq
  if [ "$(cat "$here/key" 2>/dev/null)" != "$key" ] || [ ! -f "$install/SQ-INF/manifest.json" ]; then
    say "$name $version: not built at $key here (bash packages/build.sh $name): skipped"
    continue
  fi
  if [ "$(cat "$here/cartridge-key" 2>/dev/null)" = "$key" ] && [ -f "$archive" ]; then
    say "$name $version: packed ($key)"
    continue
  fi
  "$TOOL/sqterm-pack" "$install" "$archive" > /dev/null
  for old in "$OUT/$name"-*.sq; do [ "$old" = "$archive" ] || rm -f "$old"; done
  echo "$key" > "$here/cartridge-key"
  say "$name: $(du -k "$archive" | cut -f 1) KB as a cartridge"
done < <(bash "$ROOT/packages/build.sh" --keys)
