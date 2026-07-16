-- env.d.tl — the declaration aggregator (tlconfig.lua points `global_env_def` here). Teal's
-- `global_env_def` is a single string, but a declaration file that `require`s another propagates the
-- other's globals — so this is just the load order: foundation (game-agnostic) first, then alteraeon
-- (game-specific, may reference foundation's global types).
require("foundation")
require("alteraeon")
