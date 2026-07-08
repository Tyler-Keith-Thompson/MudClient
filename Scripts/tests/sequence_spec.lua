-- Specs for the promise/sequencing layer (Scripts/Sequence.lua) and its two builders: recover([pct])
-- (AlterAeon.lua) and attack(target) (AutoFight.lua).
--
-- The CLI harness's `after` stub records callbacks but NEVER fires them (there's no event loop), so
-- auto-start never happens on its own — every promise here is started explicitly with __start(). That's
-- exactly what we want: fully deterministic control over when each link runs.

local new_promise = _SEQ_TEST.new_promise
local coerce      = _SEQ_TEST.coerce

-- A promise whose settle we hold, so the test decides when it resolves/rejects.
local function deferred(log, tag)
  local ctl = {}
  local p = new_promise(function(resolve, reject)
    if log then log[#log + 1] = "start:" .. tag end
    ctl.resolve, ctl.reject = resolve, reject
  end, tag)
  ctl.promise = p
  return ctl
end

test("andThen runs the next action only after the previous one resolves", function()
  local log = {}
  local a = deferred(log, "a")
  local b = deferred(log, "b")
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

test("a rejection stops the chain — downstream links never start", function()
  local log = {}
  local a = deferred(log, "a")
  local b = deferred(log, "b")
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
  local a = deferred(nil, "a")
  local inner = deferred(nil, "inner")
  local tail = a.promise
    .andThen(function() ran[#ran + 1] = "fn1"; return inner.promise end)  -- returns a promise → adopt
    .andThen(function() ran[#ran + 1] = "fn2" end)
  a.promise.__start()
  a.resolve()                            -- runs fn1, which returns inner (now running), tail waits on inner
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
  local a = deferred(nil, "a")
  a.promise.andThen("kill orc")
  a.promise.__start()
  a.resolve()
  send = saved_send
  expect(#sent):eq(1)
  expect(sent[1]):eq("kill orc")
end)

test("andThen works with colon-call syntax too (self shifted off)", function()
  local a = deferred(nil, "a")
  local hit = {}
  a.promise:andThen(function() hit[#hit + 1] = "x" end)   -- colon passes self as arg 1
  a.promise.__start()
  a.resolve()
  expect(table.concat(hit, ",")):eq("x")
end)

test("coerce cancels a linked promise's pending auto-start (only the head auto-runs)", function()
  -- Build with a live `after` so a start timer id is assigned, then confirm coerce cancels it.
  local saved_after, saved_cancel = after, cancel
  local timers, cancelled = {}, {}
  after  = function(_d, cb) local id = #timers + 1; timers[id] = cb; return id end
  cancel = function(id) cancelled[id] = true end
  local a = new_promise(function() end, "a")             -- schedules auto-start id=1
  local b = new_promise(function() end, "b")             -- schedules auto-start id=2
  expect(b.__start_timer):eq(2)
  a.andThen(b)                                            -- b becomes a link → its auto-start cancelled
  after, cancel = saved_after, saved_cancel
  expect(cancelled[2]):truthy()                           -- b's timer cancelled
  expect(cancelled[1]):falsy()                            -- a (the head) keeps its auto-start
  expect(b.__start_timer):eq(nil)
end)

-- ---- recover([pct]) builder -----------------------------------------------------------------------

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
    -- Not yet at 95%: no completion.
    state.hp, state.mana, state.stam = 94, 94, 94
    expect(_AA_TEST.maybe_complete_recovery()):falsy()
    expect(done):falsy()
    -- Reach 95%: completes, resolves, and the chain runs.
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
    expect(p.state):eq("done")               -- resolved in the executor
    expect(state.recover):falsy()            -- never started resting
  end)
end)

test("interrupting recovery (end_recovery false) rejects the promise and stops the chain", function()
  with_recover_state(function()
    local ran = false
    local p = recover(95)
    p.andThen(function() ran = true end)
    p.__start()
    expect(state.recover):truthy()
    _AA_TEST.end_recovery(false, "moved")    -- e.g. you walked out of the room
    expect(p.state):eq("failed")
    expect(p.err):eq("moved")
    expect(ran):falsy()
  end)
end)
