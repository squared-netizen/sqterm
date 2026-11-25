-- tools/cartridge/build.lua: sqterm-pack (pack.cpp), for this machine, with
-- sqcart's library (third_party/sqcart, vendored: tools/vendor_sqcart.sh).
-- Offline. Run from the repository's root, as tools/pack_cartridges.sh does:
--
--   sqmake -C . -f tools/cartridge/build.lua
--
-- The compiler is $CXX (and $CC): clang and libc++ 23 with `import std;`.
-- The build goes in $SQ_OUT (default build/packages/cartridge-tool).

toolchain.build = os.getenv("SQ_OUT") or "build/packages/cartridge-tool"
toolchain.cxxflags = {"-std=c++23", "-stdlib=libc++", "-O2"}
toolchain.cflags = {"-O2"}
toolchain.ldflags = {"-stdlib=libc++", "-lpthread"}

sqcart_settings = {root = "third_party/sqcart/v3"}
local cart = include("third_party/sqcart/v3/build.lua")

exe{name = "sqterm-pack", srcs = {"tools/cartridge/pack.cpp"}, deps = {cart.write},
    flags = {"-Wall", "-Wextra", "-Wno-missing-designated-field-initializers"}}
