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

-- ---- help() aliases, examples, and the nil-arg hint ----

test("help(io) — the stdlib table, unquoted — renders the io group, not 'no documented members'", function()
  local out = joined(function() help(io) end)
  expect(out:find("no documented members", 1, true)):eq(nil)
  expect(out:find("echo", 1, true) ~= nil):truthy()
  expect(out:find("send", 1, true) ~= nil):truthy()
  expect(out:find("bell", 1, true) ~= nil):truthy()
end)

test("help renders the example field as an e.g. line", function()
  doc("spec_exampled", { sig = "spec_exampled(x)", text = "Has an example.", group = "spectest",
                         example = 'spec_exampled("boo")' })
  local out = joined(function() help("spec_exampled") end)
  expect(out:find('e.g. spec_exampled("boo")', 1, true) ~= nil):truthy()
end)

test("help() footer hints at quoting and lists topic docs (the help(color) landing)", function()
  -- help(color) with no `color` global IS help(nil): the listing must end with a usage hint naming
  -- the topics (colors), so the user still lands somewhere useful.
  local out = joined(function() help(nil) end)
  expect(out:find("quote the name", 1, true) ~= nil):truthy()
  expect(out:find("Topics:", 1, true) ~= nil):truthy()
  expect(out:find("colors", 1, true) ~= nil):truthy()
end)

test("help('color') and help('colors') and help(colors) all render the palette topic", function()
  for _, target in ipairs({ "color", "colors" }) do
    local out = joined(function() help(target) end)
    expect(out:find("colors()", 1, true) ~= nil):truthy()
  end
  local out = joined(function() help(colors) end)      -- the table value itself
  expect(out:find("colors()", 1, true) ~= nil):truthy()
  expect(out:find("no documented members", 1, true)):eq(nil)
end)

test("hidden doc entries resolve by name but stay out of listings", function()
  -- "color" is hidden: help() full listing must not show it as its own line, help("color") must work.
  local all = joined(function() help() end)
  expect(all:find("\n  color ", 1, true)):eq(nil)
  local entry = joined(function() help("color") end)
  expect(entry:find("Alias of colors", 1, true) ~= nil):truthy()
end)

-- ---- colors() live demo ----

test("colors lists every base color, bright variant, and attribute (exhaustive)", function()
  local names = {}
  for _, n in ipairs(colors) do names[n] = true end
  for _, c in ipairs({ "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" }) do
    expect(names[c]):truthy()
    expect(names["bright " .. c]):truthy()
  end
  -- All broadly-supported text attributes are present, including the new italic/blink/strikethrough.
  for _, m in ipairs({ "bold", "dim", "italic", "underline", "blink", "reversed", "strikethrough" }) do
    expect(names[m]):truthy()
  end
end)

test("colors() demo prints every name grouped, with the colorN escape-hatch note", function()
  local out = joined(function() colors() end)
  for _, n in ipairs(colors) do
    expect(out:find(n, 1, true) ~= nil):truthy()
  end
  expect(out:find("bright red", 1, true) ~= nil):truthy()
  expect(out:find("attributes:", 1, true) ~= nil):truthy()   -- grouped output
  expect(out:find("colorN", 1, true) ~= nil):truthy()        -- advanced escape-hatch note
end)

-- ---- help() horizontal packing (__pack_names) ----

test("__pack_names greedily flows names within the width", function()
  local lines = __pack_names({ "aa", "bb", "cc", "dd" }, 8, 0)
  -- "aa bb cc" is exactly 8; adding " dd" would overflow, so it wraps to a second line.
  expect(#lines):eq(2)
  expect(lines[1]):eq("aa bb cc")
  expect(lines[2]):eq("dd")
end)

test("__pack_names honours the indent on every line", function()
  local lines = __pack_names({ "one", "two" }, 6, 2)
  -- indent 2, width 6: "  one" is 5; " two" would make 9 > 6, so "two" wraps (indented).
  expect(lines[1]):eq("  one")
  expect(lines[2]):eq("  two")
end)

test("__pack_names returns one (indent-only) line for an empty list", function()
  local lines = __pack_names({}, 40, 2)
  expect(#lines):eq(1)
  expect(lines[1]):eq("  ")
end)

test("help() catalog packs group members horizontally (many names, few lines)", function()
  for i = 1, 12 do doc("packname_" .. i, { text = "x", group = "packgrp" }) end
  local out = capture(function() help() end)
  -- Find the "packgrp" header, then confirm its members are flowed onto far fewer than 12 lines.
  local hi
  for i, line in ipairs(out) do if line == "packgrp" then hi = i end end
  expect(hi ~= nil):truthy()
  -- Collect the indented member lines that immediately follow the header.
  local member_lines = 0
  for i = hi + 1, #out do
    if out[i]:sub(1, 2) == "  " then member_lines = member_lines + 1 else break end
  end
  expect(member_lines >= 1):truthy()
  expect(member_lines < 12):truthy()                          -- packed, not one-per-line
  expect(out[hi + 1]:find("packname_1", 1, true) ~= nil):truthy()
end)

-- ---- echo() coercion wrapper ----

-- Capture through the HOST sink (__host_echo), leaving the coercion wrapper — the thing under test —
-- in place as the global `echo`.
local function capture_host(fn)
  local real = __host_echo
  local out = {}
  __host_echo = function(s) out[#out + 1] = (tostring(s):gsub("\27%[[%d;]*m", "")) end
  local ok, err = pcall(fn)
  __host_echo = real
  if not ok then error(err, 2) end
  return table.concat(out, "\n")
end

test("echo coerces a documented function to its repl-render", function()
  function spec_echo_fn() end
  doc("spec_echo_fn", { sig = "spec_echo_fn()", group = "spectest" })
  local out = capture_host(function() echo(spec_echo_fn) end)
  expect(out):eq("function: spec_echo_fn")
end)

test("echo coerces numbers and tables naturally", function()
  expect(capture_host(function() echo(42) end)):eq("42")
  local out = capture_host(function() echo({ a = 1 }) end)
  expect(out:find("a=1", 1, true) ~= nil):truthy()
end)

test("echo(nil) prints a usage hint about quoting, not 'nil'", function()
  local out = capture_host(function() echo(nil) end)
  expect(out:find("did you mean quotes", 1, true) ~= nil):truthy()
  expect(out):ne("nil")
end)

test("echo with a non-string color falls back to plain text", function()
  -- e.g. `#echo("hi", red)` where `red` is an undefined global (nil) — must still print "hi".
  expect(capture_host(function() echo("hi", nil) end)):eq("hi")
  expect(capture_host(function() echo("hi", 7) end)):eq("hi")
end)
