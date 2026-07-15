-- Deterministic (no AI/model) auto-fight combat script for AlterAeon — a rule-based state machine.
--
-- This is INDEPENDENT of the AI pilot (AIPilot.lua). It never calls a model; it just reacts to the
-- combat wire protocol with a fixed opener→probe→nuke→finish routine, opt-in and OFF by default.
--
-- THE ROUTINE (per fight, driven off kxwt_fighting + a few combat lines):
--   0. OPENER:           bloodmist when HP is healthy (> cfg.bloodmist_hp_min — it costs hp to cast), else
--                        the free tarrants. (A known-winner target skips straight past the probe below.)
--   1. PROBE:            on COMBAT START, cast the PRIMARY probes lightning bolt (once) then fireball (once);
--                        compare how much each dropped the enemy's health %; the bigger drop WINS. (Coarse %
--                        heuristic — fine.) If NEITHER primary cleared cfg.probe_enough, also try the
--                        FALLBACK probes icebolt then prism (once each), then pick among all four — icebolt/
--                        prism are rarely best, so we only pay for them when both primaries flopped.
--   2. NUKE:             keep casting the WINNER until the enemy is dead.
--   3. FINISH:           when the enemy is NEARLY dead (<= cfg.soulsteal_pct), cast soulsteal. If it's
--                        RESISTED, nuke once more with the winner then retry soulsteal — repeat until it
--                        lands or the enemy dies. If instead soulsteal LATCHES ("You magically latch
--                        onto <x>'s soul and wait for <x> to weaken…" — the dormant/dread-portent form),
--                        the soul isn't captured yet: keep nuking the winner (do NOT re-cast soulsteal)
--                        until the latch fires as the target drops.
--   4. SUSPEND:          any command the USER types (not one WE sent) suspends the script so they can
--                        intervene; it resumes after cfg.resume_after seconds of no manual input, or when
--                        the fight ends.
--
-- PACING (the important bit — NEVER spam, and NEVER timed): a cast goes out inside a stage, which then
-- awaits that spell's own success line (it LANDED) before the NEXT stage is built — so only one cast is
-- ever outstanding. The await IS the gate: it's the only live subscription, so nothing else can advance.
-- A FAIL ("You fail to cast…", or a resist) re-sends the SAME spell (up to cfg.max_tries). The enemy
-- health bar (kxwt_fighting) feeds a SEPARATE stream (drop accounting only) and never casts — casting on
-- every tick was the command-spam bug. Out-of-mana halts the stage and we WAIT (no retry, no spam).
--
-- NOTE: the opener is `c bloodmist` when HP is above cfg.bloodmist_hp_min (a blood demon — landed line
-- "You tap your life, and a blood red winged demon flaps quickly toward <target>!"; it costs hp, hence the
-- gate), else `c tarrants` (tarrant's spectral hand — "An ethereal hand appears and attacks <target> from
-- behind!"). Both are confirmed against the help corpus + live logs.
--
-- Wire strings below are VERBATIM from the player's raw logs (mud_raw_copy.log / mud_raw_nomelee.log),
-- not invented. See Scripts/tests/autofight_spec.lua, which replays a real Gnomian-guard fight.
--
-- ARCHITECTURE (promise + reactive): the STREAMS the fight reacts to — the spell-landed/failed lines,
-- soulsteal outcomes, out-of-mana, combat start/end, user input — are Observables (see the flow block
-- and the fromTrigger block below). The SEQUENCE is a PROMISE flow, not a phase machine:
--
--     combatStart$ :switchMap(target -> opener(target)          -- resolves when the opener LANDS
--                                         :andThen(afterOpener)) -- probe (resolves WITH the winner) → nuke/finish
--                  :takeUntil(enemyDead$)                        -- DEAD/kxwt-1/rollover end the inner flow
--
-- Each stage resolves off its event stream; the probe verdict FLOWS as the resolve value into fightLoop.
-- Pacing/retry/suspend fall out of the structure: a cast only goes out inside a stage, the next stage
-- isn't built until the current one resolves on its landed line, and "the in-flight cast's await is the
-- only live subscription" IS the busy gate — the health bar never touches the flow. The fight as a whole
-- is ALSO surfaced as a chainable PROMISE via attack()/autofight.current() (recover(95).andThen(attack('orc'))).
--
-- Controls:  autofight.on() · autofight.off() · autofight.status();  help(autofight). Hot-reloadable.

state = state or {}   -- defensive: this file may load before AlterAeon.lua under the directory loader.

-- Reactive core (__rx): the fight REACTS to streams — the enemy health bar, the spell landed/failed
-- lines, combat start/end, user input — modelled as Observables built on rx.fromTrigger (see the stream
-- block near the bottom). The promise layer (__promise, loaded by the directory loader) surfaces a whole
-- fight as a chainable promise (attack()/autofight.current()). `_`-prefixed files aren't auto-loaded, so
-- pull _rx here the documented way (dofile fallback for the bare Lua test harness).
pcall(require, "_rx")
if not __rx then dofile("Scripts/_rx.lua") end

pcall(require, "_persist")
if not __persist then dofile("Scripts/_persist.lua") end
local persist = __persist

local cfg = {
  -- PACING IS PURELY EVENT-DRIVEN, NEVER TIMED. After we send a cast we go `busy` and send NOTHING
  -- until we see that SPELL's own success line (it LANDED) or a failure line (retry). The enemy
  -- health-bar (kxwt_fighting) updates many times a second and must NEVER trigger a cast — that was
  -- the spam bug. There is no timeout.
  max_tries       = 4,   -- consecutive failures on one spell before we give up on it and move on
  resume_after    = 6,   -- seconds of no manual input before the script resumes after a user command
  soulsteal_pct   = 15,  -- enemy health % at/below which we switch to soulsteal ("nearly dead")
  new_target_jump = 20,  -- a health bar that jumps UP by >= this many points mid-combat = a NEW target
                         -- (a mob we're already fighting only trends down); triggers a fresh start
  aoe_min         = 2,   -- >= this many engaged enemies (seen in the room, e.g. on a look) = a pack → AOE
  room_burst      = 2,   -- seconds: window to tally a room-listing burst's "X is here, fighting Y" lines
  -- Exact commands to send. In-combat casts auto-target the current enemy, so these go out bare.
  opener_tarrants  = "c tarrants",   -- tarrant's spectral hand — the DEFAULT opener (see NOTE at top)
  bloodmist_cmd    = "c bloodmist",  -- summons a blood demon; used as the opener when HP is healthy — it
                                     -- COSTS hp to cast, so we only lead with it above bloodmist_hp_min
  bloodmist_hp_min = 0.5,            -- only open with bloodmist when HP is ABOVE this fraction of max
  lightning_cmd    = "cast 'lightning bolt'",  -- LIGHTNING; a PRIMARY probe/nuke (tried every fight, with fireball)
  icebolt_cmd      = "c icebolt",    -- COLD; a FALLBACK probe now — only tried if lightning+fireball underwhelm
  fireball_cmd     = "c fireball",   -- the FIRE probe/nuke (PRIMARY, tried every fight)
  prism_cmd        = "c prism",      -- LIGHT; a FALLBACK probe — only tried when lightning+fireball both underwhelm
  probe_enough     = 5,              -- % health a single PRIMARY (lightning/fireball) hit must clear to SKIP the
                                     -- icebolt/prism fallback probes (they're rarely best, so don't bother
                                     -- trying them if a primary already hits hard)
  fireball_bias    = 5,              -- percentage-points: fireball is the PREFERRED winner (splash/AOE bonus) —
                                     -- any other spell must beat fireball's %-drop by AT LEAST this much to win
                                     -- the pick instead (err toward fireball; lightning must beat it HANDILY)
  soulsteal_cmd    = "c soulsteal",
  aoe_cmd          = "c frostflower",-- room AOE, used instead of the single-target probe/nuke on a pack
  -- DORMANT: shower was the 2nd probe before scorch. Kept (with its landed trigger + hit_shower() below)
  -- so its wire strings survive for a future feature — mana-aware spell switching as we run low. The
  -- routine never casts it, so this string is unused today; nothing sends it.
  shower_cmd       = "c shower",     -- shower of sparks
  -- Tank rescue (autofight.tank): re-summon a dead clay-man/flesh-beast tank.
  clay_cmd         = "cast 'clay man'", -- summon a clay man to tank ("You add A clay man to your group." on success)
  clay_retry       = 4,   -- seconds between re-summon attempts (a success line stops the loop early)
  clay_max_tries   = 8,   -- backstop: give up after this many (e.g. no clay/dirt in the room to shape)
}

-- Survive pilot.reload(): keep the on/off toggle and any in-flight fight state in a global. Armed by
-- default on a FRESH session (`on = true`); a live reload preserves whatever you last toggled it to,
-- so an explicit autofight.off() sticks across reloads within a session.
_AUTOFIGHT = _AUTOFIGHT or { on = true }
local F = _AUTOFIGHT
-- Default the runtime fields (idempotent across reloads).
F.fighting          = F.fighting or false
F.phase             = F.phase or "idle"   -- coarse label for status() only; the flow no longer switches on it
F.suspended         = F.suspended or false
F.self_sent         = F.self_sent or {}     -- cmd -> count of sends WE issued (echo/suspend disambiguation)
F.no_mana           = F.no_mana or {}       -- spell -> true once we've been told we can't afford it
F.lightning_drop    = F.lightning_drop or 0
F.icebolt_drop      = F.icebolt_drop or 0
F.fireball_drop     = F.fireball_drop or 0
F.prism_drop        = F.prism_drop or 0
F.fallback_tried    = F.fallback_tried or false   -- did we already run the icebolt/prism fallback probes this fight?
F.finish_ready      = F.finish_ready or false     -- authoritative "target near death" latch: switch to soulsteal
-- engage() state: initiating a fight from out of combat by casting the opener (`target x` alone doesn't
-- aggro). `engaging` is true from the first opener cast until combat actually starts; `opener_primed`
-- tells start_fight the tarrants opener was already thrown so it skips straight to the probe.
F.engaging          = F.engaging or false
F.engage_busy       = F.engage_busy or false
F.engage_tries      = F.engage_tries or 0
F.opener_primed     = F.opener_primed or false
F.on_dead           = F.on_dead or nil      -- called once when an engaged fight ends
F.on_fail           = F.on_fail or nil      -- called if we can't get the opener to land
-- "Real combat actually started this engagement" latch. Set the moment kxwt_fighting begins the fight
-- (start_fight); it OUTLIVES the DEAD line, which clears F.fighting via end_fight BEFORE the trailing
-- `kxwt_fighting -1` reaches on_fight_end. Guarding on_dead's fire on F.fought (not the already-cleared
-- F.fighting) is what fixes `recover | attack <x>` leaking its promise row: the attack() resolver ran off
-- F.fighting, which DEAD had zeroed, so on_dead never fired and the pipe row never resolved.
F.fought            = F.fought or false
F.soul_latched      = F.soul_latched or false  -- dormant soulsteal latched; keep nuking, don't re-cast it
-- AOE (crowd) handling. `aoe_mode` is a preference that survives reload: "auto" uses frostflower once we
-- know it's a pack, "on" always AOEs, "off" never does. `pack` is this-combat belief that there are
-- multiple enemies — set when a kill rolls straight onto another target (no kxwt -1), cleared when
-- combat truly ends. See aoe_active().
F.aoe_mode          = F.aoe_mode or "auto"
F.pack              = F.pack or false
F.room_seen         = F.room_seen or 0      -- tally of hostile "is here, fighting" lines in the current burst
F.enemy_est         = F.enemy_est or 0      -- estimated engaged hostiles: set by a look, counted down by deaths
-- Each engagement is a tracked promise (shows in the HUD widget, resolves when combat ends) — the
-- fight-as-a-promise surface, matching recover()/eq/corpse. `fight_settle` holds its resolve/reject
-- while a fight is live; `fight_promise` is the object (for autofight.current() chaining + retitling on
-- target rollover). NOT persisted across reload — the Promise layer is fresh then, so old handles are
-- stale; cleared unconditionally (not `or`).
F.fight_settle      = nil
F.fight_promise     = nil

-- Command capture, always on (cheap, cleared each fight) so the test harness can read the exact send
-- sequence without stubbing the host `send`. `_AF_TEST.sent` aliases this table.
local sent = {}
local function clear_sent() for i = #sent, 1, -1 do sent[i] = nil end end

local function say(s) if echo then echo("\27[1;35m[autofight]\27[0m " .. s) end end

-- ---- learned winners (per target NAME) -----------------------------------------------------------
-- Remember which probe spell won against a given target so the next fight against the same name skips
-- the icebolt/fireball probe and nukes the known winner straight away. Keyed by a normalized name (lower-
-- cased, leading article stripped) so "a Gnomian guard" / "The Gnomian guard" collapse to one entry.
-- Persisted to disk (mirrors AlterAeon's classes.lua) so it survives a relaunch; kept on _AUTOFIGHT so
-- it also survives a live pilot.reload().
local function winner_key(name)
  if not name then return nil end
  local k = tostring(name):lower():gsub("^%s+", ""):gsub("%s+$", "")
  k = k:gsub("^an? ", ""):gsub("^the ", "")     -- drop a leading "a "/"an "/"the "
  return (k ~= "" and k) or nil
end

-- THE two probe spells the routine compares (cold vs fire). Single source of truth: change these and
-- the persisted winners file MIGRATES on next load (see load below) instead of being wiped. To swap a
-- spell later (e.g. icebolt -> some newer cold spell), edit this + its _cmd + its landed trigger.
local PROBE_SPELLS = { "lightning", "icebolt", "fireball", "prism" }
local function is_probe_spell(s) for _, v in ipairs(PROBE_SPELLS) do if v == s then return true end end return false end
local function probe_spellset_key() local t = {}; for _, v in ipairs(PROBE_SPELLS) do t[#t + 1] = v end; table.sort(t); return table.concat(t, ",") end

local WINNERS_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/autofight_winners.lua"
-- File format v2: { spells = "<sorted probe set>", winners = { [name] = spell } }. v1 was a flat
-- { [name] = spell } (no `spells`); loaded transparently below.
local function save_winners()
  local parts = {}
  -- Only persist CURRENT probe-spell entries — never write a retired spell back (belt against a stale
  -- in-memory entry from a live reload that predates a spell swap).
  for name, spell in pairs(_AUTOFIGHT.winners) do
    if is_probe_spell(spell) then parts[#parts + 1] = string.format("[%q]=%q", name, spell) end
  end
  persist.write(WINNERS_FILE, string.format("return {[%q]=%q,[%q]={%s}}", "spells", probe_spellset_key(), "winners", table.concat(parts, ",")))
end
-- Debounce writes: coalesce a burst of updates into one save 2s after the last (same trick as classes).
local winners_save_timer
local function schedule_winners_save()
  if cancel and winners_save_timer then cancel(winners_save_timer) end
  winners_save_timer = after and after(2, save_winners) or nil
end
-- Given a raw winners table loaded from disk (or held over in-memory across a live reload) plus its
-- recorded spell-set key (nil for a v1 file / no prior key), decide what to KEEP. VERSIONED MIGRATION: a
-- spell-set change (e.g. scorch → fireball) makes the WHOLE table stale, not just the entries for the
-- retired spell — a still-current spell like lightning/icebolt/prism was picked as the winner by comparing
-- it against the OLD lineup (it beat scorch, not fireball), so that verdict can't be trusted either. So on
-- any mismatch we clear EVERYTHING and every target simply re-probes fresh; only a matching spell-set is
-- trusted as-is. Returns (kept, matched).
local function migrate_winners(raw, recorded)
  local matched = recorded == probe_spellset_key()
  local kept = {}
  if matched then
    for name, spell in pairs(raw or {}) do
      if is_probe_spell(spell) then kept[name] = spell end
    end
  end
  return kept, matched
end

-- Load from disk ONCE per session (not on a live reload, where _AUTOFIGHT.winners already holds the
-- current, possibly-newer table).
if not _AUTOFIGHT.winners then
  local raw, recorded = {}, nil
  local t = persist.load(WINNERS_FILE)
  if type(t) == "table" then
    raw = (type(t.winners) == "table") and t.winners or t   -- v2 has .winners; v1 was flat
    recorded = t.spells                                     -- nil for a v1 file
  end
  local kept, matched = migrate_winners(raw, recorded)
  _AUTOFIGHT.winners = kept
  if not matched then
    local n = 0
    for _ in pairs(raw) do n = n + 1 end
    if n > 0 then
      if echo then
        echo("\27[1;35m[autofight]\27[0m spell set changed → cleared all learned winners, re-probing every target.")
      end
      if after then after(0, save_winners) end   -- rewrite the (now empty) file in v2 form
    end
  end
  _AUTOFIGHT.winners_spellset = probe_spellset_key()   -- baseline for the every-load check below
end

-- Runs on EVERY load (not just a fresh one): a live `#pilot.reload()` after a spell-set change keeps the
-- old in-memory _AUTOFIGHT.winners (the `if not` above is skipped) — entries learned under the PREVIOUS
-- spell set are stale (even ones whose spell is still a current probe spell; see migrate_winners above),
-- so compare the remembered spell-set against the current one and clear the whole table on a mismatch.
do
  local key = probe_spellset_key()
  if _AUTOFIGHT.winners_spellset and _AUTOFIGHT.winners_spellset ~= key then
    local n = 0
    for _ in pairs(_AUTOFIGHT.winners) do n = n + 1 end
    _AUTOFIGHT.winners = {}
    if n > 0 then
      if echo then
        echo("\27[1;35m[autofight]\27[0m spell set changed → cleared all learned winners, re-probing every target.")
      end
      if after then after(0, save_winners) end
    end
  end
  _AUTOFIGHT.winners_spellset = key
end

-- Record (and persist) the probe's verdict for this target. Only writes on a real change.
local function remember_winner(name, spell)
  local key = winner_key(name)
  if not key or not is_probe_spell(spell) then return end
  if _AUTOFIGHT.winners[key] ~= spell then
    _AUTOFIGHT.winners[key] = spell
    schedule_winners_save()
    say(string.format("learned: %s → %s", key, spell))
  end
end

-- ---- learned "unstealable" targets (per target NAME) ---------------------------------------------
-- Some creatures can NEVER be soul-stolen: undead, constructs, and already-dead bodies have no soul, so
-- the game rejects the cast with "You can only soulsteal from living things." Casting soulsteal at one is
-- a wasted round EVERY fight against that type. Once we learn a name is soulless we persist it (a bare
-- name→true set, keyed by the same normalized winner_key as the winners table) and SKIP the soulsteal
-- stage entirely for that name forever after — just nuke it down. Survives a relaunch and a live reload
-- (kept on _AUTOFIGHT) exactly like the winners memory.
local UNSTEALABLE_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/autofight_unstealable.lua"
local function save_unstealable()
  local parts = {}
  for name in pairs(_AUTOFIGHT.unstealable) do parts[#parts + 1] = string.format("[%q]=true", name) end
  persist.write(UNSTEALABLE_FILE, "return {" .. table.concat(parts, ",") .. "}")
end
-- Debounce writes: coalesce a burst into one save 2s after the last (same trick as the winners file).
local unstealable_save_timer
local function schedule_unstealable_save()
  if cancel and unstealable_save_timer then cancel(unstealable_save_timer) end
  unstealable_save_timer = after and after(2, save_unstealable) or nil
end
-- Load ONCE per session (not on a live reload, where _AUTOFIGHT.unstealable already holds the current table).
if not _AUTOFIGHT.unstealable then
  _AUTOFIGHT.unstealable = {}
  local t = persist.load(UNSTEALABLE_FILE)
  if type(t) == "table" then for name, v in pairs(t) do if v then _AUTOFIGHT.unstealable[name] = true end end end
end

-- Do we already know this target's name has no soul (skip soulsteal outright)?
local function is_unstealable(name)
  local key = winner_key(name)
  return (key and _AUTOFIGHT.unstealable[key]) or false
end

-- Record (and persist) that a target NAME can't be soul-stolen. Only writes on a real change.
local function remember_unstealable(name)
  local key = winner_key(name)
  if not key then return end
  if not _AUTOFIGHT.unstealable[key] then
    _AUTOFIGHT.unstealable[key] = true
    schedule_unstealable_save()
    say(string.format("learned: %s has no soul — won't try to soulsteal it again", key))
  end
end

-- Per-fight state, as DECLARED DEFAULTS instead of a wall of inline assignments in start_fight. Each key
-- is reset to its value at the start of every fight; a factory function value yields a FRESH table (never
-- a shared one), and the NIL sentinel means "clear to nil" (pairs() skips real nil values, so a plain
-- `= nil` here would just be an absent key). The winner pair is conditional (a known winner is kept), so
-- it stays out of this table and is handled in reset_fight_state below.
local NIL = {}
local FIGHT_RESET = {
  busy          = false,
  busy_spell    = NIL,
  lightning_drop = 0,
  icebolt_drop  = 0,
  fireball_drop = 0,
  prism_drop    = 0,
  fallback_tried = false,
  last_damage_spell = NIL,
  soul_latched  = false,
  finish_ready  = false,    -- reset the near-death latch each fight
  renuke_pending = false,   -- a soulsteal resist forces exactly ONE winner-nuke before retrying it
  probe_ptr     = NIL,      -- the fight flow's probe pointer (lightning → fireball → decide, + icebolt/prism fallback); flow owns it
  suspended     = false,
  no_mana       = function() return {} end,   -- fresh per fight
  self_sent     = function() return {} end,   -- fresh per fight
}
local function reset_fight_state()
  for k, v in pairs(FIGHT_RESET) do
    if v == NIL then F[k] = nil
    elseif type(v) == "function" then F[k] = v()
    else F[k] = v end
  end
  if not F.known_winner then F.winner, F.winner_spell = nil, nil end   -- keep a known winner if set
end

-- Send a command the SCRIPT chose. Flag it in self_sent so the echoed-back on_user_input (send loops
-- through the input observer, exactly like the pilot) doesn't mistake our own command for the user's.
local function af_send(cmd)
  F.self_sent[cmd] = (F.self_sent[cmd] or 0) + 1
  sent[#sent + 1] = cmd
  if send then send(cmd) end
end

-- ---- combat initiation (engage) -----------------------------------------------------------------
-- Starting a fight from OUT of combat: `target x` sets the target but does NOT aggro, so we cast the
-- opener (tarrants); a SUCCESSFUL cast is what actually starts combat. The opener can fail — we retry
-- it up to cfg.max_tries, then give up. Once combat starts, kxwt_fighting fires start_fight (primed by
-- opener_primed to skip re-casting the opener) and the normal routine takes over. These run only while
-- F.engaging and not yet F.fighting; the in-combat handlers below are untouched.
-- The opener spell + its name. bloodmist (a blood demon that keeps attacking) hits harder than tarrants but
-- COSTS hp to cast, so we only lead with it when HP is comfortably above bloodmist_hp_min; otherwise the
-- free tarrants opener. Read fresh each time (HP can be low by the time we re-open on an engage retry).
local function opener_cmd()
  local hp, mhp = state.hp, state.maxhp
  if hp and mhp and mhp > 0 and (hp / mhp) > cfg.bloodmist_hp_min then return cfg.bloodmist_cmd, "bloodmist" end
  return cfg.opener_tarrants, "tarrants"
end
local function send_opener() F.engage_busy = true; af_send((opener_cmd())) end

-- Opener fizzled/resisted before combat started: retry, or give up after max_tries.
local engage_giveup   -- fwd
local function engage_retry(reason)
  F.engage_busy = false
  F.engage_tries = F.engage_tries + 1
  if F.engage_tries >= cfg.max_tries then engage_giveup(reason) else send_opener() end
end

engage_giveup = function(reason)
  F.engaging, F.engage_busy, F.opener_primed = false, false, false
  local cb = F.on_fail; F.on_fail, F.on_dead = nil, nil
  say("couldn't start the fight (" .. reason .. ")")
  if cb then cb(reason) end
end

-- The engage target simply isn't in the room ("Target who?  You do not see that person here.") — there's
-- nothing to aggro, so retrying the opener is pointless. Give up immediately (rejecting attack()'s promise).
-- Guarded to the engage window so a stray bad `target` you type mid-fight doesn't abort anything.
local function engage_target_missing()
  if F.engaging and not F.fighting then engage_giveup("target not here") end
end

-- Should we AOE (frostflower the whole room) rather than single-target this fight? "on"/"off" force it;
-- "auto" (default) AOEs once we believe we're in a pack (F.pack — set when a kill rolls straight onto
-- another enemy; see on_fight). A single-target fight uses the normal tarrants→probe→nuke→soulsteal.
local function aoe_active()
  if F.aoe_mode == "on"  then return true  end
  if F.aoe_mode == "off" then return false end
  return F.pack                                       -- "auto"
end

-- Which spell to cast when an AOE is called for → (cmd, landed-tag). Fireball does SPLASH damage, so if
-- fireball is ALREADY the chosen winner we just keep nuking with it (no reason to switch off our best
-- single-target pick to hit the pack). Only when the winner ISN'T fireball do we back up to the dedicated
-- room AOE, frostflower. During the probe (no winner picked yet) F.winner_spell is nil → frostflower.
local function aoe_cast()
  if F.winner_spell == "fireball" then return cfg.fireball_cmd, "fireball" end
  return cfg.aoe_cmd, "frostflower"
end

-- ==================================================================================================
-- THE FIGHT AS A PROMISE + STREAM FLOW
-- ==================================================================================================
-- The whole routine is one reactive pipeline instead of a flag-mutating phase machine:
--
--   combatStart$ :switchMap(target ->  opener(target)               -- resolves when the opener LANDS
--                                        :andThen(afterOpener) )     -- probe -> nuke/finish
--                :takeUntil(enemyDead$)                              -- DEAD/kxwt-1 ends the inner flow
--
-- Each STAGE is a promise that resolves off the relevant event STREAM (opener landed / probe verdict /
-- soulsteal outcome). The winner flows as a resolve value: probe() resolves WITH the winning spell,
-- which afterOpener hands to fightLoop(winner).
--
-- Where the pacing rules fall out of the structure (NOT a hand-walked `busy` flag):
--   * PACING — a cast only ever goes out inside a stage; the next stage isn't built until the current
--     one RESOLVES on its spell's landed line. The health bar (on_fight) never touches the flow, so a
--     flood of kxwt_fighting ticks sends nothing. The "busy" gate is simply "only the in-flight cast's
--     await is currently SUBSCRIBED" — a straggler/other-spell line has no subscriber and is dropped.
--   * RETRY — castStep re-sends the SAME command on a fizzle/resist, up to cfg.max_tries, then resolves
--     "gaveup" so the flow moves on.
--   * OUT-OF-MANA — resolves "mana"; the stage returns a never-resolving promise, so the flow simply
--     WAITS (no retry, no spam) until the fight ends (which cancels it).
--   * SUSPEND — a user command sets F.suspended; castStep holds its (re)send until resume$ fires. The
--     in-flight await isn't interrupted, only the NEXT send is gated — exactly the intervene-then-resume
--     behaviour.
--   * ROLLOVER / AOE — a new target pushes combatStart$ again; switchMap CANCELS the previous inner flow
--     and starts a fresh one. AOE is a cast-time override (frostflower) that leaves the probe pointer
--     untouched, so single-target play resumes where it left off once the pack thins.
local rx = __rx

-- A RE-ENTRANCY-SAFE Subject. The fight flow reacts to a stream SYNCHRONOUSLY: a "landed" event resolves
-- the current stage which immediately SUBSCRIBES the next stage to the SAME subject — adding an observer
-- mid-dispatch, which raw pairs()-iteration in _rx's Subject:onNext forbids ("invalid key to 'next'").
-- We snapshot the observer set before dispatching (and skip any that unsubscribed meanwhile); observers
-- that subscribe DURING the dispatch correctly don't receive the in-flight event. (_rx is shared and
-- off-limits, so we patch the instance here.)
local function safe_subject()
  if not rx then return nil end
  local s = rx.subject()
  s.onNext = function(self, ...)
    if self.closed then return end
    local snap = {}
    for o in pairs(self.observers) do snap[#snap + 1] = o end
    for _, o in ipairs(snap) do if self.observers[o] then o.onNext(...) end end
  end
  return s
end

-- Internal hot streams the flow subscribes to. They're fed by the hit_* adapters below, which BOTH the
-- live Swift triggers AND the _AF_TEST seam call — one path, no second line-matcher to drift.
local landedS   = safe_subject()   -- a damage/AOE spell landed; emits the spell name
local openerS   = safe_subject()   -- the opener (tarrants/bloodmist) landed; emits the name
local failedS   = safe_subject()   -- a cast fizzled ("You fail to cast"); emits ()
local resistS   = safe_subject()   -- a resist; the ACTIVE await interprets it (damage vs soulsteal)
local manaS     = safe_subject()   -- out of mana; emits ()
local soulPullS = safe_subject()   -- soulsteal PULLED the soul (about to die); emits ()
local soulLatchS= safe_subject()   -- soulsteal LATCHED (dormant; keep nuking); emits ()
local deadS     = safe_subject()   -- the enemy is DEAD / combat ended; ends the fight flow
local resumeS   = safe_subject()   -- the manual-input suspend window elapsed; emits ()
local combatStartS = safe_subject() -- a fresh fight / rollover begins; emits the target start
-- The health-bar boundary: a wire round is [spell lands][near-death line?] GA, then NEXT frame
-- [kxwt_prompt][kxwt_fighting <newpct>] GA — the fresh % (and any near-death line that preceded it)
-- lags the action into the FOLLOWING frame. So the fight loop decides (nuke-winner vs soulsteal) on
-- THIS boundary, not the GA: by the time on_fight fires, both F.pct AND F.finish_ready (set by the
-- near-death trigger, which arrives before the bar update) are settled. LOCAL + reload-safe like
-- landedS (on_fight itself is redefined each reload, so no global wrapping is needed).
local barS = safe_subject()

-- A flow promise: __promise but STARTED synchronously at construction (in this flow, a stage is built
-- exactly at the moment it should run — inside the previous stage's andThen — so construct == execute)
-- and kept OUT of the HUD promise widget (only the per-fight fight_promise is a widget row).
local function P(executor)
  local p = __promise(executor, "autofight-flow")
  if __untrack_promise then __untrack_promise(p) end
  p.__start()
  return p
end
local function resolved(v) return P(function(res) res(v) end) end       -- already-settled promise
local function never_p()   return P(function() end) end                 -- never settles: the "wait" state

-- castStep(cmd, wantSpell[, landStream]) — send `cmd` (gated by suspend) and await ITS resolution:
--   "landed"  the awaited spell's own success line arrived
--   "gaveup"  it fizzled/resisted cfg.max_tries times → move on
--   "mana"    out of mana → the caller HALTS (waits)
-- Retries the SAME command on a fizzle/resist. `wantSpell` filters landStream (default landedS) so only
-- OUR spell's landed line resolves us — a straggler or an unrelated landed line is ignored (the pacing
-- guarantee). The single active subscription IS the "busy" gate: nothing else can advance the flow.
local function castStep(cmd, wantSpell, landStream)
  landStream = landStream or landedS
  return P(function(resolve, _, onCancel)
    local tries, sub, rsub, cancelled = 0, nil, nil, false
    local function cleanup()
      if sub  then sub:unsubscribe();  sub  = nil end
      if rsub then rsub:unsubscribe(); rsub = nil end
    end
    local function fin(v) cleanup(); resolve(v) end
    local function begin()
      -- :takeUntil(deadS) tears this await down the instant the fight ends (DEAD / kxwt-1 / rollover /
      -- reload) WITHOUT resolving the promise — so the chain simply STOPS and no stream observer leaks.
      -- (Promise cancel can't reach here: a handler returning a chained promise reassigns _parent.)
      sub = rx.merge(
        landStream:filter(function(s) return wantSpell == nil or s == wantSpell end):map(function() return "landed" end),
        failedS:map(function() return "fail" end),
        resistS:map(function() return "fail" end),
        manaS:map(function() return "mana" end)
      ):takeUntil(deadS):subscribe(function(ev)
        if ev == "landed" then fin("landed")
        elseif ev == "mana" then fin("mana")
        else
          tries = tries + 1
          if tries >= cfg.max_tries then fin("gaveup") else af_send(cmd) end
        end
      end)
      af_send(cmd)
    end
    onCancel(function() cancelled = true; cleanup() end)
    if F.suspended then
      rsub = resumeS:takeUntil(deadS):subscribe(function()
        if cancelled then return end
        if rsub then rsub:unsubscribe(); rsub = nil end
        begin()
      end)
    else
      begin()
    end
  end)
end

-- soulstealStep() — cast soulsteal (suspend-gated) and await its distinct outcomes: "pulled" (soul taken,
-- enemy about to die), "latched" (dormant — keep nuking), "resisted" (re-nuke once then retry), "fizzled"
-- (the CAST itself failed — re-cast the steal at once, no nuke), "mana". Awaiting failedS too is what
-- stops a soulsteal fizzle ("You fail to cast the spell 'soulsteal'.") from DEADLOCKING the flow: without
-- it the fizzle matched no outcome and this promise hung until the enemy happened to die — autofight went
-- silent mid-fight (the "why'd it stop" bug).
local function soulstealStep()
  return P(function(resolve, _, onCancel)
    local sub, rsub, cancelled = nil, nil, false
    local function cleanup()
      if sub  then sub:unsubscribe();  sub  = nil end
      if rsub then rsub:unsubscribe(); rsub = nil end
    end
    local function fin(v) cleanup(); resolve(v) end
    local function begin()
      sub = rx.merge(
        soulPullS:map(function() return "pulled" end),
        soulLatchS:map(function() return "latched" end),
        resistS:map(function() return "resisted" end),
        failedS:map(function() return "fizzled" end),
        manaS:map(function() return "mana" end)
      ):takeUntil(deadS):subscribe(function(ev) fin(ev) end)
      af_send(cfg.soulsteal_cmd)
    end
    onCancel(function() cancelled = true; cleanup() end)
    if F.suspended then
      rsub = resumeS:takeUntil(deadS):subscribe(function()
        if cancelled then return end
        if rsub then rsub:unsubscribe(); rsub = nil end
        begin()
      end)
    else
      begin()
    end
  end)
end

-- Resolve on the NEXT health-bar boundary (on_fight). takeUntil(deadS) so a kill mid-wait just stops (the
-- outer takeUntil(deadS) tears the chain down — matches castStep's teardown contract).
local function nextBar()
  return P(function(resolve)
    local sub
    sub = barS:takeUntil(deadS):subscribe(function()
      if sub then sub:unsubscribe(); sub = nil end
      resolve()
    end)
  end)
end

-- STAGE 1 — the OPENER. Resolves when it LANDS (or is given up after max_tries). Skipped (resolves at
-- once) when an engage already threw it (opener_primed) or we're AOEing a pack from the off.
local function opener()
  F.phase = "opener"
  if F.opener_primed or aoe_active() then return resolved() end
  local cmd = (opener_cmd())                          -- bloodmist above HP gate, else tarrants
  return castStep(cmd, nil, openerS)                  -- any opener landed = success
end

-- STAGE 2 — the PROBE. Resolves WITH the winning spell name. Walks a pointer through the PRIMARY probes
-- lightning → fireball → decide, and — only when NEITHER primary hit hard enough — a FALLBACK tier
-- icebolt → prism → decide, crediting each spell's %-drop (via on_fight/last_damage_spell) and picking the
-- biggest. AOE, while active, overrides the actual cast (frostflower during the probe, since no winner is
-- picked yet — see aoe_cast) WITHOUT advancing the pointer — so when the pack thins the probe resumes
-- exactly where it paused.
local PROBE_NEXT = { lightning = "fireball", fireball = "decide", icebolt = "prism", prism = "decide" }
local function probe()
  F.phase = "probe"
  F.probe_ptr = "lightning"
  local step
  step = function()
    -- A mid-probe autofight.winner() override sets F.known_winner: bail out of probing immediately and
    -- resolve WITH the override, flowing it straight into fightLoop — no need to finish walking the
    -- pointer (remember_winner is already done by autofight.winner itself).
    if F.known_winner then return resolved(F.known_winner) end
    if aoe_active() then                              -- override cast; pointer untouched
      local acmd, atag = aoe_cast()                   -- probe has no winner yet → frostflower
      F.last_damage_spell = (atag == "fireball") and "fireball" or "aoe"; F.phase = "aoe"
      return castStep(acmd, atag):andThen(function(o)
        if o == "mana" then return never_p() end
        F.phase = "probe"
        return step()
      end)
    end
    local ptr = F.probe_ptr
    if ptr == "decide" then
      -- fallback gate: only run the icebolt/prism probes when NEITHER primary (lightning, fireball) hit hard
      -- enough — they're rarely best, so skip them when a primary already landed big.
      if not F.fallback_tried and math.max(F.lightning_drop, F.fireball_drop) < cfg.probe_enough then
        F.fallback_tried, F.probe_ptr = true, "icebolt"
        return step()
      end
      -- coarse winner pick: fireball is the PREFERRED default (it also splashes/AOEs), handicapped by
      -- cfg.fireball_bias — another spell must beat fireball's drop by MORE than the bias to take the win
      -- (lightning in particular must beat it HANDILY, not just edge it out).
      local ld, sd, id, pd = F.lightning_drop, F.fireball_drop, F.icebolt_drop, F.prism_drop or 0
      local winner, best = "fireball", sd + cfg.fireball_bias   -- err toward fireball (splash/AOE bonus)
      if ld > best then winner, best = "lightning", ld end      -- lightning must beat fireball HANDILY (+bias)
      if id > best then winner, best = "icebolt",   id end
      if pd > best then winner, best = "prism",     pd end
      remember_winner(F.name, winner)                 -- learn it so the next fight skips the probe
      return resolved(winner)                          -- ← the probe verdict flows on as the resolve value
    end
    F.last_damage_spell = ptr
    return castStep(cfg[ptr .. "_cmd"], ptr):andThen(function(o)
      if o == "mana" then return never_p() end
      F.probe_ptr = PROBE_NEXT[ptr] or "decide"        -- landed OR gaveup advances the pointer
      return step()
    end)
  end
  return step()
end

-- STAGE 3 — fightLoop(winner). Reactive: on each landed spell, cast the winner (or soulsteal once the
-- enemy is in finish range), until enemyDead ends it. AOE overrides the cast: fireball if it's the winner
-- (splash), else frostflower (see aoe_cast). Soulsteal
-- resist re-nukes exactly once then retries; a latch keeps nuking the winner and never re-casts soulsteal.
local function fightLoop(winner)
  if winner then F.winner_spell, F.winner = winner, cfg[winner .. "_cmd"] end
  local step
  step = function()
    if aoe_active() then
      local acmd, atag = aoe_cast()                   -- fireball winner keeps fireball (splash); else frostflower
      F.last_damage_spell = (atag == "fireball") and "fireball" or "aoe"; F.phase = "aoe"
      return castStep(acmd, atag):andThen(function(o)
        if o == "mana" then return never_p() end
        return step()
      end)
    end
    -- finish range → soulsteal, UNLESS a dormant steal is latched or a post-resist re-nuke is owed, or the
    -- target is KNOWN soulless (persisted from a prior "can only soulsteal from living things" — never cast
    -- it at this name again). The near-death LATCH (F.finish_ready) is authoritative alongside the pct gate.
    if winner and (F.finish_ready or (F.pct and F.pct > 0 and F.pct <= cfg.soulsteal_pct))
       and not F.soul_latched and not F.renuke_pending and not F.known_unstealable then
      F.phase = "soulsteal"
      return soulstealStep():andThen(function(r)
        if r == "pulled"  then return resolved() end            -- soul taken → stop; DEAD ends the fight
        if r == "latched" then F.soul_latched = true; return step() end   -- keep nuking the winner
        if r == "resisted" then F.renuke_pending = true; return step() end -- one nuke, then retry steal
        if r == "fizzled" then return step() end   -- the CAST fizzled (skill roll) → re-cast soulsteal at
                                                   -- once; no interleaved nuke (don't waste the round and
                                                   -- risk a minion killing it before the soul is grabbed)
        if r == "mana"    then return never_p() end
        return step()
      end)
    end
    F.renuke_pending = false
    -- Read the LIVE field first: a mid-fight autofight.winner() override sets F.winner_spell, and this
    -- re-read (mirroring the AOE override's re-read-every-cast pattern) picks it up on the very next nuke
    -- instead of continuing to cast the stale CAPTURED `winner` upvalue.
    local w = F.winner_spell or winner or "lightning"  -- edge: AOE cleared before any winner was learned
    F.last_damage_spell = w; F.phase = "nuke"
    return castStep(cfg[w .. "_cmd"], w):andThen(function(o)
      if o == "mana" then return never_p() end
      return nextBar():andThen(step)   -- decide on the fresh-pct bar boundary: F.pct / finish_ready settled
    end)
  end
  return step()
end

-- After the opener lands: a known winner or an AOE pack skips the probe; otherwise probe, then nuke the
-- winner it resolves with.
local function afterOpener()
  if aoe_active()     then return fightLoop(nil) end
  if F.known_winner   then return fightLoop(F.known_winner) end
  return probe():andThen(function(winner) return fightLoop(winner) end)
end

-- Build + START the whole per-fight promise chain; return its TAIL (cancelling the tail cascades upstream
-- to abort whatever stage is currently in flight — that's how switchMap/DEAD tear a fight down).
local function runCombat()
  return opener()
    :andThen(afterOpener)
    :catch(function(why) if why ~= nil then say("fight aborted: " .. tostring(why)) end end)
end

-- The switchMap inner: an Observable that starts the chain on subscribe and cancels it on unsubscribe.
local function runCombatObs()
  return rx.Observable.create(function()
    local tail = runCombat()
    return function() if tail and tail.cancel then tail.cancel() end end
  end)
end

-- THE master pipeline (wired once per load). A fresh fight / rollover pushes combatStart$; switchMap
-- cancels any previous inner flow and starts the new one; takeUntil(enemyDead$) ends it on DEAD/kxwt-1.
if rx then
  combatStartS
    :switchMap(function() return runCombatObs():takeUntil(deadS) end)
    :subscribe(function() end)
end

-- ---- fight lifecycle -----------------------------------------------------------------------------
-- Fight-as-a-promise. begin_fight_promise() creates the tracked promise on the FIRST start_fight of an
-- engagement (guarded so a target rollover — which re-runs start_fight — doesn't spawn a second) and
-- retitles the widget row to the current target on a rollover. settle_fight_promise() resolves it when
-- combat ends. Guarded on __promise so AutoFight still runs without the promise layer. Started
-- SYNCHRONOUSLY so fight_settle is wired before any combat line can end the fight.
local function begin_fight_promise(name)
  local desc = "autofight: " .. (name or "?")
  if F.fight_settle then
    if __track_promise and F.fight_promise then __track_promise(F.fight_promise, desc) end   -- rollover → retitle
    return
  end
  if not __promise then return end
  local p = __promise(function(resolve, reject, onCancel)
    F.fight_settle = { resolve = resolve, reject = reject }
    onCancel(function() F.fight_settle = nil end)
  end, desc)
  if p and p.__start then p.__start() end
  F.fight_promise = p
end
local function settle_fight_promise()
  local s = F.fight_settle; F.fight_settle, F.fight_promise = nil, nil
  if s then s.resolve() end
end

local function start_fight(pct, name)
  F.fighting, F.pct, F.name = true, pct, name
  F.fought = true             -- real combat began; survives the DEAD line so on_fight_end can still resolve on_dead
  begin_fight_promise(name)   -- track this engagement as a promise (once; retitles on target rollover)
  -- Do we already know the winning spell for this target name? If so, the flow skips the probe entirely.
  local key = winner_key(name)
  local known = key and _AUTOFIGHT.winners[key]
  F.known_winner = is_probe_spell(known) and known or nil
  if F.known_winner then
    F.winner, F.winner_spell = cfg[F.known_winner .. "_cmd"], F.known_winner
    say(string.format("%s known → %s (skipping probe)", key, F.known_winner))
  end
  -- Known soulless (undead/construct/dead body)? Never enter the soulsteal stage this fight — just nuke it
  -- down. Set BEFORE reset_fight_state (which doesn't touch this key), fresh per engagement.
  F.known_unstealable = is_unstealable(name)
  if F.known_unstealable then say(string.format("%s has no soul → skipping soulsteal, nuking it down", key)) end
  reset_fight_state()                                                  -- declared defaults (see FIGHT_RESET)
  F.engaging, F.engage_busy = false, false
  if F.suspend_timer and cancel then cancel(F.suspend_timer); F.suspend_timer = nil end
  clear_sent()
  -- Kick the reactive fight flow. First fire deadS to tear down any PREVIOUS in-flight cast (a rollover
  -- has no DEAD to do it, and promise-cancel can't reach a deep chained stage), THEN start the new flow.
  -- switchMap swaps the inner; the new stages subscribe to deadS fresh (the abort above is already past).
  if deadS then deadS:onNext() end
  if combatStartS then combatStartS:onNext(true) end
  F.opener_primed = false                                             -- consumed by the flow just built
end

local function end_fight()
  if deadS then deadS:onNext() end    -- complete/cancel any live fight flow (unsubscribes its in-flight cast)
  F.fighting, F.phase = false, "idle"
  F.suspended = false
  if F.suspend_timer and cancel then cancel(F.suspend_timer); F.suspend_timer = nil end
end

-- ---- AOE crowd tracking --------------------------------------------------------------------------
-- F.enemy_est = our running estimate of how many hostiles are engaged. It's SET from a room listing
-- (a look/auto-look) and COUNTED DOWN as enemies die (kxwt_mdeath). AOE is on (in "auto") whenever the
-- estimate is pack-sized; the moment a death drops it below the threshold we fall back to single target
-- — no second look needed. The estimate only needs to tell "pack (>= aoe_min)" from "not"; undercounting
-- the last one to 0 still yields single target, which is what we want.

-- Enter/leave AOE just flip the belief flag. The fight flow re-reads aoe_active() at EVERY cast, so the
-- next spell it sends switches to/from frostflower on its own — no imperative re-firing needed. AOE is a
-- cast-time override that leaves the probe/nuke pointer untouched, so single-target play resumes cleanly
-- once the pack thins (see probe()/fightLoop()).
local function enter_pack_mode() F.pack = true  end
local function exit_pack_mode()  F.pack = false end

-- Apply the current estimate: pack-sized ⇒ AOE, else single target.
local function reeval_pack()
  if (F.enemy_est or 0) >= cfg.aoe_min then enter_pack_mode() else exit_pack_mode() end
end

-- A room listing is our authoritative crowd snapshot. On a look/auto-look each engaged creature prints
-- its OWN "<X> is here, fighting <Y>." line, so counting hostile SUBJECTS counts same-named packs a
-- name-keyed tracker can't. The first hostile line after a quiet gap starts a fresh tally; each line in
-- the burst adds to it; we keep the running total as the estimate and re-evaluate each line (so AOE arms
-- mid-burst, and a look showing just one enemy drops us back out). Only while WE'RE fighting.
local function note_room_fighter(subject)
  if not F.on or not F.fighting then return end
  if is_ally and is_ally(subject) then return end        -- our minion/self fighting a mob — not an enemy
  if not F.room_burst_timer then F.room_seen = 0 end      -- new burst → fresh count
  F.room_seen = F.room_seen + 1
  F.enemy_est = F.room_seen
  reeval_pack()
  if F.room_burst_timer and cancel then cancel(F.room_burst_timer) end
  F.room_burst_timer = after and after(cfg.room_burst, function() F.room_burst_timer = nil end) or nil
end

-- An enemy died (kxwt_mdeath). Count it off the estimate and re-evaluate — THIS is what drops us out of
-- AOE onto single target when a pack is whittled to the last one. Our own minions also emit mdeath, so
-- exclude allies.
local function note_mdeath(name)
  if is_ally and is_ally(name) then return end
  if (F.enemy_est or 0) > 0 then F.enemy_est = F.enemy_est - 1 end
  reeval_pack()
end

-- Timestamp of the last game PROMPT seen (via __autofight_prompt), set by the bridge below. Module-level
-- (NOT on the per-fight F table, which start_fight/end_fight reset) so it survives across fights and
-- simply tracks "is the prompt still the live/authoritative source right now?" — the fighting PROMPT is
-- the game's authoritative answer; kxwt_fighting is only a FALLBACK for when the prompt isn't firing.
local last_prompt = 0

-- kxwt_fighting <pct> <gender> <name> — the enemy health bar. Combat start = not-fighting → fighting.
-- A health-% change is BOTH a pacing resolution AND the winner-comparison signal: while a probe is the
-- most-recent damage spell, any drop is credited to it (coarse — a straggler drop can misattribute, and
-- that's explicitly acceptable).
local function on_fight(pct, name)
  if not F.on then return end
  local was, prev, prevname = F.fighting, F.pct, F.name
  F.pct, F.name = pct, name
  if barS then barS:onNext() end   -- the fresh-pct boundary: fightLoop's deferred nuke decision fires here
  if not was then start_fight(pct, name); return end   -- fresh engagement (pack persists if a look set it)
  -- Target changed mid-combat WITHOUT a kxwt_fighting -1: a mob died and we rolled straight onto the
  -- next, or an add grabbed us — the server never said "not fighting", so `was` is still true, but this
  -- is a NEW enemy. Start the routine over on it (fresh opener/probe; clears a stuck busy flag and any
  -- manual-input suspend) instead of nuking the corpse's leftover phase or stalling forever waiting on a
  -- landed line that will never come. This is the fix for "killed one, rolled onto the last, autofight
  -- froze": it no longer depends on the (AOE-ambiguous, sometimes-missed) DEAD line to notice the swap.
  -- Detected authoritatively from the health bar: the NAME changed, or it jumped UP past a regen margin
  -- (a target we're already on only trends down).
  if name ~= prevname or (prev and pct >= prev + cfg.new_target_jump) then
    -- NOTE: a rollover no longer flips AOE on by itself — AOE is driven by the crowd COUNT (a look sets
    -- the estimate, each kxwt_mdeath decrements it), so the routine drops back to single target when the
    -- pack is down to the last one. start_fight reads the current pack state, so if we're still pack-
    -- sized it stays AOE across the swap, otherwise it single-targets the new enemy.
    start_fight(pct, name); return
  end
  if prev and pct < prev then
    local d = prev - pct
    if     F.last_damage_spell == "lightning" then F.lightning_drop = F.lightning_drop + d
    elseif F.last_damage_spell == "icebolt" then F.icebolt_drop = F.icebolt_drop + d
    elseif F.last_damage_spell == "fireball" then F.fireball_drop = F.fireball_drop + d
    elseif F.last_damage_spell == "prism"   then F.prism_drop   = F.prism_drop + d end
  end
  -- A health-% change updates the winner comparison ONLY. It NEVER triggers a cast — casting is driven
  -- solely by a spell's landed line (or a failure). This is the fix for the command-spam bug: the health
  -- bar ticks several times a second, and the old code cast on every tick.
end

local function on_fight_end()
  -- Latch on F.fought, NOT F.fighting: the DEAD line runs end_fight() (clearing F.fighting) BEFORE this
  -- trailing `kxwt_fighting -1` arrives, so F.fighting is already false on a normal kill. F.fought stays
  -- true from start_fight, so an engaged kill still resolves; a stray -1 during the opener (F.engaging,
  -- never reached start_fight) leaves F.fought false and correctly does NOT resolve.
  local was_engaged_fight = F.fought and F.on_dead
  F.pack, F.enemy_est = false, 0                         -- combat truly over → next fight re-evaluates
  if deadS then deadS:onNext() end                       -- stop any still-live fight flow (e.g. the mob fled)
  if F.fighting then end_fight() end
  F.fought = false                                       -- engagement fully over; re-armed by the next start_fight
  settle_fight_promise()                                 -- resolve the engagement's promise (combat is over)
  -- The fight we started via engage() is over (mob dead or fled): fire on_dead exactly once.
  if was_engaged_fight then
    local cb = F.on_dead; F.on_dead, F.on_fail = nil, nil
    if cb then cb() end
  end
end

-- Prompt-driven combat signal: the game's fighting PROMPT is authoritative when it's around (nomelee
-- setups where kxwt_fighting flips flaky — see on_kxwt_fight/on_kxwt_end below). When the prompt isn't
-- firing at all (normal play without the custom kxwq prompt), last_prompt stays 0/stale and kxwt drives
-- exactly as before — no regression.
local PROMPT_FRESH = 10   -- seconds; kxwt is ignored while the prompt fired within this window
function __autofight_prompt(pct, name)   -- pct+name when fighting; both nil when the prompt says not-fighting
  last_prompt = os.time()                               -- the machine prompt is live → authoritative
  if pct and name and name ~= "" then on_fight(pct, name)       -- start/refresh the fight from the prompt
  else on_fight_end() end                                        -- prompt says not fighting → end it
end

-- kxwt_fighting subscribers: FALLBACK only. Ignored while the prompt is live (a stray kxwt -1 from a
-- tank "rescue" flip must not end a fight the authoritative prompt still says is ongoing).
local function on_kxwt_fight(pct, name)
  if os.time() - last_prompt < PROMPT_FRESH then return end   -- prompt live → it's authoritative; ignore kxwt
  on_fight(pct, name)
end
local function on_kxwt_end()
  if os.time() - last_prompt < PROMPT_FRESH then return end   -- ignore a stray kxwt -1 (rescue flip) while the prompt says fighting
  on_fight_end()
end

-- ---- combat line resolutions ---------------------------------------------------------------------
-- Each hit_* is what a trigger fires; the _AF_TEST seam calls the SAME hit_*, so triggers and tests
-- share one implementation. Each pushes onto the internal stream the fight FLOW subscribes to — there is
-- no phase machine to poke; the in-flight stage's subscription (if any) reacts, and when no stage is
-- awaiting a given event the push is simply dropped (that's the pacing guarantee).
local function hit_lightning()   if landedS then landedS:onNext("lightning")   end end
local function hit_icebolt()     if landedS then landedS:onNext("icebolt")     end end
local function hit_fireball()    if landedS then landedS:onNext("fireball")    end end
local function hit_prism()       if landedS then landedS:onNext("prism")       end end
local function hit_frostflower() if landedS then landedS:onNext("frostflower") end end
-- DORMANT (see cfg.shower_cmd): shower isn't in the routine, so no stage ever awaits "shower" — the push
-- has no matching subscriber and is dropped. Wired only to keep the "A shower of … sparks" string live.
local function hit_shower()      if landedS then landedS:onNext("shower")      end end
-- Opener landed (tarrants OR bloodmist). During an engage it just clears the init-busy latch (combat is
-- about to start via kxwt_fighting → start_fight); in-combat it feeds the opener stage's await.
local function opener_landed(spell)
  if F.engaging and not F.fighting then F.engage_busy = false; return end
  if openerS then openerS:onNext(spell) end
end
local function hit_tarrants()  opener_landed("tarrants")  end
local function hit_bloodmist() opener_landed("bloodmist") end
local function hit_resist()
  -- Engage opener resisted before combat started: retry the opener (imperative — engage is out-of-combat
  -- init, separate from the in-combat flow).
  if F.engaging and not F.fighting then return engage_retry("resisted") end
  -- In combat, the ACTIVE await interprets the resist: a damage/probe cast treats it as a fizzle (retry);
  -- a soulsteal cast treats it as "resisted" (re-nuke once, then retry). Both live in castStep/soulstealStep.
  if resistS then resistS:onNext() end
end
local function hit_mana()
  -- Can't afford the engage opener → combat will never start; give up initiating.
  if F.engaging and not F.fighting then return engage_giveup("out of mana") end
  if manaS then manaS:onNext() end                          -- the in-flight stage HALTS (waits, no spam)
end
local function hit_fail()
  if F.engaging and not F.fighting then return engage_retry("cast failed") end   -- engage opener fizzled → retry
  if failedS then failedS:onNext() end                                            -- in-combat fizzle → retry same spell
end                                                    -- "You fail to cast the spell '…'." — fizzled, retry

local function hit_soulsteal_ok()
  -- The soul was pulled ("…and pull <x>'s essence into a <color> soulstone!") — the enemy is about to
  -- die. The soulsteal stage resolves "pulled" and the flow stops; the DEAD line ends the fight. (Also
  -- fires when a latched steal finally activates.)
  if soulPullS then soulPullS:onNext() end
end

local function hit_soul_latched()
  -- DORMANT soulsteal: "You magically latch onto <x>'s soul and wait for <x> to weaken…". The soul is
  -- NOT captured yet. The soulsteal stage resolves "latched"; fightLoop sets F.soul_latched (so it never
  -- re-casts soulsteal) and keeps nuking the winner until the latch fires as the target drops.
  if soulLatchS then soulLatchS:onNext() end
end

local function hit_soul_nolatch()
  -- "Your spell fails to latch on to an individual soul!" — this is a TERMINATOR, not a retry: this mob
  -- simply has no individual soul to steal, so soulsteal can NEVER land on it (same category as "can only
  -- soulsteal from living things"). Persist it by name and treat it exactly like the unstealable case —
  -- stop re-casting soulsteal, keep nuking the winner down, and skip the soulsteal stage in future fights
  -- against this name.
  say("target has no individual soul to steal — nuking it down instead")
  remember_unstealable(F.name)   -- persist: future fights vs this name skip the soulsteal stage entirely
  F.known_unstealable = true     -- ...and don't re-cast for the rest of THIS fight (belt with soul_latched)
  if soulLatchS then soulLatchS:onNext() end   -- same "latched" outcome → keep nuking, don't re-steal
end

local function hit_soul_unstealable()
  -- "You can only soulsteal from living things." — the target is undead / a construct / an already-dead
  -- body, so soulsteal can NEVER land on it (but it's usually still alive and fighting). Resolve the
  -- in-flight steal so the flow doesn't DEADLOCK (this is the missing terminator that stalled autofight),
  -- then behave exactly like a dormant latch: F.soul_latched stops us re-casting soulsteal and the loop
  -- keeps nuking the winner until it dies normally. A visible note so it never just looks stuck.
  say("target can't be soul-stolen (not living) — nuking it down instead")
  remember_unstealable(F.name)   -- persist: future fights vs this name skip the soulsteal stage entirely
  F.known_unstealable = true     -- ...and don't re-cast for the rest of THIS fight (belt with soul_latched)
  if soulLatchS then soulLatchS:onNext() end   -- same "latched" outcome → keep nuking, don't re-steal
end

local function hit_dead()
  if deadS then deadS:onNext() end    -- end the fight flow (takeUntil) — no more casts
  end_fight()
end

-- Authoritative "soulsteal-viable now" signal: the game says OUR TARGET is near death / mortally wounded.
-- Latch it; the fightLoop switches to soulsteal at the next frame boundary. Target-matched so another
-- creature's near-death doesn't mis-latch (a wrong latch → a wasted, resisted soulsteal).
local function note_near_death(name)
  if F.fighting and F.name and name then
    local a = (name:gsub("^%s+", ""):gsub("%s+$", "")):lower()
    local b = (F.name:gsub("^%s+", ""):gsub("%s+$", "")):lower()
    if a == b then F.finish_ready = true end
  end
end

-- ---- manual-input suspend (step 6) ---------------------------------------------------------------
-- Observe every typed command WITHOUT swallowing it. A command we didn't send (self_sent miss) is the
-- user intervening: suspend and (re)arm a resume timer. Commands we sent echo back here and are consumed.
local function observe_input(cmd)
  cmd = (cmd or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if cmd == "" or cmd:sub(1, 1) == "#" then return end                -- ignore blanks and #control commands
  if (F.self_sent[cmd] or 0) > 0 then F.self_sent[cmd] = F.self_sent[cmd] - 1; return end
  if not F.on or not F.fighting then return end
  F.suspended = true
  if F.suspend_timer and cancel then cancel(F.suspend_timer) end
  F.suspend_timer = after and after(cfg.resume_after, function()
    F.suspend_timer = nil; F.suspended = false
    if resumeS then resumeS:onNext() end                 -- release the held cast (castStep's resume gate)
  end) or nil
end

-- ---- tank rescue: auto-resummon a dead clay-man tank ---------------------------------------------
-- Your TANK is a MINION of yours (kxwt group flag M) that's TANKING (flag T) — for this character a
-- summoned clay man (a flesh beast tanks the same way). It dying mid-fight is an emergency: the party
-- loses its front line. So when the tank dies we (1) turn OFF corpse automation — it would otherwise run
-- off to sac/loot the corpse the moment combat ends, and we need a clean shot at re-summoning instead —
-- and (2) re-cast 'clay man' on a pace until one joins the group, restoring the tank. Runs regardless of
-- F.on (a dead tank is worth handling whether or not auto-fight is armed); disable with autofight.tank('off').
local TANK = { on = true, name = nil, resummoning = false, tries = 0, timer = nil, death_at = nil }

-- Which grouped minion is currently tanking (flags contain both M = ours and T = tanking)? Read from
-- state.group_flags — kxwt's OWN roster+flags (AlterAeon.lua), the kxwt supplement RPC can't provide. This
-- is deliberately NOT state.group: over the 1.105 RPC state.group's membership comes from the framed
-- ;sgroup; event, whose timing is decoupled from the kxwt_group_end that drives refresh_tank — so a
-- just-dead tank could still be listed there. state.group_flags is refreshed in the SAME kxwt_group_end,
-- so it's self-consistent with the kxwt_ydeath that latched the death. Name is remembered stickily
-- (refresh_tank) so we still know who the tank WAS the moment it leaves.
local function current_tank_name()
  for name, f in pairs(state.group_flags or {}) do
    if f:find("M", 1, true) and f:find("T", 1, true) then return name end
  end
  return nil
end

local function stop_resummon()
  TANK.resummoning, TANK.tries = false, 0
  if TANK.timer and cancel then cancel(TANK.timer); TANK.timer = nil end
end

-- One re-summon attempt, then a backstop timer for the next. Capped so a hard, un-retryable failure —
-- no clay/dirt in the room to shape ("You need nearby clay or dirt for this.") — can't spam forever.
local resummon_tick
resummon_tick = function()
  TANK.timer = nil
  if not TANK.resummoning then return end
  if TANK.tries >= cfg.clay_max_tries then
    say(string.format("gave up re-summoning a tank after %d tries (need clay/dirt nearby?)", TANK.tries))
    stop_resummon(); return
  end
  TANK.tries = TANK.tries + 1
  say(string.format("tank down — re-summoning clay man (try %d/%d)", TANK.tries, cfg.clay_max_tries))
  af_send(cfg.clay_cmd)
  TANK.timer = after and after(cfg.clay_retry, resummon_tick) or nil
end

local function tank_died()
  if not TANK.on then return end
  say("tank died — disabling corpse automation and re-summoning a clay man")
  if autoHarvest and autoHarvest.off then autoHarvest.off() end   -- clear the way; stop auto-sac/loot
  if TANK.resummoning then return end                   -- a resummon is already in flight
  TANK.resummoning, TANK.tries = true, 0
  resummon_tick()
end

-- A clay man joined the group (or we already had one) → we have a tank again; stop retrying.
local function tank_resummoned()
  if not TANK.resummoning then return end
  say("new tank up")
  stop_resummon()
end

-- Is `name` still in kxwt's roster? Checked against state.group_flags (kxwt's own membership) to match
-- current_tank_name — self-consistent with the kxwt_group_end/kxwt_ydeath pair, unlike RPC's ;sgroup;.
local function minion_in_group(name)
  if not name then return false end
  local low = name:lower()
  for n in pairs(state.group_flags or {}) do
    if n:lower() == low then return true end
  end
  return false
end

-- kxwt_ydeath <name> — one of YOUR OWN minions just DIED (enemies emit kxwt_mdeath; a benign leave — you
-- dismiss it, it flees — emits NEITHER). The death name is a pet nickname ("flesh beastie") that does NOT
-- match the group-roster name ("A flesh beast"), so we can't tell FROM this line whether it was the tank;
-- we TIMESTAMP "a minion died" and let a following roster say which one is gone.
local TANK_DEATH_WINDOW = 6   -- seconds a ydeath stays "fresh" while we wait for the roster to drop the tank
local function tank_ydeath() TANK.death_at = os.time() end

-- kxwt_group_end: (re)track the tank and, using the ydeath latch, detect the TANK's death specifically.
-- If our remembered tank is now gone from the roster AND a minion death was announced RECENTLY, the tank was
-- the one that died → rescue. CRITICAL over the 1.105 RPC: kxwt_group streams every tick, so SEVERAL stale
-- rosters (tank still listed) fire between the ydeath and the roster that finally drops it. So we must NOT
-- clear the latch on every call (that's why the rescue never fired over RPC) — we keep it until the tank is
-- confirmed gone, and use a time WINDOW so a stale latch from some OTHER minion's death can't linger and
-- fire on a later benign departure. Gone WITHOUT a recent death (dismiss/flee — no ydeath) → no rescue.
local function refresh_tank()
  local t = current_tank_name()
  if t then TANK.name = t; return end              -- someone's tanking → track it (leave the latch alone)
  if TANK.name and not minion_in_group(TANK.name) then
    local recent = TANK.death_at and (os.time() - TANK.death_at) <= TANK_DEATH_WINDOW
    TANK.death_at = nil                            -- consume the latch now the tank is confirmed gone
    TANK.name = nil
    if recent then tank_died() end                 -- gone + a RECENT minion death → the tank died
  end
end

-- Public toggle for the tank-rescue block is autofight.tank(...) — defined with the other autofight.*
-- members below (the `autofight` table doesn't exist yet at this point in the file).

-- ---- live wire → internal streams ----------------------------------------------------------------
-- rx.fromTrigger(pattern) is a hot stream of a Swift trigger's matches (registered on first subscribe;
-- the line still displays). These subscribers do ONE job: feed the hit_* adapters above, which push onto
-- the INTERNAL streams (landedS/failedS/…) that the promise flow subscribes to. That's the single path —
-- the _AF_TEST seam calls the very same hit_* adapters, so specs drive the flow with no second
-- line-matching path to drift. Read this block top-to-bottom as "every game line that can move a fight."
--
-- Trigger REGEXES run in Swift (not unit-tested); the patterns/anchors below are byte-identical to the
-- old trigger() block, so live matching is unchanged. ALL anchored to ^ (and $ where the message is a
-- whole line) so another player's say/tell — e.g. someone chatting "the guard resists the spell." — can
-- never trip a resolution. None of these patterns overlap on a single line, so registration order among
-- them is immaterial. Guarded on __rx (the dofile fallback at the top guarantees it here and in the
-- harness); fromTrigger no-ops cleanly when the host `trigger` builtin is absent.
local rx = __rx
if rx then
  local T = rx.fromTrigger
  local function tag(pattern, spell) return T(pattern):map(function() return spell end) end

  -- LANDED ─ each spell the routine casts announces its own success line. Merge them into one "a spell
  -- landed" stream tagged with the spell name and push it onto landedS; the in-flight castStep await
  -- resolves on ITS spell. VERIFIED live: icebolt "You create and magically throw bolts of ice at <x>!",
  -- fireball has TWO landed forms: "You conjure and throw a <size/colour> fireball at <x>!" AND (verified
  -- live) "You throw a <size/colour> fireball at <x>!" — the "conjure and " prefix is optional, so it's
  -- wildcarded along with the adjectives. prism
  -- the crystal line, frostflower the whole-line AOE message. DORMANT: shower isn't in the routine, so no
  -- stage ever awaits "shower" — the push has no subscriber and is dropped; kept only so its wire string
  -- stays live for a future mana-aware feature.
  local spellLanded = rx.merge(
    tag([[^A .* bolt of lightning leaps from you to ]], "lightning"),
    tag([[^You create and magically throw bolts of ice at ]], "icebolt"),
    tag([[^You (?:conjure and )?throw a .* fireball at ]], "fireball"),
    tag([[^You use a small crystal to focus your powers and throw a confusing wash of color and force at ]], "prism"),
    tag([[^Spiked flowers of ice quickly form on everything in a ring around you!$]], "frostflower"),
    tag([[^A shower of .* sparks suddenly engulfs]], "shower"))
  spellLanded:subscribe(function(spell) if landedS then landedS:onNext(spell) end end)

  -- fireball BACKFIRE ─ "Your fireball backfires, and blows up in your face!" is a FAILURE outcome (it hit
  -- US, not the target) — route it through the same fail/retry path as a fizzle, NOT the landed stream.
  T([[^Your fireball backfires]]):subscribe(function() hit_fail() end)

  -- SEQUENCE ─ the OPENER (tarrants OR bloodmist) landing. While engaging it just clears the init-busy
  -- flag (combat is about to start); in-combat it advances the phase like any landed spell. bloodmist has
  -- two forms (a single demon / a swarm) — "You tap your life, and … toward" is bloodmist-only (lifetap
  -- says "begin tapping your life"), so the wildcard covers both without matching lifetap.
  local openerLanded = rx.merge(
    tag([[^An ethereal hand appears and attacks .+ from behind!$]], "tarrants"),
    tag([[^You tap your life, and .* toward ]], "bloodmist"))
  openerLanded:subscribe(function(spell) opener_landed(spell) end)

  -- FINISH ─ soulsteal PULLED the soul ("…separate soul from body" — enemy about to die, stop casting)
  -- vs LATCHED (dormant — soul not captured yet; keep nuking the winner until the latch fires).
  local soulPulled  = T([[^You cast the spell to separate soul from body]])
  local soulLatched = T([[^You magically latch onto .+ soul and wait for .+ to weaken]])
  soulPulled:subscribe(function()  hit_soulsteal_ok() end)
  soulLatched:subscribe(function() hit_soul_latched() end)
  -- Soulsteal that couldn't individuate a soul ("Your spell fails to latch on to an individual soul!") —
  -- another "steal didn't land" outcome; route it like a resist (re-nuke the winner once, then retry).
  local soulNoLatch = T([[^Your spell fails to latch on to an individual soul!$]])
  soulNoLatch:subscribe(function() hit_soul_nolatch() end)
  -- Soulsteal on a NON-LIVING target ("You can only soulsteal from living things.") — undead, constructs,
  -- or an already-dead body. See hit_soul_unstealable: it resolves the in-flight steal (the terminator
  -- that was MISSING — its absence deadlocked autofight and stopped it mid-fight) and keeps nuking.
  local soulNotLiving = T([[^You can only soulsteal from living things\.$]])
  soulNotLiving:subscribe(function() hit_soul_unstealable() end)

  -- PACING failures ─ a fizzle ("You fail to cast…") or a resist retries the SAME spell (soulsteal resist
  -- re-nukes once, then retries); out-of-mana marks the spell and WAITS (no retry, no spam).
  local castFailed   = T([[^You fail to cast the spell]])
  local castResisted = T([[^.+ resists the spell\.$]])
  local outOfMana    = T([[^You don't have enough mana\.$]])
  castFailed:subscribe(function()   hit_fail() end)
  castResisted:subscribe(function() hit_resist() end)
  outOfMana:subscribe(function()    hit_mana() end)

  -- The enemy health bar (kxwt_fighting — many ticks/second; the winner-probe signal, and it NEVER casts)
  -- and the two combat boundaries. enemyDead ends the fight from any phase; combatEnd (kxwt -1) resolves
  -- the fight promise + zeroes the crowd estimate.
  local combatBar = T([[^kxw[tq]_fighting (\d+) \S+ (.+)$]])
  local combatEnd = T([[^kxw[tq]_fighting -1$]])
  local enemyDead = T([[^.+ is DEAD!$]])
  combatBar:subscribe(function(c) on_kxwt_fight(tonumber(c[1]), c[2]) end)
  combatEnd:subscribe(function()  on_kxwt_end() end)
  enemyDead:subscribe(function()  hit_dead() end)

  -- Near-death latch: the game tells us OUR TARGET is nearly dead → switch to soulsteal at the next frame
  -- boundary. Target-matched (note_near_death) so a NEARBY creature's near-death can't mis-latch.
  trigger([[^(.+) is near death!$]], function(n) note_near_death(n) end)
  trigger([[^(.+) is mortally wounded, and will die soon]], function(n) note_near_death(n) end)

  -- ENGAGE guard ─ the target simply isn't here ("Target who?") → give up initiating (retrying the opener
  -- is pointless with nothing to aggro).
  T([[^Target who\?]]):subscribe(function() engage_target_missing() end)

  -- CROWD (AOE) ─ a room listing prints one "<X> is here, fighting <Y>." per engaged creature; count the
  -- hostile subjects (note_room_fighter filters out our minions/self) so a look mid-fight flips us to AOE
  -- without waiting for a kill. Each enemy death (kxwt_mdeath) counts the estimate down — that's what
  -- drops us back to single target on the last one.
  local roomFighter = T([[^(.+) is here, fighting .+$]])
  local enemyDeath  = T([[^kxw[tq]_mdeath (.+)$]])
  roomFighter:subscribe(function(c) note_room_fighter(c[1]) end)
  enemyDeath:subscribe(function(c)  note_mdeath(c[1]) end)

  -- TANK rescue ─ kxwt_ydeath latches "one of my minions died"; the following kxwt_group_end says whether
  -- it was the tank (our remembered tank is now gone) and, if so, triggers the rescue; a clay man
  -- rejoining stops the re-summon loop. The group_end subscriber runs AFTER AlterAeon's (which fills
  -- state.group; AlterAeon loads first), so the roster is fresh when refresh_tank reads it.
  T([[^kxw[tq]_ydeath ]]):subscribe(function() tank_ydeath() end)
  T([[^kxw[tq]_group_end$]]):subscribe(function() refresh_tank() end)
  T([[^You add .*clay man to your group\.$]]):subscribe(function() tank_resummoned() end)
  T([[^You already have .*clay man at your side\.$]]):subscribe(function() tank_resummoned() end)
  -- (No rvnum reset: the server re-sends rvnum on a plain `look`, so resetting here would flicker us out
  -- of AOE on every look. Leaving a room ends combat (kxwt_fighting -1), and on_fight_end already zeroes
  -- the crowd estimate — so the authoritative combat-end signal covers the "walked away" case.)
end

-- SUSPEND ─ user input is its own hot stream (a Subject, not fromTrigger: typed input isn't a game line).
-- We push each typed command in, then CHAIN the previous on_user_input (AIPilot defines one; we must not
-- clobber it). observe_input suspends the routine on a command WE didn't send, so the user can intervene.
local userInput = rx and rx.subject() or nil
if userInput then userInput:subscribe(function(cmd) observe_input(cmd) end) end
local _prev_on_user_input = on_user_input
function on_user_input(cmd)
  if userInput then userInput:onNext(cmd) end
  if _prev_on_user_input then return _prev_on_user_input(cmd) end
end

-- ---- control surface -----------------------------------------------------------------------------
local function status_line()
  local bits = string.format("%s · phase=%s", F.on and "ON" or "OFF", F.phase)
  if F.fighting then bits = bits .. string.format(" · %s %s%%", F.name or "?", tostring(F.pct or "?")) end
  if F.winner then bits = bits .. " · winner=" .. F.winner end
  bits = bits .. " · aoe=" .. F.aoe_mode .. (aoe_active() and "*" or "")   -- * = AOE active right now
  if F.suspended then bits = bits .. " · SUSPENDED (manual)" end
  return "[autofight] " .. bits
end

autofight = {}

-- Public toggle for the tank-rescue block (machinery is defined up above, before the trigger block).
-- autofight.tank('on'|'off'|'status').
function autofight.tank(mode)
  mode = (mode or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  if mode == "on" then TANK.on = true; say("tank rescue on")
  elseif mode == "off" then TANK.on = false; stop_resummon(); say("tank rescue off")
  else
    say("tank rescue " .. (TANK.on and "on" or "off")
        .. (TANK.name and (" — tank: " .. TANK.name) or " — no tank seen")
        .. (TANK.resummoning and (" (re-summoning, try " .. TANK.tries .. ")") or ""))
  end
end
doc(autofight.tank, { name = "autofight.tank", sig = "autofight.tank(['on'|'off'|'status'])", group = "combat",
  text = "When your TANK — a minion of yours that's tanking (kxwt group flags M+T), e.g. a summoned clay "
      .. "man or flesh beast — dies, turn OFF corpse automation and re-cast 'clay man' on a pace until one "
      .. "rejoins the group, restoring your front line. On by default; runs whether or not auto-fight is armed." })

function autofight.on()
  F.on = true
  say("armed — tarrants → lightning/fireball probe → nuke winner → soulsteal")
  -- Armed mid-fight (e.g. after a manual off): (re)start the reactive flow on the current enemy.
  if F.fighting and combatStartS then combatStartS:onNext(true) end
end

function autofight.off()
  F.on = false
  end_fight()
  F.fought = false
  say("disarmed")
end

function autofight.status() if echo then echo(status_line()) end end

-- current() — the in-flight fight as a PROMISE (or nil when not fighting): resolves when this engagement
-- ends. Lets you chain off combat — autofight.current() and autofight.current().andThen(function() ...) —
-- e.g. loot then explore once the fight is over. The fight also shows as an "autofight: <enemy>" row in
-- the HUD promise widget on its own; this just hands you the handle.
function autofight.current() return F.fight_promise end
doc(autofight.current, { name = "autofight.current", sig = "autofight.current() -> promise|nil", group = "combat",
  text = "The current fight as a promise (nil when not fighting), resolving when combat ends. Chain off "
      .. "it — autofight.current().andThen(...) — to act once the fight is over. Also shown as an "
      .. "'autofight: <enemy>' row in the HUD promise widget." })

-- aoe([mode]) — control room-AOE (frostflower) use. "auto" (default): AOE once a pack is detected (a
-- kill that rolls straight onto another enemy); "on": always AOE; "off": never. No arg reports current.
function autofight.aoe(mode)
  mode = (mode or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if mode == "" then
    say(string.format("AOE mode: %s%s", F.aoe_mode, aoe_active() and " (active now)" or ""))
  elseif mode == "on" or mode == "off" or mode == "auto" then
    F.aoe_mode = mode
    say("AOE mode → " .. mode .. (mode == "auto" and " (frostflower once a pack is detected)" or ""))
  else
    say("usage: autofight aoe on|off|auto")
  end
end
doc(autofight.aoe, { name = "autofight.aoe", sig = "autofight.aoe(['on'|'off'|'auto'])", group = "combat",
  text = "Control room-AOE. In a pack the routine casts frostflower on repeat instead of the "
      .. "single-target probe/nuke. 'auto' (default) switches to AOE once a kill rolls straight onto "
      .. "another enemy (no combat break); 'on' always AOEs; 'off' never does. No arg reports the mode." })

-- winners() — list the learned best-spell-per-target-name memory. forget([name]) — drop one learned
-- entry (by name), or ALL of them when called with no name; both persist the change.
function autofight.winners()
  if not echo then return end
  local keys = {}
  for k in pairs(_AUTOFIGHT.winners) do keys[#keys + 1] = k end
  table.sort(keys)
  if #keys == 0 then echo("[autofight] no learned winners yet"); return end
  echo(string.format("[autofight] learned winners (%d):", #keys))
  for _, k in ipairs(keys) do echo(string.format("  %s → %s", k, _AUTOFIGHT.winners[k])) end
end

function autofight.forget(name)
  if name == nil then
    _AUTOFIGHT.winners = {}; schedule_winners_save(); say("forgot ALL learned winners"); return
  end
  local key = winner_key(name)
  if key and _AUTOFIGHT.winners[key] then
    _AUTOFIGHT.winners[key] = nil; schedule_winners_save(); say("forgot " .. key)
  else
    say("nothing learned for " .. (key or tostring(name)))
  end
end

doc(autofight.winners, { name = "autofight.winners", sig = "autofight.winners()", group = "combat",
  text = "List the learned best-spell-per-target memory: for each target name the script has probed, "
      .. "which of icebolt/fireball/prism won. Known names skip the probe on the next fight." })
doc(autofight.forget, { name = "autofight.forget", sig = "autofight.forget([name])", group = "combat",
  text = "Forget a learned winner so it re-probes next time: pass a target name to drop just that one, "
      .. "or call with no argument to clear the whole memory. Persists the change." })

-- unstealable([name]) — the persisted "no soul, never soulsteal" memory (undead/constructs/dead bodies
-- the game rejected with "You can only soulsteal from living things"). No arg LISTS it; a name FORGETS that
-- entry (it'll try soulsteal again, re-learning if still rejected); 'all'/'clear' wipes the whole memory.
function autofight.unstealable(name)
  if name == nil then
    if not echo then return end
    local keys = {}
    for k in pairs(_AUTOFIGHT.unstealable) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys == 0 then echo("[autofight] no known soulless targets yet"); return end
    echo(string.format("[autofight] soulless targets (%d) — soulsteal is skipped for these:", #keys))
    for _, k in ipairs(keys) do echo("  " .. k) end
    return
  end
  local arg = tostring(name):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if arg == "all" or arg == "clear" then
    _AUTOFIGHT.unstealable = {}; schedule_unstealable_save(); say("forgot ALL soulless targets"); return
  end
  local key = winner_key(name)
  if key and _AUTOFIGHT.unstealable[key] then
    _AUTOFIGHT.unstealable[key] = nil; schedule_unstealable_save()
    say("forgot soulless '" .. key .. "' — will try soulsteal again")
  else
    say("'" .. (key or arg) .. "' isn't marked soulless")
  end
end
doc(autofight.unstealable, { name = "autofight.unstealable", sig = "autofight.unstealable([name])",
  group = "combat", text = "The persisted 'no soul — never soulsteal' memory: targets the game rejected "
      .. "with \"You can only soulsteal from living things\" (undead, constructs, dead bodies). The routine "
      .. "skips the soulsteal stage for these and just nukes them down. No arg lists them; a target name "
      .. "forgets that one (it'll try soulsteal again); 'all' clears the whole memory. Persists." })

-- winner(name[, spell]) — manually SET (override) the learned attack for a target NAME. Use it when the
-- probe mislearned: it picked the element the enemy RESISTS, or — worse — one that HEALS it (a cold mob
-- healed by icebolt, a fire one by fireball). `spell` is one of PROBE_SPELLS ('icebolt' cold / 'fireball' fire
-- / 'prism'), the spells the routine nukes with. No spell → report the current winner; 'none'/'clear' →
-- forget it (re-probe next fight). Persists, skips the probe for that name, and switches the CURRENT fight.
function autofight.winner(name, spell)
  local key = name and winner_key(name)
  if not key or key == "" then
    say("usage: autofight.winner('<enemy name>', '" .. table.concat(PROBE_SPELLS, "'|'") .. "')  — force which spell to nuke it with")
    return
  end
  local s = (spell or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if s == "" then
    local cur = _AUTOFIGHT.winners[key]
    say(cur and (key .. " → " .. cur) or ("no learned winner for '" .. key .. "'"))
    return
  end
  if s == "none" or s == "clear" or s == "forget" then
    _AUTOFIGHT.winners[key] = nil; schedule_winners_save(); say("forgot '" .. key .. "' — will re-probe")
    return
  end
  if not is_probe_spell(s) then
    say("winner must be one of " .. table.concat(PROBE_SPELLS, "/") .. " (the spells the routine nukes with) — got '" .. s .. "'")
    return
  end
  remember_winner(name, s)   -- set + persist; the next fight vs this name skips the probe and nukes `s`
  -- Fighting this exact target right now? Switch immediately — don't keep casting the wrong (maybe
  -- healing!) spell until the fight ends.
  if F.fighting and F.name and winner_key(F.name) == key then
    -- Mark it known: the fight flow reads F.known_winner right after the opener lands (afterOpener), so it
    -- skips the probe and nukes `s` instead of continuing to cast the wrong (maybe HEALING) element.
    F.known_winner, F.winner, F.winner_spell = s, cfg[s .. "_cmd"], s
    say("overriding the CURRENT fight → " .. s)
  end
  say("'" .. key .. "' → " .. s .. " (set, persisted)")
end
doc(autofight.winner, { name = "autofight.winner", sig = "autofight.winner(name[, 'icebolt'|'fireball'])",
  group = "combat", text = "Manually override the learned attack spell for a target NAME — for when the "
      .. "probe mislearned and picked the element the enemy RESISTS or is HEALED by. 'icebolt' (cold) or "
      .. "'fireball' (fire); no spell reports the current winner; 'none' forgets it. Persists, skips the "
      .. "probe for that name, and switches the current fight immediately if you're fighting it." })

-- engage(target[, on_dead][, on_fail]) — START a fight from out of combat. Sets the target and casts
-- the opener (tarrants) to actually aggro it, retrying the opener until it lands (up to cfg.max_tries);
-- once combat starts the normal routine takes over, skipping a second opener. on_dead() fires when the
-- fight ends; on_fail(reason) fires if the opener can't be landed. The promise layer's attack() wraps
-- this into a promise; call it directly if you just want the callbacks.
function autofight.engage(target, on_dead, on_fail)
  F.on = true
  end_fight()                                            -- clear any stale fight/init state
  F.fought = false                                       -- fresh engagement: re-armed when start_fight lands
  F.on_dead, F.on_fail = on_dead, on_fail
  F.engaging, F.engage_busy, F.engage_tries = true, false, 0
  -- You INITIATED this fight (attack/engage), so latch auto-assist (Combat.lua) OFF for it: the "rescues
  -- you"/"jumps to your side" lines that immediately follow must not also fire `assist` — you're already in.
  -- state.fighting hasn't been set yet (enemy_hp_data lags the opener), so this latch is what stops the
  -- redundant assist ("You are already fighting …"). ncombat clears state.assisted when the fight ends.
  state.assisted = true
  F.opener_primed = true                                 -- start_fight will skip re-casting the opener
  say(string.format("engaging %s — casting the opener to start the fight", tostring(target)))
  af_send("target " .. tostring(target))
  send_opener()
end
doc(autofight.engage, { name = "autofight.engage", sig = "autofight.engage(target[, on_dead][, on_fail])",
  group = "combat", text = "Start a fight from out of combat: set the target and cast the opener "
      .. "(tarrants) to aggro it, retrying until it lands, then hand off to the normal auto-fight "
      .. "routine. on_dead() fires when the fight ends; on_fail(reason) if the opener can't be landed. "
      .. "attack() wraps this into a chainable promise." })

-- attack(target) — the promise-layer builder: engage `target` and return a PROMISE (Scripts/Promise.lua)
-- that resolves when it dies and rejects if the fight can't be started. Chain it: recover(95).andThen(attack('orc')).
function attack(target)
  return __promise(function(resolve, reject, onCancel)
    autofight.engage(target, function() resolve() end, function(reason) reject(reason) end)
    onCancel(function() autofight.off() end)   -- chain aborted: disarm auto-fight
  end, "attack")
end
doc("attack", { sig = "attack(target) -> promise", group = "combat",
  text = "Engage `target` (via autofight.engage) and return a promise that resolves when it dies and "
      .. "rejects if the fight can't be started. Chain with .andThen — e.g. recover(95).andThen(attack('orc')).",
  example = "#attack('orc')" })

doc(autofight.on, { name = "autofight.on", sig = "autofight.on()", group = "combat",
  text = "Arm the deterministic auto-fight routine: on combat start it casts tarrants (once), probes "
      .. "icebolt vs fireball and keeps the harder-hitting one, then soulsteals when the enemy is nearly "
      .. "dead (re-nuking on a resist). Paced (one cast per resolution) and OFF by default; any command "
      .. "YOU type suspends it briefly so you can intervene." })
doc(autofight.off, { name = "autofight.off", sig = "autofight.off()", group = "combat",
  text = "Disarm the auto-fight routine and end any in-progress fight tracking." })
doc(autofight.status, { name = "autofight.status", sig = "autofight.status()", group = "combat",
  text = "Show whether auto-fight is armed, the current phase, the target/health%, and the chosen "
      .. "winner spell." })

-- Legacy typed `autofight on|off|status|winners|forget [name]` still works via the command bridge.
setmetatable(autofight, { __call = function(_, rest)
  rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local verb, arg = rest:match("^(%S*)%s*(.*)$")
  verb = (verb or ""):lower()
  if verb == "on" then autofight.on()
  elseif verb == "off" then autofight.off()
  elseif verb == "aoe" then autofight.aoe(arg)
  elseif verb == "winners" then autofight.winners()
  elseif verb == "forget" then autofight.forget(arg ~= "" and arg or nil)
  elseif verb == "winner" then
    -- "winner <enemy name...> <spell>" — the enemy name can have spaces, so the SPELL is the last word.
    -- If the last word isn't a spell keyword, treat the whole thing as a name (report the current winner).
    local last = arg:match("(%S+)%s*$")
    local lw = last and last:lower()
    if is_probe_spell(lw) or lw == "none" or lw == "clear" or lw == "forget" then
      autofight.winner(arg:match("^(.-)%s+%S+%s*$"), last)
    else
      autofight.winner(arg ~= "" and arg or nil)
    end
  else autofight.status() end
end })

-- Game-line aliases so the controls work typed straight in (no `#` needed), like explore/goto/noexit:
-- `autofight` alone reports status; `autofight <verb …>` dispatches (on/off/aoe/winners/forget/winner),
-- e.g. `autofight winner A ghostly presence fireball`. (`#autofight …` via the REPL still works too.)
if alias then
  alias([[^autofight$]], function() autofight() end)
  alias([[^autofight (.+)$]], function(_, rest) autofight(rest) end)
end

-- ---- test seam -----------------------------------------------------------------------------------
-- The spec drives the state machine by calling the SAME handlers the live triggers call — there is no
-- second line-matching path to drift. on_fight is the kxwt_fighting handler; icebolt/fireball/… are the
-- resolution handlers each trigger dispatches to.
_AF_TEST = {
  cfg           = cfg,
  sent          = sent,                                   -- captured send sequence (shared table)
  state         = function() return F end,
  on_fight      = on_fight,
  on_fight_end  = on_fight_end,
  on_input      = observe_input,
  lightning     = hit_lightning,   icebolt      = hit_icebolt,     fireball  = hit_fireball,
  tarrants      = hit_tarrants,
  prism         = hit_prism,       bloodmist    = hit_bloodmist,   opener_cmd = opener_cmd,
  is_probe_spell = is_probe_spell, probe_spells = PROBE_SPELLS,    save_winners = save_winners,
  spellset_key  = probe_spellset_key, migrate_winners = migrate_winners,
  frostflower   = hit_frostflower, aoe_active   = aoe_active,   room_fighter = note_room_fighter,
  mdeath        = note_mdeath,
  tank          = function() return TANK end,             -- tank-rescue state (name/resummoning/tries)
  tank_scan     = current_tank_name,                      -- who's tanking, from the current roster
  tank_refresh  = refresh_tank,                            -- kxwt_group_end: (re)track tank + detect its death
  tank_ydeath   = tank_ydeath,                             -- kxwt_ydeath: latch "a minion of mine died"
  tank_resummoned = tank_resummoned,                      -- a clay man rejoined (stop the loop)
  shower        = hit_shower,       -- dormant handler, exposed so its no-op can be verified
  resist        = hit_resist,      mana         = hit_mana,        fail      = hit_fail,
  target_missing = engage_target_missing,
  soulsteal_ok  = hit_soulsteal_ok, soul_latched = hit_soul_latched,   dead        = hit_dead,
  soul_nolatch  = hit_soul_nolatch, soul_unstealable = hit_soul_unstealable,
  near_death    = function(name) note_near_death(name) end,
  winner_key    = winner_key,
  winners       = function() return _AUTOFIGHT.winners end,
  remember      = remember_winner,
  unstealable   = function() return _AUTOFIGHT.unstealable end,
  is_unstealable = is_unstealable,
  expire_resume = function()
    if F.suspend_timer and cancel then cancel(F.suspend_timer) end
    F.suspend_timer, F.suspended = nil, false
    if resumeS then resumeS:onNext() end                 -- release the held cast (castStep's resume gate)
  end,
  begin_promise = begin_fight_promise,
  settle_promise = settle_fight_promise,
  fight_promise = function() return F.fight_promise end,
  prompt_bridge = function(pct, name) return __autofight_prompt(pct, name) end,
  mark_prompt   = function(t) last_prompt = t end,          -- set prompt "last seen" for freshness-guard tests
  kxwt_fight    = on_kxwt_fight,                            -- kxwt_fighting fallback handler (ignored while prompt is live)
  kxwt_end      = on_kxwt_end,                              -- kxwt_fighting -1 fallback handler (ditto)
  reset = function()                                      -- clean pre-fight state, armed, for a test
    F.on = true
    end_fight()
    settle_fight_promise()                                -- settle+clear any lingering fight promise
    F.self_sent = {}
    F.aoe_mode, F.pack, F.room_seen, F.enemy_est = "auto", false, 0, 0   -- hermetic: default AOE prefs
    F.room_burst_timer = nil
    clear_sent()
    _AUTOFIGHT.winners = {}   -- hermetic tests: no learned winners bleeding across cases
    _AUTOFIGHT.unstealable = {}   -- ...nor learned soulless targets
  end,
}

if echo then echo(status_line()) end
