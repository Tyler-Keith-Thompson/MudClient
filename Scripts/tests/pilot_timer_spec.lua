-- Specs for AIPilot.lua's after()-based turn timer chain and the dead-end blocker — the timer plumbing
-- the host-hooks refactor will move onto new APIs. `after` is a host builtin (the driver stubs it as a
-- no-op), so here we OVERRIDE it to capture the delays the chain schedules, and override take_turn to see
-- whether a turn actually fired. These pin the arm -> fire_if_ready guard/re-arm logic exactly as it is.

local P   = _AIP_TEST.P
local cfg = _AIP_TEST.cfg
local arm = _AIP_TEST.arm

-- Capture every after() delay scheduled during fn (WITHOUT running the callbacks), plus whether
-- take_turn fired. Restores all globals afterward. Callers set the P fields they care about first.
local function trace(fn)
  local real_after, real_take = after, take_turn
  local delays, fired = {}, false
  after = function(delay, _cb) delays[#delays + 1] = delay end
  take_turn = function() fired = true end
  local ok, err = pcall(fn)
  after, take_turn = real_after, real_take
  if not ok then error(err, 2) end
  return delays, fired
end

test("arm bumps the generation and schedules fire_if_ready after cfg.quiet — but only when enabled", function()
  local saved = { en = P.enabled, gen = P.gen }
  P.enabled, P.gen = true, 5
  local delays = trace(function() arm() end)
  expect(P.gen):eq(6)                  -- generation advanced (invalidates older pending timers)
  expect(#delays):eq(1)
  expect(delays[1]):near(cfg.quiet)    -- the quiet-window debounce

  P.enabled, P.gen = false, 5
  local d2 = trace(function() arm() end)
  expect(P.gen):eq(5)                  -- disabled: no bump...
  expect(#d2):eq(0)                    -- ...and nothing scheduled
  P.enabled, P.gen = saved.en, saved.gen
end)

-- Snapshot/restore every P field fire_if_ready reads or writes.
local function with_pilot(fields, fn)
  local keys = { "enabled", "busy", "nav", "gen", "last_turn", "last_human" }
  local saved = {}
  for _, k in ipairs(keys) do saved[k] = P[k] end
  for k, v in pairs(fields) do P[k] = v end
  local ok, err = pcall(fn)
  for _, k in ipairs(keys) do P[k] = saved[k] end
  if not ok then error(err, 2) end
end

test("fire_if_ready refuses to act on a stale generation or while disabled/busy/navigating", function()
  -- Stale generation (g ~= P.gen): a leftover timer from before the last arm() must never fire.
  with_pilot({ enabled = true, busy = false, nav = nil, gen = 9, last_turn = 0, last_human = 0 }, function()
    local delays, fired = trace(function() fire_if_ready(8) end)
    expect(fired):falsy(); expect(#delays):eq(0)
  end)
  -- Disabled.
  with_pilot({ enabled = false, busy = false, nav = nil, gen = 3, last_turn = 0, last_human = 0 }, function()
    local delays, fired = trace(function() fire_if_ready(3) end)
    expect(fired):falsy(); expect(#delays):eq(0)
  end)
  -- Already busy (a request is in flight).
  with_pilot({ enabled = true, busy = true, nav = nil, gen = 3, last_turn = 0, last_human = 0 }, function()
    local _, fired = trace(function() fire_if_ready(3) end)
    expect(fired):falsy()
  end)
  -- The script is auto-walking a route (P.nav) — the AI stays hands-off.
  with_pilot({ enabled = true, busy = false, nav = { dest = "x" }, gen = 3, last_turn = 0, last_human = 0 }, function()
    local _, fired = trace(function() fire_if_ready(3) end)
    expect(fired):falsy()
  end)
end)

test("fire_if_ready fires a turn once all guards pass and the cooldowns have elapsed", function()
  with_pilot({ enabled = true, busy = false, nav = nil, gen = 4, last_turn = 0, last_human = 0 }, function()
    local delays, fired = trace(function() fire_if_ready(4) end)
    expect(fired):truthy()             -- took the turn
    expect(P.busy):truthy()            -- and marked itself busy before the request
    expect(#delays):eq(0)              -- no re-arm; it acted immediately
  end)
end)

test("fire_if_ready re-arms (never fires) while inside the min-interval or human-grace window", function()
  -- Too soon since the last turn -> reschedule after min_interval, don't act.
  with_pilot({ enabled = true, busy = false, nav = nil, gen = 4, last_turn = os.time(), last_human = 0 }, function()
    local delays, fired = trace(function() fire_if_ready(4) end)
    expect(fired):falsy()
    expect(#delays):eq(1)
    expect(delays[1]):near(cfg.min_interval)
    expect(P.busy):falsy()
  end)
  -- Interval OK, but you typed very recently -> wait out the human grace, don't barge in.
  with_pilot({ enabled = true, busy = false, nav = nil, gen = 4, last_turn = 0, last_human = os.time() }, function()
    local delays, fired = trace(function() fire_if_ready(4) end)
    expect(fired):falsy()
    expect(#delays):eq(1)
    expect(delays[1] > 0):truthy()     -- grace_left + 0.1, a positive re-arm delay
  end)
end)

-- ---- block_last_move: a failed step marks that exit a dead end ----------------------------------
local block_last_move = _AIP_TEST.block_last_move

test("block_last_move tags the attempted exit blocked, clears the pending dir, and stops navigation", function()
  local saved = { rooms = P.rooms, cur = P.current_room, dir = P.last_move_dir,
                  nav = P.nav, en = P.enabled }
  local real_after = after
  after = function() end                                   -- swallow schedule_save/arm timers
  P.enabled = false                                        -- so arm() inside block_last_move is a no-op
  P.rooms = { R = { exits = { north = true }, moves = {} } }
  P.current_room = "R"
  P.last_move_dir = "north"
  P.nav = { dest = "somewhere" }
  block_last_move()
  expect(P.rooms.R.blocked and P.rooms.R.blocked.north):truthy()  -- dead end recorded
  expect(P.last_move_dir):eq(nil)                                 -- pending dir consumed
  expect(P.nav):eq(nil)                                           -- navigation abandoned on a blocked step
  after = real_after
  P.rooms, P.current_room, P.last_move_dir, P.nav, P.enabled =
    saved.rooms, saved.cur, saved.dir, saved.nav, saved.en
end)

test("block_last_move is a no-op when there is no pending move direction", function()
  local saved = { rooms = P.rooms, cur = P.current_room, dir = P.last_move_dir }
  P.rooms = { R = { exits = { north = true }, moves = {} } }
  P.current_room = "R"
  P.last_move_dir = nil
  block_last_move()
  expect(P.rooms.R.blocked):eq(nil)                        -- nothing to block
  P.rooms, P.current_room, P.last_move_dir = saved.rooms, saved.cur, saved.dir
end)
