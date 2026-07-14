// Minimal standalone Lua 5.4 host for the script test suite. Compiled against the vendored
// Sources/CLua by tools/luatest/run.sh — it just opens the standard libraries and runs the Lua file
// named on the command line (tools/luatest/driver.lua), reporting any load/runtime error.
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include <stdio.h>

/* Vendored lua-protobuf (Sources/CLua/pb.c), not declared in lualib.h. */
LUALIB_API int luaopen_pb(lua_State *L);

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s script.lua\n", argv[0]); return 2; }
  lua_State *L = luaL_newstate();
  luaL_openlibs(L);
  luaL_requiref(L, "pb", luaopen_pb, 1);
  lua_pop(L, 1);
  if (luaL_dofile(L, argv[1])) {
    fprintf(stderr, "LUA ERROR: %s\n", lua_tostring(L, -1));
    lua_close(L);
    return 1;
  }
  lua_close(L);
  return 0;
}
