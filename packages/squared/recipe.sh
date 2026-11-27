# squared: the squared framework's sources, MIT, installed for every
# workspace on the device to build with: $PREFIX/share/squared/VERSION/squared,
# beside the squared/ folder a template's build includes it from
# (sq/build/template.lua: app.squared names a version, the newest by
# default). Several versions can be installed side by side.
#
# What sqterm carries (squared/, SQUARED_REV), as tools/vendor_framework.sh
# took it from squared's package.squared-core: sources only, no build
# output. A workspace that changes squared itself keeps a squared/ of its
# own instead, and this is not used for it.
#
# The version is package.squared-core's (its SQ-INF/manifest.json), and
# SQUARED_REV says which commit, in share/squared/VERSION/REV.

version=1.3.0
license=MIT
file=
top=
depends=""
# 1.9 MB packed: from the repo (pkg install squared), not in the APK.
bundled=no
# squared changes only by tools/vendor_framework.sh, which writes SQUARED_REV.
inputs="SQUARED_REV"
keep="share/squared share/licenses/squared"

recipe_build() {
  local into=$dest$SQ_PREFIX/share/squared/$version
  mkdir -p "$into"
  cp -R "$ROOT/squared" "$into/squared"
  # Sources only: every folder under squared/build/ is a build's output
  # (squared's build settings, the files directly in it, stay).
  find "$into/squared/build" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
  cp "$ROOT/SQUARED_REV" "$into/REV"
}

recipe_after() {
  local to=share/licenses/squared
  mkdir -p "$to"
  # squared's (sqterm's LICENSE is the same text); its third-party code's
  # licences are in the tree, beside each.
  cp "$ROOT/LICENSE" "$to/LICENSE"
}
