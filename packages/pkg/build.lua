-- packages/pkg/build.lua: pkg (sq_app/pkg/pkg.cpp), for sqmake, from the
-- repository's root: packages/pkg/recipe.sh runs it (packages/sqmake.sh's
-- sq_android_build, which names the build folder, std.cppm and the
-- compilers). It reads cartridges through sq.cart's reader (third_party/
-- sqcart, vendored: tools/vendor_sqcart.sh), whose libraries carry yyjson
-- and zstd's decoder: pkg links them from there, once.

toolchain.cxxflags = {"-std=c++23", "-stdlib=libc++", "-O2"}
toolchain.cflags = {"-O2"}
toolchain.ldflags = {"-stdlib=libc++", "-lpthread"}

sqcart_settings = {root = "third_party/sqcart/v3"}
local cart = include("third_party/sqcart/v3/build.lua")

local version = os.getenv("SQTERM_PKG_VERSION") or "0"
exe{name = "pkg", deps = {cart.read},
    srcs = {"sq_app/pkg/pkg.cpp", "sq_app/src/unpack.cpp", "sq_app/src/unpack_cartridge.cpp"},
    flags = {"-Wall", "-Wextra", "-Isq_app/src", "-Isq_app/third_party/zstd", "-Isquared/third_party/yyjson",
             "-DSQTERM_PKG_VERSION=\"" .. version .. "\""}}
