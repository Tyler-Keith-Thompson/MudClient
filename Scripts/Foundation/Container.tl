-- Container.tl — scoped dependency-override lifecycle for tests (the `__di` analog of the user's Swift
-- `Container`/`withNestedContainer`). Lua resolution is already free (globals + the require cache), so
-- this deliberately does NOT reinstate IoC — rewriting every `trigger(...)`/`send(...)` call site to
-- resolve through a registry would fight the architecture for no benefit. The one thing worth lifting
-- out is the SCOPED-OVERRIDE lifecycle: 28+ specs currently hand-roll
--
--   local saved = __path_kind; __path_kind = fake; ...; __path_kind = saved
--
-- which leaks the fake into every later test the moment an assertion in `...` throws (the restore line
-- never runs). `with_overrides` is that pattern made leak-proof: it saves, overrides, runs the body
-- inside a pcall, and restores — unconditionally — before re-raising any error.
--
--   local di = __di
--   di.with_overrides({ __path_kind = fake_pk }, function()
--     ... test body using __path_kind ...
--   end)
--   -- __path_kind is back to whatever it held on entry, even if the body errored.
--
-- Nesting: each call restores to whatever was there AT ENTRY (not a fixed baseline), so calls nest
-- freely — an outer override survives an inner with_overrides of the same key.
--
-- Kept deliberately tiny: no register()/resolve() service seam. Lua doesn't need one — a "service" here
-- is just a global or a require'd module table, and overriding it directly (this function) is already
-- the whole mechanism; a registry on top would just be another layer of indirection to override the
-- indirection.

local M = {}

function M.with_overrides(overrides: {string:any}, body: function())
  local g = _G as {string:any}
  local saved: {string:any} = {}
  for k, v in pairs(overrides) do
    saved[k] = g[k]
    g[k] = v
  end
  local ok, err = pcall(body as function(): any)
  for k, v in pairs(saved) do
    g[k] = v
  end
  if not ok then error(err, 0) end
end

if doc then
  doc(M.with_overrides, { name = "di.with_overrides", sig = "di.with_overrides({name=value,...}, function() ... end)",
    group = "testing",
    text = "Save each named global, set it to the override, run body() under pcall, then restore every "
        .. "saved global — even if body errored (the error is re-raised after restoring). Nests: an inner "
        .. "call restores to whatever the outer call had set, not a fixed baseline." })
end

__di = M as Container
return M
