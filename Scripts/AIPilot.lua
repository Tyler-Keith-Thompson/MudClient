-- AI pilot (ported from the old Swift AIPilotService).
--
-- Drives the character via the local model. Uses the generic host primitives ai_request / after,
-- reads game state from AlterAeon.lua's `state` table + describe_state(), builds its own room map
-- (persisted with Lua serialization), and owns the prompt, turn loop, and #ai controls — all
-- hot-reloadable.

local cfg = {
  quiet = 0.75, min_interval = 2, human_grace = 4, max_cmds = 3, loop_threshold = 8,
  max_tokens = 256, combat_max_tokens = 128, max_stale_skips = 2, transcript_lines = 40,
  context_lines = 20,   -- rolling window: max recent output lines sent per turn (bounds prefill cost)
  circle_threshold = 3, -- after this many moves with no NEW room, the script auto-routes to a frontier
  use_tools = false,    -- set by the brain choice below (tools for hosted models, CMD: text for local)
  brain = "sonnet",     -- DEFAULT decision model: "sonnet" | "haiku" | "local". Applied on load.
  -- Memory head: a SEPARATE model (hosted Claude via Anthropic's OpenAI-compat endpoint) maintains
  -- structured world state (creatures/items here, inventory, a running summary) from raw output, so
  -- the decision model reads clean facts instead of hallucinating from scrolling text.
  use_memory = true,
  -- Memory head does EASY, FREQUENT extraction (parse room text -> structured facts), so it wants a
  -- cheap fast model. Haiku is the right default; the DECISION brain is where Sonnet belongs.
  mem_model = "claude-haiku-4-5-20251001",  -- #ai memmodel haiku|sonnet|<id> to switch
  -- RAG: retrieve the few doc passages most relevant to the current situation and feed them to the
  -- brain, so it knows the game's mechanics on demand instead of us hardcoding facts. Index is built
  -- offline (tools/finetune/build_rag_index.py) and embedded with the LOCAL embedding model.
  use_rag = true, rag_k = 3,
  budget = 0,   -- session $ cap; auto-disarms when exceeded (0 = off). Set with `#ai budget <dollars>`.
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
cfg.rag_index = cfg.dir .. "/rag_index.json"              -- prebuilt doc embeddings (build_rag_index.py)
os.execute("mkdir -p '" .. cfg.dir .. "' 2>/dev/null")

-- Runtime state that should survive `#ai reload` (globals persist in the lua state across the
-- script re-running). The epoch invalidates callbacks/timers scheduled by the previous load so a
-- pre-reload in-flight model request can't fire stale commands afterward.
_AIP = _AIP or {}
_AIP.epoch = (_AIP.epoch or 0) + 1
local EPOCH = _AIP.epoch

local P = {
  enabled = _AIP.enabled or false, busy = false,
  goal = _AIP.goal or "Explore, kill easy mobs, level up, and survive.",
  transcript = {}, last_turn = 0, recent_cmds = {}, loop_breaks = 0, stale_skips = 0,
  requested = {}, input_seq = 0, last_human = 0, pending = nil, nudge = nil, gen = 0, snap_seq = 0,
  snap_fighting = false, self_sent = {}, moves_since_new = 0, last_move_dir = nil, room_trail = {},
  world = { creatures = {}, items = {}, inventory = {}, summary = "", room_id = nil }, mem_fail = 0,
  manual = "", nav = nil,
  rooms = {}, current_room = nil, dir_deltas = {}, trace = true, memories = {},
  demo_count = 0,   -- human demonstrations captured this session (see #ai record)
}

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

-- ---- map persistence (Lua serialization; no JSON needed) -----------------------------------
local function ser(v)
  local t = type(v)
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "string" then return string.format("%q", v) end
  if t == "table" then
    local parts = {}
    for k, val in pairs(v) do
      local key = (type(k) == "number") and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
      parts[#parts + 1] = key .. "=" .. ser(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end

local save_gen = 0
local function save_map()
  local f = io.open(cfg.map_file, "w")
  if not f then return end
  f:write("return " .. ser({ rooms = P.rooms, dir_deltas = P.dir_deltas, memories = P.memories }))
  f:close()
end
local function schedule_save()
  save_gen = save_gen + 1
  local g = save_gen
  after(2, function() if g == save_gen then save_map() end end)
end
local function load_map()
  local chunk = loadfile(cfg.map_file)
  if not chunk then return end
  local ok, t = pcall(chunk)
  if ok and type(t) == "table" then
    P.rooms = t.rooms or {}; P.dir_deltas = t.dir_deltas or {}; P.memories = t.memories or {}
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
  -- And only link rooms that the COORDINATES say are actually different positions: ground truth, so
  -- a stale direction can't invent an adjacency between a room and itself or a non-neighbor.
  local dir = P.last_move_dir
  local moved = from and (coord[1] ~= from[1] or coord[2] ~= from[2]
                          or coord[3] ~= from[3] or coord[4] ~= from[4])
  if dir and from_id and moved then
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
  table.insert(P.transcript, "--- [MOVED to a NEW room. Everything above is a PREVIOUS room — creatures and items there are gone; act only on what's below.] ---")
  P.input_seq = P.input_seq + 1
  trim_transcript(); schedule_save()
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

-- A room is a frontier if it has an exit we've never taken (unexplored from there).
local function has_frontier(rid)
  local r = P.rooms[rid]
  if not r then return false end
  for d in pairs(r.exits) do if not r.moves[d] then return true end end
  return false
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

-- BFS over the move graph to the nearest room satisfying matches(id). Returns the route as a list of
-- directions, or nil if unreachable. BFS gives the shortest path and is inherently loop-free (the
-- `seen` set) — so a route can NEVER 2-cycle the way the old forced auto-router did.
-- Returns (route, destination_id), or nil. BFS = shortest, loop-free.
local function find_path(matches)
  local start = P.current_room
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
local TEXT_SYS = "You are an expert player of the MUD Alter Aeon, driving a character live. Read the "
  .. "character's STATE and the RECENT GAME OUTPUT, then issue exactly one command on its own line "
  .. "prefixed with 'CMD:'. Use real Alter Aeon commands and short target keywords. One action per turn."

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
- To cross ground you've ALREADY explored, or to head somewhere new, call `navigate` (destination = an area/room name you've visited, or "unexplored") — it auto-walks the whole route. Use it instead of stepping move-by-move through familiar rooms, and ESPECIALLY if you notice you're revisiting the same rooms: `navigate("unexplored")` takes you straight to new ground.
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

local function current_room_slice()
  local start = 1
  for i = #P.transcript, 1, -1 do
    if P.transcript[i]:find("MOVED to a NEW room", 1, true) then start = i; break end
  end
  -- Rolling window: never send more than cfg.context_lines of recent output, even when we've sat in
  -- one room for many lines (long fights, lots of events). Per-turn prefill is what dominates turn
  -- latency, so bounding the changing block keeps turns fast and predictable. Safe to trim old lines
  -- because the durable room identity lives in the STATE block (room name) and MAP block (exits) —
  -- those are sent every turn regardless. Tune cfg.context_lines for the speed/awareness tradeoff.
  local floor = #P.transcript - cfg.context_lines + 1
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
  local closer
  if cfg.use_tools then
    closer = fighting
      and "You are IN COMBAT — call attack or cast NOW. No reasoning."
      or "Decide the single best next action and call ONE tool. Call it directly — no preamble, no restating the situation."
  else
    closer = fighting
      and "You are IN COMBAT — reply with one line: CMD: <command> (e.g. CMD: kill kobold). Nothing else."
      or "Decide the single best next action. Reply with one line: CMD: <command>. Nothing else."
  end
  return "=== CHARACTER STATE ===\n" .. st .. world_block .. map_block .. mem_block .. manual_block .. "\n=== RECENT GAME OUTPUT ===\n" .. convo .. "\n" .. dir_block .. nudge_block .. "\n" .. closer
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
  echo("[ai] ✎ requested a script change: \"" .. req .. "\" (queued; edit a script + #ai reload to apply)")
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

  -- Collect the commands actually sent (skip `wait`/no-op tools).
  local commands = {}
  for _, a in ipairs(actions) do
    if type(a.cmd) == "string" and trim(a.cmd) ~= "" then commands[#commands + 1] = a.cmd end
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

-- Text fallback: parse CMD:/SCRIPT:/REMEMBER: lines. Used when the model answers with plain text
-- instead of calling a tool (older/smaller models), so nothing regresses.
function handle_reply(reply)
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
        echo("[ai] memory head disabled — set ANTHROPIC_API_KEY or `#ai memkey <key>`, then `#ai mem on`.") end
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
  local convo = current_room_slice()
  P.snap_seq = P.input_seq
  P.snap_fighting = in_combat()
  local directive = P.pending; P.pending = nil
  local nudge = P.nudge; P.nudge = nil
  local fighting = P.snap_fighting
  local max_tokens = fighting and cfg.combat_max_tokens or cfg.max_tokens
  local sys = system_prompt()
  local user = build_user(describe_state(), exploration_summary(), memory_summary(), world_summary(), convo, directive, nudge, fighting)

  local tools = cfg.use_tools and tools_json() or ""   -- fine-tuned models get NO tools (CMD: text only)
  ai_request(sys, user, max_tokens, tools, cfg.think_prefill, function(reply, tool_calls_json, err)
    if EPOCH ~= _AIP.epoch then return end   -- a reload happened mid-request; this plan is void
    local function finish()
      P.busy = false; P.last_turn = os.time()
      if cfg.budget and cfg.budget > 0 then
        local spent = session_cost()
        if spent >= cfg.budget then
          echo(string.format("[ai] budget cap $%.2f reached (~$%.2f spent this session) — disarming. `#ai budget 0` to lift it, then `#ai on`.", cfg.budget, spent))
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
    ai_set_endpoint("http://localhost:1234/v1"); ai_set_model("")
    if ai_set_auth then ai_set_auth(false) end
    cfg.use_tools = false; cfg.think_prefill = "<think>\n\n</think>\n\n"; cfg.brain = "local"
    return "LOCAL fine-tune (CMD: text) — load it via serve.sh + `#ai model <key>`"
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
    echo("[ai] armed — the local model is now driving. `#ai off` to stop.")
    for _, primer in ipairs({ "look", "spells", "skills" }) do echo("[ai] > " .. primer); send(primer) end
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
    if rest == "" then echo("[ai] usage: #ai tell <one-off instruction>") else
      P.pending = rest; echo("[ai] director note (next turn): " .. rest)
      if P.enabled then arm() else echo("[ai] (idle — #ai on to act)") end
    end
  elseif verb == "model" then ai_set_model(rest); echo("[ai] model: " .. (rest ~= "" and rest or "(auto)"))
  elseif verb == "brain" then
    local desc = set_brain(rest)
    if desc then echo("[ai] brain: " .. desc) else echo("[ai] usage: #ai brain local | haiku | sonnet") end
  elseif verb == "mode" then
    local m = rest:lower()
    if m == "text" or m == "cmd" then cfg.use_tools = false
    elseif m == "tools" or m == "tool" then cfg.use_tools = true end
    echo("[ai] mode: " .. (cfg.use_tools and "tools (base models)" or "text/CMD: (fine-tuned models)"))
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
    else echo("[ai] usage: #ai memkey <anthropic-api-key>") end
  elseif verb == "cost" then
    if not ai_usage then echo("[ai] cost tracking needs the new build — run `just run`, then `#ai reload`")
    else
      local total, dc, mc, du = session_cost()
      local seen = (du.i or 0) + (du.cr or 0) + (du.cw or 0)
      local cached = seen > 0 and math.floor(100 * (du.cr or 0) / seen) or 0
      echo(string.format("[ai] session ~$%.2f | brain=%s $%.2f (%d%% of input served from cache) | memory $%.2f | `#ai usagereset` to zero it",
        total, cfg.brain, dc, cached, mc))
    end
  elseif verb == "usagereset" then ai_usage_reset(); echo("[ai] usage counters reset")
  elseif verb == "budget" then
    local n = tonumber(rest)
    if n then cfg.budget = n; echo("[ai] budget cap: " .. (n > 0 and ("$" .. n .. " (auto-disarms when a turn crosses it)") or "off"))
    else echo("[ai] usage: #ai budget <dollars>  (0 = off). Current: $" .. (cfg.budget or 0)) end
  elseif verb == "rag" then
    local m = rest:lower()
    if m == "off" then cfg.use_rag = false elseif m == "on" then cfg.use_rag = true; ai_rag_load(cfg.rag_index) end
    echo("[ai] manual (RAG): " .. (cfg.use_rag and ("on — " .. ai_rag_count() .. " passages indexed") or "off")
      .. (ai_rag_count() == 0 and "  (run tools/finetune/build_rag_index.py to build the index)" or ""))
  elseif verb == "trace" then
    if rest:lower() == "off" then P.trace = false elseif rest:lower() == "on" then P.trace = true end
    echo("[ai] trace: " .. (P.trace and cfg.trace_file or "off"))
  elseif verb == "tools" then
    echo(tools_json())   -- the exact OpenAI tool definitions sent to the model each turn
  elseif verb == "demo" then
    if rest == "" then echo("[ai] usage: #ai demo <command> — preview the training example your command maps to")
    else echo(build_human_demo(rest)) end
  elseif verb == "remember" then
    if rest ~= "" then remember(rest) else echo("[ai] usage: #ai remember <fact>") end
  elseif verb == "memories" then
    if #P.memories == 0 then echo("[ai] no memories yet") end
    for _, m in ipairs(P.memories) do echo("[ai] • " .. m.text .. (m.area and (" (" .. m.area .. ")") or "")) end
  elseif verb == "forget" then
    if rest:lower() == "all" then P.memories = {}; schedule_save(); echo("[ai] forgot everything")
    else echo("[ai] usage: #ai forget all") end
  else
    echo("[ai] commands: on | off | once | status | goal <text> | tell <text> | remember <fact> | memories | forget all | model <id> | url <base> | trace [on|off] | tools")
  end
end

-- ---- wiring --------------------------------------------------------------------------------
trigger([[^kxwt_rvnum (-?\d+) -?\d+ -?\d+ (-?\d+) (-?\d+) (-?\d+) (\d+)]], function(_, vnum, x, y, z, plane)
  pilot_room_change(tonumber(vnum), { tonumber(x), tonumber(y), tonumber(z), tonumber(plane) })
end)
trigger([[^kxwt_rshort (.+)$]], function(_, n) pilot_room_name(n) end)
trigger([[.*]], function(line) pilot_observe(line) end)

load_map()
local brain_desc = set_brain(cfg.brain)                         -- apply the default decision model NOW
if cfg.use_memory then ai_set_memory_model(cfg.mem_model) end   -- endpoint+key come from Swift (Anthropic + env)
if cfg.use_rag then ai_rag_load(cfg.rag_index) end              -- prebuilt doc embeddings (if present)
echo("[ai] brain: " .. (brain_desc or cfg.brain) .. " | memory: " .. (cfg.use_memory and cfg.mem_model or "off"))
if P.enabled then
  echo("[ai] pilot reloaded — still ARMED.")
  arm()                                    -- resume without needing #ai on again
else
  echo("[ai] pilot loaded. #ai on to start.")
end
