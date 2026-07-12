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
-- dispatch to (AF.icebolt/AF.scorch/AF.resist/… via _AF_TEST) plus the kxwt_fighting handler (AF.on_fight)
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
  icebolt = AF.icebolt, scorch = AF.scorch, prism = AF.prism,
  tarrants = AF.tarrants, bloodmist = AF.bloodmist, frostflower = AF.frostflower,
}
-- Land whichever opener a fresh fight cast (tarrants or the HP-gated bloodmist).
local OPENER_LAND = { ["c tarrants"] = AF.tarrants, ["c bloodmist"] = AF.bloodmist }
local function land_opener() OPENER_LAND[AF.sent[#AF.sent]]() end

-- Get to "c icebolt in flight": start the fight (casts the tarrants opener), land tarrants → icebolt.
local function to_icebolt()
  AF.reset()
  AF.on_fight(90, ENEMY)   -- combat start → "c tarrants"
  AF.tarrants()            -- tarrants LANDED → "c icebolt"
end

-- Behaviour probes for learned-winner PERSISTENCE (all observable, no internal reads): start a FRESH
-- fight vs `name` (assumes we're not currently fighting) and watch what it casts.
--   fight_probes(name)     → true if it PROBES: opener, then "c icebolt", then (on the icebolt landing)
--                            "c scorch" — the two-spell probe, i.e. no learned winner.
--   fight_nukes(name,spell)→ true if it SKIPS the probe and NUKES `spell` off the opener: opener, then
--                            "c <spell>", and (on that landing) "c <spell>" again — a repeat nuke, which
--                            a one-shot probe cast would never do.
local function fight_probes(name)
  AF.on_fight(90, name); land_opener()
  if AF.sent[#AF.sent] ~= "c icebolt" then return false end
  AF.icebolt()
  return AF.sent[#AF.sent] == "c scorch"
end
local function fight_nukes(name, spell)
  local cmd = "c " .. spell
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
test("full fight: tarrants → icebolt/scorch probe → nuke winner → soulsteal (resist → re-nuke → retry)", function()
  to_icebolt()                        -- sent: c tarrants, c icebolt
  AF.on_fight(70, ENEMY)             -- icebolt Δ20 — a % change NEVER casts
  AF.icebolt()                        -- icebolt LANDED → "c scorch"
  AF.on_fight(65, ENEMY)             -- scorch Δ5
  AF.scorch()                        -- scorch LANDED → decide (icebolt wins) → nuke "c icebolt"
  AF.on_fight(50, ENEMY); AF.icebolt()  -- landed → "c icebolt"
  AF.on_fight(35, ENEMY); AF.icebolt()  -- landed → "c icebolt"
  AF.on_fight(20, ENEMY); AF.icebolt()  -- landed → "c icebolt"
  AF.on_fight(10, ENEMY); AF.icebolt()  -- landed, now ≤15% → "c soulsteal"
  AF.resist()                        -- soulsteal RESISTED → re-nuke → "c icebolt"
  AF.icebolt()                        -- re-nuke landed → "c soulsteal"
  AF.soulsteal_ok()                  -- landed → done (no further sends)
  AF.dead()                          -- enemy dead → fight ends

  expect_seq(seq(), {
    "c tarrants",
    "c icebolt", "c scorch",                          -- probes
    "c icebolt", "c icebolt", "c icebolt", "c icebolt",  -- winner nuked (65→50→35→20→10)
    "c soulsteal",                                   -- finish attempt
    "c icebolt",                                      -- re-nuke after the resist
    "c soulsteal",                                   -- retry — lands
  })
  -- icebolt was learned as the winner: the NEXT fight vs the same name skips the probe and nukes icebolt.
  expect(fight_nukes(ENEMY, "icebolt")):eq(true)
end)

-- ---- prism: the conditional third probe (only when icebolt/scorch underwhelm) --------------------

test("prism is SKIPPED when icebolt or scorch already clears the threshold", function()
  AF.reset(); AF.on_fight(90, ENEMY); AF.tarrants()   -- opener → icebolt
  AF.on_fight(70, ENEMY); AF.icebolt()                -- icebolt Δ20 (>= probe_enough) → scorch
  AF.on_fight(68, ENEMY); AF.scorch()                 -- scorch Δ2 → decide: 20 clears the bar → nuke, no prism
  expect(AF.sent[#AF.sent]):eq("c icebolt")           -- decided → nuking icebolt, never probed prism
  for _, c in ipairs(seq()) do expect(c:find("prism", 1, true) == nil):eq(true) end
end)

test("prism IS probed when both icebolt and scorch underwhelm, and can win", function()
  AF.reset(); AF.on_fight(90, ENEMY); AF.tarrants()   -- opener → icebolt
  AF.on_fight(87, ENEMY); AF.icebolt()                -- icebolt Δ3 (< 5) → scorch
  AF.on_fight(85, ENEMY); AF.scorch()                 -- scorch Δ2 (< 5) → decide: both weak → probe prism
  expect(seq()[#seq()]):eq("c prism")                 -- the prism probe went out
  AF.on_fight(63, ENEMY); AF.prism()                  -- prism Δ22 → decide: prism wins → nuke
  expect(AF.sent[#AF.sent]):eq("c prism")             -- nuking with the prism winner
  AF.prism()                                          -- nuke repeats prism (a probe would not) → winner=prism
  expect(AF.sent[#AF.sent]):eq("c prism")
end)

test("prism loses ties: a weak-but-tied icebolt still beats prism after the probe", function()
  AF.reset(); AF.on_fight(90, ENEMY); AF.tarrants()
  AF.on_fight(86, ENEMY); AF.icebolt()                -- icebolt Δ4
  AF.on_fight(85, ENEMY); AF.scorch()                 -- scorch Δ1 → probe prism (max 4 < 5)
  AF.on_fight(81, ENEMY); AF.prism()                  -- prism Δ4 — ties icebolt → icebolt keeps it → nuke icebolt
  expect(AF.sent[#AF.sent]):eq("c icebolt")
  AF.icebolt()                                        -- nuke repeats icebolt (not prism)
  expect(AF.sent[#AF.sent]):eq("c icebolt")
end)

test("a known prism winner skips the probe and nukes prism straight away", function()
  AF.reset()
  AF.remember("a Gnomian guard", "prism")             -- learned from a prior fight (prism is a valid winner now)
  expect(fight_nukes(ENEMY, "prism")):eq(true)        -- opener → known winner → nuke prism, no probe
  for _, cmd in ipairs(seq()) do expect(cmd == "c icebolt"):eq(false) end
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
  AF.bloodmist()                                      -- opener LANDED → icebolt probe
  expect(seq()[#seq()]):eq("c icebolt")
  state.hp, state.maxhp = sh, smh
end)

-- ---- (b) THE SPAM GUARD: a flood of health-% updates while busy sends nothing --------------------
test("spam guard: a burst of health-% updates in flight sends ZERO commands", function()
  to_icebolt()                        -- "c icebolt" in flight (busy)
  local n = #AF.sent
  -- the real health bar from the spam log: many kxwt_fighting ticks per second.
  for _, p in ipairs({ 88, 72, 71, 68, 67, 58, 57, 46, 45, 35, 24, 15, 8, 5, 3 }) do
    AF.on_fight(p, ENEMY)
  end
  expect(#AF.sent):eq(n)             -- NOT ONE extra command — this was the bug
  AF.icebolt()                        -- only the actual LANDED line releases the next cast
  expect(#AF.sent):eq(n + 1)
  expect(AF.sent[n + 1]):eq("c scorch")
end)

-- ---- (c) pacing + retry --------------------------------------------------------------------------
test("pacing: a non-resolution line sends nothing; the landed line advances", function()
  to_icebolt()
  local n = #AF.sent
  AF.on_fight(80, ENEMY)             -- a % tick: nothing
  expect(#AF.sent):eq(n)
  AF.icebolt()                        -- icebolt landed → next cast
  expect(#AF.sent):eq(n + 1)
  expect(AF.sent[n + 1]):eq("c scorch")
end)

test("a FAILED cast retries the SAME spell (not the next)", function()
  to_icebolt()                        -- "c icebolt" in flight
  local n = #AF.sent
  AF.fail()                          -- "You fail to cast the spell 'icebolt'." → retry
  expect(#AF.sent):eq(n + 1)
  expect(AF.sent[n + 1]):eq("c icebolt")   -- same spell
end)

test("an opener that keeps failing is given up after max_tries — never stalls", function()
  AF.reset(); AF.on_fight(90, ENEMY)       -- "c tarrants"
  for _ = 1, AF.cfg.max_tries do AF.fail() end   -- fizzles max_tries times (each after a fail line)
  expect(AF.sent[#AF.sent]):eq("c icebolt")       -- gave up on tarrants, moved on
end)

-- ---- (d) manual-input suspend --------------------------------------------------------------------
test("suspend: a user-typed command halts sends until the resume window", function()
  AF.reset(); AF.on_fight(90, ENEMY)       -- "c tarrants" (busy)
  expect(#AF.sent):eq(1)
  AF.on_input("kick guard")                -- the USER intervenes → suspends
  AF.tarrants()                            -- tarrants lands, but suspended → no "c icebolt"
  expect(#AF.sent):eq(1)
  AF.expire_resume()                       -- resume window elapses → routine resumes
  expect(#AF.sent):eq(2)
  expect(AF.sent[2]):eq("c icebolt")
end)

test("suspend: our OWN sends echoing back do NOT suspend", function()
  AF.reset(); AF.on_fight(90, ENEMY)       -- we send "c tarrants"
  AF.on_input("c tarrants")                -- its echo returns through the input observer
  AF.tarrants()                            -- opener lands → NOT suspended → advances to "c icebolt"
  expect(#AF.sent):eq(2)
  expect(AF.sent[2]):eq("c icebolt")
end)

-- ---- (e) winner pick: bigger %-drop wins ---------------------------------------------------------
test("winner pick: icebolt drops more than scorch → nuke with icebolt", function()
  to_icebolt()
  AF.on_fight(70, ENEMY); AF.icebolt()      -- icebolt Δ20 → "c scorch"
  AF.on_fight(65, ENEMY); AF.scorch()      -- scorch Δ5  → decide → nuke
  expect(AF.sent[#AF.sent]):eq("c icebolt")
end)

test("winner pick: scorch drops more than icebolt → nuke with scorch", function()
  to_icebolt()
  AF.on_fight(85, ENEMY); AF.icebolt()      -- icebolt Δ5  → "c scorch"
  AF.on_fight(60, ENEMY); AF.scorch()      -- scorch Δ25 → decide → nuke
  expect(AF.sent[#AF.sent]):eq("c scorch")
end)

-- ---- (f) robustness ------------------------------------------------------------------------------
test("out-of-mana stops that spell (no spam) and waits", function()
  to_icebolt()
  AF.on_fight(70, ENEMY); AF.icebolt()      -- → "c scorch"
  AF.on_fight(60, ENEMY); AF.scorch()      -- → winner icebolt → nuke "c icebolt"
  local n = #AF.sent
  AF.mana()                                -- "You don't have enough mana." → no retry, no spam
  expect(#AF.sent):eq(n)                   -- nothing more sent
  AF.on_fight(55, ENEMY)                   -- a later % tick doesn't re-cast the broke spell
  expect(#AF.sent):eq(n)
end)

test("soulsteal success line ends the routine cleanly", function()
  to_icebolt()
  AF.on_fight(70, ENEMY); AF.icebolt()
  AF.on_fight(60, ENEMY); AF.scorch()      -- winner icebolt → nuke
  AF.on_fight(8, ENEMY);  AF.icebolt()      -- landed, ≤15% → "c soulsteal"
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
  AF.on_fight(90, ENEMY)                               -- combat starts → skip opener → "c icebolt"
  expect(AF.sent[#AF.sent]):eq("c icebolt")
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
  to_icebolt()
  AF.on_fight(70, ENEMY); AF.icebolt()      -- → "c scorch"
  AF.on_fight(60, ENEMY); AF.scorch()      -- winner icebolt → nuke "c icebolt"
  AF.on_fight(8, ENEMY);  AF.icebolt()      -- landed, ≤15% → "c soulsteal"
  expect(AF.sent[#AF.sent]):eq("c soulsteal")
  AF.soul_latched()                        -- LATCHED (not stolen) → resume nuking the winner
  expect(AF.sent[#AF.sent]):eq("c icebolt") -- nuked again, NOT soulsteal
  -- Still ≤15%, but the latch guard keeps us nuking — never flips back to soulsteal.
  AF.on_fight(5, ENEMY); AF.icebolt()
  expect(AF.sent[#AF.sent]):eq("c icebolt")
  -- The latch finally activates: the steal success line, then DEAD, ends the fight cleanly.
  AF.soulsteal_ok()
  local n = #AF.sent
  AF.dead()
  expect(#AF.sent):eq(n)                    -- nothing more sent after done
end)

test("a fresh fight clears the soul_latched flag", function()
  to_icebolt()
  AF.on_fight(70, ENEMY); AF.icebolt()       -- → scorch
  AF.on_fight(60, ENEMY); AF.scorch()       -- decide → winner icebolt → nuke
  AF.on_fight(8, ENEMY);  AF.icebolt()       -- ≤15% → soulsteal
  AF.soul_latched()                          -- latched → back to nuking icebolt
  AF.dead()                                  -- fight ends
  -- NEW fight vs the same name (winner icebolt is now known): reaching ≤15% must SOULSTEAL again — a
  -- latch left set would keep nuking and never cast it, so the soulsteal send proves the flag cleared.
  AF.on_fight(90, ENEMY); AF.tarrants()      -- known winner → nuke "c icebolt"
  AF.on_fight(8, ENEMY);  AF.icebolt()       -- ≤15% → "c soulsteal"
  expect(AF.sent[#AF.sent]):eq("c soulsteal")
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
  to_icebolt()
  AF.on_fight(70, ENEMY); AF.icebolt()
  AF.on_fight(60, ENEMY); AF.scorch()      -- decide → nuke
  AF.on_fight(8, ENEMY);  AF.icebolt()      -- ≤15% → soulsteal
  AF.soulsteal_ok(); AF.dead()
  for _, cmd in ipairs(seq()) do
    expect(cmd == AF.cfg.shower_cmd):eq(false)   -- "c shower" never appears
  end
end)

test("the dormant shower handler no-ops (a stray shower line can't advance the routine)", function()
  to_icebolt()                              -- "c icebolt" in flight (busy on icebolt)
  local n = #AF.sent
  AF.shower()                              -- the dead trigger fires → succeed('shower') → guard no-ops
  expect(#AF.sent):eq(n)                   -- nothing sent
  -- The routine is still waiting on the REAL icebolt landed line — it alone advances to scorch.
  AF.icebolt()
  expect(#AF.sent):eq(n + 1)
  expect(AF.sent[n + 1]):eq("c scorch")
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
  AF.remember("a Gnomian guard", "scorch")
  expect(fight_nukes("The GNOMIAN Guard", "scorch")):eq(true)   -- "the"/upper-case collapse to one key
  AF.on_fight_end()
  AF.remember("An orc", "icebolt")
  expect(fight_nukes("orc", "icebolt")):eq(true)                -- "an "/bare collapse to one key
  AF.on_fight_end()
end)

test("a decided probe is remembered under the target's name", function()
  to_icebolt()                              -- reset() clears the winners table (hermetic)
  AF.on_fight(85, ENEMY); AF.icebolt()      -- icebolt Δ5  → scorch
  AF.on_fight(60, ENEMY); AF.scorch()      -- scorch Δ25 → decide → scorch wins → learned + nuke scorch
  expect(AF.sent[#AF.sent]):eq("c scorch")
  AF.on_fight_end()
  expect(fight_nukes(ENEMY, "scorch")):eq(true)   -- next fight vs the same name skips the probe → scorch
end)

test("a known winner SKIPS the probe: opener → straight to the known nuke", function()
  AF.reset()                               -- clears memory…
  AF.winners()["gnomian guard"] = "scorch" -- …then seed a known winner (driving the scenario)
  expect(fight_nukes(ENEMY, "scorch")):eq(true)   -- opener → straight to the known nuke, no probe
  for _, cmd in ipairs(seq()) do expect(cmd == "c icebolt"):eq(false) end   -- probe spells never appear
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
  AF.winners()["gnomian guard"] = "scorch"
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
-- restart, stale scorch still the last thing sent".)
test("a NAME change mid-combat (no -1) starts the routine over on the new enemy", function()
  to_icebolt(); AF.state().aoe_mode = "off"     -- c tarrants, c icebolt; probing ENEMY (single-target)
  AF.on_fight(70, ENEMY); AF.icebolt()          -- → c scorch (mid-probe, scorch in flight)
  AF.on_fight(72, "a crimson topaz")           -- DIFFERENT target, no -1 → start over
  expect(AF.sent[1]):eq("c tarrants")          -- fresh opener on the new enemy
  expect(#AF.sent):eq(1)
end)

test("a health bar that jumps UP (same name, new instance) also starts over", function()
  to_icebolt(); AF.state().aoe_mode = "off"     -- c tarrants, c icebolt
  AF.on_fight(70, ENEMY); AF.icebolt()          -- c scorch
  AF.on_fight(6, ENEMY)                         -- previous ape nearly dead
  AF.on_fight(78, ENEMY)                        -- same name but 6→78 jump ⇒ new instance → start over
  expect(AF.sent[1]):eq("c tarrants")
  expect(#AF.sent):eq(1)
end)

test("ordinary health drops (and a tiny up-bounce) never restart or cast", function()
  to_icebolt()                                  -- c tarrants, c icebolt
  local before = #AF.sent
  AF.on_fight(70, ENEMY)                        -- drop
  AF.on_fight(50, ENEMY)                        -- drop
  AF.on_fight(53, ENEMY)                        -- +3 bounce (< new_target_jump) — still the same enemy
  expect(#AF.sent):eq(before)                   -- health ticks send NOTHING; no spurious opener
end)

-- ---- AOE / frostflower (crowd handling) ----------------------------------------------------------
-- AOE is observed by what the routine casts: "c frostflower" (AOE) vs a single-target "c icebolt"/
-- "c scorch". The in-flight cast has to LAND before the next one goes out, so we land it to read the
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
  AF.on_fight(90, ENEMY); AF.tarrants()        -- fresh single: c tarrants → c icebolt
  AF.on_fight(72, "a crimson topaz")           -- rollover, no count set → still single-target
  expect(AF.sent[1]):eq("c tarrants")          -- fresh single-target opener on the new enemy (not frostflower)
  expect(#AF.sent):eq(1)
end)

test("aoe 'auto': crowd whittled to the last one drops back to single target (the exit fix)", function()
  AF.reset()
  AF.on_fight(90, ENEMY); AF.tarrants()        -- fighting; c tarrants → c icebolt in flight
  AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape")   -- look: 2 hostiles → AOE
  AF.icebolt()                                 -- in-flight icebolt lands → next cast is AOE
  expect(AF.sent[#AF.sent]):eq("c frostflower")
  AF.mdeath("A dire ape")                      -- one dies → estimate below pack size
  AF.frostflower()                             -- in-flight frostflower lands → back to single target
  expect(AF.sent[#AF.sent]):ne("c frostflower")   -- a single-target spell now, not another AOE
  expect(AF.sent[#AF.sent]):eq("c scorch")
end)

test("aoe 'off' never AOEs, even with a pack-sized crowd count", function()
  AF.reset(); AF.state().aoe_mode = "off"
  AF.on_fight(90, ENEMY); AF.tarrants()        -- c tarrants → c icebolt in flight
  AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape")
  AF.icebolt()                                 -- lands → single-target next (forced off regardless of count)
  expect(AF.sent[#AF.sent]):eq("c scorch")
  for _, cmd in ipairs(seq()) do expect(cmd == "c frostflower"):eq(false) end
end)

test("crowd count + AOE reset when combat truly ends (kxwt -1)", function()
  AF.reset()
  AF.on_fight(90, ENEMY); AF.tarrants()        -- c tarrants → c icebolt in flight
  AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape")
  AF.icebolt()                                 -- lands → AOE cast (confirms we're packed)
  expect(AF.sent[#AF.sent]):eq("c frostflower")
  AF.on_fight_end()                            -- -1 → combat over → crowd estimate zeroed
  AF.on_fight(90, ENEMY)                       -- a NEW fight → single-target opener (pack was reset)
  expect(AF.sent[1]):eq("c tarrants")
  expect(#AF.sent):eq(1)
end)

test("a hostile mdeath below the count doesn't go negative; our minion's death doesn't count", function()
  AF.reset()
  AF.on_fight(90, ENEMY); AF.tarrants()        -- c tarrants → c icebolt in flight
  state.name, state.group = "Vaelith", { { name = "A skeletal spider" } }
  AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape")   -- est 2 → AOE
  AF.icebolt()                                 -- lands → frostflower
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
  AF.on_fight(90, ENEMY); AF.tarrants()        -- single-target: c tarrants → c icebolt in flight
  AF.room_fighter("A dire ape")                -- look: ONE engaged hostile — not a pack
  AF.icebolt()                                 -- lands → single-target (one enemy isn't a pack)
  expect(AF.sent[#AF.sent]):eq("c scorch")
  AF.room_fighter("A dire ape")                -- a SECOND engaged hostile (own line) → pack!
  AF.scorch()                                  -- the in-flight scorch lands → next cast is AOE
  expect(AF.sent[#AF.sent]):eq("c frostflower")
end)

test("room crowd-count ignores our own minions/self — only hostiles count", function()
  AF.reset()
  AF.on_fight(90, ENEMY); AF.tarrants()        -- c tarrants → c icebolt in flight
  state.name  = "Vaelith"
  state.group = { { name = "A skeletal spider" }, { name = "Vaelith" } }
  AF.room_fighter("A skeletal spider")         -- our minion fighting a mob — not an enemy
  AF.room_fighter("Vaelith")                   -- ourself — not an enemy
  AF.icebolt()                                 -- lands → single-target (nothing hostile counted)
  expect(AF.sent[#AF.sent]):eq("c scorch")
  AF.room_fighter("A dire ape")                -- two real hostiles
  AF.room_fighter("A crimson topaz")
  AF.scorch()                                  -- lands → AOE now
  expect(AF.sent[#AF.sent]):eq("c frostflower")
  state.name, state.group = nil, nil
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
  autofight.winner("undead marsh troll", "scorch")
  expect(fight_nukes("undead marsh troll", "scorch")):eq(true)   -- set → next fight skips probe, nukes scorch
  AF.on_fight_end()
  autofight.winner("undead marsh troll", "icebolt")             -- re-override to the other element
  expect(fight_nukes("undead marsh troll", "icebolt")):eq(true)
  AF.on_fight_end()
  autofight.winner("undead marsh troll", "none")                -- forget → re-probe next time
  expect(fight_probes("undead marsh troll")):eq(true)
  AF.on_fight_end()
end)

test("autofight.winner rejects a spell that isn't icebolt/scorch (memory untouched)", function()
  AF.reset()
  autofight.winner("a rat", "frostflower")
  expect(fight_probes("a rat")):eq(true)         -- rejected → still probes (nothing learned)
  AF.on_fight_end()
end)

test("autofight.winner switches the CURRENT fight immediately (stops casting the wrong spell)", function()
  AF.reset()
  AF.on_fight(90, "a wraith")                            -- fresh fight → opener, would normally probe
  autofight.winner("a wraith", "scorch")                 -- override mid-fight (before the probe)
  AF.tarrants()                                          -- opener lands → nukes the override, never probes
  expect(AF.sent[#AF.sent]):eq("c scorch")
  for _, cmd in ipairs(seq()) do expect(cmd == "c icebolt"):eq(false) end   -- never probed icebolt
  AF.on_fight_end()
end)

-- ---- probe-spell swap + versioned winners migration ----------------------------------------------
test("is_probe_spell knows only the CURRENT probe spells", function()
  -- Observable via what a seeded winner does: a CURRENT probe spell (prism) is trusted → skip the probe
  -- and nuke it; a RETIRED spell (shards) is ignored → re-probe. (is_probe_spell(icebolt/scorch)=true is
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
  expect(AF.sent[#AF.sent]):eq("c icebolt")
  AF.icebolt()                                       -- probe continues → scorch (confirms probing, not nuking)
  expect(AF.sent[#AF.sent]):eq("c scorch")
  AF.on_fight_end()
end)

test("a still-valid winner (scorch) is trusted after the swap — skips the probe", function()
  AF.reset()
  AF.winners()["gnomian guard"] = "scorch"          -- scorch survived the swap
  AF.on_fight(90, ENEMY)
  AF.tarrants()                                      -- opener → straight to the known nuke, no probe
  expect(AF.sent[#AF.sent]):eq("c scorch")
  AF.scorch()                                        -- nuke repeats scorch (a probe would go icebolt→scorch)
  expect(AF.sent[#AF.sent]):eq("c scorch")
  for _, cmd in ipairs(seq()) do expect(cmd == "c icebolt"):eq(false) end
  AF.on_fight_end()
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
