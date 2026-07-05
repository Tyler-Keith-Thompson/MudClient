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

-- Trigger-level behaviours (kxwt_fighting -1 clear, room change clear, mdeath removal) are wired through
-- Swift-side regex triggers that call state.opponents mutation; the pure logic above covers the parts we
-- can exercise from Lua. The whole-widget rendering lives in hud_spec.lua / hud_layout_spec.lua.
