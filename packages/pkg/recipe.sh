# pkg: sqterm's package tool (sq_app/pkg/pkg.cpp): list, files, update,
# upgrade, search, install (from the release through curl, or from a file),
# remove, backup. sqterm's own, built from this
# repository: no source to download. One file in bin/, libc++ linked in.
#
# It reads packages that are squared cartridges (.sq, the release's
# index-3) through sqcart's reader (third_party/sqcart: sq.cart, C++23
# modules), and tarballs (.tar.zst) through sq_app/src/unpack.cpp.
#
# Built by sqmake from packages/pkg/build.lua (packages/sqmake.sh): the
# sqmake on PATH (sqterm's package, or CI's bootstrapped one: a recipe built
# from this repository takes no `extra`), and clang 23 for the build machine
# (LLVM_BIN, as the runtimes are built) against the sysroot package (bionic)
# and the runtimes package (libc++ 23, its std.cppm), with every flag that
# changes a compiled module on every call. sqcart's reading libraries carry
# yyjson and zstd's decoder, the same files as squared's and sq_app's
# copies: pkg links them from there, once.

version=3
license="sqterm's own"
file=
top=
# What it is built against (the toolchain's bionic and libc++); at run time
# it needs nothing (packages/needs).
depends="sysroot runtimes"
# What it is built from: these decide its key (a PINNED lists its folder's
# sources' sha256s).
inputs="sq_app/pkg/pkg.cpp sq_app/src/unpack.cpp sq_app/src/unpack.hpp sq_app/src/unpack_cartridge.cpp
        squared/third_party/zstd/zstd.h squared/third_party/yyjson/yyjson.h
        third_party/sqcart/PINNED packages/sqmake.sh"
keep="bin/pkg"

recipe_build() {
  . "$ROOT/packages/sqmake.sh"
  local here=${dest%/dest} out=$dest$SQ_PREFIX/bin
  sq_path_sqmake
  if [ -n "$SQ_HOST_TRIPLE" ]; then
    sq_android_tools
  else
    # sqterm's host harness: this machine's clang and libc++ (23, for
    # import std), the std module its libc++'s manifest names.
    SQ_TOOLS=$here/tools
    mkdir -p "$SQ_TOOLS"
    printf '#!/bin/sh\nexec %s "$@"\n' "${CXX:-clang++}" > "$SQ_TOOLS/clang++"
    printf '#!/bin/sh\nexec %s "$@"\n' "${CC:-clang}" > "$SQ_TOOLS/clang"
    chmod +x "$SQ_TOOLS/clang++" "$SQ_TOOLS/clang"
    SQ_STD_CPPM=
  fi
  SQTERM_PKG_VERSION=$version SQ_BUILD_FILE=packages/pkg/build.lua sq_android_build "$ROOT" "$here/obj" pkg
  mkdir -p "$out"
  cp "$here/obj/pkg" "$out/pkg"
}
