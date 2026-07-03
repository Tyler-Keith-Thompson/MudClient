-- AlterAeon game layer (ported from the old Swift KXWTHost).
--
-- All AlterAeon-specific knowledge now lives here, in hot-reloadable Lua, instead of the
-- generic Swift client. KXWT protocol lines are parsed by triggers (capture groups are passed
-- to the handler), feeding a shared global `state` table that AIPilot.lua reads. Recovery logic
-- (rest/sleep) lives here too.
--
-- Trigger patterns are SWIFT regular expressions, so they use [[...]] long strings to pass
-- backslash classes like \d through untouched.

state = state or {
  name = nil, gold = nil, exp = nil, expcap = nil,
  hp = nil, maxhp = nil, mana = nil, maxmana = nil, stam = nil, maxstam = nil,
  position = nil, room_id = nil, room_name = nil, room_coord = nil, area = nil, terrain = nil,
  fighting = false, fight_name = nil, fight_pct = nil,
  walkdir = nil, spells = {}, recover = false,
  inventory = {}, inv_known = false,   -- kxwt does NOT report inventory; we parse it from `inventory` output
  equipment = {}, eq_known = false,    -- nor what's worn/wielded; parsed from `equipment` output
  group = {},                          -- roster of you + pets/groupmates (kxwt_group_start..end)
  exits = {},                          -- set of available exit directions, parsed from "[Exits: ...]"
  effects = {},                        -- timed self-effects (kxwt_spst): name -> remaining-time text
}

local function pct(cur, max) if not cur or not max or max == 0 then return 0 end return cur / max end
local function ready()
  return pct(state.hp, state.maxhp) > 0.85 and pct(state.mana, state.maxmana) > 0.85
     and pct(state.stam, state.maxstam) > 0.85
end

local function choose_recovery_position()
  local hp, mp, sp = pct(state.hp, state.maxhp), pct(state.mana, state.maxmana), pct(state.stam, state.maxstam)
  if hp > 0.85 and mp < 1 and sp > 0.75 then send("rest") else send("sleep") end
end

-- KXWT handshake: enable the protocol, hide the machinery lines.
trigger([[^kxwt_supported$]], function() send("set kxwt") end)
gag([[^kxwt_]])

-- Ring buffer of the last N gagged kxwt_ lines. Triggers fire even on gagged lines, so this
-- catch-all records them all so `#kxwt dump [n]` can show the machinery that's normally hidden.
local kxwt_ring, KXWT_RING_MAX = {}, 300
trigger([[^kxwt_]], function(line)
  kxwt_ring[#kxwt_ring + 1] = line
  if #kxwt_ring > KXWT_RING_MAX then table.remove(kxwt_ring, 1) end
end)

-- `#kxwt ...` control surface. Registered as a script-owned command so the generic Swift client
-- carries no game-specific command names (it just forwards `#<word> <rest>` to whoever claimed it).
if command then command("kxwt", function(rest) kxwt_command(rest) end) end  -- guard: builtin is new
function kxwt_command(args)
  args = (args or ""):match("^%s*(.-)%s*$")
  local verb = (args:match("^%S*") or ""):lower()
  local rest = args:match("^%S*%s+(.*)$") or ""
  if verb == "" or verb == "dump" or verb:match("^%d+$") then
    local n = tonumber(rest) or tonumber(verb) or 15
    if n < 1 then n = 15 end
    if #kxwt_ring == 0 then echo("[kxwt] no kxwt lines captured yet"); return end
    local first = math.max(1, #kxwt_ring - n + 1)
    echo(string.format("[kxwt] last %d of %d captured kxwt lines:", #kxwt_ring - first + 1, #kxwt_ring))
    for i = first, #kxwt_ring do echo("  " .. kxwt_ring[i]) end
  elseif corpse_command and corpse_command(verb, rest) then
    -- handled by the corpse-automation extension
  else
    echo("[kxwt] commands: dump [n] | corpse on|off|status")
  end
end

-- Character / progress
trigger([[^kxwt_myname (.+)$]],   function(_, n) state.name = n end)
trigger([[^kxwt_gold (-?\d+)]],   function(_, g) state.gold = tonumber(g) end)
trigger([[^kxwt_exp (-?\d+)]],    function(_, e) state.exp = tonumber(e) end)
trigger([[^kxwt_expcap (-?\d+)]], function(_, e) state.expcap = tonumber(e) end)

-- Prompt: current/max for hp, mana, stamina. May complete a recovery.
trigger([[^kxwt_prompt (\d+) (\d+) (\d+) (\d+) (\d+) (\d+)]], function(_, chp, mhp, cm, mm, cs, ms)
  state.hp, state.maxhp = tonumber(chp), tonumber(mhp)
  state.mana, state.maxmana = tonumber(cm), tonumber(mm)
  state.stam, state.maxstam = tonumber(cs), tonumber(ms)
  if state.recover and (state.position == "sitting" or state.position == "sleeping") and ready() then
    echo("You have recovered and are ready to adventure!")
    send("stand")
    state.recover = false
  end
end)

-- Position. Starting a recovery sits/sleeps as appropriate.
trigger([[^kxwt_position (.+)$]], function(_, p)
  state.position = p
  if state.recover and not (p == "sitting" or p == "sleeping") then choose_recovery_position() end
end)

-- Combat. -1 = not fighting; otherwise "<pct> <gender> <name>".
trigger([[^kxwt_fighting -1$]], function()
  state.fighting, state.fight_name, state.fight_pct = false, nil, nil
end)
trigger([[^kxwt_fighting (\d+) \S+ (.+)$]], function(_, p, name)
  state.fighting, state.fight_pct, state.fight_name = true, tonumber(p), name
  state.recover = false
end)

-- Room. rvnum carries id + (x y z plane); rshort the name; area the zone. Moving cancels recovery.
trigger([[^kxwt_rvnum (-?\d+) -?\d+ -?\d+ (-?\d+) (-?\d+) (-?\d+) (\d+)]], function(_, vnum, x, y, z, plane)
  state.room_id = tonumber(vnum)
  state.room_coord = { tonumber(x), tonumber(y), tonumber(z), tonumber(plane) }
  state.recover = false
end)
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
end)

-- Environment: sky/time/weather. kxwt_time is "<mud-minutes> <daypart> <clock> <am/pm>";
-- kxwt_precipitation is a 0-100ish intensity; kxwt_sky "<light> <moon?> <...>" (kept raw-ish).
trigger([[^kxwt_time (\d+) (\S+) (\S+) (\S+)$]], function(_, _mins, part, clock, ampm)
  state.daypart = part; state.clock = clock .. " " .. ampm
end)
trigger([[^kxwt_precipitation (\d+)]], function(_, p) state.precip = tonumber(p) end)

-- Timed self-effects (spell/skill durations), e.g. "kxwt_spst mana shield, two hours, 20 minutes".
-- We keep the latest reported one keyed by name so a small "effects" widget can show remaining time.
state.effects = state.effects or {}
trigger([[^kxwt_spst (.+)$]], function(_, s)
  local name, rest = s:match("^(.-),%s*(.+)$")
  if name then state.effects[name] = rest else state.effects[s] = "" end
end)

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

function in_combat() return state.fighting == true end

-- ===== Corpse automation (kxwt_mdeath-driven) — fully stream/trigger-driven, NO timers =====
-- ON by default (`#kxwt corpse off` to stop). When you're OUT OF COMBAT, walk the corpses in the room
-- BY INDEX (1.corpse, 2.corpse, ...). For each: get all -> harvest teeth -> harvest spellcomps, then
--   * EMPTY corpse -> bsac -> sac. `sac` removes it, so the next corpse shifts into THIS index and we
--     re-process the same index.
--   * DIRTY corpse (still holds items) -> leave it intact and step to the NEXT index.
-- So a dirty corpse never blocks an empty one behind it, and we never sacrifice loot. We stop when
-- there's no corpse at the current index. Every step advances off a real STREAM line — never a timer,
-- so nothing fires late. We always ATTEMPT each harvest and let the game reject it instantly when
-- teeth are full / you lack the skill (that reply both advances us and guarantees the loot response
-- has already arrived, so the empty/dirty decision is never made early).
local corpse = { on = true, active = false, idx = 1, step = nil, dirty = false, room = nil }
local CORPSE_MAX = 20   -- safety cap on how many corpse indices we'll walk (guards a missed terminator)

function corpse_done() corpse.active = false; corpse.step = nil; corpse.idx = 1 end

function corpse_start()
  if not corpse.on or corpse.active or in_combat() then return end
  corpse.active = true; corpse.idx = 1
  corpse_process()
end

-- Loot + harvest the corpse at corpse.idx. Loot triggers set `dirty`; harvest terminals advance us.
function corpse_process()
  if not corpse.active then return end
  if corpse.idx > CORPSE_MAX then corpse_done(); return end
  corpse.dirty = false
  corpse.step = "loot"
  send("get all " .. corpse.idx .. ".corpse")     -- no corpse at idx -> "don't see anything named" ends us
  corpse.step = "teeth"
  send("harvest teeth " .. corpse.idx .. ".corpse")
end

-- A harvest terminal line was seen -> next harvest, or on to the sacrifice decision.
function corpse_harvest_done()
  if not corpse.active then return end
  if corpse.step == "teeth" then
    corpse.step = "spellcomps"
    send("harvest spellcomps " .. corpse.idx .. ".corpse")
  elseif corpse.step == "spellcomps" then
    corpse_finish()
  end
end

function corpse_finish()
  if not corpse.active then return end
  if corpse.dirty then
    corpse.idx = corpse.idx + 1   -- leave this corpse (it still has items); step past it
    corpse_process()
  else
    corpse.step = "bsac"
    send("bsac " .. corpse.idx .. ".corpse")   -- advances to sac on the bsac result line
  end
end

function corpse_sac()
  if not corpse.active or corpse.step == "sac" then return end
  corpse.step = "sac"
  send("sac " .. corpse.idx .. ".corpse")   -- removes it; the next corpse shifts into corpse.idx...
  corpse_process()                          -- ...so re-process the SAME index
end

-- Kill / combat-end -> (re)start walking the room's corpses. Both are stream events (no polling).
trigger([[^kxwt_mdeath (.+)$]], function() corpse_start() end)
trigger([[^kxwt_fighting -1$]], function() corpse_start() end)

-- Room change abandons this room's corpses (they don't follow you) -> stop, so we never target a
-- corpse in the wrong room (e.g. after fleeing).
trigger([[^kxwt_rvnum (-?\d+)]], function(_, vnum)
  if corpse.room ~= nil and corpse.room ~= vnum then corpse_done() end
  corpse.room = vnum
end)

-- No corpse at the current index -> the room's corpses are done.
trigger([[^You don't see anything named]], function() if corpse.active then corpse_done() end end)
trigger([[^You don't see that here]], function() if corpse.active then corpse_done() end end)

-- Loot outcome -> this corpse still has items, so don't sacrifice it (leave it, step to the next).
trigger([[^You can't carry that many items]], function() if corpse.active then corpse.dirty = true end end)
trigger([[^\(on ground\) the corpse of]], function() if corpse.active then corpse.dirty = true end end)

-- Harvest terminal lines (^-anchored so another player can't fire them). Success-complete OR the
-- instant "full"/"no skill" rejection — either way the harvest step is finished, so advance.
trigger([[^You don't see any usable]], function() corpse_harvest_done() end)             -- teeth (likely spellcomps too)
trigger([[^You can't safely carry any more teeth]], function() corpse_harvest_done() end) -- teeth full
trigger([[^Your collected teeth grow restless]], function() corpse_harvest_done() end)    -- teeth full
trigger([[^You don't know enough about the undead]], function() corpse_harvest_done() end) -- no spellcomp skill

-- Blood sacrifice result (success OR the undead/"not intact" refusal) -> the final sacrifice.
trigger([[^You sacrifice blood from]], function() if corpse.active and corpse.step == "bsac" then corpse_sac() end end)
trigger([[^You can only blood sacrifice]], function() if corpse.active and corpse.step == "bsac" then corpse_sac() end end)

-- `#kxwt corpse on|off|status` (dispatched from kxwt_command). Returns true if it handled the verb.
function corpse_command(verb, rest)
  if verb ~= "corpse" then return false end
  local m = (rest or ""):lower():match("^%s*(%S*)")
  if m == "on" then
    corpse.on = true
    echo("[kxwt] corpse automation ON — out of combat, per corpse (by index): loot -> harvest teeth -> harvest spellcomps -> (if empty) bsac -> sac")
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
-- so it lives here in the game layer; edit + `#ai reload` to tweak.
function game_command_reference()
  return [[MOVEMENT: type a direction or its abbreviation — north/n south/s east/e west/w up/u down/d northeast/ne northwest/nw southeast/se southwest/sw. 'recall' returns to your waypoint; 'waypoint' travels between set waypoints.
LOOKING/INFO: 'look' (room), 'look <thing>', 'exits', 'hp', 'score', 'inventory' (i/inv), 'equipment' (what you're wearing/wielding), 'spells', 'skills', 'consider <target>' (gauge a fight), 'who', 'help <topic>'.
ITEMS/GEAR: 'get <item>' / 'get all' / 'get all corpse' (loot) / 'get <item> <container>'; 'drop <item>'; 'put <item> in <container>'; 'wear <armor>'; 'wield <weapon>'; 'use <item>' (auto-pick best slot); 'remove <item>' (take off, to swap to better gear); 'donate <item>'.
COMBAT: 'kill <target>' / 'attack <target>'; 'flee' or 'run' to escape; class skills 'kick', 'trip', 'backstab'. Check 'hp' when hurt.
SPELLS: cast '<spell name>' [target]. Names may be abbreviated. With no target while fighting, it targets your current enemy; a self/buff spell with no target hits you. Only cast attack spells when there's an enemy. 'spells' lists yours.
RECOVER: 'rest' or 'sleep' to heal hp/mana/stamina; 'stand' or 'wake' when recovered.
PROGRESS: at a trainer, 'level', 'train', and 'practice' improve you; 'slist' shows newly available spells/skills.]]
end

-- Aliases: `state` dumps the snapshot; `recover` toggles the recovery routine.
alias([[^state$]], function() echo(describe_state()) end)
alias([[^recover$]], function()
  if state.recover then
    echo("Ending recovery"); state.recover = false
  elseif not ready() then
    echo("Starting recovery"); state.recover = true; choose_recovery_position()
  end
end)
