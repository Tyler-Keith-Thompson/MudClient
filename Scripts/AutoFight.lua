-- Deterministic (no AI/model) auto-fight combat script for AlterAeon — a rule-based state machine.
--
-- This is INDEPENDENT of the AI pilot (AIPilot.lua). It never calls a model; it just reacts to the
-- combat wire protocol with a fixed opener→probe→nuke→finish routine, opt-in and OFF by default.
--
-- THE ROUTINE (per fight, driven off kxwt_fighting + a few combat lines):
--   1. PROBE:            on COMBAT START, cast c shards (once) then c shower (once); compare how much each
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
  max_tries     = 4,     -- consecutive failures on one spell before we give up on it and move on
  resume_after  = 6,     -- seconds of no manual input before the script resumes after a user command
  soulsteal_pct = 15,    -- enemy health % at/below which we switch to soulsteal ("nearly dead")
  -- Exact commands to send. In-combat casts auto-target the current enemy, so these go out bare.
  opener_tarrants  = "c tarrants",   -- tarrant's spectral hand — the one opener (see NOTE at top)
  shards_cmd       = "c shards",
  shower_cmd       = "c shower",
  soulsteal_cmd    = "c soulsteal",
}

-- Survive pilot.reload(): keep the on/off toggle and any in-flight fight state in a global.
_AUTOFIGHT = _AUTOFIGHT or { on = false }
local F = _AUTOFIGHT
-- Default the runtime fields (idempotent across reloads).
F.fighting          = F.fighting or false
F.phase             = F.phase or "idle"
F.busy              = F.busy or false
F.suspended         = F.suspended or false
F.self_sent         = F.self_sent or {}     -- cmd -> count of sends WE issued (echo/suspend disambiguation)
F.no_mana           = F.no_mana or {}       -- spell -> true once we've been told we can't afford it
F.shards_drop       = F.shards_drop or 0
F.shower_drop       = F.shower_drop or 0
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

-- Command capture, always on (cheap, cleared each fight) so the test harness can read the exact send
-- sequence without stubbing the host `send`. `_AF_TEST.sent` aliases this table.
local sent = {}
local function clear_sent() for i = #sent, 1, -1 do sent[i] = nil end end

local function say(s) if echo then echo("\27[1;35m[autofight]\27[0m " .. s) end end

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

-- Advance the phase to the next spell in the routine. (nuke stays nuke — keep nuking the winner;
-- soulsteal stays soulsteal — its success is handled by the soulsteal line, not a generic "landed".)
local function next_phase()
  local p = F.phase
  if     p == "tarrants"  then F.phase = "shards"    -- opener landed → start the shards/shower probe
  elseif p == "shards"    then F.phase = "shower"
  elseif p == "shower"    then F.phase = "decide"
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
    if F.shards_drop >= F.shower_drop then F.winner, F.winner_spell = cfg.shards_cmd, "shards"
    else F.winner, F.winner_spell = cfg.shower_cmd, "shower" end
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
  elseif p == "shower"                 then F.last_damage_spell = "shower"; cast(cfg.shower_cmd, "shower")
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
  -- If engage() already threw the opener, skip the tarrants phase and go straight to the shards/shower
  -- probe; otherwise this is a normal fight and we open with tarrants as always.
  F.phase = F.opener_primed and "shards" or "tarrants"
  F.engaging, F.engage_busy, F.opener_primed = false, false, false
  F.busy, F.busy_spell = false, nil
  F.shards_drop, F.shower_drop = 0, 0
  F.winner, F.winner_spell, F.last_damage_spell = nil, nil, nil
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

-- kxwt_fighting <pct> <gender> <name> — the enemy health bar. Combat start = not-fighting → fighting.
-- A health-% change is BOTH a pacing resolution AND the winner-comparison signal: while a probe is the
-- most-recent damage spell, any drop is credited to it (coarse — a straggler drop can misattribute, and
-- that's explicitly acceptable).
local function on_fight(pct, name)
  if not F.on then return end
  local was, prev = F.fighting, F.pct
  F.pct, F.name = pct, name
  if not was then start_fight(pct, name); return end
  if prev and pct < prev then
    local d = prev - pct
    if     F.last_damage_spell == "shards" then F.shards_drop = F.shards_drop + d
    elseif F.last_damage_spell == "shower" then F.shower_drop = F.shower_drop + d end
  end
  -- A health-% change updates the winner comparison ONLY. It NEVER triggers a cast — casting is driven
  -- solely by a spell's landed line (or a failure). This is the fix for the command-spam bug: the health
  -- bar ticks several times a second, and the old code cast on every tick.
end

local function on_fight_end()
  local was_engaged_fight = F.fighting and F.on_dead
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
local function hit_shower()     succeed("shower")    end   -- "A shower of <color> sparks suddenly engulfs…"
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
  trigger([[^A shower of .* sparks suddenly engulfs]], function() hit_shower() end)
  trigger([[^An ethereal hand appears and attacks .+ from behind!$]], function() hit_tarrants() end)
  trigger([[^.+ resists the spell\.$]], function() hit_resist() end)
  trigger([[^You don't have enough mana\.$]], function() hit_mana() end)
  trigger([[^You fail to cast the spell]], function() hit_fail() end)
  trigger([[^.+ is DEAD!$]], function() hit_dead() end)
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
  if F.suspended then bits = bits .. " · SUSPENDED (manual)" end
  return "[autofight] " .. bits
end

autofight = {}

function autofight.on()
  F.on = true
  say("armed — tarrants → shards/shower probe → nuke winner → soulsteal")
  if F.fighting and not F.busy then fire() end
end

function autofight.off()
  F.on = false
  end_fight()
  say("disarmed")
end

function autofight.status() if echo then echo(status_line()) end end

-- engage(target[, on_dead][, on_fail]) — START a fight from out of combat. Sets the target and casts
-- the opener (tarrants) to actually aggro it, retrying the opener until it lands (up to cfg.max_tries);
-- once combat starts the normal routine takes over, skipping a second opener. on_dead() fires when the
-- fight ends; on_fail(reason) fires if the opener can't be landed. The sequence layer's attack() wraps
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

-- attack(target) — the sequence-layer builder: engage `target` and return a PROMISE (Scripts/Sequence.lua)
-- that resolves when it dies and rejects if the fight can't be started. Chain it: recover(95).andThen(attack('orc')).
function attack(target)
  return __promise(function(resolve, reject)
    autofight.engage(target, function() resolve() end, function(reason) reject(reason) end)
  end, "attack")
end
doc("attack", { sig = "attack(target) -> promise", group = "combat",
  text = "Engage `target` (via autofight.engage) and return a promise that resolves when it dies and "
      .. "rejects if the fight can't be started. Chain with .andThen — e.g. recover(95).andThen(attack('orc')).",
  example = "#attack('orc')" })

doc(autofight.on, { name = "autofight.on", sig = "autofight.on()", group = "combat",
  text = "Arm the deterministic auto-fight routine: on combat start it casts tarrants (once), probes "
      .. "shards vs shower and keeps the harder-hitting one, then soulsteals when the enemy is nearly "
      .. "dead (re-nuking on a resist). Paced (one cast per resolution) and OFF by default; any command "
      .. "YOU type suspends it briefly so you can intervene." })
doc(autofight.off, { name = "autofight.off", sig = "autofight.off()", group = "combat",
  text = "Disarm the auto-fight routine and end any in-progress fight tracking." })
doc(autofight.status, { name = "autofight.status", sig = "autofight.status()", group = "combat",
  text = "Show whether auto-fight is armed, the current phase, the target/health%, and the chosen "
      .. "winner spell." })

-- Legacy typed `autofight on|off|status` still works via the command bridge.
setmetatable(autofight, { __call = function(_, rest)
  local verb = ((rest or ""):gsub("^%s+", ""):gsub("%s+$", "")):lower()
  if verb == "on" then autofight.on()
  elseif verb == "off" then autofight.off()
  else autofight.status() end
end })

-- ---- test seam -----------------------------------------------------------------------------------
-- The spec drives the state machine by calling the SAME handlers the live triggers call — there is no
-- second line-matching path to drift. on_fight is the kxwt_fighting handler; shards/shower/… are the
-- resolution handlers each trigger dispatches to.
_AF_TEST = {
  cfg           = cfg,
  sent          = sent,                                   -- captured send sequence (shared table)
  state         = function() return F end,
  on_fight      = on_fight,
  on_fight_end  = on_fight_end,
  on_input      = observe_input,
  shards        = hit_shards,      shower       = hit_shower,      tarrants  = hit_tarrants,
  resist        = hit_resist,      mana         = hit_mana,        fail      = hit_fail,
  soulsteal_ok  = hit_soulsteal_ok, soul_latched = hit_soul_latched,   dead        = hit_dead,
  expire_resume = function()
    if F.suspend_timer and cancel then cancel(F.suspend_timer) end
    F.suspend_timer, F.suspended = nil, false; fire()
  end,
  reset = function()                                      -- clean pre-fight state, armed, for a test
    F.on = true
    end_fight()
    F.self_sent = {}
    clear_sent()
  end,
}

if echo then echo(status_line()) end
