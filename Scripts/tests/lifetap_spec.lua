-- Specs for the recovery lifetap booster (AlterAeon.lua): bleed surplus HP into mana while resting, to
-- optimize total recovery time. One safety floor: 55% of max HP (half + buffer) we never bleed past — we DO
-- bleed below the recovery's own HP target when mana is the bottleneck. Always a direct `lifetap <n>`, the
-- whole surplus down to the floor (max chunk). We START taps only — the game ends them (lifetap can't
-- overuse), we WAIT for the "begin tapping" confirm before re-issuing (round-trip debounce), and we back off
-- after the transient "too weak" refusal. The loop fix: while the campaign is on, choose_recovery_position
-- forces `rest` (sleep binds the wound and cancels the bleed). Necromancers with the skill only.

local wanted    = _AA_TEST.lifetap_wanted
local mana_case = _AA_TEST.lifetap_mana_case
local worth_it  = _AA_TEST.lifetap_worth_it
local hold_rest = _AA_TEST.lifetap_hold_rest
local amount    = _AA_TEST.lifetap_amount
local floor_hp  = _AA_TEST.lifetap_floor_hp
local has       = _AA_TEST.has_lifetap
local maybe     = _AA_TEST.maybe_lifetap
local choose    = _AA_TEST.choose_recovery_position
local recovery  = _AA_TEST.recovery
local FLOOR     = _AA_TEST.LIFETAP_FLOOR
local START     = _AA_TEST.LIFETAP_START
local MIN       = _AA_TEST.LIFETAP_MIN

-- Drive lifetap decisions against a fabricated state + recovery, capturing sent commands. Defaults model
-- the `recover mana` happy path: mid recovery, resting, out of combat, a level-21 necromancer, HP full,
-- mana low, no pending send / cooldown. Pass stat=false for an every-vital recovery.
local function with(opts, fn)
  local saved_state, saved_send = state, send
  local saved_rec = { pct = recovery.pct, stat = recovery.stat, minions_only = recovery.minions_only }
  opts = opts or {}
  state = {
    hp = opts.hp or 100, maxhp = opts.maxhp or 100,
    mana = opts.mana or 20, maxmana = opts.maxmana or 100,
    stam = opts.stam or 100, maxstam = opts.maxstam or 100,
    position = opts.position or "resting",
    recover = (opts.recover ~= false),
    fighting = opts.fighting or false,
    sharp = opts.sharp,
    lifetapping = opts.lifetapping or false,
    lifetap_manafull = opts.manafull or false,
    lifetap_send_at = opts.send_at,     -- nil = no tap in flight
    lifetap_retry_at = opts.retry_at,   -- nil = not backing off
    regen = opts.regen,                 -- nil = no `show regen` data (mana treated as low)
    classes = opts.classes or { Necromancer = { level = 21 } },
    group = {},
  }
  recovery.pct = opts.pct or 0.90
  if opts.stat == nil then recovery.stat = "mana"          -- default: single-stat mana recovery
  elseif opts.stat == false then recovery.stat = nil       -- every-vital recovery
  else recovery.stat = opts.stat end
  recovery.minions_only = opts.minions_only
  local sent = {}
  _G.send = function(c) sent[#sent + 1] = c end
  _AA_TEST.reset_posture()
  local ok, err = pcall(function() fn(sent) end)
  state, _G.send = saved_state, saved_send
  recovery.pct, recovery.stat, recovery.minions_only = saved_rec.pct, saved_rec.stat, saved_rec.minions_only
  if not ok then error(err, 2) end
end

-- ---- floor & skill gate ------------------------------------------------------------------------

test("floor is 55% of max hp, rounded to nearest — for every recovery type", function()
  with({ maxhp = 200 },                           function() expect(floor_hp()):eq(110) end)  -- 200 * 0.55
  with({ maxhp = 205 },                           function() expect(floor_hp()):eq(113) end)  -- 112.75 -> 113
  with({ stat = false, pct = 0.90, maxhp = 200 }, function() expect(floor_hp()):eq(110) end)  -- NOT 180
end)

test("has_lifetap requires a necromancer at level 21+", function()
  with({ classes = { Necromancer = { level = 21 } } }, function() expect(has()):truthy() end)
  with({ classes = { Necromancer = { level = 20 } } }, function() expect(has()):falsy() end)
  with({ classes = { Mage = { level = 40 } } },        function() expect(has()):falsy() end)
  with({ classes = {} },                                function() expect(has()):falsy() end)
end)

-- ---- the campaign gate (mana_case): posture- and chunk-independent -----------------------------

test("mana_case on the happy path: recovering, mana low, hp high, is a necromancer", function()
  with({}, function() expect(mana_case()):truthy() end)
end)

test("not a mana_case when not recovering, in combat, or a non-necromancer", function()
  with({ recover = false },                       function() expect(mana_case()):falsy() end)
  with({ fighting = true },                        function() expect(mana_case()):falsy() end)
  with({ classes = { Cleric = { level = 30 } } },  function() expect(mana_case()):falsy() end)
end)

test("not a mana_case once mana reaches the recovery target", function()
  with({ mana = 90, pct = 0.90 }, function() expect(mana_case()):falsy() end)
  with({ mana = 89, pct = 0.90 }, function() expect(mana_case()):truthy() end)
end)

test("campaign holds through the hysteresis band so sitting at the floor doesn't flap to sleep", function()
  -- floor is 55; the campaign zone extends a MIN below it (down to 40) so that HP resting AT the floor
  -- between taps still counts as "in the campaign" and we keep resting instead of sleeping.
  with({ hp = 55, maxhp = 100 }, function() expect(mana_case()):truthy() end)  -- exactly at the bleed floor
  with({ hp = 41, maxhp = 100 }, function() expect(mana_case()):truthy() end)  -- within the hysteresis band
  with({ hp = 40, maxhp = 100 }, function() expect(mana_case()):falsy() end)   -- below it → let it sleep
end)

test("never bleeds HP for a `recover hp`/`recover stamina`, or during a minion-only recovery", function()
  with({ stat = "hp" },         function() expect(mana_case()):falsy() end)
  with({ stat = "stam" },       function() expect(mana_case()):falsy() end)
  with({ minions_only = true }, function() expect(mana_case()):falsy() end)
end)

test("suppressed after 'mana already almost full' while mana is still near full", function()
  -- mana 85% (below the 90% target, so the target gate doesn't mask it) but above the clear threshold:
  -- the refusal still stands, so keep suppressing rather than re-tapping into another refusal.
  with({ manafull = true, mana = 85, maxmana = 100 }, function() expect(mana_case()):falsy() end)
end)

test("the 'mana almost full' suppression clears once mana has clearly drained away", function()
  -- The bug: one 'almost full' refusal used to disable tapping for the whole recovery even as mana emptied.
  -- Once mana drops well below full (spent casting), the stale flag is dropped and tapping resumes.
  with({ manafull = true, mana = 20, maxmana = 100 }, function() expect(mana_case()):truthy() end)
end)

-- ---- only tap when mana is LOW (regen-aware: mana refills faster than HP) -----------------------

test("mana_low: with no regen data, mana below target is treated as low (only tapping fills it)", function()
  with({ mana = 20 }, function() expect(_AA_TEST.lifetap_mana_low()):truthy() end)  -- regen nil
end)

test("mana_low keys off ticks-to-FULL, not raw percent — near-full waits, a real deficit taps", function()
  local low  = _AA_TEST.lifetap_mana_low
  -- deficit to FULL = 80. At 100/tick that's 0.8 ticks (near full → wait); at 10/tick, 8 ticks (far → tap).
  with({ mana = 20, regen = { mana = 100, hp = 5 } }, function() expect(low()):falsy() end)
  with({ mana = 20, regen = { mana = 10,  hp = 5 } }, function() expect(low()):truthy() end)
end)

test("the reported case: ~90 mana down at this character's regen IS low enough to tap", function()
  -- mud_raw log: mana 315/405 (90 down), resting regen ~57/tick → ~1.58 ticks to full (> 1) → tap. The old
  -- gate measured to the 90% target (~0.87 ticks) and never fired even though HP was full and mana ~90 down.
  with({ mana = 315, maxmana = 405, regen = { mana = 57, hp = 46 } }, function()
    expect(_AA_TEST.lifetap_mana_low()):truthy()
    expect(mana_case()):truthy()
  end)
  -- and a nearly-full pool still waits (55 down at 57/tick ≈ 0.96 ticks < 1)
  with({ mana = 350, maxmana = 405, regen = { mana = 57, hp = 46 } }, function()
    expect(_AA_TEST.lifetap_mana_low()):falsy()
  end)
end)

test("no lifetap campaign when mana is nearly full (natural regen will finish it)", function()
  with({ mana = 20, regen = { mana = 100, hp = 5 } },  -- <1 tick from full → wait
    function() expect(mana_case()):falsy() end)
  with({ mana = 20, regen = { mana = 10, hp = 5 } },   -- many ticks from full → campaign on
    function() expect(mana_case()):truthy() end)
end)

-- ---- worth_it (a real MIN chunk) and wanted (worth_it + awake) ----------------------------------

test("worth_it only STARTS a tap when HP is above the 75% start line", function()
  with({ hp = 76, maxhp = 100 }, function() expect(worth_it()):truthy() end)   -- above the start line
  with({ hp = 75, maxhp = 100 }, function() expect(worth_it()):falsy() end)    -- exactly at it → don't open
  with({ hp = 70, maxhp = 100 }, function() expect(worth_it()):falsy() end)    -- in the campaign, but too low to start
  -- the MIN-chunk backstop still bites on a tiny HP pool where even 75%->55% is only a few points:
  with({ hp = 47, maxhp = 60 }, function() expect(worth_it()):falsy() end)     -- 78% but chunk is 47-33=14 < MIN
  with({ hp = 49, maxhp = 60 }, function() expect(worth_it()):truthy() end)    -- 82%, chunk 49-33=16 >= MIN
end)

test("wanted is worth_it AND awake", function()
  with({ hp = 100, position = "sleeping" }, function()
    expect(worth_it()):truthy()   -- worth doing (posture-independent)...
    expect(wanted()):falsy()      -- ...but not runnable asleep
  end)
  with({ hp = 100, position = "resting" }, function() expect(wanted()):truthy() end)
end)

-- ---- hold_rest == the campaign (force rest across the whole thing) ------------------------------

test("hold_rest is exactly the campaign: rest across the hysteresis band, incl. sitting at the floor", function()
  with({ hp = 100 }, function() expect(hold_rest()):truthy() end)
  with({ hp = 55 },  function() expect(hold_rest()):truthy() end)  -- at the floor between taps → still rest
  with({ hp = 40 },  function() expect(hold_rest()):falsy() end)   -- below the band → free to sleep
end)

-- ---- amount ------------------------------------------------------------------------------------

test("amount is the whole surplus down to the floor (max safe chunk)", function()
  with({ hp = 100, maxhp = 100 }, function() expect(amount()):eq(45) end)   -- 100 - 55
  with({ stat = false, pct = 0.90, hp = 80, maxhp = 100, mana = 20 },       -- above 75% start, below 90% hp target
    function() expect(amount()):eq(25) end)                                  -- 80 - 55: still taps below the target
end)

-- ---- maybe_lifetap: START-ONLY, debounced, never self-stops ------------------------------------

test("maybe_lifetap starts a bleed with a direct hp amount, and records the send for debouncing", function()
  with({ hp = 100, maxhp = 100 }, function(sent)
    maybe()
    expect(sent[1]):eq("lifetap 45")
    expect(state.lifetap_send_at ~= nil and state.lifetap_send_at ~= 0):truthy()
  end)
end)

test("maybe_lifetap does NOT re-issue while awaiting the last tap's confirm (round-trip debounce)", function()
  with({ hp = 100, maxhp = 100, send_at = os.time() }, function(sent)
    maybe()
    expect(#sent):eq(0)   -- a tap was just sent this second → wait for the confirm, don't spam
  end)
end)

test("maybe_lifetap re-issues once the debounce window has elapsed", function()
  with({ hp = 100, maxhp = 100, send_at = os.time() - 60 }, function(sent)
    maybe()
    expect(sent[1]):eq("lifetap 45")
  end)
end)

test("maybe_lifetap backs off during the post-'too weak' cooldown", function()
  with({ hp = 100, maxhp = 100, retry_at = os.time() + 60 }, function(sent)
    maybe()
    expect(#sent):eq(0)
  end)
  with({ hp = 100, maxhp = 100, retry_at = os.time() - 60 }, function(sent)
    maybe()
    expect(sent[1]):eq("lifetap 45")   -- cooldown elapsed → retry
  end)
end)

test("lifetap_bound clears the flag and starts a settle cooldown (so we don't instantly re-tap)", function()
  local bound = _AA_TEST.lifetap_bound
  with({ lifetapping = true }, function()
    bound()
    expect(state.lifetapping):eq(false)
    expect(state.lifetap_retry_at ~= nil and state.lifetap_retry_at > os.time()):truthy()
  end)
  with({ lifetapping = true, recover = false }, function()   -- outside recovery: no cooldown to set
    bound()
    expect(state.lifetapping):eq(false)
    expect(state.lifetap_retry_at):eq(nil)
  end)
end)

test("maybe_lifetap never stops a running bleed itself — the game ends it", function()
  with({ lifetapping = true, mana = 95, pct = 0.90 }, function(sent)  -- mana passed target mid-bleed
    maybe()
    expect(#sent):eq(0)   -- NOT "lifetap stop" — we let the game bind the wound
  end)
  with({ lifetapping = true, hp = 100 }, function(sent)
    maybe()
    expect(#sent):eq(0)
  end)
end)

test("maybe_lifetap is a no-op when HP hasn't regenerated back above the start line", function()
  with({ hp = 55, maxhp = 100 }, function(sent) maybe(); expect(#sent):eq(0) end)  -- at the floor between taps
  with({ hp = 70, maxhp = 100 }, function(sent) maybe(); expect(#sent):eq(0) end)  -- in the campaign but below 75%
end)

-- ---- the loop fix: choose_recovery_position forces rest, never sleep, across the campaign -------

test("choose forces REST (not sleep) across the campaign — even sitting right at the floor", function()
  -- `recover mana`, HP resting at the 55% floor between taps, mana still low: before the fix the picker
  -- read HP as low and slept (binding the wound). It must stay at rest.
  with({ stat = "mana", hp = 55, maxhp = 100, mana = 20, sharp = false, position = "sleeping" },
    function(sent)
      choose()
      expect(sent[1]):eq("rest")   -- woken to rest, NOT left asleep
    end)
end)

test("choose forces REST when a bleed is warranted even below the hp target (optimize for time)", function()
  with({ stat = false, pct = 0.90, hp = 70, maxhp = 100, mana = 20, sharp = false, position = "sleeping" },
    function(sent)
      choose()
      expect(sent[1]):eq("rest")
    end)
end)

test("choose still sleeps for HP when there's no bleed to protect (non-necromancer)", function()
  with({ stat = false, pct = 0.90, hp = 40, maxhp = 100, mana = 20, stam = 40,
         classes = { Cleric = { level = 30 } }, position = "standing" },
    function(sent)
      choose()
      expect(sent[1]):eq("sleep")
    end)
end)
