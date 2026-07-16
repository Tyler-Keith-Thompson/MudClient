-- Script-loader specs: the pure path/extension/directory/ordering logic and the require-based
-- `load()`/`reload()` wiring (bootstrap.lua). The pure helpers are exercised through `_LOAD_TEST`;
-- the full dispatch is driven against a fake filesystem by overriding the host primitives
-- (__path_kind/__list_dir/__run_file/__clear_rules) for the duration of a case.
--
-- The old manifest-ordered loader is GONE: order now emerges from require's run-once cache plus
-- declared in-file dependencies, and the directory loader is plain case-insensitive alphabetical.
-- These cases pin the require semantics that replaced the manifest.

local di = __di or dofile("Scripts/Foundation/Container.lua")

local function join(t) return table.concat(t, ",") end

-- ---- load_filter: extension, exclusions, `_`-prefix ----

test("load_filter keeps *.lua and drops non-lua / excluded / _-prefixed", function()
  local got = _LOAD_TEST.filter({
    "AlterAeon.lua", "HUD.lua",
    "bootstrap.lua", "testing.lua",                  -- excluded (host-owned / harness)
    "_scratch.lua", "notes.txt", "README",           -- _-prefixed, non-.lua
  })
  expect(join(got)):eq("AlterAeon.lua,HUD.lua")
end)

test("load_filter no longer treats manifest.lua specially (it was deleted)", function()
  -- manifest.lua is just another *.lua now; nothing pins load order anymore.
  local got = _LOAD_TEST.filter({ "manifest.lua", "HUD.lua" })
  expect(join(got)):eq("manifest.lua,HUD.lua")
end)

test("load_filter preserves input order", function()
  expect(join(_LOAD_TEST.filter({ "z.lua", "a.lua", "m.lua" }))):eq("z.lua,a.lua,m.lua")
end)

-- ---- load_order: plain case-insensitive alphabetical (no manifest) ----

test("load_order sorts case-insensitively — AIPilot before AlterAeon (no manifest pin)", function()
  local got = _LOAD_TEST.order({ "HUD.lua", "AlterAeon.lua", "AIPilot.lua", "Equipment.lua" })
  expect(join(got)):eq("AIPilot.lua,AlterAeon.lua,Equipment.lua,HUD.lua")
end)

-- ---- module_of: basename identity so file-path and dir loads share a cache entry ----

test("module_of strips directory and extension", function()
  expect(_LOAD_TEST.module_of("Scripts/HUD.lua")):eq("HUD")
  expect(_LOAD_TEST.module_of("HUD")):eq("HUD")
  expect(_LOAD_TEST.module_of("AlterAeon.lua")):eq("AlterAeon")
end)

-- ---- resolve_script: CWD-relative resolution across the search roots ----

test("resolve_script finds a bare name under the Scripts root", function()
  local got
  di.with_overrides({
    __path_kind = function(p) return p == "Scripts/AlterAeon.lua" and "file" or "missing" end,
  }, function()
    got = _LOAD_TEST.resolve("AlterAeon")
  end)
  expect(got):eq("Scripts/AlterAeon.lua")
end)

test("resolve_script honours an explicit path first", function()
  local got
  di.with_overrides({
    __path_kind = function(p) return p == "x.lua" and "file" or "missing" end,
  }, function()
    got = _LOAD_TEST.resolve("x.lua")
  end)
  expect(got):eq("x.lua")
end)

-- ---- resolve_script + Teal: a wired compiler lets a .tl source resolve; freshness is batched (below) ----

test("resolve_script does NO per-file compile when the .lua already exists (freshness is batched)", function()
  local got, calls = nil, 0
  di.with_overrides({
    __path_kind = function(p) return (p == "Scripts/Bar.lua" or p == "Scripts/Bar.tl") and "file" or "missing" end,
    __teal_compile = function() calls = calls + 1 end,        -- must NOT be called: the .lua is present
  }, function()
    got = _LOAD_TEST.resolve("Bar")
  end)
  expect(got):eq("Scripts/Bar.lua")
  expect(calls):eq(0)                                         -- per-reload cost stays O(1), not O(files)
end)

test("resolve_script compiles a .tl-only module (no committed .lua) when a compiler is wired", function()
  local sk, stc = __path_kind, __teal_compile
  local compiled = {}
  -- Foo.lua does not exist until the hook "compiles" it; Foo.tl does.
  __path_kind = function(p)
    if p == "Scripts/Foo.tl" then return "file" end
    if p == "Scripts/Foo.lua" then return compiled["Scripts/Foo.lua"] and "file" or "missing" end
    return "missing"
  end
  __teal_compile = function(_, lua) compiled[lua] = true end
  local got = _LOAD_TEST.resolve("Foo")
  __path_kind, __teal_compile = sk, stc
  expect(got):eq("Scripts/Foo.lua")
end)

test("resolve_script ignores a .tl when NO compiler is wired (Lua-only deploy uses committed .lua only)", function()
  local sk, stc = __path_kind, __teal_compile
  __teal_compile = nil                                        -- no compiler (harness / shipped Lua-only)
  __path_kind = function(p) return p == "Scripts/Baz.tl" and "file" or "missing" end  -- only the .tl exists
  local got = _LOAD_TEST.resolve("Baz")
  __path_kind, __teal_compile = sk, stc
  expect(got):eq(nil)                                         -- a .tl alone is invisible without a compiler
end)

-- ---- full load()/reload()/require dispatch against a fake filesystem ----

-- Install a fake FS + record __run_file calls; returns (runs, restore). Also clears any leftover
-- package.loaded entries for the module names a case will touch so require actually re-runs.
local function fake_fs(kinds, listing)
  local saved = {
    pk = __path_kind, ld = __list_dir, rf = __run_file, cr = __clear_rules, lc = loadchunk,
  }
  local runs = {}
  __path_kind = function(p) return kinds[p] or "missing" end
  __list_dir = function(p) return listing[p] or {} end
  __run_file = function(p) runs[#runs + 1] = p; return true end
  __clear_rules = function() runs[#runs + 1] = "<clear>" end
  return runs, function()
    __path_kind, __list_dir, __run_file = saved.pk, saved.ld, saved.rf
    __clear_rules, loadchunk = saved.cr, saved.lc
  end
end

test("load(file) runs that file; the .lua extension is assumed", function()
  local runs, restore = fake_fs({ ["Scripts/AlterAeon.lua"] = "file" }, {})
  load("AlterAeon")            -- bare name resolves via the Scripts root to Scripts/AlterAeon.lua
  restore()
  expect(join(runs)):eq("Scripts/AlterAeon.lua")
end)

test("load(file.lua) runs the explicit file", function()
  local runs, restore = fake_fs({ ["x.lua"] = "file" }, {})
  load("x.lua")
  restore()
  expect(join(runs)):eq("x.lua")
end)

test("load() runs __teal_sync ONCE up front, then loads (stale Teal regenerated before resolution)", function()
  local runs, restore = fake_fs({ ["Scripts/X.lua"] = "file" }, {})
  local synced, ss = 0, __teal_sync
  __teal_sync = function() synced = synced + 1 end
  load("X")
  __teal_sync = ss
  restore()
  expect(synced):eq(1)                       -- one batched sync per load, regardless of file count
  expect(join(runs)):eq("Scripts/X.lua")     -- and the module still loads afterward
end)

test("load(dir) runs top-level scripts in case-insensitive alphabetical order via require", function()
  local runs, restore = fake_fs(
    { ["Scripts"] = "dir",
      ["Scripts/AIPilot.lua"] = "file", ["Scripts/HUD.lua"] = "file" },
    { ["Scripts"] = { "HUD.lua", "AIPilot.lua", "bootstrap.lua", "_x.lua", "n.txt" } })
  load("Scripts")
  restore()
  -- bootstrap/_x/n.txt excluded; the rest alphabetical (AIPilot before HUD).
  expect(join(runs)):eq("Scripts/AIPilot.lua,Scripts/HUD.lua")
end)

test("load(dir) descends one level into subdirs, Foundation before AlterAeon, after top-level files", function()
  -- Promise.lua (not _-prefixed, not excluded) stands in for a real Foundation file the directory
  -- loader actually runs; _rx.lua/_persist.lua/_dsl.lua are `_`-prefixed on purpose (loaded via
  -- explicit dofile/require from their consumers, not swept in by the directory loader).
  local runs, restore = fake_fs(
    { ["Scripts"] = "dir",
      ["Scripts/HUD.lua"] = "file",
      ["Scripts/Foundation"] = "dir", ["Scripts/Foundation/Promise.lua"] = "file",
      ["Scripts/AlterAeon"] = "dir", ["Scripts/AlterAeon/AIPilot.lua"] = "file" },
    { ["Scripts"] = { "HUD.lua", "AlterAeon", "Foundation" },   -- listed AlterAeon before Foundation on
      ["Scripts/Foundation"] = { "Promise.lua" },               -- purpose: order must NOT come from listing
      ["Scripts/AlterAeon"] = { "AIPilot.lua" } })
  load("Scripts")
  restore()
  expect(join(runs)):eq("Scripts/HUD.lua,Scripts/Foundation/Promise.lua,Scripts/AlterAeon/AIPilot.lua")
end)

test("load(dir) does NOT descend into tests/ or _-prefixed subdirs (specs never load in the live app)", function()
  local runs, restore = fake_fs(
    { ["Scripts"] = "dir",
      ["Scripts/AlterAeon"] = "dir", ["Scripts/AlterAeon/AIPilot.lua"] = "file",
      ["Scripts/tests"] = "dir", ["Scripts/tests/load_spec.lua"] = "file",
      ["Scripts/_scratch"] = "dir", ["Scripts/_scratch/x.lua"] = "file" },
    { ["Scripts"] = { "AlterAeon", "tests", "_scratch" },
      ["Scripts/AlterAeon"] = { "AIPilot.lua" },
      ["Scripts/tests"] = { "load_spec.lua" },
      ["Scripts/_scratch"] = { "x.lua" } })
  load("Scripts")
  restore()
  expect(join(runs)):eq("Scripts/AlterAeon/AIPilot.lua")   -- tests/ and _scratch/ skipped, not run
end)

test("load(dir) re-runs each file even if already required (interactive re-load)", function()
  local kinds = { ["Scripts"] = "dir", ["Scripts/A.lua"] = "file" }
  local runs, restore = fake_fs(kinds, { ["Scripts"] = { "A.lua" } })
  load("Scripts")            -- first load
  load("Scripts")            -- second load must re-run, not skip on the require cache
  restore()
  expect(join(runs)):eq("Scripts/A.lua,Scripts/A.lua")
end)

test("load(missing) raises", function()
  local _, restore = fake_fs({}, {})
  local ok, err = pcall(load, "nope")
  restore()
  expect(ok):falsy()
  expect(tostring(err)):contains("no such script or directory")
end)

test("load(function) delegates to stdlib loadchunk (not treated as a path)", function()
  local _, restore = fake_fs({}, {})
  local chunks = {}
  loadchunk = function(x) chunks[#chunks + 1] = x; return "compiled" end
  local fn = function() end
  local result = load(fn)
  restore()
  expect(#chunks):eq(1)
  expect(chunks[1]):eq(fn)
  expect(result):eq("compiled")
end)

test("reload() clears rules first, then re-runs Scripts/ (busting the require cache)", function()
  local runs, restore = fake_fs(
    { ["Scripts"] = "dir", ["Scripts/AlterAeon.lua"] = "file" },
    { ["Scripts"] = { "AlterAeon.lua" } })
  load("Scripts")     -- prime the cache
  reload()            -- must clear, then re-run despite the priming
  restore()
  -- first the priming run, then <clear>, then the re-run.
  expect(join(runs)):eq("Scripts/AlterAeon.lua,<clear>,Scripts/AlterAeon.lua")
end)

-- ---- trigger-order regression, now proven by REQUIRE ordering at the Lua layer ----
-- The manifest existed partly so a dependency loads before its dependents. Prove require's run-once
-- cache delivers that: a module that require()s another pulls the dependency in FIRST, regardless of
-- who is required first. (Same-LINE trigger firing order is a Swift-engine specificity concern, tested
-- in the Swift suite; this pins the load-time ordering guarantee require gives us.)
test("require pulls a declared dependency in before its dependent", function()
  local order = {}
  local kinds = { ["Scripts/Dep.lua"] = "file", ["Scripts/User.lua"] = "file" }
  local saved = { pk = __path_kind, rf = __run_file }
  __path_kind = function(p) return kinds[p] or "missing" end
  __run_file = function(p)
    if p == "Scripts/User.lua" then
      require("Dep")                 -- User declares a dependency on Dep
      order[#order + 1] = "User"
    elseif p == "Scripts/Dep.lua" then
      order[#order + 1] = "Dep"
    end
    return true
  end
  package.loaded["Dep"], package.loaded["User"] = nil, nil
  require("User")                    -- require the DEPENDENT first…
  __path_kind, __run_file = saved.pk, saved.rf
  package.loaded["Dep"], package.loaded["User"] = nil, nil
  expect(join(order)):eq("Dep,User")   -- …the dependency still ran first
end)
