# sqgui: the squared SDK's UI editor, MIT.
#
#   bin/sqgui-gen  an app's sq_app/names.json and sq_app/layouts/*.json into
#                  C++ (names.hpp, layouts.hpp, layouts.cpp), which an app's
#                  build runs (squared's sq/build/template.lua and
#                  mk/pkg_squared_core.mk); once squared's sqgen, the same
#                  output byte for byte
#   bin/sqgui      the editor: list, show, get, check, map, names (words or
#                  --json), view (the terminal face), and set, unset, insert,
#                  remove, move and undo, which change one thing and keep
#                  every other byte
#
# Each one static program (libc++ linked in; only Android's libc, libm and
# libdl at run time).
#
# Built with sqmake, as sqconsole is: sqgui's build.lua, against the squared
# sqterm carries (SQUARED_REV) and the SDK's toolchain (SQ_SYSROOT names the
# sysroot). sqmake 0.12.0 is bootstrapped first for the build machine, from
# its tag's archive (an `extra` file: packages/sqmake.sh); sqgui from its
# tag's.

version=0.4.0
license=MIT
file=sqgui-$version.tar.gz
url=https://github.com/squared-netizen/sqgui/archive/refs/tags/v$version.tar.gz
sha256=ab1ac63aeb23f12812b72e084790dd9994d272ab28fe3591ea18cca739a41c55
top=sqgui-$version
# "SUB URL SHA256": sqmake, for the build machine.
extra="
sqmake https://github.com/squared-netizen/sqmake/archive/refs/tags/v0.12.0.tar.gz 2d9f540d41cff5fd320d6e039126fd979502e0026eac99d42414cfc19ae336ff
"
depends="sysroot runtimes"
# squared changes only by tools/vendor_framework.sh, which writes SQUARED_REV.
inputs="SQUARED_REV squared/build/squared.lua squared/build/toolchain.lua packages/sqmake.sh"
bundled=yes
keep="bin/sqgui-gen bin/sqgui share/licenses/sqgui"

recipe_build() {
  local bin=${LLVM_BIN:-/usr/lib/llvm-23/bin}
  [ -x "$bin/clang++" ] || { echo "no clang 23 at $bin (set LLVM_BIN)" >&2; return 1; }
  local here=${dest%/dest}
  local sysroot=$here/../sysroot/dest$SQ_PREFIX/share/sysroot rt=$here/../runtimes/dest$SQ_PREFIX
  [ -d "$sysroot/usr/include" ] || { echo "no sysroot at $sysroot (build sysroot first)" >&2; return 1; }
  # 1. sqmake, for this machine (packages/sqmake.sh: its tools/bootstrap.sh).
  . "$ROOT/packages/sqmake.sh"
  sq_host_sqmake "$extra_sqmake"
  # 2. sqgui-gen, for Android: sqgui's build.lua in the unpacked source
  #    (sqmake writes its build/ there), against sqterm's squared.
  ( cd "$src" &&
    env -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS -u CXX -u CC \
      SQUARED="$ROOT/squared" SQ_LLVM_BIN="$bin" SQ_SYSROOT="$sysroot" SQ_RUNTIMES="$rt" SQ_API="$SQ_API" \
      "$SQ_HOST_SQMAKE" -j"$JOBS" )
  mkdir -p "$dest$SQ_PREFIX/bin"
  local program
  for program in sqgui-gen sqgui; do
    cp "$src/build/$program" "$dest$SQ_PREFIX/bin/$program"
    # What it is: an arm64 Android program that needs no C++ library.
    "$bin/llvm-readelf" -h "$dest$SQ_PREFIX/bin/$program" | "$SQEDIT" match -q -F AArch64
    "$bin/llvm-readelf" -l "$dest$SQ_PREFIX/bin/$program" | "$SQEDIT" match -q -F /system/bin/linker64
    ! "$bin/llvm-readelf" -d "$dest$SQ_PREFIX/bin/$program" | "$SQEDIT" match -q '"NEEDED" (!"c++" .)* "c++"'
  done
}

recipe_after() {
  local to=share/licenses/sqgui
  mkdir -p "$to"
  cp "$src/LICENSE" "$to/LICENSE"
  cp "$ROOT/squared/third_party/yyjson/LICENSE" "$to/yyjson.LICENSE"
  # stb_image's, the end of its header.
  tail -n 41 "$ROOT/squared/third_party/stb/stb_image.h" > "$to/stb_image.LICENSE"
}
