-- Specs for minion healing during recovery (AlterAeon.lua). `recover` doesn't just rest YOU — it casts
-- bolster/soothe on the player's no-regen skeletal minions until they're at FULL, waits on natural-regen
-- minions (flesh beast, clay man, ...) to come back on their own, and only calls itself done once both
-- you and every minion are topped off. These drive the SAME state machine the live Swift triggers hit
-- (via _AA_TEST): try_cast_heal (the driver) and minion_cast_settled (the reply-line pacing).

local AA = _AA_TEST

local function me()                 return { name = "Me", hp = 100, maxhp = 100 } end
local function minion(name, hp, mhp) return { name = name, hp = hp, maxhp = mhp,
                                              mana = 0, maxmana = 0, stam = 0, maxstam = 0, flags = "M" } end

-- Set up a recovering party + a send-capture, run fn(sent), restore. Vitals default to full (so the
-- player side never blocks); override via opts for the posture/completion tests.
local function with_group(group, opts, fn)
  opts = opts or {}
  local saved_state, saved_send = state, send
  local sent = {}
  state = {
    name = "Me",
    recover = (opts.recover ~= false),
    position = opts.position or "resting",
    action = opts.action or 0,
    hp = opts.hp or 100, maxhp = 100,
    mana = opts.mana or 100, maxmana = 100,
    stam = opts.stam or 100, maxstam = 100,
    group = group,
  }
  _G.send = function(c) sent[#sent + 1] = c end
  AA.reset_minion_heal()
  local ok, err = pcall(function() fn(sent) end)
  state, _G.send = saved_state, saved_send
  AA.reset_minion_heal()
  if not ok then error(err, 2) end
end

-- ---- classification ------------------------------------------------------------------------------

test("minion_needs_spell_heal: skeletal/bone constructs yes; regen minions & the player no", function()
  local f = AA.minion_needs_spell_heal
  expect(f("A skeletal spider")):truthy()
  expect(f("A skeletal mage")):truthy()
  expect(f("a bone golem")):truthy()
  expect(f("A flesh beast")):falsy()
  expect(f("a clay man")):falsy()
  expect(f("an energetic green demon")):falsy()
  expect(f("Vaelith")):falsy()
end)

test("minion_target_word is the last word of the name (the noun the player types)", function()
  expect(AA.minion_target_word("A skeletal spider")):eq("spider")
  expect(AA.minion_target_word("A skeletal mage")):eq("mage")
  expect(AA.minion_target_word("a bone golem")):eq("golem")
end)

-- ---- readiness gates -----------------------------------------------------------------------------

test("minions_pending_spell_heal: only a below-full SKELETAL minion counts", function()
  with_group({ me(), minion("A flesh beast", 100, 485) }, {}, function()
    expect(AA.minions_pending_spell_heal()):falsy()          -- a hurt regen minion doesn't count
  end)
  with_group({ me(), minion("A skeletal spider", 30, 39) }, {}, function()
    expect(AA.minions_pending_spell_heal()):truthy()
  end)
  with_group({ me(), minion("A skeletal spider", 39, 39) }, {}, function()
    expect(AA.minions_pending_spell_heal()):falsy()          -- already full
  end)
end)

test("all_minions_ready: SMALL pools must be full, BIG pools only need frac; player excluded", function()
  with_group({ me(), minion("A skeletal spider", 38, 39) }, {}, function()  -- 97% but pool<100 → not full
    expect(AA.all_minions_ready(0.90)):falsy()
  end)
  with_group({ me(), minion("A skeletal spider", 39, 39) }, {}, function()
    expect(AA.all_minions_ready(0.90)):truthy()
  end)
  with_group({ me(), minion("A flesh beast", 437, 485) }, {}, function()   -- ~90.1% big pool → ready at frac
    expect(AA.all_minions_ready(0.90)):truthy()
  end)
  with_group({ me(), minion("A flesh beast", 300, 485) }, {}, function()   -- ~62% big pool → not ready
    expect(AA.all_minions_ready(0.90)):falsy()
  end)
end)

test("the ready threshold is by POOL SIZE, not creature type", function()
  -- A big-pool construct (200 max) only needs frac even though it's skeletal…
  with_group({ me(), minion("a bone golem", 180, 200) }, {}, function()    -- 90% of a 200 pool
    expect(AA.all_minions_ready(0.90)):truthy()
  end)
  with_group({ me(), minion("a bone golem", 179, 200) }, {}, function()    -- 89.5% → below frac
    expect(AA.all_minions_ready(0.90)):falsy()
  end)
  -- …and a small-pool natural creature (<100) must be topped to FULL even though it self-regens.
  with_group({ me(), minion("a fire beetle", 89, 90) }, {}, function()     -- 98.9%, not full
    expect(AA.all_minions_ready(0.90)):falsy()
  end)
  with_group({ me(), minion("a fire beetle", 90, 90) }, {}, function()
    expect(AA.all_minions_ready(0.90)):truthy()
  end)
end)

-- ---- the driver: try_cast_heal -------------------------------------------------------------------

test("casts at the single skeletal minion by bare keyword; bolster when badly hurt, soothe near full", function()
  with_group({ me(), minion("A skeletal mage", 40, 79) }, {}, function(sent)   -- ~51% → bolster
    AA.try_cast_heal()
    expect(#sent):eq(1)
    expect(sent[1]):eq("c bolster mage")
  end)
  with_group({ me(), minion("A skeletal mage", 70, 79) }, {}, function(sent)   -- ~89% → soothe (won't over-power)
    AA.try_cast_heal()
    expect(sent[1]):eq("c soothe mage")
  end)
end)

test("heals the MOST-hurt skeletal minion first", function()
  with_group({ me(), minion("A skeletal mage", 70, 79), minion("A skeletal spider", 5, 39) }, {}, function(sent)
    AA.try_cast_heal()
    expect(sent[1]):eq("c bolster spider")   -- spider (~13%) is worse than the mage (~89%)
  end)
end)

test("multiples: targets N.keyword and a refusal advances the sweep to the next ordinal", function()
  local group = { me(),
    minion("A skeletal spider", 30, 39),   -- ~77% → soothe
    minion("A skeletal spider", 39, 39),
    minion("A skeletal spider", 39, 39) }
  with_group(group, {}, function(sent)
    AA.try_cast_heal()
    expect(sent[1]):eq("c soothe 1.spider")
    AA.minion_cast_settled("full")         -- refused → sweep to 2, retry
    expect(sent[2]):eq("c soothe 2.spider")
    AA.minion_cast_settled("full")         -- sweep to 3
    expect(sent[3]):eq("c soothe 3.spider")
  end)
end)

test("no cast when not recovering, asleep, busy, or a cast is already in flight", function()
  local g = { me(), minion("A skeletal spider", 10, 39) }
  with_group(g, { recover = false },   function(sent) AA.try_cast_heal(); expect(#sent):eq(0) end)
  with_group(g, { position = "sleeping" }, function(sent) AA.try_cast_heal(); expect(#sent):eq(0) end)
  with_group(g, { action = 50 },       function(sent) AA.try_cast_heal(); expect(#sent):eq(0) end)
  with_group(g, {}, function(sent)
    AA.try_cast_heal(); expect(#sent):eq(1)   -- first cast goes out
    AA.try_cast_heal(); expect(#sent):eq(1)   -- still casting → second is a no-op
  end)
end)

-- ---- pacing: minion_cast_settled -----------------------------------------------------------------

test("a spell failure retries the SAME target (no sweep advance)", function()
  local g = { me(), minion("A skeletal spider", 10, 39), minion("A skeletal spider", 39, 39) }
  with_group(g, {}, function(sent)
    AA.try_cast_heal()
    expect(sent[1]):eq("c bolster 1.spider")   -- 10/39 ~26% → bolster
    AA.minion_cast_settled("fail")             -- fizzled → same target again
    expect(sent[2]):eq("c bolster 1.spider")
  end)
end)

test("a landed heal waits for the next roster before the next cast", function()
  with_group({ me(), minion("A skeletal spider", 10, 39) }, {}, function(sent)
    AA.try_cast_heal()
    expect(#sent):eq(1)
    AA.minion_cast_settled("ok")               -- landed → do NOT immediately re-cast (roster drives next)
    expect(#sent):eq(1)
    expect(AA.minion_heal.casting):falsy()
  end)
end)

test("gives up on a keyword after sweeping it without ever landing a heal (no infinite loop)", function()
  local g = { me(), minion("A skeletal spider", 10, 39), minion("A skeletal spider", 20, 39) }
  with_group(g, {}, function(sent)
    AA.try_cast_heal()                         -- K=2 → cap is K+3 = 5 refusals
    for _ = 1, 6 do AA.minion_cast_settled("full") end
    expect(AA.minion_heal.blocked["spider"]):truthy()
    expect(AA.minions_pending_spell_heal()):truthy()   -- still hurt, but we stop hammering it
  end)
end)

test("'must use your name' (no valid target) is treated like a refusal", function()
  local g = { me(), minion("A skeletal spider", 10, 39), minion("A skeletal spider", 39, 39) }
  with_group(g, {}, function(sent)
    AA.try_cast_heal()
    expect(sent[1]):eq("c bolster 1.spider")
    AA.minion_cast_settled("notgt")            -- resolved to self → advance sweep, try next
    expect(sent[2]):eq("c bolster 2.spider")
  end)
end)

-- ---- integration with posture + completion -------------------------------------------------------

test("choose_recovery_position won't sleep while a skeletal minion still needs healing", function()
  local saved_state, saved_send = state, send
  local sent = {}
  -- All vitals low → normally wants sleep; a hurt skeletal minion caps posture at rest so we can cast.
  state = { name = "Me", hp = 40, maxhp = 100, mana = 40, maxmana = 100, stam = 40, maxstam = 100,
            position = "standing", recover = true,
            group = { me(), minion("A skeletal spider", 10, 39) } }
  _G.send = function(c) sent[#sent + 1] = c end
  AA.choose_recovery_position()
  state, _G.send = saved_state, saved_send
  expect(sent[1]):eq("rest")                   -- NOT sleep
end)

test("choose_recovery_position sleeps once the skeletal minions are topped off", function()
  local saved_state, saved_send = state, send
  local sent = {}
  state = { name = "Me", hp = 40, maxhp = 100, mana = 40, maxmana = 100, stam = 40, maxstam = 100,
            position = "sitting", recover = true,
            group = { me(), minion("A skeletal spider", 39, 39) } }   -- minion full → free to sleep
  _G.send = function(c) sent[#sent + 1] = c end
  AA.choose_recovery_position()
  state, _G.send = saved_state, saved_send
  expect(sent[1]):eq("sleep")
end)

-- A FULL player shouldn't stay asleep just because minions aren't done. If skeletal minions still need
-- casting, wake to rest (can't cast asleep); if only natural-regen minions are left, stand up and wait.
local function choose_with(position, group)
  local saved_state, saved_send = state, send
  local sent = {}
  state = { name = "Me", hp = 100, maxhp = 100, mana = 100, maxmana = 100, stam = 100, maxstam = 100,
            position = position, recover = true, group = group }
  _G.send = function(c) sent[#sent + 1] = c end
  AA.choose_recovery_position()
  state, _G.send = saved_state, saved_send
  return sent
end

test("full player with a skeletal minion still to heal WAKES from sleep to rest", function()
  local sent = choose_with("sleeping", { me(), minion("A skeletal spider", 10, 39) })
  expect(sent[1]):eq("rest")   -- can't cast asleep → drop to resting
end)

test("full player waiting only on natural-regen minions STANDS UP (nothing to do)", function()
  local sent = choose_with("sleeping", { me(), minion("A flesh beast", 300, 485) })
  expect(sent[1]):eq("stand")
end)

test("full player already standing while waiting on regen minions sends nothing", function()
  local sent = choose_with("standing", { me(), minion("A flesh beast", 300, 485) })
  expect(#sent):eq(0)
end)

test("recovery doesn't complete until skeletal minions are topped off", function()
  local saved_state, saved_send = state, send
  state = { name = "Me", hp = 100, maxhp = 100, mana = 100, maxmana = 100, stam = 100, maxstam = 100,
            position = "resting", recover = true,
            group = { me(), minion("A skeletal spider", 38, 39) } }
  _G.send = function() end
  local resolved
  AA.recovery.settle = { resolve = function() resolved = true end, reject = function() end }
  local not_yet = AA.maybe_complete_recovery()                 -- spider not full → keep going
  state.group[2].hp = 39                                       -- now topped
  local now = AA.maybe_complete_recovery()
  AA.recovery.settle, AA.recovery.pct = nil, AA.READY_PCT
  state, _G.send = saved_state, saved_send
  expect(not_yet):falsy()
  expect(now):truthy()
  expect(resolved):truthy()
end)
