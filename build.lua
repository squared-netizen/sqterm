-- build.lua: sqterm's build, for sqmake (there is no Makefile).
--
--   sqmake                 build/sqterm.apk, signed with ~/.android/apkpack.pem
--   sqmake install         onto the phone (tools/device.sh); run, logcat,
--                          devices, uninstall too, from squared's Android
--                          platform (squared/build/android.lua)
--   sqmake --debug VERB    the debug build (-O0 -g, debuggable)
--   sqmake packages        the prefix's packages (packages/build.sh) into
--                          sq_android/assets/packages/: offline, the sources
--                          from tools/fetch_packages.sh --sources; or
--                          tools/fetch_packages.sh puts CI's there instead
--
-- sq/build/template.lua (template.android.cpp's, squared's to update) says
-- every setting.
app = {
  name = "sqterm",
  package = "dev.squared.sqterm",
  background = true,
  -- pkg's, built by packages/pkg/recipe.sh with sqcart's reader; the app
  -- does not call it.
  exclude = {"sq_app/src/unpack_cartridge.cpp"},
  -- zstd, for the packages (12.5): squared's (squared.zstd, which sq.data
  -- links), the one copy the app has.
  flags = {"-Isquared/third_party/zstd"},
  -- The Settings screen (sq_app/src/settings.cpp).
  libraries = {"settings"},
}
local built = include("sq/build/template.lua")

-- Run when asked, not by every build (a first one takes several minutes).
action{name = "packages", desc = "the packages (packages/build.sh)", cmd = {"bash", "packages/build.sh"}}

return built
