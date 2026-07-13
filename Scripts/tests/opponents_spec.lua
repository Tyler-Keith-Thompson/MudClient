-- Specs for Combat.lua's INFERRED multi-opponent tracker. The kxwt protocol reports only ONE health
-- bar (the current target), so bars for the other mobs you're fighting are inferred from the textual
-- condition ladder ('help injury injuries damage descriptions').
--
-- BEHAVIOUR-LEVEL: the tracker is exercised through its OBSERVABLE surface — feed readings in through the
-- tracker-update seam (opponent_note, a preserved pure helper) and assert on what a consumer actually
-- sees: the public active_opponents() roster and the engaged()/in_combat() predicates. The pure PARSERS
-- (condition_pct / parse_opponent / parse_melee / parse_target_line) are unit-tested directly — they stay
-- plain functions the streams call, so their line→value mapping is pinned here, but no test reaches into
-- state.opponents internals (the tracker table shape is a HUD contract, covered in hud_layout_spec).

local condition_pct   = _AA_TEST.condition_pct
local parse_opponent  = _AA_TEST.parse_opponent
local opponent_note   = _AA_TEST.opponent_note   -- the tracker-update seam: a reading in → the roster reflects it

-- Index active_opponents()'s array by name, so tests read the observable roster instead of the table.
local function by_name(list)
  local m = {}
  for _, o in ipairs(list) do m[o.name] = o end
  return m
end

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

test("active_opponents excludes the kxwt target, flags the others as estimates, and prunes expired mobs", function()
  local so, sf = state.opponents, state.fight_name
  state.opponents = {}
  state.fight_name = "a goblin"                              -- the current kxwt target: its own exact bar
  opponent_note(state.opponents, "a goblin", 50, 100, true)  -- current target, exact
  opponent_note(state.opponents, "a rat",    3,  100, false) -- inferred
  opponent_note(state.opponents, "an orc",   55, 90,  false) -- older inferred

  -- The roster a consumer (the HUD) sees: the current target excluded, others newest-first, flagged est.
  local out = active_opponents(105)                          -- OPP_TTL is 30s, applied inside active_opponents
  expect(#out):eq(2)
  expect(out[1].name):eq("a rat")
  expect(out[1].est):truthy()                                -- inferred -> flagged estimate
  expect(out[2].name):eq("an orc")

  -- Age out anything not seen within 30s (an orc last seen at t=90; now 130 -> off the roster).
  local out2 = active_opponents(130)
  expect(#out2):eq(1)
  expect(out2[1].name):eq("a rat")
  expect(by_name(active_opponents(130))["an orc"]):eq(nil)   -- expired -> no longer reported
  state.opponents, state.fight_name = so, sf
end)

test("active_opponents sort is deterministic on a same-timestamp tie (by name)", function()
  local so, sf = state.opponents, state.fight_name
  state.opponents, state.fight_name = {}, nil
  opponent_note(state.opponents, "zeta mob", 40, 100, false)
  opponent_note(state.opponents, "alpha mob", 40, 100, false)
  for _ = 1, 25 do
    local out = active_opponents(100)
    expect(out[1].name):eq("alpha mob")           -- ties break by name, never flap
    expect(out[2].name):eq("zeta mob")
  end
  state.opponents, state.fight_name = so, sf
end)

-- ---- nomelee fights: melee-round parsing + the text-inferred engaged() state -----------------------
-- PROVEN BY RAW CAPTURE (mud_raw_nomelee.log): with `nocombat` on, the server sends NO kxwt_fighting at
-- all during a fight (the only kxwt_fighting in the whole log is the connect-time -1), so state.fighting
-- stays false. The fight exists only as text; these lines are VERBATIM from that log's orc-bachelor
-- fight, and the melee parser + engaged() predicate must reconstruct the combat state from them.

local parse_melee = _AA_TEST.parse_melee
local melee_enemy = _AA_TEST.melee_enemy

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

  -- CRIT lines (UPPERCASE verb, and the `*** VERB ***` decoration) parse the same — the helper lower()s the
  -- verb and strips `*`. These are exactly the lines auto-assist was missing (the live TRIGGER now matches
  -- them case-insensitively; parse_melee always did).
  a, t = parse_melee("A metataur guard's frigid crush MASSACRES A flesh beast!")
  expect(a):eq("A metataur guard"); expect(t):eq("A flesh beast")
  a, t = parse_melee("A spear wielding skeletal knight's shield bash *** MASSACRES *** A metataur guard!")
  expect(a):eq("A spear wielding skeletal knight"); expect(t):eq("A metataur guard")

  -- Non-combat lines with an incidental verb-word do not parse.
  expect(parse_melee("A squat orc putters around his hovel.")):eq(nil)
  expect(parse_melee("You are already targeting him.")):eq(nil)
  expect(parse_melee("An orc bachelor is burned by your fire shield!")):eq(nil)
end)

test("melee_enemy / is_ally pick the enemy side of a round line, using the kxwt_group roster", function()
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
  expect(is_ally("A FLESH BEAST")):truthy()          -- is_ally (public) roster match is case-insensitive
  state.group = saved
end)

test("is_self is YOU only, not your minions — so a minion-only brawl doesn't open the engaged window", function()
  local saved_name, saved_group = state.name, state.group
  state.name = "Vaelith"
  state.group = { { name = "Vaelith" }, { name = "A flesh beast" }, { name = "A skeletal spider" } }
  local is_self = _AA_TEST.is_self
  expect(is_self("you")):truthy()
  expect(is_self("You")):truthy()
  expect(is_self("Vaelith")):truthy()
  expect(is_self("A flesh beast")):falsy()          -- a minion is an ally, but NOT you
  expect(is_self("A skeletal spider")):falsy()
  expect(is_self("an orc bachelor")):falsy()
  -- The gate the melee trigger applies: mob-vs-minion has no `self` side (you stay free to move);
  -- mob-vs-you does (you're engaged for real).
  expect(is_self("an orc bachelor") or is_self("A flesh beast")):falsy()
  expect(is_self("an orc bachelor") or is_self("you")):truthy()
  state.name, state.group = saved_name, saved_group
end)

test("engaged() / in_combat() are true while the text-inferred window is open, without any kxwt_fighting", function()
  local saved_f, saved_u = state.fighting, state.engaged_until
  state.fighting = false
  state.engaged_until = nil
  expect(engaged(1000)):falsy()                      -- idle
  expect(in_combat()):falsy()                        -- in_combat() sits on engaged()
  state.engaged_until = 1000 + _AA_TEST.ENGAGE_TTL   -- a melee-round line just refreshed the window
  expect(engaged(1000)):truthy()                     -- engaged with state.fighting == false (nomelee!)
  expect(engaged(1000 + _AA_TEST.ENGAGE_TTL + 1)):falsy()   -- window expired -> fight over
  state.fighting, state.engaged_until = saved_f, saved_u
end)

test("opponent readings are case-insensitive: 'An orc bachelor' and 'an orc bachelor' are ONE mob", function()
  local so, sf = state.opponents, state.fight_name
  state.opponents, state.fight_name = {}, nil
  -- Melee sighting (no health info yet) under one casing...
  opponent_note(state.opponents, "an orc bachelor", nil, 100, false)
  -- ...then the condition line under sentence-case must UPDATE the same roster entry, not fork a second.
  opponent_note(state.opponents, "An orc bachelor", 3, 101, false)
  local out = active_opponents(101)
  expect(#out):eq(1)
  expect(out[1].pct):eq(3)
  -- And a later pct-less melee sighting refreshes recency WITHOUT clobbering the known estimate.
  opponent_note(state.opponents, "an orc bachelor", nil, 105, false)
  out = active_opponents(105)
  expect(out[1].pct):eq(3)
  expect(out[1].t):eq(105)
  state.opponents, state.fight_name = so, sf
end)

-- ---- explicit targeting lines (the `target` command) -------------------------------------------
-- There is NO kxwt target tag; targeting is confirmed only in text. The "acquire" and "already"
-- wordings below are VERBATIM from human-traces; "report" is the verbatim `score` line. The "clear"
-- forms are researched best guesses (never observed in traces/help — flagged in Combat.lua for
-- live confirmation).

local parse_target_line = _AA_TEST.parse_target_line

test("parse_target_line classifies the researched targeting wordings", function()
  -- Acquisition (verbatim trace: follows `target druidess`) — carries the name.
  local kind, name = parse_target_line("You keep a steady eye on a druidess.")
  expect(kind):eq("acquire"); expect(name):eq("a druidess")

  -- Pronoun re-target (verbatim trace + nomelee log): no name to extract.
  kind, name = parse_target_line("You are already targeting him.")
  expect(kind):eq("already"); expect(name):eq(nil)
  expect(parse_target_line("You are already targeting her.")):eq("already")
  expect(parse_target_line("You are already targeting it.")):eq("already")

  -- Passive score report (verbatim trace) — name, but only a report.
  kind, name = parse_target_line("You are targeting Fraxis Hammerhand.")
  expect(kind):eq("report"); expect(name):eq("Fraxis Hammerhand")

  -- Clear forms (best-guess wordings, unconfirmed live).
  kind, name = parse_target_line("You stop targeting a druidess.")
  expect(kind):eq("clear"); expect(name):eq("a druidess")
  kind, name = parse_target_line("You are no longer targeting a druidess.")
  expect(kind):eq("clear"); expect(name):eq("a druidess")
  expect(parse_target_line("You no longer have a target.")):eq("clear")

  -- Non-targeting lines are nil.
  expect(parse_target_line("You keep fighting.")):eq(nil)
  expect(parse_target_line("A druidess is near death!")):eq(nil)
end)

test("acquisition seeds the enemy name onto the roster before any melee round or condition line", function()
  -- `target druidess` acquisition seeds the name with no health reading yet...
  local so, sf = state.opponents, state.fight_name
  state.opponents, state.fight_name = {}, nil
  local kind, name = parse_target_line("You keep a steady eye on a druidess.")
  expect(kind):eq("acquire")
  opponent_note(state.opponents, name, nil, 100, false)       -- seeded by name, no health reading yet
  local out = active_opponents(100)
  expect(#out):eq(1)
  expect(out[1].name):eq("a druidess")
  expect(out[1].pct):eq(nil)                                  -- unknown health -> the HUD shows "?"
  -- ...and the first condition line later fills in the estimate on the SAME roster entry.
  opponent_note(state.opponents, "A druidess", 3, 105, false)
  out = active_opponents(105)
  expect(#out):eq(1)
  expect(out[1].pct):eq(3)
  state.opponents, state.fight_name = so, sf
end)

test("a purely-seeded target reports unknown health; an evidenced one carries its estimate", function()
  -- The target-clear trigger's rule (applied Swift-side) withdraws an entry ONLY when it's purely seeded
  -- (pct == nil): a mob with a health reading is still fighting us regardless of our targeting choice.
  -- Here we pin the OBSERVABLE distinction that guard keys on, via the public roster.
  local so, sf = state.opponents, state.fight_name
  state.opponents, state.fight_name = {}, nil
  opponent_note(state.opponents, "a druidess", nil, 100, false)  -- seeded by targeting only (pct nil)
  opponent_note(state.opponents, "an orc", 42, 100, false)       -- has a health reading
  local out = by_name(active_opponents(100))
  expect(out["a druidess"].pct):eq(nil)   -- purely-seeded -> the clear trigger may withdraw it
  expect(out["an orc"].pct):eq(42)        -- combat evidence -> the clear trigger's guard keeps it
  state.opponents, state.fight_name = so, sf
end)

-- Trigger-level behaviours (kxwt_fighting -1 clear, room change clear, mdeath removal, and the
-- engaged-window writes by the targeting/melee triggers) are wired through Swift-side regex triggers; the
-- observable surface above (active_opponents / engaged / in_combat) covers the parts we can exercise from
-- Lua. The whole-widget rendering lives in hud_spec.lua / hud_layout_spec.lua; auto-assist send behaviour
-- lives in assist_spec.lua.
