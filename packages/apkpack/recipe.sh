# apkpack 0.2.1: an APK built and signed with no Java and no Android SDK,
# MIT. In place of aapt2, zipalign, apksigner and android.jar: link (the
# manifest and res/ compiled, assets/ in whole), add (16 KB aligned .so),
# sign (APK signature scheme v2, ECDSA P-256), keygen, dump. sqterm's build
# packs its APK with it (sqmake's apk{}).
#
#   bin/apkpack    one static program (libc++ linked in; only Android's
#                  libc, libm and libdl at run time)
#
# C++23 modules (`import std`), so built as sqdrive is: by a clang 23 for
# the build machine (LLVM_BIN), against the sysroot package (bionic) and the
# runtimes package (libc++ 23 and its std.cppm), with apkpack's own
# build.lua and sqmake (packages/sqmake.sh). micro-ecc is vendored in its
# repository. A git source: the tag's commit is in sources.lock.

version=0.2.1
license=MIT
git=https://github.com/squared-netizen/apkpack
tag=v$version
file=
top=
# "SUB URL SHA256": sqmake, for the build machine (its tools/bootstrap.sh).
extra="
sqmake https://github.com/squared-netizen/sqmake/archive/refs/tags/v0.12.0.tar.gz 2d9f540d41cff5fd320d6e039126fd979502e0026eac99d42414cfc19ae336ff
"
depends="sysroot runtimes"
inputs=packages/sqmake.sh
bundled=yes
keep="bin/apkpack share/licenses/apkpack"

recipe_build() {
  . "$ROOT/packages/sqmake.sh"
  local here=${dest%/dest}
  sq_host_sqmake "$extra_sqmake"
  sq_android_tools
  # The clone is read in place: everything is built in $here/obj.
  sq_android_build "$src" "$here/obj" apkpack
  mkdir -p "$dest$SQ_PREFIX/bin"
  cp "$here/obj/apkpack" "$dest$SQ_PREFIX/bin/apkpack"
  sq_android_program "$dest$SQ_PREFIX/bin/apkpack"
}

recipe_after() {
  local to=share/licenses/apkpack
  mkdir -p "$to"
  cp "$src/LICENSE" "$to/LICENSE"
  cp "$src/NOTICE.android" "$to/NOTICE.android"
  cp "$src/third_party/micro-ecc/LICENSE.txt" "$to/micro-ecc.LICENSE.txt"
}
