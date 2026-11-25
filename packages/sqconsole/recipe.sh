# sqconsole: squared's Console client (squared/console/client), MIT. A
# debug build's Console in this terminal: its log as it is written, every
# line typed a command, files pulled and pushed. `sqmake console` (squared's
# build/android.lua) runs it, through the bridge file a
# debug build keeps (build/dev/bridge.conf).
#
#   bin/sqconsole  one static program (libc++ linked in; only Android's
#                  libc, libm and libdl at run time)
#
# Built with sqmake (as sqgen was): squared's build/squared.lua (platform
# "host", the null graphics backend) and the SDK's toolchain, from the
# squared sqterm carries (SQUARED_REV); sqmake v0.12.0 bootstrapped first for
# the build machine (packages/sqmake.sh), from the source sources.lock
# records as sqconsole@.

version=0.1.0
license=MIT
git=https://github.com/squared-netizen/sqmake
tag=v0.12.0
file=
top=
depends="sysroot runtimes"
# squared changes only by tools/vendor_framework.sh, which writes SQUARED_REV.
inputs="SQUARED_REV squared/build/squared.lua squared/build/toolchain.lua squared/console/client/sqconsole.cpp packages/sqmake.sh"
bundled=yes
keep="bin/sqconsole share/licenses/sqconsole"

recipe_build() {
  local bin=${LLVM_BIN:-/usr/lib/llvm-23/bin}
  [ -x "$bin/clang++" ] || { echo "no clang 23 at $bin (set LLVM_BIN)" >&2; return 1; }
  local here=${dest%/dest}
  local sysroot=$here/../sysroot/dest$SQ_PREFIX/share/sysroot rt=$here/../runtimes/dest$SQ_PREFIX
  [ -d "$sysroot/usr/include" ] || { echo "no sysroot at $sysroot (build sysroot first)" >&2; return 1; }
  # 1. sqmake, for this machine (packages/sqmake.sh: its tools/bootstrap.sh).
  . "$ROOT/packages/sqmake.sh"
  sq_host_sqmake "$src"
  # 2. sqconsole, for Android: a build.lua beside a copy of squared (sqmake
  #    writes its build/ there), the toolchain found from the installs of
  #    what this depends on.
  local work=$here/work
  rm -rf "$work" && mkdir -p "$work"
  cp -R "$ROOT/squared" "$work/squared"
  cat > "$work/build.lua" <<'LUA'
toolchain.sdk("squared/build/toolchain.lua")
squared_settings = {root = "squared", platform = "host", graphics = "null"}
local squared = include("squared/build/squared.lua")
exe{name = "sqconsole", srcs = {"squared/console/client/sqconsole.cpp"}, deps = {squared.console}, flags = {"-O2"}}
LUA
  ( cd "$work" &&
    env -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS -u CXX -u CC \
      SQ_LLVM_BIN="$bin" SQ_SYSROOT="$sysroot" SQ_RUNTIMES="$rt" SQ_API="$SQ_API" \
      "$SQ_HOST_SQMAKE" -j"$JOBS" )
  mkdir -p "$dest$SQ_PREFIX/bin"
  cp "$work/build/sqconsole" "$dest$SQ_PREFIX/bin/sqconsole"
  # What it is: an arm64 Android program that needs no C++ library.
  "$bin/llvm-readelf" -h "$dest$SQ_PREFIX/bin/sqconsole" | "$SQEDIT" match -q -F AArch64
  "$bin/llvm-readelf" -l "$dest$SQ_PREFIX/bin/sqconsole" | "$SQEDIT" match -q -F /system/bin/linker64
  ! "$bin/llvm-readelf" -d "$dest$SQ_PREFIX/bin/sqconsole" | "$SQEDIT" match -q '"NEEDED" (!"c++" .)* "c++"'
}

recipe_after() {
  local to=share/licenses/sqconsole
  mkdir -p "$to"
  # squared's (sqterm's LICENSE is the same text; squared/ carries none).
  cp "$ROOT/LICENSE" "$to/LICENSE"
  cp "$ROOT/squared/third_party/yyjson/LICENSE" "$to/yyjson.LICENSE"
  # stb_image's, the end of its header.
  tail -n 41 "$ROOT/squared/third_party/stb/stb_image.h" > "$to/stb_image.LICENSE"
}
