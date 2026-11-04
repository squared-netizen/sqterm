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
```

- **Shell** (the model) watches the pty's descriptor (`Telegraph::watch`):
  it sleeps until the shell writes, a key comes, or Android's lifecycle
  reaches it. What the shell writes is fed to a `sq::term::Terminal`, and
  the screen is published whole (`sq::term::ScreenPublisher`). When the
  shell exits, the terminal says `[exited N]` and a new one starts; one that
  ended within two seconds of starting waits for a key.
- **TerminalView** (a custom node, `Stage::custom`) reads the newest screen
  each frame, puts the glyphs it shows into the atlas, and paints:
  backgrounds, then glyphs, then underlines. Named keys go through
  `sq::term::key_bytes`, Ctrl and Alt with a character through
  `key_text_bytes`, typed text as it is. A vertical drag scrolls back.
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
