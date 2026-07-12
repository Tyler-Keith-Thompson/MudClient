-- AI pilot (ported from the old Swift AIPilotService).
--
-- Drives the character via the local model. Uses the generic host primitives ai_request / after,
-- reads game state from AlterAeon.lua's `state` table + describe_state(), builds its own room map
-- (persisted with Lua serialization), and owns the prompt, turn loop, and the pilot.* controls — all
-- hot-reloadable.

-- Defensive: the shared world-state table always exists here, so the pilot has no load-order
-- dependency on AlterAeon (scripts now load alphabetically, so this file may run first). AlterAeon
-- owns/fills the schema, merging into whatever table exists. Same-line ordering (specific kxwt parsers
-- before our `.*` observer) is guaranteed by the engine's specificity firing, not by load order.
state = state or {}

-- Reactive core (__rx): the goto/recall bridge REACTS to streams — a recall landing (a room change) vs
-- a fizzle ("No god responds") — modelled as Observables; the promise layer (__promise) chains the
-- one-shot recall→await→retry flow (mirrors AutoFight/Corpse/Recovery). `_`-prefixed files aren't
-- auto-loaded, so pull _rx the documented way (dofile fallback for the bare Lua test harness). Promise.lua
-- loads AFTER this file under the directory loader, but __promise is only needed at CALL time (a live
-- recall), by which point every script is loaded — same as AutoFight/Corpse, which also load first.
pcall(require, "_rx")
if not __rx then dofile("Scripts/_rx.lua") end
local rx = __rx

-- Internal hot streams the reactive flows subscribe to, fed from the SINGLE room-change / line matchers
-- (pilot_room_change / pilot_observe) so there's no second matcher to drift. Re-entrancy-safe Subjects
-- (see _rx): a resolving await may synchronously subscribe the next one on the same stream.
local roomChangeS   = rx and rx.subject() or nil   -- a room change landed; emits the new room id
local recallFizzleS = rx and rx.subject() or nil   -- a recall fizzled ("No god responds"); emits ()

-- Keep a reactive flow promise OUT of the HUD promise widget (AIPilot contributes no `active_promises`
-- rows — the recall await is internal plumbing, not a user-visible action). Mirrors AutoFight/Corpse's P().
local function untrack_flow(p)
  if p and __untrack_promise then __untrack_promise(p) end
  return p
end

local cfg = {
  quiet = 0.75, min_interval = 2, human_grace = 4, max_cmds = 3, loop_threshold = 8,
  -- A combat command is ~5-15 tokens (`kill X` / `cast 'X'`), so cap generation hard for combat turns:
  -- it stops at EOS long before the cap, but a low ceiling bounds the pathological no-EOS case and keeps
  -- the local (uncached) path predictable. The full 256 stays for exploration/hosted planning turns.
  max_tokens = 256, combat_max_tokens = 48, max_stale_skips = 2, transcript_lines = 40,
  context_lines = 20,   -- rolling window: max recent output lines sent per turn (bounds prefill cost)
  combat_context_lines = 8,   -- fewer output lines in a combat turn: less prefill = faster first token
  -- Combat-only: when ON the pilot acts ONLY while in a fight and stays dormant between fights (you
  -- explore/move manually; the AI auto-resumes the instant the next fight starts). See fire_if_ready.
  -- DEFAULT ON: the intended use is human-drives-exploration, AI-fights. `pilot.combat_only('off')`
  -- for a fully autonomous pilot that also explores/loots/navigates on its own.
  combat_only = true,
  circle_threshold = 3, -- after this many moves with no NEW room, the script auto-routes to a frontier
  use_tools = false,    -- set by the brain choice below (tools for hosted models, CMD: text for local)
  brain = "local",      -- DEFAULT decision model: "sonnet" | "haiku" | "local". Applied on load.
                        -- Defaults LOCAL (the fine-tuned combat model, no API cost/credits). Switch to
                        -- "sonnet"/"haiku" with pilot.brain(...) for the smarter hosted brains.
  -- The LM Studio model key requested on the "local" brain. MUST be an explicit key: with more than one
  -- model loaded, an empty id makes LM Studio reject the request ("Invalid model identifier"). Override
  -- with `pilot.model(<key>)` / `#ai model <key>`.
  local_model = "qwen3.6-27b-alteraeon-mlx",
  -- Memory head: a SEPARATE model (hosted Claude via Anthropic's OpenAI-compat endpoint) maintains
  -- structured world state (creatures/items here, inventory, a running summary) from raw output, so
  -- the decision model reads clean facts instead of hallucinating from scrolling text.
  -- DEFAULT OFF: the memory head is hosted-only (Haiku via Anthropic), so it would fail/charge with no
  -- API credits. Enable it (and set a mem model) once you're on a hosted setup: `pilot.mem('on')`.
  use_memory = false,
  -- Memory head does EASY, FREQUENT extraction (parse room text -> structured facts), so it wants a
  -- cheap fast model. Haiku is the right default; the DECISION brain is where Sonnet belongs.
  mem_model = "claude-haiku-4-5-20251001",  -- pilot.memmodel('haiku'|'sonnet'|<id>) to switch
  -- RAG: retrieve the few doc passages most relevant to the current situation and feed them to the
  -- brain, so it knows the game's mechanics on demand instead of us hardcoding facts. Index is built
  -- offline (tools/finetune/build_rag_index.py) and embedded with the LOCAL embedding model.
  use_rag = true, rag_k = 3,
  budget = 0,   -- session $ cap; auto-disarms when exceeded (0 = off). Set with pilot.budget(<dollars>).
  home = os.getenv("HOME") or "",
  -- Trailing assistant prefill sent with every request. Qwen3.x always opens a <think> block and
  -- spends the whole token budget reasoning (→ empty/truncated commands); prefilling a CLOSED,
  -- empty think block suppresses that, so we get a fast direct command. Set to "" for models that
  -- don't have a thinking mode (then nothing is appended). Model-specific, so it lives here.
  think_prefill = "<think>\n\n</think>\n\n",
}
cfg.dir = cfg.home .. "/Documents/MudClient"
cfg.map_file = cfg.dir .. "/explored.lua"
cfg.trace_file = cfg.dir .. "/ai-traces.jsonl"
cfg.human_trace_file = cfg.dir .. "/human-traces.jsonl"   -- demonstrations from YOUR play (gold examples)
cfg.rag_index = cfg.dir .. "/rag_index.json"              -- doc embeddings; loader prefers the .bin sibling
os.execute("mkdir -p '" .. cfg.dir .. "' 2>/dev/null")

-- Runtime state that should survive pilot.reload() (globals persist in the lua state across the
-- script re-running). The epoch invalidates callbacks/timers scheduled by the previous load so a
-- pre-reload in-flight model request can't fire stale commands afterward.
_AIP = _AIP or {}
_AIP.epoch = (_AIP.epoch or 0) + 1
local EPOCH = _AIP.epoch

local P = {
  -- Default OFF. The pilot never auto-runs; it acts only after an explicit `pilot.on()`.
  enabled = _AIP.enabled or false, busy = false,
  goal = _AIP.goal or "Explore, kill easy mobs, level up, and survive.",
  transcript = {}, last_turn = 0, recent_cmds = {}, loop_breaks = 0, stale_skips = 0,
  requested = {}, input_seq = 0, last_human = 0, pending = nil, nudge = nil, gen = 0, snap_seq = 0,
  snap_fighting = false, self_sent = {}, moves_since_new = 0, last_move_dir = nil, room_trail = {},
  world = { creatures = {}, items = {}, inventory = {}, summary = "", room_id = nil }, mem_fail = 0,
  manual = "", nav = nil,
  rooms = {}, current_room = nil, dir_deltas = {}, trace = true, memories = {},
  demo_count = 0,   -- human demonstrations captured this session
}

-- The parsed `waypoint` list (P.waypoints) and the learned number<->room maps (P.wp_room/P.room_wp) are
-- PERSISTED with the map (save_map/load_map), so they survive both a hot pilot.reload() and a full
-- relaunch — you list your waypoints once and goto keeps working. They're lazy-created where first used
-- and repopulated by load_map() at the bottom of this file.

local OPP = { north="south", south="north", east="west", west="east", up="down", down="up",
  northeast="southwest", southwest="northeast", northwest="southeast", southeast="northwest" }
local CANON = { n="north", s="south", e="east", w="west", u="up", d="down", ne="northeast",
  nw="northwest", se="southeast", sw="southwest", north="north", south="south", east="east",
  west="west", up="up", down="down", northeast="northeast", northwest="northwest",
  southeast="southeast", southwest="southwest" }

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function trim_transcript()
  while #P.transcript > cfg.transcript_lines do table.remove(P.transcript, 1) end
end

-- ---- map persistence (via the shared crash-safe persist module) ----------------------------
-- Atomic writes, a shrink-proof `.bak`, and self-healing reads all live in _persist now; the map just
-- hands it the table. This replaced a hand-rolled io.open("w") whose non-atomic truncate once wiped a
-- 2500+ room map (an interrupted write left explored.lua empty; the next launch loaded nothing and saved
-- over it). Same `return {rooms=...}` on-disk format, so existing explored.lua / .bak load unchanged.
pcall(require, "_persist")
if not __persist then dofile("Scripts/_persist.lua") end
local persist = __persist
local function count_map(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end

local save_timer
local function save_map()
  -- Persist the parsed `waypoint` list + learned number<->room maps alongside the room map, so goto's
  -- waypoint routing survives reloads and relaunches (list once, keep working).
  persist.save(cfg.map_file, { rooms = P.rooms, dir_deltas = P.dir_deltas, memories = P.memories,
                               waypoints = P.waypoints, wp_room = P.wp_room, room_wp = P.room_wp })
end
-- Debounce map writes: each edit cancels the pending save and re-arms a fresh 2s timer, so a burst of
-- edits coalesces into one write 2s after the last. (Was a generation counter that neutered stale
-- timers; the host now returns a cancellable timer id, which does the same thing directly.)
local function schedule_save()
  if cancel and save_timer then cancel(save_timer) end
  save_timer = after(2, save_map)
end
local function load_map()
  local t = persist.load(cfg.map_file, function(m) if echo then echo(m, "yellow") end end)
  if type(t) == "table" and t.rooms then
    P.rooms = t.rooms or {}; P.dir_deltas = t.dir_deltas or {}; P.memories = t.memories or {}
    P.waypoints = t.waypoints or {}; P.wp_room = t.wp_room or {}; P.room_wp = t.room_wp or {}
    if echo then echo(string.format("[map] loaded %d rooms, %d waypoints from explored.lua.",
                       count_map(P.rooms), count_map(P.waypoints)), "cyan") end
  end
end

-- ---- room map ------------------------------------------------------------------------------
local function coord_key(c) return c[1] .. "," .. c[2] .. "," .. c[3] .. "," .. c[4] end

function pilot_room_change(id, coord)
  local from_id = P.current_room
  local from = from_id and P.rooms[from_id] and P.rooms[from_id].coord
  local is_new = (P.rooms[id] == nil)            -- first time we've ever entered this room?
  P.rooms[id] = P.rooms[id] or { exits = {}, moves = {} }
  P.rooms[id].coord = coord
  if state and state.area then P.rooms[id].area = state.area end   -- tag area (feeds future `navigate`)
  -- Build the move edge from the direction WE COMMANDED (P.last_move_dir) — NOT the game's kxwt
  -- `walkdir`, which is mistimed and was mislabeling edges (the source of the "phantom" exits).
  -- Guards, so a room change that WASN'T a step never invents an adjacency:
  --   * moved      — the COORDINATES actually changed (not a re-entry / same spot);
  --   * exits[dir]  — we left through an exit the room ACTUALLY ADVERTISES. A recall or a death drops
  --                  you somewhere you didn't walk to, so `dir` won't be a real exit of the room you
  --                  left — no phantom edge, and no need to special-case teleports or death at all.
  local dir = P.last_move_dir
  local from_room = from_id and P.rooms[from_id]
  local moved = from and (coord[1] ~= from[1] or coord[2] ~= from[2]
                          or coord[3] ~= from[3] or coord[4] ~= from[4])
  if dir and from_room and moved and from_room.exits[dir] then
    P.rooms[from_id].moves[dir] = id
    if OPP[dir] then P.rooms[id].moves[OPP[dir]] = from_id end
    if from[4] == coord[4] then
      local d = { coord[1] - from[1], coord[2] - from[2], coord[3] - from[3] }
      P.dir_deltas[dir] = d
      if OPP[dir] then P.dir_deltas[OPP[dir]] = { -d[1], -d[2], -d[3] } end
    end
  end
  -- Reaching a new room IS progress: clear any repeated-command streak so the loop detector doesn't
  -- carry a count across rooms (e.g. `east` issued in several different rooms is not a stuck loop).
  if id ~= from_id then P.recent_cmds = {}; P.loop_breaks = 0 end
  -- Circling detection: count moves that DON'T reach genuinely new ground. The command-based loop
  -- detector can't see an A<->B<->A oscillation (the commands alternate), so we track room novelty
  -- instead. Entering a brand-new room resets it; bouncing among known rooms accrues it.
  if is_new then P.moves_since_new = 0; P.auto_streak = 0
  elseif id ~= from_id then P.moves_since_new = (P.moves_since_new or 0) + 1 end
  if id ~= from_id then P.last_move_dir = nil end   -- the move succeeded; nothing to mark blocked
  if id ~= from_id then
    P.room_trail[#P.room_trail + 1] = id            -- recent-path trail so the model can SEE oscillation
    while #P.room_trail > 8 do table.remove(P.room_trail, 1) end
  end
  P.current_room = id
  -- A landing (room-identity change): feed the reactive room-change stream so the in-flight recall await
  -- (goto_recall_attempt) resolves "landed". No subscriber when no recall is in flight → simply dropped.
  if id ~= from_id and roomChangeS then roomChangeS:onNext(id) end
  -- Learn which room a waypoint NUMBER travels to, from an observed `waypoint <n>` that just landed
  -- here (set in on_user_input). This is ground truth — no fragile description matching. `moved` guards
  -- against a failed hop attributing a later step to the number.
  if P.wp_pending and moved then learn_waypoint(P.wp_pending, id); P.wp_pending = nil end
  table.insert(P.transcript, "--- [MOVED to a NEW room. Everything above is a PREVIOUS room — creatures and items there are gone; act only on what's below.] ---")
  P.input_seq = P.input_seq + 1
  trim_transcript(); schedule_save()
  -- A `goto` bridge landed us somewhere new: re-decide from here (deferred a beat so exits / the
  -- kxwt_waypoint flag for this room settle first).
  if P.goto_bridge and id ~= from_id then
    after(0.4, function() if P.goto_bridge then goto_bridge_advance() end end)
  end
  if P.nav then nav_step() end   -- a route is in progress: take the next step
end

function pilot_room_name(n)
  local id = P.current_room
  if not id then return end
  P.rooms[id] = P.rooms[id] or { exits = {}, moves = {} }
  if P.rooms[id].name ~= n then P.rooms[id].name = n; schedule_save() end
end

local function parse_exits(line)
  local lower = line:lower()
  local body = lower:match("%[exits:(.-)%]") or lower:match("obvious exits:(.+)")
  if not body then return nil end
  local set, any = {}, false
  for w in body:gmatch("%a+") do
    local c = CANON[w]; if c then set[c] = true; any = true end
  end
  return any and set or nil
end

-- A room is a frontier if it has an exit we've never taken (unexplored from there) AND haven't blocked
-- (a blocked exit is a dead end for routing, so a room whose only untaken exits are blocked is NOT a
-- frontier — explore shouldn't route toward it).
local function has_frontier(rid)
  local r = P.rooms[rid]
  if not r then return false end
  for d in pairs(r.exits) do
    if not r.moves[d] and not (r.blocked and r.blocked[d]) then return true end
  end
  return false
end

-- ---- landmarks (rooms YOU tag, e.g. "trainer") ---------------------------------------------
-- Marks live on the room as a set of lowercase labels (r.marks[label]=true), persisted with the map
-- like any other room field. A label matches a query if it EQUALS it or CONTAINS it, so `goto train`
-- (and navigate("train")) both reach a "trainer" mark. Purely player-driven — the game never sets these.
local function has_mark(r, label)
  if not r or not r.marks then return false end
  for m in pairs(r.marks) do if m == label or m:find(label, 1, true) then return true end end
  return false
end

-- One "- label: room — area; room — area" line per tagged label, current room flagged inline. Shared by
-- the MAP block sent to the model and the `#mark` listing. "" when nothing is marked.
local function marks_list()
  local by_label, order = {}, {}
  for id, r in pairs(P.rooms) do
    if r.marks then
      for m in pairs(r.marks) do
        if not by_label[m] then by_label[m] = {}; order[#order + 1] = m end
        local loc = (r.name or ("room " .. tostring(id))) .. (r.area and (" — " .. r.area) or "")
        if id == P.current_room then loc = loc .. " (you are here)" end
        by_label[m][#by_label[m] + 1] = loc
      end
    end
  end
  if #order == 0 then return "" end
  table.sort(order)
  local lines = {}
  for _, m in ipairs(order) do lines[#lines + 1] = "- " .. m .. ": " .. table.concat(by_label[m], "; ") end
  return table.concat(lines, "\n")
end

-- ---- waypoints / recall (AlterAeon fast-travel) --------------------------------------------
-- The `waypoint` command prints a numbered list; rows come in three shapes (verified against real
-- game output):
--   "1 - A heavily warded waypoint"                       -> in range, travel now
--   "6 (bridge  4) - The Temple of Zin"                   -> out of range: waypoint to 4, then to 6
--   "15 (no bridge) - The Dragon Tooth Waypoint"          -> out of range, no bridge available
-- Parse one line into { num, name, bridge=<n|nil>, reachable=<bool> }, or nil if it isn't a row.
local function parse_waypoint_line(line)
  local num, br, name = line:match("^%s*(%d+)%s*%(bridge%s+(%d+)%)%s*%-%s*(.+)$")
  if num then return { num = tonumber(num), name = trim(name), bridge = tonumber(br), reachable = false } end
  num, name = line:match("^%s*(%d+)%s*%(no bridge%)%s*%-%s*(.+)$")
  if num then return { num = tonumber(num), name = trim(name), bridge = nil, reachable = false } end
  num, name = line:match("^%s*(%d+)%s*%-%s*(.+)$")
  if num then return { num = tonumber(num), name = trim(name), bridge = nil, reachable = true } end
  return nil
end

-- Parse a whole `waypoint` listing into an ordered array of entries (see parse_waypoint_line).
local function parse_waypoint_list(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local e = parse_waypoint_line(line)
    if e then out[#out + 1] = e end
  end
  return out
end

-- Recall (`recall` / `/`) is unreliable — non-god followers frequently get this exact line back, which
-- is our signal to wait and try again. Success is instead observed as a room change (kxwt_rvnum).
local function recall_failed(line)
  return line:find("No god responds to your call", 1, true) ~= nil
end

-- The number from a `waypoint <n>` travel command, tolerating AlterAeon's command abbreviations
-- ("way 8", "wayp 8", "waypoint 8"), or nil. This is how we learn which room a waypoint number reaches
-- (on_user_input sets it pending, pilot_room_change records it on arrival). The old matcher required the
-- full word "waypoint", so typing "way 1" taught it nothing.
local function waypoint_cmd_num(cmd)
  local n = cmd:match("^way%a*%s+(%d+)%s*$")
  return n and tonumber(n) or nil
end

-- ---- minimap (consumed by the HUD) ----------------------------------------------------------
-- Lay out the local area GEOMETRICALLY, from each room's kxwt coordinates, so loops close to their
-- true shape (no non-planar overlaps) and real coordinate gaps render as space. Only the current FLOOR
-- (same plane + z) is drawn; up/down lead to other floors. A coordless current room falls back to a
-- unit-step graph walk. Returns { w, h, cells = { [row] = { [col] = { ch, fg, bold } } } }, or nil.
local MM_VEC = { north = { 0, -1 }, south = { 0, 1 }, east = { 1, 0 }, west = { -1, 0 },
  northeast = { 1, -1 }, northwest = { -1, -1 }, southeast = { 1, 1 }, southwest = { -1, 1 } }
-- Render step: horizontal 4 cells, vertical 2 (a doubled grid). The between cells give EVERY link its
-- own drawn connector — including the vertical "│", so a north/south connection is unambiguous rather
-- than implied by stacking. 4:2 also corrects for terminal cells being ~2x taller than wide, so it
-- reads square. MM_LINK = the full cell run for a WALKED exit; MM_STUB = the single near cell for an
-- UNwalked one.
local MM_LINK = {
  east = { { 1, 0, "─" }, { 2, 0, "─" }, { 3, 0, "─" } },
  west = { { -1, 0, "─" }, { -2, 0, "─" }, { -3, 0, "─" } },
  north = { { 0, -1, "│" } }, south = { { 0, 1, "│" } },
  northeast = { { 2, -1, "╱" } }, southwest = { { -2, 1, "╱" } },
  northwest = { { -2, -1, "╲" } }, southeast = { { 2, 1, "╲" } },
}
local MM_STUB = {
  east = { 1, 0, "─" }, west = { -1, 0, "─" }, north = { 0, -1, "│" }, south = { 0, 1, "│" },
  northeast = { 2, -1, "╱" }, southwest = { -2, 1, "╱" }, northwest = { -2, -1, "╲" }, southeast = { 2, 1, "╲" },
}
-- grid-offset "gx,gy" -> compass direction, to draw a WALKED connector by the GEOMETRY between two
-- placed rooms (the coordinates, not the possibly-mislabelled stored edge direction).
local GEO = { ["0,-1"] = "north", ["0,1"] = "south", ["1,0"] = "east", ["-1,0"] = "west",
  ["1,-1"] = "northeast", ["-1,-1"] = "northwest", ["1,1"] = "southeast", ["-1,1"] = "southwest" }
-- terrain code -> node colour (from `help 3.terrain`, codes 0-39). Water=blue, forest/field=green,
-- sand/desert=yellow, rock/mountain/underground=gray, town/city=white, lava=red, ice=cyan,
-- swamp/marsh=magenta, shadow/crystal=bright magenta/cyan. Unknown terrain falls back to cyan.
local TERRAIN_COLOR = {
  [1] = "white", [2] = "white", [28] = "brightwhite", [26] = "brightblack",             -- building/town/city/ruins
  [3] = "green", [8] = "green", [15] = "green",                                          -- field/plateau/hill
  [4] = "brightgreen", [5] = "green", [6] = "green", [17] = "brightgreen", [34] = "green", -- forests/jungle/taiga
  [7] = "magenta", [29] = "magenta", [38] = "magenta",                                   -- swamp/marsh/mire
  [9] = "yellow", [12] = "yellow", [16] = "yellow", [14] = "brightyellow", [30] = "yellow", -- sand/desert/dunes/beach/wasteland
  [10] = "brightblack", [11] = "brightblack", [33] = "brightblack",                      -- mountain/rock/metal
  [13] = "brightwhite", [24] = "brightcyan",                                             -- tundra/ice
  [18] = "blue", [19] = "brightblue", [20] = "blue", [21] = "blue", [32] = "blue",       -- ocean/stream/river/underwater/water
  [22] = "brightblack", [27] = "brightblack", [35] = "green", [37] = "brightblack",      -- underground/cave/sewer/catacomb
  [23] = "brightcyan", [31] = "brightwhite",                                             -- air/cloud
  [25] = "brightred",                                                                    -- lava
  [36] = "brightmagenta", [39] = "brightcyan",                                           -- shadow/crystal
}

function minimap(hw, hh)
  hw, hh = hw or 3, hh or 2
  local cur = P.current_room
  if not cur or not P.rooms[cur] then return nil end

  -- ---- placement: geometric (by kxwt coords), or a unit-step graph walk if we have no coords -------
  local pos, order, occ = {}, { cur }, { ["0,0"] = true }
  pos[cur] = { 0, 0 }
  local function claim(id, gx, gy)                         -- one room per cell; the first to land keeps it
    if math.abs(gx) > hw or math.abs(gy) > hh then return false end
    local key = gx .. "," .. gy
    if occ[key] then return false end
    occ[key] = true; pos[id] = { gx, gy }; order[#order + 1] = id; return true
  end

  local rc = P.rooms[cur].coord
  if rc and rc[1] then
    -- GEOMETRIC. Gather the connected component on THIS floor (same plane + z) by walking every
    -- move-edge (we place by COORDINATES, so we don't need — and no longer gate on — advertised exits;
    -- a room goes to its true spot whether or not its exits have been recorded yet).
    local cx, cy, cz, cpl = rc[1], rc[2], rc[3], rc[4]
    local raw, seen, queue, head = {}, { [cur] = true }, { cur }, 1
    while head <= #queue do
      local id = queue[head]; head = head + 1
      for _, nb in pairs(P.rooms[id].moves or {}) do
        if not seen[nb] then
          seen[nb] = true
          local c = P.rooms[nb] and P.rooms[nb].coord
          if c and c[1] and c[4] == cpl and c[3] == cz then
            raw[nb] = { c[1] - cx, c[2] - cy }; queue[#queue + 1] = nb
          end
        end
      end
    end
    -- Local unit = the smallest nonzero coordinate step, so a 1-unit and an 8-unit area both collapse
    -- to one grid cell per adjacent room (real gaps stay as multi-cell space).
    local unit
    for _, o in pairs(raw) do
      local ax, ay = math.abs(o[1]), math.abs(o[2])
      if ax > 0 and (not unit or ax < unit) then unit = ax end
      if ay > 0 and (not unit or ay < unit) then unit = ay end
    end
    unit = unit or 1
    local ids = {}
    for id in pairs(raw) do ids[#ids + 1] = id end
    table.sort(ids)                                        -- deterministic conflict resolution
    for _, id in ipairs(ids) do
      local o = raw[id]
      -- north is +y in kxwt coords but UP on screen, so negate y for the row.
      claim(id, math.floor(o[1] / unit + 0.5), math.floor(-o[2] / unit + 0.5))
    end
  else
    -- FALLBACK: coordless current room -> topological unit-step walk over the move-graph.
    local queue, head = { cur }, 1
    while head <= #queue do
      local id = queue[head]; head = head + 1
      local g = pos[id]
      for d, nb in pairs(P.rooms[id].moves or {}) do
        local v = MM_VEC[d]
        if v and not pos[nb] and P.rooms[nb] then
          if claim(nb, g[1] + v[1], g[2] + v[2]) then queue[#queue + 1] = nb end
        end
      end
    end
  end

  -- ---- render: doubled grid (4 cols / 2 rows per unit), square on ~2:1 terminal cells --------------
  local W, H = 8 * hw + 1, 4 * hh + 1
  local ccol, crow = 4 * hw + 1, 2 * hh + 1
  local cells = {}
  local function put(col, row, ch, fg, bold)
    if col < 1 or col > W or row < 1 or row > H then return end
    cells[row] = cells[row] or {}
    cells[row][col] = { ch = ch, fg = fg, bold = bold }
  end
  local function node_xy(g) return ccol + 4 * g[1], crow + 2 * g[2] end
  local function sign(n) return n > 0 and 1 or (n < 0 and -1 or 0) end

  -- WALKED connectors, drawn by the geometry between two placed rooms (every move-edge you've walked;
  -- no exit-gating). Adjacent cells get the one-step connector; a real coordinate GAP (rooms >1 cell
  -- apart) is drawn as a straight line spanning the space, else left as a visible gap.
  for _, id in ipairs(order) do
    local a = pos[id]; local col, row = node_xy(a); local r = P.rooms[id]
    for _, nb in pairs(r.moves or {}) do
      local b = pos[nb]
      if b and not (b[1] == a[1] and b[2] == a[2]) then
        local gdx, gdy = b[1] - a[1], b[2] - a[2]
        if math.max(math.abs(gdx), math.abs(gdy)) == 1 then
          local link = MM_LINK[GEO[gdx .. "," .. gdy]]
          if link then for _, c in ipairs(link) do put(col + c[1], row + c[2], c[3], "brightblack") end end
        elseif gdy == 0 then                               -- horizontal gap
          local sx = sign(gdx)
          for c = col + sx, col + 4 * gdx - sx, sx do put(c, row, "─", "brightblack") end
        elseif gdx == 0 then                               -- vertical gap
          local sy = sign(gdy)
          for rr = row + sy, row + 2 * gdy - sy, sy do put(col, rr, "│", "brightblack") end
        end
      end
    end
  end
  -- Exit stubs: a short tick for EVERY advertised, non-dead-end exit that doesn't already have a drawn
  -- connector — i.e. whose neighbour isn't on this window, whether it's unexplored, off-window (a big
  -- coordinate jump placed it past the edge), or not-yet-stored. So a room's exits are always visible
  -- even when the room they lead to isn't. Green = unexplored (a frontier); dim = explored but off-map.
  for _, id in ipairs(order) do
    local col, row = node_xy(pos[id]); local r = P.rooms[id]
    for d in pairs(r.exits or {}) do
      local s = MM_STUB[d]
      if s and not (r.blocked and r.blocked[d]) then
        local sc, sr = col + s[1], row + s[2]
        if not (cells[sr] and cells[sr][sc]) then
          put(sc, sr, s[3], (r.moves and r.moves[d]) and "brightblack" or "brightgreen")
        end
      end
    end
  end
  -- Nodes on top: colour = terrain; glyph = your mark (★) / waypoint (W) / frontier (▣) / explored (□);
  -- YOU (◉) last, so a coordinate collision (the game has some overlapping rooms) never hides your marker.
  for _, id in ipairs(order) do
    if id ~= cur then
      local col, row = node_xy(pos[id]); local r = P.rooms[id]
      if r.marks and next(r.marks) then put(col, row, "★", "brightgreen", true)
      elseif r.waypoint then put(col, row, "ᴡ", "brightmagenta", true)
      else put(col, row, has_frontier(id) and "▣" or "□", TERRAIN_COLOR[r.terrain] or "cyan") end
    end
  end
  local cc, cr = node_xy(pos[cur])
  put(cc, cr, "◉", "brightyellow", true)
  return { w = W, h = H, cells = cells }
end

-- BFS over the move graph from the current room to the nearest room with an unexplored exit.
-- Returns the FIRST direction to head and the distance, or nil if everything reachable is explored.
local function nearest_unexplored()
  local start = P.current_room
  if not start or not P.rooms[start] then return nil end
  local seen = { [start] = true }
  local queue, head = {}, 1
  for d, nb in pairs(P.rooms[start].moves or {}) do
    if not seen[nb] then seen[nb] = true; queue[#queue + 1] = { id = nb, dir = d, dist = 1 } end
  end
  while head <= #queue do
    local n = queue[head]; head = head + 1
    if has_frontier(n.id) then return n.dir, n.dist end
    for d, nb in pairs(P.rooms[n.id] and P.rooms[n.id].moves or {}) do
      if not seen[nb] then seen[nb] = true; queue[#queue + 1] = { id = nb, dir = n.dir, dist = n.dist + 1 } end
    end
  end
  return nil
end

-- BFS over the move graph from `start` to the nearest room satisfying matches(id). Returns the route as
-- a list of directions and the destination id, or nil if unreachable. BFS gives the shortest path and is
-- inherently loop-free (the `seen` set) — so a route can NEVER 2-cycle the way the old forced router did.
local function find_path_from(start, matches)
  if not start or not P.rooms[start] then return nil end
  local seen = { [start] = true }
  local queue, head = { { id = start, path = {} } }, 1
  while head <= #queue do
    local n = queue[head]; head = head + 1
    local r = P.rooms[n.id]
    for d, nb in pairs(r and r.moves or {}) do
      -- never route through an exit we've learned is a dead end ("cannot go that way").
      if not seen[nb] and not (r.blocked and r.blocked[d]) then
        seen[nb] = true
        local np = { table.unpack(n.path) }; np[#np + 1] = d
        if matches(nb) then return np, nb end
        queue[#queue + 1] = { id = nb, path = np }
      end
    end
  end
  return nil
end
-- Path from the CURRENT room (the common case).
local function find_path(matches) return find_path_from(P.current_room, matches) end

-- The reachable room whose kxwt COORDINATES sit closest to `coord`. This is the graceful fallback for
-- `goto death`: the room you died in is often inside an area you entered through a portal / special exit
-- the move-graph can't retrace, so there's no walkable route straight to it — get as close as the
-- explored map allows instead of giving up. Same plane strongly preferred (a huge cross-plane penalty),
-- then squared 3D distance. Returns a reachable room id (never the current room), or nil.
local function nearest_reachable_to_coord(coord)
  if not coord then return nil end
  local start = P.current_room
  if not start or not P.rooms[start] then return nil end
  local seen = { [start] = true }
  local queue, head = { start }, 1
  local best, best_d
  while head <= #queue do
    local id = queue[head]; head = head + 1
    local r = P.rooms[id]
    if id ~= start and r and r.coord then
      local c = r.coord
      local dp = (c[4] ~= coord[4]) and 1e9 or 0                 -- different plane: almost never prefer it
      local dx, dy, dz = c[1] - coord[1], c[2] - coord[2], c[3] - coord[3]
      local d = dp + dx * dx + dy * dy + dz * dz
      if not best_d or d < best_d then best_d, best = d, id end
    end
    for dir, nb in pairs(r and r.moves or {}) do
      if not seen[nb] and not (r.blocked and r.blocked[dir]) then seen[nb] = true; queue[#queue + 1] = nb end
    end
  end
  return best
end

-- Built-in `goto` targets that mean "a waypoint room" rather than a player mark.
local WP_ALIASES = { waypoint = true, waypoints = true, wp = true }

-- The known waypoint room from which `label` is walkable in the FEWEST steps, or nil. This is the room
-- `goto` will waypoint-hop to before walking the final leg. We only need the room id — the walk from it
-- is recomputed on arrival.
local function nearest_waypoint_for(label)
  local best_len, best_id
  for id, r in pairs(P.rooms) do
    if r.waypoint then
      if has_mark(r, label) then return id end          -- the mark IS on this waypoint (0 steps) — unbeatable
      local path = find_path_from(id, function(x) return x ~= id and has_mark(P.rooms[x], label) end)
      if path and (not best_id or #path < best_len) then best_len, best_id = #path, id end
    end
  end
  return best_id
end

-- The waypoint NUMBER that travels to room `id`, or nil. Prefers matching the room's name against the
-- LIVE `waypoint` list (P.waypoints) — that's always current and needs no prior travel, so a named
-- waypoint like "The Indira Shrine" resolves to its number the moment you've run `waypoint` once. Falls
-- back to what we LEARNED from watching you `waypoint <n>` this session, which covers generic waypoints
-- ("A large waypoint in a stony field") whose list text doesn't match the room name. NOTE: the learned
-- map is session-only (not persisted) — a relaunch/reload forgets it, so the name match is what makes
-- this robust across sessions.
local function waypoint_num_for_room(id)
  local r = P.rooms[id]
  local rname = r and r.name and r.name:lower()
  if rname and P.waypoints then
    for num, w in pairs(P.waypoints) do
      local wn = w.name and w.name:lower()
      if wn and (wn == rname or wn:find(rname, 1, true) or rname:find(wn, 1, true)) then return num end
    end
  end
  if P.room_wp and P.room_wp[id] then return P.room_wp[id] end
  return nil
end

-- Learn that waypoint NUMBER `num` travels to room `id` — recorded by OBSERVING an actual `waypoint <n>`
-- move (see on_user_input + pilot_room_change). Writes into the _AIP-backed maps, so it survives a hot
-- pilot.reload(); a full relaunch forgets it (numbers shift with decay/reorder anyway), and the live-list
-- name match carries goto across relaunches. Also confirms the destination is a waypoint room.
local function learn_waypoint(num, id)
  if not num or not id or not P.rooms[id] then return end
  P.wp_room = P.wp_room or {}          -- number -> room id (aliased to _AIP.wp_room)
  P.room_wp = P.room_wp or {}          -- room id -> number
  -- If this number pointed at a different room before (reorder), drop the stale reverse entry.
  local prev = P.wp_room[num]
  if prev and prev ~= id then P.room_wp[prev] = nil end
  P.wp_room[num] = id
  P.room_wp[id] = num
  P.rooms[id].waypoint = true
  schedule_save()
end

-- An untaken (and not-blocked) exit of room `rid`, or nil. This is the door into NEW ground.
local function untaken_exit(rid)
  local r = P.rooms[rid]
  if not r then return nil end
  local untaken = {}
  for d in pairs(r.exits) do
    if not r.moves[d] and not (r.blocked and r.blocked[d]) then untaken[#untaken + 1] = d end
  end
  if #untaken == 0 then return nil end
  table.sort(untaken); return untaken[1]
end

-- A route that actually ENTERS new ground: take an untaken exit here if there is one, else walk to the
-- nearest room that has one and step THROUGH it. (The old version stopped at the doorstep, so the model
-- would arrive and immediately backtrack — an endless ping-pong.)
local function path_to_unexplored()
  local here = untaken_exit(P.current_room)
  if here then return { here } end
  local path, dest = find_path(function(id) return id ~= P.current_room and has_frontier(id) end)
  if not path then return nil end
  local exit = untaken_exit(dest)
  if exit then path[#path + 1] = exit end   -- the final step crosses into the unexplored room
  return path
end

-- Turn a destination string into a room predicate. "unexplored"/"new" -> nearest room with an
-- unexplored exit; otherwise a fuzzy match on area or room name.
local function resolve_nav(dest)
  local d = trim(dest or ""):lower()
  if d == "" or d == "unexplored" or d == "new" or d == "frontier" or d:find("explore", 1, true) then
    return function(id) return id ~= P.current_room and has_frontier(id) end, "unexplored ground"
  end
  return function(id)
    local r = P.rooms[id]
    if not r or id == P.current_room then return false end
    if has_mark(r, d) then return true end                      -- a room YOU tagged (e.g. "trainer")
    if r.area and r.area:lower():find(d, 1, true) then return true end
    if r.name and r.name:lower():find(d, 1, true) then return true end
    return false
  end, d
end

-- The best direction to make exploration progress: an untaken exit FROM THE CURRENT ROOM if there is
-- one (don't backtrack), otherwise the first step of the BFS route to the nearest frontier. nil when
-- everything reachable is explored. This is what the script walks when the model gets stuck circling.
local function best_explore_dir()
  local r = P.current_room and P.rooms[P.current_room]
  if not r or not r.exits then return nil end
  local blocked = r.blocked or {}
  -- Prefer a REAL exit of THIS room we've never walked and isn't a known dead end.
  local untaken = {}
  for d in pairs(r.exits) do
    if not r.moves[d] and not blocked[d] then untaken[#untaken + 1] = d end
  end
  if #untaken > 0 then table.sort(untaken); return untaken[1] end
  -- Else head toward the nearest frontier — but ONLY if that first step is an actual exit here and
  -- not blocked. This guards against a corrupt move-graph edge routing us into a wall.
  local dir = nearest_unexplored()
  if dir and r.exits[dir] and not blocked[dir] then return dir end
  return nil
end

local function exploration_summary()
  local count = 0; for _ in pairs(P.rooms) do count = count + 1 end
  local lines = {}
  if count > 0 then lines[#lines + 1] = "Rooms explored this session: " .. count .. "." end
  -- Recent path so the model can see when it's pacing back and forth (it only gets the current room
  -- otherwise, so it can't tell it's looping). Purely factual — no instruction.
  if #P.room_trail >= 4 then
    local names = {}
    for _, rid in ipairs(P.room_trail) do
      local r = P.rooms[rid]; names[#names + 1] = (r and r.name) or ("room " .. tostring(rid))
    end
    lines[#lines + 1] = "Your last rooms (oldest→newest): " .. table.concat(names, " → ")
  end
  local here = P.current_room and P.rooms[P.current_room]
  if here and next(here.exits) then
    local visited = {}
    for _, r in pairs(P.rooms) do if r.coord then visited[coord_key(r.coord)] = r.name or "a visited room" end end
    local dirs = {}; for d in pairs(here.exits) do dirs[#dirs + 1] = d end; table.sort(dirs)
    local infos, current_frontier = {}, false
    for _, dir in ipairs(dirs) do
      if here.moves[dir] then
        -- We have actually traversed this exit (or its reverse): definitively explored.
        local dest = P.rooms[here.moves[dir]]
        infos[#infos + 1] = dir .. " → " .. ((dest and dest.name) or "a visited room") .. " (explored)"
      else
        -- Haven't walked it; try coordinates as a hint, otherwise call it unexplored.
        local delta = P.dir_deltas[dir]
        local name = delta and here.coord
          and visited[coord_key({ here.coord[1] + delta[1], here.coord[2] + delta[2],
                                  here.coord[3] + delta[3], here.coord[4] })]
        if name then
          infos[#infos + 1] = dir .. " → " .. name .. " (explored)"
        else
          infos[#infos + 1] = dir .. " → UNEXPLORED"; current_frontier = true
        end
      end
    end
    lines[#lines + 1] = "Exits from your current room: " .. table.concat(infos, ", ")
    -- If there's nothing new here, point the way to the nearest unexplored ground (BFS over the map).
    if not current_frontier then
      local dir, dist = nearest_unexplored()
      if dir then
        lines[#lines + 1] = "Nothing new in this room. The nearest unexplored area is ~" .. dist
          .. " room(s) away — move " .. dir .. " toward it."
      else
        lines[#lines + 1] = "This room is fully explored, and your known map has no unexplored exits left."
      end
    end
  end
  -- Landmarks the player has tagged (see `mark`), so the model can head to one on purpose — e.g. a
  -- trainer to level up. navigate("<label>") routes to the nearest matching mark.
  local ml = marks_list()
  if ml ~= "" then
    lines[#lines + 1] = "Marked places (navigate('<label>') routes to the nearest):\n" .. ml
  end
  -- Fast-travel: waypoints seen this session. From a waypoint room, the game's `waypoint <n>` jumps to
  -- another; recall (unreliable) returns you to your recall site. Surfaced so the model can cross the
  -- world instead of walking when a destination is far.
  local wpn = {}
  for n in pairs(P.waypoints or {}) do wpn[#wpn + 1] = n end
  if #wpn > 0 then
    table.sort(wpn)
    local wl = {}
    for _, n in ipairs(wpn) do
      local w = P.waypoints[n]
      wl[#wl + 1] = "  " .. n .. " - " .. w.name .. (w.reachable and "" or " (out of range"
        .. (w.bridge and (", bridge via " .. w.bridge) or "") .. ")")
    end
    lines[#lines + 1] = "Waypoints you can travel between (command 'waypoint <n>' from a waypoint room):\n"
      .. table.concat(wl, "\n")
  end
  return table.concat(lines, "\n")
end

-- ---- memories (model-written durable notes) ------------------------------------------------
local function remember(text)
  text = trim(text)
  if text == "" then return end
  local low = text:lower()
  for _, m in ipairs(P.memories) do if m.text:lower() == low then return end end -- dedup
  P.memories[#P.memories + 1] = { text = text, area = state and state.area, room = P.current_room }
  while #P.memories > 120 do table.remove(P.memories, 1) end
  echo("[ai] ✎ remembered: " .. text)
  schedule_save()
end

-- Surface notes for the prompt: everything tied to the current area first, then the most recent
-- others, capped so context stays bounded.
local function memory_summary()
  if #P.memories == 0 then return "" end
  local here, other = {}, {}
  local area = state and state.area
  for _, m in ipairs(P.memories) do
    if area and m.area == area then here[#here + 1] = m.text else other[#other + 1] = m.text end
  end
  local lines = {}
  for _, t in ipairs(here) do lines[#lines + 1] = "- " .. t end
  for i = #other, 1, -1 do if #lines >= 15 then break end lines[#lines + 1] = "- " .. other[i] end
  return table.concat(lines, "\n")
end

-- ---- ingest --------------------------------------------------------------------------------
local function arm()
  if not P.enabled then return end
  P.gen = P.gen + 1
  local g = P.gen
  after(cfg.quiet, function() fire_if_ready(g) end)
end

-- A move just failed ("you cannot go that way"): mark that exit a dead end so the auto-router and the
-- map never try it again from this room.
local function block_last_move()
  local d, id = P.last_move_dir, P.current_room
  if d and id and P.rooms[id] then
    P.rooms[id].blocked = P.rooms[id].blocked or {}
    P.rooms[id].blocked[d] = true
    schedule_save()
  end
  P.last_move_dir = nil
  if P.nav then echo("[ai] (route blocked — stopping navigation)"); P.nav = nil; P.nav_cooldown = os.time() + 12; arm() end
end

function pilot_observe(line)
  line = line:gsub("\27%[[%d;]*%a", "")   -- strip ANSI color/escape codes
  local t = trim(line)
  if t:lower():find("cannot go that way", 1, true) then block_last_move() end
  -- Recall bridge: a fizzled recall feeds the recall await's fizzle stream, which retries after a short
  -- delay (a successful recall instead arrives as a room change → roomChangeS, resolving "landed"). No
  -- subscriber when no recall is in flight → dropped.
  if recall_failed(t) and recallFizzleS then recallFizzleS:onNext() end
  -- Learn the fast-travel network as `waypoint` listings scroll by, so `goto`'s hand-off and the AI MAP
  -- block can show real numbers. Session-only (numbers change with decay/reorder) — not persisted.
  local wpe = parse_waypoint_line(t)
  if wpe then P.waypoints = P.waypoints or {}; P.waypoints[wpe.num] = wpe; schedule_save() end
  -- Never feed gagged protocol lines or blanks to the model. kxwt facts reach it once per turn via
  -- the state block (describe_state), not as raw lines.
  if t == "" or t:match("^kxwt_") then return end
  table.insert(P.transcript, t)
  P.input_seq = P.input_seq + 1
  trim_transcript()
  local exits = parse_exits(t)
  if exits and P.current_room then
    P.rooms[P.current_room] = P.rooms[P.current_room] or { exits = {}, moves = {} }
    local r = P.rooms[P.current_room]
    for d in pairs(exits) do if not r.exits[d] then r.exits[d] = true; schedule_save() end end
  end
  arm()
end

function on_user_input(cmd)
  cmd = trim(cmd)
  if cmd == "" or cmd:sub(1, 1) == "#" then return end
  -- Watch for a `waypoint <n>` move (from YOU or our own bridge hop) so the next room change teaches us
  -- which room that number reaches (learn_waypoint). A short-lived marker, auto-cleared if no move
  -- follows within a few seconds (a hop that failed / was out of range). Placed before the self-echo
  -- guard so our own hops reinforce the mapping too.
  local wn = waypoint_cmd_num(cmd)              -- "waypoint 8" or an abbreviation ("way 8", "wayp 8")
  if wn then
    P.wp_pending = wn
    -- Auto-clear the marker if no move follows within a few seconds (a hop that failed / was out of
    -- range). A new waypoint command cancels the prior timer and re-arms, so only the latest is live.
    if cancel and P.wp_timer then cancel(P.wp_timer) end
    P.wp_timer = after(8, function() P.wp_pending = nil end)
  end
  -- Our own AI command echoing back: already logged as [you]; consume the echo and ignore.
  if (P.self_sent[cmd] or 0) > 0 then P.self_sent[cmd] = P.self_sent[cmd] - 1; return end
  if CANON[cmd:lower()] then P.last_move_dir = CANON[cmd:lower()] end   -- so human moves label edges right too
  -- A genuine human command. Capture it as a gold demonstration (context -> the tool you'd want the
  -- model to call), BEFORE adding it to the transcript so the recorded context is what you reacted to.
  if log_human_demo then log_human_demo(cmd) end
  table.insert(P.transcript, "[the human typed] " .. cmd)
  P.input_seq = P.input_seq + 1
  P.last_human = os.time()
  trim_transcript()
end

-- ---- prompt --------------------------------------------------------------------------------
-- The short, plain-text prompt the LoRA was actually FINE-TUNED on (see tools/finetune/parse_capture.py).
-- A fine-tuned model must be run in the format it learned — short prompt, no tools, `CMD:` output — or
-- it goes out-of-distribution and produces garbage. Used when cfg.use_tools is false.
-- TEMPORARY (2026-07-06): swapped to the EXACT compact prompt the 27B-AlterAeon combat fine-tune was
-- trained on (tools/finetune build_combined-short). A fine-tune only behaves as measured when driven
-- with its training prompt; the eval showed the full/old prompts collapse it. Restore the original
-- (commented below) when back on a base/hosted model.
local TEXT_SYS = "You are an expert player of the MUD Alter Aeon, driving a character live. Each turn you "
  .. "receive the character's STATE and recent game OUTPUT. Decide the single best next action and TAKE IT "
  .. "BY CALLING ONE TOOL. ONE action per turn, then wait for the result. Prefer the specific tools "
  .. "(move, attack, cast, get, drop, wear, put, recover, stand, look, inventory, flee); use `command` for "
  .. "anything they don't cover (spells, skills, train, buy, list); use `wait` to do nothing. In combat, "
  .. "attack or cast to deal damage, recover when hurt, flee if losing. ACT, don't talk — your reply must "
  .. "BE a tool call, not a sentence describing it."
-- ORIGINAL (restore when off the fine-tune):
-- local TEXT_SYS = "You are an expert player of the MUD Alter Aeon, driving a character live. Read the "
--   .. "character's STATE and the RECENT GAME OUTPUT, then issue exactly one command on its own line "
--   .. "prefixed with 'CMD:'. Use real Alter Aeon commands and short target keywords. One action per turn."

local function system_prompt()
  if not cfg.use_tools then return TEXT_SYS end
  -- Fold in the game's command reference (defined by the game layer) so the model uses REAL commands
  -- via the `command` tool instead of inventing them. Optional: absent for a game that defines none.
  local ref = ""
  if type(game_command_reference) == "function" then
    local ok, r = pcall(game_command_reference)
    if ok and type(r) == "string" and trim(r) ~= "" then
      ref = "\n\nGAME COMMAND REFERENCE — when no specific tool fits, call the `command` tool with one of these real commands (never invent commands):\n" .. r
    end
  end
  return [[You are an expert player of the MUD Alter Aeon, driving a character live. Each turn you receive the character's STATE, a MAP of what you've explored, your saved NOTES, and recent game OUTPUT. Decide the single best next action and TAKE IT BY CALLING ONE TOOL.

Goal: ]] .. P.goal .. [[

HOW TO ACT:
- ONE action per turn, then wait to see the result before deciding again. Do NOT chain actions. Explore ONE room per turn.
- Prefer the SPECIFIC tools (move, attack, cast, get, drop, wear, put, recover, stand, look, inventory, flee) — they build the exact command for you; you only supply names/keywords. Use `command` ONLY for things no specific tool covers (e.g. spells, skills, train, buy, list, help). Use `wait` to do nothing (e.g. while recovering). Use `remember` to save a durable fact.
- To cross ground you've ALREADY explored, or to head somewhere new, call `navigate` (destination = an area/room name you've visited, a MARKED PLACE label, or "unexplored") — it auto-walks the whole route. Use it instead of stepping move-by-move through familiar rooms, and ESPECIALLY if you notice you're revisiting the same rooms: `navigate("unexplored")` takes you straight to new ground. If the MAP lists MARKED PLACES (rooms the player tagged, e.g. a trainer), `navigate("<label>")` — like `navigate("trainer")` — routes to the nearest one; use this when the goal calls for it (e.g. you have training points to spend).
- ACT, don't talk. Your reply must BE a tool call (or a single `CMD: <command>` line) — NOT a sentence describing what you'll do. "Cast shower of sparks on the siren" is wrong; calling the cast tool with spell="shower of sparks", target="siren" is right. No prose, no explanation — just the call.
- Never invent output you didn't see. If you don't yet know an exact name, call look or inventory this turn and act next turn — never guess.

NAMES & TARGETS:
- Target by a SHORT keyword (the main noun): attack "beast" (not "the large hairy beast"); get "collar" (not "rusty iron collar from the ground").
- cast: give the spell's EXACT full name (e.g. "shower of sparks") — it gets quoted for you. Call command "spells" if unsure. Don't always use the same spell: if a NOTE says one hits hardest, use it; otherwise favor your strongest or area spell — they clear fights faster.

PRIORITIES, in order:
1. If the game explicitly tells you to do something (cast X, type Y, go Z), do exactly that first.
2. Survive & recover. If hurt or low on mana/stamina, `recover` (sleep recovers fastest with no enemy here; rest stays alert), then `wait` turn after turn until STATE shows you are ready, then `stand`. Do NOT move, explore, or fight while recovering. If STATE already shows you sitting or sleeping, do NOT recover again — just wait.
3. Finish the current room before leaving — if a creature blocks you and the game says to fight it, attack it first.
4. Otherwise pursue the goal: fight easy MONSTERS, explore. Only move when healthy.

COMBAT — only attack MONSTERS, named generically like "a goblin", "the large rat" (a/an/the + description). NEVER attack PLAYERS: proper-named characters, often with a class or title, who act on their own. If unsure whether something is a player, do NOT attack it.

CURRENT ROOM & MAP:
- Act ONLY on your CURRENT room (the most recent room text). A "MOVED to a NEW room" line means everything above it is a PAST room — those creatures/items are GONE, never target them. "isn't a valid target" means it isn't here.
- When exploring, prefer exits marked UNEXPLORED. If this room has none, the MAP names the direction toward the nearest unexplored area — move that way instead of wandering. Revisiting an explored room is fine for a reason (good xp, a vendor, a trainer).
- If a move fails ("you cannot go that way"), do NOT repeat it — try something else.

INVENTORY: if the game says you can't carry more, you're OVERLOADED — this turn call inventory ONLY. NEXT turn, once you see the list, drop or put an exact item. Never drop/put before you've seen the list.

SOLO & SILENT: never chat, tell, say, emote, or use channels/newbie/question. Play alone.

WHO DID WHAT: `[you]` lines are YOUR OWN past actions (a new room after `[you] e` means YOU moved there). `[the human typed]` lines are your co-driver's; respect them. Never attribute your own actions to "the human".

NOTES: your saved notes (under "NOTES YOU'VE SAVED") are things you've LEARNED are true — ACT on them. Save new ones with `remember` for durable facts: a trainer/vendor location, which spell hits hardest, a good xp spot and its level, a danger. Keep them specific; don't record transient things. Use `make_script` only for a deterministic reflex you'll repeat all session.]] .. ref
end

local function current_room_slice(limit)
  limit = limit or cfg.context_lines
  local start = 1
  for i = #P.transcript, 1, -1 do
    if P.transcript[i]:find("MOVED to a NEW room", 1, true) then start = i; break end
  end
  -- Rolling window: never send more than cfg.context_lines of recent output, even when we've sat in
  -- one room for many lines (long fights, lots of events). Per-turn prefill is what dominates turn
  -- latency, so bounding the changing block keeps turns fast and predictable. Safe to trim old lines
  -- because the durable room identity lives in the STATE block (room name) and MAP block (exits) —
  -- those are sent every turn regardless. Tune cfg.context_lines for the speed/awareness tradeoff.
  local floor = #P.transcript - limit + 1
  if start < floor then start = floor end
  if start < 1 then start = 1 end
  local lines = {}
  for i = start, #P.transcript do lines[#lines + 1] = P.transcript[i] end
  return table.concat(lines, "\n")
end

local function build_user(st, expl, mem, world, convo, directive, nudge, fighting)
  local world_block = (world and world ~= "") and ("\n=== WHAT'S HERE (current room & you) ===\n" .. world .. "\n") or ""
  local map_block = (expl ~= "") and ("\n=== MAP / WHAT YOU KNOW ===\n" .. expl .. "\n") or ""
  local mem_block = (mem ~= "") and ("\n=== NOTES YOU'VE SAVED ===\n" .. mem .. "\n") or ""
  local manual_block = (cfg.use_rag and P.manual ~= "")
    and ("\n=== RELEVANT GAME MANUAL (retrieved from the docs for THIS situation — rely on it) ===\n" .. P.manual .. "\n") or ""
  -- A DIRECTOR NOTE is from the human and must be obeyed. An AUTO NOTE is generated by the client
  -- (e.g. a loop-break hint) — keep them clearly distinct so the model never says "the human told
  -- me" about an automatic nudge it was never given.
  local dir_block = directive and ("\n=== DIRECTOR NOTE (the human just told you this — act on it now) ===\n" .. directive .. "\n") or ""
  local nudge_block = nudge and ("\n=== AUTO NOTE (generated by the game client, NOT from the human) ===\n" .. nudge .. "\n") or ""
  -- The combat closer is IDENTICAL for both paths: it's the exact string the local combat fine-tune was
  -- trained on ("call attack or cast NOW. No reasoning."), so the local path stays in-distribution and
  -- emits the compact JSON action it learned (parsed by handle_reply). The hosted tool path already used
  -- this closer, so it's unchanged. Only the NON-combat closer differs (tools vs CMD: text).
  local closer
  if fighting then
    closer = "You are IN COMBAT — call attack or cast NOW. No reasoning."
  elseif cfg.use_tools then
    closer = "Decide the single best next action and call ONE tool. Call it directly — no preamble, no restating the situation."
  else
    closer = "Decide the single best next action. Reply with one line: CMD: <command>. Nothing else."
  end
  return "=== CHARACTER STATE ===\n" .. st .. world_block .. map_block .. mem_block .. manual_block .. "\n=== RECENT GAME OUTPUT ===\n" .. convo .. "\n" .. dir_block .. nudge_block .. "\n" .. closer
end

-- ---- known-spell combat helpers ------------------------------------------------------------
-- state.spells_known (filled by AlterAeon's `spells` parse) lists the character's spells, each tagged
-- offensive?/mana/tier. These turn that into (1) a compact prompt line naming the character's REAL damage
-- spells strongest-first — the fix for the model meleeing or hallucinating `cast fireball` because it was
-- never told which spells the character HAS — and (2) a safety net that rewrites a melee/unknown attack
-- into a real known damage spell for a caster.
local DMG_TIER = { minor = 1, low = 2, moderate = 3, high = 4, massive = 5 }

-- Known OFFENSIVE spells, strongest-first (higher damage tier first; cheaper mana breaks ties).
local function damage_spells_ranked(known)
  local list = {}
  for _, s in ipairs(known or {}) do if s.offensive then list[#list + 1] = s end end
  table.sort(list, function(a, b)
    local ta, tb = DMG_TIER[a.tier or ""] or 0, DMG_TIER[b.tier or ""] or 0
    if ta ~= tb then return ta > tb end
    return (a.mana or 0) < (b.mana or 0)
  end)
  return list
end

-- The prompt line naming the character's real damage spells (top `limit`, strongest-first). nil when the
-- character knows none (not a caster), so the line is simply omitted.
local function combat_spell_line(known, limit)
  local ranked = damage_spells_ranked(known)
  if #ranked == 0 then return nil end
  local names = {}
  for i = 1, math.min(#ranked, limit or 6) do names[#names + 1] = ranked[i].name end
  return "YOUR DAMAGE SPELLS (cast one, exact name): " .. table.concat(names, ", ")
end

-- Best known damage spell the character can afford (highest tier with mana <= cur_mana); if none is
-- affordable, the cheapest known damage spell (a stretch beats a melee whiff). nil for a non-caster.
local function best_damage_spell(known, cur_mana)
  local ranked = damage_spells_ranked(known)
  if #ranked == 0 then return nil end
  for _, s in ipairs(ranked) do if (s.mana or 0) <= (cur_mana or 0) then return s end end
  local cheapest = ranked[1]
  for _, s in ipairs(ranked) do if (s.mana or 1e9) < (cheapest.mana or 1e9) then cheapest = s end end
  return cheapest
end

-- Does `rest` (the text after `cast`) name a spell the character KNOWS? Handles the quoted 'spell name'
-- and the unquoted "spell name [target]" form (known name as a prefix). Used to leave a valid cast alone.
local function names_known_spell(rest, known)
  local r = trim((rest or ""):lower())
  local q = r:match("^'([^']+)'")
  if q then r = q end
  for _, s in ipairs(known or {}) do
    local n = s.name:lower()
    if r == n or r:sub(1, #n + 1) == n .. " " then return true end
  end
  return false
end

-- Pull the target keyword from a combat command so a substituted cast keeps hitting the same thing:
-- "kill orc bachelor" -> "orc bachelor"; "cast X on siren" -> "siren"; "cast 'X' orc" -> "orc". Empty
-- when none is parseable — in combat an untargeted attack spell hits your current fight, so "" is safe.
local function combat_target(cmd)
  local on = (cmd or ""):match("%s+on%s+(.+)$")
  if on then return trim(on) end
  local verb = ((cmd or ""):match("^(%S+)") or ""):lower()
  if verb == "kill" or verb == "attack" or verb == "k" then
    return trim((cmd:match("^%S+%s+(.+)$")) or "")
  end
  local q = (cmd or ""):match("^%S+%s+'[^']+'%s+(.+)$")
  return q and trim(q) or ""
end

-- Safety net: turn the model's "deal damage" intent into the character's REAL spell. If the command is a
-- melee attack (kill/attack) or a `cast` of a spell the character does NOT know, and the character is a
-- CASTER (knows >=1 damage spell), rewrite it to `cast '<best affordable known damage spell>' <target>`.
-- A valid known cast (offensive OR utility) is left exactly as-is; a non-caster's command is never touched.
local function combat_substitute(cmd, known, cur_mana)
  if type(cmd) ~= "string" then return cmd end
  if #damage_spells_ranked(known) == 0 then return cmd end   -- non-caster: never rewrite
  local verb = (cmd:match("^(%S+)") or ""):lower()
  local is_melee = (verb == "kill" or verb == "attack" or verb == "k")
  local rest = cmd:match("^%S+%s+(.+)$")
  if verb == "cast" or verb == "c" then
    if rest and names_known_spell(rest, known) then return cmd end   -- valid known cast: leave alone
  elseif not is_melee then
    return cmd                                                        -- not an attack: leave alone
  end
  local best = best_damage_spell(known, cur_mana)
  if not best then return cmd end
  local tgt = combat_target(cmd)
  return "cast '" .. best.name .. "'" .. (tgt ~= "" and (" " .. tgt) or "")
end

-- Lean prompt for a LOCAL combat turn: state + what's here + a short output window + the combat closer.
-- The MAP / saved NOTES / RAG manual are dropped — a combat decision keys off STATE (hp/mana/target),
-- and the local model has NO prompt caching, so every dropped line is prefill the turn no longer pays
-- for. Measured ~30% faster first token vs the full prompt. Hosted models keep the full (cached) prompt;
-- this is only used on the fine-tune's combat path. A director note still rides along (you can steer).
-- A one-line roster of the character's real damage spells rides along so the model casts what it HAS
-- instead of meleeing or inventing a spell (a few tokens; keeps the prompt lean).
local function build_combat_user(st, world, convo, directive)
  local world_block = (world and world ~= "") and ("\n=== WHAT'S HERE ===\n" .. world .. "\n") or ""
  local dir_block = directive and ("\n=== DIRECTOR NOTE (act on it now) ===\n" .. directive .. "\n") or ""
  local spell_line = combat_spell_line(state.spells_known)
  local spell_block = spell_line and ("\n" .. spell_line) or ""
  return "=== CHARACTER STATE ===\n" .. st .. world_block ..
    "\n=== RECENT GAME OUTPUT ===\n" .. convo .. "\n" .. dir_block .. spell_block ..
    "\nYou are IN COMBAT — call attack or cast NOW. No reasoning."
end

-- ---- trace logging (JSONL for fine-tuning) -------------------------------------------------
local function json_escape(s)
  return (s:gsub('[%z\1-\31\\"]', function(c)
    local m = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
    return m[c] or string.format('\\u%04x', string.byte(c))
  end))
end
local function log_trace(sys, user, reply)
  if not P.trace then return end
  local f = io.open(cfg.trace_file, "a")
  if not f then return end
  local function msg(role, c) return '{"role":"' .. role .. '","content":"' .. json_escape(c) .. '"}' end
  f:write('{"messages":[' .. msg("system", sys) .. ',' .. msg("user", user) .. ',' .. msg("assistant", reply) .. ']}\n')
  f:close()
end

-- ---- minimal JSON (for tool calling) -------------------------------------------------------
-- Just enough to (a) emit the tool definitions we send and (b) decode the model's tool-call
-- arguments. Lua has no built-in JSON; the model's args are flat objects so this stays small.
local json = {}
function json.encode(v)
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return tostring(v)
  elseif t == "number" then return tostring(v)
  elseif t == "string" then return '"' .. json_escape(v) .. '"'
  elseif t == "table" then
    local n = 0; for _ in pairs(v) do n = n + 1 end
    if n == 0 then return "{}" end                 -- empty => object (our only empty tables are schemas)
    if #v == n then                                -- dense 1..n keys => array
      local parts = {}
      for _, x in ipairs(v) do parts[#parts + 1] = json.encode(x) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, x in pairs(v) do parts[#parts + 1] = '"' .. json_escape(tostring(k)) .. '":' .. json.encode(x) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

function json.decode(s)
  if type(s) ~= "string" then return nil end
  local i = 1
  local parse_value
  local function skip() while i <= #s and s:sub(i, i):match("%s") do i = i + 1 end end
  local function parse_string()
    i = i + 1
    local buf = {}
    while i <= #s do
      local c = s:sub(i, i)
      if c == '"' then i = i + 1; return table.concat(buf)
      elseif c == "\\" then
        local n = s:sub(i + 1, i + 1)
        if n == "u" then
          local code = tonumber(s:sub(i + 2, i + 5), 16) or 0; i = i + 6
          if code < 0x80 then buf[#buf + 1] = string.char(code)
          elseif code < 0x800 then buf[#buf + 1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
          else buf[#buf + 1] = string.char(0xE0 + math.floor(code / 0x1000), 0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40) end
        else
          local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
          buf[#buf + 1] = map[n] or n; i = i + 2
        end
      else buf[#buf + 1] = c; i = i + 1 end
    end
    return table.concat(buf)
  end
  local function parse_object()
    i = i + 1; local obj = {}; skip()
    if s:sub(i, i) == "}" then i = i + 1; return obj end
    while true do
      skip(); local key = parse_string(); skip(); i = i + 1   -- skip ':'
      skip(); obj[key] = parse_value(); skip()
      local c = s:sub(i, i); i = i + 1
      if c == "}" or c ~= "," then break end
    end
    return obj
  end
  local function parse_array()
    i = i + 1; local arr = {}; skip()
    if s:sub(i, i) == "]" then i = i + 1; return arr end
    while true do
      skip(); arr[#arr + 1] = parse_value(); skip()
      local c = s:sub(i, i); i = i + 1
      if c == "]" or c ~= "," then break end
    end
    return arr
  end
  parse_value = function()
    skip()
    local c = s:sub(i, i)
    if c == '"' then return parse_string()
    elseif c == "{" then return parse_object()
    elseif c == "[" then return parse_array()
    elseif c == "t" then i = i + 4; return true
    elseif c == "f" then i = i + 5; return false
    elseif c == "n" then i = i + 4; return nil
    else
      local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
      if num and #num > 0 then i = i + #num; return tonumber(num) end
      i = i + 1; return nil
    end
  end
  local ok, result = pcall(parse_value)
  if ok then return result end
  return nil
end

-- ---- tool calling --------------------------------------------------------------------------
-- The model picks a STRUCTURED action; we build the exact mud command from its slots. This stops
-- syntax garbling (multi-word spell names, "get X from the ground", abbreviations). Anything no
-- specific tool covers goes through `command` verbatim, so this stays complete without enumerating
-- every game command.
local DIRECTIONS = { "north", "south", "east", "west", "up", "down",
  "northeast", "northwest", "southeast", "southwest" }
local SETTLE = { rest = true, sleep = true, sit = true, meditate = true, nap = true }
local MOVE = { n = true, s = true, e = true, w = true, u = true, d = true, ne = true, nw = true,
  se = true, sw = true, north = true, south = true, east = true, west = true, up = true, down = true,
  northeast = true, northwest = true, southeast = true, southwest = true }
local function cmd_ends_turn(c)
  local lc = c:lower()
  return SETTLE[lc:match("^(%a+)") or ""] == true or MOVE[lc] == true
end
local function opt(s) return (type(s) == "string" and trim(s) ~= "") and (" " .. trim(s)) or "" end

local TOOLS = {
  { name = "move", ends_turn = true,
    desc = "Move one step through an exit. This is your whole turn — see the new room before moving again.",
    props = { direction = { type = "string", enum = DIRECTIONS, description = "which exit to take" } },
    required = { "direction" },
    build = function(a) return a.direction end },
  { name = "navigate", ends_turn = true, nav = true,
    desc = "Auto-walk a whole route across rooms you've ALREADY explored. Give an area or room name "
      .. "(e.g. 'the cemetery', 'town hall'), or 'unexplored' to head to the nearest place with "
      .. "unexplored exits. Use this instead of stepping one direction at a time when crossing known "
      .. "ground or when you feel stuck — the script walks the route and stops if combat starts.",
    props = { destination = { type = "string", description = "area/room name you've visited, or 'unexplored'" } },
    required = { "destination" } },
  { name = "attack",
    desc = "Start attacking a MONSTER in this room (never another player).",
    props = { target = { type = "string", description = "short keyword for the creature, e.g. 'goblin'" } },
    required = { "target" },
    build = function(a) return "kill " .. a.target end },
  { name = "cast",
    desc = "Cast a spell. Give the spell's exact full name; a target keyword if it needs one. Cast an attack spell only when there's an enemy (in combat, target is optional — it hits what you're fighting).",
    props = { spell = { type = "string", description = "exact full spell name, e.g. 'shower of sparks'" },
              target = { type = "string", description = "optional target keyword" } },
    required = { "spell" },
    build = function(a) return "cast '" .. trim(a.spell) .. "'" .. opt(a.target) end },
  { name = "get",
    desc = "Pick up an item from the room or a container.",
    props = { item = { type = "string", description = "short keyword for the item" },
              container = { type = "string", description = "optional container to take it from" } },
    required = { "item" },
    build = function(a) return "get " .. a.item .. opt(a.container) end },
  { name = "put",
    desc = "Put an item into a container/bag.",
    props = { item = { type = "string" }, container = { type = "string" } },
    required = { "item", "container" },
    build = function(a) return "put " .. a.item .. " in " .. a.container end },
  { name = "drop",
    desc = "Drop an item you are carrying.",
    props = { item = { type = "string" } }, required = { "item" },
    build = function(a) return "drop " .. a.item end },
  { name = "wear",
    desc = "Wear or wield a piece of equipment.",
    props = { item = { type = "string" } }, required = { "item" },
    build = function(a) return "wear " .. a.item end },
  { name = "recover", ends_turn = true,
    desc = "Rest or sleep to recover hp/mana/stamina (only when no enemy is here). This is your whole turn; then wait.",
    props = { method = { type = "string", enum = { "rest", "sleep" }, description = "sleep recovers fastest; rest stays alert" } },
    required = { "method" },
    build = function(a) return a.method end },
  { name = "stand",
    desc = "Stand up after resting/sleeping, once your state shows you are recovered.",
    props = {}, build = function() return "stand" end },
  { name = "look",
    desc = "Look at the current room, or at a specific thing.",
    props = { at = { type = "string", description = "optional thing to look at" } },
    build = function(a) return "look" .. opt(a.at) end },
  { name = "inventory",
    desc = "List what you are carrying.",
    props = {}, build = function() return "inventory" end },
  { name = "flee", ends_turn = true,
    desc = "Flee from combat.",
    props = {}, build = function() return "flee" end },
  { name = "command",
    desc = "Run any other game command verbatim (spells, skills, help, train, buy, list, etc.). Use ONLY when no specific tool fits.",
    props = { text = { type = "string", description = "the exact command line to send" } },
    required = { "text" },
    build = function(a) return a.text end },
  { name = "wait",
    desc = "Do nothing this turn (e.g. while recovering). No command is sent.",
    props = {}, build = function() return nil end },
  { name = "remember", note = true,
    desc = "Save a durable fact worth keeping all session (trainer/vendor location, which spell hits hardest, a good xp spot + level, a danger).",
    props = { fact = { type = "string" } }, required = { "fact" } },
  { name = "make_script", note = true,
    desc = "Request a PERMANENT reflex you'll repeat all session (e.g. 'loot every corpse', 'flee under 30% hp'). Rare.",
    props = { description = { type = "string" } }, required = { "description" } },
}
local TOOL_BY_NAME = {}
for _, t in ipairs(TOOLS) do TOOL_BY_NAME[t.name] = t end

local tools_json_cache
local function tools_json()
  if tools_json_cache then return tools_json_cache end
  local arr = {}
  for _, t in ipairs(TOOLS) do
    local params = { type = "object", properties = t.props or {} }
    if t.required then params.required = t.required end
    arr[#arr + 1] = { type = "function",
      ["function"] = { name = t.name, description = t.desc, parameters = params } }
  end
  tools_json_cache = json.encode(arr)
  return tools_json_cache
end

-- Turn decoded tool calls into actions ({ cmd, ends_turn }) plus any notes/script requests.
local function from_tool_calls(calls)
  local actions, mems, scripts = {}, {}, {}
  for _, call in ipairs(calls) do
    local args = (type(call.args) == "table") and call.args or {}
    if call.name == "remember" then
      if type(args.fact) == "string" then mems[#mems + 1] = args.fact end
    elseif call.name == "make_script" then
      if type(args.description) == "string" then scripts[#scripts + 1] = args.description end
    elseif call.name == "navigate" then
      actions[#actions + 1] = { nav = (type(args.destination) == "string") and args.destination or "", ends_turn = true }
    else
      local spec = TOOL_BY_NAME[call.name]
      if spec then
        local ok, cmd = pcall(spec.build, args)
        if ok then
          local ends = spec.ends_turn or (type(cmd) == "string" and cmd_ends_turn(cmd)) or false
          actions[#actions + 1] = { cmd = cmd, ends_turn = ends }
        end
      end
    end
  end
  return actions, mems, scripts
end

-- Reverse of the tools: classify a raw command (e.g. one the HUMAN typed) into the structured tool
-- the model should have called, so human play becomes clean tool-call demonstrations. Anything that
-- doesn't map cleanly falls back to the verbatim `command` tool (still a valid demonstration).
local function tool_call_for(cmd)
  local orig = trim(cmd)
  local lc = orig:lower()
  if CANON[lc] then return "move", { direction = CANON[lc] } end
  local verb = (orig:match("^(%S+)") or ""):lower()
  local sp = orig:find("%s")
  local rest = sp and trim(orig:sub(sp)) or ""
  if (verb == "kill" or verb == "k" or verb == "attack") and rest ~= "" then return "attack", { target = rest }
  elseif verb == "get" and rest ~= "" then return "get", { item = rest }
  elseif verb == "drop" and rest ~= "" then return "drop", { item = rest }
  elseif (verb == "wear" or verb == "wield" or verb == "use") and rest ~= "" then return "wear", { item = rest }
  elseif verb == "rest" or verb == "sleep" then return "recover", { method = verb }
  elseif verb == "stand" or verb == "wake" then return "stand", {}
  elseif verb == "inventory" or verb == "inv" or verb == "i" then return "inventory", {}
  elseif verb == "flee" or verb == "run" then return "flee", {}
  elseif (verb == "look" or verb == "l") and rest == "" then return "look", {}
  elseif verb == "cast" or verb == "c" then
    local spell, tgt = orig:match("'([^']+)'%s*(.*)$")   -- only the unambiguous quoted form
    if spell then
      tgt = trim(tgt or "")
      return "cast", (tgt ~= "" and { spell = spell, target = tgt } or { spell = spell })
    end
  end
  return "command", { text = orig }
end

-- ---- script-change requests ----------------------------------------------------------------
local function request_script_change(req)
  local key = trim(req):lower()
  if P.requested[key] then return end
  P.requested[key] = true
  local f = io.open(cfg.dir .. "/.ai-script-requests.jsonl", "a")
  if f then f:write('{"request":"' .. json_escape(req) .. '"}\n'); f:close() end
  echo("[ai] ✎ requested a script change: \"" .. req .. "\" (queued; edit a script + pilot.reload() to apply)")
end

-- ---- reply handling ------------------------------------------------------------------------
local function strip_fences(s)
  s = s:gsub("^[%s`*]+", ""):gsub("[%s`*]+$", "")
  s = s:gsub("%.+$", "")
  return (s:gsub("^[%s`*]+", ""):gsub("[%s`*]+$", ""))
end

-- Shared tail for both the tool-call path and the text fallback. `actions` is a list of
-- { cmd = <string|nil>, ends_turn = <bool> }; thoughts/scripts/mems are plain strings.
function execute(actions, thoughts, scripts, mems)
  if #thoughts > 0 then echo("[ai] " .. table.concat(thoughts, " ")) end
  for i = 1, math.min(2, #mems) do remember(mems[i]) end   -- at most two new notes per turn
  if scripts[1] then request_script_change(scripts[1]) end

  -- A navigate request takes over the turn: the script walks the BFS route (see start_navigation).
  for _, a in ipairs(actions) do
    if a.nav ~= nil then
      if P.enabled then start_navigation(a.nav) end
      return
    end
  end

  while #actions > cfg.max_cmds do table.remove(actions) end

  -- A move OR a recovery command is the WHOLE turn: drop anything chained after it. This forces
  -- one-room-at-a-time exploration (observe each room before the next move) and stops
  -- contradictions like `rest` then `east` or `south` then `west`.
  for i, a in ipairs(actions) do
    if a.ends_turn then
      for j = #actions, i + 1, -1 do table.remove(actions, j) end
      break
    end
  end

  -- Collect the commands actually sent (skip `wait`/no-op tools). In combat, run each through the
  -- known-spell substitution: a caster that the model told to melee (or to cast a spell it doesn't have)
  -- gets rewritten to its best affordable REAL damage spell. A valid known cast / non-caster is untouched.
  local commands = {}
  for _, a in ipairs(actions) do
    if type(a.cmd) == "string" and trim(a.cmd) ~= "" then
      local cmd = a.cmd
      if in_combat() then
        local sub = combat_substitute(cmd, state.spells_known, state.mana)
        if sub ~= cmd then echo("[ai] (cast real spell: `" .. cmd .. "` -> `" .. sub .. "`)"); cmd = sub end
      end
      commands[#commands + 1] = cmd
    end
  end

  -- Loop detection: only meaningful when a command repeats AND nothing changes. We already reset the
  -- counter on every room change (in pilot_room_change), so successful movement never trips it —
  -- "north" through 20 new rooms is fine. SKIP it in combat (repeating your best spell is correct),
  -- and when it does fire just NUDGE once; never disarm — a legit same-room repeat (shopping, training)
  -- shouldn't get the AI shut off.
  local loop_cmd, looping = nil, false
  if in_combat() then
    P.recent_cmds = {}
  else
    for _, c in ipairs(commands) do
      if P.recent_cmds[#P.recent_cmds] == c then P.recent_cmds[#P.recent_cmds + 1] = c
      else P.recent_cmds = { c } end
    end
    loop_cmd = P.recent_cmds[#P.recent_cmds]
    looping = #P.recent_cmds >= cfg.loop_threshold
    if looping then
      P.recent_cmds = {}
      P.nudge = "You've sent `" .. loop_cmd .. "` " .. cfg.loop_threshold ..
        " times and nothing in the room is changing — if it isn't accomplishing anything, do something different."
    end
  end

  if #commands == 0 then echo("[ai] (no command this turn)"); return end
  if looping then
    echo("[ai] (repeated `" .. loop_cmd .. "` " .. cfg.loop_threshold .. "× with no change — letting it reconsider)")
    arm(); return
  end
  if not P.enabled then echo("[ai] (disengaged mid-turn — withheld)"); return end

  for _, c in ipairs(commands) do
    echo("[ai] > " .. c)
    table.insert(P.transcript, "[you] " .. c)
    P.input_seq = P.input_seq + 1
    trim_transcript()
    -- `send` loops back through the user-input observer; remember it so on_user_input doesn't
    -- re-log our own command as if the human typed it (and doesn't capture it as a demonstration).
    P.self_sent[c] = (P.self_sent[c] or 0) + 1
    local cdir = CANON[c:lower()]
    if cdir then P.last_move_dir = cdir end   -- so a "cannot go that way" can mark it a dead end
    send(c)
  end
end

-- ---- fine-tune JSON action parsing ---------------------------------------------------------
-- The local combat fine-tune replies with a JSON action, NOT `CMD:` text. It emits it two ways:
--   * the trained tool-call: {"name":"command","arguments":{"text":"c shower"}}  (sometimes wrapped in
--     Qwen <tool_call>…</tool_call> tags), and
--   * a flattened shorthand it generalized to: {"action":"attack","target":"town guard"} /
--     {"action":"cast","target":"shower of sparks"}.
-- Both must resolve to a REAL game command through the same TOOL build path the hosted models use.
-- Generic-value key each tool's flattened form routes into (no-arg tools like flee/stand are absent).
local PRIMARY_ARG = {
  move = "direction", attack = "target", cast = "spell", get = "item", put = "item",
  drop = "item", wear = "item", recover = "method", look = "at", command = "text",
  remember = "fact", make_script = "description", navigate = "destination",
}

-- Turn ONE decoded object into a { name, args } tool call from_tool_calls understands, or nil if it
-- can't be understood (never fabricate a command). Handles the proper `arguments` shape and the
-- flattened `{action,target}` shorthand — routing a single generic value to the tool's primary arg so
-- we never emit a duplicate (e.g. cast 'X' X).
local function normalize_call(obj)
  if type(obj) ~= "table" then return nil end
  local name = obj.name or obj.action or obj.call or obj.tool or obj.function_name
  if type(name) ~= "string" or trim(name) == "" then return nil end
  name = trim(name):lower()
  if name == "kill" then name = "attack" end
  -- Proper OpenAI/Qwen shape: `arguments` is (or JSON-decodes to) the args table — pass it straight on.
  local args = obj.arguments or obj.args or obj.parameters
  if type(args) == "string" then local ok, d = pcall(json.decode, args); if ok then args = d end end
  if type(args) == "table" then return { name = name, args = args } end
  -- Flattened shorthand: pull the single value the model supplied and route it to the tool's primary arg.
  local pk = PRIMARY_ARG[name]
  if pk == nil then return { name = name, args = {} } end   -- no-arg tool (flee/stand/look/inventory/wait)
  local generic = obj.text or obj.spell or obj.target or obj.direction or obj.item
                  or obj.destination or obj.method or obj.at or obj.fact or obj.value or obj.arg
  if generic ~= nil then return { name = name, args = { [pk] = generic } } end
  return nil   -- an arg was required and none was present — skip safely rather than send garbage
end

-- Pull every action object out of a raw reply: <tool_call>…</tool_call> blocks first (Qwen format),
-- else brace-balanced bare JSON objects. Returns a (possibly empty) list of normalized calls.
local function extract_calls(reply)
  if type(reply) ~= "string" then return {} end
  local objs, found = {}, false
  for block in reply:gmatch("<tool_call>(.-)</tool_call>") do
    found = true
    local ok, o = pcall(json.decode, trim(block)); if ok then objs[#objs + 1] = o end
  end
  if not found then
    local i, n = 1, #reply
    while true do
      local a = reply:find("{", i, true); if not a then break end
      local depth, b, instr, esc = 0, nil, false, false
      for j = a, n do
        local ch = reply:sub(j, j)
        if instr then
          if esc then esc = false elseif ch == "\\" then esc = true elseif ch == '"' then instr = false end
        elseif ch == '"' then instr = true
        elseif ch == "{" then depth = depth + 1
        elseif ch == "}" then depth = depth - 1; if depth == 0 then b = j; break end end
      end
      if not b then break end
      local ok, o = pcall(json.decode, reply:sub(a, b)); if ok then objs[#objs + 1] = o end
      i = b + 1
    end
  end
  local calls = {}
  for _, o in ipairs(objs) do local c = normalize_call(o); if c then calls[#calls + 1] = c end end
  return calls
end

-- Text fallback: first try the fine-tune's JSON action(s); otherwise parse CMD:/SCRIPT:/REMEMBER: lines.
-- Used when the model answers with content instead of native API tool_calls (the local path always does).
function handle_reply(reply)
  reply = reply or ""
  local calls = extract_calls(reply)
  if #calls > 0 then
    local actions, mems, scripts = from_tool_calls(calls)
    execute(actions, {}, scripts, mems)
    return
  end
  local actions, thoughts, scripts, mems = {}, {}, {}, {}
  for line in reply:gmatch("[^\n]+") do
    local t = trim(line)
    local sreq = t:match("^[Ss][Cc][Rr][Ii][Pp][Tt]%s*:?%s*(.+)")
    local mreq = t:match("^[Rr][Ee][Mm][Ee][Mm][Bb][Ee][Rr]%s*:?%s*(.+)")
    local cmd = t:match("^[Cc][Mm][Dd]%s*:?%s*(.+)") or t:match("^>%s*(.+)")
    if sreq then scripts[#scripts + 1] = sreq
    elseif mreq then mems[#mems + 1] = mreq
    elseif cmd then cmd = strip_fences(cmd); if cmd ~= "" then actions[#actions + 1] = { cmd = cmd, ends_turn = cmd_ends_turn(cmd) } end
    elseif t ~= "" then thoughts[#thoughts + 1] = t end
  end
  execute(actions, thoughts, scripts, mems)
end

-- ---- memory head ---------------------------------------------------------------------------
-- A separate model maintains structured world state from raw output. This directly attacks the
-- "long-context hallucination" failure mode (the decision model reads facts, not scrolling text).
local MEM_SYS = "You maintain compact structured state for an autonomous text-MUD player. You are "
  .. "given the CURRENT state (JSON) and the most recent raw game output. Return the UPDATED state as "
  .. "a single JSON object, nothing else, with keys: creatures_here (array of short keywords for "
  .. "monsters/NPCs present in the CURRENT room right now), items_here (array of short keywords for "
  .. "items on the ground here), inventory (array of items the player is carrying, only if the output "
  .. "shows it; else keep the prior value), summary (one or two short sentences: what just happened "
  .. "and the immediate objective). Rules: use SHORT keywords (the main noun) — 'kobold', not 'a thin "
  .. "kobold standing here'. If the player MOVED to a new room, the previous room's creatures/items "
  .. "are gone — reset them to what the new room shows. Never invent things not in the output. Output "
  .. "ONLY the JSON object."

-- Pull the first {...} JSON object out of a possibly fenced/prefixed reply.
local function extract_json(s)
  if type(s) ~= "string" then return nil end
  local a = s:find("{", 1, true); if not a then return nil end
  local b = s:find("}[^}]*$"); if not b then b = #s end
  return json.decode(s:sub(a, b))
end

local function as_strings(v)
  local out = {}
  if type(v) == "table" then for _, x in ipairs(v) do if type(x) == "string" and trim(x) ~= "" then out[#out + 1] = trim(x) end end end
  return out
end

-- Refresh P.world from recent output, then call done(). On error/missing key, fail gracefully:
-- disable memory after a couple of failures so it never spams or blocks the turn.
local function run_memory_head(done)
  if not cfg.use_memory then return done() end
  local user = "CURRENT STATE:\n" .. json.encode(P.world) .. "\n\nRECENT GAME OUTPUT:\n" .. current_room_slice()
  ai_memory_request(MEM_SYS, user, 400, function(reply, err)
    if EPOCH ~= _AIP.epoch then return end
    if err then
      P.mem_fail = P.mem_fail + 1
      echo("[ai] (memory head error: " .. err .. ")")
      if P.mem_fail >= 2 then cfg.use_memory = false
        echo("[ai] memory head disabled — set ANTHROPIC_API_KEY or pilot.memkey('<key>'), then pilot.mem('on').") end
    else
      P.mem_fail = 0
      local t = extract_json(reply)
      if type(t) == "table" then
        P.world.creatures = as_strings(t.creatures_here)
        P.world.items = as_strings(t.items_here)
        local inv = as_strings(t.inventory)
        if #inv > 0 then P.world.inventory = inv end
        if type(t.summary) == "string" then P.world.summary = trim(t.summary) end
      end
    end
    P.world.room_id = P.current_room
    done()
  end)
end

local function world_summary()
  if not cfg.use_memory then return "" end
  local w, lines = P.world, {}
  if #w.creatures > 0 then lines[#lines + 1] = "Creatures here: " .. table.concat(w.creatures, ", ") end
  if #w.items > 0 then lines[#lines + 1] = "Items here: " .. table.concat(w.items, ", ") end
  if #w.inventory > 0 then lines[#lines + 1] = "Carrying: " .. table.concat(w.inventory, ", ") end
  if w.summary and w.summary ~= "" then lines[#lines + 1] = "Recently: " .. w.summary end
  return table.concat(lines, "\n")
end

-- ---- RAG: relevant game manual on demand ---------------------------------------------------
-- The query is the recent situation + the goal; we retrieve the few doc passages closest to it.
local function rag_query()
  return current_room_slice():sub(-700) .. "\nGoal: " .. P.goal
end
local function format_manual(chunks_json)
  local arr = json.decode(chunks_json)
  if type(arr) ~= "table" or #arr == 0 then return "" end
  local lines = {}
  for _, c in ipairs(arr) do if type(c) == "string" then lines[#lines + 1] = "- " .. c end end
  return table.concat(lines, "\n")
end

-- ---- navigation (the `navigate` tool) ------------------------------------------------------
-- Walk a precomputed BFS route, one step per room-change, with hard safety: it stops on arrival, on
-- combat, on a failed/blocked step, or if a step stalls (watchdog). The route is finite and loop-free,
-- so this can never oscillate like the old forced auto-router.
function nav_step()
  local nav = P.nav
  if not nav then return end
  if in_combat() then echo("[ai] (combat — stopping navigation)"); P.nav = nil; arm(); return end
  if nav.idx > #nav.path then
    echo("[ai] (arrived at " .. nav.dest .. ")"); P.nav = nil; arm(); return
  end
  local dir = nav.path[nav.idx]; nav.idx = nav.idx + 1
  echo("[ai] (navigating to " .. nav.dest .. ": " .. dir .. ")")
  table.insert(P.transcript, "[you] " .. dir); P.input_seq = P.input_seq + 1; trim_transcript()
  P.self_sent[dir] = (P.self_sent[dir] or 0) + 1
  P.last_move_dir = dir
  send(dir)
  -- Watchdog: if no room-change advances us within a few seconds, the step stalled (blocked/closed
  -- door). Abort and hand back to the model. nav.gen invalidates the timer once we DO advance.
  nav.gen = (nav.gen or 0) + 1
  local g = nav.gen
  after(4, function()
    if EPOCH == _AIP.epoch and P.nav and P.nav.gen == g then
      echo("[ai] (navigation stalled — handing back to you)"); P.nav = nil; P.nav_cooldown = os.time() + 12; arm()
    end
  end)
end

function start_navigation(dest)
  -- Cooldown: after a route fails (the auto-built map can have phantom edges), refuse navigation for a
  -- bit so the model explores MANUALLY — which is what actually corrects the map — instead of instantly
  -- re-triggering the same broken route. This is the hard guarantee against a navigate loop.
  if os.time() < (P.nav_cooldown or 0) then
    echo("[ai] (navigation paused — a recent route failed; move manually for a moment)")
    arm(); return
  end
  local d = trim(dest or ""):lower()
  local path, desc
  if d == "" or d == "unexplored" or d == "new" or d == "frontier" or d:find("explore", 1, true) then
    path, desc = path_to_unexplored(), "unexplored ground"
  else
    local matches; matches, desc = resolve_nav(dest); path = find_path(matches)
  end
  if not path or #path == 0 then
    echo("[ai] (no known route to '" .. desc .. "')")
    P.nudge = "There is no known route to '" .. desc .. "' in your explored map — explore toward it by "
      .. "taking unexplored exits, one at a time."
    arm(); return
  end
  echo("[ai] (routing to " .. desc .. " — " .. #path .. " steps)")
  P.nav = { path = path, idx = 1, dest = desc, gen = 0 }
  nav_step()
end

-- `explore` (human alias) — auto-walk to the NEAREST unexplored ground, reusing the stream-driven nav
-- walker: it steps on each room change, stops the moment you enter combat, and aborts if a step stalls
-- (blocked/closed door). `explore stop` cancels. This is the hands-on version of the AI's
-- navigate("unexplored"), minus the pilot's cooldown/turn machinery.
alias([[^explore stop$]], function()
  if P.nav then P.nav = nil; echo("[explore] stopped.") else echo("[explore] not navigating.") end
end)
alias([[^explore$]], function()
  if in_combat() then echo("[explore] not while you're fighting."); return end
  local path = path_to_unexplored()
  if not path or #path == 0 then
    echo("[explore] no reachable unexplored exits — the map you've walked from here is fully explored.")
    return
  end
  echo(string.format("[explore] heading to the nearest unexplored ground (%d step%s) — 'explore stop' to cancel.",
    #path, #path == 1 and "" or "s"))
  P.nav = { path = path, idx = 1, dest = "unexplored ground", gen = 0 }
  nav_step()
end)

-- noexit(dir) — mark a direction OUT OF THE CURRENT ROOM as blocked so `explore` and the pilot's
-- routing never try it, even when the room advertises that exit. The auto-detector only catches "you
-- cannot go that way"; there are many other reasons a real exit isn't traversable (a locked/closed door,
-- a guard that stops you, a one-way passage, a level/quest gate) with as many different messages — so
-- this lets you say so by hand. Per-room, persists with the map (save_map serializes r.blocked), and
-- hides that edge on the minimap. noexit() lists this room's blocks; noexit('clear <dir>') / noexit('-n')
-- unblocks one; noexit('clear') clears them all here. Named `noexit`, NOT `block`, because block/unblock
-- are real AlterAeon commands (player blocking) we must never shadow.
function noexit(args) return noexit_command(args) end
doc(noexit, { name = "noexit", sig = "noexit([dir])", group = "map",
  text = "Block a direction out of the current room so explore()/navigate never route that way — for the "
      .. "locked doors, guards and one-way exits the auto-detector (which only knows \"cannot go that "
      .. "way\") misses. noexit() lists this room's blocks; noexit('clear <dir>') unblocks one; "
      .. "noexit('clear') clears them all here. Per-room, persists with the map, hidden on the minimap.",
  example = "noexit('north')   -- the north door is locked; stop routing through it" })
function noexit_command(args)
  args = trim(args or "")
  local id = P.current_room
  local r = id and P.rooms[id]
  if not r then echo("[noexit] no current room yet — move once so the map knows where you are."); return end
  -- list
  if args == "" then
    local dirs = {}
    for d in pairs(r.blocked or {}) do dirs[#dirs + 1] = d end
    if #dirs == 0 then echo("[noexit] nothing blocked here. `noexit <dir>` blocks a direction (e.g. noexit north).")
    else table.sort(dirs); echo("[noexit] blocked out of " .. (r.name or "this room") .. ": " .. table.concat(dirs, ", ")) end
    return
  end
  -- clear ALL blocks in this room
  local low = args:lower()
  if low == "clear" or low == "reset" or low == "clear all" then
    if r.blocked then r.blocked = nil; schedule_save(); echo("[noexit] cleared every block in " .. (r.name or "this room") .. ".")
    else echo("[noexit] nothing blocked here.") end
    return
  end
  -- unblock ONE:  clear <dir> | unblock <dir> | -<dir>
  local un = args:match("^clear%s+(.+)$") or args:match("^unblock%s+(.+)$") or args:match("^%-%s*(.+)$")
  if un then
    local d = CANON[trim(un):lower()]
    if not d then echo("[noexit] '" .. trim(un) .. "' isn't a direction."); return end
    if r.blocked and r.blocked[d] then
      r.blocked[d] = nil; if not next(r.blocked) then r.blocked = nil end
      schedule_save(); echo("[noexit] unblocked " .. d .. " — explore may route that way again.")
    else echo("[noexit] " .. d .. " wasn't blocked here.") end
    return
  end
  -- block ONE
  local d = CANON[low]
  if not d then echo("[noexit] '" .. args .. "' isn't a direction. Use n/s/e/w/u/d/ne/nw/se/sw (or 'clear <dir>')."); return end
  r.blocked = r.blocked or {}
  if r.blocked[d] then echo("[noexit] " .. d .. " is already blocked here."); return end
  r.blocked[d] = true
  schedule_save()
  echo("[noexit] blocked " .. d .. " out of " .. (r.name or "this room") .. " — explore won't route that way. `noexit clear " .. d .. "` to undo.")
end
-- Game-line aliases so you can type it straight in (like `explore`) — no `#` needed. Safe because
-- `noexit` is not an AlterAeon command (unlike block/unblock, which are).
alias([[^noexit$]], function() noexit_command("") end)
alias([[^noexit (.+)$]], function(_, rest) noexit_command(rest) end)

-- mark(label) tags the CURRENT room with a landmark label (e.g. mark('trainer')) so you can
-- travel('<label>') back to it later and the pilot can navigate('<label>') to it. mark() with no args
-- lists every tagged room; mark('del <label>') (or mark('-<label>')) removes one. Marks persist with
-- the map and show as ★ on the minimap. Multiple labels per room are fine. (The `mark <label>` typed
-- straight into the game line is a separate game alias and still works.)
function mark(label) return mark_command(label) end
doc(mark, { name = "mark", sig = "mark([label])", group = "map",
  text = "Tag the current room with a landmark label; mark() lists all marks; mark('del <label>') removes one. Marks persist with the map, show as ★ on the minimap, and are travel()/navigate() targets." })
function mark_command(args)
  args = trim(args or "")
  if args == "" then
    local s = marks_list()
    if s == "" then echo("[mark] nothing marked yet. Stand in a room and mark('<label>') (e.g. mark('trainer')).")
    else echo("[mark] marked rooms:\n" .. s) end
    return
  end
  local id = P.current_room
  if not id or not P.rooms[id] then
    echo("[mark] no current room yet — move once so the map knows where you are."); return
  end
  local r = P.rooms[id]
  local del = args:match("^del%s+(.+)$") or args:match("^rm%s+(.+)$") or args:match("^%-%s*(.+)$")
  if del then
    del = trim(del):lower()
    if r.marks and r.marks[del] then
      r.marks[del] = nil
      if not next(r.marks) then r.marks = nil end
      schedule_save()
      echo("[mark] removed '" .. del .. "' from " .. (r.name or "this room") .. ".")
    else
      echo("[mark] this room isn't marked '" .. del .. "'.")
    end
    return
  end
  local label = args:lower()
  r.marks = r.marks or {}
  if r.marks[label] then echo("[mark] already marked '" .. label .. "'."); return end
  r.marks[label] = true
  schedule_save()
  echo("[mark] tagged " .. (r.name or "this room") .. (r.area and (" (" .. r.area .. ")") or "")
    .. " as '" .. label .. "'. `goto " .. label .. "` to return.")
end

-- Auto-mark where you DIED so you can `goto death` back for your corpse. Dying teleports you to recall,
-- so we capture the room NOW — the "You have been KILLED" line is processed before the recall
-- room-change overwrites P.current_room. Only the latest death is kept (old "death" marks are cleared
-- first), and it's stored as an ordinary landmark labelled "death", so it persists with the map, shows
-- ★ on the minimap, and rides the existing goto/navigate machinery. `goto death` adds a nearest-point
-- fallback for the common case where the death room's area isn't walkable back to (see human_goto).
function mark_death()
  local id = P.current_room
  local r = id and P.rooms[id]
  if not r or not r.coord then
    -- Can't place this room — keep any PREVIOUS death mark rather than wiping it for nothing.
    echo("\27[1;31m☠ you DIED — but the map hasn't placed this room, so I can't mark it (any earlier "
      .. "death mark is kept).\27[0m")
    return
  end
  -- Drop any previous death mark first, so `goto death` always heads to your MOST RECENT corpse.
  for _, rr in pairs(P.rooms) do
    if rr.marks and rr.marks.death then rr.marks.death = nil; if not next(rr.marks) then rr.marks = nil end end
  end
  r.marks = r.marks or {}
  r.marks.death = true
  schedule_save()
  echo("\27[1;31m☠ you DIED at " .. (r.name or ("room " .. tostring(id)))
    .. (r.area and (" — " .. r.area) or "") .. ". `goto death` to return for your corpse.\27[0m")
end

-- Tunable costs (in walk-step equivalents) for the walk-vs-bridge decision below. Walking is the slow,
-- expensive thing; the waypoint network is cheap — so these are small on purpose and the pilot ends up
-- recall-happy. Kept as locals so a single edit re-tunes both the planner and the live bridge.
--   HOP_COST           — a waypoint hop ≈ this many walk-steps (command latency + landing settle).
--   RECALL_COST        — entering the network by recall (cheap and reliable enough; a couple retries at
--                        worst). Deliberately LOW so recall beats a long walk-to-waypoint entry.
--   BRIDGE_MIN_SAVINGS — hysteresis: only bridge when it saves at least this many steps over walking, so
--                        we don't bridge to shave off a step or two (and don't thrash at the boundary).
local HOP_COST, RECALL_COST, BRIDGE_MIN_SAVINGS = 3, 5, 5

-- Cost (steps) + action to get from `here` onto the waypoint network. Standing on a waypoint is free.
-- Otherwise we PREFER recall (it's cheap) and only walk to a waypoint room when one is strictly closer
-- than a recall — the choice flips exactly at RECALL_COST. Returns (cost, walk_path) where a nil
-- walk_path means "enter by recall".
local function network_entry(here)
  if P.rooms[here] and P.rooms[here].waypoint then return 0, nil end
  local wpath = find_path_from(here, function(id) return id ~= here and P.rooms[id] and P.rooms[id].waypoint end)
  if wpath and #wpath > 0 and #wpath < RECALL_COST then return #wpath, wpath end
  return RECALL_COST, nil
end

-- Estimated cost of bridging from `here` to `label` via waypoint room `target_wp`, or nil when that
-- bridge can't actually complete — no target, its hop NUMBER is unknown (we'd stall mid-bridge asking for
-- a number), or the final leg wp→mark isn't walkable. Never estimate a bridge we couldn't finish.
-- Returns a table { cost, entry_cost, entry_path, final_leg }.
local function bridge_estimate(here, label, target_wp)
  if not target_wp or not waypoint_num_for_room(target_wp) then return nil end
  local final_leg
  if has_mark(P.rooms[target_wp], label) then
    final_leg = 0
  else
    local fpath = find_path_from(target_wp, function(id) return id ~= target_wp and has_mark(P.rooms[id], label) end)
    if not fpath then return nil end
    final_leg = #fpath
  end
  local entry_cost, entry_path = network_entry(here)
  return { cost = entry_cost + HOP_COST + final_leg, entry_cost = entry_cost,
           entry_path = entry_path, final_leg = final_leg }
end

-- PURE decision helper for `goto <mark>`: compare walking the whole way against bridging via the waypoint
-- network, and return which is cheaper. No side effects (no send/echo) so it's spec-testable. Returns:
--   { mode = "walk",   path = <dirs>, walk_cost = n }
--   { mode = "bridge", target_wp = id, walk_cost = n|math.huge, bridge_cost = n,
--                      entry_cost = n, entry_path = <dirs>|nil, final_leg = n }
--   { mode = "none",   reason = "unmarked" | "unreachable" }
-- Rule: bridge iff a completable bridge exists AND bridge_cost + BRIDGE_MIN_SAVINGS < walk_cost; else
-- walk if a walk path exists; else bridge if one's possible at all (today's unwalkable fallback); else
-- report why nothing works.
local function plan_goto_route(label)
  local here = P.current_room
  local walk_path = find_path_from(here, function(id) return id ~= here and has_mark(P.rooms[id], label) end)
  local walk_cost = (walk_path and #walk_path > 0) and #walk_path or math.huge

  local target_wp = nearest_waypoint_for(label)
  local be = bridge_estimate(here, label, target_wp)
  local function bridge_result()
    return { mode = "bridge", target_wp = target_wp, walk_cost = walk_cost, bridge_cost = be.cost,
             entry_cost = be.entry_cost, entry_path = be.entry_path, final_leg = be.final_leg }
  end

  if be and be.cost + BRIDGE_MIN_SAVINGS < walk_cost then return bridge_result() end
  if walk_path and #walk_path > 0 then return { mode = "walk", path = walk_path, walk_cost = walk_cost } end
  if be then return bridge_result() end   -- not walkable at all — bridge is the only way (today's fallback)

  local exists = false
  for _, r in pairs(P.rooms) do if has_mark(r, label) then exists = true; break end end
  return { mode = "none", reason = exists and "unreachable" or "unmarked" }
end

-- `goto <label>` (human alias) — travel to the NEAREST room you've tagged with `mark <label>` (e.g.
-- `goto trainer`), reusing the stream-driven nav walker. Matches a mark by substring, so `goto train`
-- reaches a "trainer". `goto stop` cancels.
--
-- It doesn't just walk when a walk path exists — it costs walking against bridging (recall/waypoint-hop
-- + a short final leg) and takes the CHEAPER one (see plan_goto_route / goto_bridge_advance). A long
-- overland trek to a mark near a known waypoint bridges instead. The hop uses the number LEARNED from
-- watching you actually `waypoint <n>` — never a fragile description match.
function human_goto(label)
  label = trim(label or ""):lower()
  if label == "" then echo("[goto] usage: travel('<mark>') or the game alias `goto <mark>`  (see mark(); travel('stop') cancels)"); return end
  if label == "stop" then
    P.goto_bridge = nil
    if P.nav then P.nav = nil; echo("[goto] stopped.") else echo("[goto] not navigating.") end
    return
  end
  if in_combat() then echo("[goto] not while you're fighting."); return end

  -- Built-in target: `goto death` (or `goto corpse`) returns you to where you last died. The room is
  -- auto-tagged "death" on the "You have been KILLED" line (see mark_death). If it's walkable, walk it;
  -- if the map can't retrace a route (you entered its area through a portal/special exit), route to the
  -- nearest reachable room by coordinates instead — as close to your corpse as the explored map allows.
  if label == "death" or label == "corpse" then
    P.goto_bridge = nil
    local dead_id
    for id, r in pairs(P.rooms) do if r.marks and r.marks.death then dead_id = id; break end end
    if not dead_id then
      echo("[goto] no death recorded yet — nothing to return to."); return
    end
    if dead_id == P.current_room then echo("[goto] you're already where you died."); return end
    local path = find_path(function(id) return id == dead_id end)
    if path and #path > 0 then
      echo(string.format("[goto] returning to where you died (%d step%s) — 'goto stop' to cancel.",
        #path, #path == 1 and "" or "s"))
      P.nav = { path = path, idx = 1, dest = "your corpse", gen = 0 }
      nav_step(); return
    end
    -- Not walkable straight there — get as close as the explored map allows.
    local near = nearest_reachable_to_coord(P.rooms[dead_id].coord)
    local npath = near and find_path(function(id) return id == near end)
    if npath and #npath > 0 then
      echo(string.format("[goto] can't retrace the exact room you died in — routing to the nearest "
        .. "reachable point (%d step%s) — 'goto stop' to cancel.", #npath, #npath == 1 and "" or "s"))
      P.nav = { path = npath, idx = 1, dest = "near your corpse", gen = 0 }
      nav_step(); return
    end
    echo("[goto] can't reach where you died from here on foot. `goto waypoint` to get onto the "
      .. "fast-travel network first, then try again.")
    return
  end

  -- Built-in target: `goto waypoint` (or `wp`) heads to the nearest known waypoint room. If none is
  -- walkable, recall lands you on your recall-site waypoint (which IS a waypoint) — so that's the bridge.
  if WP_ALIASES[label] then
    if P.rooms[P.current_room] and P.rooms[P.current_room].waypoint then
      P.goto_bridge = nil; echo("[goto] you're already at a waypoint."); return
    end
    local wpath = find_path(function(id) return id ~= P.current_room and P.rooms[id] and P.rooms[id].waypoint end)
    if wpath and #wpath > 0 then
      P.goto_bridge = nil
      echo(string.format("[goto] routing to the nearest waypoint (%d step%s) — 'goto stop' to cancel.",
        #wpath, #wpath == 1 and "" or "s"))
      P.nav = { path = wpath, idx = 1, dest = "a waypoint", gen = 0 }
      nav_step()
      return
    end
    P.goto_bridge = { label = "waypoint", want_waypoint = true, tries = 0, hops = 0 }
    echo("[goto] no waypoint walkable from here — recalling to your recall-site waypoint ('goto stop' to cancel).")
    goto_recall_attempt()
    return
  end

  if has_mark(P.rooms[P.current_room], label) then
    P.goto_bridge = nil; echo("[goto] you're already at a '" .. label .. "'."); return
  end

  local plan = plan_goto_route(label)
  if plan.mode == "walk" then
    P.goto_bridge = nil
    local path = plan.path
    echo(string.format("[goto] routing to '%s' (%d step%s) — 'goto stop' to cancel.",
      label, #path, #path == 1 and "" or "s"))
    P.nav = { path = path, idx = 1, dest = "'" .. label .. "'", gen = 0 }
    nav_step()
    return
  end
  if plan.mode == "bridge" then
    P.goto_bridge = { label = label, target_wp = plan.target_wp, tries = 0, hops = 0 }
    if plan.walk_cost < math.huge then
      -- Walking is possible but pricier — bridge by CHOICE (this is the new cheaper-route behavior).
      echo(string.format("[goto] '%s' is %d step%s on foot — bridging via waypoint (~%d) instead ('goto stop' to cancel).",
        label, plan.walk_cost, plan.walk_cost == 1 and "" or "s", plan.bridge_cost))
    else
      -- Not walkable at all — the original fallback.
      echo("[goto] '" .. label .. "' isn't walkable from here — bridging via recall/waypoint ('goto stop' to cancel).")
    end
    goto_bridge_advance()
    return
  end
  -- plan.mode == "none": distinguish "not tagged anywhere" from "tagged, but not reachable overland".
  if plan.reason == "unmarked" then
    echo("[goto] nothing is marked '" .. label .. "'. Stand in the room and mark('" .. label .. "') first.")
    return
  end
  -- Marked but not reachable exactly (no walk path, no learnable bridge). Rather than just refusing, get
  -- as CLOSE as the explored map allows — route to the nearest reachable room by coordinates (same as
  -- `goto death`). Only fall through to the hints below if we're already as close as we can get.
  local target_coord
  for _, r in pairs(P.rooms) do
    if has_mark(r, label) and r.coord then target_coord = r.coord; break end
  end
  local near = target_coord and nearest_reachable_to_coord(target_coord)
  local npath = near and near ~= P.current_room and find_path(function(id) return id == near end)
  if npath and #npath > 0 then
    P.goto_bridge = nil
    echo(string.format("[goto] can't reach '%s' exactly from here — routing to the nearest reachable point"
      .. " (%d step%s) — 'goto stop' to cancel.", label, #npath, #npath == 1 and "" or "s"))
    P.nav = { path = npath, idx = 1, dest = "near '" .. label .. "'", gen = 0 }
    nav_step()
    return
  end
  -- "unreachable" also covers a mark that IS walkable from a known waypoint whose NUMBER we haven't
  -- learned (bridge_estimate refuses bridges that would stall mid-hop). Say so accurately instead of
  -- claiming no waypoint reaches it.
  local wp = nearest_waypoint_for(label)
  if wp then
    local rn = P.rooms[wp] and P.rooms[wp].name
    echo("[goto] '" .. label .. "' is walkable from " .. (rn and ("'" .. rn .. "'") or "a waypoint")
      .. ", but I don't know that waypoint's number yet — run `waypoint`, or hop there once with"
      .. " `waypoint <n>`, so I can learn it.")
    echo(waypoints_hint())
  else
    echo("[goto] '" .. label .. "' is marked, but not reachable on foot from any waypoint you've walked. "
      .. "Explore a route, or set a waypoint near it.")
  end
end
alias([[^goto (.+)$]], function(_, label) human_goto(label) end)

-- travel(mark) — the REPL-callable form of `goto`. `goto` is a Lua reserved word, so #goto('x') can't
-- parse; use travel('x'). The `goto <mark>` typed straight into the game line (the alias above) still
-- works unchanged. travel('stop') cancels an in-progress route.
function travel(label) return human_goto(label) end
doc(travel, { name = "travel", sig = "travel(mark)", group = "map",
  text = "Route to a marked room (or 'death'/'corpse'), costing walking vs. recall/waypoint bridging and taking the cheaper. travel('stop') cancels. Same engine as the in-game `goto <mark>` alias (goto is a Lua keyword, so use travel() from the REPL)." })

-- waypoints() — show the fast-travel waypoints parsed from `waypoint` listings this session.
function waypoints() echo(waypoints_hint()) end
doc(waypoints, { name = "waypoints", sig = "waypoints()", group = "map",
  text = "List the fast-travel waypoints learned from `waypoint` listings this session (number, name, reachability)." })

local RECALL_MAX_TRIES, HOP_MAX = 6, 5

-- One recall attempt, as a PROMISE CHAIN: send recall → await the landing (a room change) OR a fizzle
-- (rx.merge(roomChange$, fizzle$):first()) → on a fizzle, retry after a short delay, bounded by
-- RECALL_MAX_TRIES; a landing is picked up by pilot_room_change → goto_bridge_advance. Recall is
-- unreliable, hence the retry. The synchronous cap/tries/echo/send is preserved EXACTLY (the recall-cap
-- spec drives this seam directly): the reactive await is layered AROUND it, and is inert until a stream
-- event arrives (no subscriber → dropped), so a direct re-drive of goto_recall_attempt caps at 6 sends.
function goto_recall_attempt()
  local b = P.goto_bridge
  if not b then return end
  if b.tries >= RECALL_MAX_TRIES then
    echo("[goto] recall kept failing (" .. b.tries .. " tries) — try again later or move manually.")
    P.goto_bridge = nil
    return
  end
  b.tries = b.tries + 1
  echo("[goto] recalling… (attempt " .. b.tries .. "/" .. RECALL_MAX_TRIES .. ")")
  -- Drop any prior in-flight recall await so only one is ever live (cancel cascades upstream to the
  -- merged-stream subscription, unsubscribing it).
  if P._recall_await then P._recall_await.cancel(); P._recall_await = nil end
  send("recall")
  if not rx then return end
  local head = rx.merge(
    roomChangeS:map(function() return "landed" end),
    recallFizzleS:map(function() return "fizzle" end)
  ):first():toPromise()
  untrack_flow(head)                              -- internal plumbing → no HUD promise row
  P._recall_await = head.andThen(function(ev)
    P._recall_await = nil
    if ev == "fizzle" and P.goto_bridge == b then
      -- Small delay so we don't hammer the game, then retry (the cap above ends the loop).
      after(2, function() if P.goto_bridge == b then goto_recall_attempt() end end)
    end
  end)
end

-- The bridge state machine, re-run on every landing (room change) while a `goto` bridge is active. It's
-- deliberately stateless beyond P.goto_bridge: each call just re-decides from where we ARE now.
--   1. mark walkable from here?      -> walk the final leg, done.
--   2. standing on a waypoint room?  -> waypoint-hop toward the target (if we know its number), else hand off.
--   3. otherwise                     -> recall to get onto the network.
function goto_bridge_advance()
  local b = P.goto_bridge
  if not b then return end
  if in_combat() then echo("[goto] combat — stopping the bridge."); P.goto_bridge = nil; return end
  -- A bridge-entry walk is in progress (see step 3): let the nav walker reach the waypoint before we
  -- re-decide. The walker keeps the bridge alive; on arrival P.nav clears and this re-runs to hop.
  if P.nav then return end
  local here = P.current_room

  -- `goto waypoint`: any waypoint room satisfies it. If we've landed on one, we're done; else walk to
  -- the nearest, or recall again.
  if b.want_waypoint then
    if P.rooms[here] and P.rooms[here].waypoint then P.goto_bridge = nil; echo("[goto] arrived at a waypoint."); return end
    local wpath = find_path_from(here, function(id) return id ~= here and P.rooms[id] and P.rooms[id].waypoint end)
    if wpath and #wpath > 0 then
      P.goto_bridge = nil
      echo(string.format("[goto] final leg to the nearest waypoint (%d step%s).", #wpath, #wpath == 1 and "" or "s"))
      P.nav = { path = wpath, idx = 1, dest = "a waypoint", gen = 0 }
      nav_step()
      return
    end
    goto_recall_attempt()
    return
  end

  -- 1. Walk the final leg from here — but only when walking is now within BRIDGE_MIN_SAVINGS of what it
  --    would still cost to keep bridging (or no further hop is possible/known). If bridging on is clearly
  --    cheaper, DON'T greedily grab a long walk here — fall through and keep hopping.
  local path = find_path_from(here, function(id) return id ~= here and has_mark(P.rooms[id], b.label) end)
  if path and #path > 0 then
    local be = bridge_estimate(here, b.label, b.target_wp)
    if not be or #path <= be.cost + BRIDGE_MIN_SAVINGS then
      P.goto_bridge = nil
      echo(string.format("[goto] final leg to '%s' (%d step%s).", b.label, #path, #path == 1 and "" or "s"))
      P.nav = { path = path, idx = 1, dest = "'" .. b.label .. "'", gen = 0 }
      nav_step()
      return
    end
    -- else: keep hopping (bridge is meaningfully cheaper) — fall through to steps 2/3.
  end
  if has_mark(P.rooms[here], b.label) then
    P.goto_bridge = nil; echo("[goto] arrived at '" .. b.label .. "'."); return
  end

  -- 2. On a waypoint room: hop toward the target waypoint (learned number, or a name match to the list).
  if P.rooms[here] and P.rooms[here].waypoint then
    local num = b.target_wp and waypoint_num_for_room(b.target_wp)
    if here == b.target_wp then
      P.goto_bridge = nil
      echo("[goto] reached the waypoint, but '" .. b.label .. "' isn't walkable from it anymore.")
      echo(waypoints_hint()); return
    end
    if not num then
      P.goto_bridge = nil
      local rn = b.target_wp and P.rooms[b.target_wp] and P.rooms[b.target_wp].name
      echo("[goto] I don't know which waypoint number reaches " .. (rn and ("'" .. rn .. "'") or "that room")
        .. " (its name doesn't match any in your list) — hop manually, then `goto " .. b.label .. "` again:")
      echo(waypoints_hint()); return
    end
    if b.hops >= HOP_MAX then echo("[goto] too many waypoint hops — stopping."); P.goto_bridge = nil; return end
    b.hops = b.hops + 1
    b.gen = (b.gen or 0) + 1
    local g = b.gen
    echo("[goto] hopping to waypoint " .. num .. " …")
    send("waypoint " .. num)
    -- Watchdog: if the hop doesn't land (out of range / needs a bridge waypoint), hand off.
    after(6, function()
      if P.goto_bridge == b and b.gen == g then
        echo("[goto] that waypoint hop didn't land (may be out of range or need a bridge) — hop manually:")
        echo(waypoints_hint()); P.goto_bridge = nil
      end
    end)
    return
  end

  -- 3. Not on a waypoint and can't walk to the mark: get onto the network. Recall is cheap and usually
  --    the right move; only walk to a waypoint room if one is strictly closer than a recall (RECALL_COST).
  --    The walk keeps the bridge alive (the P.nav guard at the top stops re-entry churn); on arrival at
  --    the waypoint this re-runs and step 2 hops.
  local _, entry_path = network_entry(here)
  if entry_path then
    echo(string.format("[goto] walking to a waypoint %d step%s away to get onto the network.",
      #entry_path, #entry_path == 1 and "" or "s"))
    P.nav = { path = entry_path, idx = 1, dest = "a waypoint", gen = 0 }
    nav_step()
    return
  end
  goto_recall_attempt()
end

-- A human-readable list of the waypoints we've parsed from a `waypoint` listing this session, so you can
-- pick the number nearest your destination. Empty prompt when we haven't seen the list yet.
function waypoints_hint()
  local nums = {}
  for n in pairs(P.waypoints or {}) do nums[#nums + 1] = n end
  if #nums == 0 then
    return "[goto] (type `waypoint` to see your waypoints, hop nearer with `waypoint <n>`, then `goto` again.)"
  end
  table.sort(nums)
  local lines = { "[goto] known waypoints (`waypoint <n>` to hop, then `goto` again):" }
  for _, n in ipairs(nums) do
    local w = P.waypoints[n]
    local tag = w.reachable and "" or (w.bridge and (" (bridge via " .. w.bridge .. ")") or " (out of range)")
    lines[#lines + 1] = "  " .. n .. " - " .. w.name .. tag
  end
  return table.concat(lines, "\n")
end

-- reset('room <dir>') — forget the room in <dir> from where you're standing (a manual heal for a bad
-- write to the map). Purges that room AND every edge pointing at it, so the direction shows as an
-- unexplored exit again; just walk there to remap it clean. reset('here') forgets the current room.
function reset(args) return reset_command(args) end
doc(reset, { name = "reset", sig = "reset('room <dir>' | 'here')", group = "map",
  text = "Forget a mis-mapped room and every edge pointing at it, so its direction reads unexplored again — reset('room <dir>') for a neighbour, reset('here') for the current room. Walk back to remap it clean." })
function reset_command(args)
  args = trim(args or ""):lower()
  local sub = args:match("^%S*")
  local cur = P.current_room
  if not cur or not P.rooms[cur] then echo("[reset] I don't know which room you're in yet."); return end

  local target
  if sub == "here" then
    target = cur
  elseif sub == "room" then
    local dir = CANON[args:match("^%S+%s+(%S+)") or ""]
    if not dir then echo("[reset] usage: reset('room <dir>')   (n/s/e/w/ne/nw/se/sw/u/d)"); return end
    target = P.rooms[cur].moves and P.rooms[cur].moves[dir]
    if not target then echo("[reset] no known room to the " .. dir .. " from here — nothing to forget."); return end
  else
    echo("[reset] usage: reset('room <dir>')  |  reset('here')"); return
  end

  local name = (P.rooms[target] and P.rooms[target].name) or ("room " .. tostring(target))
  P.rooms[target] = nil
  local edges = 0
  for _, r in pairs(P.rooms) do                        -- sever every edge that pointed at it
    if r.moves then
      for d, dest in pairs(r.moves) do
        if dest == target then r.moves[d] = nil; edges = edges + 1 end
      end
    end
  end
  if target == cur then                                 -- forgot the room you're standing in:
    P.rooms[cur] = { exits = {}, moves = {} }            -- keep you anchored with a blank record that
    if state and state.room_name then P.rooms[cur].name = state.room_name end  -- refills as you look/move
  end
  schedule_save()
  echo(string.format("[reset] forgot '%s' and %d edge%s to it — walk there again to remap it.",
    name, edges, edges == 1 and "" or "s"))
end

-- ---- cost tracking -------------------------------------------------------------------------
-- Per-million-token USD rates: {input, output, cache_read, cache_write}.
local RATES = {
  ["claude-sonnet-4-6"] = { 3, 15, 0.30, 3.75 },
  ["claude-haiku-4-5-20251001"] = { 1, 5, 0.10, 1.25 },
}
local function usage_cost(u, model)
  local r = RATES[model]; if not r then return 0 end
  return (u[1] * r[1] + u[2] * r[2] + u[3] * r[3] + u[4] * r[4]) / 1e6
end
-- Returns total $, brain $, memory $, brain-usage {i,o,cr,cw}, memory-usage {i,o,cr,cw}. 0 if the
-- usage primitives aren't loaded (pre-`just run`).
local function session_cost()
  if not ai_usage then return 0, 0, 0, {}, {} end
  local i, o, cr, cw = ai_usage()
  local mi, mo, mcr, mcw = ai_mem_usage()
  local bmodel = (cfg.brain == "haiku") and "claude-haiku-4-5-20251001" or "claude-sonnet-4-6"
  local dc = (cfg.brain ~= "local") and usage_cost({ i, o, cr, cw }, bmodel) or 0
  local mc = cfg.use_memory and usage_cost({ mi, mo, mcr, mcw }, cfg.mem_model) or 0
  return dc + mc, dc, mc, { i = i, o = o, cr = cr, cw = cw }, { i = mi, o = mo, cr = mcr, cw = mcw }
end

-- ---- the turn ------------------------------------------------------------------------------
-- Chain: refresh structured memory (only if the room changed) -> retrieve relevant manual passages
-- -> decide. Each step is async; same-room turns skip the memory call.
function take_turn()
  local function then_decide()
    if cfg.use_rag and ai_rag_count() > 0 then
      ai_retrieve(rag_query(), cfg.rag_k, function(chunks_json, err)
        if EPOCH ~= _AIP.epoch then return end
        if not err and chunks_json then P.manual = format_manual(chunks_json) end
        take_turn_decide()
      end)
    else
      take_turn_decide()
    end
  end
  if cfg.use_memory and P.world.room_id ~= P.current_room then
    run_memory_head(then_decide)
  else
    then_decide()
  end
end

function take_turn_decide()
  P.snap_seq = P.input_seq
  P.snap_fighting = in_combat()
  local directive = P.pending; P.pending = nil
  local nudge = P.nudge; P.nudge = nil
  local fighting = P.snap_fighting
  local max_tokens = fighting and cfg.combat_max_tokens or cfg.max_tokens
  local sys = system_prompt()
  -- Local combat path gets the LEAN prompt (state + short output window, no map/notes/manual) and a
  -- shorter output window — no prompt caching locally, so trimming prefill is the biggest speed win.
  -- Hosted models (cached) and every non-combat turn keep the full prompt.
  local lean = fighting and not cfg.use_tools
  local convo = current_room_slice(lean and cfg.combat_context_lines or cfg.context_lines)
  local user = lean
    and build_combat_user(describe_state(), world_summary(), convo, directive)
    or build_user(describe_state(), exploration_summary(), memory_summary(), world_summary(), convo, directive, nudge, fighting)

  local tools = cfg.use_tools and tools_json() or ""   -- fine-tuned models get NO tools (CMD: text only)
  ai_request(sys, user, max_tokens, tools, cfg.think_prefill, function(reply, tool_calls_json, err)
    if EPOCH ~= _AIP.epoch then return end   -- a reload happened mid-request; this plan is void
    local function finish()
      P.busy = false; P.last_turn = os.time()
      if cfg.budget and cfg.budget > 0 then
        local spent = session_cost()
        if spent >= cfg.budget then
          echo(string.format("[ai] budget cap $%.2f reached (~$%.2f spent this session) — disarming. pilot.budget(0) to lift it, then pilot.on().", cfg.budget, spent))
          P.enabled = false; _AIP.enabled = false; return
        end
      end
      if P.enabled and P.input_seq ~= P.snap_seq then arm() end
    end
    if err then echo("[ai] request failed: " .. err .. " (is LM Studio running?)"); finish(); return end

    -- Combat started or ended while we were thinking: the plan we were forming is obsolete (an
    -- exploration move during a fresh fight, or an attack on a mob that's now dead). Always reassess.
    local fighting_now = in_combat()
    if fighting_now ~= P.snap_fighting then
      echo(fighting_now and "[ai] (combat started while thinking — reassessing)"
                         or "[ai] (combat ended while thinking — reassessing)")
      P.stale_skips = 0
      if not P.pending then P.pending = directive end
      finish(); return
    end

    -- Out of combat, let a couple of re-reads absorb a burst of output. In STEADY combat we always
    -- act now — round-by-round noise must not stall us.
    local moved = P.input_seq ~= P.snap_seq
    if not fighting_now and moved and P.stale_skips < cfg.max_stale_skips then
      P.stale_skips = P.stale_skips + 1
      if not P.pending then P.pending = directive end
      echo("[ai] (situation changed while thinking — re-reading before acting)")
      finish(); return
    end
    P.stale_skips = 0
    log_trace(sys, user, reply or "")

    -- Prefer the structured tool calls; fall back to text parsing if the model didn't use them.
    local tcs = tool_calls_json and json.decode(tool_calls_json)
    if type(tcs) == "table" and #tcs > 0 then
      local calls = {}
      for _, c in ipairs(tcs) do
        local a = c.arguments
        if type(a) == "string" then a = json.decode(a) end
        calls[#calls + 1] = { name = c.name, args = (type(a) == "table") and a or {} }
      end
      local actions, mems, scripts = from_tool_calls(calls)
      local thoughts = (type(reply) == "string" and trim(reply) ~= "") and { trim(reply) } or {}
      execute(actions, thoughts, scripts, mems)
    else
      handle_reply(reply or "")
    end
    finish()
  end)
end

-- Capture a human-played turn as an OpenAI tool-call SFT example: the exact prompt the model would
-- have seen, paired with the tool call your command maps to. Written to a SEPARATE file so your gold
-- play never mixes with the model's own (sometimes wrong) traces. Defined as a global so the early
-- on_user_input can reach it; it uses the prompt builders, which are in scope here.
function build_human_demo(cmd)
  local name, args = tool_call_for(cmd)
  local sys = system_prompt()
  local user = build_user(describe_state(), exploration_summary(), memory_summary(), "",
    current_room_slice(), nil, nil, in_combat())
  local record = {
    -- Timing metadata (top-level, NOT inside `messages`, so build_dataset.py — which keeps only
    -- `messages` — ignores it for training, while it stays available for analysis/curriculum/filtering).
    -- `ts` = wall-clock capture time; `dt` = seconds since your previous command (your decision time).
    ts = os.time(),
    dt = (P.last_human > 0) and (os.time() - P.last_human) or 0,
    messages = {
      { role = "system", content = sys },
      { role = "user", content = user },
      { role = "assistant", content = "", tool_calls = { {
        id = "call_1", type = "function",
        ["function"] = { name = name, arguments = json.encode(args) },
      } } },
    } }
  return json.encode(record)
end

function log_human_demo(cmd)
  if not P.trace then return end
  local f = io.open(cfg.human_trace_file, "a")
  if not f then return end
  f:write(build_human_demo(cmd) .. "\n")
  f:close()
  P.demo_count = P.demo_count + 1
  if P.demo_count % 25 == 0 then echo("[ai] captured " .. P.demo_count .. " demos this session") end
end

function fire_if_ready(g)
  if EPOCH ~= _AIP.epoch then return end   -- superseded by a reload
  if g ~= P.gen or not P.enabled or P.busy or P.nav then return end   -- P.nav: script is auto-walking a route
  -- Combat-only: go dormant between fights. We simply DON'T fire (and don't re-arm) when out of combat;
  -- the next fight's output re-arms the chain (pilot_observe -> arm), so this auto-resumes with no
  -- per-fight re-arming. Nothing else changes — it never fires on your manual movement between fights.
  if cfg.combat_only and not in_combat() then return end
  local now = os.time()
  if now - P.last_turn < cfg.min_interval then
    after(cfg.min_interval, function() fire_if_ready(g) end); return
  end
  local grace_left = cfg.human_grace - (now - P.last_human)
  if grace_left > 0 then
    after(grace_left + 0.1, function() fire_if_ready(g) end); return
  end
  P.busy = true
  take_turn()
end

-- ---- controls (#ai ...) --------------------------------------------------------------------
-- Configure the DECISION model. "sonnet"/"haiku" = hosted Claude (Anthropic, tool-calling); "local"
-- = the fine-tuned local model (CMD: text). Used both by `#ai brain` and on load (cfg.brain default).
-- ai_set_auth is a Swift primitive added later — guarded so an un-relaunched binary doesn't error.
local function set_brain(b)
  b = (b or ""):lower()
  if b == "local" then
    ai_set_endpoint("http://localhost:1234/v1"); ai_set_model(cfg.local_model or "")
    if ai_set_auth then ai_set_auth(false) end
    cfg.use_tools = false; cfg.think_prefill = "<think>\n\n</think>\n\n"; cfg.brain = "local"
    return "LOCAL fine-tune (" .. (cfg.local_model or "auto") .. ") — override with `pilot.model(<key>)`"
  elseif b == "haiku" or b == "sonnet" then
    local m = (b == "haiku") and "claude-haiku-4-5-20251001" or "claude-sonnet-4-6"
    ai_set_endpoint("https://api.anthropic.com/v1"); ai_set_model(m)
    if ai_set_auth then ai_set_auth(true) end
    cfg.use_tools = true; cfg.think_prefill = ""; cfg.brain = b
    return m .. " (Anthropic, tool-calling)"
  end
  return nil
end

local function set_enabled(on)
  P.enabled = on
  _AIP.enabled = on
  if on then
    P.recent_cmds = {}; P.stale_skips = 0
    -- `spells` is one-time SESSION setup (it teaches the combat prompt which real spells the character
    -- has), not a between-fight action, so prime it even in combat-only. The recurring look/skills primers
    -- stay skipped in combat-only so the pilot truly stays hands-off until a fight begins.
    echo("[ai] > spells"); send("spells")
    if cfg.combat_only then
      echo("[ai] armed (COMBAT-ONLY) — dormant until a fight starts, then it drives each turn. pilot.off() to stop.")
    else
      echo("[ai] armed — the local model is now driving. pilot.off() to stop.")
      for _, primer in ipairs({ "look", "skills" }) do echo("[ai] > " .. primer); send(primer) end
    end
    arm()
  else
    echo("[ai] disengaged.")
  end
end

function ai_command(args)
  local verb, rest = (args or ""):match("^(%S*)%s*(.*)$")
  verb = (verb or ""):lower(); rest = trim(rest or "")
  if verb == "" or verb == "status" then
    local hosted = (cfg.brain == "sonnet" or cfg.brain == "haiku")
    echo(string.format("[ai] %s | brain=%s%s | memory=%s | rag=%s | goal=%s",
      P.enabled and "ARMED" or "idle",
      cfg.brain,
      hosted and " (Anthropic, prompt-caching — needs the native build via `just run`)" or " (local model)",
      cfg.use_memory and cfg.mem_model or "off",
      cfg.use_rag and (ai_rag_count() .. " passages") or "off",
      P.goal))
  elseif verb == "on" or verb == "start" then set_enabled(true)
  elseif verb == "off" or verb == "stop" then set_enabled(false)
  elseif verb == "once" or verb == "go" then
    if not P.busy then P.busy = true; take_turn() else echo("[ai] busy") end
  elseif verb == "goal" then if rest ~= "" then P.goal = rest; _AIP.goal = rest end; echo("[ai] goal: " .. P.goal)
  elseif verb == "tell" or verb == "say" or verb == "nudge" then
    if rest == "" then echo("[ai] usage: pilot.tell('<one-off instruction>')") else
      P.pending = rest; echo("[ai] director note (next turn): " .. rest)
      if P.enabled then arm() else echo("[ai] (idle — pilot.on() to act)") end
    end
  elseif verb == "model" then ai_set_model(rest); echo("[ai] model: " .. (rest ~= "" and rest or "(auto)"))
  elseif verb == "brain" then
    local desc = set_brain(rest)
    if desc then echo("[ai] brain: " .. desc) else echo("[ai] usage: pilot.brain('local' | 'haiku' | 'sonnet')") end
  elseif verb == "mode" then
    local m = rest:lower()
    if m == "text" or m == "cmd" then cfg.use_tools = false
    elseif m == "tools" or m == "tool" then cfg.use_tools = true end
    echo("[ai] mode: " .. (cfg.use_tools and "tools (base models)" or "text/CMD: (fine-tuned models)"))
  elseif verb == "combat_only" or verb == "combatonly" then
    local m = rest:lower()
    if m == "on" or m == "true" or m == "1" or m == "yes" then cfg.combat_only = true
    elseif m == "off" or m == "false" or m == "0" or m == "no" then cfg.combat_only = false end
    echo("[ai] combat-only: " .. (cfg.combat_only
      and "ON — acts only during fights, dormant (hands-off) between them; auto-resumes each new fight"
      or "off — the pilot drives continuously (explore/loot/move) when armed"))
  elseif verb == "url" then if rest ~= "" then ai_set_endpoint(rest) end; echo("[ai] endpoint set")
  elseif verb == "mem" then
    local m = rest:lower()
    if m == "off" then cfg.use_memory = false elseif m == "on" then cfg.use_memory = true; P.mem_fail = 0 end
    echo("[ai] memory head: " .. (cfg.use_memory and ("on (" .. cfg.mem_model .. ")") or "off"))
  elseif verb == "memmodel" then
    local m = rest:lower()
    if m == "sonnet" then cfg.mem_model = "claude-sonnet-4-6"
    elseif m == "haiku" then cfg.mem_model = "claude-haiku-4-5-20251001"
    elseif rest ~= "" then cfg.mem_model = rest end
    ai_set_memory_model(cfg.mem_model); echo("[ai] memory model: " .. cfg.mem_model)
  elseif verb == "memkey" then
    if rest ~= "" then ai_set_memory_key(rest); cfg.use_memory = true; P.mem_fail = 0; echo("[ai] memory key set; memory head on")
    else echo("[ai] usage: pilot.memkey('<anthropic-api-key>')") end
  elseif verb == "cost" then
    if not ai_usage then echo("[ai] cost tracking needs the new build — run `just run`, then pilot.reload()")
    else
      local total, dc, mc, du = session_cost()
      local seen = (du.i or 0) + (du.cr or 0) + (du.cw or 0)
      local cached = seen > 0 and math.floor(100 * (du.cr or 0) / seen) or 0
      echo(string.format("[ai] session ~$%.2f | brain=%s $%.2f (%d%% of input served from cache) | memory $%.2f | pilot.usagereset() to zero it",
        total, cfg.brain, dc, cached, mc))
    end
  elseif verb == "usagereset" then ai_usage_reset(); echo("[ai] usage counters reset")
  elseif verb == "budget" then
    local n = tonumber(rest)
    if n then cfg.budget = n; echo("[ai] budget cap: " .. (n > 0 and ("$" .. n .. " (auto-disarms when a turn crosses it)") or "off"))
    else echo("[ai] usage: pilot.budget(<dollars>)  (0 = off). Current: $" .. (cfg.budget or 0)) end
  elseif verb == "rag" then
    local m = rest:lower()
    if m == "off" then cfg.use_rag = false elseif m == "on" then cfg.use_rag = true; ai_rag_load(cfg.rag_index) end
    -- The index loads off-thread, so ai_rag_count() reads 0 for a beat after `on`; report it a moment later.
    if cfg.use_rag then
      after(0.5, function()
        local n = ai_rag_count()
        echo("[ai] manual (RAG): on — " .. n .. " passages indexed"
          .. (n == 0 and "  (run tools/finetune/build_rag_index.py to build the index)" or ""))
      end)
    else echo("[ai] manual (RAG): off") end
  elseif verb == "trace" then
    if rest:lower() == "off" then P.trace = false elseif rest:lower() == "on" then P.trace = true end
    echo("[ai] trace: " .. (P.trace and cfg.trace_file or "off"))
  elseif verb == "tools" then
    echo(tools_json())   -- the exact OpenAI tool definitions sent to the model each turn
  elseif verb == "demo" then
    if rest == "" then echo("[ai] usage: pilot.demo('<command>') — preview the training example your command maps to")
    else echo(build_human_demo(rest)) end
  elseif verb == "remember" then
    if rest ~= "" then remember(rest) else echo("[ai] usage: pilot.remember('<fact>')") end
  elseif verb == "memories" then
    if #P.memories == 0 then echo("[ai] no memories yet") end
    for _, m in ipairs(P.memories) do echo("[ai] • " .. m.text .. (m.area and (" (" .. m.area .. ")") or "")) end
  elseif verb == "forget" then
    if rest:lower() == "all" then P.memories = {}; schedule_save(); echo("[ai] forgot everything")
    else echo("[ai] usage: pilot.forget('all')") end
  else
    echo("[ai] commands via the pilot table: pilot.on() | pilot.off() | pilot.once() | pilot.status() | pilot.goal(text) | pilot.tell(text) | pilot.remember(fact) | pilot.memories() | pilot.forget('all') | pilot.model(id) | pilot.brain('local'|'haiku'|'sonnet') | pilot.trace('on'|'off') | pilot.tools()  —  help(pilot)")
  end
end

-- ---- public pilot surface (the `pilot` table) ----------------------------------------------
-- First-class, documented replacement for the old `#ai <sub>` string commands. Each member forwards
-- its verb to ai_command; the table is callable so a legacy `#ai on` (rewritten by the host to
-- `ai("on")`) and `pilot("on")` both still work. `ai(args)` remains as a thin deprecated wrapper.
pilot = {}
-- verb -> { sig, text }; turned into pilot.<verb>(arg) forwarders + individual docs.
local PILOT_CMDS = {
  on         = { sig = "pilot.on()",              text = "Arm the pilot: the decision model starts driving." },
  off        = { sig = "pilot.off()",             text = "Disengage the pilot." },
  once       = { sig = "pilot.once()",            text = "Take a single pilot turn without arming." },
  status     = { sig = "pilot.status()",          text = "Show armed state, brain/memory/RAG config, and the current goal." },
  goal       = { sig = "pilot.goal([text])",      text = "Set (or, with no arg, show) the standing goal the pilot pursues." },
  tell       = { sig = "pilot.tell(text)",        text = "Queue a one-off director note for the pilot's next turn." },
  model      = { sig = "pilot.model(id)",         text = "Set the decision model id directly." },
  brain      = { sig = "pilot.brain(which)",      text = "Choose the decision brain: 'local' | 'haiku' | 'sonnet'." },
  mode       = { sig = "pilot.mode(m)",           text = "Force 'tools' (base models) or 'text'/'cmd' (fine-tuned) mode." },
  combat_only = { sig = "pilot.combat_only(on)",  text = "When ON (the DEFAULT), the pilot acts ONLY during fights and stays dormant (hands-off) between them, auto-resuming each new fight — you explore/move manually. 'off' makes it fully autonomous (explores/loots/navigates too). A modifier on pilot.on()." },
  url        = { sig = "pilot.url(base)",         text = "Set the decision client's API endpoint." },
  mem        = { sig = "pilot.mem(on_off)",       text = "Turn the memory head on or off ('on'/'off')." },
  memmodel   = { sig = "pilot.memmodel(which)",   text = "Set the memory head's model ('haiku' | 'sonnet' | <id>)." },
  memkey     = { sig = "pilot.memkey(key)",       text = "Set the memory head's Anthropic API key and enable it." },
  cost       = { sig = "pilot.cost()",            text = "Report this session's estimated token spend." },
  usagereset = { sig = "pilot.usagereset()",      text = "Zero the token/cost counters." },
  budget     = { sig = "pilot.budget([dollars])", text = "Set a session $ cap that auto-disarms the pilot when crossed (0 = off)." },
  rag        = { sig = "pilot.rag(on_off)",       text = "Toggle RAG manual retrieval ('on'/'off')." },
  trace      = { sig = "pilot.trace(on_off)",     text = "Toggle turn tracing to the trace file ('on'/'off')." },
  tools      = { sig = "pilot.tools()",           text = "Print the exact tool definitions sent to the model each turn." },
  demo       = { sig = "pilot.demo(command)",     text = "Preview the training example a command maps to." },
  remember   = { sig = "pilot.remember(fact)",    text = "Add a memory the pilot will carry." },
  memories   = { sig = "pilot.memories()",        text = "List the pilot's remembered facts." },
  forget     = { sig = "pilot.forget(what)",      text = "Forget memories (pilot.forget('all'))." },
}
for verb, info in pairs(PILOT_CMDS) do
  pilot[verb] = function(arg) return ai_command(trim(verb .. " " .. (arg == nil and "" or tostring(arg)))) end
  doc(pilot[verb], { name = "pilot." .. verb, sig = info.sig, text = info.text, group = "pilot" })
end
function pilot.reload() return reload() end
doc(pilot.reload, { name = "pilot.reload", sig = "pilot.reload()", group = "pilot",
  text = "Hot-reload the Scripts/ directory (same as reload() / legacy `#ai reload`)." })
-- pilot.restore_map([path]) — import a saved/backup map file into the LIVE map, replacing what's in
-- memory, then persist it. Race-free (an in-memory swap, not a file-timing dance): use it to recover from
-- a backup (e.g. explored.lua.bak or a hand-made copy) without stopping the session. `path` defaults to
-- explored.lua.bak; a bare name resolves under the MudClient data dir. self-heals via persist.load.
function pilot.restore_map(path)
  path = (path ~= nil and path ~= "") and tostring(path) or (cfg.dir .. "/explored.lua.bak")
  if not path:find("/") then path = cfg.dir .. "/" .. path end
  local t = persist.load(path, function(m) if echo then echo(m, "yellow") end end)
  if type(t) ~= "table" or not t.rooms then
    echo("[map] restore failed: " .. path .. " is not a valid map file.", "red"); return
  end
  P.rooms = t.rooms or {}; P.dir_deltas = t.dir_deltas or {}; P.memories = t.memories or {}
  P.waypoints = t.waypoints or {}; P.wp_room = t.wp_room or {}; P.room_wp = t.room_wp or {}
  schedule_save()
  echo(string.format("[map] restored %d rooms, %d memories from %s (saving safely now).",
                     count_map(P.rooms), count_map(P.memories), path), "green")
end
doc(pilot.restore_map, { name = "pilot.restore_map", sig = "pilot.restore_map([path])", group = "pilot",
  text = "Import a saved/backup map file into the live map (replaces the in-memory rooms/marks/notes/waypoints, then saves). `path` defaults to explored.lua.bak; a bare name resolves under ~/Documents/MudClient. Use it to recover from a backup mid-session." })
setmetatable(pilot, { __call = function(_, args) return ai(args) end })

-- `ai` stays as a thin, deprecated wrapper (bootstrap defines it; here we just re-document it) so the
-- legacy `#ai …` typed form keeps working while pilot.* is the real surface.
doc("ai", { sig = "ai(args)", group = "pilot",
  text = "Deprecated: use the pilot.* table (pilot.on(), pilot.status(), …). Thin wrapper kept for the legacy `#ai …` typed form; ai('reload') re-runs scripts, else forwards to the pilot." })

-- ---- wiring (reactive: the room-parse / observe triggers as Observables) -------------------
-- The kxwt_* room parsers and the broad `.*` observer are rx.fromTrigger streams: each registers its
-- trigger on first subscribe (here, at load) and emits a `caps` table per match (caps[1..N] = capture
-- groups, caps.line = the full line). Subscribed in this order — SPECIFIC parsers BEFORE the broad
-- observer — so the underlying trigger registration keeps that order; and same-line firing is by pattern
-- specificity in the engine regardless, so the specific kxwt parsers still write the state the `.*`
-- observer reads (a broad `.*` is the least specific, so it fires last). fromTrigger returns nil (no gag)
-- from its handler, so every line still displays exactly as before. A permanent subscribe keeps the
-- trigger registered for the session, identical to a plain trigger().
if rx then
  rx.fromTrigger([[^kxwt_rvnum (-?\d+) -?\d+ -?\d+ (-?\d+) (-?\d+) (-?\d+) (\d+)]]):subscribe(function(c)
    pilot_room_change(tonumber(c[1]), { tonumber(c[2]), tonumber(c[3]), tonumber(c[4]), tonumber(c[5]) })
  end)
  rx.fromTrigger([[^kxwt_rshort (.+)$]]):subscribe(function(c) pilot_room_name(c[1]) end)
  -- Tag the current room with its terrain type (kxwt_terrain arrives just after rvnum, so current_room
  -- is already set). Persisted, so the minimap can colour each room by terrain.
  rx.fromTrigger([[^kxwt_terrain (\d+)]]):subscribe(function(c)
    local id = P.current_room
    if id and P.rooms[id] and P.rooms[id].terrain ~= tonumber(c[1]) then
      P.rooms[id].terrain = tonumber(c[1]); schedule_save()
    end
  end)
  -- kxwt_waypoint marks the current room as a travel waypoint; remember it so the minimap can flag it.
  rx.fromTrigger([[^kxwt_waypoint]]):subscribe(function()
    local id = P.current_room
    if id and P.rooms[id] and not P.rooms[id].waypoint then P.rooms[id].waypoint = true; schedule_save() end
  end)
  -- Your own death (only ever printed for YOU) teleports you to recall — mark the corpse room first.
  rx.fromTrigger([[^You have been KILLED]]):subscribe(function() mark_death() end)
  -- The broad observer (least specific → fires LAST on any line): feeds the transcript, exits parse, the
  -- waypoint-listing learner, the recall fizzle, and the turn arm.
  rx.fromTrigger([[.*]]):subscribe(function(c) pilot_observe(c.line) end)
else
  -- No reactive core (shouldn't happen — _rx loads at the top): fall back to plain triggers so the pilot
  -- still wires up its room parsing/observe.
  trigger([[^kxwt_rvnum (-?\d+) -?\d+ -?\d+ (-?\d+) (-?\d+) (-?\d+) (\d+)]], function(_, vnum, x, y, z, plane)
    pilot_room_change(tonumber(vnum), { tonumber(x), tonumber(y), tonumber(z), tonumber(plane) })
  end)
  trigger([[^kxwt_rshort (.+)$]], function(_, n) pilot_room_name(n) end)
  trigger([[^kxwt_terrain (\d+)]], function(_, t)
    local id = P.current_room
    if id and P.rooms[id] and P.rooms[id].terrain ~= tonumber(t) then
      P.rooms[id].terrain = tonumber(t); schedule_save()
    end
  end)
  trigger([[^kxwt_waypoint]], function()
    local id = P.current_room
    if id and P.rooms[id] and not P.rooms[id].waypoint then P.rooms[id].waypoint = true; schedule_save() end
  end)
  trigger([[^You have been KILLED]], function() mark_death() end)
  trigger([[.*]], function(line) pilot_observe(line) end)
end

load_map()
local brain_desc = set_brain(cfg.brain)                         -- apply the default decision model NOW
if cfg.use_memory then ai_set_memory_model(cfg.mem_model) end   -- endpoint+key come from Swift (Anthropic + env)
if cfg.use_rag then ai_rag_load(cfg.rag_index) end              -- prebuilt doc embeddings (if present)
echo("[ai] brain: " .. (brain_desc or cfg.brain) .. " | memory: " .. (cfg.use_memory and cfg.mem_model or "off"))
if P.enabled then
  echo("[ai] pilot reloaded — still ARMED.")
  arm()                                    -- resume without needing #ai on again
else
  echo("[ai] pilot loaded. pilot.on() to start.")
end

-- Pure helpers exposed for the test harness (see Scripts/tests/aipilot_spec.lua). `P` is closed over,
-- so map/nav specs can build a throwaway room table and drive real pathing. Not used by the client.
_AIP_TEST = {
  has_mark = has_mark, marks_list = marks_list, find_path = find_path,
  nearest_reachable_to_coord = nearest_reachable_to_coord, mark_death = mark_death,
  find_path_from = find_path_from, has_frontier = has_frontier, coord_key = coord_key, P = P,
  parse_waypoint_list = parse_waypoint_list, recall_failed = recall_failed,
  learn_waypoint = learn_waypoint, nearest_waypoint_for = nearest_waypoint_for,
  waypoint_num_for_room = waypoint_num_for_room, waypoint_cmd_num = waypoint_cmd_num,
  parse_exits = parse_exits, cmd_ends_turn = cmd_ends_turn, untaken_exit = untaken_exit,
  path_to_unexplored = path_to_unexplored, resolve_nav = resolve_nav,
  best_explore_dir = best_explore_dir, block_last_move = block_last_move, noexit_command = noexit_command,
  arm = arm, cfg = cfg, nearest_unexplored = nearest_unexplored,
  save_map = save_map, load_map = load_map,
  extract_calls = extract_calls, normalize_call = normalize_call, from_tool_calls = from_tool_calls,
  plan_goto_route = plan_goto_route, network_entry = network_entry, bridge_estimate = bridge_estimate,
  HOP_COST = HOP_COST, RECALL_COST = RECALL_COST, BRIDGE_MIN_SAVINGS = BRIDGE_MIN_SAVINGS,
  damage_spells_ranked = damage_spells_ranked, combat_spell_line = combat_spell_line,
  best_damage_spell = best_damage_spell, names_known_spell = names_known_spell,
  combat_target = combat_target, combat_substitute = combat_substitute,
  build_combat_user = build_combat_user,
}
