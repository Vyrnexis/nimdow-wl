## Compiler and linker flags of the C libraries the bindings in this directory
## wrap, taken from pkg-config at compile time.

template pkgConfig*(pkgs: static string) =
  {.passC: gorge("pkg-config --cflags " & pkgs).}
  {.passL: gorge("pkg-config --libs " & pkgs).}
