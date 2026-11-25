# sqmake 0.11.0: the squared SDK's build system, MIT. It builds what a
# project's build.lua describes, on its own: no make files, no shell. It
# finds the SDK's toolchain itself from squared's build/toolchain.lua
# (`sqmake toolchain` says what it found, or exactly what is missing).
#
#   bin/sqmake     one static program (libc++ linked in, Lua 5.4 compiled in;
#                  only Android's libc, libm and libdl at run time)
#
# C++23 modules (`import std`), so built as sqedit is: by a clang 23 for the
# build machine (LLVM_BIN), against the sysroot package (bionic) and the
# runtimes package (libc++ 23 and its std.cppm), with sqmake's own
# Makefile. Lua, squared's sq.data and yyjson are vendored in its
# repository. A git source: the tag's commit is in sources.lock.

version=0.11.0
license=MIT
git=https://github.com/squared-netizen/sqmake
tag=v$version
file=
top=
depends="sysroot runtimes"
bundled=yes
keep="bin/sqmake share/licenses/sqmake"

recipe_build() {
  local bin=${LLVM_BIN:-/usr/lib/llvm-23/bin}
  [ -x "$bin/clang++" ] || { echo "no clang 23 at $bin (set LLVM_BIN)" >&2; return 1; }
  local triple=aarch64-unknown-linux-android$SQ_API
  local here=${dest%/dest}
  local sysroot=$here/../sysroot/dest$SQ_PREFIX/share/sysroot rt=$here/../runtimes/dest$SQ_PREFIX
  [ -d "$sysroot/usr/include" ] || { echo "no sysroot at $sysroot (build sysroot first)" >&2; return 1; }
  local std
  std=$(ls "$rt"/share/libc++/v*/std.cppm 2>/dev/null | head -n 1)
  [ -f "$std" ] || { echo "no std.cppm in $rt (build runtimes first)" >&2; return 1; }
  # The resource directory and the two compiler scripts, as sqdrive's
  # recipe makes them (its comments say why each flag is there).
  local rd=$here/resource-dir out=$here/obj tools=$here/tools
  rm -rf "$rd" "$out" && mkdir -p "$rd" "$out" "$tools"
  cp -R "$("$bin/clang" -print-resource-dir)/include" "$rd/"
  cp -R "$rt"/lib/clang/*/lib "$rd/"
  local flags="--target=$triple --sysroot=$sysroot -resource-dir=$rd -rtlib=compiler-rt -unwindlib=libunwind -D__BIONIC_CTYPE_INLINE=inline"
  printf '#!/bin/sh\nexec "%s" %s "$@"\n' "$bin/clang" "$flags" > "$tools/clang"
  printf '#!/bin/sh\nexec "%s" %s -nostdinc++ -isystem "%s" -isystem "%s" "$@"\n' "$bin/clang++" "$flags" \
    "$rt/include/$triple/c++/v1" "$rt/include/c++/v1" > "$tools/clang++"
  chmod +x "$tools/clang" "$tools/clang++"
  env -u CFLAGS -u CXXFLAGS -u CPPFLAGS make -j"$JOBS" BUILD="$out" CXX="$tools/clang++" CC="$tools/clang" \
    AR="$bin/llvm-ar" OPT=-O2 STD_MANIFEST= STD_CPPM="$std" \
    LDFLAGS="-stdlib=libc++ -static-libstdc++ -fuse-ld=lld -L$rt/lib/$triple" \
    "$out/sqmake"
  mkdir -p "$dest$SQ_PREFIX/bin"
  cp "$out/sqmake" "$dest$SQ_PREFIX/bin/sqmake"
  # What it is: an arm64 Android program that needs no C++ library.
  "$bin/llvm-readelf" -h "$dest$SQ_PREFIX/bin/sqmake" | "$SQEDIT" match -q -F AArch64
  "$bin/llvm-readelf" -l "$dest$SQ_PREFIX/bin/sqmake" | "$SQEDIT" match -q -F /system/bin/linker64
  ! "$bin/llvm-readelf" -d "$dest$SQ_PREFIX/bin/sqmake" | "$SQEDIT" match -q '"NEEDED" (!"c++" .)* "c++"'
}

recipe_after() {
  local to=share/licenses/sqmake
  mkdir -p "$to"
  cp "$src/LICENSE" "$to/LICENSE"
  cp "$src/third_party/lua/LICENSE" "$to/lua.LICENSE"
  cp "$src/third_party/squared-data/LICENSE" "$to/squared-data.LICENSE"
  cp "$src/third_party/yyjson-0.12.0/LICENSE" "$to/yyjson.LICENSE"
}
