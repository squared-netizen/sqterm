# sqterm

A terminal for Android, written as a [squared](https://github.com/squared-netizen/squared)
app: a shell in a pseudo-terminal, drawn by squared, with no Java of its own.
Inspired by Termux. Side-loaded (target SDK 28, minimum 22), never on Google
Play.

Where it stands (Sprint 12 of the squared plan):

- 12.3d, this: the first APK. Android's own shell (`/system/bin/sh`) in a
  pty on the model's thread, its screen drawn with JetBrains Mono from one
  glyph texture, typing (a keyboard's Ctrl, Alt, arrows, F-keys, Page Up and
  Down), a drag to scroll back, rotation. When the shell exits it says so and
  starts again.
- Next: 12.4 input (paste, selection), 12.5 the prefix and `pkg` (zsh, the
  clang stack, neovim, bundled in the APK and installed from it), 12.6
  running in the background, 12.7 Android from the shell.

## Build and install

On the phone, in Termux, from this folder:

```sh
make dev      # a debug build with the Console, installed
make apk      # a plain APK in build/
```

The Makefile's head lists every target.

## Layout

```
sq_app/src/         the app (yours): main.cpp, shell.cpp (the model),
                    terminal_view.cpp (the widget), glyphs.cpp (the fonts)
sq_android/         the platform layer, from the template; assets/fonts/
terminfo/sqterm.ti  TERM=sqterm: what the emulator implements (12.5 installs it)
squared/            the framework, vendored: never edited here
mk/                 the template's and the package's make fragments
tools/              vendor_framework.sh: squared from the package
```

## The framework

`squared/` is the package's, copied at the commit in `SQUARED_REV`. To take
the package's latest:

```sh
tools/vendor_framework.sh --latest
```

then commit `squared/`, `SQUARED_REV` and `mk/`.

## Licences

See [NOTICE.md](NOTICE.md): JetBrains Mono (SIL Open Font License 1.1) and
FreeType (the FreeType Project License) ship in the APK.
