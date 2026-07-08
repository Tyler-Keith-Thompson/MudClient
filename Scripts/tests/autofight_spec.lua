-- Specs for AutoFight.lua — the deterministic auto-fight state machine.
--
-- These drive the ACTUAL state machine by calling the SAME resolution handlers the live Swift triggers
-- dispatch to (AF.shards/AF.scorch/AF.resist/… via _AF_TEST) plus the kxwt_fighting handler (AF.on_fight)
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

-- Get to "c shards in flight": start the fight (casts the tarrants opener), land tarrants → shards.
local function to_shards()
  AF.reset()
  AF.on_fight(90, ENEMY)   -- combat start → "c tarrants"
  AF.tarrants()            -- tarrants LANDED → "c shards"
end

-- ---- (a) full fight command sequence -------------------------------------------------------------
test("full fight: tarrants → shards/scorch probe → nuke winner → soulsteal (resist → re-nuke → retry)", function()
  to_shards()                        -- sent: c tarrants, c shards
  AF.on_fight(70, ENEMY)             -- shards Δ20 — a % change NEVER casts
  AF.shards()                        -- shards LANDED → "c scorch"
  AF.on_fight(65, ENEMY)             -- scorch Δ5
  AF.scorch()                        -- scorch LANDED → decide (shards wins) → nuke "c shards"
  AF.on_fight(50, ENEMY); AF.shards()  -- landed → "c shards"
  AF.on_fight(35, ENEMY); AF.shards()  -- landed → "c shards"
  AF.on_fight(20, ENEMY); AF.shards()  -- landed → "c shards"
  AF.on_fight(10, ENEMY); AF.shards()  -- landed, now ≤15% → "c soulsteal"
  AF.resist()                        -- soulsteal RESISTED → re-nuke → "c shards"
  AF.shards()                        -- re-nuke landed → "c soulsteal"
  AF.soulsteal_ok()                  -- landed → done (no further sends)
  AF.dead()                          -- enemy dead → fight ends

  expect_seq(seq(), {
    "c tarrants",
    "c shards", "c scorch",                          -- probes
    "c shards", "c shards", "c shards", "c shards",  -- winner nuked (65→50→35→20→10)
    "c soulsteal",                                   -- finish attempt
    "c shards",                                      -- re-nuke after the resist
    "c soulsteal",                                   -- retry — lands
  })
  local F = AF.state()
  expect(F.winner_spell):eq("shards")
  expect(F.fighting):eq(false)
  expect(F.phase):eq("idle")
end)

-- ---- (b) THE SPAM GUARD: a flood of health-% updates while busy sends nothing --------------------
test("spam guard: a burst of health-% updates in flight sends ZERO commands", function()
  to_shards()                        -- "c shards" in flight (busy)
  local n = #AF.sent
  expect(AF.state().busy):eq(true)
  -- the real health bar from the spam log: many kxwt_fighting ticks per second.
  for _, p in ipairs({ 88, 72, 71, 68, 67, 58, 57, 46, 45, 35, 24, 15, 8, 5, 3 }) do
    AF.on_fight(p, ENEMY)
  end
  expect(#AF.sent):eq(n)             -- NOT ONE extra command — this was the bug
  expect(AF.state().busy):eq(true)   -- still waiting on the shards landed line
  AF.shards()                        -- only the actual LANDED line releases the next cast
  expect(#AF.sent):eq(n + 1)
  expect(AF.sent[n + 1]):eq("c scorch")
end)

-- ---- (c) pacing + retry --------------------------------------------------------------------------
test("pacing: a non-resolution line sends nothing; the landed line advances", function()
  to_shards()
  local n = #AF.sent
  AF.on_fight(80, ENEMY)             -- a % tick: nothing
  expect(#AF.sent):eq(n)
  AF.shards()                        -- shards landed → next cast
  expect(#AF.sent):eq(n + 1)
  expect(AF.sent[n + 1]):eq("c scorch")
end)

test("a FAILED cast retries the SAME spell (not the next)", function()
  to_shards()                        -- "c shards" in flight
  local n = #AF.sent
  AF.fail()                          -- "You fail to cast the spell 'shards'." → retry
  expect(#AF.sent):eq(n + 1)
  expect(AF.sent[n + 1]):eq("c shards")   -- same spell
end)

test("an opener that keeps failing is given up after max_tries — never stalls", function()
  AF.reset(); AF.on_fight(90, ENEMY)       -- "c tarrants"
  for _ = 1, AF.cfg.max_tries do AF.fail() end   -- fizzles max_tries times (each after a fail line)
  expect(AF.sent[#AF.sent]):eq("c shards")       -- gave up on tarrants, moved on
end)

-- ---- (d) manual-input suspend --------------------------------------------------------------------
test("suspend: a user-typed command halts sends until the resume window", function()
  AF.reset(); AF.on_fight(90, ENEMY)       -- "c tarrants" (busy)
  expect(#AF.sent):eq(1)
  AF.on_input("kick guard")                -- the USER intervenes
  expect(AF.state().suspended):eq(true)
  AF.tarrants()                            -- tarrants lands, but suspended → no "c shards"
  expect(#AF.sent):eq(1)
  AF.expire_resume()                       -- resume window elapses
  expect(AF.state().suspended):eq(false)
  expect(#AF.sent):eq(2)
  expect(AF.sent[2]):eq("c shards")
end)

test("suspend: our OWN sends echoing back do NOT suspend", function()
  AF.reset(); AF.on_fight(90, ENEMY)       -- we send "c tarrants"
  AF.on_input("c tarrants")                -- its echo returns through the input observer
  expect(AF.state().suspended):eq(false)
end)

-- ---- (e) winner pick: bigger %-drop wins ---------------------------------------------------------
test("winner pick: shards drops more than scorch → nuke with shards", function()
  to_shards()
  AF.on_fight(70, ENEMY); AF.shards()      -- shards Δ20 → "c scorch"
  AF.on_fight(65, ENEMY); AF.scorch()      -- scorch Δ5  → decide → nuke
  local F = AF.state()
  expect(F.shards_drop):eq(20)
  expect(F.scorch_drop):eq(5)
  expect(F.winner_spell):eq("shards")
  expect(AF.sent[#AF.sent]):eq("c shards")
end)

test("winner pick: scorch drops more than shards → nuke with scorch", function()
  to_shards()
  AF.on_fight(85, ENEMY); AF.shards()      -- shards Δ5  → "c scorch"
  AF.on_fight(60, ENEMY); AF.scorch()      -- scorch Δ25 → decide → nuke
  local F = AF.state()
  expect(F.scorch_drop):eq(25)
  expect(F.winner_spell):eq("scorch")
  expect(AF.sent[#AF.sent]):eq("c scorch")
end)

-- ---- (f) robustness ------------------------------------------------------------------------------
test("out-of-mana stops that spell (no spam) and waits", function()
  to_shards()
  AF.on_fight(70, ENEMY); AF.shards()      -- → "c scorch"
  AF.on_fight(60, ENEMY); AF.scorch()      -- → winner shards → nuke "c shards"
  local n = #AF.sent
  AF.mana()                                -- "You don't have enough mana."
  expect(AF.state().no_mana["shards"]):eq(true)
  expect(#AF.sent):eq(n)                   -- nothing more sent
  AF.on_fight(55, ENEMY)                   -- a later % tick doesn't re-cast the broke spell
  expect(#AF.sent):eq(n)
end)

test("soulsteal success line ends the routine cleanly", function()
  to_shards()
  AF.on_fight(70, ENEMY); AF.shards()
  AF.on_fight(60, ENEMY); AF.scorch()      -- winner shards → nuke
  AF.on_fight(8, ENEMY);  AF.shards()      -- landed, ≤15% → "c soulsteal"
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
  AF.on_fight(90, ENEMY)                               -- combat starts → skip opener → "c shards"
  expect(AF.state().engaging):eq(false)
  expect(AF.state().phase):eq("shards")
  expect(AF.sent[#AF.sent]):eq("c shards")
  AF.on_fight_end()                                    -- fight over → on_dead fires once
  expect(dead):eq(true)
  expect(failed):eq(nil)
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
  to_shards()
  AF.on_fight(70, ENEMY); AF.shards()      -- → "c scorch"
  AF.on_fight(60, ENEMY); AF.scorch()      -- winner shards → nuke "c shards"
  AF.on_fight(8, ENEMY);  AF.shards()      -- landed, ≤15% → "c soulsteal"
  expect(AF.sent[#AF.sent]):eq("c soulsteal")
  AF.soul_latched()                        -- LATCHED (not stolen) → resume nuking the winner
  expect(AF.state().soul_latched):eq(true)
  expect(AF.state().phase):eq("nuke")
  expect(AF.sent[#AF.sent]):eq("c shards") -- nuked again, NOT soulsteal
  -- Still ≤15%, but the latch guard keeps us nuking — never flips back to soulsteal.
  AF.on_fight(5, ENEMY); AF.shards()
  expect(AF.sent[#AF.sent]):eq("c shards")
  -- The latch finally activates: the steal success line, then DEAD, ends the fight cleanly.
  AF.soulsteal_ok()
  expect(AF.state().phase):eq("done")
  local n = #AF.sent
  AF.dead()
  expect(AF.state().fighting):eq(false)
  expect(#AF.sent):eq(n)                    -- nothing more sent after done
end)

test("a fresh fight clears the soul_latched flag", function()
  to_shards()
  AF.on_fight(70, ENEMY); AF.shards()       -- → scorch
  AF.on_fight(60, ENEMY); AF.scorch()       -- decide → winner shards → nuke
  AF.on_fight(8, ENEMY);  AF.shards()       -- ≤15% → soulsteal
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
  to_shards()
  AF.on_fight(70, ENEMY); AF.shards()
  AF.on_fight(60, ENEMY); AF.scorch()      -- decide → nuke
  AF.on_fight(8, ENEMY);  AF.shards()      -- ≤15% → soulsteal
  AF.soulsteal_ok(); AF.dead()
  for _, cmd in ipairs(seq()) do
    expect(cmd == AF.cfg.shower_cmd):eq(false)   -- "c shower" never appears
  end
end)

test("the dormant shower handler no-ops (a stray shower line can't advance the routine)", function()
  to_shards()                              -- "c shards" in flight (busy on shards)
  local n = #AF.sent
  local phase = AF.state().phase
  AF.shower()                              -- the dead trigger fires → succeed('shower') → guard no-ops
  expect(#AF.sent):eq(n)                   -- nothing sent
  expect(AF.state().phase):eq(phase)       -- phase unchanged (busy_spell was 'shards', not 'shower')
  expect(AF.state().busy):eq(true)         -- still waiting on the real shards landed line
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
  to_shards()                              -- reset() clears the winners table (hermetic)
  AF.on_fight(85, ENEMY); AF.shards()      -- shards Δ5  → scorch
  AF.on_fight(60, ENEMY); AF.scorch()      -- scorch Δ25 → decide → scorch wins → learned
  expect(AF.winners()["gnomian guard"]):eq("scorch")
end)

test("a known winner SKIPS the probe: opener → straight to the known nuke", function()
  AF.reset()                               -- clears memory…
  AF.winners()["gnomian guard"] = "scorch" -- …then seed a known winner
  AF.on_fight(90, ENEMY)                   -- combat start → "c tarrants" (no probe scheduled)
  expect(AF.state().known_winner):eq("scorch")
  AF.tarrants()                            -- opener landed → skip shards/scorch → nuke the known winner
  expect(AF.state().phase):eq("nuke")
  expect(AF.sent[#AF.sent]):eq("c scorch")
  -- keep nuking scorch to the end; the probe spells never appear
  AF.on_fight(40, ENEMY); AF.scorch()
  for _, cmd in ipairs(seq()) do expect(cmd == "c shards"):eq(false) end
end)

test("engage() with a known winner goes opener → known nuke (no probe)", function()
  AF.reset()
  AF.winners()["gnomian guard"] = "shards"
  autofight.engage(ENEMY)                  -- target + opener; opener_primed
  AF.tarrants()                            -- opener landed (engaging)…
  AF.on_fight(90, ENEMY)                   -- …combat starts → primed + known → straight to nuke
  expect(AF.state().phase):eq("nuke")
  expect(AF.sent[#AF.sent]):eq("c shards")
end)

test("forget(name) drops one entry; forget() clears all", function()
  AF.reset()
  AF.winners()["gnomian guard"] = "scorch"
  AF.winners()["orc"] = "shards"
  autofight.forget("a Gnomian guard")      -- normalized to "gnomian guard"
  expect(AF.winners()["gnomian guard"]):eq(nil)
  expect(AF.winners()["orc"]):eq("shards")
  autofight.forget()                       -- clear all
  expect(next(AF.winners())):eq(nil)
end)
