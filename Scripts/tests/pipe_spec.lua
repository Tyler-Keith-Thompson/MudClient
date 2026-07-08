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
