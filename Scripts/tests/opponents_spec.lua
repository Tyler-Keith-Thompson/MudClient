-- Specs for AlterAeon.lua's INFERRED multi-opponent tracker. The kxwt protocol reports only ONE health
-- bar (the current target), so bars for the other mobs you're fighting are inferred from the textual
-- condition ladder ('help injury injuries damage descriptions'). These pin the pure helpers: the
-- phrase->pct mapping, the line parser, and the table update/expiry/removal logic.

local condition_pct   = _AA_TEST.condition_pct
local parse_opponent  = _AA_TEST.parse_opponent
local opponent_note   = _AA_TEST.opponent_note
local opponents_active = _AA_TEST.opponents_active

test("condition_pct maps every rung of the injury ladder (plus 'near death') to a descending %", function()
  -- The full 8-rung ladder from 'help injury injuries damage descriptions', plus the combat-only
  -- "near death" below "mortally wounded".
  expect(condition_pct("a goblin is in excellent condition")):eq(95)
  expect(condition_pct("a goblin has a few scratches")):eq(82)
  expect(condition_pct("a goblin has small wounds and bruises")):eq(68)
  expect(condition_pct("a goblin has quite a few wounds")):eq(55)
  expect(condition_pct("a goblin has big nasty wounds and scratches")):eq(42)
  expect(condition_pct("a goblin is pretty hurt")):eq(28)
  expect(condition_pct("a goblin is in awful condition")):eq(15)
  expect(condition_pct("a goblin is mortally wounded, and will die soon if not aided")):eq(8)
  expect(condition_pct("a goblin is near death!")):eq(3)
  -- Every rung is strictly lower than the one above it (monotonic ladder).
  local ladder = { 95, 82, 68, 55, 42, 28, 15, 8, 3 }
  for i = 2, #ladder do expect(ladder[i] < ladder[i - 1]):truthy() end
  -- A line with no condition phrase yields nil.
  expect(condition_pct("a goblin swings its club at you")):eq(nil)
  expect(condition_pct(nil)):eq(nil)
end)

test("condition_pct resolves overlapping phrases to their OWN rung (no shadowing)", function()
  -- "big nasty wounds and scratches" contains "scratches"; "quite a few wounds" / "small wounds" must
  -- not collapse to a bare wounds rung.
  expect(condition_pct("the troll has big nasty wounds and scratches")):eq(42)
  expect(condition_pct("the troll has small wounds and bruises")):eq(68)
  expect(condition_pct("the troll has quite a few wounds")):eq(55)
end)

test("parse_opponent extracts the mob name + estimate, rejecting self, minions and junk", function()
  local n, p = parse_opponent("A goblin is near death!")
  expect(n):eq("A goblin"); expect(p):eq(3)

  n, p = parse_opponent("The big ugly troll has quite a few wounds.")
  expect(n):eq("The big ugly troll"); expect(p):eq(55)

  -- Verb variants: has / looks.
  expect(parse_opponent("A rat looks pretty hurt")):eq("A rat")

  -- Self and your own minion are NOT opponents.
  expect(parse_opponent("You are near death!")):eq(nil)       -- "are" has no is/has/looks subject anyway
  expect(parse_opponent("Your wolf is near death!")):eq(nil)  -- own minion, filtered

  -- A "young dragon" must survive the you/your filter (frontier match, not a prefix match).
  expect(parse_opponent("A young dragon is pretty hurt")):eq("A young dragon")

  -- No condition phrase, or a multi-sentence / over-long subject -> nil (avoids grabbing a whole line).
  expect(parse_opponent("The goblin swings wildly and misses")):eq(nil)
  expect(parse_opponent("You hit the goblin hard. A goblin is near death!")):eq(nil)
end)

test("opponents_active: target exact, others inferred, expiry prunes, exclude drops the current target", function()
  local tbl = {}
  opponent_note(tbl, "a goblin", 50, 100, true)    -- current target, exact
  opponent_note(tbl, "a rat",    3,  100, false)   -- inferred
  opponent_note(tbl, "an orc",   55, 90,  false)   -- older inferred

  -- Exclude the current target -> only the two others, newest-first (a rat @100 before an orc @90).
  local out = opponents_active(tbl, 105, 30, "a goblin")
  expect(#out):eq(2)
  expect(out[1].name):eq("a rat")
  expect(out[1].est):truthy()                      -- inferred -> flagged estimate
  expect(out[2].name):eq("an orc")

  -- Age out anything not seen within ttl (an orc last seen at t=90, now 130, ttl 30 -> gone; pruned in place).
  local out2 = opponents_active(tbl, 130, 30, "a goblin")
  expect(#out2):eq(1)
  expect(out2[1].name):eq("a rat")
  expect(tbl["an orc"]):eq(nil)                    -- expired entry removed from the table
end)

test("opponents_active sort is deterministic on a same-timestamp tie (by name)", function()
  local tbl = {}
  opponent_note(tbl, "zeta mob", 40, 100, false)
  opponent_note(tbl, "alpha mob", 40, 100, false)
  for _ = 1, 25 do
    local out = opponents_active(tbl, 100, 30, nil)
    expect(out[1].name):eq("alpha mob")           -- ties break by name, never flap
    expect(out[2].name):eq("zeta mob")
  end
end)

-- ---- nomelee fights: melee-round parsing + the text-inferred engaged() state -----------------------
-- PROVEN BY RAW CAPTURE (mud_raw_nomelee.log): with `nocombat` on, the server sends NO kxwt_fighting at
-- all during a fight (the only kxwt_fighting in the whole log is the connect-time -1), so state.fighting
-- stays false. The fight exists only as text; these lines are VERBATIM from that log's orc-bachelor
-- fight, and the melee parser + engaged() predicate must reconstruct the combat state from them.

local parse_melee = _AA_TEST.parse_melee
local melee_enemy = _AA_TEST.melee_enemy
local is_ally     = _AA_TEST.is_ally

test("parse_melee parses the verbatim nomelee-log round lines into attacker/target", function()
  local a, t = parse_melee("An orc bachelor's punch hits A flesh beast.")
  expect(a):eq("An orc bachelor"); expect(t):eq("A flesh beast")

  a, t = parse_melee("A flesh beast's bite scratches an orc bachelor.")
  expect(a):eq("A flesh beast"); expect(t):eq("an orc bachelor")

  a, t = parse_melee("an orc bachelor's kick hits you.")
  expect(a):eq("an orc bachelor"); expect(t):eq("you")

  a, t = parse_melee("A skeleton's slice devastates an orc bachelor!")
  expect(a):eq("A skeleton"); expect(t):eq("an orc bachelor")

  a, t = parse_melee("A skeleton's slice wounds an orc bachelor.")
  expect(a):eq("A skeleton"); expect(t):eq("an orc bachelor")

  -- Your own swings (melee mode): "Your <skill> <verb> <target>."
  a, t = parse_melee("Your slash MUTILATES an orc bachelor!")
  expect(a):eq("you"); expect(t):eq("an orc bachelor")

  -- Non-combat lines with an incidental verb-word do not parse.
  expect(parse_melee("A squat orc putters around his hovel.")):eq(nil)
  expect(parse_melee("You are already targeting him.")):eq(nil)
  expect(parse_melee("An orc bachelor is burned by your fire shield!")):eq(nil)
end)

test("melee_enemy picks the non-ally side of a round line, using the kxwt_group roster", function()
  local saved = state.group
  -- The verbatim kxwt_group roster from the log: you + three minions.
  state.group = {
    { name = "Vaelith", flags = "XLN" }, { name = "A skeleton", flags = "M" },
    { name = "A flesh beast", flags = "MT" }, { name = "an energetic green demon", flags = "MN" },
  }
  -- Mob hits minion -> the mob is the enemy; minion hits mob -> still the mob (case-insensitive roster).
  expect(melee_enemy("An orc bachelor", "A flesh beast")):eq("An orc bachelor")
  expect(melee_enemy("A flesh beast", "an orc bachelor")):eq("an orc bachelor")
  expect(melee_enemy("an orc bachelor", "you")):eq("an orc bachelor")
  expect(melee_enemy("you", "an orc bachelor")):eq("an orc bachelor")
  -- Both sides yours (minion sparring?) or neither (bystander fight) -> no enemy.
  expect(melee_enemy("A skeleton", "A flesh beast")):eq(nil)
  expect(melee_enemy("a rabid dog", "a deer")):eq(nil)
  expect(is_ally("A FLESH BEAST")):truthy()          -- roster match is case-insensitive
  state.group = saved
end)

test("engaged() is true while the text-inferred window is open, without any kxwt_fighting", function()
  local saved_f, saved_u = state.fighting, state.engaged_until
  state.fighting = false
  state.engaged_until = nil
  expect(engaged(1000)):falsy()                      -- idle
  state.engaged_until = 1000 + _AA_TEST.ENGAGE_TTL   -- a melee-round line just refreshed the window
  expect(engaged(1000)):truthy()                     -- engaged with state.fighting == false (nomelee!)
  expect(engaged(1000 + _AA_TEST.ENGAGE_TTL + 1)):falsy()   -- window expired -> fight over
  state.fighting, state.engaged_until = saved_f, saved_u
end)

test("opponent keys are case-insensitive: 'An orc bachelor' and 'an orc bachelor' are ONE mob", function()
  local tbl = {}
  -- Melee sighting (no health info yet) under one casing...
  opponent_note(tbl, "an orc bachelor", nil, 100, false)
  -- ...then the condition line under sentence-case must UPDATE it, not fork a second entry.
  opponent_note(tbl, "An orc bachelor", 3, 101, false)
  local out = opponents_active(tbl, 101, 30, nil)
  expect(#out):eq(1)
  expect(out[1].pct):eq(3)
  -- And a later pct-less melee sighting refreshes recency WITHOUT clobbering the known estimate.
  opponent_note(tbl, "an orc bachelor", nil, 105, false)
  out = opponents_active(tbl, 105, 30, nil)
  expect(out[1].pct):eq(3)
  expect(out[1].t):eq(105)
end)

-- Trigger-level behaviours (kxwt_fighting -1 clear, room change clear, mdeath removal) are wired through
-- Swift-side regex triggers that call state.opponents mutation; the pure logic above covers the parts we
-- can exercise from Lua. The whole-widget rendering lives in hud_spec.lua / hud_layout_spec.lua.
