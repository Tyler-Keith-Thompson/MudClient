-- Specs for the `recover` readiness threshold (AlterAeon.lua). `recover` rests/sleeps until ready(),
-- then auto-stands; "ready" means every vital at least 90%.

local ready = _AA_TEST.ready

local function with_state(hp, mp, sp, fn)
  local saved = state
  state = { hp = hp, maxhp = 100, mana = mp, maxmana = 100, stam = sp, maxstam = 100 }
  local ok, err = pcall(fn)
  state = saved
  if not ok then error(err, 2) end
end

test("ready() is true only when every vital is at least 90%", function()
  with_state(90, 95, 100, function() expect(ready()):truthy() end)   -- exactly 90% counts
  with_state(100, 100, 100, function() expect(ready()):truthy() end)
end)

test("ready() is false if any single vital is below 90%", function()
  with_state(89, 100, 100, function() expect(ready()):falsy() end)   -- hp low
  with_state(100, 89, 100, function() expect(ready()):falsy() end)   -- mana low
  with_state(100, 100, 89, function() expect(ready()):falsy() end)   -- stamina low
end)

-- ---- context-aware recovery posture (choose_recovery_position) -----------------------------------

local choose = _AA_TEST.choose_recovery_position
local depth  = _AA_TEST.recovery_depth

-- Set vitals + current posture, capture what choose_recovery_position() sends.
local function with_posture(hp, mp, sp, position, fn)
  local saved_state, saved_send = state, send
  local sent = {}
  state = { hp = hp, maxhp = 100, mana = mp, maxmana = 100, stam = sp, maxstam = 100, position = position }
  _G.send = function(c) sent[#sent + 1] = c end
  local ok, err = pcall(function() fn(sent) end)
  state, _G.send = saved_state, saved_send
  if not ok then error(err, 2) end
end

test("recovery_depth ranks postures (standing<sitting/resting<sleeping, unknown=0)", function()
  expect(depth("standing")):eq(0)
  expect(depth("sitting")):eq(1)
  expect(depth("resting")):eq(1)
  expect(depth("sleeping")):eq(2)
  expect(depth("meditating")):eq(0)   -- unmapped → 0
  expect(depth(nil)):eq(0)
end)

test("from standing, choose sends the wanted posture", function()
  with_posture(90, 50, 90, "standing", function(sent)   -- hp/stam high, mana low → rest
    choose(); expect(sent[1]):eq("rest")
  end)
  with_posture(40, 40, 40, "standing", function(sent)   -- everything low → sleep
    choose(); expect(sent[1]):eq("sleep")
  end)
end)

test("already resting/sitting when rest is enough sends nothing (no redundant rest)", function()
  with_posture(90, 50, 90, "sitting", function(sent) choose(); expect(#sent):eq(0) end)
  with_posture(90, 50, 90, "resting", function(sent) choose(); expect(#sent):eq(0) end)
end)

test("sitting but wanting deeper recovery escalates to sleep", function()
  with_posture(40, 40, 40, "sitting", function(sent)    -- want sleep, only at depth 1 → escalate
    choose(); expect(sent[1]):eq("sleep")
  end)
end)

test("already sleeping never re-sends (deeper than any target)", function()
  with_posture(40, 40, 40, "sleeping", function(sent) choose(); expect(#sent):eq(0) end)  -- want sleep
  with_posture(90, 50, 90, "sleeping", function(sent) choose(); expect(#sent):eq(0) end)  -- want rest, don't downgrade
end)
