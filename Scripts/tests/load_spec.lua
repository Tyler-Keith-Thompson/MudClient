-- Script-loader specs: the pure path/extension/directory/ordering logic behind `load(path)` and the
-- `reload()` wiring (bootstrap.lua). The pure helpers are exercised through `_LOAD_TEST`; the full
-- `load()`/`reload()` dispatch is driven against a fake filesystem by overriding the host primitives
-- (__path_kind/__list_dir/__run_file/__clear_rules) for the duration of a case.

local function join(t) return table.concat(t, ",") end

-- ---- load_filter: extension, exclusions, `_`-prefix ----

test("load_filter keeps *.lua and drops non-lua / excluded / _-prefixed", function()
  local got = _LOAD_TEST.filter({
    "AlterAeon.lua", "HUD.lua",
    "bootstrap.lua", "testing.lua", "manifest.lua",  -- excluded (host-owned / harness / metadata)
    "_scratch.lua", "notes.txt", "README",           -- _-prefixed, non-.lua
  })
  expect(join(got)):eq("AlterAeon.lua,HUD.lua")
end)

test("load_filter preserves input order", function()
  expect(join(_LOAD_TEST.filter({ "z.lua", "a.lua", "m.lua" }))):eq("z.lua,a.lua,m.lua")
end)

-- ---- load_order: manifest pin + alphabetical fallback ----

test("load_order with no manifest sorts case-insensitively", function()
  local got = _LOAD_TEST.order({ "HUD.lua", "AIPilot.lua", "alterAeon.lua" }, nil)
  expect(join(got)):eq("AIPilot.lua,alterAeon.lua,HUD.lua")
end)

test("load_order honours a manifest first, then alphabetical for the rest", function()
  -- Manifest lists base names; AlterAeon must precede AIPilot despite alphabetical order.
  local names = { "Equipment.lua", "AIPilot.lua", "HUD.lua", "AlterAeon.lua", "Zebra.lua" }
  local got = _LOAD_TEST.order(names, { "AlterAeon", "AIPilot", "HUD" })
  expect(join(got)):eq("AlterAeon.lua,AIPilot.lua,HUD.lua,Equipment.lua,Zebra.lua")
end)

-- ---- full load() dispatch against a fake filesystem ----

-- Install a fake FS + record __run_file calls; returns a restore function.
local function fake_fs(kinds, listing)
  local saved = {
    pk = __path_kind, ld = __list_dir, rf = __run_file, cr = __clear_rules, lc = loadchunk,
  }
  local runs, chunks = {}, {}
  __path_kind = function(p) return kinds[p] or "missing" end
  __list_dir = function(p) return listing[p] or {} end
  __run_file = function(p) runs[#runs + 1] = p; return true end
  __clear_rules = function() runs[#runs + 1] = "<clear>" end
  loadchunk = function(x) chunks[#chunks + 1] = x; return "compiled" end
  return runs, chunks, function()
    __path_kind, __list_dir, __run_file = saved.pk, saved.ld, saved.rf
    __clear_rules, loadchunk = saved.cr, saved.lc
  end
end

test("load(file) runs that file; the .lua extension is assumed", function()
  local runs, _, restore = fake_fs({ ["AlterAeon.lua"] = "file" }, {})
  load("AlterAeon")            -- no extension → resolves to AlterAeon.lua
  restore()
  expect(join(runs)):eq("AlterAeon.lua")
end)

test("load(file.lua) runs the explicit file", function()
  local runs, _, restore = fake_fs({ ["x.lua"] = "file" }, {})
  load("x.lua")
  restore()
  expect(join(runs)):eq("x.lua")
end)

test("load(dir) runs top-level scripts in manifest-less alphabetical order", function()
  local runs, _, restore = fake_fs(
    { ["Scripts"] = "dir" },
    { ["Scripts"] = { "HUD.lua", "AIPilot.lua", "bootstrap.lua", "manifest.lua", "_x.lua", "n.txt" } })
  load("Scripts")
  restore()
  -- bootstrap/manifest/_x/n.txt excluded; the rest alphabetical (no manifest file present here).
  expect(join(runs)):eq("Scripts/AIPilot.lua,Scripts/HUD.lua")
end)

test("load(missing) raises", function()
  local _, _, restore = fake_fs({}, {})
  local ok, err = pcall(load, "nope")
  restore()
  expect(ok):falsy()
  expect(tostring(err)):contains("no such script or directory")
end)

test("load(function) delegates to stdlib loadchunk (not treated as a path)", function()
  local _, chunks, restore = fake_fs({}, {})
  local fn = function() end
  local result = load(fn)
  restore()
  expect(#chunks):eq(1)
  expect(chunks[1]):eq(fn)
  expect(result):eq("compiled")
end)

test("reload() clears rules first, then loads Scripts/", function()
  local runs, _, restore = fake_fs({ ["Scripts"] = "dir" }, { ["Scripts"] = { "AlterAeon.lua" } })
  reload()
  restore()
  expect(join(runs)):eq("<clear>,Scripts/AlterAeon.lua")
end)
