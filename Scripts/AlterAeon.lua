-- AlterAeon game layer (ported from the old Swift KXWTHost).
--
-- All AlterAeon-specific knowledge now lives here, in hot-reloadable Lua, instead of the
-- generic Swift client. KXWT protocol lines are parsed by triggers (capture groups are passed
-- to the handler), feeding a shared global `state` table that AIPilot.lua reads. Recovery logic
-- (rest/sleep) lives here too.
--
-- Trigger patterns are SWIFT regular expressions, so they use [[...]] long strings to pass
-- backslash classes like \d through untouched.
--
-- This script is the game ENTRY POINT: loading it (at startup, via load("Scripts")) opens the
-- connection. The connect is top-level and guarded by is_connected() so a hot-reload() — which
-- re-runs this file in the LIVE state — never drops or redials an already-open session.
if not is_connected() then connect("alteraeon.com", 3002) end

-- The shared world-state table. AlterAeon OWNS the schema, but fills it DEFENSIVELY (merge missing
-- keys into whatever `state` already is) so load order doesn't matter: another script may create a
-- bare `state = state or {}` before this file runs (scripts now load in alphabetical, not manifest,
-- order), and this still installs every default without clobbering values already parsed in.
state = state or {}
do
  local defaults = {
    classes = {},
    fighting = false,
    opponents = {},                      -- inferred multi-opponent tracker (name -> {pct,exact,t})
    spells = {}, recover = false,
    inventory = {}, inv_known = false,   -- kxwt does NOT report inventory; we parse it from `inventory` output
    equipment = {}, eq_known = false,    -- nor what's worn/wielded; parsed from `equipment` output
    group = {},                          -- roster of you + pets/groupmates (kxwt_group_start..end)
    exits = {},                          -- set of available exit directions, parsed from "[Exits: ...]"
    effects = {},                        -- timed self-effects (kxwt_spst): name -> remaining-time text
    action = 0,                          -- kxwt_action code; >= 50 prevents spellcasting
    music = {},                          -- channel -> current track name (kxwt_music), for the HUD ♪
    auto_assist = true,                  -- auto-`assist` when your minions are fighting but you aren't
  }
  for k, v in pairs(defaults) do if state[k] == nil then state[k] = v end end
  -- (name/gold/exp/expcap/hp/maxhp/mana/maxmana/stam/maxstam/position/room_*/area/terrain/
  --  fight_name/fight_pct/walkdir/outdoors/sky_visible/overcast start nil and are filled by triggers.)
end

local function pct(cur, max) if not cur or not max or max == 0 then return 0 end return cur / max end
-- "Ready" = recovered enough to keep exploring: every vital at least 90%. Drives the `recover` alias's
-- auto-stand and the AI's " (ready)" readiness label, so both share one definition.
local READY_PCT = 0.90
-- ready([p]) — every vital at least p (fraction, default READY_PCT). recover([pct]) recovers to a
-- caller-chosen threshold, so this takes an argument; the no-arg callers (AI readiness label, the typed
-- `recover` alias) keep the 90% default.
local function ready(p)
  p = p or READY_PCT
  return pct(state.hp, state.maxhp) >= p and pct(state.mana, state.maxmana) >= p
     and pct(state.stam, state.maxstam) >= p
end

-- Recovery postures ranked by how deeply they heal (and how far they drop your guard): standing/kneeling
-- don't recover; `rest` (kxwt reports the resting state as sitting/resting) heals moderately while you
-- keep some awareness; `sleep` heals fastest but fully drops your guard. Unknown posture → 0, so we err
-- toward issuing a command rather than assuming we're already recovering.
local RECOVERY_DEPTH = { standing = 0, kneeling = 0, sitting = 1, resting = 1, sleeping = 2 }
local function recovery_depth(posn) return RECOVERY_DEPTH[posn or ""] or 0 end

-- Forward declarations for the minion-healing block (defined just below the recovery machinery). The
-- posture chooser and the completion check — both defined ABOVE that block — consult it: we must not
-- sleep while skeletal minions still need casting (you can't cast asleep), and recovery isn't "done"
-- until every minion is topped off too.
local minions_pending_spell_heal   -- () -> bool: any skeletal (no-regen) minion still below full
local all_minions_ready            -- (frac) -> bool: every minion at its target (skeletal=full, else frac)
local heal_minions_kick            -- () -> nil: (re)start the minion-heal driver
local reset_minion_heal            -- () -> nil: clear the minion-heal driver (on recovery end/cancel)
local recovery                     -- { pct, settle, stat } — the active recovery's target + promise callbacks
local self_cast_wanted             -- () -> bool: fwd decl (choose_recovery_position, above its definition)

-- Single-stat recovery (`recover hp|mana|stamina`): rest/sleep until just ONE vital hits the threshold,
-- ignoring the others (and ignoring minions). recovery.stat is the canonical key ("hp"/"mana"/"stam");
-- nil = the normal every-vital recovery. STAT_ALIASES maps the words a user might type onto that key.
local STAT_FIELDS  = { hp = { "hp", "maxhp" }, mana = { "mana", "maxmana" }, stam = { "stam", "maxstam" } }
local STAT_LABEL   = { hp = "HP", mana = "mana", stam = "stamina" }
local STAT_ALIASES = {
  hp = "hp", health = "hp", hitpoints = "hp",
  mana = "mana", mp = "mana",
  stamina = "stam", stam = "stam", sta = "stam", sp = "stam",
}
-- one_stat_ready(key, p) — just that stat at >= p. stat_ready(p) — the ACTIVE recovery's readiness:
-- the one stat if recovery.stat is set, else every vital (falls back to ready()).
local function one_stat_ready(key, p)
  local f = STAT_FIELDS[key]; if not f then return true end
  return pct(state[f[1]], state[f[2]]) >= (p or READY_PCT)
end
local function stat_ready(p)
  local st = recovery and recovery.stat
  if st then return one_stat_ready(st, p) end
  return ready(p)
end

-- A posture command (rest/sleep/stand) takes a moment to reflect in state.position (the kxwt_position
-- update lags the command by a round-trip). choose_recovery_position runs on EVERY prompt, so without a
-- guard it re-sends the same command many times before position catches up — the "You are already
-- resting." spam. Debounce: never repeat the SAME posture command within this window; a DIFFERENT command
-- (escalating rest->sleep, or standing) always goes through immediately. Self-heals if a command didn't
-- take (after the window, it may resend).
local POSTURE_REPEAT = 3
local last_posture_cmd, last_posture_at = nil, 0
local function send_posture(cmd)
  local now = os.time()
  if cmd == last_posture_cmd and (now - last_posture_at) < POSTURE_REPEAT then return end
  last_posture_cmd, last_posture_at = cmd, now
  send(cmd)
end
local function reset_posture() last_posture_cmd, last_posture_at = nil, 0 end

-- Pick the recovery posture for the current vitals, current posture, AND what the minions still need.
-- rest keeps more of your guard, so it wins when only mana is lacking (hp/stam already high); otherwise
-- sleep heals fastest. Context aware: only send a command when it actually changes the posture — and
-- never spams a duplicate while the last one is still in flight (send_posture).
local function choose_recovery_position()
  if recovery and recovery.minions_only then return end   -- minion-only recovery never touches YOUR posture
  local player_done = stat_ready(recovery and recovery.pct or nil)
  -- Single-stat recovery is player-only: it never casts on minions, so don't let a hurt skeletal minion
  -- hold the posture at `rest` (cast_pending caps sleep at rest so you can cast).
  local cast_pending = (not (recovery and recovery.stat))
    and minions_pending_spell_heal and minions_pending_spell_heal()
  if player_done then
    -- You're fully recovered; you're only still "recovering" because the minions aren't all topped off.
    -- There's no point staying asleep (or even resting) when you're full: either cast on the skeletal
    -- ones or just wait standing on the natural-regen ones.
    if cast_pending then
      -- You must cast bolster/soothe on the skeletal minions, which you can't do asleep — wake to resting.
      if recovery_depth(state.position) >= 2 then send_posture("rest") end
    else
      -- Only natural-regen minions left to wait on — nothing for you to do, so stand back up.
      if recovery_depth(state.position) > 0 then send_posture("stand") end
    end
    return
  end
  -- You still need to recover yourself. rest when only mana is low (keeps your guard), else sleep — but
  -- you can't cast while asleep, so cap at rest while skeletal minions still need bolster/soothe. rest
  -- heals you a bit slower than sleep, but the minions can't heal themselves at all.
  local hp, mp, sp = pct(state.hp, state.maxhp), pct(state.mana, state.maxmana), pct(state.stam, state.maxstam)
  local want = (hp > 0.85 and mp < 1 and sp > 0.75) and "rest" or "sleep"
  -- "Sleep until sharp, then cast": when spending mana on your own hp/stam is on the table, first SLEEP
  -- to earn the sharp buff (fast regen — which alone may finish the job); once sharp, drop to REST so we
  -- can actually cast the deficits the boosted regen still can't close quickly.
  local self_want = self_cast_wanted()
  if self_want then want = state.sharp and "rest" or "sleep" end
  if want == "sleep" and cast_pending then want = "rest" end   -- minions need casting → must be awake
  -- We must be AWAKE (resting, not asleep) to cast: for the minions, or once sharp for our own vitals.
  -- The deepen-only guard below would otherwise leave us asleep, so force the sleep→rest downgrade here.
  local need_awake = cast_pending or (self_want and state.sharp)
  if want == "rest" and need_awake and recovery_depth(state.position) >= 2 then send_posture("rest"); return end
  local target = (want == "sleep") and 2 or 1
  if recovery_depth(state.position) >= target then return end   -- already at least this deep → nothing to do
  send_posture(want)
end

-- Recovery-as-a-promise. `recovery.pct` is the current target threshold; `recovery.settle` holds the
-- resolve/reject callbacks of the promise recover() returned, while one is waiting (nil otherwise).
-- end_recovery() is the single settle point: it clears the flag, restores the default threshold, and
-- resolves (completed) or rejects (interrupted: you moved, a fight started, you cancelled) the promise.
recovery = { pct = READY_PCT, settle = nil }
local function end_recovery(completed, reason)
  state.recover = false
  if reset_minion_heal then reset_minion_heal() end   -- stop any in-flight minion healing
  local s = recovery.settle
  recovery.settle, recovery.pct, recovery.minions_only, recovery.stat = nil, READY_PCT, nil, nil
  if s then if completed then s.resolve() else s.reject(reason or "recovery interrupted") end end
end

-- Called from the kxwt_prompt trigger on every vitals update: stand + resolve once the target is met.
-- Factored out (and exposed via _AA_TEST) so the spec can drive completion without the Swift trigger.
local function maybe_complete_recovery()
  -- Minion-only recovery (`recover minions`): heal the skeletal minions and finish as soon as none still
  -- need a cast — YOUR vitals and posture are left entirely alone. Driven off the group roster, not the
  -- player prompt (minion HP changes with kxwt_group, not kxwt_prompt), so this is also checked there.
  if recovery.minions_only then
    if state.recover and not (minions_pending_spell_heal and minions_pending_spell_heal()) then
      echo("Minions topped off.")
      end_recovery(true)
      return true
    end
    return false
  end
  -- Done only when YOU are recovered AND every minion is topped off: skeletal (no-regen) minions we
  -- healed to full, natural-regen minions we simply waited on. Until then, keep resting (and, if the
  -- skeletal minions are now all healed but you still want to sleep for your own vitals, re-pick the
  -- posture so we escalate rest -> sleep).
  -- No posture gate: once you're standing-and-waiting on natural-regen minions (choose stands you up
  -- when you're full but they aren't), completion must still fire when they finally top off.
  if state.recover and stat_ready(recovery.pct)
     and (recovery.stat or (all_minions_ready and all_minions_ready(recovery.pct))) then
    if recovery.stat then echo(string.format("Your %s is recovered — standing up.", STAT_LABEL[recovery.stat]))
    else echo("You have recovered and are ready to adventure!") end
    send("stand")
    end_recovery(true)
    return true
  end
  -- Not done yet. Re-pick the posture: once the skeletal minions are finally topped off we're allowed to
  -- escalate rest -> sleep for your own remaining recovery. choose_recovery_position only sends when it
  -- actually deepens the posture, so this is a no-op on the common tick.
  if state.recover then choose_recovery_position() end
  return false
end

-- ---- Minion healing during recovery -------------------------------------------------------------
--
-- The player animates undead (skeletal spider/mage, bone constructs) that have NO natural regen: the
-- only way their HP comes back is the cleric actively casting on them. So `recover` doesn't just heal
-- YOU — it tops those minions off with bolster/soothe. Everything else the player fields (flesh beast,
-- clay man, summoned demons, natural pets) regenerates on its own; we never spend mana on them, but
-- recovery still waits for them to come back up before it calls itself done.
--
-- Pacing is one cast at a time, settled by the game's own reply lines (mirrors AutoFight): a heal lands
-- ("You repair the damage to X's body."), fails ("You fail to cast the spell '...'."), is refused
-- ("X doesn't need that much healing right now." — fires when the spell is too strong for a tiny wound
-- OR when we targeted the wrong one of several same-named minions; either way it REFUNDS the mana), or
-- finds no target ("...you must use your name."). A fresh group roster (or a timeout backstop) drives
-- the next cast.
--
-- Multiples: same-named minions are addressed by ordinal (1.spider, 2.spider, ...). The group roster's
-- order isn't guaranteed to match the room's `N.keyword` order, so we can't map a hurt roster entry to
-- a fixed ordinal. Instead we SWEEP: cycle the ordinal 1..K; the full ones refund harmlessly and the
-- hurt one gets healed within K casts. A refusal advances the sweep past that slot.

-- How full a minion must be before recovery is satisfied with it — by HP POOL SIZE, not creature type.
-- Small pools (< 100 max hp: the skeletal spiders/mage at ~40-80) must be topped to FULL, since a few
-- missing points is a big fraction of them. Big pools (the flesh beast's ~485) just respect the recovery
-- threshold `frac` — waiting for a huge bar to regen its last point is pointless. `frac` defaults to the
-- active recovery target (recovery.pct), so `recover 80` holds the flesh beast to 80% but still fulls the
-- little ones.
local MINION_FULL_BELOW = 100
local function minion_ready_target(m, frac)
  if (m.maxhp or 0) < MINION_FULL_BELOW then return 1.0 end
  return frac or (recovery and recovery.pct) or READY_PCT
end
-- Below this fraction a wound is big enough for bolster (the strong heal); at or above it we use soothe
-- (the weak heal) so the game doesn't refuse it as "doesn't need that much healing" near full.
local BOLSTER_BELOW = 0.70

-- ---- Self spell-recovery: spend surplus mana to top your OWN vitals faster than natural regen -------
--
-- A cleric can convert mana into hp (`bolster`/`soothe` on yourself — needs your name) or into stamina
-- (`refresh`, self by default). Mana can only come back by RESTING (no spell makes mana), so we convert
-- only when it genuinely "beats waiting": the target stat is many ticks of natural regen from its target
-- AND paying the spell's mana won't make mana the slower bottleneck. Natural regen rates come from
-- parsing `show regen` (state.regen = {hp, mana, move, position}; state.sharp) — auto-queried (gagged)
-- while recovering. A tick is ~30s; regen is fastest asleep, less resting, least standing, and higher
-- still while "sharp" (earned by sleeping a couple ticks) — so the plan is: sleep to get sharp first,
-- then rest and cast only the deficits the (now boosted) regen still can't close quickly.
local REFRESH_COST       = 15     -- mana; help: "Spell: refresh  Mana: 15"
local HEAL_COST          = 14     -- mana; bolster's cost (the pricier of the two — conservative guard)
local CAST_MIN_TICKS     = 3      -- don't bother casting if the stat is within this many ticks of target
local SELF_CAST_MANA_MIN = 0.50   -- only trade mana for hp/stam when mana is at least this full

-- ticks_to_target(cur,max,rate,frac) — ticks of natural regen to reach frac*max. 0 if already there;
-- nil when we have no positive rate (→ "unknown", never treated as slow-enough-to-cast).
local function ticks_to_target(cur, max, rate, frac)
  local target = (frac or READY_PCT) * (max or 0)
  local deficit = target - (cur or 0)
  if deficit <= 0 then return 0 end
  if not rate or rate <= 0 then return nil end
  return deficit / rate
end

-- cast_beats_waiting(cur,max,rate,cost) — is spending `cost` mana to top this stat faster than waiting?
-- True only with fresh regen data, when the stat is > CAST_MIN_TICKS from target, and paying `cost`
-- keeps mana's own ticks-to-target BELOW the stat's (so we never make mana the slower bottleneck — this
-- is the whole "only if it beats waiting" policy, and it protects mana, which no spell restores).
local function cast_beats_waiting(cur, max, rate, cost)
  local r = state.regen
  if not r then return false end
  local st = ticks_to_target(cur, max, rate, recovery and recovery.pct)
  if not st or st <= CAST_MIN_TICKS then return false end
  local mt = ticks_to_target((state.mana or 0) - cost, state.maxmana, r.mana, recovery and recovery.pct)
  if mt == nil then return false end       -- no mana rate known → don't risk starving mana
  return mt < st
end

-- self_cast_wanted() — cheap gate: is a self-cast even in scope? (mana at least half full, a physical
-- stat below the active target, and this recovery covers that stat — never during minion-only recovery).
-- Used for BOTH the posture cap (stay at rest so we can cast) and as a precondition to cast_beats_waiting.
self_cast_wanted = function()
  if recovery and recovery.minions_only then return false end
  if not state.maxmana or pct(state.mana, state.maxmana) < SELF_CAST_MANA_MIN then return false end
  local st = recovery and recovery.stat
  local frac = (recovery and recovery.pct) or READY_PCT
  local want_hp   = (st == nil or st == "hp")   and pct(state.hp, state.maxhp)     < frac
  local want_stam = (st == nil or st == "stam") and pct(state.stam, state.maxstam) < frac
  return want_hp or want_stam
end

-- Auto-refresh regen numbers for the CURRENT posture, gagged (see the show-regen trigger). Debounced so
-- we only have one query outstanding; the parse clears the flag, and a 2s backstop clears it if the
-- reply never matches (so a later manual `show regen` isn't swallowed).
local regen_query_pending = false
local function query_regen()
  if regen_query_pending then return end
  regen_query_pending = true
  send("show regen")
  after(2, function() regen_query_pending = false end)
end

-- Skeletal/undead constructs the player raises: no natural regen, must be spell-healed. Matched by name
-- ("skeletal spider", "skeletal mage", "bone ..."). Everything else is assumed to self-regen.
local function minion_needs_spell_heal(name)
  local low = (name or ""):lower()
  return low:find("skelet", 1, true) ~= nil or low:find("bone ", 1, true) ~= nil
end

-- Roster helpers. state.group includes YOU (name == state.name) plus pets/groupmates; a minion is any
-- entry that isn't you. (Other real players could be grouped too, but they regen and we never heal
-- them, so lumping them with the natural-regen crowd is harmless.)
local function is_self_row(m) return state.name and m.name == state.name end
local function minion_target_word(name)
  -- Cast target keyword = last word of the name ("A skeletal spider" -> "spider", "A skeletal mage"
  -- -> "mage"), which is the distinctive noun the player actually types (see human traces).
  return (name or ""):match("(%S+)%s*$") or ""
end

-- () -> bool: any skeletal (no-regen) minion still below its ready target — used to keep posture at rest.
minions_pending_spell_heal = function()
  for _, m in ipairs(state.group or {}) do
    if not is_self_row(m) and minion_needs_spell_heal(m.name)
       and pct(m.hp, m.maxhp) < minion_ready_target(m) then
      return true
    end
  end
  return false
end

-- (frac) -> bool: every minion at its ready target (small pools to full, big pools to `frac`) — whether
-- we heal them (skeletal) or just wait on their natural regen (flesh beast, clay man, ...).
all_minions_ready = function(frac)
  for _, m in ipairs(state.group or {}) do
    if not is_self_row(m) and pct(m.hp, m.maxhp) < minion_ready_target(m, frac) then return false end
  end
  return true
end

-- Driver state. `casting` = a heal is out, awaiting its reply line. `sweep[word]` = next ordinal to try
-- for that keyword. `blocked[word]` = gave up on it this recovery (backstop against a refuse loop).
-- `token` invalidates a stale timeout when a reply arrives first.
local minion_heal = { casting = false, sweep = {}, blocked = {}, refuse_streak = 0, token = 0, last = nil }

reset_minion_heal = function()
  minion_heal.casting, minion_heal.refuse_streak = false, 0
  minion_heal.sweep, minion_heal.blocked, minion_heal.last = {}, {}, nil
  minion_heal.self_hp_blocked, minion_heal.self_stam_blocked = false, false
  minion_heal.token = minion_heal.token + 1   -- kill any in-flight timeout
end

-- Pick the most-hurt skeletal minion still below its ready target (skipping any keyword we gave up on).
local function most_hurt_spell_minion()
  local best, best_frac
  for _, m in ipairs(state.group or {}) do
    if not is_self_row(m) and minion_needs_spell_heal(m.name)
       and pct(m.hp, m.maxhp) < minion_ready_target(m)
       and not minion_heal.blocked[minion_target_word(m.name)] then
      local f = pct(m.hp, m.maxhp)
      if not best_frac or f < best_frac then best, best_frac = m, f end
    end
  end
  return best, best_frac
end

-- Count group members sharing a target keyword (so ordinals 1..K line up with the room's N.keyword).
local function keyword_count(word)
  local n = 0
  for _, m in ipairs(state.group or {}) do
    if minion_target_word(m.name) == word then n = n + 1 end
  end
  return n
end

-- Fire the 3s reply-backstop shared by every recovery cast: if no reply line arrives (silent failure),
-- clear the casting flag and try the next cast. Returns the token so a real reply can invalidate it.
local function arm_cast_backstop()
  local token = minion_heal.token + 1
  minion_heal.token = token
  after(3, function() if minion_heal.token == token then minion_heal.casting = false; try_cast_heal() end end)
end

local try_self_cast   -- fwd decl: try_cast_heal falls through to it when no minion needs a heal

-- Try to cast one heal at the most-hurt skeletal minion. No-op when not recovering, a cast is already
-- out, casting is blocked (busy action / asleep), or nothing needs healing. When no minion needs a heal
-- it falls through to try_self_cast (spend surplus mana on your own vitals). Exposed via _AA_TEST.
local function try_cast_heal()
  if not state.recover or minion_heal.casting then return end
  if (state.action or 0) >= 50 then return end          -- a busy action prevents spellcasting
  if state.position == "sleeping" then return end        -- can't cast asleep (posture logic avoids this)
  -- Single-stat recovery (recover hp/stamina) is player-only — it never heals minions; skip straight to
  -- the self-cast. Full recovery (stat==nil) heals minions first, then falls through to self-casts.
  local m, f
  if not (recovery and recovery.stat) then m, f = most_hurt_spell_minion() end
  if not m then try_self_cast(); return end
  local word = minion_target_word(m.name)
  local K = keyword_count(word)
  local target = word
  local ord
  if K > 1 then
    ord = minion_heal.sweep[word] or 1
    if ord > K then ord = 1 end
    target = ord .. "." .. word
  end
  local spell = (f < BOLSTER_BELOW) and "bolster" or "soothe"
  minion_heal.last = { word = word, ord = ord, K = K, kind = "minion" }
  minion_heal.casting = true
  send("c " .. spell .. " " .. target)
  arm_cast_backstop()
end

-- Spend surplus mana on YOUR own lagging vitals — one cast, paced like the minion driver. hp is tried
-- before stamina (survivability first). Each stat is gated by cast_beats_waiting (regen vs mana cost),
-- and a stat we've given up on this recovery (self_*_blocked, set on a refuse) is skipped. Self-heals
-- need your name; refresh is self by default and can't be cast in combat (recovery isn't, but guard).
try_self_cast = function()
  if not self_cast_wanted() then return end
  local frac = (recovery and recovery.pct) or READY_PCT
  local st   = recovery and recovery.stat
  local r    = state.regen
  -- self HP via bolster/soothe (needs your name)
  if (st == nil or st == "hp") and not minion_heal.self_hp_blocked and state.name then
    local hpf = pct(state.hp, state.maxhp)
    if hpf < frac and cast_beats_waiting(state.hp, state.maxhp, r and r.hp, HEAL_COST) then
      local spell = (hpf < BOLSTER_BELOW) and "bolster" or "soothe"
      minion_heal.last = { kind = "self_hp" }
      minion_heal.casting = true
      send("c " .. spell .. " " .. state.name)
      arm_cast_backstop()
      return
    end
  end
  -- self stamina via refresh (self-target; never in/at combat)
  if (st == nil or st == "stam") and not minion_heal.self_stam_blocked and not engaged() then
    local spf = pct(state.stam, state.maxstam)
    if spf < frac and cast_beats_waiting(state.stam, state.maxstam, r and r.move, REFRESH_COST) then
      minion_heal.last = { kind = "self_stam" }
      minion_heal.casting = true
      send("c refresh")
      arm_cast_backstop()
      return
    end
  end
end

-- Settle the outstanding cast on one of the game's reply lines, then decide the next move.
--   ok           -> healed; wait for the refreshed roster to choose the next target
--   fail         -> spell fizzled; retry the same target immediately
--   full/notgt   -> this slot is topped (or wrong target); advance the sweep and try the next ordinal
local MINION_REFUSE_CAP = 3   -- consecutive refuses per keyword beyond K before we give up on it
local function minion_cast_settled(kind)
  if not minion_heal.casting then return end
  minion_heal.casting = false
  minion_heal.token = minion_heal.token + 1     -- a reply beat the timeout; invalidate it
  local last = minion_heal.last
  -- Self-cast (refresh / bolster / soothe on yourself): no ordinal sweep. ok/fail just re-drive; a refuse
  -- ("don't need that much healing" / "must use your name") means this vital won't take the spell right
  -- now, so stop trying it this recovery (the 3s backstop + fresh prompts still re-evaluate next tick).
  if last and last.kind and last.kind ~= "minion" then
    if kind == "ok" then minion_heal.refuse_streak = 0
    elseif kind == "fail" then -- fizzle → try again next evaluation
    else
      if last.kind == "self_hp" then minion_heal.self_hp_blocked = true
      elseif last.kind == "self_stam" then minion_heal.self_stam_blocked = true end
    end
    try_cast_heal()
    return
  end
  if kind == "ok" then
    minion_heal.refuse_streak = 0
    return   -- next kxwt_group_end drives the following cast (roster reflects the new HP by then)
  elseif kind == "fail" then
    try_cast_heal()   -- unchanged roster -> same target; just retry
    return
  end
  -- full / notgt: advance the sweep past this ordinal.
  if last and (last.K or 1) > 1 then
    minion_heal.sweep[last.word] = ((last.ord or 1) % last.K) + 1
  end
  minion_heal.refuse_streak = minion_heal.refuse_streak + 1
  if last and minion_heal.refuse_streak > (last.K or 1) + MINION_REFUSE_CAP then
    -- Swept every ordinal and still can't land a heal (roster says hurt but every cast refuses) —
    -- give up on this keyword for the rest of this recovery so we don't loop forever.
    if last.word then
      minion_heal.blocked[last.word] = true
      echo("\27[33m[recover] can't seem to heal '" .. last.word .. "'; skipping it.\27[0m")
    end
    minion_heal.refuse_streak = 0
  end
  try_cast_heal()
end

-- (Re)start the driver — called when a recovery begins and on every fresh group roster.
heal_minions_kick = function() try_cast_heal() end

-- Exposed for the test harness (Scripts/tests/recover_spec.lua, promise_spec.lua, minion_heal_spec.lua).
_AA_TEST = { ready = ready, pct = pct, READY_PCT = READY_PCT,
             stat_ready = stat_ready, one_stat_ready = one_stat_ready, STAT_ALIASES = STAT_ALIASES,
             choose_recovery_position = choose_recovery_position, recovery_depth = recovery_depth,
             recovery = recovery, end_recovery = end_recovery,
             maybe_complete_recovery = maybe_complete_recovery,
             minion_needs_spell_heal = minion_needs_spell_heal, minion_target_word = minion_target_word,
             minions_pending_spell_heal = minions_pending_spell_heal, all_minions_ready = all_minions_ready,
             minion_heal = minion_heal, try_cast_heal = try_cast_heal,
             minion_cast_settled = minion_cast_settled, reset_minion_heal = reset_minion_heal,
             reset_posture = reset_posture,
             ticks_to_target = ticks_to_target, cast_beats_waiting = cast_beats_waiting,
             self_cast_wanted = self_cast_wanted, try_self_cast = try_self_cast }

-- KXWT handshake: enable the protocol, hide the machinery lines.
trigger([[^kxwt_supported$]], function() send("set kxwt") end)
gag([[^kxwt_]])

-- Ring buffer of the last N gagged kxwt_ lines. Triggers fire even on gagged lines, so this
-- catch-all records them all so kxwt.dump([n]) can show the machinery that's normally hidden.
local kxwt_ring, KXWT_RING_MAX = {}, 300
trigger([[^kxwt_]], function(line)
  kxwt_ring[#kxwt_ring + 1] = line
  if #kxwt_ring > KXWT_RING_MAX then table.remove(kxwt_ring, 1) end
end)

-- The `kxwt` protocol-inspection surface: a documented, first-class table (Phase-2 migration off the
-- old `command("kxwt", …)` string parser). kxwt.dump([n]) shows the last n captured kxwt_ lines;
-- kxwt.corpse(...) drives the corpse-automation extension. The table is *callable* so the legacy typed
-- `#kxwt dump 5` (rewritten by the host to `kxwt("dump 5")`) still dispatches to the right member.
kxwt = {}

function kxwt.dump(n)
  n = tonumber(n) or 15
  if n < 1 then n = 15 end
  if #kxwt_ring == 0 then echo("[kxwt] no kxwt lines captured yet"); return end
  local first = math.max(1, #kxwt_ring - n + 1)
  echo(string.format("[kxwt] last %d of %d captured kxwt lines:", #kxwt_ring - first + 1, #kxwt_ring))
  for i = first, #kxwt_ring do echo("  " .. kxwt_ring[i]) end
end

-- kxwt.corpse(['on'|'off'|'status']) — toggle/report the after-kill corpse automation (see corpse_command,
-- defined further down; it's only called at runtime, so the later definition is fine).
function kxwt.corpse(mode) return corpse_command("corpse", mode or "") end

doc(kxwt.dump, { name = "kxwt.dump", sig = "kxwt.dump([n])", group = "protocol",
  text = "Show the last n (default 15) captured kxwt_ protocol lines — the machinery normally hidden from the display." })
doc(kxwt.corpse, { name = "kxwt.corpse", sig = "kxwt.corpse(['on'|'off'|'status'])", group = "protocol",
  text = "Control the after-kill corpse automation (harvest teeth/spellcomps; bsac+sac only the EMPTY corpses, leave any holding loot intact — no looting). No arg reports status." })

-- Callable table: forward a legacy subcommand string to the right member.
setmetatable(kxwt, { __call = function(_, args)
  args = (args or ""):match("^%s*(.-)%s*$")
  local verb = (args:match("^%S*") or ""):lower()
  local rest = args:match("^%S*%s+(.*)$") or ""
  if verb == "" or verb == "dump" or verb:match("^%d+$") then
    kxwt.dump(tonumber(rest) or tonumber(verb))
  elseif verb == "corpse" then
    kxwt.corpse(rest)
  else
    echo("[kxwt] commands: kxwt.dump([n]) | kxwt.corpse('on'|'off'|'status')")
  end
end })

-- Character / progress
trigger([[^kxwt_myname (.+)$]],   function(_, n) state.name = n end)
trigger([[^kxwt_gold (-?\d+)]],   function(_, g) state.gold = tonumber(g) end)
-- kxwt_exp is your unspent EXPERIENCE POOL; kxwt_expcap is the most you can earn from a SINGLE KILL
-- (a static-ish ceiling), NOT experience-to-level. The exp needed to level isn't a kxwt field — it only
-- appears in the `level`/`score` table, so we scrape that below.
trigger([[^kxwt_exp (-?\d+)]],    function(_, e) state.exp = tonumber(e) end)
trigger([[^kxwt_expcap (-?\d+)]], function(_, e) state.expcap = tonumber(e) end)

-- Per-class level costs, scraped from the `level`/`score` table. Rows look like:
--   "Mage          8                27000   (100%)   <- You can level!"
-- i.e. <Class> <current level> [micro] <exp cost to next level> (<percent>%). The header resets the
-- set so a fresh table clears stale classes. The HUD combines this (cached) with the LIVE exp pool to
-- show how much experience remains to level your cheapest class. Costs go stale after you level until
-- you run `level`/`score` again — which you do at a trainer anyway, so it refreshes when it matters.
state.classes = state.classes or {}

-- Persist the scraped class costs so the HUD's "exp to level" survives a relaunch without you re-running
-- `level`. They go stale after you actually level (until you run `level` again, which re-scrapes), but a
-- starting point beats nothing. Small dedicated file — kept out of AIPilot's map save.
local CLASSES_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/classes.lua"
local function save_classes()
  local f = io.open(CLASSES_FILE, "w")
  if not f then return end
  local parts = {}
  for name, c in pairs(state.classes) do
    parts[#parts + 1] = string.format("[%q]={level=%d,cost=%d}", name, c.level or 0, c.cost or 0)
  end
  f:write("return {" .. table.concat(parts, ",") .. "}")
  f:close()
end
-- Debounce: coalesce a whole table's rows into one write. Each new row cancels the pending save and
-- re-arms a fresh 2s timer, so exactly one write fires 2s after the LAST row (was a generation counter
-- that neutered stale timers; the cancellable timer id the host now returns does the same, directly).
local classes_save_timer
local function schedule_classes_save()
  if cancel and classes_save_timer then cancel(classes_save_timer) end
  classes_save_timer = after(2, save_classes)
end
-- Load once at startup (not on a live pilot.reload(), where state already holds the fresh table).
if not next(state.classes) then
  local chunk = loadfile(CLASSES_FILE)
  if chunk then local ok, t = pcall(chunk); if ok and type(t) == "table" then state.classes = t end end
end

trigger([[^Class +Level +.*Exp Cost]], function() state.classes = {} end)
-- Row: "<Class>  <level>  [micro]  <exp cost>  ( <pct>%)". The percent is space-padded for alignment
-- (e.g. "( 92%)"), so allow spaces after the "(" — matching only "(100%)" dropped every class you can't
-- yet level, which was the whole point of the widget.
trigger([[^(Mage|Cleric|Thief|Warrior|Necromancer|Druid) +(\d+) +.*?(\d+) +\( *\d+%\)]],
  function(_, cls, lvl, cost)
    state.classes[cls] = { level = tonumber(lvl), cost = tonumber(cost) }
    schedule_classes_save()
  end)

-- Prompt: current/max for hp, mana, stamina. May complete a recovery.
trigger([[^kxwt_prompt (\d+) (\d+) (\d+) (\d+) (\d+) (\d+)]], function(_, chp, mhp, cm, mm, cs, ms)
  state.hp, state.maxhp = tonumber(chp), tonumber(mhp)
  state.mana, state.maxmana = tonumber(cm), tonumber(mm)
  state.stam, state.maxstam = tonumber(cs), tonumber(ms)
  maybe_complete_recovery()
end)

-- Position. Starting a recovery sits/sleeps as appropriate.
trigger([[^kxwt_position (.+)$]], function(_, p)
  local changed = (state.position ~= p)
  state.position = p
  -- If we're recovering but got knocked back to a non-recovery posture (stood up, kicked awake), re-issue.
  if state.recover and recovery_depth(p) == 0 then choose_recovery_position() end
  -- Regen rates are per-posture — refresh them (gagged) so the cast-vs-wait decision uses the right numbers.
  if state.recover and changed and (not state.regen or state.regen.position ~= p) then query_regen() end
end)

-- Combat. -1 = not fighting; otherwise "<pct> <gender> <name>".
trigger([[^kxwt_fighting -1$]], function()
  state.fighting, state.fight_name, state.fight_pct = false, nil, nil
end)
trigger([[^kxwt_fighting (\d+) \S+ (.+)$]], function(_, p, name)
  state.fighting, state.fight_pct, state.fight_name = true, tonumber(p), name
  end_recovery(false, "combat started")           -- a fight cancels (and rejects) any recovery
end)

-- Update the current room from an rvnum. Ends recovery ONLY on a REAL move: the server re-sends rvnum on
-- a plain `look` (same id + coords), and a look mid-rest must not abort the recovery. Pure + exposed via
-- _AA_TEST so the move-vs-look decision is unit-tested (the trigger regex itself runs in Swift).
local function note_room(nid, nx, ny, nz, np)
  local oc = state.room_coord
  local moved = (state.room_id ~= nid)
      or not oc or oc[1] ~= nx or oc[2] ~= ny or oc[3] ~= nz or oc[4] ~= np
  state.room_id = nid
  state.room_coord = { nx, ny, nz, np }
  if moved then end_recovery(false, "moved") end   -- a real move cancels (and rejects) any recovery
end

-- Room. rvnum carries id + (x y z plane); rshort the name; area the zone.
trigger([[^kxwt_rvnum (-?\d+) -?\d+ -?\d+ (-?\d+) (-?\d+) (-?\d+) (\d+)]], function(_, vnum, x, y, z, plane)
  note_room(tonumber(vnum), tonumber(x), tonumber(y), tonumber(z), tonumber(plane))
end)
if _AA_TEST then _AA_TEST.note_room = note_room end
trigger([[^kxwt_rshort (.+)$]], function(_, n) state.room_name = n end)

-- Exits are NOT a kxwt field — they print as a plain "[Exits: east west ]" line at the end of the
-- room description. Parse the direction words into a set the HUD compass reads. (ANSI colour codes
-- are stripped upstream before triggers match, so the ^-anchor is safe even for the coloured
-- auto-look form emitted when moving.) Level-1 long string [=[ ]=] so the pattern's own ] doesn't
-- close it.
trigger([=[^\[Exits: (.*?)\]]=], function(_, list)
  local set = {}
  for dir in (list or ""):gmatch("%a+") do set[dir:lower()] = true end
  state.exits = set
end)
trigger([[^kxwt_area \d+ (.+)$]], function(_, a) state.area = a end)
trigger([[^kxwt_terrain (\d+)]], function(_, t) state.terrain = tonumber(t) end)

-- Walk direction (numeric code -> name), used by the map.
local WALK = { ["0"]="north", ["1"]="east", ["2"]="south", ["3"]="west", ["4"]="northeast",
  ["5"]="southeast", ["6"]="southwest", ["7"]="northwest", ["20"]="up", ["30"]="down" }
trigger([[^kxwt_walkdir (\d+)]], function(_, d) state.walkdir = WALK[d] end)

-- Spells up/down. Losing a spell while sleeping with mana to spare drops to resting.
trigger([[^kxwt_spellup (.+)$]], function(_, s) state.spells[s] = true end)
trigger([[^kxwt_spelldown (.+)$]], function(_, s)
  state.spells[s] = nil
  if state.recover and state.position == "sleeping" and pct(state.mana, state.maxmana) > 0.3 then
    send("rest"); state.position = "sitting"
  end
end)

-- Group roster. kxwt streams the party (you + pets/groupmates) as a block bracketed by
-- kxwt_group_start .. kxwt_group_end; each member line is "chp mhp cm mm cs ms <flags> <name>".
-- Accumulate between start/end so a half-sent block never renders partial data.
local group_capturing, group_buf = false, {}
trigger([[^kxwt_group_start$]], function() group_capturing = true; group_buf = {} end)
trigger([[^kxwt_group (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\S+) (.+)$]],
  function(_, chp, mhp, cm, mm, cs, ms, flags, name)
    if not group_capturing then return end
    group_buf[#group_buf + 1] = {
      hp = tonumber(chp), maxhp = tonumber(mhp),
      mana = tonumber(cm), maxmana = tonumber(mm),
      stam = tonumber(cs), maxstam = tonumber(ms),
      flags = flags, name = name,
    }
  end)
trigger([[^kxwt_group_end$]], function()
  if group_capturing then state.group = group_buf end
  group_capturing = false
  -- Fresh roster: if we're recovering, this is the cue to (re)pick the next minion to heal, and — since
  -- minion HP only changes here (not on the player prompt) — to check whether recovery is now done.
  if state.recover then heal_minions_kick(); maybe_complete_recovery() end
end)

-- Recovery-cast pacing: settle the outstanding cast on the game's own reply lines (see the recovery
-- block above). Anchored so another player's speech can't spoof them. The construct wording ("repair the
-- damage to X's body") is minion-only; the "feel ..." lines are self-casts; fail/refuse route by
-- last.kind inside minion_cast_settled (bolster/soothe are shared between self and minions).
trigger([[^You repair the damage to .+'s body\.$]], function() minion_cast_settled("ok") end)
trigger([[^You feel less tired\.$]], function() minion_cast_settled("ok") end)   -- refresh, self
trigger([[^You feel a little better\.$]], function() minion_cast_settled("ok") end)   -- soothe, self
trigger([[^You will your injuries to heal and your soul to take courage\.$]],        -- bolster, self
  function() minion_cast_settled("ok") end)
trigger([[^You fail to cast the spell '(soothe wounds|bolster|refresh)'\.$]], function() minion_cast_settled("fail") end)
trigger([[^.+ doesn't need that much healing right now\.$]], function() minion_cast_settled("full") end)
trigger([[^If you really want to cast that on yourself, you must use your name\.$]],
  function() minion_cast_settled("notgt") end)

-- `show regen` — regen per tick at the CURRENT posture, drives the recovery cast-vs-wait decision.
-- Two forms: with the "feel sharp" prefix (the sharp buff, from sleeping a while → faster regen) and
-- without. We gag ONLY our own auto-query (query_regen sets regen_query_pending); a manual `show regen`
-- the player typed still prints.
trigger([[^You (feel sharp, and )?currently gain (\d+) hitpoints, (\d+) mana, and (\d+) movement while (\w+)\.$]],
  function(_, sharp, hp, mana, move, posn)
    state.regen = { hp = tonumber(hp), mana = tonumber(mana), move = tonumber(move), position = posn }
    state.sharp = (sharp ~= nil and sharp ~= "")
    if regen_query_pending then regen_query_pending = false; return false end   -- gag our auto-query
  end)
-- Sharp up/down. Sharp changes every regen rate, so re-query while recovering to keep state.regen fresh.
trigger([[^You find yourself feeling sharp and ready to take on anything!$]], function()
  state.sharp = true; if state.recover then query_regen() end
end)
trigger([[^You no longer feel sharp and at your best\.$]], function()
  state.sharp = false; if state.recover then query_regen() end
end)

-- Environment: sky/time/weather. kxwt_time is "<mud-minutes> <daypart> <clock> <am/pm>";
-- kxwt_precipitation is a 0-100ish intensity; kxwt_sky is "<outdoors> <sky-visible> <overcast>" (1/0).
trigger([[^kxwt_time (\d+) (\S+) (\S+) (\S+)$]], function(_, _mins, part, clock, ampm)
  state.daypart = part; state.clock = clock .. " " .. ampm
end)
trigger([[^kxwt_precipitation (\d+)]], function(_, p) state.precip = tonumber(p) end)
trigger([[^kxwt_sky (\d+) (\d+) (\d+)]], function(_, o, v, c)
  state.outdoors = tonumber(o) == 1; state.sky_visible = tonumber(v) == 1; state.overcast = tonumber(c) == 1
end)

-- Current action code (butchering, turning, etc.). Per 'help kxwt', values >= 50 PREVENT spellcasting,
-- so the HUD can warn casters. Moving cancels most actions, so clear it on a room change as a safety.
trigger([[^kxwt_action (\d+)]], function(_, a) state.action = tonumber(a) end)
trigger([[^kxwt_rvnum ]], function() state.action = 0 end)

-- Transient alerts: level-ups / quest completions (kxwt_event) and deaths of a player (pdeath), your
-- own minion (ydeath), or a group member's minion (gdeath). kxwt_ lines are gagged, so we echo a short
-- coloured banner into the output instead. (mob deaths, kxwt_mdeath, drive corpse automation below.)
trigger([[^kxwt_event (\S+) ?(.*)$]], function(_, kw, data)
  echo("\27[1;33m★ " .. kw .. (data ~= "" and (": " .. data) or "") .. "\27[0m")
end)
trigger([[^kxwt_pdeath (.+)$]], function(_, n) echo("\27[1;31m☠ " .. n .. " has DIED!\27[0m") end)
trigger([[^kxwt_ydeath (.+)$]], function(_, n) echo("\27[31m☠ your " .. n .. " has died.\27[0m") end)
trigger([[^kxwt_gdeath (.+)$]], function(_, n) echo("\27[31m☠ " .. n .. " (a group minion) has died.\27[0m") end)

-- Music channels (kxwt_music). We only receive track NAMES per channel (e.g. the "music" and
-- "terrain" channels), not audio. We know where the AlterAeon dclient soundpack lives, so we build the
-- full path and hand it to the generic Swift player (which stays game-agnostic — it just plays a file).
-- The track names already carry their subdir (soundtrack/…, weather/…), so SOUNDPACK is the ogg_v1 root.
-- We also remember each channel's track so the HUD can show a "♪" mood indicator. `if music then`
-- guards an un-relaunched binary that lacks the new builtin.
local SOUNDPACK = (os.getenv("HOME") or "") .. "/Library/AlterAeon/soundpack/ogg_v1/"
state.music = state.music or {}
trigger([[^kxwt_music channel_play (\S+) (\S+)]], function(_, ch, tr)
  state.music[ch] = tr
  if music then music.play(ch, SOUNDPACK .. tr .. ".ogg") end
end)
trigger([[^kxwt_music channel_stop (\S+)]], function(_, ch)
  state.music[ch] = nil
  if music then music.stop(ch) end
end)

-- Audio volume: a MASTER plus three categories — music (layered player), sfx (MSP sound effects), and
-- voice (TTS). The effective level pushed to each host service = round(master% × category%), so
-- `volume('0')` zeroes the master → all three effective 0 → full silence, while `volume('voice 0')`
-- mutes only TTS. Levels persist across reload/reconnect in state.volumes (migrated from the old
-- single state.music_volume). The `if …` guards tolerate an un-relaunched binary lacking a new builtin.
-- music defaults to 35% (deliberately quiet, matching Swift's own default); everything else to 100%.
local VOLUME_DEFAULTS = { master = 100, music = 35, sfx = 100, voice = 100 }
state.volumes = state.volumes or {}
for k, v in pairs(VOLUME_DEFAULTS) do
  if state.volumes[k] == nil then state.volumes[k] = v end
end
-- Migrate the legacy single music level into the new table (once).
if state.music_volume ~= nil then
  state.volumes.music = state.music_volume
  state.music_volume = nil
end

-- Accepted category words (aliases fold onto the three canonical keys). `master` is accepted too so
-- `volume('master 80')` works alongside the bare-number shorthand.
local VOLUME_ALIASES = {
  master = "master", music = "music",
  sfx = "sfx", effects = "sfx", effect = "sfx", msp = "sfx",
  voice = "voice", speech = "voice", tts = "voice", say = "voice",
}

-- Effective 0-100 level for a category = master% × category%, rounded.
local function volume_effective(cat)
  return math.floor((state.volumes.master / 100) * (state.volumes[cat] / 100) * 100 + 0.5)
end

-- Recompute all three effective levels and push them to the host services. Returns them for callers/tests.
local function volume_apply()
  local em, es, ev = volume_effective("music"), volume_effective("sfx"), volume_effective("voice")
  if music and music.volume then music.volume(em) end
  if msp_volume then msp_volume(es) end
  if speech_volume then speech_volume(ev) end
  return em, es, ev
end

local function volume_readout()
  echo(string.format("[volume] master %d%%  |  music %d%%->%d%%  sfx %d%%->%d%%  voice %d%%->%d%%",
    state.volumes.master,
    state.volumes.music, volume_effective("music"),
    state.volumes.sfx, volume_effective("sfx"),
    state.volumes.voice, volume_effective("voice")))
  echo("[volume] volume('0-100')=master; volume('music|sfx|voice <0-100>')=category; volume()=this readout")
end

-- First-class documented function (migrated off command("volume", …)); the legacy typed
-- `#volume music 40` still rewrites to volume("music 40") and lands here unchanged.
function volume(args) return volume_command(args) end
doc(volume, { name = "volume", sig = "volume(['<0-100>' | '<music|sfx|voice> <0-100>'])", group = "audio",
  text = "Master + per-category audio volume (0-100). volume('0') mutes EVERYTHING (master); volume('50') sets master; volume('music 40'), volume('sfx 0'), volume('voice 0') set a category (aliases: effects/msp=sfx, speech/tts=voice); volume() prints a readout. Effective = master% x category%.",
  example = "volume('0')  -- silence all; volume('voice 0')  -- mute only TTS" })

function volume_command(args)
  -- Coerce to string first: the typed bridge (`#volume music 40`) always passes a string, but a direct
  -- Lua call can pass a NUMBER — volume(0) — and 0 is truthy, so `(args or "")` kept the number and the
  -- `:match` below indexed a number value. tostring() makes volume(0) and volume('0') behave alike.
  args = tostring(args or ""):match("^%s*(.-)%s*$")
  if args == "" then volume_readout(); return end
  -- bare number => MASTER
  if args:match("^%d+$") then
    state.volumes.master = math.max(0, math.min(100, tonumber(args)))
    volume_apply()
    echo(string.format("[volume] master set to %d%%", state.volumes.master))
    return
  end
  local word = (args:match("^(%S+)") or ""):lower()
  local rest = args:match("^%S+%s+(.*)$") or ""
  local cat = VOLUME_ALIASES[word]
  if not cat then
    echo("[volume] usage: volume('0-100') sets master; volume('music|sfx|voice <0-100>') sets a category")
    return
  end
  local num = rest:match("^(%d+)")
  if not num then volume_readout(); return end
  state.volumes[cat] = math.max(0, math.min(100, tonumber(num)))
  volume_apply()
  if cat == "master" then
    echo(string.format("[volume] master set to %d%%", state.volumes.master))
  else
    echo(string.format("[volume] %s set to %d%% (effective %d%%)", cat, state.volumes[cat], volume_effective(cat)))
  end
end

-- Push the persisted levels to the services once at load (so a reload re-applies them).
volume_apply()

_AA_TEST.volume_effective = volume_effective
_AA_TEST.volume_apply = volume_apply
_AA_TEST.volume_command = volume_command
_AA_TEST.VOLUME_DEFAULTS = VOLUME_DEFAULTS

-- Timed self-effects (spell/skill durations), e.g. "kxwt_spst mana shield, two hours, 20 minutes".
-- kxwt_spst is sent once per tick per active effect and has NO expiry/down signal, so this table can
-- only accumulate — a dropped buff is never removed. It is therefore NOT shown by the HUD (the live
-- `spells` widget, driven by kxwt_spellup/spelldown, is the authoritative "what's up on you" display);
-- we still capture the duration text here for scripting/AI use, and clear it on reconnect (on_connect).
state.effects = state.effects or {}
trigger([[^kxwt_spst (.+)$]], function(_, s)
  local name, rest = s:match("^(.-),%s*(.+)$")
  if name then state.effects[name] = rest else state.effects[s] = "" end
end)

-- Session-scoped buff state must not survive a reconnect. The Lua globals (state) persist across a
-- disconnect and across pilot.reload(), so on a fresh connection the previous session's spells and
-- timed effects would linger until new kxwt lines happen to overwrite them — and neither kxwt_spelldown
-- nor kxwt_spst carries a "reset" event to clear the stragglers. So wipe them here; the server re-pushes
-- the current spellups / spst on connect and they repopulate from scratch. (Music is left alone: it is
-- persistent server-side and isn't necessarily re-pushed on a brief reconnect.)
function on_connect()
  state.spells = {}
  state.effects = {}
  state.opponents = {}
end

-- ===== Inferred multi-opponent tracking =========================================================
-- The kxwt protocol reports exactly ONE health bar — kxwt_fighting, the CURRENT target (or -1 when
-- combat ends); the raw logs show one line per update, no multi-mob enumeration. To show bars for the
-- OTHER mobs you're engaged with, we INFER their health from the textual condition ladder AlterAeon
-- prints after hits ("X is near death!", "X has quite a few wounds.") — see 'help injury injuries damage
-- descriptions'. These are ESTIMATES (flagged as such in the HUD). state.opponents: name ->
-- { pct = 0..100, exact = <bool>, t = <os.time last seen> }. The current target also lands here (exact),
-- so switching targets leaves its last bar behind as an "other".
state.opponents = state.opponents or {}

-- Condition phrase -> representative % (band midpoint of the 8-rung injury ladder, plus the even-lower
-- combat "near death"). Substring match, case-insensitive; ordered lowest-first, and longer phrases that
-- contain a shorter one resolve to their own rung because we return the FIRST hit and the specific
-- phrases are listed ahead of any bare word that could shadow them.
local CONDITION_LADDER = {
  { "near death",                 3 },
  { "mortally wounded",           8 },
  { "big nasty wounds",          42 },   -- before any bare "wounds"; distinct band
  { "quite a few wounds",        55 },
  { "small wounds and bruises",  68 },
  { "a few scratches",           82 },
  { "pretty hurt",               28 },
  { "awful",                     15 },
  { "excellent",                 95 },
}
-- Estimated health % for a line of game text carrying a condition phrase, or nil if it carries none.
local function condition_pct(text)
  local low = (text or ""):lower()
  for _, e in ipairs(CONDITION_LADDER) do
    if low:find(e[1], 1, true) then return e[2] end
  end
  return nil
end

-- Parse a condition-report line into (mob-name, estimated-%), or nil. The subject is the noun phrase
-- before the "is/has/looks" clause; we reject yourself and your own minions ("You…"/"Your…") and reject
-- over-long or multi-sentence subjects (a stray phrase match inside a longer combat line).
local function parse_opponent(line)
  local pct = condition_pct(line)
  if not pct then return nil end
  local subj = line:match("^(.-)%s+[Ii]s%s") or line:match("^(.-)%s+[Hh]as%s")
             or line:match("^(.-)%s+[Ll]ooks?%s")
  if not subj then return nil end
  subj = subj:gsub("^%s+", ""):gsub("%s+$", "")
  if subj == "" or #subj > 40 or subj:find("[%.!%?]") then return nil end
  local lw = subj:lower()
  if lw:find("^your?%f[%A]") then return nil end   -- "you"/"your <minion>"
  return subj, pct
end

-- Record (or refresh) an opponent's reading. Keyed by LOWERCASED name (the wire mixes "An orc bachelor"
-- and "an orc bachelor" for the same mob); the display name is the first-seen original. `exact` is true
-- only for the kxwt_fighting target. A nil pct (a melee sighting with no condition phrase) refreshes the
-- timestamp but never clobbers a known health estimate.
local function opponent_note(tbl, name, pct, now, exact)
  if not name then return end
  local key = name:lower()
  local e = tbl[key]
  if e then
    e.t = now
    if pct ~= nil then e.pct, e.exact = pct, exact == true end
  else
    tbl[key] = { display = name, pct = pct, exact = exact == true, t = now }
  end
end

-- Live opponents as an array, sorted most-recently-seen first (name breaks ties deterministically),
-- excluding `exclude` (the current target, shown by its own exact bar; compared case-insensitively) and
-- dropping entries not seen within `ttl` seconds. Prunes the expired entries from `tbl` in place.
local function opponents_active(tbl, now, ttl, exclude)
  local exl = exclude and exclude:lower() or nil
  local out = {}
  for key, o in pairs(tbl or {}) do
    if now - (o.t or 0) > ttl then
      tbl[key] = nil
    elseif key ~= exl then
      out[#out + 1] = { name = o.display or key, pct = o.pct, est = not o.exact, t = o.t }
    end
  end
  table.sort(out, function(a, b)
    if a.t ~= b.t then return a.t > b.t end
    return a.name < b.name
  end)
  return out
end

local OPP_TTL = 30
-- Public: the HUD's inferred-opponent bars read this. Returns the pruned, sorted "other opponents" list
-- (excludes the current kxwt_fighting target) as { {name, pct, est}, ... }, newest-first.
function active_opponents(now)
  return opponents_active(state.opponents, now or os.time(), OPP_TTL, state.fight_name)
end
doc(active_opponents, { name = "active_opponents", sig = "active_opponents([now])", group = "combat",
  text = "Inferred list of the OTHER mobs you're fighting (not the current kxwt_fighting target), health estimated from the condition ladder. Returns an array of {name, pct, est} newest-first; prunes entries older than 30s." })

-- Is `name` you or one of your groupmates/minions (so a combat line about them is NOT an enemy)?
-- "you"/"You" (the melee lines' pronoun for yourself) counts, as does your kxwt_myname. Global (like
-- engaged/active_opponents) so other scripts — e.g. AutoFight's crowd detection — can classify names.
function is_ally(name)
  if not name then return false end
  local low = name:lower()
  if low == "you" then return true end
  if state.name and low == state.name:lower() then return true end   -- kxwt_myname
  for _, m in ipairs(state.group or {}) do if m.name:lower() == low then return true end end
  return false
end
doc(is_ally, { name = "is_ally", sig = "is_ally(name) -> bool", group = "combat",
  text = "True when `name` is you (incl. the \"you\" pronoun / your kxwt_myname) or a current group "
      .. "member/minion — i.e. a combat line about them is friendly, not an enemy sighting." })

-- ---- "engaged" (fighting without kxwt_fighting) ------------------------------------------------
-- PROVEN BY THE RAW LOGS: with `nocombat` (nomelee) toggled on, the server does NOT send kxwt_fighting
-- AT ALL during a fight — not per round, not even -1 — because you're not in the melee round. The fight
-- exists only as text: melee-round lines between your minions and the mob, the mob's attacks on you,
-- and the condition ladder. So we derive an ENGAGED state from those lines: any melee-round line
-- involving you or an ally refreshes `state.engaged_until`; it expires ENGAGE_TTL seconds after the
-- last one (rounds are ~2s apart), and is cleared eagerly on room change, kxwt_fighting -1, and when
-- the last known opponent dies (kxwt_mdeath) so post-kill looting isn't held up.
local ENGAGE_TTL = 10

-- The canonical melee damage-verb ladder, from 'help default damage strings' (both the flat and the
-- percentage-based combatmode sets), lowercased for matching.
local MELEE_VERBS = {
  annoys = true, scratches = true, hits = true, injures = true, wounds = true, mauls = true,
  decimates = true, devastates = true, maims = true, mutilates = true, dismembers = true,
  disembowels = true, massacres = true, obliterates = true, demolishes = true, destroys = true,
  annihilates = true, misses = true,
  -- percentage-mode edged/pointed + blunt variants
  nicks = true, cuts = true, gouges = true, gashes = true, lacerates = true, shreds = true,
  mangles = true, rends = true, thumps = true, mars = true, batters = true, thrashes = true,
  clobbers = true, smashes = true, pulverizes = true,
}

-- Parse a melee-round line into (attacker, target), or nil. Forms:
--   "<attacker>'s <skill> <verb> <target>."   (greedy attacker match so a name containing 's survives)
--   "Your <skill> <verb> <target>."           (your own melee swings)
-- The *** BIG DAMAGE *** decorations are stripped first. Lua patterns can't alternate on the verb set,
-- so after splitting off the attacker we SCAN the remaining words for the first damage verb; everything
-- before it is the skill (1..4 words) and everything after is the target.
local function parse_melee(line)
  local t = (line or ""):gsub("%*", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  local attacker, rest = t:match("^(.+)'s (.+)$")
  if not attacker then
    rest = t:match("^[Yy]our (.+)$")
    if rest then attacker = "you" end
  end
  if not rest then return nil end
  local body = rest:match("^(.-)[%.!]+$")          -- combat sends always end in . or !
  if not body then return nil end
  local before = 0
  for s, word in body:gmatch("()(%S+)") do
    if MELEE_VERBS[word:lower()] and before >= 1 and before <= 4 then
      local target = body:sub(s + #word + 1)
      if target ~= "" then return attacker, target end
    end
    before = before + 1
  end
  return nil
end

-- The enemy in an (attacker, target) melee pair: whichever side is NOT you/an ally. nil when the pair
-- doesn't involve your side at all (bystander mob-vs-mob), or when both sides are yours.
local function melee_enemy(attacker, target)
  local a_ally, t_ally = is_ally(attacker), is_ally(target)
  if a_ally and not t_ally then return target end
  if t_ally and not a_ally then return attacker end
  return nil
end

-- Are we engaged in a fight, kxwt-confirmed or text-inferred? THE combat predicate — HUD gating,
-- in_combat() and every pilot/equipment consumer sit on this.
function engaged(now)
  if state.fighting then return true end
  return (state.engaged_until or 0) > (now or os.time())
end
doc(engaged, { name = "engaged", sig = "engaged([now])", group = "combat",
  text = "True when you're in a fight: the kxwt_fighting target is live OR combat text (melee-round lines) was seen within the last ~10s. Covers nomelee fights, where the server sends NO kxwt_fighting at all." })

-- Auto-assist. When your minions (or you) are getting hit by an enemy but you're NOT in the melee round
-- yourself — engaged() is true from the combat text, yet state.fighting is false (no kxwt_fighting), the
-- "dimmed target" state — jump into the fight with `assist` so you (and AutoFight) actually engage. Fires
-- off the melee-round trigger (which has already identified the enemy and confirmed your side is in it),
-- debounced so the many rounds-per-second lines don't spam `assist`. Off via `autoassist off`.
local ASSIST_COOLDOWN = 3   -- seconds between assist attempts (retries if the first didn't pull you in)
local assist_at = 0
local function maybe_assist(now)
  if not state.auto_assist then return end
  if state.fighting then return end          -- already in the melee round → nothing to assist into
  now = now or os.time()
  if now < assist_at + ASSIST_COOLDOWN then return end
  assist_at = now
  send("assist")
end
-- kxwt_fighting -1 (combat ended) resets the debounce so the NEXT fight assists immediately.
_AA_TEST = _AA_TEST or {}
_AA_TEST.maybe_assist = maybe_assist
_AA_TEST.reset_assist = function() assist_at = 0 end

-- Feed the tracker. The current target's EXACT reading (kxwt_fighting), every melee-round line (names
-- the enemy and proves engagement), and every condition line while engaged update the table; combat
-- end / room change / mob death clear or remove entries. The condition trigger is gated on engaged()
-- so out-of-combat 'look' condition lines can't spawn phantom opponents.
trigger([[^kxwt_fighting (\d+) \S+ (.+)$]], function(_, p, name)
  opponent_note(state.opponents, name, tonumber(p), os.time(), true)
end)
trigger([[^kxwt_fighting -1$]], function()
  state.opponents = {}; state.engaged_until = nil
  assist_at = 0                      -- fight over → next fight may assist immediately
end)
-- Just YOU (not your minions): the melee lines' pronoun "you", or your kxwt_myname. Lets us tell "I'm in
-- this fight" from "my MINIONS are" — a mob brawling only with your pets shouldn't pin YOU in combat.
local function is_self(name)
  if not name then return false end
  local low = name:lower()
  return low == "you" or (state.name ~= nil and low == state.name:lower())
end
_AA_TEST.is_self = is_self
trigger([[\S+'s [a-z ]*(annoys|scratches|hits|injures|wounds|mauls|decimates|devastates|maims|mutilates|dismembers|disembowels|massacres|obliterates|demolishes|destroys|annihilates|misses|nicks|cuts|gouges|gashes|lacerates|shreds|mangles|rends|thumps|mars|batters|thrashes|clobbers|smashes|pulverizes) ]],
  function(line)
    local attacker, target = parse_melee(line)
    if not attacker then return end
    local enemy = melee_enemy(attacker, target)
    if not enemy then return end                       -- bystander fight; not ours
    local now = os.time()
    opponent_note(state.opponents, enemy, nil, now, false)   -- name sighting; keeps any known pct
    maybe_assist(now)                                  -- your side is fighting; jump in if you aren't
    -- Only YOU being in the melee opens the engaged window (which gates goto/explore/rest). A mob brawling
    -- only with your MINIONS keeps them busy but doesn't stop you moving — else `goto` refuses while your
    -- pets mop up adds and you're free to walk off. (If you then `assist`, kxwt_fighting/your own melee
    -- lines engage you for real.)
    if is_self(attacker) or is_self(target) then
      state.engaged_until = now + ENGAGE_TTL
      end_recovery(false, "combat started")           -- fights (kxwt-visible or not) cancel recovery
    end
  end)
trigger([[(near death|mortally wounded|awful|pretty hurt|nasty wounds|a few wounds|small wounds|few scratches|excellent)]],
  function(line)
    if not engaged() then return end
    local name, pct = parse_opponent(line)
    if name and not is_ally(name) then
      state.engaged_until = os.time() + ENGAGE_TTL
      opponent_note(state.opponents, name, pct, os.time(), false)
    end
  end)
-- ---- explicit targeting (the `target` command) --------------------------------------------------
-- There is NO kxwt target tag (the full documented tag vocabulary has nothing target-shaped;
-- kxwt_fighting is the only enemy tag and it's melee-gated) — but the game confirms targeting in TEXT.
-- Researched wordings, VERBATIM from human-traces:
--   "You keep a steady eye on a druidess."      <- `target <name>` acquisition (carries the NAME)
--   "You are already targeting him."            <- re-target, pronoun only (no name)
--   "You are targeting Fraxis Hammerhand."      <- passive report inside `score` output
-- Target-CLEARED wordings ('target noone') appear NOWHERE in the traces or help corpus — the forms
-- below ("You stop targeting …" / "You are no longer targeting …" / "You no longer have a target") are
-- best guesses, UNCONFIRMED LIVE; adjust here if the real send differs.
-- Classify a targeting line -> kind ("acquire"|"already"|"report"|"clear"), name-or-nil.
local function parse_target_line(line)
  local t = line or ""
  local name = t:match("^You keep a steady eye on (.+)%.$")
  if name then return "acquire", name end
  if t:match("^You are already targeting %a+%.$") then return "already", nil end
  name = t:match("^You are targeting (.+)%.$")
  if name then return "report", name end
  name = t:match("^You stop targeting (.+)%.$") or t:match("^You are no longer targeting (.+)%.$")
  if name then return "clear", name end
  if t:match("^You no longer have a target") then return "clear", nil end
  return nil
end

-- Acquisition ("steady eye") SEEDS the enemy name immediately — before any melee round or condition
-- line — and opens the engaged window, so a caster who targets and opens with a spell has a named
-- combat block up from the first cast. The pronoun form refreshes the window but carries no name
-- (never creates a nameless entry). The passive `score` report seeds the name only while already
-- engaged (score is routinely run at rest; a persistent target must not flash the combat HUD).
trigger([[^You keep a steady eye on .+\.$]], function(line)
  local _, name = parse_target_line(line)
  if not name or is_ally(name) then return end
  local now = os.time()
  state.engaged_until = now + ENGAGE_TTL
  opponent_note(state.opponents, name, nil, now, false)
end)
trigger([[^You are already targeting \w+\.$]], function(line)
  if parse_target_line(line) == "already" then state.engaged_until = os.time() + ENGAGE_TTL end
end)
trigger([[^You are targeting .+\.$]], function(line)
  local kind, name = parse_target_line(line)
  if kind == "report" and name and engaged() and not is_ally(name) then
    opponent_note(state.opponents, name, nil, os.time(), false)
  end
end)
-- Target cleared (UNCONFIRMED wordings — see note above): withdraw the seeded entry only when it has
-- no combat evidence yet (pct == nil, i.e. it exists purely because we targeted it); a mob with a
-- health reading is still fighting us regardless of our targeting choice. Never touches the window.
trigger([[^You (stop targeting .+|are no longer targeting .+|no longer have a target.*)$]], function(line)
  local kind, name = parse_target_line(line)
  if kind ~= "clear" or not name then return end
  local e = state.opponents[name:lower()]
  if e and e.pct == nil then state.opponents[name:lower()] = nil end
end)

trigger([[^kxwt_rvnum ]], function()                   -- room change abandons the engagement
  state.opponents = {}; state.engaged_until = nil
end)
trigger([[^kxwt_mdeath (.+)$]], function(_, name)      -- a mob died -> drop its bar immediately
  state.opponents[name:lower()] = nil
  -- Last opponent down and no kxwt melee target -> the fight is over; clear the engaged window NOW so
  -- corpse looting (gated on in_combat()) isn't stalled for the TTL tail.
  if not state.fighting and not next(state.opponents) then state.engaged_until = nil end
end)

_AA_TEST.condition_pct = condition_pct
_AA_TEST.parse_opponent = parse_opponent
_AA_TEST.opponent_note = opponent_note
_AA_TEST.opponents_active = opponents_active
_AA_TEST.parse_melee = parse_melee
_AA_TEST.melee_enemy = melee_enemy
_AA_TEST.is_ally = is_ally
_AA_TEST.ENGAGE_TTL = ENGAGE_TTL
_AA_TEST.parse_target_line = parse_target_line

-- ===== Authoritative spell membership from the `score`/affects block =============================
-- kxwt_spellup/spelldown keep state.spells live between sightings, but they only carry names and a
-- silently-expired spell can linger. The "You are affected by:" block (printed by `score`) lists EVERY
-- active spell, so whenever we see it we RECONCILE WHOLESALE — replace state.spells, not merge — which
-- drops the stragglers. MEMBERSHIP ONLY: we extract the spell NAME (and level, which is free in the same
-- row); the "<duration> remaining" middle is deliberately treated as an opaque blob and NOT parsed or
-- stored — no timing data is tracked. Values become { level = n }; the widget only needs the keys.
-- Parse one "Spell '<name>', <anything> remaining, level <n>" row -> { name, level } or nil.
local function parse_affect_row(line)
  local name, lvl = (line or ""):match("^Spell '(.-)', .- remaining, level (%d+)")
  if not name then return nil end
  return { name = name, level = tonumber(lvl) }
end

-- Build the wholesale-replacement spell set from a list of parsed affect rows.
local function affects_to_spells(rows)
  local fresh = {}
  for _, e in ipairs(rows or {}) do fresh[e.name] = { level = e.level } end
  return fresh
end

local affects_capturing, affects_buf = false, nil
trigger([[^You are affected by:]], function() affects_capturing = true; affects_buf = {} end)
trigger([[^Spell '.+', .+ remaining, level \d+]], function(line)
  if affects_capturing then
    local r = parse_affect_row(line)
    if r then affects_buf[#affects_buf + 1] = r end
  end
end)
trigger([[.*]], function(line)
  if not affects_capturing then return end
  if line:match("^Spell '") or line:match("^You are affected by") then return end   -- header / rows
  affects_capturing = false                                                          -- any other line ends it
  state.spells = affects_to_spells(affects_buf)                                       -- reconcile wholesale
end)

-- Authoritative per-class LEVELS from the score line "Your levels are:  Ma 12  Cl 6  Th 0 ...". These
-- refresh state.classes[<full name>].level (levels in the cached cost table go stale after you level),
-- which the HUD's next-level tie-break cross-checks. Cost is filled separately by the `level` scrape;
-- a level-only (cost-less) entry is simply ignored by next_level until its cost is known.
local LVL_ABBR = { Ma = "Mage", Cl = "Cleric", Th = "Thief", Wa = "Warrior", Nc = "Necromancer", Dr = "Druid" }
local function parse_levels(rest)
  local out = {}
  for ab, lv in (rest or ""):gmatch("(%a%a)%s+(%d+)") do
    if LVL_ABBR[ab] then out[LVL_ABBR[ab]] = tonumber(lv) end
  end
  return out
end
trigger([[^Your levels are: (.+)$]], function(_, rest)
  for full, lv in pairs(parse_levels(rest)) do
    state.classes[full] = state.classes[full] or {}
    state.classes[full].level = lv
  end
end)

_AA_TEST.parse_affect_row = parse_affect_row
_AA_TEST.affects_to_spells = affects_to_spells
_AA_TEST.parse_levels = parse_levels

-- ===== Known spells from the `spells` command ====================================================
-- The AI combat pilot must cast the character's REAL spells, not melee or hallucinate one it lacks. To
-- know which offensive spells the character actually HAS (and how strong each is), we parse the `spells`
-- listing into state.spells_known and cross-reference SPELL_DB — a static table of every game DAMAGE
-- spell (name -> mana + damage tier), harvested from the help corpus' per-spell pages (each carries a
-- "Damage: <tier>" line for offensive spells and none for buffs/heals — that Damage tier IS the
-- offensive signal). A known spell present in SPELL_DB is offensive; absent = a buff/utility spell.
local SPELL_DB = {
  ["ball lightning"] = { mana = 13, tier = "massive" },
  ["blaze"] = { mana = 5, tier = "moderate" },
  ["blizzard"] = { mana = 35, tier = "massive", area = true },
  ["blue dart"] = { mana = 4, tier = "low" },
  ["burning hands"] = { mana = 5, tier = "moderate" },
  ["call thunder"] = { mana = 15, tier = "massive" },
  ["chasten"] = { mana = 7, tier = "low" },
  ["chill touch"] = { mana = 5, tier = "low" },
  ["coffin"] = { mana = 51, tier = "massive" },
  ["coldfire"] = { mana = 6, tier = "minor" },
  ["color spray"] = { mana = 6, tier = "low" },
  ["condemnation"] = { mana = 34, tier = "high" },
  ["cone of cold"] = { mana = 16, tier = "high" },
  ["crystal spear"] = { mana = 12, tier = "high" },
  ["death and decay"] = { mana = 27, tier = "high", area = true },
  ["dust devil"] = { mana = 16, tier = "moderate" },
  ["earthquake"] = { mana = 19, tier = "moderate", area = true },
  ["field of the grasping dead"] = { mana = 35, tier = "low", area = true },
  ["fireball"] = { mana = 10, tier = "high" },
  ["firefield"] = { mana = 10, tier = "moderate", area = true },
  ["fireweb"] = { mana = 13, tier = "moderate" },
  ["fist of the earth"] = { mana = 14, tier = "moderate" },
  ["flamestrike"] = { mana = 15, tier = "moderate" },
  ["frost bite"] = { mana = 13, tier = "high" },
  ["frostflower"] = { mana = 4, tier = "moderate", area = true },
  ["fury of the heavens"] = { mana = 15, tier = "massive", area = true },
  ["gust of wind"] = { mana = 8, tier = "minor" },
  ["hailstone"] = { mana = 20, tier = "high" },
  ["harm"] = { mana = 21, tier = "high" },
  ["ice fog"] = { mana = 23, tier = "high", area = true },
  ["icebolt"] = { mana = 8, tier = "moderate" },
  ["inflict suffering"] = { mana = 13, tier = "moderate" },
  ["inflict wounds"] = { mana = 4, tier = "minor" },
  ["kaleidoscope"] = { mana = 16, tier = "high" },
  ["landslide"] = { mana = 39, tier = "massive" },
  ["lightning bolt"] = { mana = 9, tier = "moderate" },
  ["maelstrom"] = { mana = 40, tier = "massive", area = true },
  ["mage hand"] = { mana = 17, tier = "moderate" },
  ["magic missile"] = { mana = 2, tier = "minor" },
  ["noxious cloud"] = { mana = 12, tier = "moderate" },
  ["prism"] = { mana = 6, tier = "moderate" },
  ["radiant orbs"] = { mana = 7, tier = "minor" },
  ["riptide"] = { mana = 25, tier = "moderate" },
  ["rotting sphere"] = { mana = 27, tier = "moderate" },
  ["sacred touch"] = { mana = 15, tier = "massive" },
  ["sandstorm"] = { mana = 20, tier = "minor", area = true },
  ["scorch"] = { mana = 8, tier = "moderate" },
  ["shard storm"] = { mana = 18, tier = "high", area = true },
  ["shards"] = { mana = 4, tier = "moderate" },
  ["shocking grasp"] = { mana = 5, tier = "moderate" },
  ["shower of sparks"] = { mana = 4, tier = "low" },
  ["sickening touch"] = { mana = 10, tier = "moderate" },
  ["solar flare"] = { mana = 10, tier = "high" },
  ["spectral claw"] = { mana = 20, tier = "moderate" },
  ["static blast"] = { mana = 5, tier = "minor" },
  ["storm of roses"] = { mana = 29, tier = "high", area = true },
  ["sunbeam"] = { mana = 8, tier = "low" },
  ["sunblind"] = { mana = 30, tier = "moderate" },
  ["sunstorm"] = { mana = 85, tier = "massive", area = true },
  ["tarrants spectral hand"] = { mana = 12, tier = "low" },
  ["tempest"] = { mana = 20, tier = "low", area = true },
  ["thistles"] = { mana = 6, tier = "low" },
  ["thunder seeds"] = { mana = 7, tier = "low" },
}

-- Damage tiers, weakest -> strongest. Lets the pilot order known offensive spells strongest-first.
local SPELL_TIER = { minor = 1, low = 2, moderate = 3, high = 4, massive = 5 }

-- Parse ONE row of the `spells` listing. Verbatim rows look like (columns space-padded for alignment):
--   "shards                            very good  87%"   -> name="shards", prof="very good", pct=87
-- Class-header lines ("Mage"), the "----" rule, and the "You know..." header have no trailing "N%" and
-- return nil. Name may be multi-word; the name/prof gap is always 2+ spaces (single spaces are within a
-- name), and prof is a word or two before the percent.
local function parse_spell_row(line)
  local name, prof, pctv = (line or ""):match("^(%S.-%S)%s%s+(%S.-)%s+(%d+)%%")
  if not name then return nil end
  return { name = name, prof = prof, pct = tonumber(pctv) }
end

-- Classify a spell NAME against SPELL_DB. Returns offensive?, mana, tier, area. Absent => a buff/utility
-- spell (offensive=false), which the combat pilot must never pick as an attack.
local function classify_spell(name)
  local e = SPELL_DB[(name or ""):lower()]
  if e then return true, e.mana, e.tier, e.area end
  return false
end

-- Annotate parsed `spells` rows with combat metadata, dropping any "not learned" straggler. Each entry:
-- { name, prof, pct, offensive, mana, tier, area } — the shape state.spells_known holds and the pilot
-- reads to build its damage-spell line and its melee->real-spell substitution.
local function annotate_spells(rows)
  local out = {}
  for _, r in ipairs(rows or {}) do
    if not (r.prof and r.prof:lower():match("not learned")) then
      local off, mana, tier, area = classify_spell(r.name)
      out[#out + 1] = { name = r.name, prof = r.prof, pct = r.pct,
                        offensive = off, mana = mana, tier = tier, area = area }
    end
  end
  return out
end

-- Pure end-to-end parse of a whole `spells` output BLOCK (the live path uses the line triggers below,
-- but both share parse_spell_row + annotate_spells, so this is the same logic under test). Captures rows
-- between the "You know the following spells:" header and the first line that is neither a spell row nor
-- a class-header/rule line (a prompt or blank ends it).
local function parse_spells_block(block)
  local rows, capturing = {}, false
  for line in (block or ""):gmatch("[^\n]+") do
    if line:match("^You know the following spells:") then
      capturing = true
    elseif capturing then
      local r = parse_spell_row(line)
      if r then rows[#rows + 1] = r
      elseif line:match("^%-+%s*$") or line:match("^%s*%u%a+%s*$") then   -- class header / rule: keep going
      else break end
    end
  end
  return annotate_spells(rows)
end

-- Live capture: mirror the affects/inventory block pattern. The header arms it; spell rows accumulate;
-- a class header / "----" rule keeps it open (multiple classes); anything else (prompt, blank, the
-- following `skills` header) commits state.spells_known and stops.
local spells_capturing, spells_buf = false, nil
trigger([[^You know the following spells:]], function() spells_capturing = true; spells_buf = {} end)
trigger([[.*]], function(line)
  if not spells_capturing then return end
  if line:match("^You know the following spells:") then return end
  local r = parse_spell_row(line)
  if r then spells_buf[#spells_buf + 1] = r; return end
  if line:match("^%-+%s*$") or line:match("^%s*%u%a+%s*$") then return end   -- class header / rule
  spells_capturing = false
  state.spells_known = annotate_spells(spells_buf)
end)

_AA_TEST.SPELL_DB = SPELL_DB
_AA_TEST.SPELL_TIER = SPELL_TIER
_AA_TEST.parse_spell_row = parse_spell_row
_AA_TEST.classify_spell = classify_spell
_AA_TEST.annotate_spells = annotate_spells
_AA_TEST.parse_spells_block = parse_spells_block

-- Inventory tracking. kxwt never reports what you carry, so parse the `inventory` output: capture the
-- lines between "You are carrying:" and the next prompt/section. Until that first capture, inventory
-- is "unknown" so the agent knows to actually check before reaching for gear it may not have.
local inv_capturing = false
trigger([[^You are carrying:]], function() inv_capturing = true; state.inventory = {}; state.inv_known = true end)
trigger([[.*]], function(line)
  if not inv_capturing then return end
  local t = (line:gsub("^%s+", ""):gsub("%s+$", ""))
  if t:match("^You are carrying") then return end            -- the header itself; keep going
  if t == "" or t:match("^<%d+hp") or t:match("^kxwt_")
     or t:match("^You are using") or t:match("^You are wearing") or t:match("^You can't carry") then
    inv_capturing = false; return                            -- end of the list
  end
  local low = t:lower()
  if low ~= "nothing." and low ~= "nothing" then state.inventory[#state.inventory + 1] = t end
end)

-- Equipment (worn/wielded) tracking — same idea, parsed from the `equipment` output. Lines look like
-- "<worn on head>  a hard leather helm"; we keep the whole line so the agent sees slot + item.
local eq_capturing = false
trigger([[^You are using:]],   function() eq_capturing = true; state.equipment = {}; state.eq_known = true end)
trigger([[^You are wearing:]], function() eq_capturing = true; state.equipment = {}; state.eq_known = true end)
trigger([[.*]], function(line)
  if not eq_capturing then return end
  local t = (line:gsub("^%s+", ""):gsub("%s+$", ""))
  if t:match("^You are using") or t:match("^You are wearing") then return end   -- the header
  if t == "" or t:match("^<%d+hp") or t:match("^kxwt_") or t:match("^You are carrying") then
    eq_capturing = false; return
  end
  local low = t:lower()
  if low ~= "nothing." and low ~= "nothing" then state.equipment[#state.equipment + 1] = t end
end)

-- A compact, model-friendly state snapshot (consumed by AIPilot.lua via describe_state()).
function describe_state()
  local out = {}
  out[#out+1] = "name: " .. (state.name or "unknown")
  if state.hp then
    out[#out+1] = string.format("hp: %d/%d, mana: %d/%d, stamina: %d/%d%s",
      state.hp, state.maxhp or 0, state.mana or 0, state.maxmana or 0,
      state.stam or 0, state.maxstam or 0, ready() and " (ready)" or "")
  end
  if state.position then out[#out+1] = "position: " .. state.position end
  if state.room_name then out[#out+1] = "room: " .. state.room_name end
  if state.area then out[#out+1] = "area: " .. state.area end
  if state.fighting then
    out[#out+1] = string.format("combat: fighting %s (%d%%)", state.fight_name or "?", state.fight_pct or 0)
  elseif engaged() then
    -- nomelee fight: no kxwt target, but combat text proves an engagement. Name the inferred enemies.
    local opps = active_opponents()
    local names = {}
    for _, o in ipairs(opps) do
      names[#names + 1] = o.name .. (o.pct and string.format(" (~%d%%)", o.pct) or "")
    end
    out[#out+1] = "combat: ENGAGED (nomelee — no exact target data)"
      .. (#names > 0 and (": " .. table.concat(names, ", ")) or "")
  else
    out[#out+1] = "combat: not fighting"
  end
  local sp = {}
  for k in pairs(state.spells) do sp[#sp+1] = k end
  if #sp > 0 then out[#out+1] = "active spells: " .. table.concat(sp, ", ") end
  -- Inventory/equipment intentionally omitted: kxwt doesn't report them (they're parsed from
  -- `inventory`/`equipment` output and go stale fast), so they're noise in the state block.
  if state.gold then out[#out+1] = "gold: " .. state.gold end
  out[#out+1] = "recovery mode: " .. (state.recover and "on" or "off")
  return table.concat(out, "\n")
end

-- THE combat predicate for every consumer (pilot navigation/prompt gating, equipment swaps, corpse
-- automation, recovery). Broadened to the engaged() state: in a nomelee fight kxwt_fighting is never
-- sent, but you're still very much in combat — navigation must not walk off, eq swaps must not start,
-- recovery must not begin, and the pilot must be told it's fighting. Consumers that specifically need
-- "am I in the melee round with an exact target" should read state.fighting directly.
function in_combat() return engaged() end

-- ===== Corpse automation (kxwt_mdeath-driven) — fully stream/trigger-driven =====
-- ON by default (kxwt.corpse('off') to stop). Runs only after an actual KILL (not a flee — see below).
-- When you're OUT OF COMBAT, walk the corpses in the room BY INDEX (1.corpse, 2.corpse, ...) and HARVEST
-- each: harvest teeth -> harvest spellcomps, then:
--   * EMPTY corpse -> bsac -> sac. `sac` removes it, so the next corpse shifts into THIS index (re-process).
--   * HAS LOOT -> leave it INTACT and step to the NEXT index. We never `get all` (looting was removed by
--     request), and we must never sacrifice a corpse that still holds items — that would destroy them,
--     incl. binding/quest gear (the bug fixed earlier). "Has loot" is read from the contents the game
--     auto-prints at the kill ("(on ground) the corpse of X contains:"); each corpse's NAME comes from its
--     own "You start harvesting…" reply, so we only sac the ones we're sure are empty.
-- We stop when there's no corpse at the current index. Each step advances off a real STREAM line; the
-- watchdog below is only a last-resort net for a missed line.
local corpse = { on = true, active = false, idx = 1, step = nil, room = nil,
                 killed = false, settle = nil, watchdog = nil,
                 with_items = {}, cur_name = nil }
if _AA_TEST then _AA_TEST.corpse = corpse end   -- exposed so the empty/has-loot decision is unit-tested
local CORPSE_MAX = 20   -- safety cap on how many corpse indices we'll walk (guards a missed terminator)

-- Stall watchdog. Pacing stays STREAM-DRIVEN (each step advances off a real game line); this is only a
-- last-resort net: the harvest replies vary a lot (a successful `harvest spellcomps` just yields its
-- comps with no distinct "done" line), so if we ever miss a terminal the machine would hang forever —
-- corpse.active stuck true (blocking every future loot pass) and the promise row leaking. If no step
-- has advanced within CORPSE_WATCHDOG seconds, force the pass closed so nothing stays wedged.
local CORPSE_WATCHDOG = 5
local function corpse_touch()
  if corpse.watchdog then cancel(corpse.watchdog); corpse.watchdog = nil end
  if not corpse.active then return end
  corpse.watchdog = after(CORPSE_WATCHDOG, function()
    corpse.watchdog = nil
    if corpse.active then echo("\27[33m[corpse] loot pass stalled — wrapping it up.\27[0m"); corpse_done() end
  end)
end

-- `killed` = a mob actually DIED this fight (kxwt_mdeath), so combat ending means we have corpses to
-- work. Cleared here (and on a room change), so ending combat by FLEEING — which changes rooms and
-- leaves no corpse of ours — never kicks off looting. Settling the promise (resolve) drops the row from
-- the promise widget, whether the pass finished naturally or was stopped (off / room change).
function corpse_done()
  corpse.active = false; corpse.step = nil; corpse.idx = 1; corpse.killed = false
  if corpse.watchdog then cancel(corpse.watchdog); corpse.watchdog = nil end
  local s = corpse.settle; corpse.settle = nil
  if s then s.resolve() end
end

function corpse_start()
  if not corpse.on or corpse.active or in_combat() then return end
  corpse.active = true; corpse.idx = 1
  -- Surface the harvest pass as a tracked promise so it shows in the HUD promise widget ("harvesting
  -- corpses") and disappears when corpse_done() resolves it. Guarded so the driver runs without Promise.lua.
  -- CRITICAL: start the promise SYNCHRONOUSLY (p.__start()) so corpse.settle is wired *before* we harvest.
  -- The builder otherwise runs its executor on the next tick (after(0)); but corpse_done() — driven by
  -- stream lines — can fire before that tick, find corpse.settle still nil, and never resolve, leaking
  -- the widget row forever. Running the executor now removes the timing dependency entirely.
  if __promise then
    local p = __promise(function(resolve, reject, onCancel)
      corpse.settle = { resolve = resolve, reject = reject }
      onCancel(function() corpse.settle = nil; if corpse.active then corpse_done() end end)
    end, "harvesting corpses")
    if p and p.__start then p.__start() end
  end
  corpse_process()
end

-- Loot + harvest the corpse at corpse.idx. Loot triggers set `dirty`; harvest terminals advance us.
function corpse_process()
  if not corpse.active then return end
  if corpse.idx > CORPSE_MAX then corpse_done(); return end
  corpse_touch()          -- progress: (re)arm the stall watchdog
  corpse.step, corpse.cur_name = "teeth", nil   -- cur_name is re-learned from this corpse's harvest reply
  -- Harvest is the FIRST thing we send now — no `get all`. On a missing corpse this yields "You don't see
  -- anything named '<n>.corpse'" (or the watchdog fires), which ends the walk.
  send("harvest teeth " .. corpse.idx .. ".corpse")
end

-- A harvest terminal line was seen -> next harvest, or on to the empty/has-loot decision.
function corpse_harvest_done()
  if not corpse.active then return end
  corpse_touch()          -- progress: (re)arm the stall watchdog
  if corpse.step == "teeth" then
    corpse.step = "spellcomps"
    send("harvest spellcomps " .. corpse.idx .. ".corpse")
  elseif corpse.step == "spellcomps" then
    corpse_finish()
  end
end

-- Done harvesting this corpse. Sacrifice it ONLY if we're sure it's empty: we know its name (from its
-- harvest reply) AND the kill didn't auto-print any loot contents for it. Otherwise (has loot, or name
-- unknown) leave it INTACT and step to the next index — never destroy items.
function corpse_finish()
  if not corpse.active then return end
  local name = corpse.cur_name
  if name and not corpse.with_items[name] then
    corpse.step = "bsac"
    send("bsac " .. corpse.idx .. ".corpse")   -- empty → blood-sacrifice, then sac on the bsac result line
  else
    corpse.idx = corpse.idx + 1                 -- has loot (or unsure) → leave it, next corpse
    corpse_process()
  end
end

function corpse_sac()
  if not corpse.active or corpse.step == "sac" then return end
  corpse_touch()          -- progress: (re)arm the stall watchdog
  corpse.step = "sac"
  send("sac " .. corpse.idx .. ".corpse")   -- removes it; the next corpse shifts into corpse.idx...
  corpse_process()                          -- ...so re-process the SAME index
end

-- A mob DIED -> remember it and try to start (usually a no-op: you're still fighting, so corpse_start
-- bails; the real start is when combat ENDS below). kxwt_fighting -1 fires when combat ends for ANY
-- reason, so only walk corpses if a kill actually happened this fight — fleeing ends combat with no
-- corpse of ours (and moves us), and must NOT trigger looting.
trigger([[^kxwt_mdeath (.+)$]], function() corpse.killed = true; corpse_start() end)
trigger([[^kxwt_fighting -1$]], function() if corpse.killed then corpse_start() end end)

-- Room change abandons this room's corpses (they don't follow you) -> stop, so we never target a
-- corpse in the wrong room (e.g. after fleeing).
trigger([[^kxwt_rvnum (-?\d+)]], function(_, vnum)
  if corpse.room ~= nil and corpse.room ~= vnum then
    corpse_done()
    corpse.with_items = {}   -- has-loot knowledge is per-room; forget it when we leave
  end
  corpse.room = vnum
end)

-- Loot detection WITHOUT looting: the game auto-prints a corpse's contents at the kill — "(on ground)
-- the corpse(s) of <name> contains:" — whenever it holds items. Record those names; the harvest walk
-- then bsac/sacs only the corpses that never showed contents (see corpse_finish). Loose (unanchored) on
-- purpose: over-recording just leaves a corpse un-sacrificed, while missing one would destroy its loot.
trigger([[the corpses? of (.+) contains:]], function(_, name) corpse.with_items[name] = true end)
-- Learn the current corpse's name from its own harvest reply so we can match it against with_items.
trigger([[^You start harvesting teeth from the corpses? of (.+?)\.?$]], function(_, name) corpse.cur_name = name end)

-- No corpse at the current index -> the room's corpses are done. The `'<n>.corpse'` miss is how the
-- index-walk detects "no more corpses", so gag it: it's internal plumbing, not something you did.
gag([[^You don't see anything named '\d+\.corpse']])
trigger([[^You don't see anything named]], function() if corpse.active then corpse_done() end end)
trigger([[^You don't see that here]], function() if corpse.active then corpse_done() end end)

-- Harvest terminal lines (^-anchored so another player can't fire them). Success-complete OR the
-- instant "full"/"no skill" rejection — either way the harvest step is finished, so advance.
trigger([[^You don't see any usable]], function() corpse_harvest_done() end)             -- teeth (likely spellcomps too)
trigger([[^You can't safely carry any more teeth]], function() corpse_harvest_done() end) -- teeth full
trigger([[^Your collected teeth grow restless]], function() corpse_harvest_done() end)    -- teeth full
trigger([[^You don't know enough about the undead]], function() corpse_harvest_done() end) -- no spellcomp skill
trigger([[^You can't harvest spell components from that]], function() corpse_harvest_done() end) -- this corpse yields no spellcomps
trigger([[^Looks like the corpses? of .+ (is|are) too damaged for you to use]], function() corpse_harvest_done() end) -- corpse(s) too mangled to harvest -> skip, keep going (plural for swarm/group mobs)
-- A SUCCESSFUL `harvest spellcomps` has no distinct "done" line — it just yields the component(s) and
-- stops (unlike teeth, which end on "grow restless"). So the yield line IS the terminal for the
-- spellcomps step. Necromancer comps come in a few shapes; generalized to catch every colour/type:
--   * "…drain <X> into <Y>"          ("You make a small incision and drain some fluid into a vial of
--                                      bile.", "You find a dark cyst and drain it into a vial of melancholy.")
--   * "…tie off the ends…"           (hack-out/find a bladder of coloured fluid)
-- Gated to the spellcomps step so a stray yield can't advance a teeth harvest early — and so an earlier
-- fight's line can't fire it.
trigger([[^You .+ drain .+ into a vial]],
  function() if corpse.active and corpse.step == "spellcomps" then corpse_harvest_done() end end)
trigger([[^You .+ tie off the ends]],
  function() if corpse.active and corpse.step == "spellcomps" then corpse_harvest_done() end end)

-- Blood-sacrifice result (success OR the undead/"not intact" refusal) -> the final sacrifice.
trigger([[^You sacrifice blood from]], function() if corpse.active and corpse.step == "bsac" then corpse_sac() end end)
trigger([[^You can only blood sacrifice]], function() if corpse.active and corpse.step == "bsac" then corpse_sac() end end)

-- kxwt.corpse('on'|'off'|'status') (dispatched from the kxwt table). Returns true if it handled the verb.
function corpse_command(verb, rest)
  if verb ~= "corpse" then return false end
  local m = (rest or ""):lower():match("^%s*(%S*)")
  if m == "on" then
    corpse.on = true
    echo("[kxwt] corpse automation ON — out of combat, per corpse (by index): harvest teeth -> harvest spellcomps -> (if EMPTY) bsac -> sac; corpses holding loot are left intact (never `get all`, never sac loot)")
  elseif m == "off" then
    corpse.on = false; corpse_done()
    echo("[kxwt] corpse automation OFF")
  else
    echo(string.format("[kxwt] corpse %s | active=%s idx=%d step=%s",
      corpse.on and "ON" or "off", tostring(corpse.active), corpse.idx, tostring(corpse.step)))
  end
  return true
end

-- A concise reference of REAL AlterAeon commands, condensed from the official command guide
-- (alteraeon.com/guides/commands.html). AIPilot folds this into the system prompt so the model
-- reaches for actual commands (via the `command` tool) instead of inventing them. Game knowledge,
-- so it lives here in the game layer; edit + pilot.reload() to tweak.
function game_command_reference()
  return [[MOVEMENT: type a direction or its abbreviation — north/n south/s east/e west/w up/u down/d northeast/ne northwest/nw southeast/se southwest/sw. 'recall' returns to your waypoint; 'waypoint' travels between set waypoints.
LOOKING/INFO: 'look' (room), 'look <thing>', 'exits', 'hp', 'score', 'inventory' (i/inv), 'equipment' (what you're wearing/wielding), 'spells', 'skills', 'consider <target>' (gauge a fight), 'who', 'help <topic>'.
ITEMS/GEAR: 'get <item>' / 'get all' / 'get all corpse' (loot) / 'get <item> <container>'; 'drop <item>'; 'put <item> in <container>'; 'wear <armor>'; 'wield <weapon>'; 'use <item>' (auto-pick best slot); 'remove <item>' (take off, to swap to better gear); 'donate <item>'.
COMBAT: 'kill <target>' / 'attack <target>'; 'flee' or 'run' to escape; class skills 'kick', 'trip', 'backstab'. Check 'hp' when hurt.
SPELLS: cast '<spell name>' [target]. Names may be abbreviated. With no target while fighting, it targets your current enemy; a self/buff spell with no target hits you. Only cast attack spells when there's an enemy. 'spells' lists yours.
RECOVER: 'rest' or 'sleep' to heal hp/mana/stamina; 'stand' or 'wake' when recovered.
PROGRESS: at a trainer, 'level', 'train', and 'practice' improve you; 'slist' shows newly available spells/skills.]]
end

-- begin_recovery(frac) — start resting/sleeping toward the `frac` threshold. Shared by the typed
-- `recover` alias (frac = 90%) and the recover([pct]) builder. The auto-stand lives in the kxwt_prompt
-- trigger (maybe_complete_recovery), which watches ready(recovery.pct).
local function begin_recovery(frac)
  recovery.pct = frac
  state.recover = true
  local pctlabel = math.floor(frac * 100 + 0.5)
  if recovery.stat then
    echo(string.format("Recovering %s — resting/sleeping; I'll stand you up once %s hits %d%%.",
         STAT_LABEL[recovery.stat], STAT_LABEL[recovery.stat], pctlabel))
  else
    echo(string.format("Recovering — resting/sleeping; I'll stand you up once every vital hits %d%%.", pctlabel))
  end
  reset_posture()       -- fresh recovery → don't let a just-interrupted one's debounce eat the first rest
  choose_recovery_position()
  -- Kick the recovery-cast driver (heals skeletal minions on a full recovery, and/or spends surplus mana
  -- on your own vitals). It internally respects the mode: minion-only skips self, single-stat skips
  -- minions, `recover mana` casts nothing (no spell makes mana).
  heal_minions_kick()
  -- Fetch current-posture regen numbers (gagged) so cast-vs-wait has data — unless this is minion-only.
  if not recovery.minions_only then query_regen() end
end

-- recover([pct]) — start a recovery and return a PROMISE (Scripts/Promise.lua) that resolves when
-- every vital reaches the target (default 90%; pass 95 or 0.95 for a custom threshold) and rejects if
-- recovery is interrupted (you move, a fight starts, or you cancel). Chain the next action with
-- .andThen, e.g.  #recover(95).andThen(attack('orc')).  The typed `recover` alias (below) is the
-- fire-and-forget form; this returns a composable promise.
function recover(target)
  local frac = READY_PCT
  if target ~= nil then
    local n = tonumber(target)
    if n and n > 0 then frac = (n > 1) and (n / 100) or n end   -- accept 95 or 0.95
  end
  if frac > 1 then frac = 1 end
  return __promise(function(resolve, reject, onCancel)
    -- Nothing to do only if YOU are at target AND every minion is topped off — otherwise recovery still
    -- has work (resting your vitals and/or casting heals on the skeletal minions).
    if ready(frac) and all_minions_ready(frac) then
      echo("Already recovered — vitals at target and minions topped off."); resolve(); return
    end
    -- A recovery is a singleton (one `recovery.settle` slot). If one is already pending — e.g. you typed
    -- `recover`, then `recover | explore` — the newer call takes over: reject the old promise as
    -- superseded so it settles (and leaves the promise widget) instead of dangling forever, orphaned.
    if recovery.settle then local old = recovery.settle; recovery.settle = nil; old.reject("superseded") end
    recovery.settle = { resolve = resolve, reject = reject }
    recovery.stat, recovery.minions_only = nil, nil   -- normal recovery: every vital, heal minions too
    begin_recovery(frac)
    onCancel(function()
      -- Chain aborted: stand up and clear the recovery flag WITHOUT firing resolve/reject (the promise
      -- is cancelled, not settled). A later kxwt_prompt then can't complete it (state.recover is false).
      if state.recover then send("stand") end
      recovery.settle, recovery.pct, state.recover = nil, READY_PCT, false
      reset_minion_heal()   -- drop any in-flight minion healing too
    end)
  end, "recover")
end
doc("recover", { sig = "recover([pct]) -> promise", group = "combat",
  text = "Start a recovery and return a promise that resolves once every vital reaches `pct` (95 or "
      .. "0.95; default 90%) and rejects if interrupted (you move, a fight starts, you cancel). Chain "
      .. "the next action with .andThen — e.g. recover(95).andThen(attack('orc')).",
  example = "#recover(95).andThen(attack('orc'))" })

-- recover_minions() — heal JUST your skeletal minions (bolster/soothe) until they're topped off, leaving
-- your own vitals and posture completely alone (no rest/sleep). Returns a promise that resolves when no
-- minion still needs a cast (or immediately if none do) and rejects if cancelled/superseded. Shares the
-- singleton `recovery.settle` slot with recover(), so starting one supersedes the other. Typed: `recover
-- minions`.
function recover_minions()
  return __promise(function(resolve, reject, onCancel)
    if not minions_pending_spell_heal() then
      echo("No minions need healing right now."); resolve(); return
    end
    if recovery.settle then local old = recovery.settle; recovery.settle = nil; old.reject("superseded") end
    recovery.settle = { resolve = resolve, reject = reject }
    recovery.minions_only, recovery.stat, state.recover = true, nil, true
    echo("Healing your minions — casting until they're topped off (leaving your own vitals alone).")
    heal_minions_kick()
    onCancel(function()
      recovery.settle, recovery.minions_only, state.recover = nil, nil, false
      reset_minion_heal()
    end)
  end, "recover minions")
end
doc("recover_minions", { sig = "recover_minions() -> promise", group = "combat",
  text = "Heal ONLY your skeletal minions (bolster/soothe) until topped off, leaving your own vitals and "
      .. "posture alone — no rest/sleep. Returns a promise; resolves when no minion needs a cast. Typed "
      .. "form: `recover minions` (and `recover minions off` to stop)." })

-- recover_stat(stat[, pct]) — recover ONE vital only. `stat` is hp/health, mana/mp, or stamina/sp (any
-- of the STAT_ALIASES). Runs the normal rest/sleep flow but the DONE condition watches just that stat
-- (the others are ignored), and it never spends mana healing minions. Returns the usual recovery promise.
function recover_stat(stat, target)
  local key = STAT_ALIASES[tostring(stat):lower()]
  return __promise(function(resolve, reject, onCancel)
    if not key then echo("Unknown stat '" .. tostring(stat) .. "' — use hp, mana, or stamina."); resolve(); return end
    local frac = READY_PCT
    if target ~= nil then
      local n = tonumber(target)
      if n and n > 0 then frac = (n > 1) and (n / 100) or n end   -- accept 95 or 0.95
    end
    if frac > 1 then frac = 1 end
    if one_stat_ready(key, frac) then
      echo(string.format("Already recovered — %s at target.", STAT_LABEL[key])); resolve(); return
    end
    if recovery.settle then local old = recovery.settle; recovery.settle = nil; old.reject("superseded") end
    recovery.settle = { resolve = resolve, reject = reject }
    recovery.minions_only, recovery.stat = nil, key
    begin_recovery(frac)
    onCancel(function()
      if state.recover then send("stand") end
      recovery.settle, recovery.pct, recovery.stat, state.recover = nil, READY_PCT, nil, false
      reset_minion_heal()
    end)
  end, "recover " .. STAT_LABEL[key or "hp"])
end
doc("recover_stat", { sig = "recover_stat(stat[, pct]) -> promise", group = "combat",
  text = "Recover ONE vital only — `stat` is hp/health, mana/mp, or stamina/sp. Same rest/sleep flow as "
      .. "recover(), but done as soon as that single stat hits `pct` (default 90%); ignores the other "
      .. "vitals and never heals minions. Typed form: `recover hp` / `recover mana` / `recover stamina`.",
  example = "#recover_stat('mana', 95)" })

-- Aliases: `state` dumps the snapshot; `recover` rests/sleeps until ready, then auto-stands.
alias([[^state$]], function() echo(describe_state()) end)
-- `recover` — sit/sleep to heal and STAND automatically once every vital is back to 90%+ (the auto-stand
-- lives in the kxwt_prompt trigger, which watches ready()). choose_recovery_position picks rest vs sleep
-- for the situation. Typing `recover` again while already recovering is a NO-OP (just echoes) — it does
-- NOT stop and does NOT re-send a posture command, so you can change your mind and follow up with
-- `recover | explore` without a stray cancel racing it. Use `recover off` to actually stop.
alias([[^recover$]], function()
  if state.recover then
    echo("Already recovering — 'recover off' to stop.")
  elseif ready() and all_minions_ready() then
    echo("Already recovered — all vitals at 90%+ and minions topped off.")
  else
    recover()   -- go through the promise (not begin_recovery) so the recovery shows in the promise widget
  end
end)
-- `autoassist [on|off]` — toggle/report the auto-`assist` (jump into a fight your minions are in when
-- you're not). NOT named `assist` — that's a real game command we must never shadow.
alias([[^autoassist\s*(\w*)$]], function(_, arg)
  local a = (arg or ""):lower()
  if a == "on" then state.auto_assist = true
  elseif a == "off" then state.auto_assist = false
  elseif a ~= "" then echo("Usage: autoassist [on|off]"); return end
  echo("Auto-assist is " .. (state.auto_assist and "ON" or "OFF")
    .. " — I " .. (state.auto_assist and "will" or "won't") .. " `assist` when your minions are fighting and you aren't.")
end)

-- `recover minions` — heal ONLY your minions (bolster/soothe), leaving your own vitals/posture alone.
-- `recover minions off` stops it. (More specific than `^recover$`, so it wins the alias match.)
alias([[^recover minions$]], function()
  if state.recover then
    echo("Already recovering — 'recover off' to stop.")
  elseif not minions_pending_spell_heal() then
    echo("No minions need healing right now.")
  else
    recover_minions()   -- promise-backed, so it shows in the promise widget as "recover minions"
  end
end)
alias([[^recover minions off$]], function()
  if state.recover then echo("Ending minion healing."); end_recovery(false, "cancelled")
  else echo("Not recovering.") end
end)

-- `recover hp|health|mana|mp|stamina|sp|...` — recover just ONE vital (ignores the others, no minion
-- casts). More specific than `^recover$`, so it wins the alias match. `recover off` still stops it.
alias([[^recover (hp|health|hitpoints|mana|mp|stamina|stam|sta|sp)$]], function(_, word)
  local key = STAT_ALIASES[word:lower()]
  if state.recover then
    echo("Already recovering — 'recover off' to stop.")
  elseif one_stat_ready(key) then
    echo(string.format("Already recovered — %s at 90%%+.", STAT_LABEL[key]))
  else
    recover_stat(word)   -- promise-backed, so it shows in the widget as "recover HP/mana/stamina"
  end
end)

-- `recover off` — the only way to end an in-progress recovery (bare `recover` no longer toggles).
alias([[^recover off$]], function()
  if state.recover then
    echo("Ending recovery."); end_recovery(false, "cancelled")
  else
    echo("Not recovering.")
  end
end)

-- test() — run the Lua spec suite against the CURRENTLY-LOADED scripts, in this same Lua state, so you
-- can verify a change right after pilot.reload(). Re-reads the harness + every Scripts/tests/*.lua so it
-- always reflects the latest edits. Pure Lua; no external interpreter or build step. A first-class
-- documented function (migrated off the command() bridge); the legacy typed `#test` rewrites to test().
-- (Note: the spec harness itself, testing.lua, temporarily rebinds the global `test` to the case
-- registrar while a run is in progress — same as the old bridge did — so re-run via pilot.reload() first.)
function test() return run_test_suite() end
doc("test", { sig = "test() -> (pass, fail)", group = "scripts",
  text = "Run the Lua spec suite (Scripts/tests/*.lua) against the live, currently-loaded scripts and report pass/fail per case — verify an edit right after pilot.reload()." })
-- Returns (pass, fail) so a CLI runner can set its exit code; the in-app test() just ignores them.
function run_test_suite()
  local pass, fail = 0, 0
  local ok, err = pcall(function()
    dofile("Scripts/testing.lua")   -- (re)defines test/expect/run_tests/reset_tests/capture_update/count
    reset_tests()
    -- Discover spec files by globbing the tests dir (CWD is the repo root, as with `#load`). Falls back
    -- to a manifest if io.popen is unavailable, so new spec files just need adding to TEST_SPECS below.
    local files = {}
    local p = io.popen and io.popen("ls Scripts/tests/*.lua 2>/dev/null")
    if p then for f in p:lines() do files[#files + 1] = f end; p:close() end
    if #files == 0 then
      TEST_SPECS = TEST_SPECS or { "Scripts/tests/hud_spec.lua", "Scripts/tests/aipilot_spec.lua" }
      for _, f in ipairs(TEST_SPECS) do
        local fh = io.open(f, "r")
        if fh then fh:close(); files[#files + 1] = f end
      end
    end
    table.sort(files)
    if #files == 0 then echo("[test] no spec files found under Scripts/tests/"); return end
    echo(string.format("[test] running %d spec file(s)…", #files))
    for _, f in ipairs(files) do
      local okf, e = pcall(dofile, f)
      if not okf then
        fail = fail + 1
        echo("[test] \27[31mfailed to load " .. f .. ": " .. tostring(e) .. "\27[0m")
      end
    end
    local p, fl = run_tests()
    pass, fail = pass + p, fail + fl
  end)
  if not ok then echo("[test] \27[31mharness error: " .. tostring(err) .. "\27[0m"); return 0, 1 end
  return pass, fail
end
