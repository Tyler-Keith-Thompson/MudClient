-- Specs for _persist.lua — the crash-safe persistence used by every save site (the map, voices, equipment,
-- class costs, …). These lock the guarantees that exist because a non-atomic write once truncated
-- explored.lua and cost a 2500+ room map: atomic writes, a shrink-proof `.bak`, and self-healing reads.

local persist = __persist or dofile("Scripts/Foundation/_persist.lua")

-- Scratch paths under TMPDIR so specs never touch the real ~/Documents files.
local seq = 0
local function tmp() seq = seq + 1
  return (os.getenv("TMPDIR") or "/tmp") .. "/mudclient_persist_" .. tostring(os.time()) .. "_" .. seq end
local function write_raw(p, s) local f = io.open(p, "w"); f:write(s); f:close() end
local function read_raw(p) local f = io.open(p, "r"); if not f then return nil end
  local d = f:read("a"); f:close(); return d end
local function count_ids(s) local n = 0; for _ in (s or ""):gmatch("%[%d+%]=") do n = n + 1 end; return n end
local function cleanup(p) for _, suf in ipairs({ "", ".tmp", ".bak", ".corrupt" }) do os.remove(p .. suf) end end

test("persist: save -> load round-trips a table", function()
  local p = tmp(); cleanup(p)
  persist.save(p, { a = 1, b = "two", nested = { x = true } })
  local t = persist.load(p)
  expect(t.a):eq(1)
  expect(t.b):eq("two")
  expect(t.nested.x):truthy()
  cleanup(p)
end)

test("persist: write is atomic — no .tmp orphan and the file parses", function()
  local p = tmp(); cleanup(p)
  persist.save(p, { only = 1 })
  expect(read_raw(p .. ".tmp")):falsy()          -- temp sibling renamed away, never orphaned
  expect(loadfile(p) ~= nil):truthy()            -- primary is valid Lua
  cleanup(p)
end)

test("persist: .bak is shrink-proof — a tiny save never shrinks the backup below the largest map", function()
  local p = tmp(); cleanup(p)
  local big = {}; for i = 1, 40 do big[i] = { name = "R" .. i } end
  persist.save(p, big)                            -- first save: no prior file, so no .bak yet
  persist.save(p, big)                            -- second save: snapshots the big prior file into .bak
  persist.save(p, { [1] = { name = "tiny" } })    -- catastrophic shrink
  expect(count_ids(read_raw(p)) < 5):truthy()     -- primary is the tiny map
  expect(count_ids(read_raw(p .. ".bak")) >= 40):truthy()  -- but .bak still holds the big one
  cleanup(p)
end)

test("persist: load self-heals from .bak when the primary is corrupt (and preserves the corrupt file)", function()
  local p = tmp(); cleanup(p)
  persist.save(p, { [1] = { name = "good" }, [2] = { name = "also" } })
  persist.save(p, { [1] = { name = "good" }, [2] = { name = "also" } })  -- ensure .bak exists
  write_raw(p, "return { this is not ][ valid")   -- corrupt the primary
  local t = persist.load(p)
  expect(t):truthy()                              -- recovered, not nil
  expect(t[1].name):eq("good")
  expect(read_raw(p .. ".corrupt") ~= nil):truthy()  -- corrupt primary kept aside, not discarded
  cleanup(p)
end)

test("persist: load recovers from .bak when the primary is missing entirely", function()
  local p = tmp(); cleanup(p)
  write_raw(p .. ".bak", persist.serialize({ [7] = { name = "frombak" } }))
  local t = persist.load(p)
  expect(t[7].name):eq("frombak")
  expect(read_raw(p) ~= nil):truthy()             -- primary restored from the backup
  cleanup(p)
end)

test("persist: load returns nil when there is genuinely nothing (no file, no backup)", function()
  local p = tmp(); cleanup(p)
  expect(persist.load(p)):falsy()
  cleanup(p)
end)
