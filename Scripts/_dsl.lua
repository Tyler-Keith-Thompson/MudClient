













local FieldBuilder = {}


function FieldBuilder:into(...)
   for _, k in ipairs({ ... }) do self.cfg.keys[#self.cfg.keys + 1] = k end
   return self
end
function FieldBuilder:as(conv) self.cfg.conv = conv; return self end
function FieldBuilder:via(conv) self.cfg.conv = conv; return self end
function FieldBuilder:then_(fn) self.cfg.after = fn; return self end


local ReplyRouter = {}


function ReplyRouter:on(pattern, outcome)
   local h = self.handler
   trigger(pattern, function() h(outcome) end)
   return self
end









local M = {}


function M.number(s) return tonumber(s) end

function M.flag(s) return tonumber(s) == 1 end

function M.field(pattern)
   local cfg = { keys = {} }
   trigger(pattern, function(_, ...)
      if #cfg.keys == 0 then return end
      local caps = { ... }
      for i, key in ipairs(cfg.keys) do
         local v = caps[i]
         if cfg.conv then v = cfg.conv(v) end
         state[key] = v
      end
      if cfg.after then cfg.after() end
   end)
   return setmetatable({ cfg = cfg }, { __index = FieldBuilder })
end

function M.replies(handler)
   return setmetatable({ handler = handler }, { __index = ReplyRouter })
end


function M.on_all(patterns, fn)
   for _, p in ipairs(patterns) do trigger(p, fn) end
end

__dsl = M
return M
