# square 0.5.2: the squared SDK's workspace manager, MIT. The one tool that
# knows what a workspace is: square info, where, owner, verify, roles, find,
# pack, explode, resources, show, and square call (the SDK's tool protocol),
# on the workspaces sqpg makes (pkg install squared-pg) and the cartridges it
# installs, and your own ($XDG_DATA_HOME/squared-pg/resources).
#
#   bin/square     one static program (libc++ linked in; only Android's
#                  libc, libm and libdl at run time)
#
# C++23 modules (`import std`), so built as sqedit is: by a clang 23 for the
# build machine (LLVM_BIN), against the sysroot and runtimes packages, with
# square's own build.lua and sqmake (packages/sqmake.sh). sqdrive (how it
# packs and explodes) and the sqcart it builds on (with squared's sq.data
# and yyjson) are vendored in its repository. A git source: the tag's commit
# is in sources.lock.

version=0.5.2
license=MIT
git=https://github.com/squared-netizen/square
tag=v$version
file=
top=
# "SUB URL SHA256": sqmake, for the build machine (its tools/bootstrap.sh).
extra="
sqmake https://github.com/squared-netizen/sqmake/archive/refs/tags/v0.12.0.tar.gz 2d9f540d41cff5fd320d6e039126fd979502e0026eac99d42414cfc19ae336ff
"
depends="sysroot runtimes"
inputs=packages/sqmake.sh
bundled=no
keep="bin/square share/licenses/square"

recipe_build() {
  . "$ROOT/packages/sqmake.sh"
  local here=${dest%/dest}
  sq_host_sqmake "$extra_sqmake"
  sq_android_tools
  # The clone is read in place: everything is built in $here/obj.
  sq_android_build "$src" "$here/obj" square
  mkdir -p "$dest$SQ_PREFIX/bin"
  cp "$here/obj/square" "$dest$SQ_PREFIX/bin/square"
  sq_android_program "$dest$SQ_PREFIX/bin/square"
}

recipe_after() {
  local to=share/licenses/square
  mkdir -p "$to"
  cp "$src/LICENSE" "$to/LICENSE"
  cp "$src/third_party/sqcart/LICENSE" "$to/sqcart.LICENSE"
  cp "$src/third_party/sqdrive/LICENSE" "$to/sqdrive.LICENSE"
}
