






















local M = {}



local function ser(v)
   local t = type(v)
   if t == "number" or t == "boolean" then return tostring(v) end
   if t == "string" then return string.format("%q", v) end
   if t == "table" then
      local parts = {}
      for k, val in pairs(v) do
         local key
         if type(k) == "number" then key = "[" .. k .. "]" else key = "[" .. string.format("%q", k) .. "]" end
         parts[#parts + 1] = key .. "=" .. ser(val)
      end
      return "{" .. table.concat(parts, ",") .. "}"
   end
   return "nil"
end
function M.serialize(v) return "return " .. ser(v) end

local function slurp(path)
   local f = io.open(path, "r"); if not f then return nil end
   local d = f:read("a"); f:close(); return d
end
local function spit(path, data)
   local f = io.open(path, "w"); if not f then return false end
   f:write(data); f:close(); return true
end
local function fsize(path) local d = slurp(path); return d and #d or 0 end



local function parse(path)
   local raw = slurp(path)
   if not raw or raw:match("%S") == nil then return nil, "empty" end
   local chunk = loadfile(path); if not chunk then return nil, "corrupt" end
   local ok, v = pcall(chunk); if not ok then return nil, "corrupt" end
   return v
end




function M.write(path, body)
   if not spit(path .. ".tmp", body) then return false end




   local data = slurp(path)
   local cur = data and #data or 0
   if cur > 0 and cur >= fsize(path .. ".bak") then spit(path .. ".bak", data) end
   return os.rename(path .. ".tmp", path) and true or false
end


function M.save(path, tbl) return M.write(path, M.serialize(tbl)) end





function M.load(path, notify)
   local v, why = parse(path)
   if v ~= nil then return v end
   if why == "corrupt" then
      os.rename(path, path .. ".corrupt")
      if notify then notify("[persist] " .. path .. " was corrupt — moved aside to .corrupt") end
   end
   local b = parse(path .. ".bak")
   if b ~= nil then
      local data = slurp(path .. ".bak"); if data then spit(path, data) end
      if notify then notify("[persist] recovered " .. path .. " from backup") end
      return b
   end
   return nil
end


if doc then
   doc(M.save, { name = "persist.save", sig = "persist.save(path, tbl) -> ok", group = "persistence",
text = "Serialize `tbl` to `return {...}` and write it to `path` atomically, keeping a shrink-proof `path.bak`.", })
   doc(M.load, { name = "persist.load", sig = "persist.load(path[, notify]) -> value|nil", group = "persistence",
text = "Load a value saved by persist.save/write. Self-heals from `path.bak` if the primary is missing/empty/corrupt (a corrupt primary is preserved as `path.corrupt`). `notify(msg)` is called on recovery.", })
   doc(M.write, { name = "persist.write", sig = "persist.write(path, body) -> ok", group = "persistence",
text = "Like persist.save but takes a pre-serialized `return {...}` string, for callers that build their own literal.", })
end





__persist = M
return M
