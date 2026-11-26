# Third-party software in sqterm

## JetBrains Mono

`sq_android/assets/fonts/JetBrainsMonoNL-Regular.ttf` and
`JetBrainsMonoNL-Bold.ttf`: JetBrains Mono 2.304, the NL family (no
ligatures). Copyright 2020 The JetBrains Mono Project Authors
(https://github.com/JetBrains/JetBrainsMono). Licensed under the SIL Open
Font License 1.1: `sq_android/assets/fonts/OFL.txt`, bundled beside them.

## FreeType

sqterm draws its glyphs with FreeType 2.15.0, compiled into the app from
squared (`squared/third_party/freetype/`).

Portions of this software are copyright © The FreeType Project
(https://freetype.org). All rights reserved.

Licensed under the FreeType Project License:
`squared/third_party/freetype/FTL.TXT`.

## Zstandard

`squared/third_party/zstd/`: zstd 1.5.7, squared's one copy (the library
`squared.zstd`, which the app and pkg use), as its
`build/single_file_libs/create_single_file_library.sh` amalgamates it
(`zstd.c`), with its headers. Copyright (c) Meta Platforms, Inc. and
affiliates. Licensed under the BSD licence: `squared/third_party/zstd/LICENSE`
(zstd is dual-licensed; this takes the BSD one).

## The prefix's packages

The packages `sqmake packages` builds (`packages/`), which the APK carries and
unpacks into sqterm's prefix, are other projects' software: ncurses (an
X11-style licence) and zsh (its own permissive licence). Each package carries
its licence, installed under `$PREFIX/share/licenses/<name>/`. The recipes
make a few changes for Android after the ones Termux's packages make
(termux-packages, Apache License 2.0), written again for these recipes, not
copied.
