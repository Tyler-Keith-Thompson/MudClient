-- Specs for AutoFight.lua — the deterministic auto-fight state machine.
--
-- These drive the ACTUAL state machine by calling the SAME resolution handlers the live Swift triggers
-- dispatch to (AF.icebolt/AF.scorch/AF.resist/… via _AF_TEST) plus the kxwt_fighting handler (AF.on_fight)
-- and the input observer (AF.on_input). The trigger REGEXES live in one place — the trigger() block in
-- AutoFight.lua — and run in Swift; there is no second Lua line-matcher to drift, so the specs test the
-- state-machine LOGIC, not the matching.
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

-- Get to "c icebolt in flight": start the fight (casts the tarrants opener), land tarrants → icebolt.
local function to_icebolt()
  AF.reset()
  AF.on_fight(90, ENEMY)   -- combat start → "c tarrants"
  AF.tarrants()            -- tarrants LANDED → "c icebolt"
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
  local F = AF.state()
  expect(F.winner_spell):eq("icebolt")
  expect(F.fighting):eq(false)
  expect(F.phase):eq("idle")
end)

-- ---- (b) THE SPAM GUARD: a flood of health-% updates while busy sends nothing --------------------
test("spam guard: a burst of health-% updates in flight sends ZERO commands", function()
  to_icebolt()                        -- "c icebolt" in flight (busy)
  local n = #AF.sent
  expect(AF.state().busy):eq(true)
  -- the real health bar from the spam log: many kxwt_fighting ticks per second.
  for _, p in ipairs({ 88, 72, 71, 68, 67, 58, 57, 46, 45, 35, 24, 15, 8, 5, 3 }) do
    AF.on_fight(p, ENEMY)
  end
  expect(#AF.sent):eq(n)             -- NOT ONE extra command — this was the bug
  expect(AF.state().busy):eq(true)   -- still waiting on the icebolt landed line
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
  AF.on_input("kick guard")                -- the USER intervenes
  expect(AF.state().suspended):eq(true)
  AF.tarrants()                            -- tarrants lands, but suspended → no "c icebolt"
  expect(#AF.sent):eq(1)
  AF.expire_resume()                       -- resume window elapses
  expect(AF.state().suspended):eq(false)
  expect(#AF.sent):eq(2)
  expect(AF.sent[2]):eq("c icebolt")
end)

test("suspend: our OWN sends echoing back do NOT suspend", function()
  AF.reset(); AF.on_fight(90, ENEMY)       -- we send "c tarrants"
  AF.on_input("c tarrants")                -- its echo returns through the input observer
  expect(AF.state().suspended):eq(false)
end)

-- ---- (e) winner pick: bigger %-drop wins ---------------------------------------------------------
test("winner pick: icebolt drops more than scorch → nuke with icebolt", function()
  to_icebolt()
  AF.on_fight(70, ENEMY); AF.icebolt()      -- icebolt Δ20 → "c scorch"
  AF.on_fight(65, ENEMY); AF.scorch()      -- scorch Δ5  → decide → nuke
  local F = AF.state()
  expect(F.icebolt_drop):eq(20)
  expect(F.scorch_drop):eq(5)
  expect(F.winner_spell):eq("icebolt")
  expect(AF.sent[#AF.sent]):eq("c icebolt")
end)

test("winner pick: scorch drops more than icebolt → nuke with scorch", function()
  to_icebolt()
  AF.on_fight(85, ENEMY); AF.icebolt()      -- icebolt Δ5  → "c scorch"
  AF.on_fight(60, ENEMY); AF.scorch()      -- scorch Δ25 → decide → nuke
  local F = AF.state()
  expect(F.scorch_drop):eq(25)
  expect(F.winner_spell):eq("scorch")
  expect(AF.sent[#AF.sent]):eq("c scorch")
end)

-- ---- (f) robustness ------------------------------------------------------------------------------
test("out-of-mana stops that spell (no spam) and waits", function()
  to_icebolt()
  AF.on_fight(70, ENEMY); AF.icebolt()      -- → "c scorch"
  AF.on_fight(60, ENEMY); AF.scorch()      -- → winner icebolt → nuke "c icebolt"
  local n = #AF.sent
  AF.mana()                                -- "You don't have enough mana."
  expect(AF.state().no_mana["icebolt"]):eq(true)
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
  expect(AF.state().phase):eq("done")
  expect(#AF.sent):eq(n)                   -- nothing more
end)

test("DEAD line ends the fight from any phase", function()
  AF.reset(); AF.on_fight(100, ENEMY)
  expect(AF.state().fighting):eq(true)
  AF.dead()
  expect(AF.state().fighting):eq(false)
  expect(AF.state().phase):eq("idle")
end)

-- ---- engage(): starting a fight from OUT of combat (attack()'s core) -----------------------------
-- `target x` alone doesn't aggro, so engage() casts the opener (tarrants) to start combat, retrying it
-- until it lands; once combat starts the routine skips the opener and goes straight to the probe.

test("engage: target + opener, retry opener on fail, then hand off to the probe on combat start", function()
  AF.reset()
  local dead, failed = false, nil
  autofight.engage("orc", function() dead = true end, function(r) failed = r end)
  expect_seq(seq(), { "target orc", "c tarrants" })   -- set target, throw the opener
  expect(AF.state().engaging):eq(true)
  AF.fail()                                            -- opener fizzled → retry the opener
  expect_seq(seq(), { "target orc", "c tarrants", "c tarrants" })
  AF.tarrants()                                        -- opener LANDED → wait for combat to start (no send)
  expect_seq(seq(), { "target orc", "c tarrants", "c tarrants" })
  AF.on_fight(90, ENEMY)                               -- combat starts → skip opener → "c icebolt"
  expect(AF.state().engaging):eq(false)
  expect(AF.state().phase):eq("icebolt")
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
  expect(AF.state().fighting):eq(false)
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
  expect(AF.state().engaging):eq(false)
end)

test("engage: out of mana on the opener gives up immediately", function()
  AF.reset()
  local failed = nil
  autofight.engage("orc", function() end, function(r) failed = r end)
  AF.mana()                                            -- can't afford the opener → give up
  expect(failed):eq("out of mana")
  expect(AF.state().engaging):eq(false)
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
  expect(AF.state().soul_latched):eq(true)
  expect(AF.state().phase):eq("nuke")
  expect(AF.sent[#AF.sent]):eq("c icebolt") -- nuked again, NOT soulsteal
  -- Still ≤15%, but the latch guard keeps us nuking — never flips back to soulsteal.
  AF.on_fight(5, ENEMY); AF.icebolt()
  expect(AF.sent[#AF.sent]):eq("c icebolt")
  -- The latch finally activates: the steal success line, then DEAD, ends the fight cleanly.
  AF.soulsteal_ok()
  expect(AF.state().phase):eq("done")
  local n = #AF.sent
  AF.dead()
  expect(AF.state().fighting):eq(false)
  expect(#AF.sent):eq(n)                    -- nothing more sent after done
end)

test("a fresh fight clears the soul_latched flag", function()
  to_icebolt()
  AF.on_fight(70, ENEMY); AF.icebolt()       -- → scorch
  AF.on_fight(60, ENEMY); AF.scorch()       -- decide → winner icebolt → nuke
  AF.on_fight(8, ENEMY);  AF.icebolt()       -- ≤15% → soulsteal
  AF.soul_latched()
  expect(AF.state().soul_latched):eq(true)
  AF.dead()                                 -- fight ends
  AF.reset(); AF.on_fight(100, ENEMY)       -- new fight
  expect(AF.state().soul_latched):eq(false)
end)

-- ---- dormant shower (kept, not probed) -----------------------------------------------------------
-- shower is no longer a probe (scorch replaced it) but is kept DORMANT — cfg.shower_cmd + hit_shower()
-- + its landed trigger stay in the file so a future feature (mana-aware spell switching) doesn't have
-- to re-source the strings. It must never actually cast, and its handler must no-op if it fires.

test("shower's command string is retained in cfg", function()
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
  local phase = AF.state().phase
  AF.shower()                              -- the dead trigger fires → succeed('shower') → guard no-ops
  expect(#AF.sent):eq(n)                   -- nothing sent
  expect(AF.state().phase):eq(phase)       -- phase unchanged (busy_spell was 'icebolt', not 'shower')
  expect(AF.state().busy):eq(true)         -- still waiting on the real icebolt landed line
end)

-- ---- learned winners (per target name) -----------------------------------------------------------
-- After the probe decides, the winner is remembered by target name; the NEXT fight against that name
-- skips the probe and nukes the known winner straight from the opener.

test("winner_key normalizes: lowercased, leading article stripped", function()
  expect(AF.winner_key("a Gnomian guard")):eq("gnomian guard")
  expect(AF.winner_key("The old fisherman Omno")):eq("old fisherman omno")
  expect(AF.winner_key("An orc")):eq("orc")
  expect(AF.winner_key(nil)):eq(nil)
end)

test("a decided probe is remembered under the target's name", function()
  to_icebolt()                              -- reset() clears the winners table (hermetic)
  AF.on_fight(85, ENEMY); AF.icebolt()      -- icebolt Δ5  → scorch
  AF.on_fight(60, ENEMY); AF.scorch()      -- scorch Δ25 → decide → scorch wins → learned
  expect(AF.winners()["gnomian guard"]):eq("scorch")
end)

test("a known winner SKIPS the probe: opener → straight to the known nuke", function()
  AF.reset()                               -- clears memory…
  AF.winners()["gnomian guard"] = "scorch" -- …then seed a known winner
  AF.on_fight(90, ENEMY)                   -- combat start → "c tarrants" (no probe scheduled)
  expect(AF.state().known_winner):eq("scorch")
  AF.tarrants()                            -- opener landed → skip icebolt/scorch → nuke the known winner
  expect(AF.state().phase):eq("nuke")
  expect(AF.sent[#AF.sent]):eq("c scorch")
  -- keep nuking scorch to the end; the probe spells never appear
  AF.on_fight(40, ENEMY); AF.scorch()
  for _, cmd in ipairs(seq()) do expect(cmd == "c icebolt"):eq(false) end
end)

test("engage() with a known winner goes opener → known nuke (no probe)", function()
  AF.reset()
  AF.winners()["gnomian guard"] = "icebolt"
  autofight.engage(ENEMY)                  -- target + opener; opener_primed
  AF.tarrants()                            -- opener landed (engaging)…
  AF.on_fight(90, ENEMY)                   -- …combat starts → primed + known → straight to nuke
  expect(AF.state().phase):eq("nuke")
  expect(AF.sent[#AF.sent]):eq("c icebolt")
end)

test("forget(name) drops one entry; forget() clears all", function()
  AF.reset()
  AF.winners()["gnomian guard"] = "scorch"
  AF.winners()["orc"] = "icebolt"
  autofight.forget("a Gnomian guard")      -- normalized to "gnomian guard"
  expect(AF.winners()["gnomian guard"]):eq(nil)
  expect(AF.winners()["orc"]):eq("icebolt")
  autofight.forget()                       -- clear all
  expect(next(AF.winners())):eq(nil)
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

test("aoe 'on' frostflowers immediately — skips the single-target opener and probe", function()
  AF.reset(); AF.state().aoe_mode = "on"
  AF.on_fight(90, ENEMY)                       -- start → straight to AOE
  expect(AF.sent[1]):eq("c frostflower")
  AF.frostflower()                             -- landed → cast again (repeat)
  expect(AF.sent[2]):eq("c frostflower")
  expect(AF.aoe_active()):eq(true)
end)

test("aoe 'auto': a rollover ALONE does not AOE — AOE is driven by the crowd COUNT", function()
  AF.reset()                                   -- aoe_mode auto, no crowd counted
  AF.on_fight(90, ENEMY); AF.tarrants()        -- fresh single: c tarrants → c icebolt
  AF.on_fight(72, "a crimson topaz")           -- rollover, no count set → still single-target
  expect(AF.sent[1]):eq("c tarrants")          -- fresh single-target opener on the new enemy
  expect(AF.aoe_active()):eq(false)
end)

test("aoe 'auto': crowd whittled to the last one drops back to single target (the exit fix)", function()
  AF.reset()
  AF.on_fight(90, ENEMY); AF.tarrants()        -- fighting; c tarrants → c icebolt in flight
  AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape")   -- look: 2 hostiles → AOE
  expect(AF.aoe_active()):eq(true)
  expect(AF.state().enemy_est):eq(2)
  AF.mdeath("A dire ape")                      -- one dies → estimate 1 → below pack size
  expect(AF.state().enemy_est):eq(1)
  expect(AF.aoe_active()):eq(false)            -- back to single target
  expect(AF.state().phase ~= "aoe"):eq(true)   -- and the plan is a single-target spell again
end)

test("aoe 'off' never AOEs, even with a pack-sized crowd count", function()
  AF.reset(); AF.state().aoe_mode = "off"
  AF.on_fight(90, ENEMY); AF.tarrants()
  AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape")
  expect(AF.state().enemy_est):eq(3)
  expect(AF.aoe_active()):eq(false)            -- forced off regardless of the count
end)

test("crowd count + AOE reset when combat truly ends (kxwt -1)", function()
  AF.reset()
  AF.on_fight(90, ENEMY); AF.tarrants()
  AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape")
  expect(AF.aoe_active()):eq(true)
  AF.on_fight_end()                            -- -1 → combat over
  expect(AF.state().pack):eq(false)
  expect(AF.state().enemy_est):eq(0)
end)

test("a hostile mdeath below the count doesn't go negative; our minion's death doesn't count", function()
  AF.reset()
  AF.on_fight(90, ENEMY); AF.tarrants()
  state.name, state.group = "Vaelith", { { name = "A skeletal spider" } }
  AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape")   -- est 2 → AOE
  AF.mdeath("A skeletal spider")               -- our minion — NOT counted
  expect(AF.state().enemy_est):eq(2)
  expect(AF.aoe_active()):eq(true)
  AF.mdeath("A dire ape"); AF.mdeath("A dire ape"); AF.mdeath("A dire ape")  -- floors at 0
  expect(AF.state().enemy_est):eq(0)
  state.name, state.group = nil, nil
end)

test("aoe 'auto': a look showing multiple enemies fighting flips to AOE WITHOUT a kill", function()
  AF.reset()
  AF.on_fight(90, ENEMY); AF.tarrants()        -- single-target: c tarrants → c icebolt in flight
  expect(AF.aoe_active()):eq(false)
  AF.room_fighter("A dire ape")                -- look: one engaged hostile
  expect(AF.aoe_active()):eq(false)            -- one enemy is not a pack
  AF.room_fighter("A dire ape")                -- a SECOND engaged hostile (own line) → pack!
  expect(AF.aoe_active()):eq(true)
  expect(AF.state().phase):eq("aoe")           -- plan switched immediately (still busy on icebolt)
  AF.icebolt()                                  -- the in-flight icebolt lands → next cast is AOE
  expect(AF.sent[#AF.sent]):eq("c frostflower")
end)

test("room crowd-count ignores our own minions/self — only hostiles count", function()
  AF.reset()
  AF.on_fight(90, ENEMY); AF.tarrants()
  state.name  = "Vaelith"
  state.group = { { name = "A skeletal spider" }, { name = "Vaelith" } }
  AF.room_fighter("A skeletal spider")         -- our minion fighting a mob — not an enemy
  AF.room_fighter("Vaelith")                   -- ourself — not an enemy
  expect(AF.aoe_active()):eq(false)
  AF.room_fighter("A dire ape")                -- two real hostiles
  AF.room_fighter("A crimson topaz")
  expect(AF.aoe_active()):eq(true)
  state.name, state.group = nil, nil
end)

test("a peaceful look (not fighting) never arms AOE", function()
  AF.reset()                                   -- not fighting
  AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape"); AF.room_fighter("A dire ape")
  expect(AF.aoe_active()):eq(false)
  expect(AF.state().pack):eq(false)
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
  local key = AF.winner_key("undead marsh troll")
  autofight.winner("undead marsh troll", "scorch")
  expect(_AUTOFIGHT.winners[key]):eq("scorch")
  autofight.winner("undead marsh troll", "icebolt")     -- re-override to the other element
  expect(_AUTOFIGHT.winners[key]):eq("icebolt")
  autofight.winner("undead marsh troll", "none")        -- forget → re-probe next time
  expect(_AUTOFIGHT.winners[key]):eq(nil)
end)

test("autofight.winner rejects a spell that isn't icebolt/scorch (memory untouched)", function()
  AF.reset()
  autofight.winner("a rat", "frostflower")
  expect(_AUTOFIGHT.winners[AF.winner_key("a rat")]):eq(nil)
end)

test("autofight.winner switches the CURRENT fight immediately (stops casting the wrong spell)", function()
  AF.reset()
  local F = AF.state()
  AF.on_fight(90, "a wraith")                            -- fresh fight → would normally probe
  autofight.winner("a wraith", "scorch")                 -- override mid-fight
  expect(F.winner_spell):eq("scorch")
  expect(F.known_winner):eq("scorch")
  AF.on_fight_end()
end)

-- ---- probe-spell swap + versioned winners migration ----------------------------------------------
test("is_probe_spell knows only the CURRENT probe spells", function()
  expect(AF.is_probe_spell("icebolt")):truthy()
  expect(AF.is_probe_spell("scorch")):truthy()
  expect(AF.is_probe_spell("shards")):falsy()      -- retired by the icebolt swap
  expect(AF.is_probe_spell(nil)):falsy()
end)

test("a RETIRED spell left in the winners table is ignored → the target re-probes (not a stale nuke)", function()
  AF.reset()
  AF.winners()["gnomian guard"] = "shards"          -- a pre-swap entry the migration would drop / ignore
  AF.on_fight(90, ENEMY)                             -- fresh fight vs "a Gnomian guard"
  AF.tarrants()                                      -- opener landed → 'shards' isn't current → PROBE, don't nuke
  expect(AF.state().phase):eq("icebolt")
  expect(AF.sent[#AF.sent]):eq("c icebolt")
  AF.on_fight_end()
end)

test("a still-valid winner (scorch) is trusted after the swap — skips the probe", function()
  AF.reset()
  AF.winners()["gnomian guard"] = "scorch"          -- scorch survived the swap
  AF.on_fight(90, ENEMY)
  AF.tarrants()                                      -- opener → straight to the known nuke, no probe
  expect(AF.state().phase):eq("nuke")
  expect(AF.sent[#AF.sent]):eq("c scorch")
  AF.on_fight_end()
end)

-- ---- tank rescue: a dead clay-man/flesh-beast tank → corpse off + re-summon ----------------------
-- The tank is a minion of ours (group flag M) that's tanking (flag T). When it dies we turn off corpse
-- automation and re-cast 'clay man' until one rejoins. Detection is name-based and sticky so it survives
-- the roster dropping the dead row before the mdeath line lands.

local function tank_reset()
  AF.reset()
  local T = AF.tank(); T.on, T.name, T.resummoning, T.tries, T.timer = true, nil, false, 0, nil
  _AA_TEST.corpse.on = true                          -- start with corpse automation ON
  state.name, state.group = "Vaelith", nil
end

test("tank_scan: the minion flagged M+T is the tank; a plain minion or an ally player is not", function()
  state.group = {
    { name = "Vaelith",     flags = "XL" },          -- you (leader)
    { name = "A skeletal spider", flags = "M" },     -- your minion, NOT tanking
    { name = "A clay man",  flags = "MT" },           -- your minion, tanking → the tank
  }
  expect(AF.tank_scan()):eq("A clay man")
  state.name, state.group = nil, nil
end)

test("tank dies: corpse automation goes OFF and we start re-casting clay man", function()
  tank_reset()
  state.group = { { name = "Vaelith", flags = "XL" }, { name = "flesh beast", flags = "MT" } }
  AF.tank_refresh()                                   -- kxwt_group_end → remember "flesh beast" as tank
  expect(AF.tank().name):eq("flesh beast")
  AF.tank_mdeath("flesh beast")                       -- the tank dies
  expect(_AA_TEST.corpse.on):eq(false)               -- (1) corpse automation disabled
  expect(AF.sent[#AF.sent]):eq(AF.cfg.clay_cmd)      -- (2) first re-summon cast went out
  expect(AF.tank().resummoning):eq(true)
end)

test("a NON-tank minion dying does nothing (no corpse-off, no re-summon)", function()
  tank_reset()
  state.group = {
    { name = "flesh beast", flags = "MT" },           -- the tank
    { name = "A skeletal spider", flags = "M" },       -- a plain minion
  }
  AF.tank_refresh()
  local before = #AF.sent
  AF.tank_mdeath("A skeletal spider")                 -- a non-tank minion dies
  expect(_AA_TEST.corpse.on):eq(true)                -- corpse automation untouched
  expect(#AF.sent):eq(before)                        -- nothing re-summoned
  expect(AF.tank().resummoning):eq(false)
end)

test("re-summon stops as soon as a clay man rejoins the group", function()
  tank_reset()
  state.group = { { name = "flesh beast", flags = "MT" } }
  AF.tank_refresh()
  AF.tank_mdeath("flesh beast")
  expect(AF.tank().resummoning):eq(true)
  AF.tank_resummoned()                                -- "You add A clay man to your group."
  expect(AF.tank().resummoning):eq(false)             -- loop stopped
end)

test("tank rescue can be disabled: autofight.tank('off') suppresses the response", function()
  tank_reset()
  autofight.tank("off")
  state.group = { { name = "flesh beast", flags = "MT" } }
  AF.tank_refresh()
  local before = #AF.sent
  AF.tank_mdeath("flesh beast")
  expect(_AA_TEST.corpse.on):eq(true)                -- disabled → no action
  expect(#AF.sent):eq(before)
  autofight.tank("on")                                -- restore for later tests
end)
