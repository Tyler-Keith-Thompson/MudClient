-- Tiny promise layer so asynchronous game actions chain readably:
--
--     recover(95).andThen(attack('orc')).andThen(recover())
--
-- An "action builder" (recover/attack, defined in their game files) returns a PROMISE. A promise
-- resolves when its action finishes (recovery reaches the target %, the target dies) and rejects with a
-- reason if it's interrupted (you move mid-rest, the opener can't be cast).
--
-- API (all methods work with BOTH dot and colon call — `p.andThen(x)` and `p:andThen(x)` both work):
--   p.andThen(onOk [, onErr])  run onOk on resolve; onErr(reason) on reject. onOk may be a function, a
--                              PROMISE (run it next — this is the chaining case), or a STRING (send it).
--                              Returns a NEW promise for the result, so chains compose.
--   p.catch(onErr)             react to a rejection; == andThen(nil, onErr). Returning normally RECOVERS
--                              the chain (the result resolves).
--   p.finally(fn)              run fn on resolve OR reject (not on cancel); passes the outcome through.
--   p.timeout(seconds[, why])  reject the result if p hasn't settled in `seconds`, and CANCEL p (so its
--                              action is aborted + undone). Safety net against a hung action.
--   p.cancel()                 abort a pending/running chain. Runs each promise's cancel hook (undo its
--                              side effect) and propagates both ways along the chain.
--
-- UNHANDLED REJECTIONS ARE SURFACED: if a promise rejects and nothing ever chained onto it (no
-- andThen/catch/finally/timeout), we echo a dim "[promise] <label> rejected: <reason> (unhandled)" on
-- the next tick. This is the fix for the silent-stall footgun — before, `recover(95).andThen(attack())`
-- interrupted mid-rest just stopped with zero feedback; now you see why.
--
-- CANCELLATION HOOKS: a builder's executor gets a third arg, onCancel(hook). Register a hook to UNDO the
-- action if the promise is cancelled (recover → stand up; attack → autofight.off()). Cancel propagates
-- up to the source and down to the continuation, so cancelling any node aborts the whole linear chain.
-- (Chains here are single-consumer; upstream cancel doesn't ref-count sibling consumers.)
--
-- WHY `.andThen` AND NOT `.then`: `then` is a reserved Lua keyword (it closes `if <cond> then`), so the
-- lexer never treats it as a field name — `p.then` is a syntax error, exactly like `p.end`. `andThen`
-- is an ordinary identifier. (The literal word survives only as a string index, `p["then"]`.)
--
-- COLD-BY-DEFAULT, AUTO-START ONCE: building a promise does NOT run its action immediately — it
-- schedules a next-tick auto-start (after(0)). Writing `recover(95).andThen(attack('orc'))` builds BOTH
-- promises (both schedule an auto-start) before `.andThen` runs; `.andThen` ADOPTS `attack('orc')` as
-- the continuation and CANCELS its pending auto-start, so only the head (recover) fires next tick and
-- attack stays cold until recovery resolves. A builder called alone — `#attack('orc')` — just runs.
--
-- Hot-reloadable, pure-Lua, no host support beyond after()/cancel()/echo/send. Tested in promise_spec.lua.
--
-- TEAL NOTE: mud.d.tl's `Promise<T>` only declares the public surface (andThen/catch/finally/timeout/
-- cancel) — the typed contract consumers (DCast.tl etc) cast to/from at the boundary (`as Promise<T>`).
-- The RUNTIME object needs a lot more (state/label/_handlers/__start/…), so this file works against a
-- local structural record, `Prom`, that's the actual shape, and casts to `Promise<any>` only where the
-- declared global surface requires it. Methods stay CLOSURES assigned per-instance at construction (not
-- a shared metatable `__index`) exactly like the Lua — Teal generic methods don't survive `__index`
-- dispatch across differing `T`, and the closure shape maps directly with no restructuring needed.

-- global test seam (matches _AA_TEST/_AIP_TEST/etc's declare-inline-in-the-defining-script convention)
global _PROMISE_TEST: {string:any}

-- Callback-shaped fields (onOk/onErr/finally, and the andThen/catch/finally/timeout methods themselves)
-- are typed permissively (`...: any` / `any...`), matching the `function(...: any): any...` convention
-- foundation.d.tl already uses for trigger/alias/on_* handlers: the dot/colon dual-call shift and the
-- "handler may or may not return a value" adoption logic are genuinely dynamic, not statically trackable.
local record Handler
   onOk:    function(...: any): any...
   onErr:   function(...: any): any...
   result:  Prom
   finally: function(...: any): any...
end

local record Prom
   __is_promise:   boolean
   state:          string
   label:          string
   value:          any
   err:            any
   _handlers:      {Handler}
   _had_consumer:  boolean
   _parent:        Prom
   _adopted:       Prom
   _track_desc:    string
   _seq:           integer
   __start_timer:  integer
   _timeout_timer: integer
   _on_cancel:     function()
   __resolve:      function(any)
   __reject:       function(any)
   __start:        function()
   _attach:        function(function(...: any): any..., function(...: any): any...)
   andThen:        function(...: any): Prom
   catch:          function(...: any): Prom
   finally:        function(...: any): Prom
   timeout:        function(...: any): Prom
   cancel:         function()
end

local function is_promise(x: any): boolean
   return type(x) == "table" and (x as Prom).__is_promise == true
end
local function cancel_timer(id: integer)
   if id and cancel then cancel(id) end
end
local function schedule(fn: function()): integer
   if after then return after(0, fn) end
   fn()
   return nil
end

-- Surface an unhandled rejection as a dim warning — the "why did my chain stop?" fix.
local function surface_unhandled(label: string, err: any)
   if echo then
      echo("\27[90m[promise] " .. tostring(label or "?") .. " rejected"
         .. (err ~= nil and (": " .. tostring(err)) or "") .. " (unhandled)\27[0m")
   end
end

-- Normalize an andThen argument into a handler function, or nil. A PROMISE becomes a thunk returning it
-- (and its pending auto-start is cancelled — it's a continuation now, not a chain head); a STRING becomes
-- a send(); a function is used as-is (onErr receives the rejection reason, onOk ignores its arg).
local function normalize(x: any): any
   if x == nil then return nil end
   if is_promise(x) then
      local xp = x as Prom
      cancel_timer(xp.__start_timer); xp.__start_timer = nil
      return function(): any return xp end
   elseif type(x) == "function" then
      return x
   elseif type(x) == "string" then
      local cmd = x as string
      return function(): any if send then send(cmd) end end
   else
      return function(): any end
   end
end

-- Registry of not-yet-settled promises so cancelPromises() can abort every in-flight chain at once
-- (running each promise's cancel hook — recover stands you up, attack disarms auto-fight, a pipe
-- segment's pending send is dropped). Weak KEYS so a promise that's otherwise unreferenced can still be
-- collected; entries are also cleared eagerly the moment a promise settles or is cancelled, so the table
-- reflects only genuinely live promises.
local live: {Prom:boolean} = setmetatable({}, { __mode = "k" })

-- Cancel every currently-live promise. Snapshots the set first, because cancel() clears `live` entries
-- (and cascades to parents/children) as it runs. Returns how many promise objects were cancelled.
local function cancel_all(): integer
   local snapshot: {Prom} = {}
   for p in pairs(live) do snapshot[#snapshot + 1] = p end
   for _, p in ipairs(snapshot) do p.cancel() end
   return #snapshot
end

-- DISPLAY registry — the promises a HUD widget should show as one row each. Distinct from `live`: we
-- want ONE row per user action, not every internal result/continuation. A builder auto-registers (so a
-- bare recover()/attack() shows by its label); a promise is DE-registered the moment it's adopted as
-- someone's continuation (it's now part of a chain, not its own row); and a pipe registers its final
-- chain promise under the typed line (e.g. "recover | explore") after de-registering the head — so the
-- whole chain shows as that one line for its entire life. Weak keys so nothing leaks.
local tracked: {Prom:boolean} = setmetatable({}, { __mode = "k" })
local seq = 0                                        -- creation order, for a stable widget row order
local function track(p: Prom, desc: string)
   if p then tracked[p] = true; if desc then p._track_desc = desc end end
end
local function untrack(p: Prom)
   if p then tracked[p] = nil end
end

local record ActiveEntry
   desc:  string
   state: string
   seq:   integer
end

-- The in-flight tracked promises, oldest first, as { desc, state }. `desc` is the pipe line if set, else
-- the promise's label. Only cold/running (i.e. genuinely pending) entries — settled/cancelled drop off.
local function active_promises(): {ActiveEntry}
   local out: {ActiveEntry} = {}
   for p in pairs(tracked) do
      if p.state == "cold" or p.state == "running" then
         out[#out + 1] = { desc = p._track_desc or p.label or "?", state = p.state, seq = p._seq or 0 }
      end
   end
   table.sort(out, function(a: ActiveEntry, b: ActiveEntry): boolean return a.seq < b.seq end)
   return out
end

-- The "current" in-flight promise: the most-recently-created still-pending tracked one. This is what
-- `+| <cmd>` appends onto — e.g. after `recover`, `+| explore` grafts explore onto the recovery. Returns
-- the promise OBJECT (or nil if nothing's pending), plus its display desc.
local function current_promise(): Prom
   local best: Prom = nil
   for p in pairs(tracked) do
      if (p.state == "cold" or p.state == "running") and (not best or (p._seq or 0) > (best._seq or 0)) then
         best = p
      end
   end
   return best
end

-- Pop the TAIL segment off a chain (the `-|` operator, inverse of `+|`). Detach the last continuation
-- from its parent so an unstarted last segment never runs, and cancel the tail itself — running its
-- action's cancel hook if the segment already STARTED (e.g. `attack` → autofight.off()) — WITHOUT the
-- usual upstream cascade, so the earlier segments keep running. cancel() climbs `_parent`, so we sever
-- the tail's parent link first. Returns the new tail (the parent), or nil when `tail` had no parent (it
-- WAS the whole chain, so it's simply cancelled). No-op-safe on nil.
local function pop_tail(tail: Prom): Prom
   if not tail then return nil end
   local parent = tail._parent
   if parent and parent._handlers then                 -- drop the handler that spawns this tail (if parent
      local hs = parent._handlers                        -- is still pending; once it settles _handlers is
      for i = #hs, 1, -1 do if hs[i].result == tail then table.remove(hs, i) end end  -- already cleared)
   end
   tail._parent = nil                                   -- sever upstream so cancel() can't climb the chain
   tail.cancel()                                         -- cancel just this segment (+ its running hook)
   untrack(tail)
   return parent
end

-- Core constructor (no auto-start). `builder` (below) wraps this to add the next-tick auto-start that
-- makes a bare `recover(95)` run on its own; result promises from andThen/finally/timeout use `make`
-- directly and are driven by their parent, never a timer.
local function make(executor: function(function(any), function(any), function(function()): boolean): any..., label: string): Prom
   local p: Prom = { __is_promise = true, state = "cold", label = label,
                      _handlers = {}, _had_consumer = false }
   live[p] = true                                                    -- track until it settles/cancels
   seq = seq + 1; p._seq = seq                                       -- creation order (widget row order)

   -- Run one side of an andThen handler and settle its result promise:
   --   no handler   → pass the outcome straight through to the result;
   --   handler ok   → result resolves, adopting a promise the handler returned (so it follows that);
   --   handler threw → result rejects with the error.
   -- (Ordered before `dispatch`, which calls it — the Lua's forward `local run_handler` declaration isn't
   -- needed here since nothing above this point references it; purely a reordering, same single scope.)
   local function run_handler(fn: function(...: any): any..., reason: any, result: Prom, is_err: boolean)
      if not fn then
         -- no handler on this side: pass the outcome straight through — the incoming VALUE on the ok side,
         -- the reason on the error side — so a value survives chain nodes that only handle the other side.
         if result then if is_err then result.__reject(reason) else result.__resolve(reason) end end
         return
      end
      local ok, ret = pcall(fn, reason)
      if not ok then if result then result.__reject(ret) end; return end
      if not result then return end
      if is_promise(ret) then
         local retp = ret as Prom
         cancel_timer(retp.__start_timer); retp.__start_timer = nil
         untrack(retp)                                   -- it's a continuation now, not its own widget row
         retp._parent = result; result._adopted = retp
         retp._attach(function(v: any) result.__resolve(v) end, function(e: any) result.__reject(e) end)
         retp.__start()
      else
         result.__resolve(ret)                           -- a handler's plain RETURN becomes the chain's value
      end
   end

   local function dispatch(h: Handler)
      if h.finally then
         if p.state ~= "cancelled" then h.finally(p.state == "failed", p.err) end
         return
      end
      if p.state == "done" then run_handler(h.onOk, p.value, h.result, false)
      elseif p.state == "failed" then run_handler(h.onErr, p.err, h.result, true) end
   end

   local function settle(newstate: string, err: any, value?: any)
      if p.state ~= "cold" and p.state ~= "running" then return end   -- settle-once (incl. after cancel)
      p.state, p.err, p.value = newstate, err, value
      live[p] = nil                                                   -- settled → no longer in-flight
      local hs = p._handlers; p._handlers = {}
      for _, h in ipairs(hs) do dispatch(h) end
      if newstate == "failed" then
         schedule(function() if not p._had_consumer then surface_unhandled(p.label, err) end end)
      end
   end

   p.__resolve = function(value: any) settle("done", nil, value) end
   p.__reject  = function(err: any) settle("failed", err) end

   p.__start = function()
      cancel_timer(p.__start_timer); p.__start_timer = nil
      if p.state ~= "cold" then return end
      p.state = "running"
      local function onCancel(hook: function()): boolean p._on_cancel = hook; return p.state == "cancelled" end
      local ok, err = pcall(executor, p.__resolve, p.__reject, onCancel)
      if not ok then p.__reject(err) end
   end

   -- Low-level attach used by adoption/timeout: raw resolve/reject callbacks, no result promise.
   p._attach = function(onOk: function(...: any): any..., onErr: function(...: any): any...)
      p._had_consumer = true
      local h: Handler = { onOk = onOk, onErr = onErr }
      if p.state == "cold" or p.state == "running" then p._handlers[#p._handlers + 1] = h else dispatch(h) end
   end

   -- Attach a handler that produces a result promise (andThen/finally). `mk(result)` builds the handler.
   local function attach_result(mk: function(Prom): Handler): Prom
      p._had_consumer = true
      local result = make(function() end, label)   -- inherits label so surfaced messages read naturally
      result._parent = p
      local h = mk(result)
      if p.state == "cold" or p.state == "running" then p._handlers[#p._handlers + 1] = h else dispatch(h) end
      return result
   end

   p.andThen = function(...: any): Prom
      local a, b, c = ...
      local onOk, onErr: any, any
      if a == p then onOk, onErr = b, c else onOk, onErr = a, b end   -- colon-call shift
      onOk, onErr = normalize(onOk), normalize(onErr)
      return attach_result(function(result: Prom): Handler return { onOk = onOk as function(...: any): any..., onErr = onErr as function(...: any): any..., result = result } end)
   end

   p.catch = function(...: any): Prom
      local a, b = ...
      return p.andThen(nil, (a == p) and b or a)
   end

   p.finally = function(...: any): Prom
      local a, b = ...
      local fn = (a == p) and b or a
      return attach_result(function(result: Prom): Handler
         return { finally = function(...: any): any...
            local is_err, reason = ...
            local ok, e = pcall(fn as function(): any)
            if not ok then result.__reject(e)
            elseif is_err then result.__reject(reason)
            else result.__resolve(nil) end
         end }
      end)
   end

   p.timeout = function(...: any): Prom
      local a, b, c = ...
      local secs, why: any, any
      if a == p then secs, why = b, c else secs, why = a, b end
      local result = make(function() end, label)
      result._parent = p
      p._attach(function(v: any) cancel_timer(result._timeout_timer); result.__resolve(v) end,
                function(e: any) cancel_timer(result._timeout_timer); result.__reject(e) end)
      result._timeout_timer = after and after(secs as number, function()
         result._timeout_timer = nil
         if result.state == "cold" or result.state == "running" then
            result.__reject(why or ("timed out after " .. tostring(secs) .. "s"))
            p.cancel()   -- abort the hung action + run its cancel hook
         end
      end) or nil
      return result
   end

   p.cancel = function()
      if p.state ~= "cold" and p.state ~= "running" then return end   -- terminal → no-op
      p.state = "cancelled"
      live[p] = nil
      cancel_timer(p.__start_timer); p.__start_timer = nil
      cancel_timer(p._timeout_timer); p._timeout_timer = nil
      if p._on_cancel then pcall(p._on_cancel) end                    -- UNDO the side effect
      local hs = p._handlers; p._handlers = {}
      for _, h in ipairs(hs) do if h.result then h.result.cancel() end end  -- downstream: pending results
      if p._adopted then p._adopted.cancel() end                      -- downstream: an adopted continuation
      if p._parent then p._parent.cancel() end                       -- upstream: the source we consume
   end

   return p
end

-- Builder: a promise that auto-starts on the next tick unless adopted as a continuation first. It's a
-- top-level action (recover/attack/…), so it auto-registers for the promise widget under its label; a
-- pipe/adoption de-registers it if it turns out to be part of a larger chain.
local function builder(executor: function(function(any), function(any), function(function()): boolean): any..., label: string): Prom
   local p = make(executor, label)
   p.__start_timer = after and after(0, function() p.__start_timer = nil; p.__start() end) or nil
   track(p, nil)
   return p
end

-- Exposed as a global so the game-layer builders (recover/attack) can wrap their actions. `__`-prefixed
-- => internal by convention (doc-exempt); the user-facing surface is recover()/attack()/.andThen/etc.
local function __promise_impl(executor: function(function(any), function(string), function(function())): any..., label: string): Promise<any>
   return builder(executor as (function(function(any), function(any), function(function()): boolean): any...), label) as Promise<any>
end
__promise = __promise_impl

-- cancelPromises() — abort every in-flight promise at once. Each one's cancel hook runs, so the action
-- is UNDONE: recover stands you up, attack disarms auto-fight, a queued pipe segment's send is dropped.
-- The panic button for "stop whatever the chain is doing." Returns how many promises were cancelled.
function cancelPromises(): integer
   local n = cancel_all()
   if echo then
      echo("[promise] cancelled " .. n .. " in-flight promise" .. (n == 1 and "" or "s") .. ".")
   end
   return n
end
doc("cancelPromises", { sig = "cancelPromises() -> count", group = "combat",
   text = "Abort EVERY in-flight promise chain (recover/attack/goto, `|` pipe sequences, timeouts) and "
       .. "run each one's cancel hook so its action is undone — stand up from recovery, disarm auto-fight, "
       .. "drop a queued send. Returns how many promises were cancelled.",
   example = "#cancelPromises()" })

-- Promise-widget surface. `active_promises()` (global, like active_opponents) feeds the HUD row list.
-- __track_promise/__untrack_promise let the pipe layer (bootstrap) name a whole chain as one row and
-- drop the head it superseded. `__`-prefixed => internal/doc-exempt; active_promises is documented.
_G.active_promises = active_promises as function(): {any}    -- _G. is REQUIRED: `active_promises` is a
_G.__track_promise    = track as function(any)                -- local here, so a bare assignment would
_G.__untrack_promise  = untrack as function(Promise<any>)     -- just rebind the local, never create the
_G.__current_promise  = current_promise as function(): any    -- global the HUD/pipe look up. (This was
_G.__pop_tail         = pop_tail as function(): any            -- the "widget never shows" bug.) The casts
                                                                -- bridge to foundation.d.tl's declared
                                                                -- (looser) global signatures; see file-top
                                                                -- Teal note — same reason DCast/AutoFight
                                                                -- cast at the Promise<T> boundary.
doc("active_promises", { sig = "active_promises() -> { {desc, state}, ... }", group = "combat",
   text = "The in-flight promises for the HUD widget, oldest first: each is { desc, state } where desc "
       .. "is the typed pipe line (e.g. \"recover | explore\") or the action's label, and state is "
       .. "\"cold\"/\"running\". Settled/cancelled promises drop off." })

_PROMISE_TEST = { make = make, builder = builder, normalize = normalize, is_promise = is_promise,
                  live = live, cancel_all = cancel_all,
                  active = active_promises, track = track, untrack = untrack, current = current_promise,
                  pop_tail = pop_tail }
