

























local M = {}

function M.with_overrides(overrides, body)
   local g = _G
   local saved = {}
   for k, v in pairs(overrides) do
      saved[k] = g[k]
      g[k] = v
   end
   local ok, err = pcall(body)
   for k, v in pairs(saved) do
      g[k] = v
   end
   if not ok then error(err, 0) end
end

if doc then
   doc(M.with_overrides, { name = "di.with_overrides", sig = "di.with_overrides({name=value,...}, function() ... end)",
group = "testing",
text = "Save each named global, set it to the override, run body() under pcall, then restore every " ..
"saved global — even if body errored (the error is re-raised after restoring). Nests: an inner " ..
"call restores to whatever the outer call had set, not a fixed baseline.", })
end

__di = M
return M
