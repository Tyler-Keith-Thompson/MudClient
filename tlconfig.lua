-- Teal config. `.tl` scripts are the typed source of truth; `tl gen` emits the plain `.lua` the client
-- loads. `global_env_def` = Scripts/Foundation/env.d.tl (which requires foundation.d.tl then alteraeon.d.tl),
-- so every script is type-checked against the real host + infra surface.
return {
   global_env_def = "Scripts/Foundation/env",
   include_dir = { "Scripts", "Scripts/Foundation", "Scripts/AlterAeon" },
   gen_target = "5.4",     -- match the embedded interpreter (Lua 5.4.7)
   gen_compat = "off",     -- no compat shim; we run on exactly one Lua
}
