-- Specs for the promise layer (Scripts/Promise.lua) and its two builders: recover([pct])
-- (AlterAeon.lua) and attack(target) (AutoFight.lua).
--
-- The CLI harness's `after` stub records callbacks but NEVER fires them (there's no event loop), so
-- auto-start never happens on its own — every promise here is started explicitly with __start(). That's
-- exactly what we want: fully deterministic control over when each link runs. Tests that need a timer or
-- the next-tick unhandled-rejection check to actually FIRE override `after` locally.

local make       = _PROMISE_TEST.make       -- core ctor (no auto-start) — used for controllable promises
local builder    = _PROMISE_TEST.builder    -- auto-starting ctor (what __promise is)

-- A promise whose settle we hold, so the test decides when it resolves/rejects. Its cancel hook flips
-- `cancelled` so we can assert the undo ran.
local function deferred(tag, log)
  local ctl = { cancelled = false }
  ctl.promise = make(function(resolve, reject, onCancel)
    if log then log[#log + 1] = "start:" .. tag end
    ctl.resolve, ctl.reject = resolve, reject
    onCancel(function() ctl.cancelled = true end)
  end, tag)
  return ctl
end

-- ---- chaining ------------------------------------------------------------------------------------

test("andThen runs the next action only after the previous one resolves", function()
  local log = {}
  local a = deferred("a", log)
  local b = deferred("b", log)
  a.promise.andThen(b.promise)
  a.promise.__start()                    -- head starts; b must stay cold
  expect(a.promise.state):eq("running")
  expect(b.promise.state):eq("cold")
  a.resolve()                            -- a done → b starts
  expect(a.promise.state):eq("done")
  expect(b.promise.state):eq("running")
  b.resolve()
  expect(b.promise.state):eq("done")
  expect(table.concat(log, ",")):eq("start:a,start:b")
end)

test("a rejection stops the success chain — the continuation never starts", function()
  local log = {}
  local a = deferred("a", log)
  local b = deferred("b", log)
  a.promise.andThen(b.promise)
  a.promise.__start()
  a.reject("boom")
  expect(a.promise.state):eq("failed")
  expect(a.promise.err):eq("boom")
  expect(b.promise.state):eq("cold")           -- never started
  expect(table.concat(log, ",")):eq("start:a") -- b's executor never ran
end)

test("andThen accepts a function continuation and adopts a promise it returns", function()
  local ran = {}
  local a = deferred("a")
  local inner = deferred("inner")
  local tail = a.promise
    .andThen(function() ran[#ran + 1] = "fn1"; return inner.promise end)  -- returns a promise → adopt
    .andThen(function() ran[#ran + 1] = "fn2" end)
  a.promise.__start()
  a.resolve()                            -- runs fn1, which returns inner (now running); tail waits on inner
  expect(table.concat(ran, ",")):eq("fn1")
  expect(inner.promise.state):eq("running")
  inner.resolve()                        -- inner done → fn2 runs
  expect(table.concat(ran, ",")):eq("fn1,fn2")
  expect(tail.state):eq("done")
end)

test("andThen accepts a string continuation and send()s it", function()
  local saved_send = send
  local sent = {}
  send = function(c) sent[#sent + 1] = c end
  local a = deferred("a")
  a.promise.andThen("kill orc")
  a.promise.__start()
  a.resolve()
  send = saved_send
  expect(#sent):eq(1)
  expect(sent[1]):eq("kill orc")
end)

test("andThen works with colon-call syntax too (self shifted off)", function()
  local a = deferred("a")
  local hit = {}
  a.promise:andThen(function() hit[#hit + 1] = "x" end)   -- colon passes self as arg 1
  a.promise.__start()
  a.resolve()
  expect(table.concat(hit, ",")):eq("x")
end)

test("adopting a promise as a continuation cancels its pending auto-start (only the head auto-runs)", function()
  local saved_after, saved_cancel = after, cancel
  local n, cancelled = 0, {}
  after  = function() n = n + 1; return n end
  cancel = function(id) cancelled[id] = true end
  local a = builder(function() end, "a")     -- schedules auto-start id=1
  local b = builder(function() end, "b")     -- schedules auto-start id=2
  expect(b.__start_timer):eq(2)
  a.andThen(b)                               -- b becomes a continuation → its auto-start cancelled
  after, cancel = saved_after, saved_cancel
  expect(cancelled[2]):truthy()
  expect(cancelled[1]):falsy()               -- head keeps its auto-start
  expect(b.__start_timer):eq(nil)
end)

-- ---- catch ---------------------------------------------------------------------------------------

test("andThen(onOk, onErr): onErr runs with the reason and recovers the chain", function()
  local a = deferred("a")
  local got
  local res = a.promise.andThen(function() got = "ok" end, function(e) got = "err:" .. e end)
  a.promise.__start()
  a.reject("nope")
  expect(got):eq("err:nope")
  expect(res.state):eq("done")           -- onErr returned normally → result RECOVERS
end)

test("catch handles a rejection and lets the chain continue", function()
  local a = deferred("a")
  local seen, after_ran = nil, false
  a.promise.catch(function(e) seen = e end).andThen(function() after_ran = true end)
  a.promise.__start()
  a.reject("boom")
  expect(seen):eq("boom")
  expect(after_ran):truthy()
end)

-- ---- finally -------------------------------------------------------------------------------------

test("finally runs on resolve and passes the success through", function()
  local a = deferred("a")
  local fin, after_ok = false, false
  a.promise.finally(function() fin = true end).andThen(function() after_ok = true end)
  a.promise.__start(); a.resolve()
  expect(fin):truthy()
  expect(after_ok):truthy()
end)

test("finally runs on reject and passes the rejection through", function()
  local a = deferred("a")
  local fin = false
  local res = a.promise.finally(function() fin = true end)
  res.catch(function() end)              -- observe so it isn't flagged unhandled
  a.promise.__start(); a.reject("x")
  expect(fin):truthy()
  expect(res.state):eq("failed")
  expect(res.err):eq("x")
end)

-- ---- timeout -------------------------------------------------------------------------------------

test("timeout rejects the result and CANCELS the source (aborting its action) when it fires", function()
  local saved_after, saved_cancel = after, cancel
  local timers = {}
  after  = function(d, cb) timers[#timers + 1] = { d = d, cb = cb }; return #timers end
  cancel = function() end
  local d = deferred("slow")
  local t = d.promise.timeout(5, "too slow")
  d.promise.__start()
  for _, tm in ipairs(timers) do if tm.d == 5 then tm.cb() end end   -- fire the timeout timer
  after, cancel = saved_after, saved_cancel
  expect(t.state):eq("failed")
  expect(t.err):eq("too slow")
  expect(d.promise.state):eq("cancelled")   -- source aborted
  expect(d.cancelled):truthy()              -- source's cancel hook ran (undo)
end)

test("timeout does NOT fire if the source settles first", function()
  local saved_after, saved_cancel = after, cancel
  local timers, cancelled = {}, {}
  after  = function(d, cb) timers[#timers + 1] = { d = d, cb = cb }; return #timers end
  cancel = function(id) cancelled[id] = true end
  local d = deferred("quick")
  local t = d.promise.timeout(5)
  d.promise.__start()
  d.resolve()                                -- settles before the timer
  after, cancel = saved_after, saved_cancel
  expect(t.state):eq("done")
  expect(next(cancelled) ~= nil):truthy()    -- the timeout timer was cancelled
end)

-- ---- cancel --------------------------------------------------------------------------------------

test("cancel runs the promise's cancel hook (undo) exactly once and is idempotent", function()
  local d = deferred("a")
  d.promise.__start()                        -- running, hook registered
  d.promise.cancel()
  expect(d.promise.state):eq("cancelled")
  expect(d.cancelled):truthy()
  d.cancelled = false
  d.promise.cancel()                         -- terminal → no-op
  expect(d.cancelled):falsy()
end)

test("cancel propagates to an already-adopted continuation (whole chain aborts)", function()
  local a = deferred("a")
  local b = deferred("b")
  local tail = a.promise.andThen(b.promise)
  a.promise.__start()
  a.resolve()                                -- b adopted + started
  expect(b.promise.state):eq("running")
  tail.cancel()                              -- cancel the tail
  expect(tail.state):eq("cancelled")
  expect(b.promise.state):eq("cancelled")    -- the running continuation was aborted…
  expect(b.cancelled):truthy()               -- …and its undo ran
end)

test("cancelling the head leaves an un-started continuation inert, and cancels the result", function()
  local a = deferred("a")
  local b = deferred("b")
  local tail = a.promise.andThen(b.promise)
  a.promise.__start()                        -- a running; b cold (its auto-start was cancelled at andThen)
  a.promise.cancel()                         -- cancel the head
  expect(a.promise.state):eq("cancelled")
  expect(a.cancelled):truthy()               -- head's undo ran
  expect(tail.state):eq("cancelled")         -- the downstream result promise was cancelled
  expect(b.promise.state):eq("cold")         -- continuation never adopted → never ran, nothing to undo
  expect(b.cancelled):falsy()
end)

-- ---- unhandled-rejection surfacing ---------------------------------------------------------------

test("an unhandled rejection is surfaced (echoed) on the next tick", function()
  local saved_after, saved_echo = after, echo
  after = function(_d, cb) cb() end          -- fire the next-tick check synchronously
  local msgs = {}
  echo = function(s) msgs[#msgs + 1] = s end
  local rej
  local p = make(function(_, reject) rej = reject end, "recover")
  p.__start()
  rej("moved")                               -- nothing chained onto p → should surface
  after, echo = saved_after, saved_echo
  expect(#msgs):eq(1)
  expect(msgs[1]:find("recover", 1, true) ~= nil):truthy()
  expect(msgs[1]:find("moved", 1, true) ~= nil):truthy()
end)

test("a rejection with a handler is NOT surfaced", function()
  local saved_after, saved_echo = after, echo
  after = function(_d, cb) cb() end
  local msgs = {}
  echo = function(s) msgs[#msgs + 1] = s end
  local rej
  local p = make(function(_, reject) rej = reject end, "recover")
  p.catch(function() end)                    -- a consumer → handled
  p.__start()
  rej("moved")
  after, echo = saved_after, saved_echo
  expect(#msgs):eq(0)
end)

-- ---- recover([pct]) builder ----------------------------------------------------------------------

local function with_recover_state(fn)
  local saved = state
  state = { hp = 50, maxhp = 100, mana = 50, maxmana = 100, stam = 50, maxstam = 100,
            position = "standing", recover = false }
  local saved_send = send
  send = function(c) if c == "rest" or c == "sleep" then state.position = "sitting" end end
  local ok, err = pcall(fn)
  send, state = saved_send, saved
  _AA_TEST.recovery.settle, _AA_TEST.recovery.pct = nil, _AA_TEST.READY_PCT   -- leave the controller clean
  if not ok then error(err, 2) end
end

test("recover(pct) resolves when vitals reach the target, and stands you up", function()
  with_recover_state(function()
    local done = false
    local p = recover(95)
    p.andThen(function() done = true end)
    p.__start()                              -- executor: not ready → begins recovery
    expect(state.recover):truthy()
    expect(_AA_TEST.recovery.pct):eq(0.95)
    state.hp, state.mana, state.stam = 94, 94, 94
    expect(_AA_TEST.maybe_complete_recovery()):falsy()
    expect(done):falsy()
    state.hp, state.mana, state.stam = 95, 95, 95
    expect(_AA_TEST.maybe_complete_recovery()):truthy()
    expect(state.recover):falsy()
    expect(p.state):eq("done")
    expect(done):truthy()
  end)
end)

test("recover accepts a fraction (0.9) and a percent (90) alike; default is 90%", function()
  with_recover_state(function()
    recover(0.9).__start();  expect(_AA_TEST.recovery.pct):eq(0.90); _AA_TEST.end_recovery(false)
    recover(90).__start();   expect(_AA_TEST.recovery.pct):eq(0.90); _AA_TEST.end_recovery(false)
    recover().__start();     expect(_AA_TEST.recovery.pct):eq(0.90); _AA_TEST.end_recovery(false)
  end)
end)

test("recover resolves immediately (no rest) when already at the target", function()
  with_recover_state(function()
    state.hp, state.mana, state.stam = 100, 100, 100
    local p = recover(95)
    p.__start()
    expect(p.state):eq("done")
    expect(state.recover):falsy()
  end)
end)

test("interrupting recovery (end_recovery false) rejects the promise and stops the chain", function()
  with_recover_state(function()
    local ran = false
    local p = recover(95)
    p.andThen(function() ran = true end)
    p.__start()
    expect(state.recover):truthy()
    _AA_TEST.end_recovery(false, "moved")
    expect(p.state):eq("failed")
    expect(p.err):eq("moved")
    expect(ran):falsy()
  end)
end)

test("cancelling a recover in progress stands you up and clears the flag (undo hook)", function()
  with_recover_state(function()
    local p = recover(95)
    p.__start()
    expect(state.recover):truthy()
    p.cancel()
    expect(p.state):eq("cancelled")
    expect(state.recover):falsy()            -- cancel hook cleared it
    expect(_AA_TEST.recovery.settle):eq(nil) -- and dropped the settlers
  end)
end)

-- ---- cancelPromises() (global panic button) ------------------------------------------------------

test("cancel_all cancels every live promise and runs each one's cancel hook", function()
  local a = deferred("cancel-a")
  local b = deferred("cancel-b")
  a.promise.__start(); b.promise.__start()          -- both running and registered as live
  expect(a.promise.state):eq("running")
  expect(b.promise.state):eq("running")
  local n = _PROMISE_TEST.cancel_all()
  expect(n >= 2):eq(true)                            -- (>= : other specs may leave live promises around)
  expect(a.promise.state):eq("cancelled")
  expect(b.promise.state):eq("cancelled")
  expect(a.cancelled):eq(true)                       -- undo hook ran
  expect(b.cancelled):eq(true)
end)

test("a settled promise is not re-cancelled by cancel_all (left the registry)", function()
  local a = deferred("settled")
  a.promise.__start()
  a.resolve()
  expect(a.promise.state):eq("done")
  expect(_PROMISE_TEST.live[a.promise]):eq(nil)      -- deregistered on settle
  _PROMISE_TEST.cancel_all()
  expect(a.promise.state):eq("done")                 -- still done, not flipped to cancelled
end)

-- ---- promise widget registry (active_promises) ---------------------------------------------------

local active = _PROMISE_TEST.active

local function widget_has(desc)
  for _, e in ipairs(active()) do if e.desc == desc then return e end end
  return nil
end

test("a builder shows in the widget under its label while pending, and drops off when it settles", function()
  local b = builder(function() end, "wtest-run")
  b.__start()
  expect(widget_has("wtest-run") ~= nil):eq(true)
  expect(widget_has("wtest-run").state):eq("running")
  b.__resolve()
  expect(widget_has("wtest-run") == nil):eq(true)   -- settled → no longer pending → gone
end)

test("untrack removes a promise from the widget (used when a chain supersedes a head)", function()
  local b = builder(function() end, "wtest-untrack"); b.__start()
  expect(widget_has("wtest-untrack") ~= nil):eq(true)
  _PROMISE_TEST.untrack(b)
  expect(widget_has("wtest-untrack") == nil):eq(true)
end)

test("a cancelled promise drops off the widget", function()
  local b = builder(function(_, _, onCancel) end, "wtest-cancel"); b.__start()
  expect(widget_has("wtest-cancel") ~= nil):eq(true)
  b.cancel()
  expect(widget_has("wtest-cancel") == nil):eq(true)
end)

test("active_promises is a GLOBAL (the HUD widget looks it up by that name)", function()
  expect(type(active_promises)):eq("function")       -- bare global lookup — nil if the export regressed
  expect(type(__track_promise)):eq("function")
end)

test("a second recover() supersedes the first (old promise rejects, doesn't dangle)", function()
  with_recover_state(function()
    local a = recover(90); a.__start()          -- first recovery in progress
    expect(state.recover):truthy()
    local a_err
    a.catch(function(e) a_err = e end)
    local b = recover(95); b.__start()          -- second recover() takes over the singleton recovery
    expect(a.state):eq("failed")                -- old one settled (not left pending)
    expect(a_err):eq("superseded")
    expect(b.state):eq("running")               -- the new one owns the recovery now
    expect(_AA_TEST.recovery.pct):eq(0.95)
  end)
end)
