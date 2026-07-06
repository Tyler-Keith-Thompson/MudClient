-- Deterministic (no AI/model) auto-fight combat script for AlterAeon — a rule-based state machine.
--
-- This is INDEPENDENT of the AI pilot (AIPilot.lua). It never calls a model; it just reacts to the
-- combat wire protocol with a fixed opener→probe→nuke→finish routine, opt-in and OFF by default.
--
-- THE ROUTINE (per fight, driven off kxwt_fighting + a few combat lines):
--   1. On COMBAT START:  cast earth wall  (once — a buff opener)
--   2.                    c tarrants       (once — a buff opener)
--   3. PROBE:            c shards (once) then c shower (once); compare how much each dropped the
--                        enemy's health %; the bigger drop WINS. (Coarse % heuristic — that's fine.)
--   4. NUKE:             keep casting the WINNER until the enemy is dead.
--   5. FINISH:           when the enemy is NEARLY dead (<= cfg.soulsteal_pct), cast soulsteal. If it's
--                        RESISTED, nuke once more with the winner then retry soulsteal — repeat until it
--                        lands or the enemy dies.
--   6. SUSPEND:          any command the USER types (not one WE sent) suspends the script so they can
--                        intervene; it resumes after cfg.resume_after seconds of no manual input, or when
--                        the fight ends.
--
-- PACING (the important bit — never spam): after sending a cast we set `busy` and refuse to send the
-- next cast until that cast RESOLVES. Resolution = the spell's landed line, a resist, an out-of-mana
-- line, a change in the enemy health %, OR a fallback timeout (cfg.cast_timeout) so we never deadlock
-- waiting on a signal the game didn't send.
--
-- ROBUSTNESS: earth wall (a Druid spell) and tarrants may not be known by this character. Openers are
-- cast exactly once and the machine MOVES ON when they resolve by ANY signal (incl. the timeout and a
-- "You fail to cast" line) — it never retries an opener, so the shards/shower/soulsteal core still runs
-- even if the buffs fail. Out-of-mana on a spell marks it unaffordable for the rest of the fight (we
-- wait rather than spam it).
--
-- Wire strings below are VERBATIM from the player's raw logs (mud_raw_copy.log / mud_raw_nomelee.log),
-- not invented. See Scripts/tests/autofight_spec.lua, which replays a real Gnomian-guard fight.
--
-- Controls:  autofight.on() · autofight.off() · autofight.status();  help(autofight). Hot-reloadable.

state = state or {}   -- defensive: this file may load before AlterAeon.lua under the directory loader.

local cfg = {
  cast_timeout  = 2.5,   -- seconds: fallback that clears `busy` if no resolution line is seen
  resume_after  = 6,     -- seconds of no manual input before the script resumes after a user command
  soulsteal_pct = 15,    -- enemy health % at/below which we switch to soulsteal ("nearly dead")
  -- Exact commands to send. In-combat casts auto-target the current enemy, so these go out bare.
  opener_earthwall = "cast earth wall",
  opener_tarrants  = "c tarrants",
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

-- Command capture, always on (cheap, cleared each fight) so the test harness can read the exact send
-- sequence without stubbing the host `send`. `_AF_TEST.sent` aliases this table.
local sent = {}
local function clear_sent() for i = #sent, 1, -1 do sent[i] = nil end end

local function say(s) if echo then echo("\27[1;35m[autofight]\27[0m " .. s) end end

-- Forward declarations (mutually recursive: advance ⇄ cast ⇄ resolve).
local advance, cast, resolve

-- Send a command the SCRIPT chose. Flag it in self_sent so the echoed-back on_user_input (send loops
-- through the input observer, exactly like the pilot) doesn't mistake our own command for the user's.
local function af_send(cmd)
  F.self_sent[cmd] = (F.self_sent[cmd] or 0) + 1
  sent[#sent + 1] = cmd
  if send then send(cmd) end
end

-- Send `cmd` as spell `spell`, then go busy until it resolves. Skips the send (but not the phase, which
-- the caller already advanced) if we've learned the spell is unaffordable — we WAIT rather than spam it.
cast = function(cmd, spell)
  if F.no_mana[spell] then return end
  F.busy, F.busy_spell, F.busy_pct = true, spell, F.pct
  if F.busy_timer and cancel then cancel(F.busy_timer) end
  F.busy_timer = after and after(cfg.cast_timeout, function() resolve("timeout") end) or nil
  af_send(cmd)
end

-- A cast resolved (any of: landed line / resist / out-of-mana / health-% change / timeout / fail).
-- Clear busy, apply the resolution's side effects, then let the machine take its next step.
resolve = function(reason)
  if not F.busy then return end
  local spell = F.busy_spell
  F.busy, F.busy_spell = false, nil
  if F.busy_timer and cancel then cancel(F.busy_timer); F.busy_timer = nil end
  if reason == "mana" then F.no_mana[spell] = true end                 -- stop casting the unaffordable spell
  if reason == "resist" and spell == "soulsteal" then F.phase = "renuke" end
  advance()
end

-- The single place that decides the next SEND, purely from phase + the pacing/suspend guards. Every
-- event (health-% update, resolution line, resume) funnels back here.
advance = function()
  if not F.on or not F.fighting or F.suspended or F.busy then return end
  local p = F.phase
  if p == "earthwall" then
    F.phase = "tarrants"; cast(cfg.opener_earthwall, "earthwall")     -- opener, cast once; move on regardless
  elseif p == "tarrants" then
    F.phase = "shards";   cast(cfg.opener_tarrants, "tarrants")       -- opener, cast once
  elseif p == "shards" then
    F.phase = "shower";   F.last_damage_spell = "shards"; cast(cfg.shards_cmd, "shards")   -- probe #1
  elseif p == "shower" then
    F.phase = "decide";   F.last_damage_spell = "shower"; cast(cfg.shower_cmd, "shower")   -- probe #2
  elseif p == "decide" then
    -- Coarse winner pick: whichever probe dropped the enemy health % more. Ties → shards.
    if F.shards_drop >= F.shower_drop then F.winner, F.winner_spell = cfg.shards_cmd, "shards"
    else F.winner, F.winner_spell = cfg.shower_cmd, "shower" end
    F.phase = "nuke"; advance()                                       -- act on the new phase now
  elseif p == "nuke" then
    if F.pct and F.pct > 0 and F.pct <= cfg.soulsteal_pct then
      F.phase = "soulsteal"; advance()                               -- nearly dead → finish it
    else
      F.last_damage_spell = F.winner_spell; cast(F.winner, F.winner_spell)
    end
  elseif p == "renuke" then
    -- One winner nuke after a soulsteal resist, then (once it resolves) back to soulsteal.
    F.phase = "soulsteal"; F.last_damage_spell = F.winner_spell; cast(F.winner, F.winner_spell)
  elseif p == "soulsteal" then
    cast(cfg.soulsteal_cmd, "soulsteal")
  end
end

-- ---- fight lifecycle -----------------------------------------------------------------------------
local function start_fight(pct, name)
  F.fighting, F.pct, F.name = true, pct, name
  F.phase = "earthwall"
  F.busy, F.busy_spell = false, nil
  F.shards_drop, F.shower_drop = 0, 0
  F.winner, F.winner_spell, F.last_damage_spell = nil, nil, nil
  F.no_mana = {}
  F.suspended = false
  F.self_sent = {}
  if F.busy_timer and cancel then cancel(F.busy_timer); F.busy_timer = nil end
  if F.suspend_timer and cancel then cancel(F.suspend_timer); F.suspend_timer = nil end
  clear_sent()
  advance()
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
  if F.busy and prev ~= pct then resolve("pct") else advance() end
end

local function on_fight_end()
  if F.fighting then end_fight() end
end

-- ---- combat line resolutions ---------------------------------------------------------------------
-- Each hit_* is what a trigger fires; on_line() (the test seam) classifies a verbatim line and calls the
-- same hit_*, so triggers and tests share one implementation.
local function hit_shards()  resolve("landed") end
local function hit_shower()  resolve("landed") end
local function hit_resist()  resolve("resist") end
local function hit_mana()    resolve("mana")   end
local function hit_fail()    resolve("fail")   end   -- "You fail to cast the spell '…'." — cast fizzled

local function hit_soulsteal_ok()
  -- The soul was pulled; the enemy is about to die. Stop casting; the DEAD line ends the fight.
  if F.busy_timer and cancel then cancel(F.busy_timer); F.busy_timer = nil end
  F.busy, F.busy_spell, F.phase = false, nil, "done"
end

local function hit_dead()
  end_fight()
end

-- Classify ONE verbatim game line and dispatch. Ordered most-specific first. VERBATIM patterns:
--   "You cast the spell to separate soul from body, and pull <name>'s essence into a red soulstone!"
--   "You create and magically throw white shards of crystal at <target>!"
--   "A shower of <color> sparks suddenly engulfs <target>!"
--   "<name> resists the spell."
--   "You don't have enough mana."
--   "You fail to cast the spell 'shards'."
--   "<name> is DEAD!"
local function on_line(l)
  l = l or ""
  if l:find("separate soul from body", 1, true) then hit_soulsteal_ok(); return "soulsteal_ok" end
  if l:find("white shards of crystal at", 1, true) then hit_shards(); return "shards" end
  if l:match("A shower of .- sparks suddenly engulfs") then hit_shower(); return "shower" end
  if l:find("resists the spell", 1, true) then hit_resist(); return "resist" end
  if l:find("enough mana", 1, true) then hit_mana(); return "mana" end
  if l:find("You fail to cast the spell", 1, true) then hit_fail(); return "fail" end
  if l:match("^.- is DEAD!") then hit_dead(); return "dead" end
  return nil
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
    F.suspend_timer = nil; F.suspended = false; advance()
  end) or nil
end

-- ---- triggers ------------------------------------------------------------------------------------
-- Lines reach triggers ANSI-stripped. Register health-bar + resolution triggers that call the same
-- handlers on_line() does. (Trigger regexes run in Swift and aren't unit-testable — the pure handlers
-- they call are; see the spec.)
if trigger then
  trigger([[^kxwt_fighting (\d+) \S+ (.+)$]], function(_, pct, name) on_fight(tonumber(pct), name) end)
  trigger([[^kxwt_fighting -1$]], function() on_fight_end() end)
  trigger([[separate soul from body]], function() hit_soulsteal_ok() end)
  trigger([[white shards of crystal at]], function() hit_shards() end)
  trigger([[A shower of .* sparks suddenly engulfs]], function() hit_shower() end)
  trigger([[resists the spell]], function() hit_resist() end)
  trigger([[don't have enough mana]], function() hit_mana() end)
  trigger([[You fail to cast the spell]], function() hit_fail() end)
  trigger([[ is DEAD!]], function() hit_dead() end)
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
  say("armed — earth wall → tarrants → shards/shower probe → nuke winner → soulsteal")
  if F.fighting and not F.busy then advance() end
end

function autofight.off()
  F.on = false
  end_fight()
  say("disarmed")
end

function autofight.status() if echo then echo(status_line()) end end

doc(autofight.on, { name = "autofight.on", sig = "autofight.on()", group = "combat",
  text = "Arm the deterministic auto-fight routine: on combat start it casts earth wall then tarrants "
      .. "(once each), probes shards vs shower and keeps the harder-hitting one, then soulsteals when "
      .. "the enemy is nearly dead (re-nuking on a resist). Paced (one cast per resolution) and OFF by "
      .. "default; any command YOU type suspends it briefly so you can intervene." })
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
-- Drives the ACTUAL state machine from Scripts/tests/autofight_spec.lua. on_line/on_fight are the same
-- handlers the live triggers call; expire_cast/expire_resume fire the fallback timers deterministically
-- (the CLI harness never auto-fires `after`).
_AF_TEST = {
  cfg           = cfg,
  sent          = sent,                                   -- captured send sequence (shared table)
  state         = function() return F end,
  on_fight      = on_fight,
  on_fight_end  = on_fight_end,
  on_line       = on_line,
  on_input      = observe_input,
  expire_cast   = function() resolve("timeout") end,
  expire_resume = function()
    if F.suspend_timer and cancel then cancel(F.suspend_timer) end
    F.suspend_timer, F.suspended = nil, false; advance()
  end,
  reset = function()                                      -- clean pre-fight state, armed, for a test
    F.on = true
    end_fight()
    F.self_sent = {}
    clear_sent()
  end,
}

if echo then echo(status_line()) end
