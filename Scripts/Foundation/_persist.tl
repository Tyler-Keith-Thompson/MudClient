-- _persist.tl — durable, crash-safe persistence for the small Lua tables the scripts cache under
-- ~/Documents/MudClient (the explored map, learned TTS voices, identified equipment, class costs, autofight
-- winners, regen/trivia caches, …). It replaces the ad-hoc `io.open(path,"w")` + `loadfile` that every
-- save site used to hand-roll — one of which once truncated explored.lua mid-write and cost a 2500+ room
-- map. Guarantees, for every file that goes through here:
--
--   * ATOMIC writes — content is written to `path.tmp` and os.rename()d over `path`, so a crash, quit, or
--     hot-reload mid-write leaves the temp file, NEVER a truncated/empty primary.
--   * SHRINK-PROOF backup — before each replace, the current good file is snapshotted into `path.bak`, but
--     only when it's at least as large as the existing `.bak`; so `.bak` always holds the LARGEST good
--     version and a truncated/shrunken save can't erase it. (Stateless — derived from on-disk sizes, so it
--     survives reloads and relaunches.)
--   * SELF-HEALING reads — if `path` is missing, empty, or corrupt, load() transparently recovers from
--     `path.bak` (restoring the primary from it) and returns that; a corrupt primary is moved aside to
--     `path.corrupt` first so it is never silently discarded.
--
-- Format is a plain `return { ... }` Lua literal, identical to what the old per-site serializers emitted,
-- so existing files (and their .bak siblings) load unchanged.
--
-- Consumers pull it in with:  pcall(require, "_persist"); if not __persist then dofile("Scripts/Foundation/_persist.lua") end
-- (a `_`-prefixed shared lib, so directory-loading never auto-runs it; it exposes the global __persist as
-- well as returning the module, matching _rx / _dsl.)

local M = {}

-- Compact Lua-literal serializer (numbers / booleans / strings / tables). Shared so the on-disk format is
-- identical at every call site and always round-trips through load().
local function ser(v: any): string
  local t = type(v)
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "string" then return string.format("%q", v as string) end
  if t == "table" then
    local parts: {string} = {}
    for k, val in pairs(v as {any:any}) do
      local key: string
      if k is number then key = "[" .. k .. "]" else key = "[" .. string.format("%q", k as string) .. "]" end
      parts[#parts + 1] = key .. "=" .. ser(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end
function M.serialize(v: any): string return "return " .. ser(v) end

local function slurp(path: string): string
  local f = io.open(path, "r"); if not f then return nil end
  local d = f:read("a"); f:close(); return d
end
local function spit(path: string, data: string): boolean
  local f = io.open(path, "w"); if not f then return false end
  f:write(data); f:close(); return true
end
local function fsize(path: string): integer local d = slurp(path); return d and #d or 0 end

-- Parse a serialized file. Returns (value) on success, or (nil, reason) where reason is "empty" (missing or
-- all-whitespace — nothing to recover) or "corrupt" (has content but won't load/eval — recover from .bak).
local function parse(path: string): any, string
  local raw = slurp(path)
  if not raw or raw:match("%S") == nil then return nil, "empty" end
  local chunk = loadfile(path); if not chunk then return nil, "corrupt" end
  local ok, v = pcall(chunk); if not ok then return nil, "corrupt" end
  return v
end

-- persist.write(path, body): atomically replace `path` with the pre-serialized string `body`
-- ("return {...}"), keeping a shrink-proof `.bak`. Use this when a caller builds its own literal; use
-- persist.save() when you just have a table. Returns true on success.
function M.write(path: string, body: string): boolean
  if not spit(path .. ".tmp", body) then return false end
  -- Snapshot the shrink-proof .bak. Read the current primary ONCE (not 3×: the old code slurped `path`
  -- for its size, slurped `.bak` for ITS size, then slurped `path` AGAIN to copy — three full reads of a
  -- multi-hundred-KB file per save, all under the Lua lock). We only need the primary's bytes + the .bak
  -- size, so: one read of the primary, one size of .bak.
  local data = slurp(path)
  local cur = data and #data or 0
  if cur > 0 and cur >= fsize(path .. ".bak") then spit(path .. ".bak", data) end
  return os.rename(path .. ".tmp", path) and true or false
end

-- persist.save(path, tbl): serialize `tbl` and write it atomically (see M.write).
function M.save(path: string, tbl: any): boolean return M.write(path, M.serialize(tbl)) end

-- persist.load(path[, notify]): return the stored value, or nil if there is genuinely nothing to load.
-- Self-healing: a missing/empty/corrupt primary is recovered from `path.bak` (which is also restored back
-- into `path`); a corrupt primary is preserved as `path.corrupt` first. `notify` (optional) is called with
-- a one-line message on recovery/corruption so callers can surface it (echo).
function M.load(path: string, notify: function(string)): any
  local v, why = parse(path)
  if v ~= nil then return v end
  if why == "corrupt" then
    os.rename(path, path .. ".corrupt")
    if notify then notify("[persist] " .. path .. " was corrupt — moved aside to .corrupt") end
  end
  local b = parse(path .. ".bak")
  if b ~= nil then
    local data = slurp(path .. ".bak"); if data then spit(path, data) end   -- restore the primary from backup
    if notify then notify("[persist] recovered " .. path .. " from backup") end
    return b
  end
  return nil
end

-- Docs (persist is a public script module; keep it discoverable via #help).
if doc then
  doc(M.save,  { name = "persist.save",  sig = "persist.save(path, tbl) -> ok", group = "persistence",
    text = "Serialize `tbl` to `return {...}` and write it to `path` atomically, keeping a shrink-proof `path.bak`." })
  doc(M.load,  { name = "persist.load",  sig = "persist.load(path[, notify]) -> value|nil", group = "persistence",
    text = "Load a value saved by persist.save/write. Self-heals from `path.bak` if the primary is missing/empty/corrupt (a corrupt primary is preserved as `path.corrupt`). `notify(msg)` is called on recovery." })
  doc(M.write, { name = "persist.write", sig = "persist.write(path, body) -> ok", group = "persistence",
    text = "Like persist.save but takes a pre-serialized `return {...}` string, for callers that build their own literal." })
end

-- persist.load's optional NOTIFY callback (second arg) isn't part of foundation.d.tl's declared Persist.load
-- (function(string): any) — same widening cast AIPilot.tl uses at its call sites — so the extra arg doesn't
-- reject at this boundary while callers can still pass notify through `persist.load as function(string,
-- function(string)): any`.
__persist = M as Persist
return M
