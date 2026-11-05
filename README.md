# sqterm

A terminal for Android, written as a [squared](https://github.com/squared-netizen/squared)
app: a shell in a pseudo-terminal, drawn by squared, with no Java of its own.
Inspired by Termux. Side-loaded (target SDK 28, minimum 22), never on Google
Play.

Where it stands (Sprint 12 of the squared plan):

- 12.3d, this: the first APK. Android's own shell (`/system/bin/sh`) in a
  pty on the model's thread, its screen drawn with JetBrains Mono from one
  glyph texture, typing (a keyboard's Ctrl, Alt, arrows, F-keys, Page Up and
  Down), a drag to scroll back, rotation. When the shell exits it says so as
  Termux does (`[Process completed (code 0) - press Enter]`), and Enter
  closes sqterm.
- 12.4, copy and paste, as Termux does: a long press selects the word under
  the finger and a drag that follows moves its end; two handles move either
  end, and dragged to the top or bottom edge they scroll, so a selection
  runs through the whole scrollback; a bar above it has Copy and Paste; a
  long press on blank space shows Paste alone; a tap elsewhere or a key puts
  it away. A paste goes in as Termux sends one (escapes out, newlines as
  Enter, bracketed when the program asks).
- 12.6, running in the background, as Termux does: while the shell runs, a
  notification ("1 session") keeps sqterm's process alive off the screen;
  tapped, it opens sqterm; Exit ends the shell and closes sqterm; Acquire
  wakelock keeps it running with the screen off. A swipe from the recent
  apps leaves the shell running.
- 12.6b, pinch zoom, as Termux does: two fingers scale the font, from 50%
  to 300% in steps of 5, and the grid follows; the size is kept for the next
  launch. (Every squared app zooms its whole UI with a pinch; the terminal
  takes the pinch for its font instead.)
- Next: 12.5 the prefix and `pkg` (zsh, the clang stack, neovim, bundled in
  the APK and installed from it), 12.7 Android from the shell.

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
