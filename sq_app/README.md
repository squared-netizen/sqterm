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
- **Glyphs** (one for the process): JetBrains Mono NL regular and bold,
  mapped from the APK (stored uncompressed), Android's fonts for what they
  lack; a 1024 x 1024 coverage atlas and its alpha texture, which takes only
  the rectangle that changed. The Stage's surface hook (`Stage::on_surface`)
  brings the texture back after Android takes the surface away.

## Memory

The model: the Terminal (two 80 x 24 grids to start, then the screen's
size, and a 1 MB scrollback), a 16 KB read buffer, the three snapshot buffers
(the screen, 12 bytes a cell). The UI: the atlas's 1 MB image and its 1 MB
texture on the GPU, FreeType's faces (about 100 KB each), the fonts' mapped
pages (clean, only what is read).
