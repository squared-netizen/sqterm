# sqdrive 0.6.0: the Virtual Cartridge Drive's tool, MIT. Reads and writes
# the files of a squared cartridge (sqcart 3.0) by range: ls, stat, cat,
# bench, write, truncate, rm, mv, commit, recover. Its journals go in
# ~/.local/state/sqdrive (or $SQDRIVE_STAGING).
#
#   bin/sqdrive    one static program (libc++ linked in; only Android's
#                  libc, libm and libdl at run time)
#
# C++23 modules (`import std`), so built as squared's own C++ is: by a clang
# 23 for the build machine (LLVM_BIN, as the runtimes are; the NDK's is 21),
# against the sysroot package (bionic) and the runtimes package (libc++ 23
# and its std.cppm), with sqdrive's own build.lua and sqmake
# (packages/sqmake.sh). sqcart, zstd, yyjson, Monocypher and squared's
# sq.data are vendored in its repository: nothing else to download. GitHub's
# archive of its tag, checked by its sha256 (an archive, not a clone: a git
# source takes no `extra`).

version=0.6.0
license=MIT
file=sqdrive-$version.tar.gz
url=https://github.com/squared-netizen/sqdrive/archive/refs/tags/v$version.tar.gz
sha256=1063f58d76b31e8f101a583cb21e49027c676717e2e592162b1a08b240145526
top=sqdrive-$version
# "SUB URL SHA256": sqmake, for the build machine (its tools/bootstrap.sh).
extra="
sqmake https://github.com/squared-netizen/sqmake/archive/refs/tags/v0.12.0.tar.gz 2d9f540d41cff5fd320d6e039126fd979502e0026eac99d42414cfc19ae336ff
"
depends="sysroot runtimes"
inputs=packages/sqmake.sh
bundled=no
keep="bin/sqdrive share/licenses/sqdrive"

recipe_build() {
  . "$ROOT/packages/sqmake.sh"
  local here=${dest%/dest}
  sq_host_sqmake "$extra_sqmake"
  sq_android_tools
  # The source is only read: everything is built in $here/obj.
  sq_android_build "$src" "$here/obj" sqdrive
  mkdir -p "$dest$SQ_PREFIX/bin"
  cp "$here/obj/sqdrive" "$dest$SQ_PREFIX/bin/sqdrive"
  sq_android_program "$dest$SQ_PREFIX/bin/sqdrive"
}

recipe_after() {
  local to=share/licenses/sqdrive tp=$src/third_party/sqcart
  mkdir -p "$to"
  cp "$src/LICENSE" "$to/LICENSE"
  cp "$tp/LICENSE" "$to/sqcart.LICENSE"
  cp "$tp/third_party/squared-data/LICENSE" "$to/squared-data.LICENSE"
  cp "$tp/third_party/zstd-1.5.7/LICENSE" "$to/zstd.LICENSE"
  cp "$tp/third_party/yyjson-0.12.0/LICENSE" "$to/yyjson.LICENSE"
  cp "$tp/third_party/monocypher-4.0.3/LICENCE.md" "$to/monocypher.LICENCE.md"
}
