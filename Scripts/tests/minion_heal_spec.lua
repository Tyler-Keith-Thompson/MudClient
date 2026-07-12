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
  AA.reset_posture()
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

test("minion_target_words: distinctive noun first, then descriptors, articles dropped", function()
  expect(table.concat(AA.minion_target_words("a clay man"), ",")):eq("man,clay")
  expect(table.concat(AA.minion_target_words("A skeletal spider"), ",")):eq("spider,skeletal")
  expect(table.concat(AA.minion_target_words("the ancient stone golem"), ",")):eq("golem,stone,ancient")
end)

-- The reported bug: a "clay man" answers to 'clay', not 'man', so `c soothe man` gets
-- "Sorry, 'man' isn't a valid target for the spell 'soothe wounds'." The driver must try the next
-- keyword, and once every keyword is refused give up on THAT minion (never loop) — narrating both.
test("a rejected target keyword retries the minion's other name-words, then gives up + narrates", function()
  with_group({ me(), minion("a clay man", 50, 100) }, {}, function(sent)
    local echoed, saved_echo = {}, echo
    _G.echo = function(s) echoed[#echoed + 1] = (tostring(s):gsub("\27%[[%d;]*m", "")) end
    local ok, err = pcall(function()
      AA.try_cast_heal()                                    -- first cast: primary keyword 'man'
      expect(sent[#sent]:match("(%S+)$")):eq("man")
      AA.minion_target_invalid("man")                       -- game refuses 'man' → retry 'clay'
      expect(sent[#sent]:match("(%S+)$")):eq("clay")        -- re-cast at the alternate keyword (observable retry)
      AA.minion_target_invalid("clay")                      -- refuses 'clay' too → give up on this minion
      local before = #sent
      AA.try_cast_heal()                                    -- driver moves on; no more casts at the blocked minion
      expect(#sent):eq(before)
    end)
    _G.echo = saved_echo
    if not ok then error(err) end
    local joined = table.concat(echoed, "\n")
    expect(joined:find("trying 'clay'", 1, true) ~= nil):truthy()   -- narrated the retry
    expect(joined:find("giving up", 1, true) ~= nil):truthy()       -- narrated the give-up
  end)
end)

-- ---- readiness gates -----------------------------------------------------------------------------

test("minions_pending_spell_heal: skeletal always; our natural-regen minion only when YOU'RE topped off", function()
  -- Player full → a hurt regen minion of OURS is now worth casting on (surplus mana tops the tank off).
  with_group({ me(), minion("A flesh beast", 100, 485) }, {}, function()
    expect(AA.minions_pending_spell_heal()):truthy()
  end)
  -- Player still low (mana) → don't spend it on a regen minion yet; let it self-regen while we recover.
  with_group({ me(), minion("A flesh beast", 100, 485) }, { mana = 40 }, function()
    expect(AA.minions_pending_spell_heal()):falsy()
  end)
  -- A hurt regen minion that ISN'T ours (no M group flag — another player) is never our job.
  with_group({ me(), { name = "Ally", hp = 100, maxhp = 485, flags = "P" } }, {}, function()
    expect(AA.minions_pending_spell_heal()):falsy()
  end)
  -- Skeletal minions still count regardless of your state (no natural regen — a cast is the only heal).
  with_group({ me(), minion("A skeletal spider", 30, 39) }, {}, function()
    expect(AA.minions_pending_spell_heal()):truthy()
  end)
  with_group({ me(), minion("A skeletal spider", 39, 39) }, {}, function()
    expect(AA.minions_pending_spell_heal()):falsy()          -- already full
  end)
end)

test("full player actively heals a hurt natural-regen minion: bolster when low, soothe near full", function()
  with_group({ me(), minion("A flesh beast", 100, 485) }, {}, function(sent)   -- ~21% → bolster
    AA.try_cast_heal()
    expect(sent[1]):eq("c bolster beast")
  end)
  with_group({ me(), minion("A flesh beast", 400, 485) }, {}, function(sent)   -- ~82% → soothe (>= BOLSTER_BELOW)
    AA.try_cast_heal()
    expect(sent[1]):eq("c soothe beast")
  end)
  -- While YOU still need mana, leave the regen minion alone — don't spend recovery mana on it yet.
  with_group({ me(), minion("A flesh beast", 100, 485) }, { mana = 40 }, function(sent)
    AA.try_cast_heal()
    expect(#sent):eq(0)
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

test("skeletal minions heal to FULL regardless of pool size; self-regen minions by pool size", function()
  -- A skeletal/undead construct has NO natural regen, so a big pool must STILL be topped all the way —
  -- stopping at frac would leave it permanently short (the reported skeletal-knight bug).
  with_group({ me(), minion("a bone golem", 198, 200) }, {}, function()    -- 99% of a 200 pool, still not full
    expect(AA.all_minions_ready(0.90)):falsy()
  end)
  with_group({ me(), minion("a bone golem", 200, 200) }, {}, function()    -- full → ready
    expect(AA.all_minions_ready(0.90)):truthy()
  end)
  -- A big-pool SELF-REGEN creature only needs frac — it'll regen the last points on its own.
  with_group({ me(), minion("A flesh beast", 437, 485) }, {}, function()   -- ~90.1% big pool → ready at frac
    expect(AA.all_minions_ready(0.90)):truthy()
  end)
  -- A small-pool self-regen creature (<100) is still topped to FULL (a few points is a big fraction).
  with_group({ me(), minion("a fire beetle", 89, 90) }, {}, function()     -- 98.9%, not full
    expect(AA.all_minions_ready(0.90)):falsy()
  end)
  with_group({ me(), minion("a fire beetle", 90, 90) }, {}, function()
    expect(AA.all_minions_ready(0.90)):truthy()
  end)
end)

test("a big-pool skeletal minion (the knight) is cast on PAST frac, all the way to full", function()
  -- Repro of the reported bug: the skeletal knight (a big pool) was left short of 100% because big pools
  -- only got `frac`. Skeletons never self-regen, so it must keep getting cast on until it's actually full.
  local function knight(hp, mhp) return minion("A spear wielding skeletal knight", hp, mhp) end
  with_group({ me(), knight(280, 300) }, {}, function(sent)   -- 93% — ABOVE a 90% frac, but NOT full
    expect(AA.all_minions_ready(0.90)):falsy()                -- recovery is not "done": a skeleton must be full
    AA.try_cast_heal()
    expect(sent[1]):eq("c soothe knight")                     -- still actively healing it (near full → soothe)
  end)
  with_group({ me(), knight(300, 300) }, {}, function(sent)   -- full → nothing left to do
    expect(AA.all_minions_ready(0.90)):truthy()
    AA.try_cast_heal()
    expect(#sent):eq(0)
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

test("does NOT heal minions when YOUR mana is critically low — recover your own mana first", function()
  local g = { me(), minion("A skeletal mage", 40, 79) }    -- a hurt skeletal minion that would normally heal
  with_group(g, { mana = 20 }, function(sent)               -- 20% mana < MINION_HEAL_MANA_MIN (30%)
    AA.try_cast_heal()
    expect(#sent):eq(0)                                     -- no cast — don't drain a critically low pool
  end)
  with_group(g, { mana = 50 }, function(sent)               -- 50% mana ≥ floor → healing resumes
    AA.try_cast_heal()
    expect(sent[1]):eq("c bolster mage")
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

-- ---- shared keyword: "skeleton" reaches the WHOLE skeletal family (a bare skeleton can't be singled out)

test("keyword_matches: 'skeleton' reaches every skeletal minion; specific nouns stay specific", function()
  expect(AA.keyword_matches("skeleton", "A skeleton")):truthy()
  expect(AA.keyword_matches("skeleton", "A skeletal mage")):truthy()
  expect(AA.keyword_matches("skeleton", "A skeletal spider")):truthy()
  expect(AA.keyword_matches("mage", "A skeletal mage")):truthy()
  expect(AA.keyword_matches("mage", "A skeleton")):falsy()          -- 'mage' only matches the mage
  expect(AA.keyword_matches("spider", "A skeletal mage")):falsy()
end)

test("keyword_count: 'skeleton' counts EVERY skeletal minion so the ordinal sweep can reach a bare one", function()
  local group = { me(),
    minion("A skeleton", 59, 119), minion("A skeletal mage", 79, 79),
    minion("A skeletal spider", 39, 39), minion("A skeletal spider", 39, 39) }
  with_group(group, {}, function()
    expect(AA.keyword_count("skeleton")):eq(4)   -- skeleton + mage + 2 spiders all answer to 'skeleton'
    expect(AA.keyword_count("mage")):eq(1)       -- 'mage' is specific
    expect(AA.keyword_count("spider")):eq(2)
  end)
end)

test("a hurt bare skeleton SWEEPS N.skeleton instead of forever hitting the full mage (the reported bug)", function()
  -- Roster from the raw log: a hurt "A skeleton" (the skeletal warrior) beside a FULL "A skeletal mage" and
  -- full spiders. 'skeleton' matches them all, so with K=1 (old bug) every cast went to the mage. With the
  -- family count the driver uses ordinals and can sweep past the full ones to the hurt skeleton.
  local group = { me(),
    minion("A skeleton", 59, 119),         -- HURT — the only one needing a heal
    minion("A skeletal mage", 79, 79),     -- full
    minion("A skeletal spider", 39, 39),   -- full
    minion("A skeletal spider", 39, 39) }
  with_group(group, {}, function(sent)
    AA.try_cast_heal()
    expect(sent[1]:find("^c %a+ 1%.skeleton$") ~= nil):truthy()   -- ordinal (K>1), NOT bare "skeleton"
    AA.minion_cast_settled("full")                                -- that slot was a full minion → sweep on
    expect(sent[2]:find("^c %a+ 2%.skeleton$") ~= nil):truthy()
    AA.minion_cast_settled("full")
    expect(sent[3]:find("^c %a+ 3%.skeleton$") ~= nil):truthy()   -- keeps advancing (old code was stuck at 1)
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
    -- Un-busied (the landed cast settled): the NEXT roster tick drives another cast (spider still hurt).
    AA.try_cast_heal()
    expect(#sent):eq(2)
  end)
end)

test("gives up on a keyword after sweeping it without ever landing a heal (no infinite loop)", function()
  local g = { me(), minion("A skeletal spider", 10, 39), minion("A skeletal spider", 20, 39) }
  with_group(g, {}, function(sent)
    local echoed, saved_echo = {}, echo
    _G.echo = function(s) echoed[#echoed + 1] = (tostring(s):gsub("\27%[[%d;]*m", "")) end
    AA.try_cast_heal()                         -- K=2 → cap is K+3 = 5 refusals
    for _ = 1, 6 do AA.minion_cast_settled("full") end
    _G.echo = saved_echo
    -- Gave up on the keyword: narrated the skip AND stops sending (no more casts at 'spider').
    expect(table.concat(echoed, "\n"):find("skipping it", 1, true) ~= nil):truthy()
    local before = #sent
    AA.try_cast_heal()
    expect(#sent):eq(before)                             -- stopped hammering it
    expect(AA.minions_pending_spell_heal()):truthy()     -- still hurt, but we don't cast at it
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
  AA.reset_posture()
  AA.choose_recovery_position()
  state, _G.send = saved_state, saved_send
  return sent
end

test("full player with a skeletal minion still to heal WAKES from sleep to rest", function()
  local sent = choose_with("sleeping", { me(), minion("A skeletal spider", 10, 39) })
  expect(sent[1]):eq("rest")   -- can't cast asleep → drop to resting
end)

test("full player with a hurt natural-regen minion WAKES to rest to heal it (surplus mana)", function()
  local sent = choose_with("sleeping", { me(), minion("A flesh beast", 300, 485) })
  expect(sent[1]):eq("rest")   -- topped off → wake and cast on the tank instead of just waiting
end)

test("full player already standing while healing a regen minion sends nothing (standing can cast)", function()
  local sent = choose_with("standing", { me(), minion("A flesh beast", 300, 485) })
  expect(#sent):eq(0)          -- already awake enough to cast; try_cast_heal drives the actual heal
end)

test("full player only waiting on ANOTHER PLAYER's regen (not ours) stands up — nothing to heal", function()
  local sent = choose_with("sleeping", { me(), { name = "Ally", hp = 300, maxhp = 485, flags = "P" } })
  expect(sent[1]):eq("stand")  -- no M-flag minion to heal → nothing to do → stand
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

-- ---- recover minions (minion-only recovery) ------------------------------------------------------

test("minion-only recovery: choose_recovery_position is a no-op (never rests/sleeps/stands you)", function()
  local saved_state, saved_send = state, send
  local sent = {}
  state = { name = "Me", hp = 40, maxhp = 100, mana = 40, maxmana = 100, stam = 40, maxstam = 100,
            position = "standing", recover = true,
            group = { me(), minion("A skeletal spider", 10, 39) } }
  AA.recovery.minions_only = true
  _G.send = function(c) sent[#sent + 1] = c end
  AA.reset_posture()
  AA.choose_recovery_position()
  AA.recovery.minions_only = nil
  state, _G.send = saved_state, saved_send
  expect(#sent):eq(0)                     -- no rest/sleep/stand — YOUR posture is untouched
end)

test("minion-only recovery completes when no skeletal minion still needs a cast", function()
  local saved_state, saved_send = state, send
  state = { name = "Me", hp = 40, maxhp = 100, mana = 40, maxmana = 100, stam = 40, maxstam = 100,
            recover = true, group = { me(), minion("A skeletal spider", 38, 39) } }
  _G.send = function() end
  AA.recovery.minions_only = true
  local resolved
  AA.recovery.settle = { resolve = function() resolved = true end, reject = function() end }
  local not_yet = AA.maybe_complete_recovery()   -- spider 38/39, pool<100 → must be full → still pending
  state.group[2].hp = 39                          -- topped off
  local now = AA.maybe_complete_recovery()
  AA.recovery.settle, AA.recovery.minions_only, AA.recovery.pct = nil, nil, AA.READY_PCT
  state, _G.send = saved_state, saved_send
  expect(not_yet):falsy()
  expect(now):truthy()
  expect(resolved):truthy()
end)
