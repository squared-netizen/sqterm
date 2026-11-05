# ncurses: the terminal database and the library zsh's line editor draws with.
#
# Built static only (the prefix's programs link it in; no .so to load), wide
# (UTF-8), for the prefix's terminfo directory. The package carries the
# programs a shell user calls (tic, infocmp, tput, clear, reset, tset, toe)
# and a short terminfo database: sqterm's own entry, compiled here from
# terminfo/sqterm.ti, and the few others a remote machine or a program may
# ask for. Headers and the library stay in the build, for what links them
# (zsh); they join the prefix with the compiler (12.5, later).
#
# GNU publishes no sha256 for ncurses, only a signature: the first download
# is recorded in packages/sources.lock.

version=6.6
file=ncurses-$version.tar.gz
url=https://ftp.gnu.org/gnu/ncurses/$file
mirrors="https://invisible-mirror.net/archives/ncurses/$file"
sha256=
top=ncurses-$version
depends=
keep="bin/tic bin/infocmp bin/tput bin/clear bin/reset bin/tset bin/toe share/terminfo
      share/licenses/ncurses"

recipe_patch() {
  # Paths outside the prefix that tic and tset use: there is no /tmp or /etc
  # an app can write on Android.
  sed -i "s|\"/tmp/XXXXXX\"|\"$SQ_PREFIX/tmp/XXXXXX\"|" progs/tic.c
  sed -i "s|\"/etc/termcap\"|\"$SQ_PREFIX/etc/termcap\"|" progs/tic.c
  sed -i "s|\"/etc/ttytype\"|\"$SQ_PREFIX/etc/ttytype\"|; s|\"/etc/ttys\"|\"$SQ_PREFIX/etc/ttys\"|" progs/tset.c
}

recipe_build() {
  # Android refuses hard links in an app's files (the phone, 2026-11-04: tic's
  # "cannot link l/lpr to p/printer"): tic makes an entry's other names as
  # symbolic links. The database is not installed whole (--disable-db-install,
  # and the install would run whichever tic is on PATH): recipe_after
  # compiles the entries kept, with the tic built here.
  # --enable-big-core: configure skips its memory test when it takes the
  # build for a cross one (the phone, 2026-11-04), and then builds a tic that
  # refuses -e ("can't be used without -I or -C"), which recipe_after uses.
  # A phone has the memory.
  # nl_langinfo is API 26 and locale.h's functions are not all there at 22:
  # ncurses takes its charset from the environment instead.
  ./configure ${SQ_HOST_TRIPLE:+--host=$SQ_HOST_TRIPLE --build=$(sh ./config.guess)} \
    --prefix="$SQ_PREFIX" \
    --without-shared --with-normal --without-debug \
    --without-ada --without-cxx --without-cxx-binding --without-tests --without-manpages \
    --enable-widec --enable-overwrite --enable-const \
    --enable-ext-colors --enable-ext-mouse --disable-stripping \
    --enable-symlinks --disable-db-install --enable-big-core \
    --with-default-terminfo-dir="$SQ_PREFIX/share/terminfo" \
    --with-terminfo-dirs="$SQ_PREFIX/share/terminfo" \
    --with-termpath="$SQ_PREFIX/etc/termcap" \
    ac_cv_header_locale_h=no am_cv_langinfo_codeset=no
  make -j"$JOBS"
  make install DESTDIR="$dest"
}

recipe_after() {
  # The terminfo database: the entries a shell, a remote machine or a
  # program may ask for (the whole is 8 MB), and sqterm's own, compiled by
  # the tic built here (it runs where it was built: on the phone, and in a
  # host test). An entry's other names become symbolic links.
  local entries=ansi,dumb,linux,screen,screen-256color,tmux,tmux-256color
  entries=$entries,vt100,vt102,vt220,xterm,xterm-256color,xterm-color,xterm-direct
  mkdir -p share/terminfo
  ./bin/tic -x -e "$entries" -o share/terminfo "$src/misc/terminfo.src"
  ./bin/tic -x -o share/terminfo "$ROOT/terminfo/sqterm.ti"
  local entry
  for entry in a/ansi d/dumb x/xterm-256color s/sqterm; do
    [ -f "share/terminfo/$entry" ] || { echo "tic did not write $entry" >&2; return 1; }
  done
  # Its licence travels with it.
  mkdir -p share/licenses/ncurses
  cp "$src/COPYING" share/licenses/ncurses/COPYING
}
