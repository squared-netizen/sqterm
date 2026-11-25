# packages/sqmake.sh: what the recipes of the SDK's own tools share, the
# tools built by sqmake from their own build.lua (sqmake, sqedit, apkpack,
# sqdrive, square, squared-pg, and sqgui and sqconsole), and sqterm's own
# (pkg by sqmake; sqterm-tools by the compilers alone). A recipe names it in
# `inputs` and sources it from recipe_build:
#
#   . "$ROOT/packages/sqmake.sh"
#   sq_host_sqmake SOURCE      sqmake for this machine, from a sqmake source
#                              tree or its archive (an `extra` file), by its
#                              tools/bootstrap.sh (a compiler and a shell, no
#                              make): $SQ_HOST_SQMAKE
#   sq_path_sqmake             the sqmake on PATH (or $SQMAKE) instead, for a
#                              recipe built from this repository, which takes
#                              no `extra` (pkg): $SQ_HOST_SQMAKE
#   sq_android_tools           clang and clang++ for Android, as scripts
#                              ($SQ_TOOLS), against the sysroot and runtimes
#                              packages; $SQ_STD_CPPM, their std.cppm
#   sq_android_build DIR OUT GOAL...
#                              DIR's build.lua for Android, built into OUT
#                              (the source is only read); $SQ_BUILD_FILE for
#                              another build file of DIR's
#   sq_android_program FILE    holds FILE to what each of these is: an arm64
#                              Android program that needs no C++ library
#
# Each tool is one static program: libc++ linked in, only Android's libc, libm
# and libdl at run time. Built by a clang 23 for the build machine (LLVM_BIN,
# default apt.llvm.org's on CI), with none of the Android flags build.sh
# exports (their own builds say theirs).

SQ_LLVM=${LLVM_BIN:-/usr/lib/llvm-23/bin}

sq_host_sqmake() {
  [ -x "$SQ_LLVM/clang++" ] || { echo "no clang 23 at $SQ_LLVM (set LLVM_BIN)" >&2; return 1; }
  local from=$1
  if [ -f "$from" ]; then
    from=${dest%/dest}/sqmake
    rm -rf "$from" && mkdir -p "$from"
    tar -xzf "$1" -C "$from" --strip-components=1
  fi
  ( cd "$from" && env -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS SQMAKE_CACHE=off \
      CXX="$SQ_LLVM/clang++" CC="$SQ_LLVM/clang" AR="$SQ_LLVM/llvm-ar" sh tools/bootstrap.sh )
  SQ_HOST_SQMAKE=$from/build/sqmake
  [ -x "$SQ_HOST_SQMAKE" ] || { echo "sqmake did not build in $from" >&2; return 1; }
}

sq_path_sqmake() {
  SQ_HOST_SQMAKE=$(command -v "${SQMAKE:-sqmake}") ||
    { echo "no sqmake on PATH (set SQMAKE; in sqterm, pkg install sqmake)" >&2; return 1; }
}

sq_android_tools() {
  [ -x "$SQ_LLVM/clang++" ] || { echo "no clang 23 at $SQ_LLVM (set LLVM_BIN)" >&2; return 1; }
  local triple=aarch64-unknown-linux-android$SQ_API
  local here=${dest%/dest}
  local sysroot=$here/../sysroot/dest$SQ_PREFIX/share/sysroot rt=$here/../runtimes/dest$SQ_PREFIX
  [ -d "$sysroot/usr/include" ] || { echo "no sysroot at $sysroot (build sysroot first)" >&2; return 1; }
  SQ_STD_CPPM=$(ls "$rt"/share/libc++/v*/std.cppm 2>/dev/null | head -n 1)
  [ -f "$SQ_STD_CPPM" ] || { echo "no std.cppm in $rt (build runtimes first)" >&2; return 1; }
  # A resource directory: the build machine clang's own headers, the
  # runtimes' builtins (as the runtimes recipe links its proofs).
  local rd=$here/resource-dir
  SQ_TOOLS=$here/tools
  rm -rf "$rd" "$SQ_TOOLS" && mkdir -p "$rd" "$SQ_TOOLS"
  cp -R "$("$SQ_LLVM/clang" -print-resource-dir)/include" "$rd/"
  cp -R "$rt"/lib/clang/*/lib "$rd/"
  # -D__BIONIC_CTYPE_INLINE=inline, as the sysroot's clang.cfg gives every
  # compile: import std cannot export bionic's static inline ctype. The
  # runtime libraries on every compile, not only the link: they decide target
  # features (compiler-rt turns on outline atomics and function
  # multiversioning), and a module compiled with others is refused (CI,
  # 2026-11-19). The link's flags too (a build.lua's own are for its host):
  # libc++ linked in, by lld, 16 KB pages (Android 15's devices with them
  # load nothing aligned to less), and -lpthread left out (bionic's pthreads
  # are in libc; it has no libpthread). As squared's build/toolchain.lua's.
  local flags="--target=$triple --sysroot=$sysroot -resource-dir=$rd -rtlib=compiler-rt -unwindlib=libunwind"
  flags="$flags -pthread -D__BIONIC_CTYPE_INLINE=inline -Wno-unused-command-line-argument"
  local link="-static-libstdc++ -fuse-ld=lld -Wl,-z,max-page-size=16384 -L$rt/lib/$triple"
  local drop='for a; do shift; [ "$a" = -lpthread ] || set -- "$@" "$a"; done'
  printf '#!/bin/sh\n%s\nexec "%s" %s %s "$@"\n' "$drop" "$SQ_LLVM/clang" "$flags" "$link" > "$SQ_TOOLS/clang"
  printf '#!/bin/sh\n%s\nexec "%s" %s -nostdinc++ -isystem "%s" -isystem "%s" %s "$@"\n' "$drop" "$SQ_LLVM/clang++" \
    "$flags" "$rt/include/$triple/c++/v1" "$rt/include/c++/v1" "$link" > "$SQ_TOOLS/clang++"
  chmod +x "$SQ_TOOLS/clang" "$SQ_TOOLS/clang++"
}

sq_android_build() {
  local dir=$1 out=$2
  shift 2
  local here=${dest%/dest}
  # A build file of the recipe's own: the project's build.lua, its outputs
  # in OUT and its std.cppm the runtimes'.
  cat > "$here/package.lua" <<'LUA'
toolchain.build = os.getenv("SQ_OUT")
toolchain.std_cppm = os.getenv("SQ_STD_CPPM")
toolchain.ar = os.getenv("SQ_AR")
include(os.getenv("SQ_BUILD_FILE") or "build.lua")
LUA
  local goals=() goal
  for goal; do goals+=("$out/$goal"); done
  ( cd "$dir" && env -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS SQMAKE_CACHE=off OPT=-O2 \
      CXX="$SQ_TOOLS/clang++" CC="$SQ_TOOLS/clang" SQ_OUT="$out" SQ_STD_CPPM="$SQ_STD_CPPM" \
      SQ_AR="$SQ_LLVM/llvm-ar" SQ_BUILD_FILE="${SQ_BUILD_FILE:-build.lua}" "$SQ_HOST_SQMAKE" -f "$here/package.lua" -j"$JOBS" "${goals[@]}" )
}

sq_android_program() {
  "$SQ_LLVM/llvm-readelf" -h "$1" | "$SQEDIT" match -q -F AArch64
  "$SQ_LLVM/llvm-readelf" -l "$1" | "$SQEDIT" match -q -F /system/bin/linker64
  ! "$SQ_LLVM/llvm-readelf" -d "$1" | "$SQEDIT" match -q '"NEEDED" (!"c++" .)* "c++"'
}
