#ifndef CLUA_SHIM_H
#define CLUA_SHIM_H

#include "lua.h"

/* Lua exposes a handful of its C API as function-like macros, which Swift's
   Clang importer cannot see. We only need the two that involve macro arithmetic
   over LUAI_MAXSTACK; everything else in the Lua API is a real exported function
   that Swift can call directly. */

static inline int clua_registryindex(void) { return LUA_REGISTRYINDEX; }
static inline int clua_upvalueindex(int i)  { return lua_upvalueindex(i); }

#endif /* CLUA_SHIM_H */
