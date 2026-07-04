-- testing.lua — a tiny test harness for the MUD client's Lua scripts.
--
-- Loaded on demand by the `#test` command (registered in AlterAeon.lua). It runs in the SAME Lua state
-- as the live scripts, so specs can call the real widget/map code (exposed via _HUD_TEST / _AIP_TEST)
-- and even drive the real `on_update` with a stubbed panel. No external interpreter or build step — it
-- executes inside the app's own embedded Lua. Workflow: edit a script, `#ai reload`, then `#test`.
--
-- A spec file (Scripts/tests/*.lua) registers cases with:
--     test("what it does", function() expect(actual):eq(expected) end)
-- and the runner reports a ✓/✗ per case plus a summary. Re-`dofile`d fresh on every `#test`, so it's
-- always current after an edit.

local T = { cases = {} }

-- Register a case. `fn` runs later under pcall; raise (via expect/assert) to fail it.
function test(name, fn) T.cases[#T.cases + 1] = { name = name, fn = fn } end
function reset_tests() T.cases = {} end

local function fmt(v)
  if type(v) == "string" then return "'" .. v .. "'" end
  if type(v) == "table" then return "<table>" end
  return tostring(v)
end

-- Fluent assertions: expect(x):eq(y) / :ne(y) / :truthy() / :falsy() / :near(y[,eps]) / :contains(sub).
-- Each raises a descriptive error (level 2, so the reported line is the spec's, not this file's).
local Expect = {}
Expect.__index = Expect
function expect(v) return setmetatable({ v = v }, Expect) end
function Expect:eq(o) if self.v ~= o then error("expected " .. fmt(self.v) .. " == " .. fmt(o), 2) end end
function Expect:ne(o) if self.v == o then error("expected " .. fmt(self.v) .. " ~= " .. fmt(o), 2) end end
function Expect:truthy() if not self.v then error("expected truthy, got " .. fmt(self.v), 2) end end
function Expect:falsy() if self.v then error("expected falsy, got " .. fmt(self.v), 2) end end
function Expect:near(o, eps)
  eps = eps or 1e-9
  if type(self.v) ~= "number" or math.abs(self.v - o) > eps then
    error("expected " .. fmt(self.v) .. " ≈ " .. fmt(o), 2)
  end
end
function Expect:contains(sub)
  if type(self.v) ~= "string" or not self.v:find(sub, 1, true) then
    error("expected " .. fmt(self.v) .. " to contain '" .. tostring(sub) .. "'", 2)
  end
end

-- Count non-overlapping occurrences of a (possibly multi-byte) substring. Handy for measuring a gauge:
-- how many "█" it drew. Plain-text find, so needles like "█" match their exact UTF-8 bytes.
function count(haystack, needle)
  local n, i = 0, 1
  while true do
    local s = (haystack or ""):find(needle, i, true)
    if not s then return n end
    n = n + 1; i = s + #needle
  end
end

-- Drive the live HUD once and capture what it would have painted, without a real screen. Temporarily
-- swaps the global `panel` (and, by default, nils `minimap` to isolate widgets from the map), calls
-- on_update, then restores both. Returns (top_rows, bottom_rows) — the exact specs passed to
-- panel.top / panel.render. Specs set a fake `state` before calling.
function capture_update(opts)
  opts = opts or {}
  local real_panel, real_minimap = panel, minimap
  local top_rows, bot_rows
  panel = {
    render = function(rows) bot_rows = rows end,
    top    = function(rows) top_rows = rows end,
    height = function() return 0 end,
    top_height = function() return 0 end,
  }
  if opts.keep_minimap ~= true then minimap = nil end
  local ok, err = pcall(on_update)
  panel, minimap = real_panel, real_minimap
  if not ok then error(err, 2) end
  return top_rows, bot_rows
end

-- Run every registered case, echoing a coloured ✓/✗ per case and a summary. Returns (pass, fail).
function run_tests()
  local pass, fail = 0, 0
  for _, c in ipairs(T.cases) do
    local ok, err = pcall(c.fn)
    if ok then
      pass = pass + 1
      echo("\27[32m  ✓\27[0m " .. c.name)
    else
      fail = fail + 1
      echo("\27[31m  ✗ " .. c.name .. "\27[0m\n      \27[31m" .. tostring(err) .. "\27[0m")
    end
  end
  local colour = fail == 0 and "\27[1;32m" or "\27[1;31m"
  echo(string.format("%s[test] %d passed, %d failed, %d total\27[0m", colour, pass, fail, pass + fail))
  return pass, fail
end
