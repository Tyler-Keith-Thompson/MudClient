-- Doc-coverage enforcement: a new capability CANNOT ship undocumented.
--
-- Host builtins: every name in `__host_builtins` — populated by the Swift host's Lua.register in-app,
-- and mirrored by tools/luatest/driver.lua's stub() in the CLI harness — must be documented (by name,
-- or by the function value it backs, which covers raw registrations like panel_render that are
-- documented as panel.render). Public script APIs: every function member of the public tables below
-- must have a doc() entry. Failures NAME the offenders, so the fix is obvious.
--
-- Exemptions: names starting with `__` are internal by convention. ALLOWLIST is for the rare
-- genuinely-internal registration that can't use the prefix; keep it small and justified.
-- (Swift-side hook call sites are enforced by the companion Swift test, hookDocsCoverSwiftCallSites.)

local ALLOWLIST = {
  -- (empty — the raw panel_*/music_* registrations pass via their table-member docs)
}

-- Is builtin `n` documented? By name, or by the function value the global holds (a raw registration
-- like `panel_render` is documented as `panel.render`, the same function value).
local function documented(n)
  if __docs.by_name[n] then return true end
  local v = _G[n]
  if type(v) == "function" and __docs.by_fn[v] then return true end
  return false
end

test("every host builtin is documented (doc() in bootstrap.lua)", function()
  expect(type(__host_builtins)):eq("table")
  local missing = {}
  for n in pairs(__host_builtins) do
    if n:sub(1, 2) ~= "__" and not ALLOWLIST[n] and not documented(n) then
      missing[#missing + 1] = n
    end
  end
  table.sort(missing)
  if #missing > 0 then
    error("undocumented host builtins (add doc() entries in Scripts/bootstrap.lua): "
          .. table.concat(missing, ", "), 1)
  end
end)

test("__host_builtins is populated (the enforcement has teeth)", function()
  local n = 0
  for _ in pairs(__host_builtins) do n = n + 1 end
  expect(n > 30):truthy()   -- the real surface is ~50 names; a near-empty table means recording broke
end)

-- Public script/host API tables: every function member must be documented (by function value, since
-- members are doc()'d as "tbl.member"). `__`-prefixed keys are internal.
local PUBLIC_TABLES = { "panel", "music", "eq", "pilot", "kxwt", "trivia" }

test("every public-table API member is documented", function()
  local missing = {}
  for _, tname in ipairs(PUBLIC_TABLES) do
    local tbl = _G[tname]
    expect(type(tbl)):eq("table")
    for k, v in pairs(tbl) do
      local key = tostring(k)
      if type(v) == "function" and key:sub(1, 2) ~= "__" and not __docs.by_fn[v] then
        missing[#missing + 1] = tname .. "." .. key
      end
    end
  end
  table.sort(missing)
  if #missing > 0 then
    error("undocumented public API members (add doc() entries next to their definitions): "
          .. table.concat(missing, ", "), 1)
  end
end)

-- The detector itself must fail loudly on a fake undocumented builtin (guards against the checks
-- rotting into always-pass).
test("coverage check catches an undocumented builtin", function()
  __host_builtins["zz_fake_builtin_for_spec"] = true
  local ok = documented("zz_fake_builtin_for_spec")
  __host_builtins["zz_fake_builtin_for_spec"] = nil
  expect(ok):falsy()
end)
