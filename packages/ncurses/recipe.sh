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
  # nl_langinfo is API 26 and locale.h's functions are not all there at 22:
  # ncurses takes its charset from the environment instead.
  ./configure ${SQ_HOST_TRIPLE:+--host=$SQ_HOST_TRIPLE --build=$(sh ./config.guess)} \
    --prefix="$SQ_PREFIX" \
    --without-shared --with-normal --without-debug \
    --without-ada --without-cxx --without-cxx-binding --without-tests --without-manpages \
    --enable-widec --enable-overwrite --enable-const \
    --enable-ext-colors --enable-ext-mouse --disable-stripping \
    --with-default-terminfo-dir="$SQ_PREFIX/share/terminfo" \
    --with-terminfo-dirs="$SQ_PREFIX/share/terminfo" \
    --with-termpath="$SQ_PREFIX/etc/termcap" \
    ac_cv_header_locale_h=no am_cv_langinfo_codeset=no
  make -j"$JOBS"
  make install DESTDIR="$dest"
}

recipe_after() {
  # The terminfo database, cut to what is used (the whole is 8 MB), with
  # sqterm's entry added. The tic built here compiles it: on the phone, and
  # in a host test, it runs where it was built.
  local full=share/terminfo.full
  mv share/terminfo "$full"
  local entries="a/ansi d/dumb l/linux s/screen s/screen-256color t/tmux t/tmux-256color
                 v/vt100 v/vt102 v/vt220 x/xterm x/xterm-256color x/xterm-color x/xterm-direct"
  for entry in $entries; do
    mkdir -p "share/terminfo/${entry%%/*}"
    cp "$full/$entry" "share/terminfo/$entry"
  done
  rm -rf "$full"
  ./bin/tic -x -o share/terminfo "$ROOT/terminfo/sqterm.ti"
  [ -f share/terminfo/s/sqterm ] || { echo "tic did not write sqterm's entry" >&2; return 1; }
  # Its licence travels with it.
  mkdir -p share/licenses/ncurses
  cp "$src/COPYING" share/licenses/ncurses/COPYING
}
