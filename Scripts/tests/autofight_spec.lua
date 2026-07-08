-- Specs for AutoFight.lua — the deterministic auto-fight state machine.
--
-- These drive the ACTUAL state machine by calling the SAME resolution handlers the live Swift triggers
-- dispatch to (AF.shards/AF.shower/AF.resist/… via _AF_TEST) plus the kxwt_fighting handler (AF.on_fight)
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
test("full fight: tarrants → shards/shower probe → nuke winner → soulsteal (resist → re-nuke → retry)", function()
  to_shards()                        -- sent: c tarrants, c shards
  AF.on_fight(70, ENEMY)             -- shards Δ20 — a % change NEVER casts
  AF.shards()                        -- shards LANDED → "c shower"
  AF.on_fight(65, ENEMY)             -- shower Δ5
  AF.shower()                        -- shower LANDED → decide (shards wins) → nuke "c shards"
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
    "c shards", "c shower",                          -- probes
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
  expect(AF.sent[n + 1]):eq("c shower")
end)

-- ---- (c) pacing + retry --------------------------------------------------------------------------
test("pacing: a non-resolution line sends nothing; the landed line advances", function()
  to_shards()
  local n = #AF.sent
  AF.on_fight(80, ENEMY)             -- a % tick: nothing
  expect(#AF.sent):eq(n)
  AF.shards()                        -- shards landed → next cast
  expect(#AF.sent):eq(n + 1)
  expect(AF.sent[n + 1]):eq("c shower")
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
test("winner pick: shards drops more than shower → nuke with shards", function()
  to_shards()
  AF.on_fight(70, ENEMY); AF.shards()      -- shards Δ20 → "c shower"
  AF.on_fight(65, ENEMY); AF.shower()      -- shower Δ5  → decide → nuke
  local F = AF.state()
  expect(F.shards_drop):eq(20)
  expect(F.shower_drop):eq(5)
  expect(F.winner_spell):eq("shards")
  expect(AF.sent[#AF.sent]):eq("c shards")
end)

test("winner pick: shower drops more than shards → nuke with shower", function()
  to_shards()
  AF.on_fight(85, ENEMY); AF.shards()      -- shards Δ5  → "c shower"
  AF.on_fight(60, ENEMY); AF.shower()      -- shower Δ25 → decide → nuke
  local F = AF.state()
  expect(F.shower_drop):eq(25)
  expect(F.winner_spell):eq("shower")
  expect(AF.sent[#AF.sent]):eq("c shower")
end)

-- ---- (f) robustness ------------------------------------------------------------------------------
test("out-of-mana stops that spell (no spam) and waits", function()
  to_shards()
  AF.on_fight(70, ENEMY); AF.shards()      -- → "c shower"
  AF.on_fight(60, ENEMY); AF.shower()      -- → winner shards → nuke "c shards"
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
  AF.on_fight(60, ENEMY); AF.shower()      -- winner shards → nuke
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
