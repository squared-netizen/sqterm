# packages: sqterm's prefix

sqterm runs its programs from its own folder, `/data/data/dev.squared.sqterm/files/usr`
(`$PREFIX` in its shell), as Termux runs its own. What is in it comes from
packages built here, carried in the APK (`sq_android/assets/packages/`), and
unpacked by the app the first time it starts. Decided in Sprint 12 (the plan's
12.0 and 12.5): squared's own recipes, each tool's latest stable release, only
the tools in use, C, C++ or Lua only; built on the phone first, and on GitHub
Actions later with the same scripts.

```text
build.sh          downloads, checks, builds and packs every recipe, writes the index
sources.lock      sha256s of the sources that publish none, from their first download
ncurses/recipe.sh ncurses 6.6: the terminal database (sqterm's entry in it), tic, tput
zsh/recipe.sh     zsh 5.9.2: the shell, static, its modules linked in
zsh/zshrc         $PREFIX/etc/zshrc: keys, history, completion, a prompt
```

## Building

On the phone, in Termux, from sqterm's folder:

```sh
pkg install curl xz-utils zstd    # once
make packages                     # or: bash packages/build.sh [name...]
make dev                          # the APK, with them
```

The first `make packages` takes several minutes (ncurses, then zsh). It writes
`sq_android/assets/packages/<name>-<version>.tar.zst` and `index`, which are
not kept in git (the APK build packs them). Commit `packages/sources.lock`
when it changes: ncurses publishes a signature but no sha256, so its first
download is recorded there and later ones must match it.

`bash packages/build.sh --host-test` builds the same recipes for the machine
it runs on, into `build/packages/host/` (nothing goes into the APK): a check of
a recipe where there is no NDK.

## What a recipe is

`packages/<name>/recipe.sh`, sourced by `build.sh`:

| Variable or function | What |
|---|---|
| `version`, `file`, `url`, `mirrors` | the source, and where else to find it |
| `sha256` | the source's, as published; empty: `sources.lock` |
| `top` | the folder the source unpacks into |
| `depends` | recipes built first, whose headers and libraries it uses |
| `keep` | what the package carries, relative to the prefix |
| `recipe_patch` | in the source: changes for Android (paths) |
| `recipe_build` | configure, make, `make install DESTDIR="$dest"` |
| `recipe_after` | in what was installed: the last touches (links, files of ours) |

It is given `SQ_PREFIX` (the prefix), `SQ_HOST_TRIPLE` (`aarch64-linux-android`,
empty in a host test), `CC` and the flags (the NDK's sysroot for API 22,
`--hash-style=both` for Android 5, 16 KB pages), `JOBS`, `ROOT` (sqterm's
folder), `src` and `dest`.

## The packages

Each is a ustar archive compressed with zstd (a 1 MB window: what the app's
decoder holds while it unpacks), its files' paths relative to the prefix,
sorted and dated at the epoch, so two builds of the same source give the
same bytes. Executables are stripped. The index, `sqterm packages 1` and a
line a package (`name version file sha`), is what the app compares with the
one it last installed: when they differ, it unpacks them all again.

Not yet: removing what an older package had and a newer one does not (`pkg`,
later in 12.5); the recipes in GitHub Actions (there, configure cannot run
what it builds: the recipes give the answers it would have found, and the
terminfo entry needs a tic for the build machine).
