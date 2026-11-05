# sq_app: sqterm's code

Everything here is sqterm's; the generator does not write here again. No
layouts and no names.json: one screen, written in C++, holding one custom
widget, and the addresses written by hand (`src/sqterm.hpp`).

```text
src/sqterm.hpp         what the files share: the addresses, Shell, Glyphs, TerminalView
src/main.cpp           squared_main: the model, the widget, the screen
src/shell.cpp          the model: the shell in a pty, on the model's thread
src/terminal_view.cpp  the widget: the screen drawn, keys sent
src/glyphs.cpp         the fonts, mapped from the APK; the glyph atlas and its texture
src/prefix.cpp         the prefix: the APK's packages copied out, unpacked (tar + zstd)
third_party/zstd/      zstd's decoder (one C file) and its headers
```

## How it fits together

```text
 UI thread                         Telegraph                 model thread
 TerminalView  -- do term.input  (keys, typed text) -->     Shell -> Pty -> sh
               -- do term.size   (columns, rows)    -->       |  (watched: wakes
               -- do term.scroll (lines back)       -->       |   when sh writes)
               <-- snapshot term.screen (the whole screen) -- Terminal + ScreenPublisher
               <-- state term.completed (the shell ended) --
               -- do term.copy   (two places)       -->       Terminal::copy_text
               <-- snapshot term.copied (the text, for the clipboard) --
```

- **Shell** (the model) watches the pty's descriptor (`Telegraph::watch`):
  it sleeps until the shell writes, a key comes, or Android's lifecycle
  reaches it. What the shell writes is fed to a `sq::term::Terminal`, and
  the screen is published whole (`sq::term::ScreenPublisher`). When the
  shell exits, the terminal says so as Termux does (`[Process completed
  (code N) - press Enter]`, or `(signal N)`), sets the state
  `term.completed`, and drops what is typed after.
- **TerminalView** (a custom node, `Stage::custom`) reads the newest screen
  each frame, puts the glyphs it shows into the atlas, and paints:
  backgrounds, then glyphs, then underlines. Named keys go through
  `sq::term::key_bytes`, Ctrl and Alt with a character through
  `key_text_bytes`, typed text as it is. A vertical drag scrolls back. Once
  `term.completed` is true, Enter calls `quit_app()` (the App kept by
  `squared_main`): the model stops, Android closes the activity, and the
  next launch starts a new shell.
- **Selecting** (12.4, in TerminalView): a long press (0.45 s, within 10
  units) selects the word under the finger, and the finger still down moves
  its end; on blank space it shows the bar with Paste alone. The ends are
  `sq::term::TextPoint`s, the terminal's line numbers (the snapshot's
  `top_line` plus the row), so they stay on their text as more scrolls in.
  Two handles hang below the ends; a finger within 40 units takes one, and
  held at the top or bottom edge it scrolls a line each 60 ms. The bar
  (Copy, Paste) sits above the selection's first line, or below it at the
  top. Copy sends `do term.copy` ("from_line from_column to_line
  to_column"); the Shell answers with `Terminal::copy_text` in the snapshot
  `term.copied`, and the widget gives it to `stage.clipboard()`. Paste reads
  the clipboard whole, makes it `sq::term::paste_text`, and sends it as
  `term.input` in pieces of 1 KB as the rings take them, a frame at a time
  (the paste's buffer, about twice its size, is freed when it is sent).
  A tap elsewhere, or a key, puts the selection away.
- **Pinch zoom** (12.6b, in TerminalView): squared's Stage offers a
  two-finger pinch to the widget under it before it zooms the UI, and the
  terminal takes it (`TerminalView::pinch`): the font's size, in percent of
  20 units, is the size at the pinch's start times its scale, to a step of 5
  from 50 to 300. Each step makes the glyphs again at the new pixel size
  (the atlas cleared, the texture uploaded whole) and sends the new grid as
  `term.size`; between steps nothing happens. The size is the process's (a
  rotation makes the widget again), read from the app's files
  (`terminal.font`, the percent and a newline) at the first fit and written
  as the fingers lift.
- **The prefix** (12.5, `prefix.cpp`): `squared_main` makes `files/home`
  and `files/usr/tmp`, and calls `stage_packages`: the APK's
  `assets/packages/index` against `usr/var/lib/sqterm/packages`, the one
  last installed. When they differ, each archive is copied out of the APK
  (mapped: they are stored uncompressed) into `usr/var/cache/sqterm/`, so
  the model's thread reads plain files whatever happens to the activity. The
  Shell's `start` unpacks them into `files/usr` before the shell (the
  terminal says `[sqterm: unpacking zsh 5.9.2]` for each), removes the
  copies, and records the index. The reader takes ustar (files, directories,
  symbolic links, hard links as copies, the 155-byte prefix field), unlinks
  before it writes (a running program cannot be written over), and refuses a
  name or a link with `..` or a leading `/`. Then the shell is the prefix's
  zsh, as a login shell (`-l`), or Android's sh when there is none. Its
  environment: `TERM=sqterm`, `COLORTERM`, `LANG`, `HOME`, `TMPDIR`
  (`$PREFIX/tmp`, where zsh puts here-documents), `PREFIX`, `PATH`
  (`$PREFIX/bin` first, then `/system/bin`), `SHELL`, `SQTERM`, and
  Android's `ANDROID_DATA` and `ANDROID_ROOT`.
- **Running in the background** (12.6, `main.cpp`):
  `app.keep_running({.title = "sqterm", .text = "1 session"})` once the
  Shell runs, with `BACKGROUND=1` in the Makefile: squared's foreground
  service keeps the process (and the shell) alive with sqterm off the screen.
  Exit in the notification is a quit (the shell ends); a quit, Enter after
  the shell ended included, stops the service.
- **Glyphs** (one for the process): JetBrains Mono NL regular and bold,
  mapped from the APK (stored uncompressed), Android's fonts for what they
  lack; a 1024 x 1024 coverage atlas and its alpha texture, which takes only
  the rectangle that changed. The Stage's surface hook (`Stage::on_surface`)
  brings the texture back after Android takes the surface away.

## Memory

The model: the Terminal (two 80 x 24 grids to start, then the screen's
size, and a 1 MB scrollback), a 16 KB read buffer, the three snapshot buffers
(the screen, 12 bytes a cell).

The prefix, while it unpacks (the first start, and after an update with new
packages): zstd's decoder (about 100 KB) and its window (1 MB), 64 KB of
input and 128 KB of output, freed when it is done; the archives' copies on
disk until each is unpacked. Nothing after.

The UI: the atlas's 1 MB image and its 1 MB
texture on the GPU (the same at every font size: bigger glyphs fill it
sooner), FreeType's faces (about 100 KB each), the fonts' mapped
pages (clean, only what is read).
