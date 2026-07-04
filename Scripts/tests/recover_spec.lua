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
