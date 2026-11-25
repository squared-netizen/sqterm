# sqedit 0.2.0: a text tool on parsing expression grammars, MIT. What sed,
# grep and awk did in squared's and sqterm's builds and scripts: match,
# pick, lines, sub, wrap and json, each with a count it can be held to.
# squared's build needs it (build/common.mk), so it is in the APK.
#
#   bin/sqedit     one static program (libc++ linked in; only Android's
#                  libc, libm and libdl at run time)
#
# C++23 modules (`import std`), so built as sqdrive is: by a clang 23 for
# the build machine (LLVM_BIN), against the sysroot package (bionic) and the
# runtimes package (libc++ 23 and its std.cppm), with sqedit's own build.lua
# and sqmake (packages/sqmake.sh). squared's sq.data and yyjson are vendored
# in its repository. GitHub's archive of its tag, checked by its sha256 (an
# archive, not a clone: a git source takes no `extra`).

version=0.2.0
license=MIT
file=sqedit-$version.tar.gz
url=https://github.com/squared-netizen/sqedit/archive/refs/tags/v$version.tar.gz
sha256=1c97104a92eca2f15a079748e6c03cd7c458208ddf54f598f94619dd13a1a50a
top=sqedit-$version
# "SUB URL SHA256": sqmake, for the build machine (its tools/bootstrap.sh).
extra="
sqmake https://github.com/squared-netizen/sqmake/archive/refs/tags/v0.12.0.tar.gz 2d9f540d41cff5fd320d6e039126fd979502e0026eac99d42414cfc19ae336ff
"
depends="sysroot runtimes"
inputs=packages/sqmake.sh
bundled=yes
keep="bin/sqedit share/licenses/sqedit"

recipe_build() {
  . "$ROOT/packages/sqmake.sh"
  local here=${dest%/dest}
  sq_host_sqmake "$extra_sqmake"
  sq_android_tools
  # The source is only read: everything is built in $here/obj.
  sq_android_build "$src" "$here/obj" sqedit
  mkdir -p "$dest$SQ_PREFIX/bin"
  cp "$here/obj/sqedit" "$dest$SQ_PREFIX/bin/sqedit"
  sq_android_program "$dest$SQ_PREFIX/bin/sqedit"
}

recipe_after() {
  local to=share/licenses/sqedit
  mkdir -p "$to"
  cp "$src/LICENSE" "$to/LICENSE"
  cp "$src/third_party/squared-data/LICENSE" "$to/squared-data.LICENSE"
  cp "$src/third_party/yyjson-0.12.0/LICENSE" "$to/yyjson.LICENSE"
}
