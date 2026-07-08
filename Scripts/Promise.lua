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

local function is_promise(x) return type(x) == "table" and x.__is_promise == true end
local function cancel_timer(id) if id and cancel then cancel(id) end end
local function schedule(fn) if after then return after(0, fn) else fn() end end

-- Surface an unhandled rejection as a dim warning — the "why did my chain stop?" fix.
local function surface_unhandled(label, err)
  if echo then
    echo("\27[90m[promise] " .. tostring(label or "?") .. " rejected"
      .. (err ~= nil and (": " .. tostring(err)) or "") .. " (unhandled)\27[0m")
  end
end

-- Normalize an andThen argument into a handler function, or nil. A PROMISE becomes a thunk returning it
-- (and its pending auto-start is cancelled — it's a continuation now, not a chain head); a STRING becomes
-- a send(); a function is used as-is (onErr receives the rejection reason, onOk ignores its arg).
local function normalize(x)
  if x == nil then return nil end
  if is_promise(x) then
    cancel_timer(x.__start_timer); x.__start_timer = nil
    return function() return x end
  elseif type(x) == "function" then
    return x
  elseif type(x) == "string" then
    local cmd = x
    return function() if send then send(cmd) end end
  else
    return function() end
  end
end

-- Registry of not-yet-settled promises so cancelPromises() can abort every in-flight chain at once
-- (running each promise's cancel hook — recover stands you up, attack disarms auto-fight, a pipe
-- segment's pending send is dropped). Weak KEYS so a promise that's otherwise unreferenced can still be
-- collected; entries are also cleared eagerly the moment a promise settles or is cancelled, so the table
-- reflects only genuinely live promises.
local live = setmetatable({}, { __mode = "k" })

-- Cancel every currently-live promise. Snapshots the set first, because cancel() clears `live` entries
-- (and cascades to parents/children) as it runs. Returns how many promise objects were cancelled.
local function cancel_all()
  local snapshot = {}
  for p in pairs(live) do snapshot[#snapshot + 1] = p end
  for _, p in ipairs(snapshot) do p.cancel() end
  return #snapshot
end

-- Core constructor (no auto-start). `builder` (below) wraps this to add the next-tick auto-start that
-- makes a bare `recover(95)` run on its own; result promises from andThen/finally/timeout use `make`
-- directly and are driven by their parent, never a timer.
local function make(executor, label)
  local p = { __is_promise = true, state = "cold", label = label,
              _handlers = {}, _had_consumer = false }
  live[p] = true                                                    -- track until it settles/cancels

  local run_handler   -- fwd

  local function dispatch(h)
    if h.finally then
      if p.state ~= "cancelled" then h.finally(p.state == "failed", p.err) end
      return
    end
    if p.state == "done" then run_handler(h.onOk, nil, h.result, false)
    elseif p.state == "failed" then run_handler(h.onErr, p.err, h.result, true) end
  end

  -- Run one side of an andThen handler and settle its result promise:
  --   no handler   → pass the outcome straight through to the result;
  --   handler ok   → result resolves, adopting a promise the handler returned (so it follows that);
  --   handler threw → result rejects with the error.
  run_handler = function(fn, reason, result, is_err)
    if not fn then
      if result then if is_err then result.__reject(reason) else result.__resolve() end end
      return
    end
    local ok, ret = pcall(fn, reason)
    if not ok then if result then result.__reject(ret) end; return end
    if not result then return end
    if is_promise(ret) then
      cancel_timer(ret.__start_timer); ret.__start_timer = nil
      ret._parent = result; result._adopted = ret
      ret._attach(function() result.__resolve() end, function(e) result.__reject(e) end)
      ret.__start()
    else
      result.__resolve()
    end
  end

  local function settle(newstate, err)
    if p.state ~= "cold" and p.state ~= "running" then return end   -- settle-once (incl. after cancel)
    p.state, p.err = newstate, err
    live[p] = nil                                                   -- settled → no longer in-flight
    local hs = p._handlers; p._handlers = {}
    for _, h in ipairs(hs) do dispatch(h) end
    if newstate == "failed" then
      schedule(function() if not p._had_consumer then surface_unhandled(p.label, err) end end)
    end
  end

  p.__resolve = function() settle("done") end
  p.__reject  = function(err) settle("failed", err) end

  p.__start = function()
    cancel_timer(p.__start_timer); p.__start_timer = nil
    if p.state ~= "cold" then return end
    p.state = "running"
    local function onCancel(hook) p._on_cancel = hook; return p.state == "cancelled" end
    local ok, err = pcall(executor, p.__resolve, p.__reject, onCancel)
    if not ok then p.__reject(err) end
  end

  -- Low-level attach used by adoption/timeout: raw resolve/reject callbacks, no result promise.
  p._attach = function(onOk, onErr)
    p._had_consumer = true
    local h = { onOk = onOk, onErr = onErr }
    if p.state == "cold" or p.state == "running" then p._handlers[#p._handlers + 1] = h else dispatch(h) end
  end

  -- Attach a handler that produces a result promise (andThen/finally). `mk(result)` builds the handler.
  local function attach_result(mk)
    p._had_consumer = true
    local result = make(function() end, label)   -- inherits label so surfaced messages read naturally
    result._parent = p
    local h = mk(result)
    if p.state == "cold" or p.state == "running" then p._handlers[#p._handlers + 1] = h else dispatch(h) end
    return result
  end

  p.andThen = function(a, b, c)
    local onOk, onErr
    if a == p then onOk, onErr = b, c else onOk, onErr = a, b end   -- colon-call shift
    onOk, onErr = normalize(onOk), normalize(onErr)
    return attach_result(function(result) return { onOk = onOk, onErr = onErr, result = result } end)
  end

  p.catch = function(a, b) return p.andThen(nil, (a == p) and b or a) end

  p.finally = function(a, b)
    local fn = (a == p) and b or a
    return attach_result(function(result)
      return { finally = function(is_err, reason)
        local ok, e = pcall(fn)
        if not ok then result.__reject(e)
        elseif is_err then result.__reject(reason)
        else result.__resolve() end
      end }
    end)
  end

  p.timeout = function(a, b, c)
    local secs, why
    if a == p then secs, why = b, c else secs, why = a, b end
    local result = make(function() end, label)
    result._parent = p
    p._attach(function() cancel_timer(result._timeout_timer); result.__resolve() end,
              function(e) cancel_timer(result._timeout_timer); result.__reject(e) end)
    result._timeout_timer = after and after(secs, function()
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
    if p._parent then p._parent.cancel() end                        -- upstream: the source we consume
  end

  return p
end

-- Builder: a promise that auto-starts on the next tick unless adopted as a continuation first.
local function builder(executor, label)
  local p = make(executor, label)
  p.__start_timer = after and after(0, function() p.__start_timer = nil; p.__start() end) or nil
  return p
end

-- Exposed as a global so the game-layer builders (recover/attack) can wrap their actions. `__`-prefixed
-- => internal by convention (doc-exempt); the user-facing surface is recover()/attack()/.andThen/etc.
__promise = builder

-- cancelPromises() — abort every in-flight promise at once. Each one's cancel hook runs, so the action
-- is UNDONE: recover stands you up, attack disarms auto-fight, a queued pipe segment's send is dropped.
-- The panic button for "stop whatever the chain is doing." Returns how many promises were cancelled.
function cancelPromises()
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

_PROMISE_TEST = { make = make, builder = builder, normalize = normalize, is_promise = is_promise,
                  live = live, cancel_all = cancel_all }
