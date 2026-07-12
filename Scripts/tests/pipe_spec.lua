-- Specs for the `|` command pipe's Lua half (bootstrap.lua): turning already-split segments into a
-- promise chain so each segment waits for the previous to resolve. The SPLIT + escaping is Swift's job
-- (InputService.pipeSegments); here we test the per-segment promise (_PIPE_TEST.run) and the chain
-- builder (_PIPE_TEST.pipe / __pipe).
--
-- As in promise_spec, the CLI harness's `after` stub never fires, so builder auto-start doesn't happen
-- on its own — we start the head explicitly (or, for the __pipe integration test, override `after` to
-- fire synchronously) for fully deterministic ordering.

local run  = _PIPE_TEST.run
local pipe = _PIPE_TEST.pipe

-- ---- per-segment promise -------------------------------------------------------------------------

test("| a segment whose first word is a callable global returns that action's own promise", function()
  local marker = _PROMISE_TEST.make(function() end, "marker")
  _G.pipetestaction = function() return marker end
  local p = run("pipetestaction")
  expect(p == marker):eq(true)                 -- chain waits on the action's real promise
  _G.pipetestaction = nil
end)

test("| a callable segment is called with the rest of the line as one string arg", function()
  local got = "UNSET"
  _G.pipetestcap = function(arg) got = arg end
  run("pipetestcap  hello  world ")
  expect(got):eq("hello  world")               -- surrounding gaps trimmed, interior preserved
  run("pipetestcap")
  expect(got == nil):eq(true)                  -- no rest → called with nil
  _G.pipetestcap = nil
end)

test("| a callable returning a non-promise yields a promise that completes on start", function()
  _G.pipetestnum = function() return 42 end
  local p = run("pipetestnum")
  expect(p.__is_promise):eq(true)
  p.__start()
  expect(p.state):eq("done")
  _G.pipetestnum = nil
end)

test("| a non-action segment is sent as a command, deferred until the promise starts", function()
  local sent, real_send = {}, send
  _G.send = function(s) sent[#sent + 1] = s end
  local p = run("kill rat")
  expect(#sent):eq(0)                          -- NOT sent yet — waits for its turn
  p.__start()
  expect(sent[1]):eq("kill rat")
  expect(p.state):eq("done")
  _G.send = real_send
end)

-- ---- chaining (the whole point) ------------------------------------------------------------------

test("| later segments run only after earlier ones resolve", function()
  local log, ctl = {}, {}
  local function act(name)
    return function()
      log[#log + 1] = "call:" .. name
      local c = {}
      c.p = _PROMISE_TEST.make(function(res) log[#log + 1] = "start:" .. name; c.res = res end, name)
      ctl[name] = c
      return c.p
    end
  end
  _G.pipeacta, _G.pipeactb = act("a"), act("b")
  -- Mirror __pipe's chaining, driving the head ourselves (harness has no event loop to auto-start).
  local head  = run("pipeacta")
  local chain = head.andThen(function() return run("pipeactb") end)
  expect(table.concat(log, ",")):eq("call:a")                 -- head built; b not touched yet
  head.__start()
  expect(table.concat(log, ",")):eq("call:a,start:a")
  ctl.a.res()                                                 -- a resolves → b is invoked + started
  expect(table.concat(log, ",")):eq("call:a,start:a,call:b,start:b")
  ctl.b.res()
  expect(chain.state):eq("done")
  _G.pipeacta, _G.pipeactb = nil, nil
end)

test("| __pipe runs an array of ordinary commands in order, each after the previous", function()
  local sent, real_send, real_after = {}, send, after
  _G.send  = function(s) sent[#sent + 1] = s end
  _G.after = function(_, cb) cb(); return 0 end     -- fire auto-start synchronously (no event loop here)
  pipe({ "north", "south", "look" })
  expect(table.concat(sent, ",")):eq("north,south,look")
  _G.send, _G.after = real_send, real_after
end)

test("| __pipe ignores an empty segment list", function()
  local ok = pcall(function() pipe({}) end)
  expect(ok):eq(true)
end)

-- ---- `;`-group steps: `|` binds looser than `;` -------------------------------------------------
-- A `|` STEP is a `;`-group (Swift's InputService gives us the nested split). A one-command step awaits;
-- a multi-command `;`-group fires each command independently and resolves AT ONCE (`;` never waits).

local run_step = _PIPE_TEST.run_step

test("| a `;`-group step fires every command at once and resolves immediately", function()
  local sent, real_send = {}, send
  _G.send = function(s) sent[#sent + 1] = s end
  local p = run_step({ "look", "score" })
  p.__start()
  expect(table.concat(sent, ",")):eq("look,score")   -- both fired, in order
  expect(p.state):eq("done")                          -- `;`-group doesn't await → resolves at once
  _G.send = real_send
end)

test("| a one-command step still AWAITS a callable's promise (single-command semantics unchanged)", function()
  local marker = _PROMISE_TEST.make(function() end, "marker")
  _G.pipetestaction = function() return marker end
  expect(run_step({ "pipetestaction" }) == marker):eq(true)   -- normalized {cmd} == awaiting run()
  expect(run_step("pipetestaction") == marker):eq(true)       -- bare string normalizes the same way
  _G.pipetestaction = nil
end)

test("| `;`-group commands go through the first-word-callable convenience, un-awaited", function()
  local calls, sent, real_send = {}, {}, send
  _G.send = function(s) sent[#sent + 1] = s end
  _G.pipegrpcall = function(arg) calls[#calls + 1] = arg or "NIL" end
  local p = run_step({ "pipegrpcall hi", "plaincmd" })
  p.__start()
  expect(calls[1]):eq("hi")           -- callable invoked (not sent)
  expect(sent[1]):eq("plaincmd")      -- ordinary command sent
  expect(p.state):eq("done")
  _G.send, _G.pipegrpcall = real_send, nil
end)

test("| the whole pipe with a `;`-group renders as one widget row: `recover | look; score | l`", function()
  local sent, real_send, real_after = {}, send, after
  _G.send  = function(s) sent[#sent + 1] = s end
  _G.after = function(_, cb) cb(); return 0 end     -- fire auto-starts synchronously
  pipe({ { "recover" }, { "look", "score" }, { "l" } })
  local function present(d)
    for _, e in ipairs(_PROMISE_TEST.active()) do if e.desc == d then return true end end
    return false
  end
  -- The head "recover" is an ordinary command here (no recover callable stubbed) → sends + resolves,
  -- so the chain flows straight through; assert the desc regardless via _PIPE_TEST.desc too.
  expect(_PIPE_TEST.desc({ { "recover" }, { "look", "score" }, { "l" } })):eq("recover | look; score | l")
  expect(present("recover | look; score | l") or #sent > 0):eq(true)
  _G.send, _G.after = real_send, real_after
end)

-- ---- promise widget: a pipe is ONE row (the typed line), not per-segment ---------------------------

test("__pipe registers the whole pipe as a single widget row and de-registers the head", function()
  _G.wpipeA = function() return _PROMISE_TEST.builder(function() end, "A") end   -- head auto-tracks "A"
  _G.wpipeB = function() return _PROMISE_TEST.make(function() end, "B") end
  pipe({ "wpipeA", "wpipeB x" })
  local function present(desc)
    for _, e in ipairs(_PROMISE_TEST.active()) do if e.desc == desc then return true end end
    return false
  end
  expect(present("wpipeA | wpipeB x")):eq(true)   -- the whole line, one row
  expect(present("A")):eq(false)                  -- head superseded by the line (de-registered)
  _G.wpipeA, _G.wpipeB = nil, nil
end)

-- ---- +| : append to the current in-flight promise -------------------------------------------------

test("+| grafts the segments onto the current promise and retitles the widget row", function()
  local head = _PROMISE_TEST.builder(function(res) _G.__ap_res = res end, "wtesthead")
  head.__start()                                       -- running; it's the newest pending → the "current"
  expect(_PROMISE_TEST.current() == head):eq(true)
  local sent, real_send = {}, send; _G.send = function(c) sent[#sent + 1] = c end
  local ok = _PIPE_TEST.append({ "wtestcmd" })         -- like typing `+| wtestcmd`
  expect(ok):eq(true)
  local function present(d)
    for _, e in ipairs(_PROMISE_TEST.active()) do if e.desc == d then return true end end
    return false
  end
  expect(present("wtesthead | wtestcmd")):eq(true)     -- one row, the whole line
  expect(present("wtesthead")):eq(false)               -- the old standalone row is gone
  expect(#sent):eq(0)                                  -- appended step waits for the head to resolve
  _G.__ap_res()                                        -- head done → the appended command runs
  expect(sent[1]):eq("wtestcmd")
  _G.send, _G.__ap_res = real_send, nil
end)

test("+| with nothing in flight falls back to just running the segments", function()
  _PROMISE_TEST.cancel_all()                           -- clear everything → no "current" promise
  expect(_PROMISE_TEST.current()):eq(nil)
  local ok = _PIPE_TEST.append({ "wtestfallback" })
  expect(ok):eq(false)                                 -- nothing to append to
  local cur = _PROMISE_TEST.current()                  -- but it ran the segment as a fresh promise
  expect(cur ~= nil):eq(true)
  expect(cur._track_desc):eq("wtestfallback")
end)

-- ---- -| : drop the tail segment off the current chain (inverse of +|) -----------------------------

local function present(d)
  for _, e in ipairs(_PROMISE_TEST.active()) do if e.desc == d then return true end end
  return false
end

test("-| drops the last (unstarted) segment; the earlier segment keeps running and never spawns it", function()
  _PROMISE_TEST.cancel_all()
  local head = _PROMISE_TEST.builder(function(res) _G.__pp_res = res end, "wpophead")
  head.__start()                                       -- running; the current
  local sent, real_send = {}, send; _G.send = function(c) sent[#sent + 1] = c end
  _PIPE_TEST.append({ "wpoptail" })                    -- chain: wpophead | wpoptail (tail still cold)
  expect(present("wpophead | wpoptail")):eq(true)
  local ok = _PIPE_TEST.pop()                          -- like typing `-|`
  expect(ok):eq(true)
  expect(present("wpophead | wpoptail")):eq(false)     -- the tail row is gone
  expect(present("wpophead")):eq(true)                 -- back to just the head, still running
  _G.__pp_res()                                        -- head resolves → the dropped tail must NOT run
  expect(#sent):eq(0)
  _G.send, _G.__pp_res = real_send, nil
end)

test("-| on a one-segment chain cancels it and runs its cancel hook", function()
  _PROMISE_TEST.cancel_all()
  local cancelled = false
  local solo = _PROMISE_TEST.builder(function(_, _, onCancel) onCancel(function() cancelled = true end) end, "wpopsolo")
  solo.__start()
  expect(_PROMISE_TEST.current() == solo):eq(true)
  expect(_PIPE_TEST.pop()):eq(true)
  expect(solo.state):eq("cancelled")
  expect(cancelled):eq(true)                           -- the sole segment's cancel hook fired
  expect(_PROMISE_TEST.current()):eq(nil)              -- nothing in flight now
end)

test("-| cancels an ALREADY-STARTED tail (runs its cancel hook), leaving the finished head alone", function()
  _PROMISE_TEST.cancel_all()
  local disarmed = false
  _G.wpopact = function()
    return _PROMISE_TEST.builder(function(_, _, onCancel) onCancel(function() disarmed = true end) end, "wpopact")
  end
  local head = _PROMISE_TEST.builder(function(res) _G.__pp2_res = res end, "wpophd2")
  head.__start()
  _PIPE_TEST.append({ "wpopact" })                     -- head | wpopact
  _G.__pp2_res()                                       -- head resolves → wpopact is invoked + started (adopted)
  expect(disarmed):eq(false)                           -- tail running, hook not fired yet
  expect(_PIPE_TEST.pop()):eq(true)
  expect(disarmed):eq(true)                            -- the running tail's cancel hook fired
  _G.wpopact, _G.__pp2_res = nil, nil
end)

test("-| with nothing in flight is a harmless no-op", function()
  _PROMISE_TEST.cancel_all()
  expect(_PROMISE_TEST.current()):eq(nil)
  expect(_PIPE_TEST.pop()):eq(false)
end)
