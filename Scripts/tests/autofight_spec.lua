-- Specs for AutoFight.lua — the deterministic auto-fight state machine.
--
-- CHARACTERIZATION suite. These assert OBSERVABLE BEHAVIOUR — the exact `send` sequences the routine
-- emits, the echo/`say` lines it prints, the learned-winner persistence (seen via the next fight's
-- skip-probe behaviour), and the fight outcomes (promise resolution / on_dead callbacks) — NOT the
-- machine's internal state fields (F.phase, F.busy, F.winner_spell, F.enemy_est, …). The point: a
-- reactive reimplementation of AutoFight that stores state completely differently must still turn these
-- green, because it reproduces the same sends/echoes/outcomes. Any change to the actual command sequence
-- breaks a test.
--
-- They drive the ACTUAL machine by feeding it the SAME resolution handlers the live Swift triggers
-- dispatch to (AF.icebolt/AF.fireball/AF.resist/… via _AF_TEST) plus the kxwt_fighting handler (AF.on_fight)
-- and the input observer (AF.on_input). Reading _AF_TEST is used only to DRIVE the scenario (feed lines,
-- advance the fight); every ASSERTION is on observable output — AF.sent (the captured send sequence),
-- captured echo text, or a callback/promise outcome.
--
-- PACING RULE under test: a cast goes out, then NOTHING until that spell's own landed line (or a fail).
-- The enemy health bar (on_fight / kxwt_fighting) ticks many times a second and must send NOTHING.

local AF = _AF_TEST
local ENEMY = "a Gnomian guard"

local function seq() local t = {}; for i, v in ipairs(AF.sent) do t[i] = v end; return t end
local function expect_seq(got, want)
  expect(#got):eq(#want)
  for i = 1, #want do
    if got[i] ~= want[i] then
      error(string.format("send[%d]: expected '%s', got '%s'  (full: %s)",
        i, tostring(want[i]), tostring(got[i]), table.concat(got, " | ")), 2)
    end
  end
end

-- Land the currently-in-flight spell by name (drives the resolution handler the trigger would call).
local LAND = {
  lightning = AF.lightning, icebolt = AF.icebolt, fireball = AF.fireball, prism = AF.prism,
  tarrants = AF.tarrants, bloodmist = AF.bloodmist, frostflower = AF.frostflower,
}
-- Spell → the exact wire command it casts (lightning's isn't "c lightning").
local CMD = {
  lightning = "cast 'lightning bolt'", icebolt = "c icebolt", fireball = "c fireball", prism = "c prism",
}
-- Land whichever opener a fresh fight cast (tarrants or the HP-gated bloodmist).
local OPENER_LAND = { ["c tarrants"] = AF.tarrants, ["c bloodmist"] = AF.bloodmist }
local function land_opener() OPENER_LAND[AF.sent[#AF.sent]]() end

-- Get to "the first (lightning) probe in flight": start the fight (casts the tarrants opener), land
-- tarrants → the first PRIMARY probe "cast 'lightning bolt'".
local function to_lightning()
  AF.reset()
  AF.on_fight(90, ENEMY)   -- combat start → "c tarrants"
  AF.tarrants()            -- tarrants LANDED → "cast 'lightning bolt'"
end

-- Behaviour probes for learned-winner PERSISTENCE (all observable, no internal reads): start a FRESH
-- fight vs `name` (assumes we're not currently fighting) and watch what it casts.
--   fight_probes(name)     → true if it PROBES: opener, then the first primary "cast 'lightning bolt'",
--                            then (on the lightning landing) "c fireball" — the two-primary probe, i.e. no
--                            learned winner.
--   fight_nukes(name,spell)→ true if it SKIPS the probe and NUKES `spell` off the opener: opener, then
--                            `spell`'s cast command, and (on that landing) the same again — a repeat nuke,
--                            which a one-shot probe cast would never do.
local function fight_probes(name)
  AF.on_fight(90, name); land_opener()
  if AF.sent[#AF.sent] ~= CMD.lightning then return false end
  AF.lightning()
  return AF.sent[#AF.sent] == "c fireball"
end
local function fight_nukes(name, spell)
  local cmd = CMD[spell]
  AF.on_fight(90, name); land_opener()
  if AF.sent[#AF.sent] ~= cmd then return false end
  LAND[spell]()
  return AF.sent[#AF.sent] == cmd
end

-- Capture the echo/`say` lines a call emits (colour stripped), restoring the real echo afterwards. Used
-- where the user-visible message is the only observable of an action.
local function capture_echo(fn)
  local saved = echo
  local out = {}
  echo = function(s) out[#out + 1] = (tostring(s):gsub("\27%[[%d;]*m", "")) end
  local ok, err = pcall(fn)
  echo = saved
  if not ok then error(err, 2) end
  return table.concat(out, "\n")
end

-- ---- (a) full fight command sequence -------------------------------------------------------------
test("full fight: tarrants → lightning/fireball probe → nuke winner → soulsteal (resist → re-nuke → retry)", function()
  to_lightning()                      -- sent: c tarrants, cast 'lightning bolt'
  AF.on_fight(70, ENEMY)             -- lightning Δ20 — a % change NEVER casts
  AF.lightning()                      -- lightning LANDED → "c fireball" (probe advances immediately)
  AF.on_fight(65, ENEMY)             -- fireball Δ5
  AF.fireball()                        -- fireball LANDED → decide (lightning wins, primary cleared bar) → nuke lightning
  -- each winner-nuke now decides on the BAR boundary: land, THEN the fresh kxwt_fighting % (on_fight IS
  -- the boundary — it fires barS itself, no separate seam needed).
  AF.lightning(); AF.on_fight(50, ENEMY)  -- landed → bar → "cast 'lightning bolt'"
  AF.lightning(); AF.on_fight(35, ENEMY)  -- landed → bar → "cast 'lightning bolt'"
  AF.lightning(); AF.on_fight(20, ENEMY)  -- landed → bar → "cast 'lightning bolt'"
  AF.lightning(); AF.on_fight(10, ENEMY)  -- landed, now ≤15% at the bar → "c soulsteal"
  AF.resist()                        -- soulsteal RESISTED → re-nuke → "cast 'lightning bolt'"
  AF.lightning(); AF.on_fight(10, ENEMY)   -- re-nuke landed → bar → retry "c soulsteal"
  AF.soulsteal_ok()                  -- landed → done (no further sends)
  AF.dead()                          -- enemy dead → fight ends

  expect_seq(seq(), {
    "c tarrants",
    "cast 'lightning bolt'", "c fireball",              -- primary probes
    "cast 'lightning bolt'", "cast 'lightning bolt'", "cast 'lightning bolt'", "cast 'lightning bolt'",  -- winner nuked (65→50→35→20→10)
    "c soulsteal",                                   -- finish attempt
    "cast 'lightning bolt'",                          -- re-nuke after the resist
    "c soulsteal",                                   -- retry — lands
  })
  -- lightning was learned as the winner: the NEXT fight vs the same name skips the probe and nukes lightning.
  expect(fight_nukes(ENEMY, "lightning")):eq(true)
end)

test("soulsteal FIZZLE ('You fail to cast the spell') re-casts the steal at once — no deadlock, no nuke", function()
  to_lightning()                      -- sent: c tarrants, cast 'lightning bolt'
  AF.on_fight(70, ENEMY); AF.lightning()   -- lightning landed → "c fireball"
  AF.on_fight(65, ENEMY); AF.fireball()      -- fireball landed → decide (lightning wins) → nuke lightning
  AF.lightning(); AF.on_fight(10, ENEMY)   -- landed, ≤15% at the bar → "c soulsteal"
  expect(AF.sent[#AF.sent]):eq("c soulsteal")
  AF.fail()                           -- the soulsteal CAST fizzled → must retry the STEAL immediately
  expect(AF.sent[#AF.sent]):eq("c soulsteal")   -- re-cast at once (NOT a winner nuke) — and no deadlock
  AF.soulsteal_ok()                   -- retry lands → done
  AF.dead()
end)

test("soulsteal 'fails to latch on to an individual soul' is a TERMINATOR: keep nuking, persist unstealable", function()
  -- This line means the mob has no individual soul — soulsteal can NEVER land on it. Treat it exactly like
  -- "can only soulsteal from living things": stop re-casting, keep nuking, and remember the name.
  to_lightning()
  AF.on_fight(70, ENEMY); AF.lightning()
  AF.on_fight(65, ENEMY); AF.fireball()      -- winner lightning
  AF.lightning(); AF.on_fight(10, ENEMY)   -- ≤15% → the ONE soulsteal attempt
  expect(AF.sent[#AF.sent]):eq("c soulsteal")
  AF.soul_nolatch()                        -- no individual soul → back to nuking, never re-steal
  expect(AF.sent[#AF.sent]):eq(CMD.lightning)
  expect(AF.is_unstealable(ENEMY)):eq(true)    -- learned + persisted for this name
  -- And it must not keep trying to soulsteal, even as it stays in finish range.
  for _ = 1, 3 do
    AF.near_death(ENEMY)
    AF.lightning(); AF.on_fight(5, ENEMY)
    expect(AF.sent[#AF.sent]):eq(CMD.lightning)
  end
  local souls = 0
  for _, cmd in ipairs(seq()) do if cmd == "c soulsteal" then souls = souls + 1 end end
  expect(souls):eq(1)                      -- exactly the one attempt that failed, never again
end)

-- ---- the FALLBACK tier: icebolt → prism, probed only when BOTH primaries (lightning/fireball) underwhelm

test("the fallback tier is SKIPPED when a primary (lightning or fireball) already clears the threshold", function()
  AF.reset(); AF.on_fight(90, ENEMY); AF.tarrants()   -- opener → lightning
  AF.on_fight(70, ENEMY); AF.lightning()              -- lightning Δ20 (>= probe_enough) → fireball
  AF.on_fight(68, ENEMY); AF.fireball()                 -- fireball Δ2 → decide: 20 clears the bar → nuke, no fallback
  expect(AF.sent[#AF.sent]):eq(CMD.lightning)         -- decided → nuking lightning, never probed icebolt/prism
  for _, c in ipairs(seq()) do
    expect(c:find("prism", 1, true) == nil):eq(true)
    expect(c ~= "c icebolt"):eq(true)
  end
end)

test("the fallback tier IS probed when both primaries underwhelm: icebolt then prism, and prism can win", function()
  AF.reset(); AF.on_fight(90, ENEMY); AF.tarrants()   -- opener → lightning
  AF.on_fight(87, ENEMY); AF.lightning()              -- lightning Δ3 (< 5) → fireball
  AF.on_fight(85, ENEMY); AF.fireball()                 -- fireball Δ2 (< 5) → decide: both weak → fallback icebolt
  expect(seq()[#seq()]):eq("c icebolt")               -- first fallback probe went out
  AF.on_fight(84, ENEMY); AF.icebolt()                -- icebolt Δ1 → second fallback prism
  expect(seq()[#seq()]):eq("c prism")                 -- the prism probe went out
  AF.on_fight(63, ENEMY); AF.prism()                  -- prism Δ21 → decide: prism wins → nuke
  expect(AF.sent[#AF.sent]):eq("c prism")             -- nuking with the prism winner
  AF.prism()                                          -- nuke repeats prism (a probe would not) → winner=prism
  expect(AF.sent[#AF.sent]):eq("c prism")
end)

test("prism loses ties: a weak-but-tied icebolt (fallback) still beats prism after the probe", function()
  -- icebolt/prism must each clear fireball's handicap (fireball_drop + cfg.fireball_bias = 1+5 = 6) to be
  -- in contention at all, so this tie is driven at Δ7/Δ7 (was Δ4/Δ4 pre-bias) — same "tie" intent, just
  -- above fireball's now-preferred floor.
  AF.reset(); AF.on_fight(90, ENEMY); AF.tarrants()
  AF.on_fight(88, ENEMY); AF.lightning()              -- lightning Δ2 (< 5) → fireball
  AF.on_fight(87, ENEMY); AF.fireball()                 -- fireball Δ1 (< 5) → fallback icebolt
  AF.on_fight(80, ENEMY); AF.icebolt()                -- icebolt Δ7 (clears fireball's 1+bias=6 floor) → prism
  AF.on_fight(73, ENEMY); AF.prism()                  -- prism Δ7 — ties icebolt → icebolt keeps it → nuke icebolt
  expect(AF.sent[#AF.sent]):eq("c icebolt")
  AF.icebolt()                                        -- nuke repeats icebolt (not prism)
  expect(AF.sent[#AF.sent]):eq("c icebolt")
end)

test("a known prism winner skips the probe and nukes prism straight away", function()
  AF.reset()
  AF.remember("a Gnomian guard", "prism")             -- learned from a prior fight (prism is a valid winner now)
  expect(fight_nukes(ENEMY, "prism")):eq(true)        -- opener → known winner → nuke prism, no probe
  for _, cmd in ipairs(seq()) do expect(cmd == CMD.lightning):eq(false) end   -- the first probe cast never appears
end)

-- ---- bloodmist opener (only when HP can spare it) ------------------------------------------------

test("opener_cmd picks bloodmist above 50% HP, tarrants at/below (or unknown)", function()
  local sh, smh = state.hp, state.maxhp
  -- Drive a fresh fight at each HP level; the opener is the FIRST command it sends.
  local function opener_at(hp, mhp)
    state.hp, state.maxhp = hp, mhp
    AF.reset(); AF.on_fight(90, ENEMY)
    return AF.sent[1]
  end
  expect(opener_at(60, 100)):eq("c bloodmist")
  expect(opener_at(51, 100)):eq("c bloodmist")
  expect(opener_at(50, 100)):eq("c tarrants")   -- exactly 50% is NOT above
  expect(opener_at(20, 100)):eq("c tarrants")
  expect(opener_at(nil, nil)):eq("c tarrants")  -- unknown → safe default
  state.hp, state.maxhp = sh, smh
end)

test("the fight opens with bloodmist when HP is healthy, then hands off to the probe", function()
  local sh, smh = state.hp, state.maxhp
  state.hp, state.maxhp = 80, 100
  AF.reset(); AF.on_fight(90, ENEMY)                  -- opener chosen by HP → bloodmist
  expect(seq()[#seq()]):eq("c bloodmist")
  AF.bloodmist()                                      -- opener LANDED → lightning probe
  expect(seq()[#seq()]):eq(CMD.lightning)
  state.hp, state.maxhp = sh, smh
end)

-- ---- (b) THE SPAM GUARD: a flood of health-% updates while busy sends nothing --------------------
test("spam guard: a burst of health-% updates in flight sends ZERO commands", function()
  to_lightning()                      -- "cast 'lightning bolt'" in flight (busy)
  local n = #AF.sent
  -- the real health bar from the spam log: many kxwt_fighting ticks per second.
  for _, p in ipairs({ 88, 72, 71, 68, 67, 58, 57, 46, 45, 35, 24, 15, 8, 5, 3 }) do
    AF.on_fight(p, ENEMY)
  end
  expect(#AF.sent):eq(n)             -- NOT ONE extra command — this was the bug
  AF.lightning()                      -- only the actual LANDED line releases the next cast
  expect(#AF.sent):eq(n + 1)
  expect(AF.sent[n + 1]):eq("c fireball")
end)

-- ---- (c) pacing + retry --------------------------------------------------------------------------
test("pacing: a non-resolution line sends nothing; the landed line advances", function()
  to_lightning()
  local n = #AF.sent
  AF.on_fight(80, ENEMY)             -- a % tick: nothing
  expect(#AF.sent):eq(n)
  AF.lightning()                      -- lightning landed → next cast
  expect(#AF.sent):eq(n + 1)
  expect(AF.sent[n + 1]):eq("c fireball")
end)

test("a FAILED cast retries the SAME spell (not the next)", function()
  to_lightning()                      -- "cast 'lightning bolt'" in flight
  local n = #AF.sent
  AF.fail()                          -- a cast-fail line → retry
  expect(#AF.sent):eq(n + 1)
  expect(AF.sent[n + 1]):eq(CMD.lightning)   -- same spell
end)

test("an opener that keeps failing is given up after max_tries — never stalls", function()
  AF.reset(); AF.on_fight(90, ENEMY)       -- "c tarrants"
  for _ = 1, AF.cfg.max_tries do AF.fail() end   -- fizzles max_tries times (each after a fail line)
  expect(AF.sent[#AF.sent]):eq(CMD.lightning)     -- gave up on tarrants, moved on to the first probe
end)

-- fireball can BACKFIRE ("Your fireball backfires, and blows up in your face!") — it hit US, not the
-- target, so it's a FAILURE outcome routed to the same hit_fail() path as a fizzle ("You fail to cast the
-- spell 'fireball'."), NOT the landed stream: it must RETRY the same cast, never advance the probe/nuke
-- pointer, and count against cfg.max_tries like any other fizzle.
test("fireball BACKFIRE is treated as a failed attempt: retries fireball, doesn't advance the probe", function()
  to_lightning()
  AF.lightning()                      -- lightning landed → probe advances to "c fireball"
  expect(AF.sent[#AF.sent]):eq("c fireball")
  local n = #AF.sent
  AF.fail()                           -- the live trigger for a backfire calls this SAME handler
  expect(#AF.sent):eq(n + 1)
  expect(AF.sent[n + 1]):eq("c fireball")   -- retried fireball, did NOT advance to "decide"/nuke
end)

test("fireball that keeps backfiring is given up after max_tries — moves the probe on, never stalls", function()
  to_lightning()
  AF.lightning()                      -- lightning landed → "c fireball"
  for _ = 1, AF.cfg.max_tries do AF.fail() end   -- repeated backfire/fizzle → gaveup
  -- both primaries now exhausted with zero drop each → fallback tier: icebolt
  expect(AF.sent[#AF.sent]):eq("c icebolt")
end)

-- ---- (d) manual-input suspend --------------------------------------------------------------------
test("suspend: a user-typed command halts sends until the resume window", function()
  AF.reset(); AF.on_fight(90, ENEMY)       -- "c tarrants" (busy)
  expect(#AF.sent):eq(1)
  AF.on_input("kick guard")                -- the USER intervenes → suspends
  AF.tarrants()                            -- tarrants lands, but suspended → no probe cast
  expect(#AF.sent):eq(1)
  AF.expire_resume()                       -- resume window elapses → routine resumes
  expect(#AF.sent):eq(2)
  expect(AF.sent[2]):eq(CMD.lightning)
end)

test("suspend: our OWN sends echoing back do NOT suspend", function()
  AF.reset(); AF.on_fight(90, ENEMY)       -- we send "c tarrants"
  AF.on_input("c tarrants")                -- its echo returns through the input observer
  AF.tarrants()                            -- opener lands → NOT suspended → advances to the probe
  expect(#AF.sent):eq(2)
  expect(AF.sent[2]):eq(CMD.lightning)
end)

-- ---- (e) winner pick: bigger %-drop wins ---------------------------------------------------------
test("winner pick: lightning drops more than fireball → nuke with lightning", function()
  to_lightning()
  AF.on_fight(70, ENEMY); AF.lightning()    -- lightning Δ20 → "c fireball"
  AF.on_fight(65, ENEMY); AF.fireball()      -- fireball Δ5  → decide → nuke
  expect(AF.sent[#AF.sent]):eq(CMD.lightning)
end)

test("winner pick: fireball drops more than lightning → nuke with fireball", function()
  to_lightning()
  AF.on_fight(85, ENEMY); AF.lightning()    -- lightning Δ5  → "c fireball"
  AF.on_fight(60, ENEMY); AF.fireball()      -- fireball Δ25 → decide → nuke
  expect(AF.sent[#AF.sent]):eq("c fireball")
end)

-- fireball_bias: fireball is the PREFERRED winner — lightning must beat it by MORE than cfg.fireball_bias
-- (5 points), not just edge it out, or fireball keeps the pick (splash/AOE bonus).
test("winner pick bias: lightning beats fireball by <= the bias → fireball still wins (err toward fireball)", function()
  to_lightning()
  AF.on_fight(78, ENEMY); AF.lightning()    -- lightning Δ12 → "c fireball"
  AF.on_fight(68, ENEMY); AF.fireball()      -- fireball Δ10 → decide: 12 doesn't beat 10+bias(5)=15 → fireball
  expect(AF.sent[#AF.sent]):eq("c fireball")
end)

test("winner pick bias: lightning beats fireball by MORE than the bias → lightning wins handily", function()
  to_lightning()
  AF.on_fight(74, ENEMY); AF.lightning()    -- lightning Δ16 → "c fireball"
  AF.on_fight(64, ENEMY); AF.fireball()      -- fireball Δ10 → decide: 16 beats 10+bias(5)=15 → lightning
  expect(AF.sent[#AF.sent]):eq(CMD.lightning)
end)

-- ---- (f) robustness ------------------------------------------------------------------------------
test("out-of-mana stops that spell (no spam) and waits", function()
  to_lightning()
  AF.on_fight(70, ENEMY); AF.lightning()    -- → "c fireball"
  AF.on_fight(60, ENEMY); AF.fireball()      -- → winner lightning → nuke
  local n = #AF.sent
  AF.mana()                                -- "You don't have enough mana." → no retry, no spam
  expect(#AF.sent):eq(n)                   -- nothing more sent
  AF.on_fight(55, ENEMY)                   -- a later % tick doesn't re-cast the broke spell
  expect(#AF.sent):eq(n)
end)

test("soulsteal success line ends the routine cleanly", function()
  to_lightning()
  AF.on_fight(70, ENEMY); AF.lightning()
  AF.on_fight(60, ENEMY); AF.fireball()      -- winner lightning → nuke
  AF.lightning(); AF.on_fight(8, ENEMY)    -- landed → bar drops to ≤15% → "c soulsteal"
  expect(AF.sent[#AF.sent]):eq("c soulsteal")
  local n = #AF.sent
  AF.soulsteal_ok()
  expect(#AF.sent):eq(n)                   -- nothing more
end)

test("DEAD line ends the fight from any phase", function()
  AF.reset(); AF.on_fight(100, ENEMY)      -- fighting; opener "c tarrants" in flight
  expect(#AF.sent):eq(1)
  AF.dead()                                -- DEAD ends the fight
  AF.tarrants()                            -- the opener's landed line arrives AFTER death → must not advance
  expect(#AF.sent):eq(1)                   -- fight over: nothing more cast
end)

-- ---- engage(): starting a fight from OUT of combat (attack()'s core) -----------------------------
-- `target x` alone doesn't aggro, so engage() casts the opener (tarrants) to start combat, retrying it
-- until it lands; once combat starts the routine skips the opener and goes straight to the probe.

test("engage: target + opener, retry opener on fail, then hand off to the probe on combat start", function()
  AF.reset()
  local dead, failed = false, nil
  autofight.engage("orc", function() dead = true end, function(r) failed = r end)
  expect_seq(seq(), { "target orc", "c tarrants" })   -- set target, throw the opener
  AF.fail()                                            -- opener fizzled → retry the opener
  expect_seq(seq(), { "target orc", "c tarrants", "c tarrants" })
  AF.tarrants()                                        -- opener LANDED → wait for combat to start (no send)
  expect_seq(seq(), { "target orc", "c tarrants", "c tarrants" })
  AF.on_fight(90, ENEMY)                               -- combat starts → skip opener → first probe
  expect(AF.sent[#AF.sent]):eq(CMD.lightning)
  AF.on_fight_end()                                    -- fight over → on_dead fires once
  expect(dead):eq(true)
  expect(failed):eq(nil)
end)

-- REGRESSION: the DEAD line arrives BEFORE the trailing `kxwt_fighting -1`, and DEAD runs end_fight()
-- which clears F.fighting. The old guard was `F.fighting and F.on_dead`, so by the time -1 ran F.fighting
-- was already false and on_dead never fired — the attack() promise (and any `recover | attack` pipe row
-- adopting it) leaked forever. The fix latches F.fought at combat start; assert on_dead fires on the
-- normal DEAD-then-(-1) kill order.
test("engage: on_dead still fires when DEAD (clears F.fighting) precedes the kxwt -1", function()
  AF.reset()
  local dead = false
  autofight.engage("orc", function() dead = true end)
  AF.tarrants()                                        -- opener landed
  AF.on_fight(90, ENEMY)                               -- combat truly starts → F.fought latched
  AF.dead()                                            -- "... is DEAD!" → end_fight() zeroes F.fighting
  expect(dead):eq(false)                               -- on_dead does NOT fire on the DEAD line itself…
  AF.on_fight_end()                                    -- trailing kxwt -1 → on_dead must STILL resolve
  expect(dead):eq(true)
end)

test("engage: gives up (on_fail) after cfg.max_tries opener failures", function()
  AF.reset()
  local dead, failed = false, nil
  autofight.engage("orc", function() dead = true end, function(r) failed = r end)
  for _ = 1, AF.cfg.max_tries do AF.fail() end        -- opener never lands
  expect(failed):eq("cast failed")
  expect(dead):eq(false)
end)

test("engage: out of mana on the opener gives up immediately", function()
  AF.reset()
  local failed = nil
  autofight.engage("orc", function() end, function(r) failed = r end)
  AF.mana()                                            -- can't afford the opener → give up
  expect(failed):eq("out of mana")
end)

test("engage: target not in the room ('Target who?') gives up immediately (rejects attack)", function()
  AF.reset()
  local failed = nil
  autofight.engage("wombat", function() end, function(r) failed = r end)
  AF.target_missing()                                  -- "Target who?  You do not see that person here."
  expect(failed):eq("target not here")
end)

test("engage: 'Target who?' does nothing once the fight is actually underway", function()
  AF.reset()
  local failed = nil
  autofight.engage("orc", function() end, function(r) failed = r end)
  AF.on_fight(90, "orc")                                -- combat started → no longer engaging
  AF.target_missing()                                  -- a stray bad target mid-fight must not abort
  expect(failed):eq(nil)
end)

test("engage: a stray fight-end while still landing the opener does NOT resolve on_dead", function()
  AF.reset()
  local dead = false
  autofight.engage("orc", function() dead = true end)
  AF.on_fight_end()                                    -- -1 before combat ever started
  expect(dead):eq(false)
end)

-- ---- dormant soulsteal (latch) -------------------------------------------------------------------
-- Soulsteal can LATCH instead of stealing outright ("You magically latch onto <x>'s soul and wait for
-- <x> to weaken…") — the dread-portent/near-death dormant form. The soul isn't captured; if we stopped
-- casting we'd stall. So we keep nuking the winner (never re-casting soulsteal) until the latch fires.

test("soulsteal latch: keep nuking the winner, don't re-cast soulsteal, until it fires", function()
  to_lightning()
  AF.on_fight(70, ENEMY); AF.lightning()    -- → "c fireball"
  AF.on_fight(60, ENEMY); AF.fireball()      -- winner lightning → nuke
  AF.lightning(); AF.on_fight(8, ENEMY)    -- landed → bar drops to ≤15% → "c soulsteal"
  expect(AF.sent[#AF.sent]):eq("c soulsteal")
  AF.soul_latched()                        -- LATCHED (not stolen) → resume nuking the winner
  expect(AF.sent[#AF.sent]):eq(CMD.lightning) -- nuked again, NOT soulsteal
  -- Still ≤15%, but the latch guard keeps us nuking — never flips back to soulsteal.
  AF.lightning(); AF.on_fight(5, ENEMY)
  expect(AF.sent[#AF.sent]):eq(CMD.lightning)
  -- The latch finally activates: the steal success line, then DEAD, ends the fight cleanly.
  AF.soulsteal_ok()
  local n = #AF.sent
  AF.dead()
  expect(#AF.sent):eq(n)                    -- nothing more sent after done
end)

test("a fresh fight clears the soul_latched flag", function()
  to_lightning()
  AF.on_fight(70, ENEMY); AF.lightning()     -- → fireball
  AF.on_fight(60, ENEMY); AF.fireball()       -- decide → winner lightning → nuke
  AF.lightning(); AF.on_fight(8, ENEMY)     -- landed → bar drops to ≤15% → soulsteal
  AF.soul_latched()                          -- latched → back to nuking lightning
  AF.dead()                                  -- fight ends
  -- NEW fight vs the same name (winner lightning is now known): reaching ≤15% must SOULSTEAL again — a
  -- latch left set would keep nuking and never cast it, so the soulsteal send proves the flag cleared.
  AF.on_fight(90, ENEMY); AF.tarrants()      -- known winner → nuke lightning
  AF.lightning(); AF.on_fight(8, ENEMY)      -- landed → bar drops to ≤15% → "c soulsteal"
  expect(AF.sent[#AF.sent]):eq("c soulsteal")
end)

-- ---- finish timing: decide on the BAR boundary, not mid-frame (the off-by-one soulsteal fix) --------
-- The wire ordering is [spell lands][near-death line?] GA, THEN the next frame [kxwt_prompt]
-- [kxwt_fighting <newpct>] GA — the fresh % (and any near-death line ahead of it) lags the action into
-- the FOLLOWING frame. So the finish decision (nuke-winner vs switch-to-soulsteal) must run on THAT
-- kxwt_fighting update (on_fight — which IS the boundary, via barS), not synchronously on the raw landed
-- line (which read F.pct one hit stale → fired ONE extra winner-nuke before switching). An authoritative
-- near-death latch (F.finish_ready) switches even before the numeric pct crosses.

test("finish timing: a bar crossing ≤ soulsteal_pct on the FRESH pct switches to soulsteal — no extra nuke", function()
  to_lightning()
  AF.on_fight(70, ENEMY); AF.lightning()    -- probe → c fireball
  AF.on_fight(60, ENEMY); AF.fireball()      -- decide → winner lightning → nuke#1 (pct still 60)
  expect(AF.sent[#AF.sent]):eq(CMD.lightning)
  -- The winning hit LANDS; the fresh kxwt_fighting % arrives in the FOLLOWING frame, crossing the
  -- threshold. Historically the decision ran on the landed line itself (stale pct) → one extra winner-nuke.
  AF.lightning()                            -- nuke#1 lands (decision is deferred to the bar update)
  local n = #AF.sent
  AF.on_fight(12, ENEMY)                    -- the fresh % arrives → crosses ≤ soulsteal_pct → decide now
  expect(#AF.sent):eq(n + 1)                -- exactly ONE cast, not an extra winner-nuke first
  expect(AF.sent[#AF.sent]):eq("c soulsteal")
end)

test("finish timing: an authoritative near-death latch switches to soulsteal even while pct is still > threshold", function()
  to_lightning()
  AF.on_fight(70, ENEMY); AF.lightning()
  AF.on_fight(60, ENEMY); AF.fireball()      -- decide → winner lightning → nuke#1
  AF.lightning()                            -- nuke#1 lands (decision deferred)
  AF.near_death(ENEMY)                      -- the near-death line precedes the bar update, per the wire order
  local n = #AF.sent
  AF.on_fight(40, ENEMY)                    -- fresh pct still WELL above soulsteal_pct (15) — the boundary
  expect(#AF.sent):eq(n + 1)                -- the latch is authoritative → soulsteal despite pct 40
  expect(AF.sent[#AF.sent]):eq("c soulsteal")
end)

test("near-death from ANOTHER creature does not mis-latch (target-matched)", function()
  to_lightning()
  AF.on_fight(70, ENEMY); AF.lightning()
  AF.on_fight(60, ENEMY); AF.fireball()      -- winner lightning → nuke#1
  AF.lightning()                            -- nuke#1 lands
  AF.near_death("a passing bystander")     -- a DIFFERENT creature's near-death → must NOT latch
  AF.on_fight(40, ENEMY)                    -- the boundary → still above threshold, still nuking
  expect(AF.sent[#AF.sent]):eq(CMD.lightning)
end)

test("latched soulsteal → winner nuke only: never casts soulsteal again this fight, even if near-death re-fires", function()
  to_lightning()
  AF.on_fight(70, ENEMY); AF.lightning()
  AF.on_fight(60, ENEMY); AF.fireball()      -- winner lightning → nuke#1
  AF.lightning(); AF.on_fight(8, ENEMY)    -- landed → bar drops to ≤15% → "c soulsteal"
  expect(AF.sent[#AF.sent]):eq("c soulsteal")
  AF.soul_latched()                         -- LATCH → from here on it's winner-nuke ONLY
  expect(AF.sent[#AF.sent]):eq(CMD.lightning)
  -- Re-asserting near death / finish-ready must NOT bring soulsteal back this fight.
  for _ = 1, 3 do
    AF.near_death(ENEMY)
    AF.lightning(); AF.on_fight(5, ENEMY)
    expect(AF.sent[#AF.sent]):eq(CMD.lightning)
  end
  local souls = 0
  for _, cmd in ipairs(seq()) do if cmd == "c soulsteal" then souls = souls + 1 end end
  expect(souls):eq(1)                       -- exactly the one pre-latch attempt, never again
end)

test("soulsteal on a NON-LIVING target ('You can only soulsteal from living things') keeps nuking — no stall", function()
  -- Regression: this line had no terminator, so the soulsteal await hung and autofight went SILENT
  -- mid-fight (a metataur — a construct — got soul-stolen and the pilot froze until the human stepped in).
  to_lightning()
  AF.on_fight(70, ENEMY); AF.lightning()
  AF.on_fight(60, ENEMY); AF.fireball()      -- winner lightning
  AF.lightning(); AF.on_fight(8, ENEMY)    -- ≤15% → "c soulsteal"
  expect(AF.sent[#AF.sent]):eq("c soulsteal")
  AF.soul_unstealable()                     -- "You can only soulsteal from living things." → keep nuking
  expect(AF.sent[#AF.sent]):eq(CMD.lightning)   -- it did NOT go silent — back to nuking at once
  -- And it must not keep trying to soulsteal an unstealable target, even as it stays in finish range.
  for _ = 1, 3 do
    AF.near_death(ENEMY)
    AF.lightning(); AF.on_fight(5, ENEMY)
    expect(AF.sent[#AF.sent]):eq(CMD.lightning)
  end
  local souls = 0
  for _, cmd in ipairs(seq()) do if cmd == "c soulsteal" then souls = souls + 1 end end
  expect(souls):eq(1)                       -- exactly the one attempt that got rejected, never again
end)

test("a soulless target is REMEMBERED: a LATER fight vs the same name never casts soulsteal at all", function()
  -- FIRST fight: learn it's unstealable (the game rejects the one attempt). Persisted by name.
  to_lightning()
  AF.on_fight(70, ENEMY); AF.lightning()
  AF.on_fight(60, ENEMY); AF.fireball()      -- winner lightning
  AF.lightning(); AF.on_fight(8, ENEMY)    -- ≤15% → the ONE soulsteal attempt
  expect(AF.sent[#AF.sent]):eq("c soulsteal")
  AF.soul_unstealable()                     -- rejected → learned + persisted for this name
  expect(AF.is_unstealable(ENEMY)):eq(true)
  AF.dead()                                 -- enemy dies → fight ends (persistence survives)

  -- SECOND fight vs the SAME name (no reset — persistence must carry over): it stays in finish range the
  -- whole time and must NEVER cast soulsteal, just keep nuking the known winner.
  local before = #seq()
  AF.on_fight(90, ENEMY); land_opener()     -- fresh engagement
  for _ = 1, 4 do
    LAND[AF.sent[#AF.sent] == CMD.lightning and "lightning" or "fireball"]()
    AF.on_fight(5, ENEMY)                   -- deep in finish range every tick
    expect(AF.sent[#AF.sent]):eq(CMD.lightning)   -- winner nuke, never "c soulsteal"
  end
  local souls = 0
  for i = before + 1, #AF.sent do if AF.sent[i] == "c soulsteal" then souls = souls + 1 end end
  expect(souls):eq(0)                       -- not a single soulsteal in the whole second fight
end)

test("autofight.unstealable('name') forgets a soulless target so it tries soulsteal again", function()
  to_lightning()
  AF.on_fight(70, ENEMY); AF.lightning()
  AF.on_fight(60, ENEMY); AF.fireball()
  AF.lightning(); AF.on_fight(8, ENEMY)
  AF.soul_unstealable()
  expect(AF.is_unstealable(ENEMY)):eq(true)
  autofight.unstealable(ENEMY)              -- forget it
  expect(AF.is_unstealable(ENEMY)):eq(false)
end)

-- ---- dormant shower (kept, not probed) -----------------------------------------------------------
-- shower is no longer a probe (scorch replaced it) but is kept DORMANT — cfg.shower_cmd + hit_shower()
-- + its landed trigger stay in the file so a future feature (mana-aware spell switching) doesn't have
-- to re-source the strings. It must never actually cast, and its handler must no-op if it fires.

test("shower's command string is retained in cfg", function()
  -- NOTE: a config CONSTANT, not machine state. shower is dormant (never cast — see the next two tests),
  -- so its retention has no runtime-observable behaviour; this just pins the wire string still exists.
  expect(AF.cfg.shower_cmd):eq("c shower")
end)

test("shower is never cast during a fight (dormant, not in the routine)", function()
  to_lightning()
  AF.on_fight(70, ENEMY); AF.lightning()
  AF.on_fight(60, ENEMY); AF.fireball()      -- decide → nuke
  AF.lightning(); AF.on_fight(8, ENEMY)    -- landed → bar drops to ≤15% → soulsteal
  AF.soulsteal_ok(); AF.dead()
  for _, cmd in ipairs(seq()) do
    expect(cmd == AF.cfg.shower_cmd):eq(false)   -- "c shower" never appears
  end
end)

test("the dormant shower handler no-ops (a stray shower line can't advance the routine)", function()
  to_lightning()                            -- "cast 'lightning bolt'" in flight (busy on lightning)
  local n = #AF.sent
  AF.shower()                              -- the dead trigger fires → succeed('shower') → guard no-ops
  expect(#AF.sent):eq(n)                   -- nothing sent
  -- The routine is still waiting on the REAL lightning landed line — it alone advances to fireball.
  AF.lightning()
  expect(#AF.sent):eq(n + 1)
  expect(AF.sent[n + 1]):eq("c fireball")
end)

-- ---- learned winners (per target name) -----------------------------------------------------------
-- After the probe decides, the winner is remembered by target name; the NEXT fight against that name
-- skips the probe and nukes the known winner straight from the opener. Observed via fight_probes /
-- fight_nukes (what the next fight actually casts) rather than by inspecting the winners table.

test("winner_key normalizes: lowercased, leading article stripped", function()
  AF.reset()
  -- Learned under one spelling, matched across case + leading-article variants → the same normalized
  -- key, so the differently-spelled fight still skips the probe. (winner_key(nil)=nil has no observable
  -- consequence — a nil target name never reaches learning/lookup — so it isn't asserted here.)
  AF.remember("a Gnomian guard", "fireball")
  expect(fight_nukes("The GNOMIAN Guard", "fireball")):eq(true)   -- "the"/upper-case collapse to one key
  AF.on_fight_end()
  AF.remember("An orc", "icebolt")
  expect(fight_nukes("orc", "icebolt")):eq(true)                -- "an "/bare collapse to one key
  AF.on_fight_end()
end)

test("a decided probe is remembered under the target's name", function()
  to_lightning()                            -- reset() clears the winners table (hermetic)
  AF.on_fight(85, ENEMY); AF.lightning()    -- lightning Δ5  → fireball
  AF.on_fight(60, ENEMY); AF.fireball()      -- fireball Δ25 → decide → fireball wins → learned + nuke fireball
  expect(AF.sent[#AF.sent]):eq("c fireball")
  AF.on_fight_end()
  expect(fight_nukes(ENEMY, "fireball")):eq(true)   -- next fight vs the same name skips the probe → fireball
end)

test("a known winner SKIPS the probe: opener → straight to the known nuke", function()
  AF.reset()                               -- clears memory…
  AF.winners()["gnomian guard"] = "fireball" -- …then seed a known winner (driving the scenario)
  expect(fight_nukes(ENEMY, "fireball")):eq(true)   -- opener → straight to the known nuke, no probe
  for _, cmd in ipairs(seq()) do expect(cmd == CMD.lightning):eq(false) end   -- the first probe cast never appears
end)

test("engage() with a known winner goes opener → known nuke (no probe)", function()
  AF.reset()
  AF.winners()["gnomian guard"] = "icebolt"
  autofight.engage(ENEMY)                  -- target + opener; opener_primed
  AF.tarrants()                            -- opener landed (engaging)…
  AF.on_fight(90, ENEMY)                   -- …combat starts → primed + known → straight to nuke
  expect(AF.sent[#AF.sent]):eq("c icebolt")
end)

test("forget(name) drops one entry; forget() clears all", function()
  AF.reset()
  AF.winners()["gnomian guard"] = "fireball"
  AF.winners()["orc"] = "icebolt"
  autofight.forget("a Gnomian guard")      -- normalized to "gnomian guard"
  expect(fight_probes(ENEMY)):eq(true)     -- gnomian re-probes now
  AF.on_fight_end()
  expect(fight_nukes("an orc", "icebolt")):eq(true)   -- orc's winner untouched → still skips the probe
  AF.on_fight_end()
  autofight.forget()                       -- clear all
  expect(fight_probes("an orc")):eq(true)  -- orc re-probes now too
  AF.on_fight_end()
end)

-- ---- target change mid-combat WITHOUT a kxwt -1 (the "rolled onto the next mob" bug) --------------

-- These isolate the RESTART mechanism (bug fix), so they force aoe='off' to see the single-target
-- opener; the pack→frostflower behaviour of a rollover under the default 'auto' is covered in the AOE
-- section below. start_fight clear_sent()s for a clean per-fight sequence, so after a restart AF.sent
-- holds ONLY the new fight: exactly the fresh opener. (#==1 distinguishes a real restart from "no
-- restart, stale fireball still the last thing sent".)
test("a NAME change mid-combat (no -1) starts the routine over on the new enemy", function()
  to_lightning(); AF.state().aoe_mode = "off"   -- c tarrants, cast 'lightning bolt'; probing ENEMY (single-target)
  AF.on_fight(70, ENEMY); AF.lightning()        -- → c fireball (mid-probe, fireball in flight)
  AF.on_fight(72, "a crimson topaz")           -- DIFFERENT target, no -1 → start over
  expect(AF.sent[1]):eq("c tarrants")          -- fresh opener on the new enemy
  expect(#AF.sent):eq(1)
end)

test("a health bar that jumps UP (same name, new instance) also starts over", function()
  to_lightning(); AF.state().aoe_mode = "off"   -- c tarrants, cast 'lightning bolt'
  AF.on_fight(70, ENEMY); AF.lightning()        -- c fireball
  AF.on_fight(6, ENEMY)                         -- previous ape nearly dead
  AF.on_fight(78, ENEMY)                        -- same name but 6→78 jump ⇒ new instance → start over
  expect(AF.sent[1]):eq("c tarrants")
  expect(#AF.sent):eq(1)
end)

test("ordinary health drops (and a tiny up-bounce) never restart or cast", function()
  to_lightning()                                -- c tarrants, cast 'lightning bolt'
  local before = #AF.sent
  AF.on_fight(70, ENEMY)                        -- drop
  AF.on_fight(50, ENEMY)                        -- drop
  AF.on_fight(53, ENEMY)                        -- +3 bounce (< new_target_jump) — still the same enemy
  expect(#AF.sent):eq(before)                   -- health ticks send NOTHING; no spurious opener
end)

-- ---- AOE / frostflower (crowd handling) ----------------------------------------------------------
-- AOE is observed by what the routine casts: "c frostflower" (AOE) vs a single-target "cast 'lightning
-- bolt'"/"c fireball". The in-flight cast has to LAND before the next one goes out, so we land it to read the
-- routine's current choice.

test("aoe 'on' frostflowers immediately — skips the single-target opener and probe", function()
  AF.reset(); AF.state().aoe_mode = "on"
  AF.on_fight(90, ENEMY)                       -- start → straight to AOE
  expect(AF.sent[1]):eq("c frostflower")
  AF.frostflower()                             -- landed → cast again (repeat)
  expect(AF.sent[2]):eq("c frostflower")
end)

test("aoe 'auto': a rollover ALONE does not AOE — AOE is driven by the crowd COUNT", function()
  AF.reset()                                   -- aoe_mode auto, no crowd counted
  AF.on_fight(90, ENEMY); AF.tarrants()        -- fresh single: c tarrants → cast 'lightning bolt'
  AF.on_fight(72, "a crimson topaz")           -- rollover, no count set → still single-target
  expect(AF.sent[1]):eq("c tarrants")          -- fresh single-target opener on the new enemy (not frostflower)
  expect(#AF.sent):eq(1)
end)

test("aoe 'auto': crowd whittled to the last one drops back to single target (the exit fix)", function()
  AF.reset()
  AF.on_fight(90, ENEMY); AF.tarrants()        -- fighting; c tarrants → cast 'lightning bolt' in flight
  AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape")   -- look: 2 hostiles → AOE
  AF.lightning()                               -- in-flight lightning lands → next cast is AOE
  expect(AF.sent[#AF.sent]):eq("c frostflower")
  AF.mdeath("A dire ape")                      -- one dies → estimate below pack size
  AF.frostflower()                             -- in-flight frostflower lands → back to single target
  expect(AF.sent[#AF.sent]):ne("c frostflower")   -- a single-target spell now, not another AOE
  expect(AF.sent[#AF.sent]):eq("c fireball")
end)

test("aoe 'off' never AOEs, even with a pack-sized crowd count", function()
  AF.reset(); AF.state().aoe_mode = "off"
  AF.on_fight(90, ENEMY); AF.tarrants()        -- c tarrants → cast 'lightning bolt' in flight
  AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape")
  AF.lightning()                               -- lands → single-target next (forced off regardless of count)
  expect(AF.sent[#AF.sent]):eq("c fireball")
  for _, cmd in ipairs(seq()) do expect(cmd == "c frostflower"):eq(false) end
end)

test("crowd count + AOE reset when combat truly ends (kxwt -1)", function()
  AF.reset()
  AF.on_fight(90, ENEMY); AF.tarrants()        -- c tarrants → cast 'lightning bolt' in flight
  AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape")
  AF.lightning()                               -- lands → AOE cast (confirms we're packed)
  expect(AF.sent[#AF.sent]):eq("c frostflower")
  AF.on_fight_end()                            -- -1 → combat over → crowd estimate zeroed
  AF.on_fight(90, ENEMY)                       -- a NEW fight → single-target opener (pack was reset)
  expect(AF.sent[1]):eq("c tarrants")
  expect(#AF.sent):eq(1)
end)

test("a hostile mdeath below the count doesn't go negative; our minion's death doesn't count", function()
  AF.reset()
  AF.on_fight(90, ENEMY); AF.tarrants()        -- c tarrants → cast 'lightning bolt' in flight
  state.name, state.group = "Vaelith", { { name = "A skeletal spider" } }
  AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape")   -- est 2 → AOE
  AF.lightning()                               -- lands → frostflower
  expect(AF.sent[#AF.sent]):eq("c frostflower")
  AF.mdeath("A skeletal spider")               -- our minion — NOT counted → still a pack
  AF.frostflower()                             -- lands → still AOE
  expect(AF.sent[#AF.sent]):eq("c frostflower")
  AF.mdeath("A dire ape"); AF.mdeath("A dire ape"); AF.mdeath("A dire ape")  -- floors at 0
  AF.frostflower()                             -- lands → single target now
  expect(AF.sent[#AF.sent]):ne("c frostflower")
  state.name, state.group = nil, nil
end)

test("aoe 'auto': a look showing multiple enemies fighting flips to AOE WITHOUT a kill", function()
  AF.reset()
  AF.on_fight(90, ENEMY); AF.tarrants()        -- single-target: c tarrants → cast 'lightning bolt' in flight
  AF.room_fighter("A dire ape")                -- look: ONE engaged hostile — not a pack
  AF.lightning()                               -- lands → single-target (one enemy isn't a pack)
  expect(AF.sent[#AF.sent]):eq("c fireball")
  AF.room_fighter("A dire ape")                -- a SECOND engaged hostile (own line) → pack!
  AF.fireball()                                  -- the in-flight fireball lands → next cast is AOE
  expect(AF.sent[#AF.sent]):eq("c frostflower")
end)

test("room crowd-count ignores our own minions/self — only hostiles count", function()
  AF.reset()
  AF.on_fight(90, ENEMY); AF.tarrants()        -- c tarrants → cast 'lightning bolt' in flight
  state.name  = "Vaelith"
  state.group = { { name = "A skeletal spider" }, { name = "Vaelith" } }
  AF.room_fighter("A skeletal spider")         -- our minion fighting a mob — not an enemy
  AF.room_fighter("Vaelith")                   -- ourself — not an enemy
  AF.lightning()                               -- lands → single-target (nothing hostile counted)
  expect(AF.sent[#AF.sent]):eq("c fireball")
  AF.room_fighter("A dire ape")                -- two real hostiles
  AF.room_fighter("A crimson topaz")
  AF.fireball()                                  -- lands → AOE now
  expect(AF.sent[#AF.sent]):eq("c frostflower")
  state.name, state.group = nil, nil
end)

-- aoe_cast: fireball does splash/AOE damage, so if fireball is the CHOSEN winner an AOE keeps nuking it
-- instead of backing off to the dedicated frostflower — any OTHER winner still backs up to frostflower.
test("AOE with a fireball winner keeps casting fireball (splash) instead of backing up to frostflower", function()
  AF.reset()
  AF.winners()["gnomian guard"] = "fireball"          -- known winner → skip probe, nuke fireball
  AF.on_fight(90, ENEMY); AF.tarrants()               -- opener → known winner → "c fireball" in flight
  expect(AF.sent[#AF.sent]):eq("c fireball")
  AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape")   -- pack forms mid-fight
  AF.fireball(); AF.on_fight(85, ENEMY)               -- landed → bar boundary → next nuke decision reads AOE
  expect(AF.sent[#AF.sent]):eq("c fireball")          -- keeps fireball (splash), NOT frostflower
  AF.on_fight_end()
end)

test("AOE with a lightning winner backs up to frostflower (only a fireball winner keeps its own cast)", function()
  AF.reset()
  AF.winners()["gnomian guard"] = "lightning"         -- known winner → skip probe, nuke lightning
  AF.on_fight(90, ENEMY); AF.tarrants()               -- opener → known winner → "cast 'lightning bolt'" in flight
  expect(AF.sent[#AF.sent]):eq(CMD.lightning)
  AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape")   -- pack forms mid-fight
  AF.lightning(); AF.on_fight(85, ENEMY)              -- landed → bar boundary → next nuke decision reads AOE
  expect(AF.sent[#AF.sent]):eq("c frostflower")       -- backs up to the dedicated room AOE
  AF.on_fight_end()
end)

test("a peaceful look (not fighting) never arms AOE", function()
  AF.reset()                                   -- not fighting
  AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape")
  AF.on_fight(90, ENEMY)                        -- start a fight → single-target opener (no pack armed)
  expect(AF.sent[1]):eq("c tarrants")
  expect(#AF.sent):eq(1)
end)

-- ---- fight-as-a-promise --------------------------------------------------------------------------
local function fight_widget_has(desc)
  for _, e in ipairs(active_promises()) do if e.desc == desc then return true end end
  return false
end

test("a fresh fight is a tracked promise that shows in the widget and resolves when combat ends", function()
  AF.reset()
  _PROMISE_TEST.cancel_all()
  AF.on_fight(90, "a gnoll warrior")            -- fresh engagement → start_fight → promise
  expect(AF.fight_promise() ~= nil):eq(true)
  expect(fight_widget_has("autofight: a gnoll warrior")):eq(true)
  AF.on_fight_end()                             -- combat over → resolve
  expect(AF.fight_promise()):eq(nil)
  expect(fight_widget_has("autofight: a gnoll warrior")):eq(false)
end)

test("a target rollover retitles the SAME promise, not a second one", function()
  AF.reset()
  _PROMISE_TEST.cancel_all()
  AF.on_fight(90, "a gnoll warrior")
  local p1 = AF.fight_promise()
  AF.on_fight(80, "a gnoll pup")                -- name change mid-combat (no -1) → rollover
  expect(AF.fight_promise()):eq(p1)             -- same promise object
  expect(fight_widget_has("autofight: a gnoll pup")):eq(true)      -- retitled to the new target
  expect(fight_widget_has("autofight: a gnoll warrior")):eq(false)
  AF.on_fight_end()
end)

test("autofight.current() exposes the in-flight promise, nil when not fighting", function()
  AF.reset()
  _PROMISE_TEST.cancel_all()
  expect(autofight.current()):eq(nil)
  AF.on_fight(90, "a rat")
  expect(autofight.current() ~= nil):eq(true)
  AF.on_fight_end()
  expect(autofight.current()):eq(nil)
end)

-- ---- manual winner override (autofight.winner) ---------------------------------------------------
test("autofight.winner sets/overrides the learned attack for a target and persists it; 'none' clears", function()
  AF.reset()
  autofight.winner("undead marsh troll", "fireball")
  expect(fight_nukes("undead marsh troll", "fireball")):eq(true)   -- set → next fight skips probe, nukes fireball
  AF.on_fight_end()
  autofight.winner("undead marsh troll", "icebolt")             -- re-override to the other element
  expect(fight_nukes("undead marsh troll", "icebolt")):eq(true)
  AF.on_fight_end()
  autofight.winner("undead marsh troll", "none")                -- forget → re-probe next time
  expect(fight_probes("undead marsh troll")):eq(true)
  AF.on_fight_end()
end)

test("autofight.winner rejects a spell that isn't lightning/icebolt/fireball/prism (memory untouched)", function()
  AF.reset()
  autofight.winner("a rat", "frostflower")       -- not a probe spell → rejected
  expect(fight_probes("a rat")):eq(true)         -- rejected → still probes (nothing learned)
  AF.on_fight_end()
  autofight.winner("a rat", "lightning")         -- lightning IS a valid winner now → accepted
  expect(fight_nukes("a rat", "lightning")):eq(true)
  AF.on_fight_end()
end)

test("autofight.winner switches the CURRENT fight immediately (stops casting the wrong spell)", function()
  AF.reset()
  AF.on_fight(90, "a wraith")                            -- fresh fight → opener, would normally probe
  autofight.winner("a wraith", "fireball")                 -- override mid-fight (before the probe)
  AF.tarrants()                                          -- opener lands → nukes the override, never probes
  expect(AF.sent[#AF.sent]):eq("c fireball")
  for _, cmd in ipairs(seq()) do expect(cmd == CMD.lightning):eq(false) end   -- never probed
  AF.on_fight_end()
end)

-- A mid-fight override must redirect the CURRENT fight even when it lands DURING an already in-flight
-- stage (not just before the probe starts, like the test above) — both while the PROBE is walking its
-- pointer and while fightLoop is mid-nuke on a resolved winner.
test("autofight.winner override during the PROBE stage redirects the very next cast", function()
  AF.reset()
  AF.on_fight(90, "a wraith")                            -- opener → probe starts
  AF.tarrants()                                          -- opener lands → probe's first primary cast in flight
  expect(AF.sent[#AF.sent]):eq(CMD.lightning)
  autofight.winner("a wraith", "icebolt")                  -- override WHILE the lightning probe is in flight
  AF.lightning()                                         -- in-flight lightning lands → probe bails on the override
  expect(AF.sent[#AF.sent]):eq("c icebolt")               -- redirected, never reached "c fireball"
  for _, cmd in ipairs(seq()) do expect(cmd == "c fireball"):eq(false) end
  AF.on_fight_end()
end)

test("autofight.winner override during the NUKE stage redirects the very next cast", function()
  to_lightning()
  AF.on_fight(70, ENEMY); AF.lightning()                 -- lightning Δ20 → "c fireball"
  AF.on_fight(65, ENEMY); AF.fireball()                    -- fireball Δ5 → decide → winner lightning → nuke#1
  expect(AF.sent[#AF.sent]):eq(CMD.lightning)
  autofight.winner(ENEMY, "prism")                         -- override WHILE nuke#1 is in flight
  AF.lightning(); AF.on_fight(50, ENEMY)                 -- nuke#1 lands → bar boundary → reads the override
  expect(AF.sent[#AF.sent]):eq("c prism")
  AF.on_fight_end()
end)

-- ---- probe-spell swap + versioned winners migration ----------------------------------------------
test("is_probe_spell knows only the CURRENT probe spells", function()
  -- Observable via what a seeded winner does: a CURRENT probe spell (prism) is trusted → skip the probe
  -- and nuke it; a RETIRED spell (shards) is ignored → re-probe. (is_probe_spell(icebolt/fireball)=true is
  -- exercised throughout; is_probe_spell(nil)=false has no observable path — a nil spell is never learned.)
  AF.reset()
  AF.winners()["gnomian guard"] = "prism"           -- prism is a current probe spell → trusted
  expect(fight_nukes(ENEMY, "prism")):eq(true)
  AF.on_fight_end()
  AF.winners()["gnomian guard"] = "shards"           -- retired → ignored
  expect(fight_probes(ENEMY)):eq(true)
  AF.on_fight_end()
end)

test("a RETIRED spell left in the winners table is ignored → the target re-probes (not a stale nuke)", function()
  AF.reset()
  AF.winners()["gnomian guard"] = "shards"          -- a pre-swap entry the migration would drop / ignore
  AF.on_fight(90, ENEMY)                             -- fresh fight vs "a Gnomian guard"
  AF.tarrants()                                      -- opener landed → 'shards' isn't current → PROBE, don't nuke
  expect(AF.sent[#AF.sent]):eq(CMD.lightning)
  AF.lightning()                                     -- probe continues → fireball (confirms probing, not nuking)
  expect(AF.sent[#AF.sent]):eq("c fireball")
  AF.on_fight_end()
end)

test("a winner for a CURRENT probe spell (fireball) is trusted this session — skips the probe", function()
  AF.reset()
  AF.winners()["gnomian guard"] = "fireball"          -- fireball is one of today's probe spells
  AF.on_fight(90, ENEMY)
  AF.tarrants()                                      -- opener → straight to the known nuke, no probe
  expect(AF.sent[#AF.sent]):eq("c fireball")
  AF.fireball()                                        -- nuke repeats fireball (a probe would go lightning→fireball)
  expect(AF.sent[#AF.sent]):eq("c fireball")
  for _, cmd in ipairs(seq()) do expect(cmd == CMD.lightning):eq(false) end
  AF.on_fight_end()
end)

-- migrate_winners(raw, recorded) is the pure decision the on-disk load (and the every-load live-reload
-- prune) both apply: on a spell-set MISMATCH the whole table is stale — even an entry whose spell is
-- STILL a current probe spell (e.g. lightning survived the scorch→fireball swap) was picked by comparing
-- it against the OLD lineup, so it can't be trusted either — the routine clears everything and re-probes
-- every target fresh, rather than the old "keep still-valid entries" selective prune.
test("migrate_winners: a spell-set MISMATCH wipes ALL entries, even ones for still-current spells", function()
  local raw = { ["gnomian guard"] = "lightning", ["orc"] = "prism", ["troll"] = "shards" }
  local kept, matched = AF.migrate_winners(raw, "icebolt,lightning,prism,shards")   -- an old, different set
  expect(matched):eq(false)
  local n = 0; for _ in pairs(kept) do n = n + 1 end
  expect(n):eq(0)   -- lightning/prism survived as probe spells, but the WHOLE table is still cleared
end)

test("migrate_winners: a MATCHING spell-set is trusted as-is (still filtered to current probe spells)", function()
  local raw = { ["gnomian guard"] = "lightning", ["orc"] = "prism" }
  local kept, matched = AF.migrate_winners(raw, AF.spellset_key())   -- the CURRENT set
  expect(matched):eq(true)
  expect(kept["gnomian guard"]):eq("lightning")
  expect(kept["orc"]):eq("prism")
end)

test("migrate_winners: no recorded set (v1 file / nil) is treated as a mismatch → wipes all", function()
  local raw = { ["gnomian guard"] = "lightning" }
  local kept, matched = AF.migrate_winners(raw, nil)
  expect(matched):eq(false)
  local n = 0; for _ in pairs(kept) do n = n + 1 end
  expect(n):eq(0)
end)

-- ---- tank rescue: a dead clay-man/flesh-beast tank → corpse off + re-summon ----------------------
-- The tank is a minion of ours (group flag M) that's tanking (flag T). When it DIES we turn off corpse
-- automation and re-cast 'clay man' until one rejoins. Detection: kxwt_ydeath (your OWN minion died —
-- enemies emit kxwt_mdeath, a dismiss/flee emits neither) latches "a minion died"; the following roster
-- says whether it was the tank (our remembered tank is now gone). A tank that merely lost its T flag
-- between fights, or left benignly (no ydeath), must NOT trigger a rescue. Observed via the two side
-- effects a rescue produces: corpse automation turning OFF and the "cast 'clay man'" re-summon send.

local function tank_reset()
  AF.reset()
  local T = AF.tank(); T.on, T.name, T.resummoning, T.tries, T.timer = true, nil, false, 0, nil
  _AA_TEST.corpse.on = true                          -- start with corpse automation ON
  state.name, state.group = "Vaelith", nil
end

test("tank_scan: the minion flagged M+T is the tank; a plain minion or an ally player is not", function()
  tank_reset()
  -- A roster with a leader (you), a plain minion, and the M+T tank: only the M+T one's death rescues.
  state.group = {
    { name = "Vaelith",     flags = "XL" },          -- you (leader)
    { name = "A skeletal spider", flags = "M" },     -- your minion, NOT tanking
    { name = "A clay man",  flags = "MT" },           -- your minion, tanking → the tank
  }
  AF.tank_refresh()                                   -- tracks the M+T clay man as the tank
  AF.tank_ydeath()                                   -- a minion of mine died…
  state.group = { { name = "Vaelith", flags = "XL" }, { name = "A skeletal spider", flags = "M" } }  -- …the clay man is gone
  local before = #AF.sent
  AF.tank_refresh()
  expect(_AA_TEST.corpse.on):eq(false)               -- the M+T member was the tank → rescue fired
  expect(AF.sent[#AF.sent]):eq(AF.cfg.clay_cmd)      -- (the plain minion / leader would not have)
  expect(#AF.sent):eq(before + 1)
  state.name, state.group = nil, nil
end)

test("tank dies (kxwt_ydeath then roster drops it): corpse automation OFF + re-cast clay man", function()
  tank_reset()
  state.group = { { name = "Vaelith", flags = "XL" }, { name = "A flesh beast", flags = "MT" } }
  AF.tank_refresh()                                   -- roster shows the tank → remembered
  AF.tank_ydeath()                                   -- kxwt_ydeath "flesh beastie" — a minion of mine died
  state.group = { { name = "Vaelith", flags = "XL" } }  -- the FOLLOWING roster drops it
  local before = #AF.sent
  AF.tank_refresh()
  expect(_AA_TEST.corpse.on):eq(false)               -- (1) corpse automation disabled
  expect(AF.sent[#AF.sent]):eq(AF.cfg.clay_cmd)      -- (2) first re-summon cast went out
  expect(#AF.sent):eq(before + 1)
end)

test("the tank LEAVING benignly (dismiss/flee — no kxwt_ydeath) does NOT rescue", function()
  tank_reset()
  state.group = { { name = "A flesh beast", flags = "MT" } }
  AF.tank_refresh()
  local before = #AF.sent
  state.group = {}                                    -- gone, but NO ydeath latched → benign leave
  AF.tank_refresh()
  expect(#AF.sent):eq(before)                        -- no re-summon
  expect(_AA_TEST.corpse.on):eq(true)                -- corpse automation untouched
end)

test("a NON-tank minion dying (ydeath, but the tank is still grouped) does NOT rescue", function()
  tank_reset()
  state.group = {
    { name = "A flesh beast", flags = "MT" },          -- the tank
    { name = "A skeletal spider", flags = "M" },        -- a plain minion
  }
  AF.tank_refresh()
  local before = #AF.sent
  AF.tank_ydeath()                                   -- a minion died...
  state.group = { { name = "A flesh beast", flags = "MT" } }  -- ...but the SPIDER; tank still tanking
  AF.tank_refresh()
  expect(_AA_TEST.corpse.on):eq(true)                -- tank still here → death latch consumed harmlessly
  expect(#AF.sent):eq(before)                        -- no re-summon
end)

test("a tank merely BETWEEN fights (still grouped, just not tanking) is NOT rescued", function()
  tank_reset()
  state.group = { { name = "A flesh beast", flags = "MT" } }
  AF.tank_refresh()
  local before = #AF.sent
  state.group = { { name = "A flesh beast", flags = "M" } }   -- alive, still grouped, no T flag right now
  AF.tank_refresh()
  expect(#AF.sent):eq(before)                        -- still in the group → alive → no re-summon
  expect(_AA_TEST.corpse.on):eq(true)
end)

test("re-summon stops as soon as a clay man rejoins the group", function()
  tank_reset()
  state.group = { { name = "A flesh beast", flags = "MT" } }
  AF.tank_refresh()
  AF.tank_ydeath()
  state.group = {}                                    -- tank died + gone
  AF.tank_refresh()
  expect(AF.sent[#AF.sent]):eq(AF.cfg.clay_cmd)      -- rescue underway (re-summoning)
  local said = capture_echo(function() AF.tank_resummoned() end)   -- "You add A clay man to your group."
  expect(said):contains("new tank up")               -- loop acknowledged the rejoin and stopped
end)

test("tank rescue can be disabled: autofight.tank('off') suppresses the response", function()
  tank_reset()
  autofight.tank("off")
  state.group = { { name = "A flesh beast", flags = "MT" } }
  AF.tank_refresh()
  local before = #AF.sent
  AF.tank_ydeath()
  state.group = {}
  AF.tank_refresh()
  expect(_AA_TEST.corpse.on):eq(true)                -- disabled → no action
  expect(#AF.sent):eq(before)
  autofight.tank("on")                                -- restore for later tests
end)

-- ---- prompt bridge (nomelee) ------------------------------------------------------------------------
-- The fighting PROMPT is the game's authoritative answer: Prompt.lua's apply_prompt calls
-- __autofight_prompt (exposed here as AF.prompt_bridge) with the parsed fight_pct/fight_name, and it
-- ALWAYS drives combat, stamping "the prompt is live" as it goes. kxwt_fighting (AF.kxwt_fight/kxwt_end)
-- is only a FALLBACK, and is ignored while the prompt is live — this is what stops a flaky tank-rescue
-- kxwt_fighting -1 flip from prematurely ending a fight the prompt still says is ongoing (nomelee bug).
-- When the prompt never fires at all (normal play, no custom kxwq prompt), last_prompt stays stale and
-- kxwt drives exactly as before — no regression.

test("prompt bridge starts and ends a fight (prompt is authoritative)", function()
  AF.reset()
  AF.mark_prompt(0)
  AF.prompt_bridge(90, ENEMY)                         -- fresh engagement, prompt-driven
  expect_seq(seq(), { "c tarrants" })                 -- same opener a kxwt-driven start_fight would send
  land_opener()
  AF.prompt_bridge(nil, nil)                          -- prompt says not-fighting → end the fight
  expect(AF.state().fighting):eq(false)
end)

test("a stray kxwt_fighting -1 (tank-rescue flip) is ignored while the prompt is live", function()
  AF.reset()
  AF.mark_prompt(0)
  AF.prompt_bridge(90, ENEMY)                         -- prompt starts the fight, stamps last_prompt = now
  land_opener()
  expect(AF.state().fighting):eq(true)
  AF.kxwt_end()                                       -- the rescue flip's spurious "kxwt_fighting -1"
  expect(AF.state().fighting):eq(true)                -- still live — the stray kxwt end was ignored
end)

test("kxwt drives as a fallback when the prompt is stale (normal play, no nomelee prompt)", function()
  AF.reset()
  AF.mark_prompt(0)                                   -- prompt never fired — stale
  AF.kxwt_fight(90, ENEMY)
  expect_seq(seq(), { "c tarrants" })                  -- kxwt drove the engagement directly
  expect(AF.state().fighting):eq(true)
end)
