-- Specs for the Phase-2 #command -> Lua REPL migration: the game scripts must expose first-class,
-- documented Lua functions/tables instead of command() registrations, while the callable-table
-- forwarding keeps the legacy typed forms (`#eq scan` -> `eq("scan")`) working.
--
-- These run in the same Lua state as the live scripts (loaded by the harness/driver), so the migrated
-- globals (eq/pilot/kxwt/trivia tables, mark/waypoints/reset/travel/test/volume) and the doc registry
-- are all present. File-scanning specs read the sources from disk (CWD is the repo root, as with #load).

local GAME_FILES = {
  "Scripts/AlterAeon.lua", "Scripts/AIPilot.lua", "Scripts/HUD.lua",
  "Scripts/Trivia.lua", "Scripts/Equipment.lua",
}

-- Find a real `command(` CALL: comments stripped, and `command` not the tail of another identifier
-- (so `corpse_command(` / `run_test_suite` don't count). Returns the offending snippet, or nil.
local function find_command_call(src)
  for line in (src .. "\n"):gmatch("(.-)\n") do
    local code = line:gsub("%-%-.*$", "")          -- drop the line comment
    local i = 1
    while true do
      local s, e = code:find("command%s*%(", i)
      if not s then break end
      local prev = s > 1 and code:sub(s - 1, s - 1) or ""
      if not prev:match("[%w_]") then return line end   -- boundary-real command( call
      i = e + 1
    end
  end
  return nil
end

for _, path in ipairs(GAME_FILES) do
  test("no command() registrations remain in " .. path, function()
    local fh = io.open(path, "r")
    expect(fh ~= nil):truthy()
    local src = fh:read("*a"); fh:close()
    local hit = find_command_call(src)
    if hit then error("found a command() registration: " .. hit, 1) end
    expect(hit):eq(nil)
  end)
end

-- Sanity: the detector itself catches a real call but ignores `corpse_command(` and comments.
test("find_command_call flags a real call but not corpse_command( or comments", function()
  expect(find_command_call([[command("eq", function() end)]]) ~= nil):truthy()
  expect(find_command_call([[if corpse_command and corpse_command(v, r) then end]])):eq(nil)
  expect(find_command_call([[-- command("eq", fn) in a comment]])):eq(nil)
end)

-- ---- migrated tables: shape, docs, and __call forwarding ----

-- Each entry: the global table, its expected member names, and its doc group.
local TABLES = {
  { name = "eq",     tbl = eq,     members = { "scan", "quick", "compare", "id", "shop", "stats", "forget" }, group = "equipment" },
  { name = "pilot",  tbl = pilot,  members = { "on", "off", "once", "status", "goal", "tell", "reload", "remember" }, group = "pilot" },
  { name = "kxwt",   tbl = kxwt,   members = { "dump", "corpse" }, group = "protocol" },
  { name = "trivia", tbl = trivia, members = { "on", "off", "status", "stats", "forget" }, group = "trivia" },
}

for _, spec in ipairs(TABLES) do
  test(spec.name .. " is a callable table with documented members", function()
    expect(type(spec.tbl)):eq("table")
    local mt = getmetatable(spec.tbl)
    expect(mt ~= nil and type(mt.__call) == "function"):truthy()   -- callable for the legacy typed form
    for _, m in ipairs(spec.members) do
      expect(type(spec.tbl[m])):eq("function")                     -- member exists and is callable
      local d = __docs.by_fn[spec.tbl[m]]
      if not d then error(spec.name .. "." .. m .. " is not documented", 1) end
      expect(d.group):eq(spec.group)                               -- filed under the right help group
      expect(type(d.sig)):eq("string")
    end
  end)
end

-- Spy on a table member for the duration of fn, recording the last args it was called with.
local function with_spy(tbl, member, fn)
  local real = tbl[member]
  local calls = {}
  tbl[member] = function(...) calls[#calls + 1] = { ... } end
  local ok, err = pcall(fn, calls)
  tbl[member] = real
  if not ok then error(err, 2) end
  return calls
end

test("eq(...) forwards legacy subcommands to the right member", function()
  local c = with_spy(eq, "scan", function() eq("scan") end)
  expect(#c):eq(1)
  c = with_spy(eq, "id", function() eq("id a rusty sword") end)
  expect(#c):eq(1)
  expect(c[1][1]):eq("a rusty sword")
  c = with_spy(eq, "compare", function() eq("compare weapon") end)
  expect(c[1][1]):eq("weapon")
  c = with_spy(eq, "forget", function() eq("forget") end)
  expect(#c):eq(1)
end)

test("kxwt(...) forwards dump/corpse and a bare number to dump", function()
  local c = with_spy(kxwt, "dump", function() kxwt("dump 5") end)
  expect(c[1][1]):eq(5)
  c = with_spy(kxwt, "dump", function() kxwt("7") end)   -- bare number => dump n
  expect(c[1][1]):eq(7)
  c = with_spy(kxwt, "corpse", function() kxwt("corpse on") end)
  expect(c[1][1]):eq("on")
end)

test("trivia(...) forwards on/off/forget to the right member", function()
  local c = with_spy(trivia, "on", function() trivia("on") end)
  expect(#c):eq(1)
  c = with_spy(trivia, "forget", function() trivia("forget") end)
  expect(#c):eq(1)
  c = with_spy(trivia, "status", function() trivia("") end)   -- bare => status
  expect(#c):eq(1)
end)

test("pilot members and pilot(...) forward to ai_command", function()
  local real = ai_command
  local got = {}
  ai_command = function(s) got[#got + 1] = s end
  local ok, err = pcall(function()
    pilot.on();            expect(got[#got]):eq("on")
    pilot.goal("survive"); expect(got[#got]):eq("goal survive")
    pilot("status");       expect(got[#got]):eq("status")   -- __call -> ai() -> ai_command
  end)
  ai_command = real
  if not ok then error(err, 2) end
end)

-- ---- migrated bare globals: functions + docs ----

local GLOBALS = {
  { name = "mark",      group = "map" },
  { name = "waypoints", group = "map" },
  { name = "reset",     group = "map" },
  { name = "travel",    group = "map" },
  { name = "test",      group = "scripts" },
  { name = "volume",    group = "audio" },
}

for _, g in ipairs(GLOBALS) do
  test(g.name .. "() is a documented global function", function()
    expect(type(_G[g.name])):eq("function")
    local d = __docs.by_name[g.name]
    if not d then error(g.name .. " is not documented", 1) end
    expect(d.group):eq(g.group)
    expect(type(d.sig)):eq("string")
  end)
end

-- The legacy `ai` wrapper stays, but re-documented as deprecated in favour of pilot.*.
test("ai is re-documented as deprecated, pointing at pilot.*", function()
  local d = __docs.by_name["ai"]
  expect(d ~= nil):truthy()
  expect(d.text:lower():find("deprecated", 1, true) ~= nil):truthy()
  expect(d.text:find("pilot", 1, true) ~= nil):truthy()
end)
