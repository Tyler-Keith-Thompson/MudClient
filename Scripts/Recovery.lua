-- AlterAeon recovery layer — rest/sleep, lifetap, minion healing, self-casting, regen cache.
--
-- Split out of AlterAeon.lua. The recovery state machine and everything that drives it. AlterAeon.lua
-- parses the kxwt fields into `state` and calls the __recovery_on_* hooks (bottom of this file) so the
-- machinery — all file-local upvalues — reacts without being exposed. recover()/recover_stat()/
-- recover_minions() + the typed aliases are the public entry points.

state = state or {}
_AA_TEST = _AA_TEST or {}

local function pct(cur, max) if not cur or not max or max == 0 then return 0 end return cur / max end
-- "Ready" = recovered enough to keep exploring: every vital at least 90%. Drives the `recover` alias's
-- auto-stand and the AI's " (ready)" readiness label, so both share one definition.
local READY_PCT = 0.90
-- When a buff drops while we're asleep recovering, we wake to rest so it can be recast; hold awake this
-- many seconds waiting for the corresponding spellup before we're allowed to sleep again (else we sleep
-- through the recast and bounce). Cleared early when the spellup actually lands.
local SPELLUP_WAIT = 12
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
local pick_self_cast               -- () -> decision|nil: fwd decl (choose consults it; defined below)
local lifetap_hold_rest            -- () -> bool: fwd decl — a worthwhile HP->mana bleed is available or in
                                   -- flight, so choose_recovery_position must force `rest` (sleep would
                                   -- bind the wound and cancel it). Defined in the lifetap block below.
local ticks_to_target             -- (cur,max,rate,frac) -> ticks of natural regen to target; fwd-declared so
                                   -- the lifetap block (above its definition) can ask "is mana far off?"

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

-- Decision narration during recovery — the user asked to SEE what recover decided and why. Two
-- independent DEDUPED channels (posture + cast): a decision announces once and stays quiet until it
-- changes, so the choice narrates without spamming every prompt tick. Reset per recovery so a fresh one
-- re-narrates from scratch.
local last_posture_key, last_cast_key
local function narrate(chan, key, msg)
  if chan == "posture" then
    if key == last_posture_key then return end
    last_posture_key = key
  else
    if key == last_cast_key then return end
    last_cast_key = key
  end
  if echo then echo("\27[36m[recover]\27[0m " .. msg) end
end
local function reset_narration() last_posture_key, last_cast_key = nil, nil end

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
  -- A buff dropped while we were asleep (the spelldown trigger woke us): hold at rest until the spellup
  -- lands or we time out, so we don't sleep straight through the recast and bounce awake again.
  if recovery and recovery.await_spell and os.time() >= (recovery.await_until or 0) then
    recovery.await_spell, recovery.await_until = nil, nil    -- timed out waiting — give up and recover normally
  end
  local awaiting_spellup = recovery and recovery.await_spell ~= nil
  if player_done then
    -- You're fully recovered; you're only still "recovering" because the minions aren't all topped off.
    -- There's no point staying asleep (or even resting) when you're full: cast on any minion that still
    -- needs it — the skeletal ones, AND (now that you have surplus mana) our own natural-regen tank/pets
    -- via minion_heal_eligible. Only stand-and-wait when nothing of OURS is left to heal.
    if cast_pending then
      narrate("posture", "done-minions-cast", "you're topped off — resting to finish healing your minions")
      -- You must cast bolster/soothe on the minions, which you can't do asleep — wake to resting.
      if recovery_depth(state.position) >= 2 then send_posture("rest") end
    else
      narrate("posture", "done-minions-wait", "you're topped off — standing, waiting on your minions to regen")
      -- Nothing of ours left to actively heal (only other players / given-up minions regen on their
      -- own) — nothing for you to do, so stand back up.
      if recovery_depth(state.position) > 0 then send_posture("stand") end
    end
    return
  end
  -- You still need to recover yourself. rest when only mana is low (keeps your guard), else sleep — but
  -- you can't cast while asleep, so cap at rest while skeletal minions still need bolster/soothe. rest
  -- heals you a bit slower than sleep, but the minions can't heal themselves at all.
  local hp, mp, sp = pct(state.hp, state.maxhp), pct(state.mana, state.maxmana), pct(state.stam, state.maxstam)
  local want = (hp > 0.85 and mp < 1 and sp > 0.75) and "rest" or "sleep"
  -- Self-cast recovery, in priority order:
  --   * a cast would fire RIGHT NOW (regen says it beats waiting) → REST so we can cast it;
  --   * else a physical stat lags but no cast is worth it YET and we're not sharp → SLEEP to earn sharp
  --     (faster regen; may finish the job, or make a later cast unnecessary);
  --   * else fall through to the plain vitals heuristic (rest if only mana's low, else sleep).
  local self_want = self_cast_wanted()
  local cast_now  = self_want and (pick_self_cast() ~= nil)
  if cast_now then want = "rest"
  elseif self_want and not state.sharp then want = "sleep" end
  if want == "sleep" and (cast_pending or awaiting_spellup) then want = "rest" end   -- casting/awaiting a recast → stay awake
  -- Lifetap and sleep are mutually exclusive — falling asleep BINDS the wound and cancels the bleed — and
  -- when surplus HP can feed lagging mana, the tap is the faster path (we optimize for total recovery time,
  -- so trading HP down to the safety floor for mana is fine). So while a bleed is worth doing or already in
  -- flight, force rest: without this the sharp/deep-sleep branches above and maybe_lifetap fight (sleep
  -- cancels the tap, HP regens, we tap again) — the rest/sleep oscillation. Wins over every sleep above.
  local tap_rest = lifetap_hold_rest and lifetap_hold_rest()
  if tap_rest then want = "rest" end
  -- Narrate the posture decision (deduped) so you can see WHY we're resting vs sleeping — ONE coherent
  -- line per decision, matching what we're about to do.
  if tap_rest then
    narrate("posture", "rest-lifetap", "resting to bleed surplus hp into mana")
  elseif awaiting_spellup then
    narrate("posture", "rest-spellup", "staying up until " .. recovery.await_spell .. " is recast (or it times out)")
  elseif cast_now then
    narrate("posture", "rest-cast", "resting so I can cast to top off your " .. pick_self_cast().label)
  elseif self_want and not state.sharp then
    narrate("posture", "sleep-sharp", "sleeping to get sharp first — faster regen; I'll cast after if it's still worth it")
  elseif cast_pending then
    narrate("posture", "rest-minions", "resting so I can cast heals on your minions")
  elseif want == "rest" then
    narrate("posture", "rest-mana", "hp and stamina are set — just resting out mana now")
  else
    narrate("posture", "sleep-deep", "sleeping — deepest heal for your hp/stamina")
  end
  -- Resting keeps your guard up — you can be attacked in your sleep — so a "rest" decision moves us TO
  -- rest from EITHER direction, INCLUDING down from sleep. A "sleep" decision only ever DEEPENS (never
  -- wakes us). This fixes "narrated 'just resting out mana' but stayed asleep": the old deepen-only guard
  -- treated already-asleep as deep enough and never downgraded to rest.
  if want == "rest" then
    if recovery_depth(state.position) ~= 1 then send_posture("rest") end
    return
  end
  if recovery_depth(state.position) >= 2 then return end   -- already asleep → nothing to do
  send_posture("sleep")
end

-- Recovery-as-a-promise. `recovery.pct` is the current target threshold; `recovery.settle` holds the
-- resolve/reject callbacks of the promise recover() returned, while one is waiting (nil otherwise).
-- end_recovery() is the single settle point: it clears the flag, restores the default threshold, and
-- resolves (completed) or rejects (interrupted: you moved, a fight started, you cancelled) the promise.
recovery = { pct = READY_PCT, settle = nil }
local function end_recovery(completed, reason)
  state.recover = false
  reset_narration()
  -- We never stop a lifetap ourselves (it can't overuse — the game caps and ends it, and completion's
  -- auto-`stand` / a fight / a move all bind the wound in-game). Just clear our per-recovery lifetap
  -- bookkeeping so the next recovery starts clean.
  state.lifetap_manafull, state.lifetap_retry_at, state.lifetap_send_at = false, nil, 0
  if reset_minion_heal then reset_minion_heal() end   -- stop any in-flight minion healing
  local s = recovery.settle
  recovery.settle, recovery.pct, recovery.minions_only, recovery.stat = nil, READY_PCT, nil, nil
  recovery.await_spell, recovery.await_until = nil, nil   -- drop any "waiting for a recast" hold
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

-- ---- Lifetap: bleed surplus HP into mana during recovery ----------------------------------------
--
-- `lifetap <hp>` is a necromancer skill that trades HP for mana over time (disallowed in combat, cancelled
-- if you fall asleep). During a mana-limited rest that HP is pure surplus — it regens back for free — so we
-- dump it into mana to finish recovering faster. Rules the user set:
--   * only tap when MANA IS LOW — more than LIFETAP_MANA_TICKS ticks of natural regen from FULL. Mana
--     regens faster than HP (we read both rates from `show regen`), so if mana is nearly full we just wait
--     it out rather than paying slow-to-regen HP for it; lifetap earns its keep on a real deficit (roughly
--     a tick's worth or more — e.g. ~90 points down at this character's regen);
--   * only START a tap with real surplus in hand — HP above LIFETAP_START of max — then bleed the whole
--     chunk down to the floor. (Holding/re-picking rest is separate: once tapped down we keep resting and
--     only re-tap after HP regens back above the start line, so we bleed in big chunks, not scraps.)
--   * never bleed past LIFETAP_FLOOR of max HP (half + a buffer); it's fine to go below the recovery's own
--     HP target — trading HP for mana is the point when mana is the bottleneck (optimize for time);
--   * always a direct amount (`lifetap <n>`) — the whole surplus down to the floor ("max safe chunk");
--   * we do NOT stop the bleed ourselves — lifetap can't overuse (the game caps it and binds the wound when
--     the requested amount is spent), so we just start it and let the game end it;
--   * WAIT for the game's "begin tapping" confirmation before issuing another (the reply lags the command
--     by a round-trip; without a debounce we'd fire `lifetap` again every tick and spam it);
--   * back off briefly after the transient "You are too weak to do that right now." refusal, then retry.
-- Gated to necromancers who actually have the skill (level >= 21); self-disables on everyone else.
local LIFETAP_FLOOR     = 0.55   -- fraction of max HP we refuse to bleed below (half + buffer)
local LIFETAP_START     = 0.75   -- only START a fresh tap when HP is above this (bleed real surplus, not scraps)
local LIFETAP_MIN       = 15     -- don't start a bleed for a surplus smaller than this (avoid churn)
local LIFETAP_MANA_TICKS = 1     -- only tap when mana is MORE than this many ticks of natural regen from FULL
local LIFETAP_MIN_LEVEL = 21     -- necromancer level the lifetap skill unlocks at
local LIFETAP_RETRY     = 5      -- seconds to back off after a transient "too weak" refusal before retrying
local LIFETAP_COOLDOWN  = 15     -- seconds to settle after a bleed binds before opening another
local LIFETAP_SEND_WAIT = 3      -- seconds to await the "begin tapping" confirm before re-issuing a tap

-- The HP we refuse to bleed below. Round to nearest (not ceil): `100 * 0.55` is 55.0000…1 in double, and
-- ceil would surprise a reader with 56. The buffer above half absorbs the sub-HP rounding.
local function lifetap_floor_hp() return math.floor((state.maxhp or 0) * LIFETAP_FLOOR + 0.5) end
local function has_lifetap()
  local n = state.classes and state.classes.Necromancer
  return n and (n.level or 0) >= LIFETAP_MIN_LEVEL
end

-- The lifetap "campaign" is active: a mana-lagging recovery (general or `recover mana`), out of combat, for
-- a necromancer with the skill, with HP still in the tapping zone. The zone floor sits a MIN-HP HYSTERESIS
-- below the bleed floor: right after we tap down TO the floor, HP sits AT it, and without this slack the
-- posture picker would read "HP low" and sleep — which binds the wound. Holding rest across that band keeps
-- the picker and the tap cooperating (no rest/sleep flap). We never actually bleed into the band (the tap
-- amount stops at the bleed floor); it's only reached by regen sitting us at the floor between taps.
-- Is mana LOW enough to be worth bleeding HP for? Measured against a FULL pool, not the recovery target:
-- the value of a tap is a topped-up mana bar, so "close" means close to FULL. We tap only when natural
-- regen would take more than LIFETAP_MANA_TICKS ticks to fill (a real deficit — ~a tick's worth or more),
-- and let mana finish for free otherwise. Measuring to the 90% recovery target instead used to block this:
-- with mana's fast regen, a 90-points-down pool sits <1 tick from the target and never tripped the gate.
-- No mana-regen rate known (rate 0 / no `show regen`) → nil ticks → treat as low: regen won't fill it.
local function lifetap_mana_low()
  local r = state.regen
  local mt = ticks_to_target(state.mana, state.maxmana, r and r.mana, 1.0)   -- ticks to reach FULL
  if mt == nil then return true end
  return mt > LIFETAP_MANA_TICKS
end

local function lifetap_mana_case()
  if not state.recover or state.fighting then return false end
  if state.lifetap_manafull then return false end                        -- game refused: mana already ~full
  if recovery and recovery.minions_only then return false end            -- minion-only recovery: never touch YOU
  if recovery and recovery.stat and recovery.stat ~= "mana" then return false end  -- `recover hp` must not bleed HP
  if not has_lifetap() then return false end
  local frac = (recovery and recovery.pct) or READY_PCT
  if pct(state.mana, state.maxmana) >= frac then return false end         -- mana already at target → done
  if not lifetap_mana_low() then return false end                        -- mana's close; wait it out (regen is faster than HP)
  return (state.hp or 0) > lifetap_floor_hp() - LIFETAP_MIN               -- in the tapping zone (with slack)
end

-- A bleed WORTH starting: the campaign is on, HP is above the start line (LIFETAP_START — we only open a
-- fresh tap with real surplus in hand, never near the floor), AND the chunk clears LIFETAP_MIN (a backstop
-- for tiny HP pools where even 75%→55% is only a few points). Note this is STRICTER than mana_case: between
-- taps HP sits below the start line but still in the campaign, so we keep resting without re-tapping.
local function lifetap_worth_it()
  return lifetap_mana_case()
     and pct(state.hp, state.maxhp) > LIFETAP_START
     and ((state.hp or 0) - lifetap_floor_hp()) >= LIFETAP_MIN
end

-- Force `rest` (never sleep) for the whole campaign — sleep binds the wound and cancels the bleed, and the
-- tap is the faster mana path. This is the loop fix: the posture picker and the tap agree instead of
-- fighting (sleep→cancel→regen→tap→sleep…). Posture-independent so it can WAKE us from sleep to rest.
lifetap_hold_rest = function() return lifetap_mana_case() end

-- Should we START a bleed RIGHT NOW? Worth doing AND we're awake (asleep can't tap). The timing gates
-- (post-refusal cooldown, send debounce) live in maybe_lifetap, not here.
local function lifetap_wanted()
  return lifetap_worth_it() and recovery_depth(state.position) < 2
end

-- The HP amount to bleed if we start now, or nil. "Max safe chunk": the whole surplus down to the floor.
local function lifetap_amount()
  if not lifetap_wanted() then return nil end
  return (state.hp or 0) - lifetap_floor_hp()
end

-- Run every prompt tick during recovery. START a bleed when one's worth doing; never stop one — the game
-- ends it (it can't overuse). Two timing gates before starting: don't retry during the post-"too weak"
-- cooldown, and don't re-issue until the last `lifetap` has been confirmed (or SEND_WAIT elapses) so a
-- slow round-trip doesn't make us fire it every tick.
local function maybe_lifetap()
  if state.lifetapping then return end                                          -- already bleeding; let the game end it
  local now = os.time()
  if state.lifetap_retry_at and now < state.lifetap_retry_at then return end    -- settling after a bind / "too weak"
  if (now - (state.lifetap_send_at or 0)) < LIFETAP_SEND_WAIT then return end   -- awaiting the last tap's confirm
  local amt = lifetap_amount()
  if amt and amt > 0 then
    send("lifetap " .. amt)
    state.lifetap_send_at = now
    if echo then echo(string.format(
      "\27[36m[recover]\27[0m tapping %d hp into mana (keeping you above %d%% hp)",
      amt, math.floor(LIFETAP_FLOOR * 100 + 0.5))) end
  end
end

-- The game bound the wound (the bleed spent its amount, or a posture change/combat ended it). Clear the
-- in-flight flag and, during a recovery, hold off LIFETAP_COOLDOWN seconds before opening another — a settle
-- so we don't instantly re-tap (and so we skip the "too weak" that tends to fire right after a bind). Pure +
-- exposed via _AA_TEST; the trigger below just calls it.
local function lifetap_bound()
  state.lifetapping = false
  if state.recover then state.lifetap_retry_at = os.time() + LIFETAP_COOLDOWN end
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
-- Skeletal minions can only heal via a cast, but a cast still costs mana — so when YOUR mana is critically
-- low, don't drain it further on minions; recover your own mana first and heal them once it climbs back.
-- Lower than SELF_CAST_MANA_MIN because minion heals are more essential (skeletons have no natural regen).
local MINION_HEAL_MANA_MIN = 0.30

-- ticks_to_target(cur,max,rate,frac) — ticks of natural regen to reach frac*max. 0 if already there;
-- nil when we have no positive rate (→ "unknown", never treated as slow-enough-to-cast). Forward-declared
-- above (the lifetap block consults it), so this ASSIGNS the upvalue rather than shadowing it.
ticks_to_target = function(cur, max, rate, frac)
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
local function reset_regen_query() regen_query_pending = false end   -- test seam (the after() backstop is a no-op in tests)

-- ---- regen cache -------------------------------------------------------------------------------
-- `show regen` only reports the CURRENT posture (and reflects sharp), and the numbers only drift with
-- level / equipment / age — so cache each result keyed by (posture bucket, sharp) and reuse it instead
-- of re-querying every posture change. Busted two ways, both checked at LOOKUP (no event trigger needed):
--   * LEVEL: each entry records the total level it was measured at (summed from state.classes, which we
--     already scrape from `level`/`score` and persist) — a level change invalidates it automatically.
--   * AGE: entries older than REGEN_TTL (2 real days) are re-queried. Persisted across sessions so the
--     TTL is meaningful. Sharp itself is tracked in memory (the sharp up/down lines + show regen's prefix).
local REGEN_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/regen_cache.lua"
local REGEN_TTL  = 2 * 24 * 3600            -- 2 days, real seconds
local regen_cache = {}                       -- key "bucket:sharp" -> { hp, mana, move, at, lvl }

-- Total character level = sum of the per-class levels we scraped (0 until `level`/`score` is seen).
local function total_level()
  local n = 0
  for _, c in pairs(state.classes or {}) do n = n + (c.level or 0) end
  return n
end
-- Cache key. Posture collapses to its regen tier (standing/resting/sleeping via recovery_depth), so
-- sitting≡resting. nil when sharp is UNKNOWN (never seen a regen/sharp line) → forces a fresh query.
local function regen_key(posn, sharp)
  if sharp == nil then return nil end
  return recovery_depth(posn) .. ":" .. (sharp and "1" or "0")
end
local function regen_fresh(entry)
  return entry and entry.at and (os.time() - entry.at) < REGEN_TTL and (entry.lvl or 0) == total_level()
end

local function save_regen_cache()
  local f = io.open(REGEN_FILE, "w"); if not f then return end
  local parts = {}
  for k, v in pairs(regen_cache) do
    parts[#parts + 1] = string.format("[%q]={hp=%d,mana=%d,move=%d,at=%d,lvl=%d}",
      k, v.hp or 0, v.mana or 0, v.move or 0, v.at or 0, v.lvl or 0)
  end
  f:write("return {" .. table.concat(parts, ",") .. "}")
  f:close()
end
local function load_regen_cache()
  regen_cache = {}
  local chunk = loadfile and loadfile(REGEN_FILE)
  if not chunk then return end
  local ok, t = pcall(chunk)
  if ok and type(t) == "table" then
    for k, v in pairs(t) do
      if type(v) == "table" then regen_cache[k] = { hp = v.hp, mana = v.mana, move = v.move, at = v.at, lvl = v.lvl } end
    end
  end
end

-- Store a freshly-parsed regen line in the cache (keyed by the line's own posture + the sharp it reported).
local function cache_regen(posn, sharp, hp, mana, move)
  local key = regen_key(posn, sharp)
  if not key then return end
  regen_cache[key] = { hp = hp, mana = mana, move = move, at = os.time(), lvl = total_level() }
  save_regen_cache()
end

-- Make state.regen reflect the current posture+sharp: use a fresh cached `show regen` if we have one (no
-- round-trip — the cast decision gets data immediately), else query the game (the parse caches it).
local function ensure_regen()
  local key = regen_key(state.position, state.sharp)
  local entry = key and regen_cache[key]
  if regen_fresh(entry) then
    state.regen = { hp = entry.hp, mana = entry.mana, move = entry.move, position = state.position }
  else
    query_regen()
  end
end

load_regen_cache()   -- warm the cache from disk (stale/level-mismatched entries are filtered at lookup)

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

local ARTICLES = { a = true, an = true, the = true }
-- Ordered candidate target keywords for a minion, distinctive noun FIRST (the last word, which usually
-- works) then the earlier descriptive words, articles dropped. "a clay man" -> {"man","clay"}. The game
-- rejects a keyword that doesn't name anything here ("'man' isn't a valid target ..."), so when the
-- primary word is refused we walk this list to find one the game accepts (a clay man answers to 'clay').
local function minion_target_words(name)
  local words = {}
  for w in (name or ""):gmatch("%S+") do
    local lw = w:lower()
    if not ARTICLES[lw] then words[#words + 1] = lw end
  end
  local out = {}
  for i = #words, 1, -1 do out[#out + 1] = words[i] end
  return out
end

-- () -> bool: are YOUR own vitals at the recovery target? (stat_ready against the active threshold.)
local function player_recovered()
  return stat_ready(recovery and recovery.pct or nil)
end

-- Should we spend mana casting a heal on this minion RIGHT NOW? Skeletal/bone constructs always — they
-- have no natural regen, so a cast is the only way their HP comes back. Everything else of OURS (the
-- flesh beast / clay man tank, summoned pets) ONLY once YOU are fully recovered: then there's surplus
-- mana, so top the tank off with bolster/soothe instead of idling while it slowly self-regens (the
-- old "standing, waiting on your minions to regen" case). Gated on the M group flag so we never start
-- healing OTHER players in the group — only our own minions. (`f`, if given, is the minion's HP frac,
-- to avoid recomputing pct.)
local function minion_heal_eligible(m, f)
  if is_self_row(m) then return false end
  f = f or pct(m.hp, m.maxhp)
  if f >= minion_ready_target(m) then return false end
  if minion_needs_spell_heal(m.name) then return true end            -- skeletal: always (no natural regen)
  if (m.flags or ""):find("M", 1, true) == nil then return false end -- only OUR minions (M) get surplus heals
  return player_recovered()                                          -- natural-regen: only when you're topped off
end

-- () -> bool: any minion we should be casting a heal on right now — skeletal always, our natural-regen
-- minions once you're topped off. Keeps the recovery posture at rest (awake to cast) rather than asleep.
minions_pending_spell_heal = function()
  for _, m in ipairs(state.group or {}) do
    if minion_heal_eligible(m) then return true end
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
-- `tried[name]` = set of keywords the game refused as invalid for that minion this recovery; `word_blocked
-- [name]` = we exhausted its keywords and gave up healing it (both keyed by minion NAME, since the failing
-- thing is the keyword, not a room ordinal — distinct from `blocked[word]`, the topped-off refuse backstop).
local minion_heal = { casting = false, sweep = {}, blocked = {}, tried = {}, word_blocked = {},
                      refuse_streak = 0, token = 0, last = nil }

reset_minion_heal = function()
  minion_heal.casting, minion_heal.refuse_streak = false, 0
  minion_heal.sweep, minion_heal.blocked, minion_heal.last = {}, {}, nil
  minion_heal.tried, minion_heal.word_blocked = {}, {}
  minion_heal.self_hp_blocked, minion_heal.self_stam_blocked = false, false
  minion_heal.token = minion_heal.token + 1   -- kill any in-flight timeout
end

-- The next candidate keyword for `name` we haven't already had the game refuse this recovery (nil once
-- every keyword has been tried — the minion then gets word_blocked and skipped).
local function next_untried_word(name)
  local tried = minion_heal.tried[name]
  for _, w in ipairs(minion_target_words(name)) do
    if not (tried and tried[w]) then return w end
  end
  return nil
end

-- Pick the most-hurt heal-eligible minion still below its ready target (skipping any keyword we gave up
-- on). Eligibility (minion_heal_eligible) is skeletal-always plus our natural-regen minions once you're
-- topped off, so a full player rolls straight onto healing the tank rather than just waiting on it.
local function most_hurt_spell_minion()
  local best, best_frac
  for _, m in ipairs(state.group or {}) do
    local f = pct(m.hp, m.maxhp)
    if minion_heal_eligible(m, f) and not minion_heal.blocked[minion_target_word(m.name)]
       and not minion_heal.word_blocked[m.name] then
      if not best_frac or f < best_frac then best, best_frac = m, f end
    end
  end
  return best, best_frac
end

-- Does the game's target keyword `word` REACH this minion? Normally a minion answers to its last word
-- (mage/spider/…), so the match is exact. BUT "skeleton" is a keyword shared by EVERY skeletal minion (a
-- skeletal mage/spider IS a skeleton), so a bare "A skeleton" — whose only distinctive word is "skeleton"
-- — can't be singled out: `skeleton` matches the whole skeletal family. We must therefore SWEEP across all
-- of them to reach it. This is the bug where healing a bare skeleton kept hitting the full mage: the count
-- below saw only ONE "skeleton" (K=1 → no ordinal), so every cast went to `skeleton` = the first skeletal
-- creature the game found (the mage), never the hurt one. (The player's own logs use `2.skeleton`.)
local function keyword_matches(word, name)
  if word == "skeleton" then return (name or ""):lower():find("skelet", 1, true) ~= nil end
  return minion_target_word(name) == word
end

-- Count group members the keyword REACHES (so ordinals 1..K line up with the room's N.keyword), skipping
-- yourself. For a family keyword like "skeleton" this is every skeletal minion, not just bare skeletons.
local function keyword_count(word)
  local n = 0
  for _, m in ipairs(state.group or {}) do
    if not is_self_row(m) and keyword_matches(word, m.name) then n = n + 1 end
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
  -- Mana too low to spend on minions: don't drain it further (recover YOUR mana first). The skeletal minion
  -- stays hurt for now — recovery keeps resting, and once mana climbs back above the floor we heal it. We
  -- do NOT fall through to a self-cast: those need even MORE mana (SELF_CAST_MANA_MIN), so also no-op here.
  if pct(state.mana, state.maxmana) < MINION_HEAL_MANA_MIN then return end
  local word = next_untried_word(m.name)
  if not word then                          -- every keyword refused: give up on this minion, move on
    minion_heal.word_blocked[m.name] = true
    try_cast_heal(); return
  end
  local K = keyword_count(word)
  local target = word
  local ord
  if K > 1 then
    ord = minion_heal.sweep[word] or 1
    if ord > K then ord = 1 end
    target = ord .. "." .. word
  end
  local spell = (f < BOLSTER_BELOW) and "bolster" or "soothe"
  minion_heal.last = { word = word, ord = ord, K = K, kind = "minion", name = m.name }
  minion_heal.casting = true
  send("c " .. spell .. " " .. target)
  arm_cast_backstop()
end

-- Spend surplus mana on YOUR own lagging vitals — one cast, paced like the minion driver. hp is tried
-- before stamina (survivability first). Each stat is gated by cast_beats_waiting (regen vs mana cost),
-- and a stat we've given up on this recovery (self_*_blocked, set on a refuse) is skipped. Self-heals
-- need your name; refresh is self by default and can't be cast in combat (recovery isn't, but guard).
-- Decide the single self-cast to make right now, or nil. PURE (no send/narrate) so choose_recovery_position
-- can ask "would we actually cast?" to pick rest-to-cast vs sleep-for-sharp. hp before stamina.
pick_self_cast = function()
  if not self_cast_wanted() then return nil end
  local frac = (recovery and recovery.pct) or READY_PCT
  local st   = recovery and recovery.stat
  local r    = state.regen
  if (st == nil or st == "hp") and not minion_heal.self_hp_blocked and state.name then
    local hpf = pct(state.hp, state.maxhp)
    if hpf < frac and cast_beats_waiting(state.hp, state.maxhp, r and r.hp, HEAL_COST) then
      return { stat = "hp", label = "hp", spell = (hpf < BOLSTER_BELOW) and "bolster" or "soothe",
               target = state.name, pctv = hpf, ticks = ticks_to_target(state.hp, state.maxhp, r and r.hp, frac) or 0,
               kind = "self_hp" }
    end
  end
  if (st == nil or st == "stam") and not minion_heal.self_stam_blocked and not engaged() then
    local spf = pct(state.stam, state.maxstam)
    if spf < frac and cast_beats_waiting(state.stam, state.maxstam, r and r.move, REFRESH_COST) then
      return { stat = "stam", label = "stamina", spell = "refresh", target = nil, pctv = spf,
               ticks = ticks_to_target(state.stam, state.maxstam, r and r.move, frac) or 0, kind = "self_stam" }
    end
  end
  return nil
end

try_self_cast = function()
  local pick = pick_self_cast()
  if not pick then
    -- Wanted a stat but not casting. Stay QUIET while we're still gathering sharp (the posture channel
    -- already says "sleeping to get sharp") — only explain the wait once we're sharp and still declined,
    -- so the two channels never contradict each other.
    if self_cast_wanted() and state.sharp then
      if not state.regen then
        narrate("cast", "nodata", "no regen numbers yet — I'll check `show regen` and decide once I have them")
      else
        narrate("cast", "wait", "sharp now and natural regen is fast enough — not worth spending mana")
      end
    end
    return
  end
  narrate("cast", pick.stat, string.format("casting %s%s — %s %d%% is ~%d ticks of regen away; mana to spare",
    pick.spell, (pick.stat == "hp") and " on yourself" or "", pick.label,
    math.floor(pick.pctv * 100 + 0.5), math.ceil(pick.ticks)))
  minion_heal.last = { kind = pick.kind }
  minion_heal.casting = true
  send("c " .. pick.spell .. (pick.target and (" " .. pick.target) or ""))
  arm_cast_backstop()
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
for _k, _v in pairs({ ready = ready, pct = pct, READY_PCT = READY_PCT,
             stat_ready = stat_ready, one_stat_ready = one_stat_ready, STAT_ALIASES = STAT_ALIASES,
             choose_recovery_position = choose_recovery_position, recovery_depth = recovery_depth,
             recovery = recovery, end_recovery = end_recovery,
             maybe_complete_recovery = maybe_complete_recovery,
             minion_needs_spell_heal = minion_needs_spell_heal, minion_target_word = minion_target_word,
             minion_target_words = minion_target_words, next_untried_word = next_untried_word,
             keyword_count = keyword_count, keyword_matches = keyword_matches,
             minions_pending_spell_heal = minions_pending_spell_heal, all_minions_ready = all_minions_ready,
             minion_heal = minion_heal, try_cast_heal = try_cast_heal,
             MINION_HEAL_MANA_MIN = MINION_HEAL_MANA_MIN,
             minion_cast_settled = minion_cast_settled, reset_minion_heal = reset_minion_heal,
             reset_posture = reset_posture,
             ticks_to_target = ticks_to_target, cast_beats_waiting = cast_beats_waiting,
             self_cast_wanted = self_cast_wanted, try_self_cast = try_self_cast,
             lifetap_wanted = lifetap_wanted, lifetap_amount = lifetap_amount,
             lifetap_mana_case = lifetap_mana_case, lifetap_worth_it = lifetap_worth_it,
             lifetap_hold_rest = lifetap_hold_rest, maybe_lifetap = maybe_lifetap,
             lifetap_bound = lifetap_bound, lifetap_floor_hp = lifetap_floor_hp,
             lifetap_mana_low = lifetap_mana_low,
             LIFETAP_START = LIFETAP_START, LIFETAP_COOLDOWN = LIFETAP_COOLDOWN,
             LIFETAP_MANA_TICKS = LIFETAP_MANA_TICKS,
             has_lifetap = has_lifetap, LIFETAP_FLOOR = LIFETAP_FLOOR, LIFETAP_MIN = LIFETAP_MIN,
             pick_self_cast = pick_self_cast, reset_narration = reset_narration,
             regen_cache = regen_cache, regen_key = regen_key, regen_fresh = regen_fresh,
             total_level = total_level, ensure_regen = ensure_regen, cache_regen = cache_regen,
             reset_regen_query = reset_regen_query, REGEN_TTL = REGEN_TTL }) do _AA_TEST[_k] = _v end

-- Lifetap bleed state (drives maybe_lifetap's start/stop transitions). The bleed begins on the cut, and
-- ends when the game binds the wound (falling asleep, or finishing the requested amount both print the bind
-- line). The confirm/refusal lines also clear the send debounce (state.lifetap_send_at) so the next tap
-- can go out immediately once this one resolves.
trigger([[^You make a shallow yet bloody cut and begin tapping your life\.]], function()
  state.lifetapping, state.lifetap_send_at = true, 0   -- confirmed: a fresh bleed is running
end)
trigger([[^You will now tap \d+ hitpoints from this point on\.]], function()
  state.lifetapping, state.lifetap_send_at = true, 0   -- confirmed: adjusted an already-running bleed
end)
trigger([[^You are busy tapping your life for mana\.]], function()
  state.lifetapping = true               -- defensive: a bleed is running even if we missed the start line
end)
trigger([[^You quickly bind your wound and stop tapping your life\.]], function()
  lifetap_bound()                        -- game ended the bleed → clear the flag + start the settle cooldown
end)
-- Transient refusal: right after a posture change you can be momentarily "too weak" to start a tap even
-- with HP to spare (it clears as you settle/regen — a slightly larger tap a moment later often works). Back
-- off for LIFETAP_RETRY seconds rather than re-issuing every tick. Guarded to recovery, since this generic
-- line can come from other failed actions too.
trigger([[^You are too weak to do that right now\.]], function()
  if not state.recover then return end
  state.lifetapping, state.lifetap_send_at = false, 0
  state.lifetap_retry_at = os.time() + LIFETAP_RETRY
end)
-- The game refuses the bleed when mana is essentially capped. Nothing bled, so HP/mana won't move — set a
-- suppression flag (cleared at the next recovery boundary) so we don't re-issue `lifetap` every tick.
trigger([[^Your mana is already almost full\.]], function()
  state.lifetapping, state.lifetap_send_at, state.lifetap_manafull = false, 0, true
end)

-- Recovery-cast pacing: settle the outstanding cast on the game's own reply lines (see the recovery
-- block above). Anchored so another player's speech can't spoof them. The construct wording ("repair the
-- damage to X's body") is minion-only; the "feel ..." lines are self-casts; fail/refuse route by
-- last.kind inside minion_cast_settled (bolster/soothe are shared between self and minions).
-- Each reply line -> the settle outcome it signals. minion_cast_settled routes fail/refuse by last.kind
-- (self vs minion), so one flat table covers both. "ok" for the construct-repair (minion) AND the self
-- "feel ..." lines; "full"/"notgt" advance the ordinal sweep.
local CAST_REPLIES = {
  { [[^You repair the damage to .+'s body\.$]],                          "ok" },     -- minion heal landed
  { [[^You feel less tired\.$]],                                         "ok" },     -- refresh, self
  { [[^You feel a little better\.$]],                                    "ok" },     -- soothe, self
  { [[^You will your injuries to heal and your soul to take courage\.$]], "ok" },    -- bolster, self
  { [[^You fail to cast the spell '(soothe wounds|bolster|refresh)'\.$]], "fail" },  -- fizzle -> retry
  { [[^.+ doesn't need that much healing right now\.$]],                  "full" },  -- too full / wrong ordinal
  { [[^If you really want to cast that on yourself, you must use your name\.$]], "notgt" },
}
for _, r in ipairs(CAST_REPLIES) do
  local kind = r[2]
  trigger(r[1], function() minion_cast_settled(kind) end)
end

-- The game refuses a heal whose TARGET KEYWORD names nothing here — "Sorry, 'man' isn't a valid target
-- for the spell 'soothe wounds'." (a "clay man" answers to 'clay', not 'man'). CAST_REPLIES never matched
-- this, so the cast hung on its 3s backstop and re-fired the SAME dead keyword forever. Recover by trying
-- the minion's other name-words in turn (next_untried_word); once every keyword has been refused, give up
-- on healing THAT minion for this recovery and skip it (word_blocked) — narrating both steps. Recovery
-- itself keeps going (the driver rolls to the next minion / self-cast). Guarded to our own minion cast:
-- the same line during combat (a mis-targeted attack spell) leaves minion_heal.casting false and is ignored.
local function minion_target_invalid(word)
  if not minion_heal.casting then return end
  local last = minion_heal.last
  if not (last and last.kind == "minion" and last.name) then return end   -- not our minion cast; let the backstop handle it
  minion_heal.casting = false
  minion_heal.token = minion_heal.token + 1        -- a reply beat the timeout; invalidate it
  local name = last.name
  local bad = last.word or word
  minion_heal.tried[name] = minion_heal.tried[name] or {}
  minion_heal.tried[name][bad] = true
  local nextw = next_untried_word(name)
  if nextw then
    echo("\27[33m[recover] '" .. bad .. "' isn't a target for " .. name .. "; trying '" .. nextw .. "'.\27[0m")
  else
    minion_heal.word_blocked[name] = true
    echo("\27[33m[recover] no working keyword to heal " .. name .. " — giving up on it this recovery.\27[0m")
  end
  try_cast_heal()
end
trigger([[^Sorry, '([^']+)' isn't a valid target for the spell '[^']+'\.$]],
  function(_, word) minion_target_invalid(word) end)
_AA_TEST.minion_target_invalid = minion_target_invalid

-- `show regen` — regen per tick at the CURRENT posture, drives the recovery cast-vs-wait decision.
-- Two forms: with the "feel sharp" prefix (the sharp buff, from sleeping a while → faster regen) and
-- without. We gag ONLY our own auto-query (query_regen sets regen_query_pending); a manual `show regen`
-- the player typed still prints.
trigger([[^You (feel sharp, and )?currently gain (\d+) hitpoints, (\d+) mana, and (\d+) movement while (\w+)\.$]],
  function(_, sharp, hp, mana, move, posn)
    local is_sharp = (sharp ~= nil and sharp ~= "")
    local H, M, V = tonumber(hp), tonumber(mana), tonumber(move)
    state.sharp = is_sharp
    state.regen = { hp = H, mana = M, move = V, position = posn }
    cache_regen(posn, is_sharp, H, M, V)   -- remember it (keyed by this line's posture + sharp)
    if regen_query_pending then regen_query_pending = false; return false end   -- gag our auto-query
  end)
-- Sharp up/down. Sharp changes every regen rate, so refresh state.regen (from cache or a query) while recovering.
trigger([[^You find yourself feeling sharp and ready to take on anything!$]], function()
  state.sharp = true; if state.recover then ensure_regen() end
end)
trigger([[^You no longer feel sharp and at your best\.$]], function()
  state.sharp = false; if state.recover then ensure_regen() end
end)

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
  reset_narration()     -- fresh recovery re-narrates its decisions from scratch
  choose_recovery_position()
  -- Kick the recovery-cast driver (heals skeletal minions on a full recovery, and/or spends surplus mana
  -- on your own vitals). It internally respects the mode: minion-only skips self, single-stat skips
  -- minions, `recover mana` casts nothing (no spell makes mana).
  heal_minions_kick()
  -- Get current-posture regen numbers (from cache, else a gagged query) so cast-vs-wait has data —
  -- unless this is minion-only.
  if not recovery.minions_only then ensure_regen() end
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

-- ---- Protocol -> recovery hooks -----------------------------------------------------------------
-- AlterAeon.lua parses the kxwt fields into `state` and, once done, calls these so the recovery state
-- machine (all upvalues in THIS file) can react — keeping protocol parsing and recovery logic in
-- separate files without exposing the machinery. All `__`-prefixed (internal; doc-exempt) and guarded
-- at the call site, so a not-yet-loaded Recovery.lua is simply inert.

function __recovery_on_vitals()          -- kxwt_prompt: complete recovery, then bleed surplus hp->mana
  maybe_complete_recovery()
  if state.recover then maybe_lifetap() end
end

function __recovery_on_position(p, changed)   -- kxwt_position: re-issue posture / refresh per-posture regen
  if state.recover and recovery_depth(p) == 0 then choose_recovery_position() end
  if state.recover and changed and (not state.regen or state.regen.position ~= p) then ensure_regen() end
end

function __recovery_on_group()           -- kxwt_group_end: (re)pick the next minion heal + re-check done
  heal_minions_kick(); maybe_complete_recovery()
end

function __recovery_on_spellup(s)        -- kxwt_spellup: the recast we woke for landed — release the hold
  if recovery and recovery.await_spell == s then recovery.await_spell, recovery.await_until = nil, nil end
end

function __recovery_on_spelldown(s)      -- kxwt_spelldown: buff dropped mid-sleep — drop to rest for the recast
  if state.recover and state.position == "sleeping" and pct(state.mana, state.maxmana) > 0.3 then
    send("rest"); state.position = "sitting"
    if recovery then recovery.await_spell, recovery.await_until = s, os.time() + SPELLUP_WAIT end
  end
end

function __recovery_cancel(reason)       -- a move / a fight interrupts recovery (reject the promise)
  end_recovery(false, reason)
end

function __ready(p) return ready(p) end  -- describe_state's " (ready)" label (AlterAeon.lua)
