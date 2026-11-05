# zsh: sqterm's shell (12.5, decided 2026-11-02: fish is Rust since 4.0).
#
# Static: every module linked into the one binary (no dlopen, nothing else to
# load), the line editor drawing through ncurses (linked in). Its paths are
# the prefix's: functions under share/zsh, the system startup files in etc/,
# temporary files (here-documents) in the prefix's tmp/. A few places assume
# a Unix /bin and /tmp that Android has not: they are changed here, after the
# changes Termux's package makes (termux-packages, packages/zsh), written
# again for this recipe.
#
# The package: the shell, its functions (the completion functions of other
# systems left out), and etc/zshrc, sqterm's starting point for an
# interactive shell (packages/zsh/zshrc), read before the user's ~/.zshrc.

version=5.9.2
file=zsh-$version.tar.xz
url=https://www.zsh.org/pub/$file
mirrors="https://downloads.sourceforge.net/project/zsh/zsh/$version/$file"
# From the release's announcement (zsh.org/mla/announce/msg00136.html).
sha256=36fa734374b44783582cec09bcd67822e2f992c779ec1624ab5596df078d2f81
top=zsh-$version
depends=ncurses
keep="bin/zsh bin/zsh-$version share/zsh etc/zshrc share/licenses/zsh"

recipe_patch() {
  # Here-documents and the like: /tmp/zsh* by default; Android has no /tmp
  # an app can write.
  sed -i "s|\"/tmp/zsh\"|\"$SQ_PREFIX/tmp/zsh\"|" config.h.in
  grep -q "$SQ_PREFIX/tmp/zsh" config.h.in
  # A script with no #! line runs under /bin/sh, which Android does not have.
  sed -i 's|execve("/bin/sh", |execve("/system/bin/sh", |' Src/exec.c
  grep -q 'execve("/system/bin/sh", ' Src/exec.c
  # Setting the line discipline is refused to an app; each try costs a call.
  sed -i 's|^#if defined(TIOCSETD) && defined(NTTYDISC)$|#if defined(TIOCSETD) \&\& defined(NTTYDISC) \&\& !defined(__ANDROID__)|' Src/init.c
}

recipe_build() {
  # The cache values are what configure cannot test when it cannot run what
  # it builds (a build for Android elsewhere than on Android): bionic's.
  # utmp and wtmp are not kept on Android; setresuid is refused to an app.
  ./configure ${SQ_HOST_TRIPLE:+--host=$SQ_HOST_TRIPLE --build=$(sh ./config.guess)} \
    --prefix="$SQ_PREFIX" \
    --disable-dynamic --disable-gdbm --disable-pcre --disable-cap \
    --enable-multibyte \
    --enable-etcdir="$SQ_PREFIX/etc" \
    --enable-function-subdirs --enable-site-fndir=no \
    --enable-fndir="$SQ_PREFIX/share/zsh/functions" \
    --enable-scriptdir="$SQ_PREFIX/share/zsh/scripts" \
    --with-term-lib=ncursesw \
    zsh_cv_path_wtmp=no ac_cv_header_utmp_h=no \
    ac_cv_func_getpwuid=yes ac_cv_func_setresgid=no ac_cv_func_setresuid=no \
    zsh_cv_printf_has_lld=yes zsh_cv_rlim_t_is_longer=no zsh_cv_type_rlim_t_is_unsigned=yes
  # With no dynamic loading, only the shell's core modules are linked in;
  # these are the others a user's .zshrc and its plugins reach for.
  local module
  for module in deltochar files mapfile mathfunc param_private regex stat system \
                watch zprof zpty zselect; do
    sed -i "s|^\(name=[^ ]* modfile=[^ ]*/$module\.mdd link=\)no|\1static|" config.modules
  done
  # Other systems' completions (their package managers, their commands).
  local system
  for system in AIX BSD Cygwin Darwin Debian Mandriva openSUSE Redhat Solaris; do
    rm -rf "Completion/$system"
    sed -i "s#[[:space:]]*Completion/$system/\*/\*##g" Src/Zle/complete.mdd
  done
  make -j"$JOBS"
  make install.bin install.modules install.fns DESTDIR="$dest"
}

recipe_after() {
  # A hard link Android may refuse to make: a symbolic one.
  rm -f "bin/zsh-$version"
  ln -s zsh "bin/zsh-$version"
  mkdir -p etc share/licenses/zsh
  cp "$ROOT/packages/zsh/zshrc" etc/zshrc
  # Its licence travels with it.
  cp "$src/LICENCE" share/licenses/zsh/LICENCE
}
