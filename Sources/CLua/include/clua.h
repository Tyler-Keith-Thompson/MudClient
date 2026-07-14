#ifndef CLUA_UMBRELLA_H
#define CLUA_UMBRELLA_H

/* Umbrella for the embedded Lua 5.4 C library, surfaced to Swift as `import CLua`.
   Only the public API headers are exposed; the internal Lua headers (lstate.h,
   lobject.h, …) live alongside these but are not part of the module. */
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "clua_shim.h"

/* Vendored lua-protobuf (starwing/lua-protobuf, pinned at 0.5.2, see ../pb.c/pb.h).
   Not part of stock Lua, so it's not declared in lualib.h; surfaced here so Swift
   can register it with luaL_requiref the same way it opens the standard libs. */
LUALIB_API int luaopen_pb(lua_State *L);

#endif /* CLUA_UMBRELLA_H */
