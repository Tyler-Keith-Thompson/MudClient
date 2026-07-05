-- Specs for the host bootstrap (Scripts/bootstrap.lua): the doc/help registry, the REPL pretty-printer,
-- and the legacy command() bridge. These run in the same Lua state as the live scripts (loaded by the
-- test harness / driver), so `doc`, `help`, `command`, `__repl_print`, and the builtin docs are present.

-- Capture what help()/__repl_print echo, with a temporary echo override, then restore it.
local function capture(fn)
  local real = echo
  local out = {}
  echo = function(s) out[#out + 1] = (tostring(s):gsub("\27%[[%d;]*m", "")) end   -- strip colour
  local ok, err = pcall(fn)
  echo = real
  if not ok then error(err, 2) end
  return out
end

local function joined(fn) return table.concat(capture(fn), "\n") end

-- ---- doc registry ----

test("doc registers by name and help(name) shows it", function()
  doc("spec_widget", { sig = "spec_widget(x) -> y", text = "A test widget.", group = "spectest" })
  local out = joined(function() help("spec_widget") end)
  expect(out:find("spec_widget(x) -> y", 1, true) ~= nil):truthy()
  expect(out:find("A test widget.", 1, true) ~= nil):truthy()
  expect(out:find("spectest", 1, true) ~= nil):truthy()
end)

test("doc indexes a global function so help(fn) works by reference", function()
  function spec_fn() return 1 end
  doc("spec_fn", { sig = "spec_fn()", text = "By ref.", group = "spectest" })
  local out = joined(function() help(spec_fn) end)         -- pass the function value, not the name
  expect(out:find("By ref.", 1, true) ~= nil):truthy()
end)

test("help('group') lists every entry in that group", function()
  doc("spec_a", { text = "alpha", group = "grouptest" })
  doc("spec_b", { text = "beta", group = "grouptest" })
  local out = joined(function() help("grouptest") end)
  expect(out:find("spec_a", 1, true) ~= nil):truthy()
  expect(out:find("spec_b", 1, true) ~= nil):truthy()
end)

test("help() lists builtins grouped (triggers group present)", function()
  local out = joined(function() help() end)
  expect(out:find("triggers", 1, true) ~= nil):truthy()
  expect(out:find("trigger", 1, true) ~= nil):truthy()
  expect(out:find("alias", 1, true) ~= nil):truthy()
end)

test("help on an undocumented existing global reports its type", function()
  spec_undoc = 42
  local out = joined(function() help("spec_undoc") end)
  expect(out:find("undocumented", 1, true) ~= nil):truthy()
  expect(out:find("number", 1, true) ~= nil):truthy()
end)

test("help on an unknown target says so", function()
  local out = joined(function() help("nope_not_a_thing_xyz") end)
  expect(out:find("no documentation", 1, true) ~= nil):truthy()
end)

test("help(table) lists documented members", function()
  spec_tbl = { one = function() end, two = function() end }
  doc(spec_tbl.one, { name = "spec_tbl.one", sig = "spec_tbl.one()", group = "spectest" })
  local out = joined(function() help(spec_tbl) end)
  expect(out:find("one", 1, true) ~= nil):truthy()
end)

-- ---- REPL pretty-printer ----

test("__repl_print renders a string plainly", function()
  expect(joined(function() __repl_print("hello") end)):eq("hello")
end)

test("__repl_print renders a number plainly", function()
  expect(joined(function() __repl_print(42) end)):eq("42")
end)

test("__repl_print with no args prints nothing", function()
  expect(#capture(function() __repl_print() end)):eq(0)
end)

test("__repl_print renders a table shallowly with quoted string values", function()
  local out = joined(function() __repl_print({ a = 1, b = "x" }) end)
  expect(out:find("a=1", 1, true) ~= nil):truthy()
  expect(out:find('b="x"', 1, true) ~= nil):truthy()
end)

test("__repl_print bounds a huge table with an N-more marker", function()
  local big = {}
  for i = 1, 50 do big[i] = i end
  local out = joined(function() __repl_print(big) end)
  expect(out:find("more", 1, true) ~= nil):truthy()
end)

test("__repl_print names a documented function", function()
  local out = joined(function() __repl_print(spec_fn) end)   -- documented above
  expect(out:find("function: spec_fn", 1, true) ~= nil):truthy()
end)

-- ---- command() bridge ----

test("command defines a global function that forwards its argument", function()
  local got
  command("spec_cmd", function(arg) got = arg end)
  expect(type(spec_cmd)):eq("function")          -- a real global, not a host registry entry
  spec_cmd("payload")
  expect(got):eq("payload")
end)

test("command sanitizes non-identifier names to a valid global", function()
  local hit = false
  command("spec-weird.name", function() hit = true end)
  expect(type(spec_weird_name)):eq("function")   -- '-' and '.' -> '_'
  spec_weird_name()
  expect(hit):truthy()
end)

test("command registers a doc stub for the new global", function()
  command("spec_documented", function() end)
  local out = joined(function() help("spec_documented") end)
  expect(out:find("migrated legacy command", 1, true) ~= nil):truthy()
end)
