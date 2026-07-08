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

-- Pick the recovery posture for the current vitals — and current posture. rest keeps more of your guard,
-- so it wins when only mana is lacking (hp/stam already high); otherwise sleep heals fastest. Context
-- aware: only send a command when it actually deepens the posture. Already resting/sleeping when rest is
-- enough → send nothing; sitting/resting when we want sleep → escalate to sleep. No redundant spam.
local function choose_recovery_position()
  local hp, mp, sp = pct(state.hp, state.maxhp), pct(state.mana, state.maxmana), pct(state.stam, state.maxstam)
  local want = (hp > 0.85 and mp < 1 and sp > 0.75) and "rest" or "sleep"
  local target = (want == "sleep") and 2 or 1
  if recovery_depth(state.position) >= target then return end   -- already at least this deep → nothing to do
  send(want)
end

-- Recovery-as-a-promise. `recovery.pct` is the current target threshold; `recovery.settle` holds the
-- resolve/reject callbacks of the promise recover() returned, while one is waiting (nil otherwise).
-- end_recovery() is the single settle point: it clears the flag, restores the default threshold, and
-- resolves (completed) or rejects (interrupted: you moved, a fight started, you cancelled) the promise.
local recovery = { pct = READY_PCT, settle = nil }
local function end_recovery(completed, reason)
  state.recover = false
  local s = recovery.settle
  recovery.settle, recovery.pct = nil, READY_PCT
  if s then if completed then s.resolve() else s.reject(reason or "recovery interrupted") end end
end

-- Called from the kxwt_prompt trigger on every vitals update: stand + resolve once the target is met.
-- Factored out (and exposed via _AA_TEST) so the spec can drive completion without the Swift trigger.
local function maybe_complete_recovery()
  if state.recover and recovery_depth(state.position) >= 1 and ready(recovery.pct) then
    echo("You have recovered and are ready to adventure!")
    send("stand")
    end_recovery(true)
    return true
  end
  return false
end

-- Exposed for the test harness (Scripts/tests/recover_spec.lua, promise_spec.lua).
_AA_TEST = { ready = ready, pct = pct, READY_PCT = READY_PCT,
             choose_recovery_position = choose_recovery_position, recovery_depth = recovery_depth,
             recovery = recovery, end_recovery = end_recovery,
             maybe_complete_recovery = maybe_complete_recovery }

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
  text = "Control the after-kill corpse automation (loot -> harvest -> sacrifice). No arg reports status." })

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
  state.position = p
  -- If we're recovering but got knocked back to a non-recovery posture (stood up, kicked awake), re-issue.
  if state.recover and recovery_depth(p) == 0 then choose_recovery_position() end
end)

-- Combat. -1 = not fighting; otherwise "<pct> <gender> <name>".
trigger([[^kxwt_fighting -1$]], function()
  state.fighting, state.fight_name, state.fight_pct = false, nil, nil
end)
trigger([[^kxwt_fighting (\d+) \S+ (.+)$]], function(_, p, name)
  state.fighting, state.fight_pct, state.fight_name = true, tonumber(p), name
  end_recovery(false, "combat started")           -- a fight cancels (and rejects) any recovery
end)

-- Room. rvnum carries id + (x y z plane); rshort the name; area the zone. Moving cancels recovery.
trigger([[^kxwt_rvnum (-?\d+) -?\d+ -?\d+ (-?\d+) (-?\d+) (-?\d+) (\d+)]], function(_, vnum, x, y, z, plane)
  state.room_id = tonumber(vnum)
  state.room_coord = { tonumber(x), tonumber(y), tonumber(z), tonumber(plane) }
  end_recovery(false, "moved")                     -- moving cancels (and rejects) any recovery
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

-- Feed the tracker. The current target's EXACT reading (kxwt_fighting), every melee-round line (names
-- the enemy and proves engagement), and every condition line while engaged update the table; combat
-- end / room change / mob death clear or remove entries. The condition trigger is gated on engaged()
-- so out-of-combat 'look' condition lines can't spawn phantom opponents.
trigger([[^kxwt_fighting (\d+) \S+ (.+)$]], function(_, p, name)
  opponent_note(state.opponents, name, tonumber(p), os.time(), true)
end)
trigger([[^kxwt_fighting -1$]], function()
  state.opponents = {}; state.engaged_until = nil
end)
trigger([[\S+'s [a-z ]*(annoys|scratches|hits|injures|wounds|mauls|decimates|devastates|maims|mutilates|dismembers|disembowels|massacres|obliterates|demolishes|destroys|annihilates|misses|nicks|cuts|gouges|gashes|lacerates|shreds|mangles|rends|thumps|mars|batters|thrashes|clobbers|smashes|pulverizes) ]],
  function(line)
    local attacker, target = parse_melee(line)
    if not attacker then return end
    local enemy = melee_enemy(attacker, target)
    if not enemy then return end                       -- bystander fight; not ours
    local now = os.time()
    state.engaged_until = now + ENGAGE_TTL
    end_recovery(false, "combat started")             -- fights (kxwt-visible or not) cancel recovery
    opponent_note(state.opponents, enemy, nil, now, false)   -- name sighting; keeps any known pct
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

-- ===== Corpse automation (kxwt_mdeath-driven) — fully stream/trigger-driven, NO timers =====
-- ON by default (kxwt.corpse('off') to stop). Runs only after an actual KILL (not a flee — see below).
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

-- kxwt.corpse('on'|'off'|'status') (dispatched from the kxwt table). Returns true if it handled the verb.
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
  echo(string.format("Recovering — resting/sleeping; I'll stand you up once every vital hits %d%%.",
       math.floor(frac * 100 + 0.5)))
  choose_recovery_position()
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
    if ready(frac) then echo("Already recovered — vitals at target."); resolve(); return end
    -- A recovery is a singleton (one `recovery.settle` slot). If one is already pending — e.g. you typed
    -- `recover`, then `recover | explore` — the newer call takes over: reject the old promise as
    -- superseded so it settles (and leaves the promise widget) instead of dangling forever, orphaned.
    if recovery.settle then local old = recovery.settle; recovery.settle = nil; old.reject("superseded") end
    recovery.settle = { resolve = resolve, reject = reject }
    begin_recovery(frac)
    onCancel(function()
      -- Chain aborted: stand up and clear the recovery flag WITHOUT firing resolve/reject (the promise
      -- is cancelled, not settled). A later kxwt_prompt then can't complete it (state.recover is false).
      if state.recover then send("stand") end
      recovery.settle, recovery.pct, state.recover = nil, READY_PCT, false
    end)
  end, "recover")
end
doc("recover", { sig = "recover([pct]) -> promise", group = "combat",
  text = "Start a recovery and return a promise that resolves once every vital reaches `pct` (95 or "
      .. "0.95; default 90%) and rejects if interrupted (you move, a fight starts, you cancel). Chain "
      .. "the next action with .andThen — e.g. recover(95).andThen(attack('orc')).",
  example = "#recover(95).andThen(attack('orc'))" })

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
  elseif ready() then
    echo("Already recovered — all vitals at 90%+.")
  else
    recover()   -- go through the promise (not begin_recovery) so the recovery shows in the promise widget
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
