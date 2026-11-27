# squared-pg: sqpg, the squared SDK's project generator, MIT. It creates a
# workspace from a template, kits and packages (`sqpg new`), offline.
#
#   share/squared-pg/sqpg        the program (libc++ linked in, Lua 5.4 in)
#   share/squared-pg/sqcart      sqcart's CLI, which travels with sqpg
#   share/squared-pg/lua/        its workflows (the control layer)
#   share/squared-pg/resources/  what it generates from: squared's templates,
#                                kits, packages and assets, and its own
#   bin/sqpg, bin/sqcart         links to them: sqpg finds its resources
#                                beside its own (real) path
#
# Its sources, each GitHub's archive checked by its sha256: squared-pg itself
# (its tag), and as `extra`, at the commits squared-pg pins, sqcart
# (SQCART_VERSION: compiled in, as tools/bootstrap.sh would clone it to
# sqcart/) and squared (SQUARED_VERSION: its templates, kits, packages and
# assets, which bootstrap.sh would link from resources/.squared); and sqmake,
# for the build machine. Built as sqmake is: by a clang 23 for the build
# machine (LLVM_BIN) against the sysroot and runtimes packages, with
# squared-pg's own build.lua (packages/sqmake.sh).

version=0.1.0-alpha.6
license=MIT
file=squared-pg-$version.tar.gz
url=https://github.com/squared-netizen/squared-pg/archive/refs/tags/v$version.tar.gz
sha256=a5e664fcf352ca422860fbea1d6be82d6e0bc36cbb423231fc69787c7fc984d0
top=squared-pg-$version
# "SUB URL SHA256": GitHub's archive of a commit, checked by its sha256.
extra="
sqcart  https://github.com/squared-netizen/sqcart/archive/e8676d4c6b3187dd205f9c5f5d2fa84f060d25a3.tar.gz 6e7378061203c2ec3430c7aa91592871b67983cd97ca0e957b63fe2a871c820e
sqmake  https://github.com/squared-netizen/sqmake/archive/refs/tags/v0.13.2.tar.gz fabb240ceb83e33ee01614fe1b631f51a262b985c05533bf12177ed2ba43febe
squared https://github.com/squared-netizen/squared/archive/7fcb48a13f95f671e827b855189f23dfff6bf1b6.tar.gz 2d8501ed4e48bb258ac85771c8cd6f1832a7de046298ae5fd0fd579ddb7332e2
"
depends="sysroot runtimes"
inputs=packages/sqmake.sh
bundled=no
keep="bin/sqpg bin/sqcart share/squared-pg share/licenses/squared-pg"

recipe_build() {
  . "$ROOT/packages/sqmake.sh"
  local here=${dest%/dest}
  # The tree bootstrap.sh would assemble, in the unpacked source: sqcart/
  # and squared's resources.
  local tree=$src
  mkdir -p "$tree/sqcart" "$here/squared"
  tar -xzf "$extra_sqcart" -C "$tree/sqcart" --strip-components=1
  tar -xzf "$extra_squared" -C "$here/squared" --strip-components=1
  local kind
  for kind in templates kits packages assets; do
    cp -R "$here/squared/$kind" "$tree/resources/$kind"
  done
  sq_host_sqmake "$extra_sqmake"
  sq_android_tools
  # sqpg, and sqcart's CLI (sqcart3) that travels with it.
  sq_android_build "$tree" "$here/obj" sqpg sqcart3

  local share=$dest$SQ_PREFIX/share/squared-pg
  mkdir -p "$share" "$dest$SQ_PREFIX/bin"
  cp "$here/obj/sqpg" "$share/sqpg"
  cp "$here/obj/sqcart3" "$share/sqcart"
  cp -R "$tree/lua" "$tree/resources" "$share/"
  cp "$tree/VERSION" "$share/VERSION"
  ln -sf ../share/squared-pg/sqpg "$dest$SQ_PREFIX/bin/sqpg"
  ln -sf ../share/squared-pg/sqcart "$dest$SQ_PREFIX/bin/sqcart"
  local program
  for program in sqpg sqcart; do sq_android_program "$share/$program"; done
}

recipe_after() {
  local to=share/licenses/squared-pg
  mkdir -p "$to"
  cp "$src/LICENSE" "$to/LICENSE"
}
