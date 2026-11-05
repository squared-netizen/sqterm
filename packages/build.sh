#!/usr/bin/env bash
# packages/build.sh: build sqterm's packages for its prefix (Sprint 12.5).
#
# Each package is a recipe (packages/<name>/recipe.sh): its source's URL and
# sha256, how to build it, and what of its install goes in the package. This
# script downloads the source, checks it, builds it with the NDK for the
# oldest Android sqterm runs on (API 22, so the tablet too), and packs what
# the recipe keeps as <name>-<version>.tar.zst in sq_android/assets/packages/,
# with an index the app reads. The app unpacks them into its prefix the first
# time it starts (and again when the index changes).
#
#   bash packages/build.sh              every package, in order (ncurses zsh)
#   bash packages/build.sh zsh          one (what it depends on must be built)
#   bash packages/build.sh --host-test  for this machine instead, into
#                                       build/packages/host/: to check a recipe
#                                       where there is no NDK (nothing packed
#                                       into the app)
#   bash packages/build.sh --list       the packages and their versions
#
# Runs on the phone (Termux: clang, make, curl, tar, xz, zstd) with the NDK the
# APK builds use ($ANDROID_NDK_HOME, or the newest under
# $PREFIX/opt/android-sdk/ndk). The same script is meant for GitHub Actions
# later (12.5, decided 2026-11-04): nothing in it is the phone's alone, but a
# build for Android on another machine runs nothing it built, and the recipes
# say where that matters.
#
# Sources are kept in build/packages/sources/ and checked against the
# recipe's sha256. A recipe with none (no checksum was published) is checked
# against packages/sources.lock, which the first download writes: commit it,
# and later downloads must match.
#
# Idempotent: each build starts from a fresh copy of the source; the package
# is written beside its old one and moved into place.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RECIPES=$ROOT/packages
WORK=$ROOT/build/packages
SOURCES=$WORK/sources
LOCK=$RECIPES/sources.lock
ORDER="ncurses zsh"

# Where the app's prefix is: what every program is built to find its files
# under. The app's getFilesDir() is /data/user/0/dev.squared.sqterm/files,
# the same directory as /data/data/...; Termux names its own the same way.
SQ_PREFIX=/data/data/dev.squared.sqterm/files/usr
SQ_API=${SQ_MIN_SDK:-22}
OUT=$ROOT/sq_android/assets/packages
HOST_TEST=0

say() { printf '== %s\n' "$*"; }
fail() { printf 'packages: %s\n' "$*" >&2; exit 1; }

names=()
while [ $# -gt 0 ]; do
  case $1 in
    --host-test) HOST_TEST=1 ;;
    --list)
      for name in $ORDER; do
        (. "$RECIPES/$name/recipe.sh"; printf '  %-10s %s\n' "$name" "$version")
      done
      exit 0 ;;
    -h | --help) sed -n '2,32p' "$0"; exit 0 ;;
    -*) fail "unknown option: $1 (see --help)" ;;
    *) [ -f "$RECIPES/$1/recipe.sh" ] || fail "no recipe: packages/$1/recipe.sh"
       names+=("$1") ;;
  esac
  shift
done
[ ${#names[@]} -gt 0 ] || read -r -a names <<< "$ORDER"

need() { command -v "$1" >/dev/null 2>&1 || fail "$1 is missing${2:+ (Termux: pkg install $2)}"; }
for tool in curl tar xz zstd make sha256sum; do need "$tool" "$tool"; done
need clang clang

# The toolchain. For Android: this host's clang, aimed at the NDK's sysroot
# for API $SQ_API (as mk/squared_generated.mk builds the app). Executables
# carry DT_HASH for Android 5 and 16 KB pages for the devices that have them.
if [ "$HOST_TEST" = 1 ]; then
  # Where it will be unpacked, if not here (sqterm's host harness: its files).
  SQ_PREFIX=${SQ_HOST_PREFIX:-$WORK/host/usr}
  OUT=$WORK/host/out
  WORK=$WORK/host/work
  export CC=${CC:-cc} AR=${AR:-ar} RANLIB=${RANLIB:-ranlib} STRIP=${STRIP:-strip}
  export CFLAGS="-O2" LDFLAGS=""
  SQ_HOST_TRIPLE=
  say "host test: built for this machine, prefix $SQ_PREFIX"
else
  NDK=${ANDROID_NDK_HOME:-}
  if [ -z "$NDK" ]; then
    NDK=$(ls -d "${PREFIX:-/nonexistent}/opt/android-sdk/ndk"/* "${ANDROID_HOME:-/nonexistent}/ndk"/* \
            2>/dev/null | sort -Vr | head -n 1 || true)
  fi
  [ -n "$NDK" ] && [ -d "$NDK" ] || fail "no NDK: set ANDROID_NDK_HOME (the app's build finds it the same way)"
  SYSROOT=$(ls -d "$NDK"/toolchains/llvm/prebuilt/*/sysroot 2>/dev/null | head -n 1)
  [ -d "$SYSROOT/usr/lib/aarch64-linux-android/$SQ_API" ] || fail "the NDK at $NDK has no libraries for API $SQ_API"
  SQ_HOST_TRIPLE=aarch64-linux-android
  pick() { for tool in "$@"; do command -v "$tool" >/dev/null 2>&1 && { echo "$tool"; return; }; done; echo "$1"; }
  export CC="clang --target=$SQ_HOST_TRIPLE$SQ_API --sysroot=$SYSROOT"
  export AR=$(pick llvm-ar ar) RANLIB=$(pick llvm-ranlib ranlib) STRIP=$(pick llvm-strip strip)
  # Termux's clang looks for the unwinder Android links beside itself, which
  # --sysroot hides: the NDK clang's own (as the app's build takes it).
  UNWIND=$(ls -d "$NDK"/toolchains/llvm/prebuilt/*/lib/clang/*/lib/linux/aarch64/libunwind.a 2>/dev/null | head -n 1)
  [ -n "$UNWIND" ] || fail "the NDK at $NDK has no libunwind.a for aarch64"
  export CFLAGS="-O2 -fPIC"
  export LDFLAGS="-L$(dirname "$UNWIND") -Wl,--hash-style=both -Wl,-z,max-page-size=16384"
  # What configure builds to run here (config.guess, a recipe's helpers).
  export CC_FOR_BUILD=${CC_FOR_BUILD:-cc}
  say "for Android API $SQ_API (arm64), prefix $SQ_PREFIX; NDK $NDK"
fi
export CPPFLAGS="" PKG_CONFIG=/bin/false
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
mkdir -p "$SOURCES" "$OUT" "$WORK"

# Download $url (or one of $mirrors) as $file, and check it.
fetch() {
  local path=$SOURCES/$file
  if [ ! -f "$path" ]; then
    local got=0
    for from in $url $mirrors; do
      say "download $from"
      if curl -fL --retry 3 --connect-timeout 20 -o "$path.part" "$from"; then got=1; break; fi
    done
    [ "$got" = 1 ] || fail "$name: could not download $file"
    mv "$path.part" "$path"
  fi
  local actual
  actual=$(sha256sum "$path" | cut -d ' ' -f 1)
  local expected=$sha256
  if [ -z "$expected" ] && [ -f "$LOCK" ]; then
    expected=$(awk -v f="$file" '$1 == f { print $2 }' "$LOCK")
  fi
  if [ -z "$expected" ]; then
    printf '%s %s\n' "$file" "$actual" >> "$LOCK"
    say "$file: no published sha256; recorded $actual in packages/sources.lock (commit it)"
  elif [ "$actual" != "$expected" ]; then
    fail "$file: sha256 $actual, expected $expected (delete build/packages/sources/$file to download it again)"
  fi
}

# What a dependency installed (its headers and static libraries), for the next build.
dest_of() { echo "$WORK/$1/dest$SQ_PREFIX"; }
use_dependency() {
  local dir
  dir=$(dest_of "$1")
  [ -d "$dir" ] || fail "$name needs $1 built first: bash packages/build.sh $1 $name"
  CPPFLAGS="$CPPFLAGS -I$dir/include"
  LDFLAGS="$LDFLAGS -L$dir/lib"
}

build_one() {
  name=$1
  local recipe_dir=$RECIPES/$name
  # The recipe's variables and functions, fresh for each package.
  unset -f recipe_patch recipe_build recipe_after 2>/dev/null || true
  version= url= mirrors= sha256= file= top= depends= keep=
  . "$recipe_dir/recipe.sh"
  say "$name $version"
  fetch
  local here=$WORK/$name
  rm -rf "$here"
  mkdir -p "$here"
  tar -xf "$SOURCES/$file" -C "$here"
  src=$here/$top
  dest=$here/dest
  [ -d "$src" ] || fail "$name: $file has no $top/"
  local saved_cppflags=$CPPFLAGS saved_ldflags=$LDFLAGS
  for dependency in $depends; do use_dependency "$dependency"; done
  export CPPFLAGS LDFLAGS SQ_PREFIX SQ_HOST_TRIPLE SQ_API JOBS ROOT src dest version
  # In a bash of its own, so a failing step stops it (set -e does not reach
  # into a command on the left of ||).
  bash -c 'set -euo pipefail; . "$1"; cd "$src"
           if declare -f recipe_patch >/dev/null; then recipe_patch; fi
           recipe_build' recipe "$recipe_dir/recipe.sh" > "$here/build.log" 2>&1 || {
      tail -n 30 "$here/build.log" >&2
      fail "$name: the build failed; all of it is in build/packages/$name/build.log"; }
  CPPFLAGS=$saved_cppflags LDFLAGS=$saved_ldflags
  local installed=$dest$SQ_PREFIX
  [ -d "$installed" ] || fail "$name: nothing was installed under $installed"
  if declare -f recipe_after >/dev/null; then ( cd "$installed" && recipe_after ); fi
  # Only what the package keeps; executables and libraries stripped.
  ( cd "$installed"
    for path in $keep; do [ -e "$path" ] || [ -L "$path" ] || fail "$name: keeps $path, which was not installed"; done
    find $keep -type f -perm -u+x 2>/dev/null | while read -r program; do
      if head -c 4 "$program" | grep -q 'ELF'; then $STRIP "$program" 2>/dev/null || true; fi
    done )
  local archive=$OUT/$name-$version.tar.zst
  # ustar (names in its 255 bytes, as the app's reader takes), sorted, owned
  # by nobody in particular, dated at the epoch: the same bytes each build.
  # A 1 MB window (wlog 20): what the app's decoder must hold while it
  # unpacks (it refuses more than 2 MB), for a few percent of size.
  ( cd "$installed" &&
    tar --format=ustar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 -cf - $keep ) |
    zstd -q -19 --zstd=wlog=20 -T0 -o "$archive.new" -f
  mv "$archive.new" "$archive"
  # Older versions of it go.
  for old in "$OUT/$name"-*.tar.zst; do [ "$old" = "$archive" ] || rm -f "$old"; done
  say "$name: $(du -k "$archive" | cut -f 1) KB packed, $(du -sk "$installed" | cut -f 1) KB installed"
}

for package in "${names[@]}"; do build_one "$package"; done

# The index the app reads: a line a package, "name version file", in the
# order they install. The app installs again when this file changes.
{
  printf 'sqterm packages 1\n'
  for name in $ORDER; do
    for archive in "$OUT/$name"-*.tar.zst; do
      [ -f "$archive" ] || continue
      base=$(basename "$archive")
      version=${base#"$name"-}
      version=${version%.tar.zst}
      printf '%s %s %s %s\n' "$name" "$version" "$base" "$(sha256sum "$archive" | cut -c 1-16)"
    done
  done
} > "$OUT/index.new"
mv "$OUT/index.new" "$OUT/index"
say "index: $(($(wc -l < "$OUT/index") - 1)) package(s) in ${OUT#"$ROOT"/}"
