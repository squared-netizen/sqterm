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
# Three sources, at the commits squared-pg pins, each GitHub's archive
# checked by its sha256: squared-pg itself (its tag), and as `extra` sqcart (SQCART_VERSION:
# compiled in, as tools/bootstrap.sh would clone it to sqcart/) and squared
# (SQUARED_VERSION: its templates, kits, packages and assets, which
# bootstrap.sh would link from resources/.squared). Built as sqmake is: by
# a clang 23 for the build machine (LLVM_BIN) against the sysroot and
# runtimes packages, with squared-pg's own Makefile.

version=0.1.0-alpha.4
license=MIT
file=squared-pg-$version.tar.gz
url=https://github.com/squared-netizen/squared-pg/archive/refs/tags/v$version.tar.gz
sha256=f5f79efe9a2537b27d5f919700c15b438452f2a5b72ed4d3b2b08f10b46e7dc1
top=squared-pg-$version
# "SUB URL SHA256": GitHub's archive of a commit, checked by its sha256.
extra="
sqcart  https://github.com/squared-netizen/sqcart/archive/c43983bd6679160b227aeb8210a381ab1000a1d7.tar.gz 386254f3f01232b4736fbc0e23ed4ad4b0657a1726ccabe53463f69f8aa158a8
squared https://github.com/squared-netizen/squared/archive/9d188e5047363d4bf22684472129c38212a34f23.tar.gz a92a2f5163e8c99f288137c8522bc248a48a0674743a48894958fbbce2753751
"
depends="sysroot runtimes"
bundled=no
keep="bin/sqpg bin/sqcart share/squared-pg share/licenses/squared-pg"

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

  # The resource directory and the two compiler scripts, as sqmake's recipe
  # makes them.
  local rd=$here/resource-dir tools=$here/tools
  rm -rf "$rd" && mkdir -p "$rd" "$tools"
  cp -R "$("$bin/clang" -print-resource-dir)/include" "$rd/"
  cp -R "$rt"/lib/clang/*/lib "$rd/"
  local flags="--target=$triple --sysroot=$sysroot -resource-dir=$rd -rtlib=compiler-rt -unwindlib=libunwind -D__BIONIC_CTYPE_INLINE=inline"
  printf '#!/bin/sh\nexec "%s" %s "$@"\n' "$bin/clang" "$flags" > "$tools/clang"
  printf '#!/bin/sh\nexec "%s" %s -nostdinc++ -isystem "%s" -isystem "%s" "$@"\n' "$bin/clang++" "$flags" \
    "$rt/include/$triple/c++/v1" "$rt/include/c++/v1" > "$tools/clang++"
  chmod +x "$tools/clang" "$tools/clang++"
  # LDFLAGS without -lpthread: bionic's pthreads are in libc.
  (cd "$tree" && env -u CFLAGS -u CXXFLAGS -u CPPFLAGS make -j"$JOBS" CXX="$tools/clang++" CC="$tools/clang" \
    AR="$bin/llvm-ar" OPT=-O2 STD_MANIFEST= STD_CPPM="$std" \
    LDFLAGS="-stdlib=libc++ -static-libstdc++ -fuse-ld=lld -L$rt/lib/$triple" build/sqpg)

  local share=$dest$SQ_PREFIX/share/squared-pg
  mkdir -p "$share" "$dest$SQ_PREFIX/bin"
  cp "$tree/build/sqpg" "$share/sqpg"
  cp "$tree/sqcart/v3/build/sqcart3" "$share/sqcart"
  cp -R "$tree/lua" "$tree/resources" "$share/"
  cp "$tree/VERSION" "$share/VERSION"
  ln -sf ../share/squared-pg/sqpg "$dest$SQ_PREFIX/bin/sqpg"
  ln -sf ../share/squared-pg/sqcart "$dest$SQ_PREFIX/bin/sqcart"
  # What it is: arm64 Android programs that need no C++ library.
  local program
  for program in sqpg sqcart; do
    "$bin/llvm-readelf" -h "$share/$program" | "$SQEDIT" match -q -F AArch64
    "$bin/llvm-readelf" -l "$share/$program" | "$SQEDIT" match -q -F /system/bin/linker64
    ! "$bin/llvm-readelf" -d "$share/$program" | "$SQEDIT" match -q '"NEEDED" (!"c++" .)* "c++"'
  done
}

recipe_after() {
  local to=share/licenses/squared-pg
  mkdir -p "$to"
  cp "$src/LICENSE" "$to/LICENSE"
}
