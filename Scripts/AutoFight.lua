-- Deterministic (no AI/model) auto-fight combat script for AlterAeon — a rule-based state machine.
--
-- This is INDEPENDENT of the AI pilot (AIPilot.lua). It never calls a model; it just reacts to the
-- combat wire protocol with a fixed opener→probe→nuke→finish routine, opt-in and OFF by default.
--
-- THE ROUTINE (per fight, driven off kxwt_fighting + a few combat lines):
--   1. PROBE:            on COMBAT START, cast c shards (once) then c scorch (once); compare how much each
--                        dropped the enemy's health %; the bigger drop WINS. (Coarse % heuristic — fine.)
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
-- PACING (the important bit — NEVER spam, and NEVER timed): after we send a cast we set `busy` and send
-- NOTHING until we SEE that spell's own success line (it LANDED) — then we cast the next. If the cast
-- FAILS ("You fail to cast…", or it resisted), we retry the SAME spell (up to cfg.max_tries). The enemy
-- health bar (kxwt_fighting) updates several times a second and must NEVER trigger a cast — casting on
-- every tick was the command-spam bug. Out-of-mana marks the spell and we WAIT (no retry, no spam).
--
-- NOTE: the single opener is `c tarrants` (tarrant's spectral hand — its landed line is "An ethereal
-- hand appears and attacks <target> from behind!", confirmed against the help corpus + a live log). The
-- earlier earth-wall opener was removed by request.
--
-- Wire strings below are VERBATIM from the player's raw logs (mud_raw_copy.log / mud_raw_nomelee.log),
-- not invented. See Scripts/tests/autofight_spec.lua, which replays a real Gnomian-guard fight.
--
-- Controls:  autofight.on() · autofight.off() · autofight.status();  help(autofight). Hot-reloadable.

state = state or {}   -- defensive: this file may load before AlterAeon.lua under the directory loader.

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
  opener_tarrants  = "c tarrants",   -- tarrant's spectral hand — the one opener (see NOTE at top)
  shards_cmd       = "c shards",
  scorch_cmd       = "c scorch",
  soulsteal_cmd    = "c soulsteal",
  aoe_cmd          = "c frostflower",-- room AOE, used instead of the single-target probe/nuke on a pack
  -- DORMANT: shower was the 2nd probe before scorch. Kept (with its landed trigger + hit_shower() below)
  -- so its wire strings survive for a future feature — mana-aware spell switching as we run low. The
  -- routine never casts it, so this string is unused today; nothing sends it.
  shower_cmd       = "c shower",     -- shower of sparks
}

-- Survive pilot.reload(): keep the on/off toggle and any in-flight fight state in a global. Armed by
-- default on a FRESH session (`on = true`); a live reload preserves whatever you last toggled it to,
-- so an explicit autofight.off() sticks across reloads within a session.
_AUTOFIGHT = _AUTOFIGHT or { on = true }
local F = _AUTOFIGHT
-- Default the runtime fields (idempotent across reloads).
F.fighting          = F.fighting or false
F.phase             = F.phase or "idle"
F.busy              = F.busy or false
F.suspended         = F.suspended or false
F.self_sent         = F.self_sent or {}     -- cmd -> count of sends WE issued (echo/suspend disambiguation)
F.no_mana           = F.no_mana or {}       -- spell -> true once we've been told we can't afford it
F.shards_drop       = F.shards_drop or 0
F.scorch_drop       = F.scorch_drop or 0
-- engage() state: initiating a fight from out of combat by casting the opener (`target x` alone doesn't
-- aggro). `engaging` is true from the first opener cast until combat actually starts; `opener_primed`
-- tells start_fight the tarrants opener was already thrown so it skips straight to the probe.
F.engaging          = F.engaging or false
F.engage_busy       = F.engage_busy or false
F.engage_tries      = F.engage_tries or 0
F.opener_primed     = F.opener_primed or false
F.on_dead           = F.on_dead or nil      -- called once when an engaged fight ends
F.on_fail           = F.on_fail or nil      -- called if we can't get the opener to land
F.soul_latched      = F.soul_latched or false  -- dormant soulsteal latched; keep nuking, don't re-cast it
-- AOE (crowd) handling. `aoe_mode` is a preference that survives reload: "auto" uses frostflower once we
-- know it's a pack, "on" always AOEs, "off" never does. `pack` is this-combat belief that there are
-- multiple enemies — set when a kill rolls straight onto another target (no kxwt -1), cleared when
-- combat truly ends. See aoe_active().
F.aoe_mode          = F.aoe_mode or "auto"
F.pack              = F.pack or false
F.room_seen         = F.room_seen or 0      -- tally of hostile "is here, fighting" lines in the current burst
F.enemy_est         = F.enemy_est or 0      -- estimated engaged hostiles: set by a look, counted down by deaths

-- Command capture, always on (cheap, cleared each fight) so the test harness can read the exact send
-- sequence without stubbing the host `send`. `_AF_TEST.sent` aliases this table.
local sent = {}
local function clear_sent() for i = #sent, 1, -1 do sent[i] = nil end end

local function say(s) if echo then echo("\27[1;35m[autofight]\27[0m " .. s) end end

-- ---- learned winners (per target NAME) -----------------------------------------------------------
-- Remember which probe spell won against a given target so the next fight against the same name skips
-- the shards/scorch probe and nukes the known winner straight away. Keyed by a normalized name (lower-
-- cased, leading article stripped) so "a Gnomian guard" / "The Gnomian guard" collapse to one entry.
-- Persisted to disk (mirrors AlterAeon's classes.lua) so it survives a relaunch; kept on _AUTOFIGHT so
-- it also survives a live pilot.reload().
local function winner_key(name)
  if not name then return nil end
  local k = tostring(name):lower():gsub("^%s+", ""):gsub("%s+$", "")
  k = k:gsub("^an? ", ""):gsub("^the ", "")     -- drop a leading "a "/"an "/"the "
  return (k ~= "" and k) or nil
end

local WINNERS_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/autofight_winners.lua"
local function save_winners()
  local f = io.open(WINNERS_FILE, "w")
  if not f then return end
  local parts = {}
  for name, spell in pairs(_AUTOFIGHT.winners) do parts[#parts + 1] = string.format("[%q]=%q", name, spell) end
  f:write("return {" .. table.concat(parts, ",") .. "}")
  f:close()
end
-- Debounce writes: coalesce a burst of updates into one save 2s after the last (same trick as classes).
local winners_save_timer
local function schedule_winners_save()
  if cancel and winners_save_timer then cancel(winners_save_timer) end
  winners_save_timer = after and after(2, save_winners) or nil
end
-- Load from disk ONCE per session (not on a live reload, where _AUTOFIGHT.winners already holds the
-- current, possibly-newer table).
if not _AUTOFIGHT.winners then
  _AUTOFIGHT.winners = {}
  local chunk = loadfile and loadfile(WINNERS_FILE)
  if chunk then local ok, t = pcall(chunk); if ok and type(t) == "table" then _AUTOFIGHT.winners = t end end
end

-- Record (and persist) the probe's verdict for this target. Only writes on a real change.
local function remember_winner(name, spell)
  local key = winner_key(name)
  if not key or (spell ~= "shards" and spell ~= "scorch") then return end
  if _AUTOFIGHT.winners[key] ~= spell then
    _AUTOFIGHT.winners[key] = spell
    schedule_winners_save()
    say(string.format("learned: %s → %s", key, spell))
  end
end

-- Forward declarations (mutually recursive).
local fire, cast, succeed, fail_again

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
local function send_opener() F.engage_busy = true; af_send(cfg.opener_tarrants) end

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

-- Send the cast for `spell` and go `busy`. NO timer — we stay busy until we SEE that spell's own
-- success line (succeed) or a failure line (fail_again). `busy` is the only thing gating sends, so we
-- can never have two casts outstanding and can never spam.
cast = function(cmd, spell)
  F.busy, F.busy_spell, F.busy_pct = true, spell, F.pct
  af_send(cmd)
end

-- Should we AOE (frostflower the whole room) rather than single-target this fight? "on"/"off" force it;
-- "auto" (default) AOEs once we believe we're in a pack (F.pack — set when a kill rolls straight onto
-- another enemy; see on_fight). A single-target fight uses the normal tarrants→probe→nuke→soulsteal.
local function aoe_active()
  if F.aoe_mode == "on"  then return true  end
  if F.aoe_mode == "off" then return false end
  return F.pack                                       -- "auto"
end

-- Advance the phase to the next spell in the routine. (nuke stays nuke — keep nuking the winner;
-- soulsteal stays soulsteal — its success is handled by the soulsteal line, not a generic "landed";
-- aoe stays aoe — keep frostflowering the pack until combat ends or the target rolls over.)
local function next_phase()
  local p = F.phase
  if     p == "tarrants"  then F.phase = aoe_active() and "aoe" or (F.known_winner and "nuke" or "shards")
  elseif p == "shards"    then F.phase = "scorch"
  elseif p == "scorch"    then F.phase = "decide"
  elseif p == "aoe"       then F.phase = "aoe"
  elseif p == "renuke"    then F.phase = "soulsteal"   -- the one post-resist nuke landed → back to soulsteal
  end
end

-- Send exactly ONE cast for the current phase. Retry-safe: it does NOT advance the phase — SUCCESS does
-- that. Handles the two send-free transitions (decide → pick winner; nuke → soulsteal when nearly dead)
-- inline. This is the ONLY function that sends, and it only runs from start_fight, succeed, fail_again,
-- and resume — never from a health-% update.
fire = function()
  if not F.on or not F.fighting or F.suspended or F.busy then return end
  if F.phase == "decide" then
    -- Coarse winner pick: whichever probe dropped the enemy health % more. Ties → shards.
    if F.shards_drop >= F.scorch_drop then F.winner, F.winner_spell = cfg.shards_cmd, "shards"
    else F.winner, F.winner_spell = cfg.scorch_cmd, "scorch" end
    remember_winner(F.name, F.winner_spell)   -- learn it so the next fight vs this name skips the probe
    F.phase = "nuke"
  end
  -- Switch to soulsteal when nearly dead — UNLESS a dormant soulsteal is already latched (then we just
  -- keep nuking to weaken the target so the latch fires; re-casting soulsteal would be wasted).
  if F.phase == "nuke" and not F.soul_latched and F.pct and F.pct > 0 and F.pct <= cfg.soulsteal_pct then
    F.phase = "soulsteal"
  end
  local p = F.phase
  if     p == "tarrants"               then cast(cfg.opener_tarrants, "tarrants")
  elseif p == "shards"                 then F.last_damage_spell = "shards"; cast(cfg.shards_cmd, "shards")
  elseif p == "scorch"                 then F.last_damage_spell = "scorch"; cast(cfg.scorch_cmd, "scorch")
  elseif p == "aoe"                    then F.last_damage_spell = "aoe"; cast(cfg.aoe_cmd, "frostflower")
  elseif p == "nuke" or p == "renuke"  then F.last_damage_spell = F.winner_spell; cast(F.winner, F.winner_spell)
  elseif p == "soulsteal"              then cast(cfg.soulsteal_cmd, "soulsteal")
  end   -- "done"/"idle": nothing to send
end

-- The spell we were casting LANDED (its own success line). `spell` must match what we're casting, so a
-- straggler line for a previous cast is ignored. Advance the phase and fire the next spell.
succeed = function(spell)
  if not F.busy or (spell and F.busy_spell ~= spell) then return end
  F.busy, F.busy_spell, F.tries = false, nil, 0
  next_phase()
  fire()
end

-- The current cast FAILED ("You fail to cast", or a damage spell resisted). Try the SAME spell again,
-- up to cfg.max_tries; after that give up on it and move on so a spell the character can't cast (e.g. an
-- unknown opener) doesn't stall the whole routine forever. Out-of-mana is handled separately (we wait).
fail_again = function()
  if not F.busy then return end
  F.busy, F.busy_spell = false, nil
  F.tries = (F.tries or 0) + 1
  if F.tries >= cfg.max_tries then F.tries = 0; next_phase() end
  fire()
end

-- ---- fight lifecycle -----------------------------------------------------------------------------
local function start_fight(pct, name)
  F.fighting, F.pct, F.name = true, pct, name
  -- Do we already know the winning spell for this target name? If so, skip the probe entirely.
  local key = winner_key(name)
  local known = key and _AUTOFIGHT.winners[key]
  F.known_winner = (known == "shards" or known == "scorch") and known or nil
  if F.known_winner then
    F.winner, F.winner_spell = cfg[F.known_winner .. "_cmd"], F.known_winner
    say(string.format("%s known → %s (skipping probe)", key, F.known_winner))
  end
  -- Phase: AOE (a pack) skips the single-target opener AND probe — we're already in combat, so go
  -- straight to frostflower. Otherwise engage() may have already thrown the opener (opener_primed); the
  -- post-opener phase is the nuke when we know the winner, else the shards/scorch probe; a fresh
  -- single-target fight opens with tarrants.
  local post_opener = F.known_winner and "nuke" or "shards"
  if aoe_active() then F.phase = "aoe"
  else F.phase = F.opener_primed and post_opener or "tarrants" end
  F.engaging, F.engage_busy, F.opener_primed = false, false, false
  F.busy, F.busy_spell = false, nil
  F.shards_drop, F.scorch_drop = 0, 0
  if not F.known_winner then F.winner, F.winner_spell = nil, nil end   -- keep the known winner if set above
  F.last_damage_spell = nil
  F.soul_latched = false
  F.no_mana = {}
  F.suspended = false
  F.self_sent = {}
  if F.busy_timer and cancel then cancel(F.busy_timer); F.busy_timer = nil end
  if F.suspend_timer and cancel then cancel(F.suspend_timer); F.suspend_timer = nil end
  clear_sent()
  fire()
end

local function end_fight()
  F.fighting, F.phase = false, "idle"
  F.busy, F.busy_spell = false, nil
  F.suspended = false
  if F.busy_timer and cancel then cancel(F.busy_timer); F.busy_timer = nil end
  if F.suspend_timer and cancel then cancel(F.suspend_timer); F.suspend_timer = nil end
end

-- ---- AOE crowd tracking --------------------------------------------------------------------------
-- F.enemy_est = our running estimate of how many hostiles are engaged. It's SET from a room listing
-- (a look/auto-look) and COUNTED DOWN as enemies die (kxwt_mdeath). AOE is on (in "auto") whenever the
-- estimate is pack-sized; the moment a death drops it below the threshold we fall back to single target
-- — no second look needed. The estimate only needs to tell "pack (>= aoe_min)" from "not"; undercounting
-- the last one to 0 still yields single target, which is what we want.

-- Enter AOE: remember it and, if we're mid single-target fight, switch to frostflower NOW (cast if free,
-- else the in-flight cast lands first and next_phase keeps AOEing). No-op once already AOEing.
local function enter_pack_mode()
  if F.pack then return end
  F.pack = true
  if F.on and F.fighting and aoe_active() then
    F.phase = "aoe"
    if not F.busy then fire() end
  end
end

-- Leave AOE: the crowd thinned below pack size, so resume single target on the CURRENT enemy (its known
-- winner, else re-probe from shards). No-op if we weren't AOEing (or AOE is force-"on", which pins it).
local function exit_pack_mode()
  if not F.pack then return end
  F.pack = false
  if F.on and F.fighting and not aoe_active() and F.phase == "aoe" then
    F.phase = F.known_winner and "nuke" or "shards"
    if not F.busy then fire() end
  end
end

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

-- kxwt_fighting <pct> <gender> <name> — the enemy health bar. Combat start = not-fighting → fighting.
-- A health-% change is BOTH a pacing resolution AND the winner-comparison signal: while a probe is the
-- most-recent damage spell, any drop is credited to it (coarse — a straggler drop can misattribute, and
-- that's explicitly acceptable).
local function on_fight(pct, name)
  if not F.on then return end
  local was, prev, prevname = F.fighting, F.pct, F.name
  F.pct, F.name = pct, name
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
    if     F.last_damage_spell == "shards" then F.shards_drop = F.shards_drop + d
    elseif F.last_damage_spell == "scorch" then F.scorch_drop = F.scorch_drop + d end
  end
  -- A health-% change updates the winner comparison ONLY. It NEVER triggers a cast — casting is driven
  -- solely by a spell's landed line (or a failure). This is the fix for the command-spam bug: the health
  -- bar ticks several times a second, and the old code cast on every tick.
end

local function on_fight_end()
  local was_engaged_fight = F.fighting and F.on_dead
  F.pack, F.enemy_est = false, 0                         -- combat truly over → next fight re-evaluates
  if F.fighting then end_fight() end
  -- The fight we started via engage() is over (mob dead or fled): fire on_dead exactly once. Guarded on
  -- was-fighting so a stray -1 while we're still trying to land the opener (F.engaging) doesn't resolve.
  if was_engaged_fight then
    local cb = F.on_dead; F.on_dead, F.on_fail = nil, nil
    if cb then cb() end
  end
end

-- ---- combat line resolutions ---------------------------------------------------------------------
-- Each hit_* is what a trigger fires; on_line() (the test seam) classifies a verbatim line and calls the
-- same hit_*, so triggers and tests share one implementation.
local function hit_shards()     succeed("shards")    end   -- "You create and magically throw white shards…"
local function hit_scorch()     succeed("scorch")    end   -- "You throw an intense burst of <color> flames at <target>!"
local function hit_frostflower() succeed("frostflower") end -- "Spiked flowers of ice quickly form on everything in a ring around you!"
-- DORMANT (see cfg.shower_cmd): shower isn't in the routine, so busy_spell is never "shower" and this
-- succeed() always hits its guard and no-ops. Wired only to keep the "A shower of … sparks" string live.
local function hit_shower()     succeed("shower")    end   -- "A shower of <color> sparks suddenly engulfs <target>."
local function hit_tarrants()
  -- Engage opener landed: combat is about to start (kxwt_fighting → start_fight); just clear the
  -- init-busy flag and let start_fight take over. Otherwise it's the normal in-combat opener.
  if F.engaging and not F.fighting then F.engage_busy = false; return end
  succeed("tarrants")
end
local function hit_resist()
  -- Engage opener resisted before combat started: retry the opener.
  if F.engaging and not F.fighting then return engage_retry("resisted") end
  -- soulsteal resisting → re-nuke once, then retry soulsteal. A DAMAGE spell resisting is just a miss → retry.
  if F.busy and F.busy_spell == "soulsteal" then
    F.busy, F.busy_spell, F.tries = false, nil, 0
    F.phase = "renuke"; fire()
  else
    fail_again()
  end
end
local function hit_mana()
  -- Can't afford the engage opener → combat will never start; give up initiating.
  if F.engaging and not F.fighting then return engage_giveup("out of mana") end
  -- Out of mana: DON'T retry and DON'T spam. Mark it and stop; we resume next time we're free to cast.
  if not F.busy then return end
  F.no_mana[F.busy_spell] = true
  F.busy, F.busy_spell = false, nil
end
local function hit_fail()
  if F.engaging and not F.fighting then return engage_retry("cast failed") end   -- engage opener fizzled → retry
  fail_again()
end                                                    -- "You fail to cast the spell '…'." — fizzled, retry

local function hit_soulsteal_ok()
  -- The soul was pulled ("…and pull <x>'s essence into a <color> soulstone!") — the enemy is about to
  -- die. Stop casting; the DEAD line ends the fight. (Also fires when a latched steal finally activates.)
  F.busy, F.busy_spell, F.phase = false, nil, "done"
end

local function hit_soul_latched()
  -- DORMANT soulsteal: "You magically latch onto <x>'s soul and wait for <x> to weaken…". The soul is
  -- NOT captured yet — the spell lies in wait until the target is weak enough. If we stopped here we'd
  -- stall (nothing weakens it). So mark it latched (which stops fire() re-casting soulsteal) and go back
  -- to nuking the winner; the latch fires — the "separate soul from body" success line, then DEAD — as
  -- the target drops. Verified against the human traces (player keeps nuking after this line).
  F.soul_latched = true
  F.busy, F.busy_spell, F.phase = false, nil, "nuke"
  fire()
end

local function hit_dead()
  end_fight()
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
    F.suspend_timer = nil; F.suspended = false; fire()
  end) or nil
end

-- ---- triggers ------------------------------------------------------------------------------------
-- Lines reach triggers ANSI-stripped. Register health-bar + resolution triggers that call the same
-- handlers on_line() does. (Trigger regexes run in Swift and aren't unit-testable — the pure handlers
-- they call are; see the spec.)
if trigger then
  trigger([[^kxwt_fighting (\d+) \S+ (.+)$]], function(_, pct, name) on_fight(tonumber(pct), name) end)
  trigger([[^kxwt_fighting -1$]], function() on_fight_end() end)
  -- ALL anchored to ^ (and $ where the message is a whole line) so another player's say/tell/channel
  -- text — e.g. someone chatting "the guard resists the spell." — can NEVER trip a resolution. Those
  -- lines start with the speaker ("Bob says, '…'"), so ^ excludes them. The messages that begin with a
  -- variable mob name (resist / DEAD) also anchor the tail with $ so a quoted say ("…DEAD!'") is excluded.
  trigger([[^You cast the spell to separate soul from body]], function() hit_soulsteal_ok() end)
  trigger([[^You magically latch onto .+ soul and wait for .+ to weaken]], function() hit_soul_latched() end)
  trigger([[^You create and magically throw white shards of crystal at]], function() hit_shards() end)
  -- scorch (replaced shower as the 2nd probe). Line from live play: "You throw an intense burst of
  -- yellow flames at <target>!" — the flame COLOUR varies, so wildcard it; ^ anchors out say-spoofs.
  trigger([[^You throw an intense burst of .* flames at ]], function() hit_scorch() end)
  -- frostflower (room AOE) landed line — the whole-line message, ^…$ anchored against say-spoofs.
  trigger([[^Spiked flowers of ice quickly form on everything in a ring around you!$]], function() hit_frostflower() end)
  -- DORMANT shower trigger (see cfg.shower_cmd / hit_shower): fires but no-ops, kept only so the string stays live.
  trigger([[^A shower of .* sparks suddenly engulfs]], function() hit_shower() end)
  trigger([[^An ethereal hand appears and attacks .+ from behind!$]], function() hit_tarrants() end)
  trigger([[^.+ resists the spell\.$]], function() hit_resist() end)
  trigger([[^You don't have enough mana\.$]], function() hit_mana() end)
  trigger([[^You fail to cast the spell]], function() hit_fail() end)
  trigger([[^.+ is DEAD!$]], function() hit_dead() end)
  -- Crowd detection: a room listing prints one "<X> is here, fighting <Y>." per engaged creature. Count
  -- the hostile subjects (note_room_fighter filters out our minions/self) — a look mid-fight now flips us
  -- to AOE without waiting for a kill. ^-anchored; the subject is captured, the opponent wildcarded.
  trigger([[^(.+) is here, fighting .+$]], function(_, subject) note_room_fighter(subject) end)
  -- Each enemy death counts down the crowd estimate — this is what drops us out of AOE onto the last one.
  trigger([[^kxwt_mdeath (.+)$]], function(_, name) note_mdeath(name) end)
  -- (No rvnum reset: the server re-sends rvnum on a plain `look`, so resetting here would flicker us out
  -- of AOE on every look. Leaving a room ends combat (kxwt_fighting -1), and on_fight_end already zeroes
  -- the crowd estimate — so the authoritative combat-end signal covers the "walked away" case.)
end

-- Observe typed input non-destructively by CHAINING the existing on_user_input (AIPilot defines one; we
-- must not clobber it). Our observer runs first, then the previous hook.
local _prev_on_user_input = on_user_input
function on_user_input(cmd)
  observe_input(cmd)
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

function autofight.on()
  F.on = true
  say("armed — tarrants → shards/scorch probe → nuke winner → soulsteal")
  if F.fighting and not F.busy then fire() end
end

function autofight.off()
  F.on = false
  end_fight()
  say("disarmed")
end

function autofight.status() if echo then echo(status_line()) end end

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
      .. "which of shards/scorch won. Known names skip the probe on the next fight." })
doc(autofight.forget, { name = "autofight.forget", sig = "autofight.forget([name])", group = "combat",
  text = "Forget a learned winner so it re-probes next time: pass a target name to drop just that one, "
      .. "or call with no argument to clear the whole memory. Persists the change." })

-- engage(target[, on_dead][, on_fail]) — START a fight from out of combat. Sets the target and casts
-- the opener (tarrants) to actually aggro it, retrying the opener until it lands (up to cfg.max_tries);
-- once combat starts the normal routine takes over, skipping a second opener. on_dead() fires when the
-- fight ends; on_fail(reason) fires if the opener can't be landed. The promise layer's attack() wraps
-- this into a promise; call it directly if you just want the callbacks.
function autofight.engage(target, on_dead, on_fail)
  F.on = true
  end_fight()                                            -- clear any stale fight/init state
  F.on_dead, F.on_fail = on_dead, on_fail
  F.engaging, F.engage_busy, F.engage_tries = true, false, 0
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
      .. "shards vs scorch and keeps the harder-hitting one, then soulsteals when the enemy is nearly "
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
  else autofight.status() end
end })

-- ---- test seam -----------------------------------------------------------------------------------
-- The spec drives the state machine by calling the SAME handlers the live triggers call — there is no
-- second line-matching path to drift. on_fight is the kxwt_fighting handler; shards/scorch/… are the
-- resolution handlers each trigger dispatches to.
_AF_TEST = {
  cfg           = cfg,
  sent          = sent,                                   -- captured send sequence (shared table)
  state         = function() return F end,
  on_fight      = on_fight,
  on_fight_end  = on_fight_end,
  on_input      = observe_input,
  shards        = hit_shards,      scorch       = hit_scorch,      tarrants  = hit_tarrants,
  frostflower   = hit_frostflower, aoe_active   = aoe_active,   room_fighter = note_room_fighter,
  mdeath        = note_mdeath,
  shower        = hit_shower,       -- dormant handler, exposed so its no-op can be verified
  resist        = hit_resist,      mana         = hit_mana,        fail      = hit_fail,
  soulsteal_ok  = hit_soulsteal_ok, soul_latched = hit_soul_latched,   dead        = hit_dead,
  winner_key    = winner_key,
  winners       = function() return _AUTOFIGHT.winners end,
  remember      = remember_winner,
  expire_resume = function()
    if F.suspend_timer and cancel then cancel(F.suspend_timer) end
    F.suspend_timer, F.suspended = nil, false; fire()
  end,
  reset = function()                                      -- clean pre-fight state, armed, for a test
    F.on = true
    end_fight()
    F.self_sent = {}
    F.aoe_mode, F.pack, F.room_seen, F.enemy_est = "auto", false, 0, 0   -- hermetic: default AOE prefs
    F.room_burst_timer = nil
    clear_sent()
    _AUTOFIGHT.winners = {}   -- hermetic tests: no learned winners bleeding across cases
  end,
}

if echo then echo(status_line()) end
