-- Specs for AIPilot.lua's after()-based turn timer chain and the dead-end blocker — the timer plumbing
-- the reactive refactor reworks. `after` is a host builtin (the driver stubs it as a no-op), so here we
-- OVERRIDE it to capture the delays/callbacks the chain schedules, and override take_turn to see whether
-- a turn actually fired. These pin the arm -> fire_if_ready guard/re-arm logic by its OBSERVABLE effects:
-- whether a turn fires (take_turn), what re-arm delays get scheduled, and whether a superseded/blocked
-- fire acts — never by reading the private generation/busy flags directly.

local P   = _AIP_TEST.P
local cfg = _AIP_TEST.cfg
local arm = _AIP_TEST.arm

-- Capture every after() delay + callback scheduled during fn (WITHOUT running the callbacks), plus
-- whether take_turn fired. Restores all globals afterward. Callers set the P fields they care about first.
local function trace(fn)
  local real_after, real_take = after, take_turn
  local delays, cbs, fired = {}, {}, false
  after = function(delay, cb) delays[#delays + 1] = delay; cbs[#cbs + 1] = cb end
  take_turn = function() fired = true end
  local ok, err = pcall(fn)
  after, take_turn = real_after, real_take
  if not ok then error(err, 2) end
  return delays, fired, cbs
end

-- Run a captured fire_if_ready callback with take_turn stubbed, and report whether it took a turn.
local function fires_a_turn(cb)
  local real_take, fired = take_turn, false
  take_turn = function() fired = true end
  local ok, err = pcall(cb)
  take_turn = real_take
  if not ok then error(err, 2) end
  return fired
end

test("arm schedules a single quiet-window fire when enabled (nothing when disabled), and a re-arm supersedes it", function()
  local saved = { en = P.enabled, busy = P.busy, nav = P.nav, lt = P.last_turn,
                  lh = P.last_human, co = cfg.combat_only }
  cfg.combat_only = false               -- isolate the timer machinery from the combat gate
  P.enabled, P.busy, P.nav, P.last_turn, P.last_human = true, false, nil, 0, 0

  local delays = trace(function() arm() end)
  expect(#delays):eq(1)
  expect(delays[1]):near(cfg.quiet)     -- one scheduled fire, after the quiet-window debounce

  P.enabled = false
  local d2 = trace(function() arm() end)
  expect(#d2):eq(0)                     -- disabled: nothing scheduled at all
  P.enabled = true

  -- Two arms schedule two fires; the FIRST is now stale (a later arm advanced the guard) and must NOT
  -- act, while the LATEST one takes the turn. That superseding is the whole point of the generation bump.
  local _, _, cbs = trace(function() arm(); arm() end)
  expect(#cbs):eq(2)
  expect(fires_a_turn(cbs[1])):falsy()
  P.busy = false                        -- (a real fire latches busy; reset for the next probe)
  expect(fires_a_turn(cbs[2])):truthy()
  P.enabled, P.busy, P.nav, P.last_turn, P.last_human, cfg.combat_only =
    saved.en, saved.busy, saved.nav, saved.lt, saved.lh, saved.co
end)

-- Snapshot/restore every P field fire_if_ready reads or writes.
local function with_pilot(fields, fn)
  local keys = { "enabled", "busy", "nav", "gen", "last_turn", "last_human" }
  local saved = {}
  for _, k in ipairs(keys) do saved[k] = P[k] end
  for k, v in pairs(fields) do P[k] = v end
  -- These tests exercise the timer machinery in isolation, independent of the combat-only gate
  -- (which now defaults ON). Neutralize it here so fire_if_ready isn't short-circuited by "not in
  -- combat" — combat-gating has its own coverage in combat_only_spec.
  local saved_co = cfg.combat_only
  cfg.combat_only = false
  local ok, err = pcall(fn)
  cfg.combat_only = saved_co
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

test("fire_if_ready fires exactly one turn once the guards pass, and blocks a re-fire", function()
  with_pilot({ enabled = true, busy = false, nav = nil, gen = 4, last_turn = 0, last_human = 0 }, function()
    local delays, fired = trace(function() fire_if_ready(4) end)
    expect(fired):truthy()             -- took the turn
    expect(#delays):eq(0)              -- no re-arm; it acted immediately
    -- Having acted, it latched itself in-flight: a second fire on the same generation does NOT re-fire.
    local _, fired2 = trace(function() fire_if_ready(4) end)
    expect(fired2):falsy()
  end)
end)

test("fire_if_ready re-arms (never fires) while inside the min-interval or human-grace window", function()
  -- Too soon since the last turn -> reschedule after min_interval, don't act.
  with_pilot({ enabled = true, busy = false, nav = nil, gen = 4, last_turn = os.time(), last_human = 0 }, function()
    local delays, fired = trace(function() fire_if_ready(4) end)
    expect(fired):falsy()
    expect(#delays):eq(1)
    expect(delays[1]):near(cfg.min_interval)
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
local block_last_move  = _AIP_TEST.block_last_move
local best_explore_dir = _AIP_TEST.best_explore_dir

test("block_last_move dead-ends the attempted exit (explore avoids it) and stops navigation with a notice", function()
  local saved = { rooms = P.rooms, cur = P.current_room, dir = P.last_move_dir,
                  nav = P.nav, en = P.enabled }
  local real_after, real_echo = after, echo
  local msgs = {}
  after = function() end                                   -- swallow schedule_save/arm timers
  echo = function(s) msgs[#msgs + 1] = tostring(s) end
  P.enabled = false                                        -- so arm() inside block_last_move is a no-op
  -- Room R advertises north (the failed step) and south. After blocking north, explore must route south.
  P.rooms = { R = { exits = { north = true, south = true }, moves = {} } }
  P.current_room = "R"
  P.last_move_dir = "north"
  P.nav = { dest = "somewhere", path = { "north" }, idx = 1 }
  block_last_move()
  expect(best_explore_dir()):eq("south")                   -- north is now a dead end -> never routed
  expect(table.concat(msgs, "\n"):find("stopping navigation", 1, true) ~= nil):truthy()  -- told the user
  -- Navigation was abandoned: a nav_step now has nothing to walk (no further move is sent).
  local sent = {}
  local real_send = send; send = function(c) sent[#sent + 1] = c end
  nav_step()
  send = real_send
  expect(#sent):eq(0)                                      -- route gone -> no move issued
  after, echo = real_after, real_echo
  P.rooms, P.current_room, P.last_move_dir, P.nav, P.enabled =
    saved.rooms, saved.cur, saved.dir, saved.nav, saved.en
end)

test("block_last_move is a no-op when there is no pending move direction", function()
  local saved = { rooms = P.rooms, cur = P.current_room, dir = P.last_move_dir }
  P.rooms = { R = { exits = { north = true }, moves = {} } }
  P.current_room = "R"
  P.last_move_dir = nil
  block_last_move()
  expect(best_explore_dir()):eq("north")                   -- nothing blocked -> north is still explorable
  P.rooms, P.current_room, P.last_move_dir = saved.rooms, saved.cur, saved.dir
end)
