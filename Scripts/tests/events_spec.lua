-- Specs for Events.tl's domain-event layer: the state-derived transition events (onCombatStart/onCombatEnd,
-- onManaLow/onHPLow, onTankDown). Line-sourced events (onSpellUp/onSpellDown/onMinionDied/onEnemyDied/
-- onCryOfVictory/onSpellLanded/onPostureChange/onNewOpponent) are plain rx.fromTrigger derivations —
-- AutoFight's own adoption of onSpellLanded/onEnemyDied is exercised end-to-end by autofight_spec.lua, so
-- this file focuses on the transition logic that's unique to Events.tl (never directly trigger-driven,
-- since `trigger()` is a no-op stub in this bare harness — see _EVENTS_TEST.tick()).

local tick = _EVENTS_TEST.tick

-- Subscribe `obs` and collect every emission into a fresh array.
local function collect(obs)
  local out = {}
  obs:subscribe(function(v) out[#out + 1] = v end)
  return out
end

test("onCombatStart/onCombatEnd fire on the engaged() edge, not every tick", function()
  state.fighting, state.engaged_until = false, nil
  local starts, ends = collect(onCombatStart), collect(onCombatEnd)
  tick()                          -- not engaged -> not engaged: no edge
  expect(#starts):eq(0)
  expect(#ends):eq(0)
  state.fighting = true
  tick()                          -- edge: false -> true
  expect(#starts):eq(1)
  expect(#ends):eq(0)
  tick()                          -- still true: no re-fire
  expect(#starts):eq(1)
  state.fighting = false
  tick()                          -- edge: true -> false
  expect(#ends):eq(1)
  state.fighting = false
end)

test("onManaLow / onHPLow fire only on the crossing (not every low tick), and report the ratio", function()
  state.mana, state.maxmana = 50, 100
  state.hp, state.maxhp = 50, 100
  local manaLow, hpLow = collect(onManaLow), collect(onHPLow)
  tick()                          -- 50% mana/hp: above both thresholds (0.2 / 0.3)
  expect(#manaLow):eq(0)
  expect(#hpLow):eq(0)
  state.mana = 10                 -- 10% < 20% mana threshold
  tick()
  expect(#manaLow):eq(1)
  expect(manaLow[1]):eq(0.1)
  tick()                          -- still low: no re-fire (edge-triggered)
  expect(#manaLow):eq(1)
  state.hp = 20                   -- 20% < 30% hp threshold
  tick()
  expect(#hpLow):eq(1)
  expect(hpLow[1]):eq(0.2)
  state.mana, state.hp = 80, 80   -- back above both -> the NEXT crossing can fire again
  tick()
  state.mana, state.hp = 5, 5
  tick()
  expect(#manaLow):eq(2)
  expect(#hpLow):eq(2)
end)

test("mana_ratio/hp_ratio are nil when vitals are unknown or maxmana/maxhp is 0", function()
  local mana_ratio, hp_ratio = _EVENTS_TEST.mana_ratio, _EVENTS_TEST.hp_ratio
  state.mana, state.maxmana = nil, nil
  expect(mana_ratio()):eq(nil)
  state.mana, state.maxmana = 5, 0
  expect(mana_ratio()):eq(nil)
  state.hp, state.maxhp = 40, 80
  expect(hp_ratio()):eq(0.5)
end)

-- ---- onTankDown: mirrors autofight_spec.lua's own tank-rescue table shape (roster of {name, flags}).
local function tgroup(rows) state.group_flags = {}; for _, m in ipairs(rows) do state.group_flags[m.name] = m.flags end end

local function tank_reset()
  _EVENTS_TEST.reset_tank()
  state.group_flags = {}
end

test("current_tank_name: the minion flagged M+T is the tank; a plain minion is not", function()
  tank_reset()
  tgroup({ { name = "You", flags = "X" }, { name = "A skeletal spider", flags = "M" }, { name = "A clay man", flags = "MT" } })
  expect(_EVENTS_TEST.current_tank_name()):eq("A clay man")
end)

test("onTankDown fires when the tank dies (ydeath, then the roster drops it)", function()
  tank_reset()
  local downs = collect(onTankDown)
  tgroup({ { name = "A flesh beast", flags = "MT" } })
  _EVENTS_TEST.tank_group_end()                 -- tracks the tank
  _EVENTS_TEST.tank_ydeath()                    -- a minion of mine died…
  tgroup({})                                    -- …the roster drops it
  _EVENTS_TEST.tank_group_end()
  expect(#downs):eq(1)
  expect(downs[1]):eq("A flesh beast")
end)

test("onTankDown survives a STALE roster (ydeath, roster still lists it, THEN removal) — rescues once", function()
  tank_reset()
  local downs = collect(onTankDown)
  tgroup({ { name = "A flesh beast", flags = "MT" } })
  _EVENTS_TEST.tank_group_end()
  _EVENTS_TEST.tank_ydeath()
  _EVENTS_TEST.tank_group_end()                 -- stale roster still lists it: latch must survive
  expect(#downs):eq(0)
  tgroup({})
  _EVENTS_TEST.tank_group_end()
  expect(#downs):eq(1)
  expect(downs[1]):eq("A flesh beast")
end)

test("the tank LEAVING benignly (no ydeath) does NOT fire onTankDown", function()
  tank_reset()
  local downs = collect(onTankDown)
  tgroup({ { name = "A flesh beast", flags = "MT" } })
  _EVENTS_TEST.tank_group_end()
  tgroup({})                                    -- gone, but no ydeath preceded it
  _EVENTS_TEST.tank_group_end()
  expect(#downs):eq(0)
end)

test("a NON-tank minion dying (tank still grouped) does NOT fire onTankDown", function()
  tank_reset()
  local downs = collect(onTankDown)
  tgroup({ { name = "A flesh beast", flags = "MT" }, { name = "A skeletal spider", flags = "M" } })
  _EVENTS_TEST.tank_group_end()
  _EVENTS_TEST.tank_ydeath()                    -- some minion died...
  tgroup({ { name = "A flesh beast", flags = "MT" } })  -- ...but the spider; tank still tanking
  _EVENTS_TEST.tank_group_end()
  expect(#downs):eq(0)
end)
