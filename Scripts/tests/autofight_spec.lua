-- Specs for AutoFight.lua — the deterministic auto-fight state machine.
--
-- These drive the ACTUAL state machine (via the _AF_TEST seam: the same on_fight/on_line/observe_input
-- handlers the live kxwt triggers and on_user_input call) and assert the exact SEND sequence, the
-- pacing (never a second cast before the prior one resolves), the manual-input suspend, and the
-- shards-vs-shower winner pick.
--
-- Every game LINE fed below is VERBATIM from the player's raw logs. The anchor fight is the Gnomian
-- guard in mud_raw_copy.log (a real shards + soulsteal kill with a live kxwt_fighting health bar):
--   "kxwt_fighting 90 male a Gnomian guard"                                               (copy.log:1208)
--   "You create and magically throw white shards of crystal at a Gnomian guard!"          (copy.log:1200)
--   "A shower of brilliant white sparks suddenly engulfs a Gnomian guard!"                (copy.log:2351)
--   "You cast the spell to separate soul from body, and pull a Gnomian guard's essence
--        into a yellow soulstone!"                                                        (copy.log:1561)
--   "A Gnomian guard is DEAD!"                                                            (copy.log:1565)
--   "You don't have enough mana."                                                        (copy.log:2618)
--   "<name> resists the spell."  (real format, copy.log:4038 "Corupius … resists the spell.")
-- The kxwt_fighting health-% values are injected as the corresponding state.fight_pct updates (the
-- anchor fight is nomelee-adjacent; the % ladder is real kxwt numbers). Since the health-% signal is
-- how the winner is measured, the winner-pick specs drive the drop cleanly via the % updates.

local AF = _AF_TEST

local ENEMY = "a Gnomian guard"

-- VERBATIM resolution lines used across the specs.
local L_SHARDS_LAND = "You create and magically throw white shards of crystal at a Gnomian guard!"
local L_SHOWER_LAND = "A shower of brilliant white sparks suddenly engulfs a Gnomian guard!"
local L_RESIST      = "a Gnomian guard resists the spell."
local L_MANA        = "You don't have enough mana."
local L_SOULSTEAL_OK= "You cast the spell to separate soul from body, and pull a Gnomian guard's essence into a yellow soulstone!"
local L_DEAD        = "A Gnomian guard is DEAD!"
local L_NOISE       = "A skeleton's slice wounds a Gnomian guard."   -- a melee line: NOT a resolution

local function seq()
  local t = {}
  for i, v in ipairs(AF.sent) do t[i] = v end
  return t
end

local function expect_seq(got, want)
  expect(#got):eq(#want)
  for i = 1, #want do
    if got[i] ~= want[i] then
      error(string.format("send[%d]: expected '%s', got '%s'  (full: %s)",
        i, tostring(want[i]), tostring(got[i]), table.concat(got, " | ")), 2)
    end
  end
end

-- Advance the openers deterministically: earth wall + tarrants aren't known here, so each resolves by
-- the fallback timeout (they never retry). After this, "c shards" has just been sent and we're busy.
local function run_openers()
  AF.reset()
  AF.on_fight(90, ENEMY)   -- combat start → casts "cast earth wall"
  AF.expire_cast()         -- earth wall timed out → casts "c tarrants"
  AF.expire_cast()         -- tarrants timed out → casts "c shards"
end

-- ---- (a) full command sequence of a real fight ---------------------------------------------------
test("full fight replay: earth wall → tarrants → shards/shower probe → nuke winner → soulsteal(resist→re-nuke→retry)", function()
  run_openers()                                   -- sent: cast earth wall, c tarrants, c shards
  AF.on_fight(70, ENEMY)                           -- shards dropped 90→70 (Δ20) → resolves → casts "c shower"
  AF.on_fight(65, ENEMY)                           -- shower dropped 70→65 (Δ5) → shards wins → nuke "c shards"
  AF.on_fight(50, ENEMY)                           -- nuke resolves → "c shards"
  AF.on_fight(35, ENEMY)                           -- nuke resolves → "c shards"
  AF.on_fight(20, ENEMY)                           -- nuke resolves → "c shards"
  AF.on_fight(10, ENEMY)                           -- ≤15% nearly dead → "c soulsteal"
  AF.on_line(L_RESIST)                             -- soulsteal RESISTED → re-nuke once → "c shards"
  AF.on_line(L_SHARDS_LAND)                         -- re-nuke landed → retry → "c soulsteal"
  AF.on_line(L_SOULSTEAL_OK)                        -- soulsteal landed → done (no further sends)
  AF.on_line(L_DEAD)                               -- enemy dead → fight ends

  expect_seq(seq(), {
    "cast earth wall", "c tarrants",               -- openers, once each
    "c shards", "c shower",                        -- probes
    "c shards", "c shards", "c shards", "c shards", -- winner (shards) nuked to near-death (65→50→35→20→10)
    "c soulsteal",                                 -- finish attempt
    "c shards",                                    -- re-nuke after the resist
    "c soulsteal",                                 -- retry — lands
  })
  local F = AF.state()
  expect(F.winner_spell):eq("shards")
  expect(F.fighting):eq(false)                     -- the DEAD line ended it
  expect(F.phase):eq("idle")
end)

-- ---- (b) pacing: no second cast before the prior cast resolves -----------------------------------
test("pacing: stays busy (no new send) until a resolution line, then advances", function()
  run_openers()
  local F = AF.state()
  expect(F.busy):eq(true)                          -- "c shards" is in flight
  expect(F.busy_spell):eq("shards")
  local n = #AF.sent                               -- 3 sends so far (earth wall, tarrants, shards)

  AF.on_line(L_NOISE)                              -- a non-resolution combat line…
  expect(#AF.sent):eq(n)                           -- …emits NOTHING and…
  expect(AF.state().busy):eq(true)                 -- …leaves us busy

  AF.on_line(L_SHARDS_LAND)                         -- the shards LANDED line resolves the cast…
  expect(#AF.sent):eq(n + 1)                       -- …and only NOW does the next cast go out
  expect(AF.sent[n + 1]):eq("c shower")
  expect(AF.state().busy):eq(true)                 -- (and we're immediately busy on the shower probe)
end)

test("pacing: a health-% change also resolves the busy cast", function()
  run_openers()
  local n = #AF.sent
  AF.on_fight(80, ENEMY)                           -- % ticked 90→80: a resolution signal
  expect(#AF.sent):eq(n + 1)
  expect(AF.sent[n + 1]):eq("c shower")
end)

test("pacing: the fallback timeout resolves so we never deadlock", function()
  run_openers()                                    -- run_openers itself relies on the timeout twice
  local n = #AF.sent
  AF.expire_cast()                                 -- no game signal ever arrived for "c shards"
  expect(#AF.sent):eq(n + 1)
  expect(AF.sent[n + 1]):eq("c shower")            -- moved on regardless
end)

-- ---- (c) manual-input suspend --------------------------------------------------------------------
test("suspend: a user-typed command halts sends until the resume window", function()
  AF.reset()
  AF.on_fight(90, ENEMY)                           -- casts "cast earth wall" (busy)
  expect(#AF.sent):eq(1)

  AF.on_input("kick guard")                        -- the USER intervenes (we never sent this)
  expect(AF.state().suspended):eq(true)

  AF.expire_cast()                                 -- earth wall resolves, but…
  expect(#AF.sent):eq(1)                           -- …suspended → no "c tarrants"
  AF.on_fight(85, ENEMY)                           -- a further game event…
  expect(#AF.sent):eq(1)                           -- …still nothing while suspended

  AF.expire_resume()                               -- resume window elapses
  expect(AF.state().suspended):eq(false)
  expect(#AF.sent):eq(2)                           -- machine resumes: casts "c tarrants"
  expect(AF.sent[2]):eq("c tarrants")
end)

test("suspend: our OWN sends echoing back do NOT suspend", function()
  AF.reset()
  AF.on_fight(90, ENEMY)                           -- we send "cast earth wall" (flagged self_sent)
  AF.on_input("cast earth wall")                   -- its echo comes back through the input observer
  expect(AF.state().suspended):eq(false)           -- recognized as ours — not treated as user input
end)

-- ---- (d) winner pick: bigger %-drop wins ---------------------------------------------------------
test("winner pick: shards drops more than shower → nuke with shards", function()
  AF.reset()
  AF.on_fight(100, ENEMY); AF.expire_cast(); AF.expire_cast()   -- → "c shards" in flight
  AF.on_fight(70, ENEMY)                           -- shards Δ30 → resolves, casts "c shower"
  AF.on_fight(65, ENEMY)                           -- shower Δ5  → decide
  local F = AF.state()
  expect(F.shards_drop):eq(30)
  expect(F.shower_drop):eq(5)
  expect(F.winner_spell):eq("shards")
  expect(AF.sent[#AF.sent]):eq("c shards")         -- the first nuke uses the winner
end)

test("winner pick: shower drops more than shards → nuke with shower", function()
  AF.reset()
  AF.on_fight(100, ENEMY); AF.expire_cast(); AF.expire_cast()   -- → "c shards" in flight
  AF.on_fight(95, ENEMY)                           -- shards Δ5  → resolves, casts "c shower"
  AF.on_fight(70, ENEMY)                           -- shower Δ25 → decide
  local F = AF.state()
  expect(F.shards_drop):eq(5)
  expect(F.shower_drop):eq(25)
  expect(F.winner_spell):eq("shower")
  expect(AF.sent[#AF.sent]):eq("c shower")
end)

-- ---- robustness: out-of-mana and terminal lines --------------------------------------------------
test("out-of-mana stops casting that spell (no spam)", function()
  AF.reset()
  AF.on_fight(100, ENEMY); AF.expire_cast(); AF.expire_cast()   -- openers done, "c shards" busy
  AF.on_fight(70, ENEMY)                           -- shards resolves → "c shower"
  AF.on_fight(60, ENEMY)                           -- shower resolves → winner shards → nuke "c shards"
  local n = #AF.sent
  AF.on_line(L_MANA)                               -- "You don't have enough mana." resolves the nuke…
  expect(AF.state().no_mana["shards"]):eq(true)    -- …and marks shards unaffordable
  expect(#AF.sent):eq(n)                           -- no further shards sent (we WAIT, don't spam)
  AF.on_fight(55, ENEMY)                           -- even a later event won't re-cast the broke spell
  expect(#AF.sent):eq(n)
end)

test("soulsteal success line ends the routine cleanly", function()
  AF.reset()
  AF.on_fight(100, ENEMY); AF.expire_cast(); AF.expire_cast()
  AF.on_fight(70, ENEMY); AF.on_fight(60, ENEMY)   -- probes → winner shards
  AF.on_fight(8, ENEMY)                            -- nearly dead → "c soulsteal"
  expect(AF.sent[#AF.sent]):eq("c soulsteal")
  local n = #AF.sent
  AF.on_line(L_SOULSTEAL_OK)                        -- soul pulled
  expect(AF.state().phase):eq("done")
  expect(#AF.sent):eq(n)                           -- nothing more sent
end)

test("DEAD line ends the fight from any phase", function()
  AF.reset()
  AF.on_fight(100, ENEMY)                          -- mid-openers
  expect(AF.state().fighting):eq(true)
  AF.on_line(L_DEAD)
  expect(AF.state().fighting):eq(false)
  expect(AF.state().phase):eq("idle")
end)

test("shower LANDED line matches the color-varying verbatim format", function()
  -- Ensure the "A shower of <color> sparks suddenly engulfs <target>!" classifier fires on real colors.
  AF.reset()
  AF.on_fight(100, ENEMY); AF.expire_cast(); AF.expire_cast()   -- "c shards" busy
  AF.on_fight(70, ENEMY)                           -- → "c shower" busy
  local n = #AF.sent
  AF.on_line("A shower of fiery blue sparks suddenly engulfs Bozonose!")   -- verbatim (copy.log:1761)
  expect(#AF.sent):eq(n + 1)                       -- resolved the shower probe → decide → nuke
end)
