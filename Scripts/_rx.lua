-- _rx.lua — a small, modern reactive core (Observables) for the game scripts. Home-grown (rxlua is
-- Lua-5.1-era and 2300 lines); this is Lua 5.4, ~1 file, and carries only the operators the MUD logic
-- actually uses. It pairs with Promise.lua: PROMISES sequence a one-shot flow (opener → probe → nuke),
-- OBSERVABLES model the never-ending streams of game events (health ticks, spell-landed lines, combat
-- start/end) that the reactive logic composes and subscribes to.
--
--   local rx = __rx
--   local spellLanded = rx.fromTrigger([[^You .* at (.+)!$]])          -- a hot stream of matches
--   spellLanded:map(function(c) return c[1] end)                        -- capture 1 = the target
--             :filter(function(t) return t ~= "" end)
--             :subscribe(function(target) --[[ react ]] end)
--   rx.fromTrigger([[^kxw[tq]_fighting (\d+)]]):first():toPromise()        -- await the next event, to chain
--
-- Everything is pure Lua over the host primitives already present: `trigger`/`rule_remove` (the event
-- source), `after`/`cancel` (time), `__promise` (the promise bridge). Hot-reloadable; `_`-prefixed so
-- `load("Scripts")` never auto-runs it — consumers pull it with `require("_rx")` (dofile fallback in the
-- bare test harness). Tested in Scripts/tests/rx_spec.lua.

local unpack = table.unpack

-- ---- Subscription -------------------------------------------------------------------------------
-- A handle to teardown work. `unsubscribe()` runs the teardown ONCE (idempotent) and marks it closed.
local Subscription = {}
Subscription.__index = Subscription

local function new_subscription(teardown)
  return setmetatable({ _teardown = teardown, closed = false }, Subscription)
end

function Subscription:unsubscribe()
  if self.closed then return end
  self.closed = true
  if self._teardown then pcall(self._teardown) end
end

local CLOSED = new_subscription(nil); CLOSED.closed = true   -- shared no-op for terminal observers

-- ---- Observer -----------------------------------------------------------------------------------
-- Normalize (onNext[, onError, onCompleted]) OR an observer table into a safe observer whose callbacks
-- never fire after it terminates (onError/onCompleted are final).
local function to_observer(a, b, c)
  local o
  if type(a) == "table" and (a.onNext or a.onError or a.onCompleted) then
    o = { onNext = a.onNext, onError = a.onError, onCompleted = a.onCompleted }
  else
    o = { onNext = a, onError = b, onCompleted = c }
  end
  o.done = false
  local raw = o
  return {
    onNext = function(...) if not raw.done and raw.onNext then raw.onNext(...) end end,
    onError = function(e) if not raw.done then raw.done = true; if raw.onError then raw.onError(e) end end end,
    onCompleted = function() if not raw.done then raw.done = true; if raw.onCompleted then raw.onCompleted() end end end,
    _raw = raw,
  }
end

-- ---- Observable ---------------------------------------------------------------------------------
local Observable = {}
Observable.__index = Observable

-- create(onSubscribe): onSubscribe(observer) does the work and returns a teardown function (or a
-- Subscription, or nil). subscribe() wraps it so terminal signals auto-unsubscribe.
function Observable.create(onSubscribe)
  return setmetatable({ _subscribe = onSubscribe }, Observable)
end

function Observable:subscribe(a, b, c)
  local observer = to_observer(a, b, c)
  local sub
  -- Terminal signals dispose the subscription so operators clean up their sources.
  local base_next, base_err, base_comp = observer.onNext, observer.onError, observer.onCompleted
  observer.onError = function(e) base_err(e); if sub then sub:unsubscribe() end end
  observer.onCompleted = function() base_comp(); if sub then sub:unsubscribe() end end
  observer.onNext = base_next
  local teardown = self._subscribe(observer)
  if getmetatable(teardown) == Subscription then
    sub = teardown
  else
    sub = new_subscription(type(teardown) == "function" and teardown or nil)
  end
  return sub
end

-- ---- Constructors -------------------------------------------------------------------------------
function Observable.of(...)
  local values = { ... }
  return Observable.create(function(observer)
    for _, v in ipairs(values) do observer.onNext(v) end
    observer.onCompleted()
  end)
end

function Observable.empty() return Observable.create(function(o) o.onCompleted() end) end
function Observable.never() return Observable.create(function() end) end
function Observable.throw(e) return Observable.create(function(o) o.onError(e) end) end

-- ---- Operators (each returns a NEW Observable) --------------------------------------------------
function Observable:map(f)
  return Observable.create(function(observer)
    return self:subscribe(function(...) observer.onNext(f(...)) end, observer.onError, observer.onCompleted)
  end)
end

function Observable:filter(pred)
  return Observable.create(function(observer)
    return self:subscribe(function(...) if pred(...) then observer.onNext(...) end end,
                          observer.onError, observer.onCompleted)
  end)
end

function Observable:tap(f)
  return Observable.create(function(observer)
    return self:subscribe(function(...) f(...); observer.onNext(...) end, observer.onError, observer.onCompleted)
  end)
end

function Observable:take(n)
  return Observable.create(function(observer)
    if n <= 0 then observer.onCompleted(); return end
    local left = n
    return self:subscribe(function(...)
      if left <= 0 then return end
      left = left - 1
      observer.onNext(...)
      if left == 0 then observer.onCompleted() end
    end, observer.onError, observer.onCompleted)
  end)
end

function Observable:skip(n)
  return Observable.create(function(observer)
    local left = n
    return self:subscribe(function(...)
      if left > 0 then left = left - 1 else observer.onNext(...) end
    end, observer.onError, observer.onCompleted)
  end)
end

-- first([pred]): emit the first (matching) value then complete. Completes with an error if the source
-- ends without one — so :toPromise() rejects on "stream closed, never saw it".
function Observable:first(pred)
  return Observable.create(function(observer)
    return self:subscribe(function(...)
      if pred == nil or pred(...) then observer.onNext(...); observer.onCompleted() end
    end, observer.onError, function() observer.onError("no first value") end)
  end)
end

function Observable:distinctUntilChanged(eq)
  eq = eq or function(a, b) return a == b end
  return Observable.create(function(observer)
    local have, last = false, nil
    return self:subscribe(function(v)
      if not have or not eq(last, v) then have, last = true, v; observer.onNext(v) end
    end, observer.onError, observer.onCompleted)
  end)
end

function Observable:scan(accumulator, seed)
  return Observable.create(function(observer)
    local acc = seed
    return self:subscribe(function(v) acc = accumulator(acc, v); observer.onNext(acc) end,
                          observer.onError, observer.onCompleted)
  end)
end

function Observable:startWith(...)
  local seeds = { ... }
  return Observable.create(function(observer)
    for _, v in ipairs(seeds) do observer.onNext(v) end
    return self:subscribe(observer.onNext, observer.onError, observer.onCompleted)
  end)
end

-- takeUntil(notifier): mirror source until `notifier` emits once, then complete.
function Observable:takeUntil(notifier)
  return Observable.create(function(observer)
    local stop
    local src = self:subscribe(observer.onNext, observer.onError, observer.onCompleted)
    stop = notifier:subscribe(function() observer.onCompleted(); if stop then stop:unsubscribe() end end)
    return function() src:unsubscribe(); if stop then stop:unsubscribe() end end
  end)
end

-- switchMap(project): for each source value, subscribe to project(v); a new value UNSUBSCRIBES the
-- previous inner (the "switch"). The workhorse for "on each combat start, run this inner flow".
function Observable:switchMap(project)
  return Observable.create(function(observer)
    local inner
    local outer = self:subscribe(function(...)
      if inner then inner:unsubscribe() end
      inner = project(...):subscribe(observer.onNext, observer.onError)   -- inner completion doesn't end outer
    end, observer.onError, function() if not inner then observer.onCompleted() end end)
    return function() outer:unsubscribe(); if inner then inner:unsubscribe() end end
  end)
end

-- merge(...): interleave observables; completes when ALL have completed. `merge_all` is the private
-- implementation so both the static `Observable.merge(a,b)` and the instance `a:merge(b)` delegate to it
-- (defining a `:merge` colon method would otherwise OVERWRITE the dot form into an infinite tail-call).
local function merge_all(...)
  local sources = { ... }
  return Observable.create(function(observer)
    local remaining = #sources
    local subs = {}
    for _, s in ipairs(sources) do
      subs[#subs + 1] = s:subscribe(observer.onNext, observer.onError, function()
        remaining = remaining - 1
        if remaining == 0 then observer.onCompleted() end
      end)
    end
    return function() for _, sub in ipairs(subs) do sub:unsubscribe() end end
  end)
end
Observable.merge = merge_all
function Observable:merge(...) return merge_all(self, ...) end

-- delay(seconds): shift each emission later via after(); teardown cancels pending timers.
function Observable:delay(seconds)
  return Observable.create(function(observer)
    local timers = {}
    local src = self:subscribe(function(...)
      local args = { ... }
      local id; id = after and after(seconds, function() timers[id] = nil; observer.onNext(unpack(args)) end)
      if id then timers[id] = true end
    end, observer.onError, observer.onCompleted)
    return function() src:unsubscribe(); for id in pairs(timers) do if cancel then cancel(id) end end end
  end)
end

-- ---- Subject: a hot, multicast Observable you push into ------------------------------------------
local Subject = setmetatable({}, { __index = Observable })
Subject.__index = Subject

function Subject.new()
  local s = setmetatable({ observers = {}, closed = false }, Subject)
  return s
end

function Subject:subscribe(a, b, c)
  if self.closed then return CLOSED end
  local observer = to_observer(a, b, c)
  self.observers[observer] = true
  return new_subscription(function() self.observers[observer] = nil end)
end

function Subject:onNext(...)
  if self.closed then return end
  -- Snapshot before dispatch: a synchronous subscriber may subscribe/unsubscribe mid-emit (e.g. a
  -- promise resolving off this stream then subscribing the next stage), which mutates `observers` — and
  -- iterating a table with `pairs()` while it's mutated errors ("invalid key to 'next'"). Iterate a copy
  -- and re-check membership so an observer unsubscribed mid-dispatch doesn't still receive this value.
  local snapshot = {}
  for o in pairs(self.observers) do snapshot[#snapshot + 1] = o end
  for _, o in ipairs(snapshot) do
    if self.observers[o] then o.onNext(...) end
  end
end
function Subject:onError(e)
  if self.closed then return end
  self.closed = true
  local os = self.observers; self.observers = {}
  for o in pairs(os) do o.onError(e) end
end
function Subject:onCompleted()
  if self.closed then return end
  self.closed = true
  local os = self.observers; self.observers = {}
  for o in pairs(os) do o.onCompleted() end
end
function Subject:count() local n = 0; for _ in pairs(self.observers) do n = n + 1 end; return n end
-- Expose as a plain Observable so callers can't push into a stream they only mean to read.
function Subject:asObservable()
  return Observable.create(function(observer) return self:subscribe(observer) end)
end

-- ---- Bridge: game trigger -> Observable ---------------------------------------------------------
-- A REFCOUNTED hot stream of a trigger's matches. The `trigger()` is registered on the FIRST subscribe
-- and `rule_remove`d on the LAST unsubscribe, so an unused stream costs nothing. Each match emits a
-- `caps` table: caps[1..N] = the regex capture groups, caps.line = the full matched line. By default the
-- line still displays (handler returns nil); pass `{gag=true}` to hide it, or `{opts=…}` to forward
-- trigger options (class/priority).
function Observable.fromTrigger(pattern, opts)
  opts = opts or {}
  local subject = Subject.new()
  local id
  local function ensure()
    if id or not trigger then return end
    id = trigger(pattern, function(line, ...)
      local caps = { line = line, ... }
      subject:onNext(caps)
      if opts.gag then return false end
    end, opts.opts)
  end
  local function release()
    if subject:count() == 0 and id and rule_remove then rule_remove(id); id = nil end
  end
  return Observable.create(function(observer)
    ensure()
    local sub = subject:subscribe(observer)
    return function() sub:unsubscribe(); release() end
  end)
end

-- ---- Bridge: Observable <-> Promise -------------------------------------------------------------
-- toPromise([why]): a Promise that resolves with this observable's FIRST value and rejects on error /
-- empty completion. Cancelling the promise unsubscribes (stops listening). Use `:first(pred):toPromise()`
-- to await a specific event as one step of a promise chain.
function Observable:toPromise(why)
  if not __promise then error("_rx:toPromise needs Promise.lua (__promise) loaded") end
  local source = self
  return __promise(function(resolve, reject, onCancel)
    local sub = source:subscribe(
      function(...) resolve(...) end,
      function(e) reject(e) end,
      function() reject(why or "completed with no value") end)
    onCancel(function() sub:unsubscribe() end)
  end, "rx")
end

-- fromPromise(p): a one-value Observable that emits the promise's resolution then completes (or errors).
function Observable.fromPromise(p)
  return Observable.create(function(observer)
    p.andThen(function(...) observer.onNext(...); observer.onCompleted() end,
              function(e) observer.onError(e) end)
    return function() if p.cancel then p.cancel() end end
  end)
end

-- ---- Export -------------------------------------------------------------------------------------
__rx = {
  Observable = Observable,
  Subject = Subject,
  of = Observable.of,
  empty = Observable.empty,
  never = Observable.never,
  throw = Observable.throw,
  merge = Observable.merge,
  fromTrigger = Observable.fromTrigger,
  fromPromise = Observable.fromPromise,
  subject = Subject.new,
}

_RX_TEST = { Observable = Observable, Subject = Subject, to_observer = to_observer,
             new_subscription = new_subscription }

return __rx
