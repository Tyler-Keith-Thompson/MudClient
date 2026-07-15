-- Teal config. `.tl` scripts are the typed source of truth; `tl gen` emits the plain `.lua` the client
-- actually loads (the loader/searcher is unchanged — it still sees `Scripts/*.lua`). This is the
-- "support both" seam: typed and hand-written Lua coexist file-by-file during migration.
--
--   ./tools/teal/tl check Scripts/_dsl.tl      -- type-check against mud.d.tl (no output)
--   ./tools/teal/tl gen   Scripts/_dsl.tl      -- emit Scripts/_dsl.lua next to it
--
-- global_env_def names the declaration module (Scripts/mud.d.tl) that types every host builtin +
-- the _rx/Promise/persist surface, so scripts are checked against the real host API.
return {
   global_env_def = "Scripts/mud",
   include_dir = { "Scripts" },
   gen_target = "5.4",     -- match the embedded interpreter (Lua 5.4.7)
   gen_compat = "off",     -- no compat shim; we run on exactly one Lua
}
