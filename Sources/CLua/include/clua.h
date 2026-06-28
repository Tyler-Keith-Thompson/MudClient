#ifndef CLUA_UMBRELLA_H
#define CLUA_UMBRELLA_H

/* Umbrella for the embedded Lua 5.4 C library, surfaced to Swift as `import CLua`.
   Only the public API headers are exposed; the internal Lua headers (lstate.h,
   lobject.h, …) live alongside these but are not part of the module. */
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "clua_shim.h"

#endif /* CLUA_UMBRELLA_H */
