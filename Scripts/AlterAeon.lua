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
  name = nil, gold = nil, exp = nil, expcap = nil, classes = {},
  hp = nil, maxhp = nil, mana = nil, maxmana = nil, stam = nil, maxstam = nil,
  position = nil, room_id = nil, room_name = nil, room_coord = nil, area = nil, terrain = nil,
  fighting = false, fight_name = nil, fight_pct = nil,
  walkdir = nil, spells = {}, recover = false,
  inventory = {}, inv_known = false,   -- kxwt does NOT report inventory; we parse it from `inventory` output
  equipment = {}, eq_known = false,    -- nor what's worn/wielded; parsed from `equipment` output
  group = {},                          -- roster of you + pets/groupmates (kxwt_group_start..end)
  exits = {},                          -- set of available exit directions, parsed from "[Exits: ...]"
  effects = {},                        -- timed self-effects (kxwt_spst): name -> remaining-time text
  action = 0,                          -- kxwt_action code; >= 50 prevents spellcasting
  outdoors = nil, sky_visible = nil, overcast = nil,   -- kxwt_sky flags
  music = {},                          -- channel -> current track name (kxwt_music), for the HUD ♪
}

local function pct(cur, max) if not cur or not max or max == 0 then return 0 end return cur / max end
-- "Ready" = recovered enough to keep exploring: every vital at least 90%. Drives the `recover` alias's
-- auto-stand and the AI's " (ready)" readiness label, so both share one definition.
local READY_PCT = 0.90
local function ready()
  return pct(state.hp, state.maxhp) >= READY_PCT and pct(state.mana, state.maxmana) >= READY_PCT
     and pct(state.stam, state.maxstam) >= READY_PCT
end

local function choose_recovery_position()
  local hp, mp, sp = pct(state.hp, state.maxhp), pct(state.mana, state.maxmana), pct(state.stam, state.maxstam)
  if hp > 0.85 and mp < 1 and sp > 0.75 then send("rest") else send("sleep") end
end

-- Exposed for the test harness (Scripts/tests/recover_spec.lua).
_AA_TEST = { ready = ready, pct = pct, READY_PCT = READY_PCT,
             choose_recovery_position = choose_recovery_position }

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
-- Load once at startup (not on a live `#ai reload`, where state already holds the fresh table).
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

-- `#volume music <0-100>` — master volume for the layered music player (all channels). A bare
-- `#volume` or `#volume music` with no number just reports the current level. Swift starts at 35%
-- (deliberately quiet); we mirror that default here for the readout. `if music.volume` guards an
-- un-relaunched binary that lacks the new builtin.
state.music_volume = state.music_volume or 35
if command then command("volume", function(rest) volume_command(rest) end) end
function volume_command(args)
  args = (args or ""):match("^%s*(.-)%s*$")
  local target = (args:match("^%S*") or ""):lower()
  local rest = args:match("^%S*%s+(.*)$") or ""
  -- accept both `#volume music 40` and the shorthand `#volume 40`
  local num = rest:match("^(%d+)") or (target:match("^%d+$") and target or nil)
  if target ~= "" and target ~= "music" and not target:match("^%d+$") then
    echo("[volume] usage: #volume music <0-100>"); return
  end
  if num then
    local n = math.max(0, math.min(100, tonumber(num)))
    state.music_volume = n
    if music and music.volume then music.volume(n) end
    echo(string.format("[volume] music set to %d%%", n))
  else
    echo(string.format("[volume] music is at %d%% (use #volume music <0-100>)", state.music_volume))
  end
end

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
-- ON by default (`#kxwt corpse off` to stop). Runs only after an actual KILL (not a flee — see below).
-- When you're OUT OF COMBAT, walk the corpses in the room BY INDEX (1.corpse, 2.corpse, ...). For each:
-- get all -> harvest teeth -> harvest spellcomps, then
--   * LOOTED/EMPTY corpse -> bsac -> sac. `sac` removes it, so the next corpse shifts into THIS index
--     and we re-process the same index.
--   * DIRTY corpse (inventory full, so items were LEFT behind) -> leave it intact, step to the NEXT index.
-- So a dirty corpse never blocks one behind it, and we never sacrifice loot we couldn't carry. We stop
-- when there's no corpse at the current index. Every step advances off a real STREAM line — never a timer,
-- so nothing fires late. We always ATTEMPT each harvest and let the game reject it instantly when
-- teeth are full / you lack the skill (that reply both advances us and guarantees the loot response
-- has already arrived, so the empty/dirty decision is never made early).
local corpse = { on = true, active = false, idx = 1, step = nil, dirty = false, room = nil, killed = false }
local CORPSE_MAX = 20   -- safety cap on how many corpse indices we'll walk (guards a missed terminator)

-- `killed` = a mob actually DIED this fight (kxwt_mdeath), so combat ending means we have corpses to
-- work. Cleared here (and on a room change), so ending combat by FLEEING — which changes rooms and
-- leaves no corpse of ours — never kicks off looting.
function corpse_done() corpse.active = false; corpse.step = nil; corpse.idx = 1; corpse.killed = false end

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

-- A mob DIED -> remember it and try to start (usually a no-op: you're still fighting, so corpse_start
-- bails; the real start is when combat ENDS below). kxwt_fighting -1 fires when combat ends for ANY
-- reason, so only walk corpses if a kill actually happened this fight — fleeing ends combat with no
-- corpse of ours (and moves us), and must NOT trigger looting.
trigger([[^kxwt_mdeath (.+)$]], function() corpse.killed = true; corpse_start() end)
trigger([[^kxwt_fighting -1$]], function() if corpse.killed then corpse_start() end end)

-- Room change abandons this room's corpses (they don't follow you) -> stop, so we never target a
-- corpse in the wrong room (e.g. after fleeing).
trigger([[^kxwt_rvnum (-?\d+)]], function(_, vnum)
  if corpse.room ~= nil and corpse.room ~= vnum then corpse_done() end
  corpse.room = vnum
end)

-- No corpse at the current index -> the room's corpses are done. The `'<n>.corpse'` miss is how the
-- index-walk detects "no more corpses", so gag it: it's internal plumbing, not something you did.
gag([[^You don't see anything named '\d+\.corpse']])
trigger([[^You don't see anything named]], function() if corpse.active then corpse_done() end end)
trigger([[^You don't see that here]], function() if corpse.active then corpse_done() end end)

-- Loot outcome -> we couldn't take everything (inventory full), so items REMAIN in this corpse: leave
-- it intact (don't sacrifice loot) and step to the next index. NOTE: we deliberately do NOT treat the
-- "(on ground) the corpse of X contains:" loot HEADER as dirty — that line prints on every corpse that
-- has items, even when we then take them all, and mis-flagging it made fully-looted corpses get skipped
-- (and probe a phantom next index) instead of sacrificed.
trigger([[^You can't carry that many items]], function() if corpse.active then corpse.dirty = true end end)

-- Harvest terminal lines (^-anchored so another player can't fire them). Success-complete OR the
-- instant "full"/"no skill" rejection — either way the harvest step is finished, so advance.
trigger([[^You don't see any usable]], function() corpse_harvest_done() end)             -- teeth (likely spellcomps too)
trigger([[^You can't safely carry any more teeth]], function() corpse_harvest_done() end) -- teeth full
trigger([[^Your collected teeth grow restless]], function() corpse_harvest_done() end)    -- teeth full
trigger([[^You don't know enough about the undead]], function() corpse_harvest_done() end) -- no spellcomp skill
trigger([[^Looks like the corpse of .+ is too damaged for you to use]], function() corpse_harvest_done() end) -- corpse too mangled to harvest -> skip, keep going

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

-- Aliases: `state` dumps the snapshot; `recover` rests/sleeps until ready, then auto-stands.
alias([[^state$]], function() echo(describe_state()) end)
-- `recover` — sit/sleep to heal and STAND automatically once every vital is back to 90%+ (the auto-stand
-- lives in the kxwt_prompt trigger, which watches ready()). Typing `recover` again cancels; if you're
-- already recovered it just says so. choose_recovery_position picks rest vs sleep for the situation.
alias([[^recover$]], function()
  if state.recover then
    echo("Ending recovery."); state.recover = false
  elseif ready() then
    echo("Already recovered — all vitals at 90%+.")
  else
    echo("Recovering — resting/sleeping; I'll stand you up once every vital hits 90%.")
    state.recover = true
    choose_recovery_position()
  end
end)

-- `#test` — run the Lua test suite against the CURRENTLY-LOADED scripts, in this same Lua state, so you
-- can verify a change right after `#ai reload`. Re-reads the harness + every Scripts/tests/*.lua so it
-- always reflects the latest edits. Pure Lua; no external interpreter or build step. `if command then`
-- guards an un-relaunched binary that predates the `command` builtin.
if command then command("test", function() run_test_suite() end) end
-- Returns (pass, fail) so a CLI runner can set its exit code; the in-app `#test` just ignores them.
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
