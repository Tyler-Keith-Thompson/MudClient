-- Specs for the `recover` readiness threshold (AlterAeon.lua). `recover` rests/sleeps until ready(),
-- then auto-stands; "ready" means every vital at least 90%.

local ready = _AA_TEST.ready

local function with_state(hp, mp, sp, fn)
  local saved = state
  state = { hp = hp, maxhp = 100, mana = mp, maxmana = 100, stam = sp, maxstam = 100 }
  local ok, err = pcall(fn)
  state = saved
  if not ok then error(err, 2) end
end

test("ready() is true only when every vital is at least 90%", function()
  with_state(90, 95, 100, function() expect(ready()):truthy() end)   -- exactly 90% counts
  with_state(100, 100, 100, function() expect(ready()):truthy() end)
end)

test("ready() is false if any single vital is below 90%", function()
  with_state(89, 100, 100, function() expect(ready()):falsy() end)   -- hp low
  with_state(100, 89, 100, function() expect(ready()):falsy() end)   -- mana low
  with_state(100, 100, 89, function() expect(ready()):falsy() end)   -- stamina low
end)

-- ---- context-aware recovery posture (choose_recovery_position) -----------------------------------

local choose = _AA_TEST.choose_recovery_position
local depth  = _AA_TEST.recovery_depth

-- Set vitals + current posture, capture what choose_recovery_position() sends.
local function with_posture(hp, mp, sp, position, fn)
  local saved_state, saved_send = state, send
  local sent = {}
  state = { hp = hp, maxhp = 100, mana = mp, maxmana = 100, stam = sp, maxstam = 100, position = position }
  _G.send = function(c) sent[#sent + 1] = c end
  _AA_TEST.reset_posture()   -- clear the cross-test posture debounce so a repeated command isn't eaten
  local ok, err = pcall(function() fn(sent) end)
  state, _G.send = saved_state, saved_send
  if not ok then error(err, 2) end
end

test("recovery_depth ranks postures (standing<sitting/resting<sleeping, unknown=0)", function()
  expect(depth("standing")):eq(0)
  expect(depth("sitting")):eq(1)
  expect(depth("resting")):eq(1)
  expect(depth("sleeping")):eq(2)
  expect(depth("meditating")):eq(0)   -- unmapped → 0
  expect(depth(nil)):eq(0)
end)

test("from standing, choose sends the wanted posture", function()
  with_posture(90, 50, 90, "standing", function(sent)   -- hp/stam high, mana low → rest
    choose(); expect(sent[1]):eq("rest")
  end)
  with_posture(40, 40, 40, "standing", function(sent)   -- everything low → sleep
    choose(); expect(sent[1]):eq("sleep")
  end)
end)

test("already resting/sitting when rest is enough sends nothing (no redundant rest)", function()
  with_posture(90, 50, 90, "sitting", function(sent) choose(); expect(#sent):eq(0) end)
  with_posture(90, 50, 90, "resting", function(sent) choose(); expect(#sent):eq(0) end)
end)

test("sitting but wanting deeper recovery escalates to sleep", function()
  with_posture(40, 40, 40, "sitting", function(sent)    -- want sleep, only at depth 1 → escalate
    choose(); expect(sent[1]):eq("sleep")
  end)
end)

test("does NOT re-send a posture command while it's still in flight (no 'already resting' spam)", function()
  -- choose runs on every prompt (many/sec); position lags the command by a round-trip, so a naive
  -- re-check would fire "rest" repeatedly until the kxwt_position update lands. It must send exactly once.
  with_posture(90, 50, 90, "standing", function(sent)   -- wants rest, currently standing
    choose(); choose(); choose()                        -- position still "standing" for all three
    expect(#sent):eq(1)
    expect(sent[1]):eq("rest")
  end)
end)

test("already sleeping never re-sends (deeper than any target)", function()
  with_posture(40, 40, 40, "sleeping", function(sent) choose(); expect(#sent):eq(0) end)  -- want sleep
  with_posture(90, 50, 90, "sleeping", function(sent) choose(); expect(#sent):eq(0) end)  -- want rest, don't downgrade
end)

-- ---- rvnum: a `look` (same room) must NOT abort recovery; a real move must ----------------------

local note_room = _AA_TEST.note_room

-- Recovering in a known room; capture whether the recovery's promise settle gets rejected.
local function with_recovering_room(fn)
  local saved = state
  state = { hp = 50, maxhp = 100, mana = 50, maxmana = 100, stam = 50, maxstam = 100,
            recover = true, room_id = 100, room_coord = { 5, 6, 7, 0 } }
  local rejected
  _AA_TEST.recovery.settle = { resolve = function() end, reject = function(r) rejected = r end }
  local ok, err = pcall(function() fn(function() return rejected end) end)
  state = saved
  _AA_TEST.recovery.settle, _AA_TEST.recovery.pct = nil, _AA_TEST.READY_PCT
  if not ok then error(err, 2) end
end

test("rvnum with the SAME room (a look) does not end recovery", function()
  with_recovering_room(function(rej)
    note_room(100, 5, 6, 7, 0)                 -- identical id + coords → it's a look, not a move
    expect(state.recover):truthy()             -- still recovering
    expect(rej()):eq(nil)                      -- promise not rejected
  end)
end)

test("rvnum with a DIFFERENT room (a real move) ends recovery", function()
  with_recovering_room(function(rej)
    note_room(101, 5, 6, 7, 0)                 -- different room id → a move
    expect(state.recover):falsy()
    expect(rej()):eq("moved")
  end)
end)

test("rvnum with the same id but different COORDS also counts as a move", function()
  with_recovering_room(function(rej)
    note_room(100, 5, 6, 8, 0)                 -- z changed
    expect(state.recover):falsy()
    expect(rej()):eq("moved")
  end)
end)

-- ---- single-stat recovery (`recover hp|mana|stamina`) -------------------------------------------
-- recovery.stat scopes the "done" check to ONE vital (ignoring the others and any minions).

local one_stat_ready = _AA_TEST.one_stat_ready
local stat_ready     = _AA_TEST.stat_ready
local rec            = _AA_TEST.recovery
local maybe_complete = _AA_TEST.maybe_complete_recovery

test("STAT_ALIASES maps the typed words onto canonical keys", function()
  local a = _AA_TEST.STAT_ALIASES
  expect(a.hp):eq("hp"); expect(a.health):eq("hp"); expect(a.hitpoints):eq("hp")
  expect(a.mana):eq("mana"); expect(a.mp):eq("mana")
  expect(a.stamina):eq("stam"); expect(a.sp):eq("stam"); expect(a.sta):eq("stam")
end)

test("one_stat_ready checks only the named stat", function()
  local saved = state
  state = { hp = 40, maxhp = 100, mana = 95, maxmana = 100, stam = 40, maxstam = 100 }
  expect(one_stat_ready("mana")):truthy()    -- mana 95% ≥ 90
  expect(one_stat_ready("hp")):falsy()       -- hp 40% < 90
  expect(one_stat_ready("stam")):falsy()
  state = saved
end)

test("stat_ready follows recovery.stat (one stat), else falls back to every-vital ready()", function()
  local saved, saved_stat = state, rec.stat
  state = { hp = 40, maxhp = 100, mana = 95, maxmana = 100, stam = 40, maxstam = 100 }
  rec.stat = "mana"; expect(stat_ready()):truthy()   -- only mana matters, and it's up
  rec.stat = "hp";   expect(stat_ready()):falsy()    -- hp is the target and it's low
  rec.stat = nil;    expect(stat_ready()):falsy()    -- every vital: hp/stam low → not ready
  state, rec.stat = saved, saved_stat
end)

-- Drive maybe_complete_recovery under a single-stat recovery; capture resolve + sent commands.
local function with_stat_recovery(statkey, hp, mp, sp, fn)
  local saved_state, saved_send, saved_settle, saved_stat, saved_pct =
        state, send, rec.settle, rec.stat, rec.pct
  local sent, resolved = {}, false
  state = { hp = hp, maxhp = 100, mana = mp, maxmana = 100, stam = sp, maxstam = 100,
            recover = true, position = "resting" }
  _G.send = function(c) sent[#sent + 1] = c end
  rec.settle = { resolve = function() resolved = true end, reject = function() end }
  rec.stat, rec.pct = statkey, _AA_TEST.READY_PCT
  _AA_TEST.reset_posture()
  local ok, err = pcall(function() fn(sent, function() return resolved end) end)
  state, _G.send = saved_state, saved_send
  rec.settle, rec.stat, rec.pct = saved_settle, saved_stat, saved_pct
  if not ok then error(err, 2) end
end

test("single-stat recovery completes when JUST the target stat hits 90% (others still low)", function()
  with_stat_recovery("mana", 40, 95, 40, function(sent, res)   -- mana up, hp/stam low
    expect(maybe_complete()):truthy()
    expect(res()):truthy()                                     -- promise resolved
    expect(sent[#sent]):eq("stand")                            -- stood up
    expect(state.recover):falsy()
  end)
end)

test("single-stat recovery is NOT done while its target stat is still low (even if others are full)", function()
  with_stat_recovery("hp", 40, 100, 100, function(sent, res)   -- hp is the target and it's low
    expect(maybe_complete()):falsy()
    expect(res()):falsy()
    expect(state.recover):truthy()                             -- keeps recovering
  end)
end)

test("single-stat recovery ignores minions (no all_minions_ready gate)", function()
  -- A hurt skeletal minion would block a normal recovery, but a single-stat one completes anyway.
  local saved_group = state and state.group
  with_stat_recovery("stam", 40, 40, 95, function(sent, res)
    state.group = { { name = "skeletal spider", hp = 1, maxhp = 50, is_minion = true } }
    expect(maybe_complete()):truthy()                          -- stam is up → done, minion notwithstanding
    expect(res()):truthy()
  end)
  if state then state.group = saved_group end
end)

-- ---- self spell-recovery (spend surplus mana on your OWN vitals) ---------------------------------
-- `recover` can cast refresh (→ stamina) and bolster/soothe (→ hp, needs your name) when it beats
-- waiting for natural regen. Regen rates come from `show regen` (state.regen); the decision is greedy:
-- cast only if the stat is many ticks from target AND paying the mana keeps mana off the bottleneck.

local tt = _AA_TEST.ticks_to_target

test("ticks_to_target: 0 at target, deficit/rate otherwise, nil with no rate", function()
  expect(tt(90, 100, 10, 0.9)):eq(0)      -- already at 90% target
  expect(tt(50, 100, 10, 0.9)):eq(4)      -- deficit 40 / rate 10 = 4 ticks
  expect(tt(50, 100, nil, 0.9)):eq(nil)   -- unknown rate
  expect(tt(50, 100, 0, 0.9)):eq(nil)     -- zero rate
end)

-- Set up a recovering player (no minions) with regen data + a send-capture, run fn(sent), restore.
local function with_self_recovery(opts, fn)
  local saved_state, saved_send = state, send
  local saved_rec = { pct = rec.pct, stat = rec.stat, minions_only = rec.minions_only }
  local sent = {}
  state = {
    name = "Me", recover = true, position = opts.position or "resting", action = 0,
    hp = opts.hp or 100, maxhp = 100, mana = opts.mana or 100, maxmana = 100,
    stam = opts.stam or 100, maxstam = 100, group = {}, sharp = opts.sharp, regen = opts.regen,
    fighting = false, engaged_until = 0,
  }
  rec.pct, rec.stat, rec.minions_only = (opts.pct or _AA_TEST.READY_PCT), opts.stat, opts.minions_only
  _G.send = function(c) sent[#sent + 1] = c end
  _AA_TEST.reset_minion_heal(); _AA_TEST.reset_posture()
  local ok, err = pcall(function() fn(sent) end)
  state, _G.send = saved_state, saved_send
  rec.pct, rec.stat, rec.minions_only = saved_rec.pct, saved_rec.stat, saved_rec.minions_only
  _AA_TEST.reset_minion_heal()
  if not ok then error(err, 2) end
end

test("casts refresh when stamina is many ticks away and mana has slack", function()
  with_self_recovery({ stam = 30, regen = { hp = 10, mana = 20, move = 6, position = "resting" } },
    function(sent) _AA_TEST.try_cast_heal(); expect(sent[1]):eq("c refresh") end)
end)

test("casts bolster on yourself for a big hp wound (soothe when the wound is small)", function()
  with_self_recovery({ hp = 30, regen = { hp = 6, mana = 20, move = 10, position = "resting" } },
    function(sent) _AA_TEST.try_cast_heal(); expect(sent[1]):eq("c bolster Me") end)   -- 30% < 70% → bolster
  with_self_recovery({ hp = 75, regen = { hp = 3, mana = 20, move = 10, position = "resting" } },
    function(sent) _AA_TEST.try_cast_heal(); expect(sent[1]):eq("c soothe Me") end)     -- 75% ≥ 70% → soothe
end)

test("does NOT cast when natural regen is fast (stat within a few ticks of target)", function()
  with_self_recovery({ stam = 85, regen = { hp = 10, mana = 20, move = 20, position = "resting" } },
    function(sent) _AA_TEST.try_cast_heal(); expect(#sent):eq(0) end)   -- 5 pts / 20 = 0.25 tick → just wait
end)

test("does NOT cast when spending would make MANA the slower bottleneck", function()
  with_self_recovery({ hp = 30, mana = 55, regen = { hp = 6, mana = 1, move = 10, position = "resting" } },
    function(sent) _AA_TEST.try_cast_heal(); expect(#sent):eq(0) end)   -- mana regen too slow to spare 14
end)

test("does NOT cast when mana is below the half-full floor", function()
  with_self_recovery({ hp = 30, mana = 40, regen = { hp = 6, mana = 20, move = 10, position = "resting" } },
    function(sent) _AA_TEST.try_cast_heal(); expect(#sent):eq(0) end)
end)

test("single-stat scope: `recover hp` never refreshes, `recover stamina` never self-heals", function()
  -- recover hp: hp full, stam low → nothing (stam out of scope)
  with_self_recovery({ stat = "hp", hp = 100, stam = 30, regen = { hp = 6, mana = 20, move = 6, position = "resting" } },
    function(sent) _AA_TEST.try_cast_heal(); expect(#sent):eq(0) end)
  -- recover stamina: stam full, hp low → nothing (hp out of scope)
  with_self_recovery({ stat = "stam", hp = 30, stam = 100, regen = { hp = 6, mana = 20, move = 6, position = "resting" } },
    function(sent) _AA_TEST.try_cast_heal(); expect(#sent):eq(0) end)
end)

test("a blocked stat (prior refuse) is skipped for the rest of the recovery", function()
  with_self_recovery({ stam = 30, regen = { hp = 10, mana = 20, move = 6, position = "resting" } },
    function(sent)
      _AA_TEST.minion_heal.self_stam_blocked = true
      _AA_TEST.try_cast_heal(); expect(#sent):eq(0)
    end)
end)

test("minion-only recovery never self-casts", function()
  with_self_recovery({ minions_only = true, hp = 30, regen = { hp = 6, mana = 20, move = 10, position = "resting" } },
    function(sent) _AA_TEST.try_cast_heal(); expect(#sent):eq(0) end)
end)

test("a self-cast refuse (over-strong heal / wrong target) blocks that stat; ok clears the streak", function()
  local mh = _AA_TEST.minion_heal
  _AA_TEST.reset_minion_heal()
  mh.casting, mh.last = true, { kind = "self_hp" }
  _AA_TEST.minion_cast_settled("full")
  expect(mh.self_hp_blocked):truthy()
  _AA_TEST.reset_minion_heal()
  mh.casting, mh.last = true, { kind = "self_stam" }
  _AA_TEST.minion_cast_settled("notgt")
  expect(mh.self_stam_blocked):truthy()
  _AA_TEST.reset_minion_heal()
  mh.casting, mh.last, mh.refuse_streak = true, { kind = "self_hp" }, 2
  _AA_TEST.minion_cast_settled("ok")
  expect(mh.self_hp_blocked):falsy()
  expect(mh.refuse_streak):eq(0)
  _AA_TEST.reset_minion_heal()
end)

-- Slow regen so a cast beats waiting (stam ~10 ticks off; mana easily spares 15).
local CAST_REGEN = { hp = 10, mana = 20, move = 6, position = "resting" }

test("posture: sleep to earn sharp first (no cast worth it yet), then rest to cast once sharp+worth it", function()
  -- physical deficit + mana, not sharp, no regen data → can't confirm a cast helps → sleep to earn sharp
  with_self_recovery({ position = "standing", mana = 90, stam = 30, sharp = false },
    function(sent) _AA_TEST.choose_recovery_position(); expect(sent[1]):eq("sleep") end)
  -- sharp now AND regen shows a refresh beats waiting → rest so we can cast it
  with_self_recovery({ position = "standing", mana = 90, stam = 30, sharp = true, regen = CAST_REGEN },
    function(sent) _AA_TEST.choose_recovery_position(); expect(sent[1]):eq("rest") end)
end)

test("once sharp with a worthwhile cast, actively drops from sleep to rest (not blocked by the deepen-only guard)", function()
  with_self_recovery({ position = "sleeping", mana = 90, stam = 30, sharp = true, regen = CAST_REGEN },
    function(sent) _AA_TEST.choose_recovery_position(); expect(sent[1]):eq("rest") end)
end)

test("while not sharp, keeps sleeping (earning sharp) instead of waking early", function()
  with_self_recovery({ position = "sleeping", mana = 90, stam = 30, sharp = false },
    function(sent) _AA_TEST.choose_recovery_position(); expect(#sent):eq(0) end)
end)

test("narrates each recovery decision, deduped (same decision announces once)", function()
  local saved_echo = echo
  local msgs = {}
  _G.echo = function(m, ...) msgs[#msgs + 1] = m end
  _AA_TEST.reset_narration()
  with_self_recovery({ hp = 30, regen = { hp = 6, mana = 20, move = 10, position = "resting" } },
    function()
      _AA_TEST.try_cast_heal()                       -- casts bolster → narrates cast:hp
      _AA_TEST.minion_heal.casting = false
      _AA_TEST.try_cast_heal()                       -- SAME decision → no new narration
    end)
  _G.echo = saved_echo
  local casts = 0
  for _, m in ipairs(msgs) do if type(m) == "string" and m:find("casting bolster") then casts = casts + 1 end end
  expect(casts):eq(1)                                -- deduped: announced exactly once
end)

test("narrates the sleep-for-sharp then rest-to-cast posture strategy", function()
  local saved_echo = echo
  local msgs = {}
  _G.echo = function(m, ...) msgs[#msgs + 1] = m end
  local function last_match(pat)
    for i = #msgs, 1, -1 do if type(msgs[i]) == "string" and msgs[i]:find(pat) then return true end end
  end
  _AA_TEST.reset_narration()
  with_self_recovery({ position = "standing", mana = 90, stam = 30, sharp = false },
    function() _AA_TEST.choose_recovery_position() end)
  expect(last_match("get sharp first")):truthy()
  _AA_TEST.reset_narration()
  with_self_recovery({ position = "standing", mana = 90, stam = 30, sharp = true, regen = CAST_REGEN },
    function() _AA_TEST.choose_recovery_position() end)
  _G.echo = saved_echo
  expect(last_match("resting so I can cast")):truthy()
end)

-- ---- regen cache (show regen results, keyed by posture+sharp; busted by level or 2-day age) ------

test("total_level sums the per-class levels from state.classes", function()
  local saved = state
  state = { classes = { mage = { level = 14 }, cleric = { level = 9 }, necromancer = { level = 19 } } }
  expect(_AA_TEST.total_level()):eq(42)
  state = { classes = {} }
  expect(_AA_TEST.total_level()):eq(0)
  state = saved
end)

test("regen_key buckets posture (sitting≡resting) and is nil when sharp is unknown", function()
  local k = _AA_TEST.regen_key
  expect(k("standing", false)):eq("0:0")
  expect(k("resting", true)):eq("1:1")
  expect(k("sitting", true)):eq("1:1")      -- sitting collapses to the resting regen tier
  expect(k("sleeping", false)):eq("2:0")
  expect(k("resting", nil)):eq(nil)         -- sharp unknown → force a fresh query
end)

test("regen_fresh: valid within TTL at the same level; stale when too old or the level changed", function()
  local saved = state
  state = { classes = { mage = { level = 10 } } }             -- total level 10
  local now = os.time()
  expect(_AA_TEST.regen_fresh({ at = now, lvl = 10 })):truthy()
  expect(_AA_TEST.regen_fresh({ at = now - (_AA_TEST.REGEN_TTL + 100), lvl = 10 })):falsy()  -- aged out
  expect(_AA_TEST.regen_fresh({ at = now, lvl = 9 })):falsy()                                 -- leveled since
  expect(_AA_TEST.regen_fresh(nil)):falsy()
  state = saved
end)

test("ensure_regen uses a fresh cached entry (no query); re-queries when the level bumps", function()
  local saved_state, saved_send = state, send
  local RC = _AA_TEST.regen_cache
  local sent = {}
  state = { recover = true, position = "resting", sharp = true, classes = { mage = { level = 5 } } }
  _G.send = function(c) sent[#sent + 1] = c end
  _AA_TEST.reset_regen_query()
  for key in pairs(RC) do RC[key] = nil end
  RC["1:1"] = { hp = 40, mana = 55, move = 25, at = os.time(), lvl = 5 }   -- fresh: resting + sharp, level 5
  _AA_TEST.ensure_regen()
  expect(#sent):eq(0)                         -- cache hit → no `show regen` round-trip
  expect(state.regen and state.regen.mana):eq(55)
  state.classes.mage.level = 6                -- level up → entry (lvl 5) no longer valid
  _AA_TEST.reset_regen_query()
  _AA_TEST.ensure_regen()
  expect(sent[1]):eq("show regen")            -- stale by level → re-query
  for key in pairs(RC) do RC[key] = nil end
  state, _G.send = saved_state, saved_send
end)
