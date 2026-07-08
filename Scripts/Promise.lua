-- Tiny promise layer so asynchronous game actions chain readably:
--
--     recover(95).andThen(attack('orc')).andThen(recover())
--
-- An "action builder" (recover/attack, defined in their game files) returns a PROMISE. A promise
-- resolves when its action finishes (recovery reaches the target %, the target dies) and rejects if it
-- is interrupted (you move mid-rest, the opener can't be cast). `.andThen(next)` runs `next` only once
-- the upstream promise resolves; a rejection stops the chain (nothing downstream runs).
--
-- WHY `.andThen` AND NOT `.then`: `then` is a reserved Lua keyword (it closes `if <cond> then`), so the
-- lexer never treats it as a field name — `p.then` is a syntax error, exactly like `p.end`. `andThen`
-- is an ordinary identifier, so `p.andThen(x)` parses fine. (The literal word survives only as a string
-- index, `p["then"]`, which is ugly — hence `andThen`.)
--
-- COLD-BY-DEFAULT, AUTO-START ONCE: building a promise does NOT run its action immediately. Instead it
-- schedules a next-tick auto-start (after(0)). When you write `recover(95).andThen(attack('orc'))` on
-- one line, BOTH promises get built (and both schedule an auto-start) before `.andThen` runs — all
-- synchronously. `.andThen` then ADOPTS `attack('orc')` as a downstream link and CANCELS its pending
-- auto-start, so only the head (recover) actually fires next tick; attack stays cold until recovery
-- resolves. Call a builder alone — `#attack('orc')` — and nothing cancels its auto-start, so it just
-- runs next tick. This is what lets the ergonomic inline form work without any explicit "start" call.
--
-- Hot-reloadable, pure-Lua, no host support beyond after()/cancel(). Tested in Scripts/tests/promise_spec.lua.

local function is_promise(x) return type(x) == "table" and x.__is_promise == true end

local coerce   -- fwd (new_promise.andThen -> coerce -> new_promise for function/string continuations)

-- Build a cold promise around `executor(resolve, reject)`. The executor starts the action and is
-- responsible for eventually calling resolve() (done) or reject(err) (failed) — synchronously for a
-- trivial action, or later from a trigger/timer for a real async one.
local function new_promise(executor, label)
  local p = { __is_promise = true, state = "cold", label = label }

  local function settle(ok, err)
    if p.state == "done" or p.state == "failed" then return end   -- settle-once
    p.state, p.err = (ok and "done" or "failed"), err
    if ok and p._next then p._next.__start() end                  -- resolve -> run the continuation
  end

  p.__resolve = function() settle(true) end
  p.__reject  = function(err) settle(false, err) end

  -- Run the action. Idempotent: only a cold promise starts (a second call — e.g. the auto-start timer
  -- firing after an explicit start — is a no-op). A throwing executor rejects rather than propagating.
  p.__start = function()
    if p.__start_timer then cancel(p.__start_timer); p.__start_timer = nil end
    if p.state ~= "cold" then return end
    p.state = "running"
    local ok, err = pcall(executor, p.__resolve, p.__reject)
    if not ok then p.__reject(err) end
  end

  -- andThen(next): link a continuation and return the tail so links keep chaining. Accepts a promise, a
  -- function (run when reached; if it returns a promise, we adopt that promise's completion), or a
  -- string (send() it, resolve immediately). Works with BOTH dot and colon call syntax: if invoked as
  -- `p:andThen(x)` the runtime passes p as arg 1, so we shift it off.
  p.andThen = function(a, b)
    local next_thing = (a == p) and b or a
    local np = coerce(next_thing)
    p._next = np
    if p.state == "done" then np.__start() end     -- already resolved before we chained: start now
    return np
  end

  -- Schedule the one-shot auto-start; adoption by an upstream andThen() cancels it (see coerce).
  p.__start_timer = after and after(0, function() p.__start_timer = nil; p.__start() end) or nil
  return p
end

-- Normalize whatever andThen() was handed into a cold promise ready to be linked.
coerce = function(x)
  if is_promise(x) then
    -- It's becoming a downstream link, not a chain head: cancel the auto-start it scheduled at build.
    if x.__start_timer then cancel(x.__start_timer); x.__start_timer = nil end
    return x
  elseif type(x) == "function" then
    return new_promise(function(resolve, reject)
      local r = x()
      if is_promise(r) then
        r.andThen(function() resolve() end)   -- adopt: we finish when the returned promise finishes
        r.__start()                           -- ...and make sure it actually runs
      else
        resolve()
      end
    end, "fn")
  elseif type(x) == "string" then
    local cmd = x
    return new_promise(function(resolve) if send then send(cmd) end; resolve() end, "send:" .. x)
  else
    -- Nothing useful to chain: a no-op that resolves at once, so the rest of the chain still runs.
    return new_promise(function(resolve) resolve() end, "noop")
  end
end

-- Exposed as a global so the game-layer builders (recover/attack) can wrap their actions. `__`-prefixed
-- => internal by convention (doc-exempt); the user-facing surface is recover()/attack()/.andThen.
__promise = new_promise

_PROMISE_TEST = { new_promise = new_promise, is_promise = is_promise, coerce = coerce }
