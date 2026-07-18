

























































































local function is_promise(x)
   return type(x) == "table" and (x).__is_promise == true
end
local function cancel_timer(id)
   if id and cancel then cancel(id) end
end
local function schedule(fn)
   if after then return after(0, fn) end
   fn()
   return nil
end


local function surface_unhandled(label, err)
   if echo then
      echo("\27[90m[promise] " .. tostring(label or "?") .. " rejected" ..
      (err ~= nil and (": " .. tostring(err)) or "") .. " (unhandled)\27[0m")
   end
end




local function normalize(x)
   if x == nil then return nil end
   if is_promise(x) then
      local xp = x
      cancel_timer(xp.__start_timer); xp.__start_timer = nil
      return function() return xp end
   elseif type(x) == "function" then
      return x
   elseif type(x) == "string" then
      local cmd = x
      return function() if send then send(cmd) end end
   else
      return function() end
   end
end






local live = setmetatable({}, { __mode = "k" })



local function cancel_all()
   local snapshot = {}
   for p in pairs(live) do snapshot[#snapshot + 1] = p end
   for _, p in ipairs(snapshot) do p.cancel() end
   return #snapshot
end







local tracked = setmetatable({}, { __mode = "k" })
local seq = 0
local function track(p, desc)
   if p then tracked[p] = true; if desc then p._track_desc = desc end end
end
local function untrack(p)
   if p then tracked[p] = nil end
end








local function name_chain(tail, desc)
   local p = tail
   while p do untrack(p); p = p._parent end
   track(tail, desc)
   return tail
end









local function active_promises()
   local out = {}
   for p in pairs(tracked) do
      if p.state == "cold" or p.state == "running" then
         out[#out + 1] = { desc = p._track_desc or p.label or "?", state = p.state, seq = p._seq or 0 }
      end
   end
   table.sort(out, function(a, b) return a.seq < b.seq end)
   return out
end




local function current_promise()
   local best = nil
   for p in pairs(tracked) do
      if (p.state == "cold" or p.state == "running") and (not best or (p._seq or 0) > (best._seq or 0)) then
         best = p
      end
   end
   return best
end







local function pop_tail(tail)
   if not tail then return nil end
   local parent = tail._parent
   if parent and parent._handlers then
      local hs = parent._handlers
      for i = #hs, 1, -1 do if hs[i].result == tail then table.remove(hs, i) end end
   end
   tail._parent = nil
   tail.cancel()
   untrack(tail)
   return parent
end




local function make(executor, label)
   local p = { __is_promise = true, state = "cold", label = label,
_handlers = {}, _had_consumer = false, }
   live[p] = true
   seq = seq + 1; p._seq = seq







   local function run_handler(fn, reason, result, is_err)
      if not fn then


         if result then if is_err then result.__reject(reason) else result.__resolve(reason) end end
         return
      end
      local ok, ret = pcall(fn, reason)
      if not ok then if result then result.__reject(ret) end; return end
      if not result then return end
      if is_promise(ret) then
         local retp = ret
         cancel_timer(retp.__start_timer); retp.__start_timer = nil
         untrack(retp)
         retp._parent = result; result._adopted = retp
         retp._attach(function(v) result.__resolve(v) end, function(e) result.__reject(e) end)
         retp.__start()
      else
         result.__resolve(ret)
      end
   end

   local function dispatch(h)
      if h.finally then
         if p.state ~= "cancelled" then h.finally(p.state == "failed", p.err) end
         return
      end
      if p.state == "done" then run_handler(h.onOk, p.value, h.result, false)
      elseif p.state == "failed" then run_handler(h.onErr, p.err, h.result, true) end
   end

   local function settle(newstate, err, value)
      if p.state ~= "cold" and p.state ~= "running" then return end
      p.state, p.err, p.value = newstate, err, value
      live[p] = nil
      local hs = p._handlers; p._handlers = {}
      for _, h in ipairs(hs) do dispatch(h) end
      if newstate == "failed" then
         schedule(function() if not p._had_consumer then surface_unhandled(p.label, err) end end)
      end
   end

   p.__resolve = function(value) settle("done", nil, value) end
   p.__reject = function(err) settle("failed", err) end

   p.__start = function()
      cancel_timer(p.__start_timer); p.__start_timer = nil
      if p.state ~= "cold" then return end
      p.state = "running"
      local function onCancel(hook) p._on_cancel = hook; return p.state == "cancelled" end
      local ok, err = pcall(executor, p.__resolve, p.__reject, onCancel)
      if not ok then p.__reject(err) end
   end


   p._attach = function(onOk, onErr)
      p._had_consumer = true
      local h = { onOk = onOk, onErr = onErr }
      if p.state == "cold" or p.state == "running" then p._handlers[#p._handlers + 1] = h else dispatch(h) end
   end


   local function attach_result(mk)
      p._had_consumer = true
      local result = make(function() end, label)
      result._parent = p
      local h = mk(result)
      if p.state == "cold" or p.state == "running" then p._handlers[#p._handlers + 1] = h else dispatch(h) end
      return result
   end

   p.andThen = function(...)
      local a, b, c = ...
      local onOk, onErr
      if a == p then onOk, onErr = b, c else onOk, onErr = a, b end
      onOk, onErr = normalize(onOk), normalize(onErr)
      return attach_result(function(result) return { onOk = onOk, onErr = onErr, result = result } end)
   end

   p.catch = function(...)
      local a, b = ...
      return p.andThen(nil, (a == p) and b or a)
   end

   p.finally = function(...)
      local a, b = ...
      local fn = (a == p) and b or a
      return attach_result(function(result)
         return { finally = function(...)
            local is_err, reason = ...
            local ok, e = pcall(fn)
            if not ok then result.__reject(e)
            elseif is_err then result.__reject(reason)
            else result.__resolve(nil) end
         end, }
      end)
   end

   p.timeout = function(...)
      local a, b, c = ...
      local secs, why
      if a == p then secs, why = b, c else secs, why = a, b end
      local result = make(function() end, label)
      result._parent = p
      p._attach(function(v) cancel_timer(result._timeout_timer); result.__resolve(v) end,
      function(e) cancel_timer(result._timeout_timer); result.__reject(e) end)
      result._timeout_timer = after and after(secs, function()
         result._timeout_timer = nil
         if result.state == "cold" or result.state == "running" then
            result.__reject(why or ("timed out after " .. tostring(secs) .. "s"))
            p.cancel()
         end
      end) or nil
      return result
   end

   p.cancel = function()
      if p.state ~= "cold" and p.state ~= "running" then return end
      p.state = "cancelled"
      live[p] = nil
      cancel_timer(p.__start_timer); p.__start_timer = nil
      cancel_timer(p._timeout_timer); p._timeout_timer = nil
      if p._on_cancel then pcall(p._on_cancel) end
      local hs = p._handlers; p._handlers = {}
      for _, h in ipairs(hs) do if h.result then h.result.cancel() end end
      if p._adopted then p._adopted.cancel() end
      if p._parent then p._parent.cancel() end
   end

   return p
end




local function builder(executor, label)
   local p = make(executor, label)
   p.__start_timer = after and after(0, function() p.__start_timer = nil; p.__start() end) or nil
   track(p, nil)
   return p
end



local function __promise_impl(executor, label)
   return builder(executor, label)
end
__promise = __promise_impl




function cancelPromises()
   local n = cancel_all()
   if echo then
      echo("[promise] cancelled " .. n .. " in-flight promise" .. (n == 1 and "" or "s") .. ".")
   end
   return n
end
doc("cancelPromises", { sig = "cancelPromises() -> count", group = "combat",
text = "Abort EVERY in-flight promise chain (recover/attack/goto, `|` pipe sequences, timeouts) and " ..
"run each one's cancel hook so its action is undone — stand up from recovery, disarm auto-fight, " ..
"drop a queued send. Returns how many promises were cancelled.",
example = "#cancelPromises()", })




_G.active_promises = active_promises
_G.__track_promise = track
_G.__untrack_promise = untrack
_G.__current_promise = current_promise
_G.__name_chain = name_chain
_G.__pop_tail = pop_tail




doc("active_promises", { sig = "active_promises() -> { {desc, state}, ... }", group = "combat",
text = "The in-flight promises for the HUD widget, oldest first: each is { desc, state } where desc " ..
"is the typed pipe line (e.g. \"recover | explore\") or the action's label, and state is " ..
"\"cold\"/\"running\". Settled/cancelled promises drop off.", })

_PROMISE_TEST = { make = make, builder = builder, normalize = normalize, is_promise = is_promise,
live = live, cancel_all = cancel_all,
active = active_promises, track = track, untrack = untrack, current = current_promise,
pop_tail = pop_tail, }
