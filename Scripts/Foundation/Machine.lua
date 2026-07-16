






































































local DONE = "__machine_done__"


local function default_next(m, i)
   local nxt = m._phases[i + 1]
   return nxt and nxt.name or DONE
end




local function resolve_next(m, i, explicit)
   if explicit ~= nil then
      if type(explicit) == "function" then return (explicit)() end
      return explicit
   end
   local ph = m._phases[i]
   if ph.transition then return ph.transition(m) end
   return default_next(m, i)
end



local function enter(m, i)
   m._cur = i
   m._token = (m._token or 0) + 1
   local token = m._token
   local ph = m._phases[i]
   local function advance(explicit)
      if m._stopped or token ~= m._token then return end
      local nxt = resolve_next(m, i, explicit)
      if nxt == DONE then
         m._cur = nil
         if m._done_cb then m._done_cb() end
         return
      end
      local j = m._index[nxt]
      if not j then
         if echo then echo("[machine] unknown phase '" .. tostring(nxt) .. "' — stopping.") end
         return
      end
      enter(m, j)
   end
   ph.handler(advance)
end

local function new(start_name)
   local m
   m = {
      _phases = {}, _index = {}, _start = start_name, _token = 0, _stopped = false,
      phase = function(self, name, handler, transition)
         self._phases[#self._phases + 1] = { name = name, handler = handler, transition = transition }
         self._index[name] = #self._phases
         return self
      end,
      start = function(self, done_cb)
         self._done_cb, self._stopped = done_cb, false
         local i = self._index[self._start]
         if not i then
            if echo then echo("[machine] unknown start phase '" .. tostring(self._start) .. "'.") end
            return self
         end
         enter(self, i)
         return self
      end,


      cancel = function(self) self._stopped = true; self._token = (self._token or 0) + 1 end,
      current = function(self)
         local ph = self._cur and self._phases[self._cur]
         return ph and ph.name or nil
      end,
      active = function(self) return not self._stopped and self._cur ~= nil end,
   }
   return m
end



local function loop_if(pred)
   return function(m) return pred() and m._start or DONE end
end



local function goto_phase(name)
   return function(_) return name end
end






__machine = setmetatable({ DONE = DONE, loop_if = loop_if, goto_phase = goto_phase },
{ __call = function(_, start_name) return new(start_name) end })

_MACHINE_TEST = { new = new, DONE = DONE, resolve_next = resolve_next, default_next = default_next }
