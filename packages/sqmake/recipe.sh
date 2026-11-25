# sqmake 0.12.0: the squared SDK's build system, MIT. It builds what a
# project's build.lua describes, on its own: no make files, no shell. It
# finds the SDK's toolchain itself from squared's build/toolchain.lua
# (`sqmake toolchain` says what it found, or exactly what is missing).
#
#   bin/sqmake     one static program (libc++ linked in, Lua 5.4 compiled in;
#                  only Android's libc, libm and libdl at run time)
#
# C++23 modules (`import std`), so built as sqedit is: by a clang 23 for the
# build machine (LLVM_BIN), against the sysroot package (bionic) and the
# runtimes package (libc++ 23 and its std.cppm), with sqmake's own build.lua
# (packages/sqmake.sh), by a sqmake for the build machine bootstrapped from
# the same clone. Lua, squared's sq.data and yyjson are vendored in its
# repository. A git source: the tag's commit is in sources.lock.

version=0.12.0
license=MIT
git=https://github.com/squared-netizen/sqmake
tag=v$version
file=
top=
depends="sysroot runtimes"
inputs=packages/sqmake.sh
bundled=yes
keep="bin/sqmake share/licenses/sqmake"

recipe_build() {
  . "$ROOT/packages/sqmake.sh"
  local here=${dest%/dest}
  # Itself for this machine first (in the clone's build/), then for Android
  # (in $here/obj).
  sq_host_sqmake "$src"
  sq_android_tools
  sq_android_build "$src" "$here/obj" sqmake
  mkdir -p "$dest$SQ_PREFIX/bin"
  cp "$here/obj/sqmake" "$dest$SQ_PREFIX/bin/sqmake"
  sq_android_program "$dest$SQ_PREFIX/bin/sqmake"
}

recipe_after() {
  local to=share/licenses/sqmake
  mkdir -p "$to"
  cp "$src/LICENSE" "$to/LICENSE"
  cp "$src/third_party/lua/LICENSE" "$to/lua.LICENSE"
  cp "$src/third_party/squared-data/LICENSE" "$to/squared-data.LICENSE"
  cp "$src/third_party/yyjson-0.12.0/LICENSE" "$to/yyjson.LICENSE"
}
