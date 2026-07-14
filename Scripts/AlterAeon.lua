-- AlterAeon game layer (ported from the old Swift KXWTHost).
--
-- All AlterAeon-specific knowledge now lives in Lua (hot-reloadable) instead of the generic Swift
-- client. KXWT protocol lines are parsed by triggers (capture groups are passed to the handler),
-- feeding a shared global `state` table that AIPilot.lua reads.
--
-- This file is the ENTRY POINT + `state`-schema owner + core kxwt field parsing (vitals, room,
-- environment, spells/affects, inventory/equipment), the `kxwt` inspection table, the state snapshot
-- (describe_state) and the command reference fed to the AI. The rest of the game layer is split by
-- concern into sibling top-level scripts (each auto-loaded by load("Scripts"), each defensively
-- `state = state or {}`):
--   * Recovery.lua — rest/sleep, lifetap, minion healing, self-casting, regen cache, recover* API.
--   * Combat.lua   — kxwt_fighting, inferred opponents, engaged()/in_combat(), targeting.
--   * Corpse.lua   — after-kill corpse harvest/sacrifice automation.
--   * Audio.lua    — music channels + master/category volume.
-- The parsing triggers here emit into `state`, then hand off to the recovery state machine through a
-- small `__recovery_on_*` hook surface (defined in Recovery.lua) — so protocol and recovery stay
-- decoupled across files without sharing upvalues.
--
-- Trigger patterns are SWIFT regular expressions, so they use [[...]] long strings to pass
-- backslash classes like \d through untouched.
--
-- AlterAeon 1.105 is single-socket: the whole game runs over the protobuf RPC
-- (www.alteraeon.com:3103) — game text arrives as text_block, commands go out as text_block,
-- telemetry + music ride the same socket. The connection is opened by RPC.lua (Scripts/RPC.lua,
-- `dclient_rpc.start()`), a pure-Lua reimplementation of the old Swift RPCConnection built on
-- net_connect/net_send/on_net/on_net_connect/on_net_disconnect — it self-starts on load (case-insensitive
-- alphabetical load order puts it after AlterAeon, but load order doesn't matter here since it's
-- guarded and self-contained). Do NOT also call rpc_connect() here — that would open a SECOND,
-- redundant Swift-side RPC connection.

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
    lifetapping = false,                 -- true while a `lifetap` bleed is in progress (recovery mana boost)
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

_AA_TEST = _AA_TEST or {}

-- The shared declarative DSL (field/replies/on_all). require() in the live client (hot-reloadable), a
-- dofile fallback for the pure-Lua test harness (where the require searcher's host primitives are stubbed).
pcall(require, "_dsl")
if not __dsl then dofile("Scripts/_dsl.lua") end
local field, number, flag = __dsl.field, __dsl.number, __dsl.flag

pcall(require, "_persist")
if not __persist then dofile("Scripts/_persist.lua") end
local persist = __persist

-- KXWT handshake: enable the protocol, hide the machinery lines.
trigger([[^kxw[tq]_supported$]], function() send("set kxwt") end)

-- Gag the kxwt/kxwq telemetry lines — but PRESERVE any ANSI escape codes the server glued to the FRONT of
-- one. AlterAeon sometimes emits a colour RESET (e.g. "\27[37m\27[0m") as the prefix of a machine line
-- ("\27[37m\27[0mkxwq_sky 1 1 0") when that reset really terminates the PRECEDING visible line (e.g. a
-- bold-blue "It is night..."). A plain `gag` dropped the whole raw line, taking the reset with it, so the
-- colour bled forward into the room contents / exits. So instead of dropping, return just the leading
-- escape run: the tag text is still hidden, but the reset survives. A tagline with no leading ANSI (the
-- common case) returns "" — fully gagged, no blank line, exactly as before. The raw ANSI line is the last
-- handler arg (CLAUDE.md); with no capture groups the run is `select`-able off the end.
local function __leading_ansi(s)
  local codes, rest = {}, s or ""
  while true do
    local c = rest:match("^(\27%[[%d;]*[A-Za-z])")   -- one CSI sequence, e.g. \27[0m / \27[1;34m
    if not c then break end
    codes[#codes + 1] = c
    rest = rest:sub(#c + 1)
  end
  return table.concat(codes)
end
-- ONE catch-all does both jobs: (1) ring-buffer every kxwt_/kxwq_ line so kxwt.dump([n]) can show the
-- machinery that's normally hidden, and (2) gag the tag from the display while PRESERVING any leading ANSI
-- (the __leading_ansi return, per the note above). These MUST be a single handler: a trigger that returns
-- ""/a string ENDS the line's handler chain (unlike a `gag()` rule), so a separate gag-returning trigger
-- would short-circuit a later ring-capture trigger and leave the ring empty. Capture runs BEFORE the
-- return, so the ring records every tag regardless of the gag.
local kxwt_ring, KXWT_RING_MAX = {}, 300
trigger([[^kxw[tq]_]], function(...)
  local a = { ... }
  kxwt_ring[#kxwt_ring + 1] = a[1]
  if #kxwt_ring > KXWT_RING_MAX then table.remove(kxwt_ring, 1) end
  return __leading_ansi(a[#a])
end)

-- The `kxwt` protocol-inspection surface: a documented, first-class table (Phase-2 migration off the
-- old `command("kxwt", …)` string parser). kxwt.dump([n]) shows the last n captured kxwt_ lines. The
-- table is *callable* so the legacy typed `#kxwt dump 5` (rewritten by the host to `kxwt("dump 5")`)
-- still dispatches to the right member. (The corpse-harvest automation moved to its own `autoHarvest`
-- control table, Corpse.lua — it no longer lives under kxwt.)
kxwt = {}

function kxwt.dump(n)
  n = tonumber(n) or 15
  if n < 1 then n = 15 end
  if #kxwt_ring == 0 then echo("[kxwt] no kxwt lines captured yet"); return end
  local first = math.max(1, #kxwt_ring - n + 1)
  echo(string.format("[kxwt] last %d of %d captured kxwt lines:", #kxwt_ring - first + 1, #kxwt_ring))
  for i = first, #kxwt_ring do echo("  " .. kxwt_ring[i]) end
end

doc(kxwt.dump, { name = "kxwt.dump", sig = "kxwt.dump([n])", group = "protocol",
  text = "Show the last n (default 15) captured kxwt_ protocol lines — the machinery normally hidden from the display." })

-- Callable table: forward a legacy subcommand string to the right member.
setmetatable(kxwt, { __call = function(_, args)
  args = (args or ""):match("^%s*(.-)%s*$")
  local verb = (args:match("^%S*") or ""):lower()
  local rest = args:match("^%S*%s+(.*)$") or ""
  if verb == "" or verb == "dump" or verb:match("^%d+$") then
    kxwt.dump(tonumber(rest) or tonumber(verb))
  else
    echo("[kxwt] commands: kxwt.dump([n])")
  end
end })

-- Walk direction: numeric code -> name (used by the map). The converter for the walkdir field below;
-- an unknown code returns nil, which `field :via` assigns straight through to clear state.walkdir.
local WALK = { ["0"]="north", ["1"]="east", ["2"]="south", ["3"]="west", ["4"]="northeast",
  ["5"]="southeast", ["6"]="southwest", ["7"]="northwest", ["20"]="up", ["30"]="down" }
local function walk_name(code) return WALK[code] end

-- ---- Flat scalar kxwt fields --------------------------------------------------------------------
-- Every trivial "one capture -> one state key" kxwt line, declared through the field() DSL so the whole
-- flat-field surface reads as a spec: which line, which state key, what type. Richer fields (position,
-- room coords, group, time, ...) keep their own triggers where the extra logic wouldn't read as a spec.
field [[^kxw[tq]_myname (.+)$]]        : into "name"
field [[^kxw[tq]_gold (-?\d+)]]        : into "gold"      : as (number)
-- exp is your unspent EXPERIENCE POOL; expcap the most you can earn from a SINGLE KILL (a static-ish
-- ceiling) — NOT experience-to-level, which isn't a kxwt field (scraped from `level`/`score` below).
field [[^kxw[tq]_exp (-?\d+)]]         : into "exp"        : as (number)
field [[^kxw[tq]_expcap (-?\d+)]]      : into "expcap"     : as (number)
field [[^kxw[tq]_rshort (.+)$]]        : into "room_name"
field [[^kxw[tq]_area \d+ (.+)$]]      : into "area"
field [[^kxw[tq]_terrain (\d+)]]       : into "terrain"    : as (number)
field [[^kxw[tq]_precipitation (\d+)]] : into "precip"     : as (number)
-- action code (butchering, turning, ...). Per 'help kxwt', >= 50 PREVENTS spellcasting; a room change
-- clears it (the separate kxwt_rvnum trigger below), since moving cancels most actions.
field [[^kxw[tq]_action (\d+)]]        : into "action"     : as (number)
field [[^kxw[tq]_walkdir (\d+)]]       : into "walkdir"    : via (walk_name)

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
  local parts = {}
  for name, c in pairs(state.classes) do
    local micro = c.micro and string.format(",micro={done=%d,total=%d}", c.micro.done or 0, c.micro.total or 0) or ""
    parts[#parts + 1] = string.format("[%q]={level=%d,cost=%d%s}", name, c.level or 0, c.cost or 0, micro)
  end
  persist.write(CLASSES_FILE, "return {" .. table.concat(parts, ",") .. "}")
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
  local t = persist.load(CLASSES_FILE)
  if type(t) == "table" then state.classes = t end
end

trigger([[^Class +Level +.*Exp Cost]], function() state.classes = {} end)
-- Row: "<Class>  <level>  [<done>/<total>]  <exp cost>  ( <pct>%)". The optional MICRO column ("0/  2")
-- appears once you're high enough that a level-up is partial — the next "level" is one of `total` micro
-- steps. We capture it when present (groups 3/4, nil otherwise) so the widget can flag a partial level-up;
-- the cheapest-class pick is unchanged (still by exp cost). The percent is space-padded ("( 92%)"), so
-- allow spaces after the "(".
trigger([[^(Mage|Cleric|Thief|Warrior|Necromancer|Druid) +(\d+)(?: +(\d+)/ *(\d+))? +(\d+) +\( *\d+%\)]],
  function(_, cls, lvl, mdone, mtotal, cost)
    local micro = (mdone and mtotal) and { done = tonumber(mdone), total = tonumber(mtotal) } or nil
    state.classes[cls] = { level = tonumber(lvl), cost = tonumber(cost), micro = micro }
    schedule_classes_save()
  end)

-- Prompt: current/max for hp, mana, stamina — six numbers straight into the vitals, then hand off to the
-- recovery machine (completion + lifetap, Recovery.lua). Reads as the spec it is.
field [[^kxw[tq]_prompt (\d+) (\d+) (\d+) (\d+) (\d+) (\d+)]]
  : into("hp", "maxhp", "mana", "maxmana", "stam", "maxstam") : as (number)
  : then_(function() if __recovery_on_vitals then __recovery_on_vitals() end end)

-- Position. Starting a recovery sits/sleeps as appropriate. state.position must be one of Recovery.lua's
-- RECOVERY_DEPTH keys (standing/kneeling/sitting/resting/sleeping) for posture depth to compute.
local function set_position(p)
  local changed = (state.position ~= p)
  state.position = p
  if __recovery_on_position then __recovery_on_position(p, changed) end   -- re-posture / refresh regen (Recovery.lua)
end
if _AA_TEST then _AA_TEST.set_position = set_position end
trigger([[^kxw[tq]_position (.+)$]], function(_, p) set_position(p) end)

-- Over the 1.105 RPC kxwt_position is DEAD, so posture never synced and recovery couldn't tell you were
-- standing (the "I never sit for regen" bug). Sync it from the game's own confirmation LINES instead
-- (patterns verbatim from live capture). `^`-anchored + the trailing period so a room description like
-- "You stand just inside the gate…" can't match "You stand up." These fire over RPC and kxwt alike (both
-- just set the same string), so no double-fire concern.
trigger([[^You stand up\.]],                     function() set_position("standing") end)
trigger([[^You are already standing]],           function() set_position("standing") end)
trigger([[^You scramble to your feet]],          function() set_position("standing") end)
trigger([[^You sit down and rest]],              function() set_position("resting") end)
trigger([[^You wake up and begin resting]],      function() set_position("resting") end)
trigger([[^You are (?:already )?resting]],       function() set_position("resting") end)
trigger([[^You sit down\.]],                     function() set_position("sitting") end)
trigger([[^You are (?:already )?sitting]],       function() set_position("sitting") end)
trigger([[^You go to sleep\.]],                  function() set_position("sleeping") end)
trigger([[^You are (?:already sound )?asleep]],  function() set_position("sleeping") end)
trigger([[^You kneel]],                          function() set_position("kneeling") end)


-- Update the current room from an rvnum. Ends recovery ONLY on a REAL move: the server re-sends rvnum on
-- a plain `look` (same id + coords), and a look mid-rest must not abort the recovery. Pure + exposed via
-- _AA_TEST so the move-vs-look decision is unit-tested (the trigger regex itself runs in Swift).
local function note_room(nid, nx, ny, nz, np)
  local oc = state.room_coord
  local moved = (state.room_id ~= nid)
      or not oc or oc[1] ~= nx or oc[2] ~= ny or oc[3] ~= nz or oc[4] ~= np
  state.room_id = nid
  state.room_coord = { nx, ny, nz, np }
  if moved and __recovery_cancel then __recovery_cancel("moved") end   -- a real move cancels (and rejects) any recovery
end

-- Room. rvnum carries id + (x y z plane); rshort the name; area the zone.
trigger([[^kxw[tq]_rvnum (-?\d+) -?\d+ -?\d+ (-?\d+) (-?\d+) (-?\d+) (\d+)]], function(_, vnum, x, y, z, plane)
  note_room(tonumber(vnum), tonumber(x), tonumber(y), tonumber(z), tonumber(plane))
end)
if _AA_TEST then _AA_TEST.note_room = note_room end

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

-- Spells that the mage "maintaining spells" skill can keep up continuously (from
-- `help maintaining spells` — the game's authoritative list). When one of these comes up we
-- auto-issue `maintain <spell>` so it never expires and we stop re-casting it. Set for O(1) lookup,
-- keyed by the exact lowercase spell name kxwt reports.
local MAINTAINABLE = {}
for _, name in ipairs({
  "armor aegis", "detect invisibility", "detect evil", "infravision", "sense life", "fly",
  "water breathing", "darken", "detect undead", "dread portent", "unburden", "walk on water",
  "feather fall",
}) do MAINTAINABLE[name] = true end

-- Auto-maintain a spell the moment it lands, if the mage "maintaining spells" skill can hold it.
-- Guard with `state.maintained` so a re-up (or a fresh score reconcile) doesn't spam `maintain` —
-- the flag is cleared on spelldown and on reconnect. Pure so it's unit-testable (the trigger regex
-- that feeds it runs in Swift and isn't).
local function maybe_maintain(s)
  state.maintained = state.maintained or {}
  if MAINTAINABLE[(s or ""):lower()] and not state.maintained[s] then
    state.maintained[s] = true
    send("maintain " .. s)
  end
end

-- Spells up/down. Losing a spell while sleeping with mana to spare drops to resting.
trigger([[^kxw[tq]_spellup (.+)$]], function(_, s)
  state.spells[s] = true
  maybe_maintain(s)
  if __recovery_on_spellup then __recovery_on_spellup(s) end   -- release any "waiting for this recast" hold (Recovery.lua)
end)
trigger([[^kxw[tq]_spelldown (.+)$]], function(_, s)
  state.spells[s] = nil
  if state.maintained then state.maintained[s] = nil end   -- dropped: allow a re-maintain when it returns
  if __recovery_on_spelldown then __recovery_on_spelldown(s) end   -- drop to rest for the recast (Recovery.lua)
end)

-- Group roster. kxwt streams the party (you + pets/groupmates) as a block bracketed by
-- kxwt_group_start .. kxwt_group_end; each member line is "chp mhp cm mm cs ms <flags> <name>".
-- Accumulate between start/end so a half-sent block never renders partial data.
local group_capturing, group_buf = false, {}
trigger([[^kxw[tq]_group_start$]], function() group_capturing = true; group_buf = {} end)
trigger([[^kxw[tq]_group (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\S+) (.+)$]],
  function(_, chp, mhp, cm, mm, cs, ms, flags, name)
    if not group_capturing then return end
    group_buf[#group_buf + 1] = {
      hp = tonumber(chp), maxhp = tonumber(mhp),
      mana = tonumber(cm), maxmana = tonumber(mm),
      stam = tonumber(cs), maxstam = tonumber(ms),
      flags = flags, name = name,
    }
  end)
trigger([[^kxw[tq]_group_end$]], function()
  if group_capturing then state.group = group_buf end
  group_capturing = false
  -- Fresh roster: while recovering, (re)pick the next minion to heal and re-check completion — minion HP
  -- only changes here, not on the player prompt (Recovery.lua).
  if state.recover and __recovery_on_group then __recovery_on_group() end
end)


-- Environment: sky/time/weather. kxwt_time is "<mud-minutes> <daypart> <clock> <am/pm>";
-- kxwt_precipitation is a 0-100ish intensity; kxwt_sky is "<outdoors> <sky-visible> <overcast>" (1/0).
trigger([[^kxw[tq]_time (\d+) (\S+) (\S+) (\S+)$]], function(_, _mins, part, clock, ampm)
  state.daypart = part; state.clock = clock .. " " .. ampm
end)
field [[^kxw[tq]_sky (\d+) (\d+) (\d+)]]
  : into("outdoors", "sky_visible", "overcast") : as (flag)   -- three 1/0 flags -> booleans

-- Moving cancels most actions, so clear the action code on a room change (the live value is parsed as a
-- flat scalar field above).
trigger([[^kxw[tq]_rvnum ]], function() state.action = 0 end)

-- Transient alerts: level-ups / quest completions (kxwt_event) and deaths of a player (pdeath), your
-- own minion (ydeath), or a group member's minion (gdeath). kxwt_ lines are gagged, so we echo a short
-- coloured banner into the output instead. (mob deaths, kxwt_mdeath, drive corpse automation below.)
trigger([[^kxw[tq]_event (\S+) ?(.*)$]], function(_, kw, data)
  echo("\27[1;33m★ " .. kw .. (data ~= "" and (": " .. data) or "") .. "\27[0m")
end)
trigger([[^kxw[tq]_pdeath (.+)$]], function(_, n) echo("\27[1;31m☠ " .. n .. " has DIED!\27[0m") end)
trigger([[^kxw[tq]_ydeath (.+)$]], function(_, n) echo("\27[31m☠ your " .. n .. " has died.\27[0m") end)
trigger([[^kxw[tq]_gdeath (.+)$]], function(_, n) echo("\27[31m☠ " .. n .. " (a group minion) has died.\27[0m") end)


-- Timed self-effects (spell/skill durations), e.g. "kxwt_spst mana shield, two hours, 20 minutes".
-- kxwt_spst is sent once per tick per active effect and has NO expiry/down signal, so this table can
-- only accumulate — a dropped buff is never removed. It is therefore NOT shown by the HUD (the live
-- `spells` widget, driven by kxwt_spellup/spelldown, is the authoritative "what's up on you" display);
-- we still capture the duration text here for scripting/AI use, and clear it on reconnect (on_connect).
state.effects = state.effects or {}
trigger([[^kxw[tq]_spst (.+)$]], function(_, s)
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
  state.maintained = {}   -- clear auto-maintain memory; the server re-pushes spellups on connect
end

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
_AA_TEST.maybe_maintain = maybe_maintain
_AA_TEST.MAINTAINABLE = MAINTAINABLE

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
  if t == "" or t:match("^<%d+hp") or t:match("^kxw[tq]_")
     or t:match("^You are using") or t:match("^You are wearing") or t:match("^You can't carry") then
    inv_capturing = false
    -- The block just closed: state.inventory is now current. Bump a monotonic marker and fire an
    -- optional hook so a script (Soulforge.lua) can await the ACTUAL response instead of guessing a
    -- fixed post-send delay — a laggy server can take seconds to answer `inv`, and a fixed short wait
    -- reads a stale/empty inventory (see Soulforge.lua's kick_inventory).
    state.inv_seq = (state.inv_seq or 0) + 1
    if on_inventory then pcall(on_inventory) end
    return
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
  if t == "" or t:match("^<%d+hp") or t:match("^kxw[tq]_") or t:match("^You are carrying") then
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
      state.stam or 0, state.maxstam or 0, (__ready and __ready()) and " (ready)" or "")
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
  -- Regen rates (from `show regen`, auto-queried + cached by Recovery.lua). Surfaced so the decision model
  -- can reason about rest-vs-keep-going, not just the deterministic recovery layer that also reads it.
  if state.regen and state.regen.hp then
    local r = state.regen
    out[#out+1] = string.format("regen per tick: %d hp, %d mana, %d move (while %s%s)",
      r.hp, r.mana or 0, r.move or 0, r.position or state.position or "standing",
      state.sharp and ", sharp" or "")
  end
  -- Inventory/equipment intentionally omitted: kxwt doesn't report them (they're parsed from
  -- `inventory`/`equipment` output and go stale fast), so they're noise in the state block.
  if state.gold then out[#out+1] = "gold: " .. state.gold end
  out[#out+1] = "recovery mode: " .. (state.recover and "on" or "off")
  return table.concat(out, "\n")
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
