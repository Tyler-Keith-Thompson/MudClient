










state = state or {}
















local function boot(name) pcall(require, name) end
boot("_rx")
if not __rx then dofile("Scripts/Foundation/_rx.lua") end
local rx = __rx




local roomChangeS = rx and rx.subject() or nil
local recallFizzleS = rx and rx.subject() or nil



local function untrack_flow(p)
   if p and __untrack_promise then __untrack_promise(p) end
   return p
end
































local cfg = {
   quiet = 0.75, min_interval = 2, human_grace = 4, max_cmds = 3, loop_threshold = 8,



   max_tokens = 256, combat_max_tokens = 48, max_stale_skips = 2, transcript_lines = 40,
   context_lines = 20,
   combat_context_lines = 8,




   combat_only = true,
   circle_threshold = 3,
   use_tools = false,
   brain = "local",





   local_model = "qwen3.6-27b-alteraeon-mlx",





   use_memory = false,


   mem_model = "claude-haiku-4-5-20251001",



   use_rag = true, rag_k = 3,
   budget = 0,
   home = os.getenv("HOME") or "",




   think_prefill = "<think>\n\n</think>\n\n",
}
cfg.dir = cfg.home .. "/Documents/MudClient"
cfg.map_file = cfg.dir .. "/explored.lua"
cfg.trace_file = cfg.dir .. "/ai-traces.jsonl"
cfg.human_trace_file = cfg.dir .. "/human-traces.jsonl"
cfg.rag_index = cfg.dir .. "/rag_index.json"
os.execute("mkdir -p '" .. cfg.dir .. "' 2>/dev/null")













































































































_AIP = _AIP or {};
(_AIP).epoch = ((_AIP).epoch or 0) + 1
local EPOCH = (_AIP).epoch

local P = {

   enabled = (_AIP).enabled or false, busy = false,
   goal = (_AIP).goal or "Explore, kill easy mobs, level up, and survive.",
   transcript = {}, last_turn = 0, recent_cmds = {}, loop_breaks = 0, stale_skips = 0,
   requested = {}, input_seq = 0, last_human = 0, pending = nil, nudge = nil, gen = 0, snap_seq = 0,
   snap_fighting = false, self_sent = {}, moves_since_new = 0, last_move_dir = nil, room_trail = {},
   world = { creatures = {}, items = {}, inventory = {}, summary = "", room_id = nil }, mem_fail = 0,
   manual = "", nav = nil,
   rooms = {}, current_room = nil, dir_deltas = {}, trace = true, memories = {},
   demo_count = 0,
}






local OPP = { north = "south", south = "north", east = "west", west = "east", up = "down", down = "up",
northeast = "southwest", southwest = "northeast", northwest = "southeast", southeast = "northwest", }
local CANON = { n = "north", s = "south", e = "east", w = "west", u = "up", d = "down", ne = "northeast",
nw = "northwest", se = "southeast", sw = "southwest", north = "north", south = "south", east = "east",
west = "west", up = "up", down = "down", northeast = "northeast", northwest = "northwest",
southeast = "southeast", southwest = "southwest", }

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function trim_transcript()
   while #P.transcript > cfg.transcript_lines do table.remove(P.transcript, 1) end
end






boot("_persist")
if not __persist then dofile("Scripts/Foundation/_persist.lua") end
local persist = __persist
local function count_map(t)
   local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n
end

local save_timer
local function save_map()





   local t0 = os.clock()
   persist.save(cfg.map_file, { rooms = P.rooms, dir_deltas = P.dir_deltas, memories = P.memories,
waypoints = P.waypoints, wp_room = P.wp_room, room_wp = P.room_wp, })
   local ms = (os.clock() - t0) * 1000
   if ms > 150 and echo then
      echo(string.format("\27[1;31m[perf] save_map %.0fms (rooms=%d)\27[0m", ms, count_map(P.rooms)))
   end
end



local function schedule_save()
   if cancel and save_timer then cancel(save_timer) end
   save_timer = after(2, save_map)
end
local function load_map()



   local loader = persist.load
   local t = loader(cfg.map_file, function(m) if echo then echo(m, "yellow") end end)
   if type(t) == "table" then
      local tt = t
      if tt.rooms then
         P.rooms = tt.rooms or {}
         P.dir_deltas = tt.dir_deltas or {}
         P.memories = tt.memories or {}
         P.waypoints = tt.waypoints or {}
         P.wp_room = tt.wp_room or {}
         P.room_wp = tt.room_wp or {}
         if echo then echo(string.format("[map] loaded %d rooms, %d waypoints from explored.lua.",
count_map(P.rooms), count_map(P.waypoints)), "cyan") end
      end
   end
end


local function coord_key(c) return c[1] .. "," .. c[2] .. "," .. c[3] .. "," .. c[4] end



























































if rx then
   rx.fromTrigger([[^kxw[tq]_rvnum (-?\d+) -?\d+ -?\d+ (-?\d+) (-?\d+) (-?\d+) (\d+)]]):subscribe(function(c)



      if not P.kxwt_live and echo then
         echo("[map] kxwt telemetry is LIVE — real room ids/coords, navigation restored.", "brightgreen")
      end
      P.kxwt_live = os.time()
      pilot_room_change(tonumber(c[1]), { tonumber(c[2]), tonumber(c[3]), tonumber(c[4]), tonumber(c[5]) })
   end)
   rx.fromTrigger([[^kxw[tq]_rshort (.+)$]]):subscribe(function(c) pilot_room_name(c[1]) end)


   rx.fromTrigger([[^kxw[tq]_terrain (\d+)]]):subscribe(function(c)
      local id = P.current_room
      if id and P.rooms[id] and P.rooms[id].terrain ~= tonumber(c[1]) then
         P.rooms[id].terrain = tonumber(c[1]); schedule_save()
      end
   end)

   rx.fromTrigger([[^kxw[tq]_waypoint]]):subscribe(function(c)
      local id = P.current_room
      if id and P.rooms[id] and not P.rooms[id].waypoint then P.rooms[id].waypoint = true; schedule_save() end
   end)

   rx.fromTrigger([[^You have been KILLED]]):subscribe(function(c) mark_death() end)


   rx.fromTrigger([[.*]]):subscribe(function(c) pilot_observe((c).line) end)
else


   trigger([[^kxw[tq]_rvnum (-?\d+) -?\d+ -?\d+ (-?\d+) (-?\d+) (-?\d+) (\d+)]], function(_, vnum, x, y, z, plane)
      pilot_room_change(tonumber(vnum), { tonumber(x), tonumber(y), tonumber(z), tonumber(plane) })
   end)
   trigger([[^kxw[tq]_rshort (.+)$]], function(_, n) pilot_room_name(n) end)
   trigger([[^kxw[tq]_terrain (\d+)]], function(_, t)
      local id = P.current_room
      if id and P.rooms[id] and P.rooms[id].terrain ~= tonumber(t) then
         P.rooms[id].terrain = tonumber(t); schedule_save()
      end
   end)
   trigger([[^kxw[tq]_waypoint]], function()
      local id = P.current_room
      if id and P.rooms[id] and not P.rooms[id].waypoint then P.rooms[id].waypoint = true; schedule_save() end
   end)
   trigger([[^You have been KILLED]], function() mark_death() end)
   trigger([[.*]], function(line) pilot_observe(line) end)
end


function pilot_room_change(id, coord)
   local from_id = P.current_room
   local from = from_id and P.rooms[from_id] and P.rooms[from_id].coord
   local is_new = (P.rooms[id] == nil)
   P.rooms[id] = P.rooms[id] or { exits = {}, moves = {} }
   P.rooms[id].coord = coord
   if state and state.area then P.rooms[id].area = state.area end







   local dir = P.last_move_dir
   local from_room = from_id and P.rooms[from_id]
   local moved = from and (coord[1] ~= from[1] or coord[2] ~= from[2] or
   coord[3] ~= from[3] or coord[4] ~= from[4])
   if dir and from_room and moved and from_room.exits[dir] then
      P.rooms[from_id].moves[dir] = id
      if OPP[dir] then P.rooms[id].moves[OPP[dir]] = from_id end
      if from[4] == coord[4] then
         local d = { coord[1] - from[1], coord[2] - from[2], coord[3] - from[3] }
         P.dir_deltas[dir] = d
         if OPP[dir] then P.dir_deltas[OPP[dir]] = { -d[1], -d[2], -d[3] } end
      end
   end


   if id ~= from_id then P.recent_cmds = {}; P.loop_breaks = 0 end



   if is_new then P.moves_since_new = 0; P.auto_streak = 0
   elseif id ~= from_id then P.moves_since_new = (P.moves_since_new or 0) + 1 end
   if id ~= from_id then P.last_move_dir = nil end
   if id ~= from_id then
      P.room_trail[#P.room_trail + 1] = id
      while #P.room_trail > 8 do table.remove(P.room_trail, 1) end
   end
   P.current_room = id


   if id ~= from_id and roomChangeS then roomChangeS:onNext(id) end








   if P.wp_pending and moved then learn_waypoint(P.wp_pending, id); P.wp_pending = nil end
   table.insert(P.transcript, "--- [MOVED to a NEW room. Everything above is a PREVIOUS room — creatures and items there are gone; act only on what's below.] ---")
   P.input_seq = P.input_seq + 1
   trim_transcript(); schedule_save()


   if P.goto_bridge and id ~= from_id then
      after(0.4, function() if P.goto_bridge then goto_bridge_advance() end end)
   end
   if P.nav then nav_step() end
end

function pilot_room_name(n)
   local id = P.current_room
   if not id then return end
   P.rooms[id] = P.rooms[id] or { exits = {}, moves = {} }
   if P.rooms[id].name ~= n then P.rooms[id].name = n; schedule_save() end
end














local function smap_rows(raw)
   local rows = {}
   for line in (raw .. "\n"):gmatch("([^\n]*)\n") do rows[#rows + 1] = (line:gsub("\r$", "")) end
   while #rows > 0 and rows[#rows] == "" do rows[#rows] = nil end
   return rows
end



local function decode_smap_cell(c4)
   local c0, c1, c2 = c4:byte(1) - 0x40, c4:byte(2) - 0x40, c4:byte(3) - 0x40
   return (c0 << 12) | (c1 << 6) | c2
end

















local function smap_coord_grid(raw)
   local rows = smap_rows(raw)
   local i, n = 1, #rows
   local best = nil
   while i <= n do
      local w = #rows[i]
      local j = i
      while j <= n and #rows[j] == w do j = j + 1 end
      if w >= 32 and (j - i) >= 6 and (not best or w > best.w) then best = { i = i, j = j - 1, w = w } end
      i = j
   end
   if not best then return nil end
   local grid = {}
   for r = best.i, best.j do
      local line, row = rows[r], {}
      for c = 1, best.w, 4 do
         local cell = line:sub(c, c + 3)
         row[#row + 1] = (#cell == 4) and decode_smap_cell(cell) or 0
      end
      grid[#grid + 1] = row
   end
   local h, w = #grid, #grid[1]
   return { grid = grid, h = h, w = w, center_r = math.floor(h / 2) + 1, center_c = math.floor(w / 2) + 1 }
end












(_AIP).smap = (_AIP).smap or ({ abs = {}, cur = nil, cur_xy = nil, prev_grid = nil })
local SM = (_AIP).smap

local function smap_grid_find(grid, id)
   for r, row in ipairs(grid) do
      for c, v in ipairs(row) do
         if v == id then return r, c end
      end
   end
   return nil
end








local function smap_apply(g)
   local grid, center_r, center_c = g.grid, g.center_r, g.center_c
   local C = grid[center_r] and grid[center_r][center_c] or 0
   if C == 0 then return end

   if SM.cur == nil then
      SM.cur_xy = SM.cur_xy or { 0, 0 }
   elseif C ~= SM.cur then
      local r
      local c
      if SM.prev_grid then r, c = smap_grid_find(SM.prev_grid.grid, C) end
      if r then


         SM.cur_xy = { SM.cur_xy[1] + (c - SM.prev_grid.center_c), SM.cur_xy[2] + (SM.prev_grid.center_r - r) }
      elseif SM.abs[C] then
         SM.cur_xy = { SM.abs[C][1], SM.abs[C][2] }
      end
   end





   local changed = (C ~= SM.cur) or (P.current_room ~= C)
   SM.cur, SM.prev_grid = C, g
   for r, row in ipairs(grid) do
      for c, id in ipairs(row) do
         if id ~= 0 then SM.abs[id] = { SM.cur_xy[1] + (c - center_c), SM.cur_xy[2] + (center_r - r) } end
      end
   end

   if changed then pilot_room_change(C, { SM.cur_xy[1], SM.cur_xy[2], 0, 0 }) end
end




function kxwt_live()
   return P.kxwt_live ~= nil and (os.time() - P.kxwt_live) < 60
end

function smap_on_map_update()
   if kxwt_live() then return end
   if not (state and state.dclient_map) then return end
   local g = smap_coord_grid(state.dclient_map)
   if g then smap_apply(g) end
end

local function parse_exits(line)
   local lower = line:lower()
   local body = lower:match("%[exits:(.-)%]") or lower:match("obvious exits:(.+)")
   if not body then return nil end
   local set = {}
   local found_any = false
   for w in body:gmatch("%a+") do
      local c = CANON[w]; if c then set[c] = true; found_any = true end
   end
   return found_any and set or nil
end




local function has_frontier(rid)
   local r = P.rooms[rid]
   if not r then return false end
   for d in pairs(r.exits) do
      if not r.moves[d] and not (r.blocked and r.blocked[d]) then return true end
   end
   return false
end





local function has_mark(r, label)
   if not r or not r.marks then return false end
   for m in pairs(r.marks) do if m == label or m:find(label, 1, true) then return true end end
   return false
end



local function marks_list()
   local by_label = {}
   local order = {}
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








local function parse_waypoint_line(line)
   local num, br, name = line:match("^%s*(%d+)%s*%(bridge%s+(%d+)%)%s*%-%s*(.+)$")
   if num then return { num = tonumber(num), name = trim(name), bridge = tonumber(br), reachable = false } end
   num, name = line:match("^%s*(%d+)%s*%(no bridge%)%s*%-%s*(.+)$")
   if num then return { num = tonumber(num), name = trim(name), bridge = nil, reachable = false } end
   num, name = line:match("^%s*(%d+)%s*%-%s*(.+)$")
   if num then return { num = tonumber(num), name = trim(name), bridge = nil, reachable = true } end
   return nil
end


local function parse_waypoint_list(text)
   local out = {}
   for line in (text .. "\n"):gmatch("(.-)\n") do
      local e = parse_waypoint_line(line)
      if e then out[#out + 1] = e end
   end
   return out
end



local function recall_failed(line)
   return line:find("No god responds to your call", 1, true) ~= nil
end





local function waypoint_cmd_num(cmd)
   local n = cmd:match("^way%a*%s+(%d+)%s*$")
   return n and tonumber(n) or nil
end






local MM_VEC = { north = { 0, -1 }, south = { 0, 1 }, east = { 1, 0 }, west = { -1, 0 },
northeast = { 1, -1 }, northwest = { -1, -1 }, southeast = { 1, 1 }, southwest = { -1, 1 }, }





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


local GEO = { ["0,-1"] = "north", ["0,1"] = "south", ["1,0"] = "east", ["-1,0"] = "west",
["1,-1"] = "northeast", ["-1,-1"] = "northwest", ["1,1"] = "southeast", ["-1,1"] = "southwest", }



local TERRAIN_COLOR = {
   [1] = "white", [2] = "white", [28] = "brightwhite", [26] = "brightblack",
   [3] = "green", [8] = "green", [15] = "green",
   [4] = "brightgreen", [5] = "green", [6] = "green", [17] = "brightgreen", [34] = "green",
   [7] = "magenta", [29] = "magenta", [38] = "magenta",
   [9] = "yellow", [12] = "yellow", [16] = "yellow", [14] = "brightyellow", [30] = "yellow",
   [10] = "brightblack", [11] = "brightblack", [33] = "brightblack",
   [13] = "brightwhite", [24] = "brightcyan",
   [18] = "blue", [19] = "brightblue", [20] = "blue", [21] = "blue", [32] = "blue",
   [22] = "brightblack", [27] = "brightblack", [35] = "green", [37] = "brightblack",
   [23] = "brightcyan", [31] = "brightwhite",
   [25] = "brightred",
   [36] = "brightmagenta", [39] = "brightcyan",
}







function minimap(hw, hh)
   hw, hh = hw or 3, hh or 2
   local cur = P.current_room
   if not cur or not P.rooms[cur] then return nil end


   local pos = {}
   local order = { cur }
   local occ = { ["0,0"] = true }
   local unexplored = {}
   pos[cur] = { 0, 0 }
   local function claim(id, gx, gy)
      if math.abs(gx) > hw or math.abs(gy) > hh then return false end
      local key = gx .. "," .. gy
      if occ[key] then return false end
      occ[key] = true; pos[id] = { gx, gy }; order[#order + 1] = id; return true
   end

   local rc = P.rooms[cur].coord
   if rc and rc[1] then





      local cx, cy, cz, cpl = rc[1], rc[2], rc[3], rc[4]


      local BOX = 4096
      local raw = {}
      for id, room in pairs(P.rooms) do
         if id ~= cur then
            local c = room.coord
            if c and c[1] and c[4] == cpl and c[3] == cz then
               local dx, dy = c[1] - cx, c[2] - cy
               if math.abs(dx) <= BOX and math.abs(dy) <= BOX then
                  raw[id] = { dx, dy }
               end
            end
         end
      end


      local unit
      for _, o in pairs(raw) do
         local ax, ay = math.abs(o[1]), math.abs(o[2])
         if ax > 0 and (not unit or ax < unit) then unit = ax end
         if ay > 0 and (not unit or ay < unit) then unit = ay end
      end
      unit = unit or 1
      local ids = {}
      for id in pairs(raw) do ids[#ids + 1] = id end
      table.sort(ids)
      for _, id in ipairs(ids) do
         local o = raw[id]

         claim(id, math.floor(o[1] / unit + 0.5), math.floor(-o[2] / unit + 0.5))
      end



      if SM.abs and not (kxwt_live and kxwt_live()) then
         local uids = {}
         for id in pairs(SM.abs) do if id ~= cur and not P.rooms[id] then uids[#uids + 1] = id end end
         table.sort(uids)
         for _, id in ipairs(uids) do
            local a = SM.abs[id]
            local dx, dy = a[1] - cx, a[2] - cy
            if math.abs(dx) <= BOX and math.abs(dy) <= BOX then
               local gx = math.floor(dx / unit + 0.5)
               local gy = math.floor(-dy / unit + 0.5)
               if math.abs(gx) <= hw and math.abs(gy) <= hh then
                  local key = gx .. "," .. gy
                  if not occ[key] then occ[key] = true; unexplored[#unexplored + 1] = { gx, gy } end
               end
            end
         end
      end
   else

      local queue = { cur }
      local head = 1
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




   for _, id in ipairs(order) do
      local a = pos[id]; local col, row = node_xy(a); local r = P.rooms[id]
      for _, nb in pairs(r.moves or {}) do
         local b = pos[nb]
         if b and not (b[1] == a[1] and b[2] == a[2]) then
            local gdx, gdy = b[1] - a[1], b[2] - a[2]
            if math.max(math.abs(gdx), math.abs(gdy)) == 1 then
               local link = MM_LINK[GEO[gdx .. "," .. gdy]]
               if link then for _, c in ipairs(link) do put(col + (c[1]), row + (c[2]), c[3], "brightblack", false) end end
            elseif gdy == 0 then
               local sx = sign(gdx)
               for c = col + sx, col + 4 * gdx - sx, sx do put(c, row, "─", "brightblack", false) end
            elseif gdx == 0 then
               local sy = sign(gdy)
               for rr = row + sy, row + 2 * gdy - sy, sy do put(col, rr, "│", "brightblack", false) end
            end
         end
      end
   end




   for _, id in ipairs(order) do
      local col, row = node_xy(pos[id]); local r = P.rooms[id]
      for d in pairs(r.exits or {}) do
         local s = MM_STUB[d]
         if s and not (r.blocked and r.blocked[d]) then
            local sc, sr = col + (s[1]), row + (s[2])
            if not (cells[sr] and cells[sr][sc]) then
               put(sc, sr, s[3], (r.moves and r.moves[d]) and "brightblack" or "brightgreen", false)
            end
         end
      end
   end



   for _, g in ipairs(unexplored) do
      local col, row = node_xy(g)
      put(col, row, "□", "brightblack", false)
   end


   for _, id in ipairs(order) do
      if id ~= cur then
         local col, row = node_xy(pos[id]); local r = P.rooms[id]
         if r.marks and next(r.marks) then put(col, row, "★", "brightgreen", true)
         elseif r.waypoint then put(col, row, "ᴡ", "brightmagenta", true)
         else put(col, row, has_frontier(id) and "▣" or "□", TERRAIN_COLOR[r.terrain] or "cyan", false) end
      end
   end
   local cc, cr = node_xy(pos[cur])
   put(cc, cr, "◉", "brightyellow", true)
   return { w = W, h = H, cells = cells }
end









local function nearest_unexplored()
   local start = P.current_room
   if not start or not P.rooms[start] then return nil end
   local seen = { [start] = true }
   local queue = {}
   local head = 1
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









local function find_path_from(start, matches)
   if not start or not P.rooms[start] then return nil end
   local seen = { [start] = true }
   local queue = { { id = start, path = {} } }
   local head = 1
   while head <= #queue do
      local n = queue[head]; head = head + 1
      local r = P.rooms[n.id]
      for d, nb in pairs(r and r.moves or {}) do

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

local function find_path(matches) return find_path_from(P.current_room, matches) end






local function nearest_reachable_to_coord(coord)
   if not coord then return nil end
   local start = P.current_room
   if not start or not P.rooms[start] then return nil end
   local seen = { [start] = true }
   local queue = { start }
   local head = 1
   local best
   local best_d
   while head <= #queue do
      local id = queue[head]; head = head + 1
      local r = P.rooms[id]
      if id ~= start and r and r.coord then
         local c = r.coord
         local dp = (c[4] ~= coord[4]) and 1e9 or 0
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


local WP_ALIASES = { waypoint = true, waypoints = true, wp = true }




local function nearest_waypoint_for(label)
   local best_len
   local best_id
   for id, r in pairs(P.rooms) do
      if r.waypoint then
         if has_mark(r, label) then return id end
         local path = find_path_from(id, function(x) return x ~= id and has_mark(P.rooms[x], label) end)
         if path and (not best_id or #path < best_len) then best_len, best_id = #path, id end
      end
   end
   return best_id
end








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









local function learn_waypoint(num, id)
   if not num or not id or not P.rooms[id] then return end
   P.wp_room = P.wp_room or {}
   P.room_wp = P.room_wp or {}

   local prev = P.wp_room[num]
   if prev and prev ~= id then P.room_wp[prev] = nil end
   P.wp_room[num] = id
   P.room_wp[id] = num
   P.rooms[id].waypoint = true
   schedule_save()
end


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




local function path_to_unexplored()
   local here = untaken_exit(P.current_room)
   if here then return { here } end
   local path, dest = find_path(function(id) return id ~= P.current_room and has_frontier(id) end)
   if not path then return nil end
   local exit = untaken_exit(dest)
   if exit then path[#path + 1] = exit end
   return path
end




local function resolve_nav(dest)
   local d = trim(dest or ""):lower()
   if d == "" or d == "unexplored" or d == "new" or d == "frontier" or d:find("explore", 1, true) then
      return function(id) return id ~= P.current_room and has_frontier(id) end, "unexplored ground"
   end
   return function(id)
      local r = P.rooms[id]
      if not r or id == P.current_room then return false end
      if has_mark(r, d) then return true end
      if r.area and r.area:lower():find(d, 1, true) then return true end
      if r.name and r.name:lower():find(d, 1, true) then return true end
      return false
   end, d
end




local function best_explore_dir()
   local r = P.current_room and P.rooms[P.current_room]
   if not r or not r.exits then return nil end
   local blocked = r.blocked or {}

   local untaken = {}
   for d in pairs(r.exits) do
      if not r.moves[d] and not blocked[d] then untaken[#untaken + 1] = d end
   end
   if #untaken > 0 then table.sort(untaken); return untaken[1] end


   local dir = nearest_unexplored()
   if dir and r.exits[dir] and not blocked[dir] then return dir end
   return nil
end

local function exploration_summary()
   local count = 0; for _ in pairs(P.rooms) do count = count + 1 end
   local lines = {}
   if count > 0 then lines[#lines + 1] = "Rooms explored this session: " .. count .. "." end


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
      local infos = {}
      local current_frontier = false
      for _, dir in ipairs(dirs) do
         if here.moves[dir] then

            local dest = P.rooms[here.moves[dir]]
            infos[#infos + 1] = dir .. " → " .. ((dest and dest.name) or "a visited room") .. " (explored)"
         else

            local delta = P.dir_deltas[dir]
            local name = delta and here.coord and
            visited[coord_key({ here.coord[1] + delta[1], here.coord[2] + delta[2],
here.coord[3] + delta[3], here.coord[4], })]
            if name then
               infos[#infos + 1] = dir .. " → " .. name .. " (explored)"
            else
               infos[#infos + 1] = dir .. " → UNEXPLORED"; current_frontier = true
            end
         end
      end
      lines[#lines + 1] = "Exits from your current room: " .. table.concat(infos, ", ")

      if not current_frontier then
         local dir, dist = nearest_unexplored()
         if dir then
            lines[#lines + 1] = "Nothing new in this room. The nearest unexplored area is ~" .. dist ..
            " room(s) away — move " .. dir .. " toward it."
         else
            lines[#lines + 1] = "This room is fully explored, and your known map has no unexplored exits left."
         end
      end
   end


   local ml = marks_list()
   if ml ~= "" then
      lines[#lines + 1] = "Marked places (navigate('<label>') routes to the nearest):\n" .. ml
   end



   local wpn = {}
   for n in pairs(P.waypoints or {}) do wpn[#wpn + 1] = n end
   if #wpn > 0 then
      table.sort(wpn)
      local wl = {}
      for _, n in ipairs(wpn) do
         local w = P.waypoints[n]
         wl[#wl + 1] = "  " .. n .. " - " .. w.name .. (w.reachable and "" or " (out of range" ..
         (w.bridge and (", bridge via " .. w.bridge) or "") .. ")")
      end
      lines[#lines + 1] = "Waypoints you can travel between (command 'waypoint <n>' from a waypoint room):\n" ..
      table.concat(wl, "\n")
   end
   return table.concat(lines, "\n")
end


local function remember(text)
   text = trim(text)
   if text == "" then return end
   local low = text:lower()
   for _, m in ipairs(P.memories) do if m.text:lower() == low then return end end
   P.memories[#P.memories + 1] = { text = text, area = state and state.area, room = P.current_room }
   while #P.memories > 120 do table.remove(P.memories, 1) end
   echo("[ai] ✎ remembered: " .. text)
   schedule_save()
end



local function memory_summary()
   if #P.memories == 0 then return "" end
   local here = {}
   local other = {}
   local area = state and state.area
   for _, m in ipairs(P.memories) do
      if area and m.area == area then here[#here + 1] = m.text else other[#other + 1] = m.text end
   end
   local lines = {}
   for _, t in ipairs(here) do lines[#lines + 1] = "- " .. t end
   for i = #other, 1, -1 do if #lines >= 15 then break end; lines[#lines + 1] = "- " .. other[i] end
   return table.concat(lines, "\n")
end


local function arm()
   if not P.enabled then return end
   P.gen = P.gen + 1
   local g = P.gen
   after(cfg.quiet, function() fire_if_ready(g) end)
end



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
   line = line:gsub("\27%[[%d;]*%a", "")
   local t = trim(line)
   if t:lower():find("cannot go that way", 1, true) then block_last_move() end



   if recall_failed(t) and recallFizzleS then recallFizzleS:onNext(nil) end


   local wpe = parse_waypoint_line(t)
   if wpe then P.waypoints = P.waypoints or {}; P.waypoints[wpe.num] = wpe; schedule_save() end


   if t == "" or t:match("^kxw[tq]_") then return end
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




   local wn = waypoint_cmd_num(cmd)
   if wn then
      P.wp_pending = wn


      if cancel and P.wp_timer then cancel(P.wp_timer) end
      P.wp_timer = after(8, function() P.wp_pending = nil end)
   end

   if (P.self_sent[cmd] or 0) > 0 then P.self_sent[cmd] = P.self_sent[cmd] - 1; return end
   if CANON[cmd:lower()] then P.last_move_dir = CANON[cmd:lower()] end


   if log_human_demo then log_human_demo(cmd) end
   table.insert(P.transcript, "[the human typed] " .. cmd)
   P.input_seq = P.input_seq + 1
   P.last_human = os.time()
   trim_transcript()
end









local TEXT_SYS = "You are an expert player of the MUD Alter Aeon, driving a character live. Each turn you " ..
"receive the character's STATE and recent game OUTPUT. Decide the single best next action and TAKE IT " ..
"BY CALLING ONE TOOL. ONE action per turn, then wait for the result. Prefer the specific tools " ..
"(move, attack, cast, get, drop, wear, put, recover, stand, look, inventory, flee); use `command` for " ..
"anything they don't cover (spells, skills, train, buy, list); use `wait` to do nothing. In combat, " ..
"attack or cast to deal damage, recover when hurt, flee if losing. ACT, don't talk — your reply must " ..
"BE a tool call, not a sentence describing it."










local G = _G
local function describe_state_dyn() return (G.describe_state)() end
local function game_command_reference_dyn()
   local f = G.game_command_reference
   return f and f() or nil
end

local function system_prompt()
   if not cfg.use_tools then return TEXT_SYS end


   local ref = ""
   local gcr = G.game_command_reference
   if type(gcr) == "function" then
      local ok, r = pcall(game_command_reference_dyn)
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
   local manual_block = (cfg.use_rag and P.manual ~= "") and
   ("\n=== RELEVANT GAME MANUAL (retrieved from the docs for THIS situation — rely on it) ===\n" .. P.manual .. "\n") or ""



   local dir_block = directive and ("\n=== DIRECTOR NOTE (the human just told you this — act on it now) ===\n" .. directive .. "\n") or ""
   local nudge_block = nudge and ("\n=== AUTO NOTE (generated by the game client, NOT from the human) ===\n" .. nudge .. "\n") or ""




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
















local DMG_TIER = { minor = 1, low = 2, moderate = 3, high = 4, massive = 5 }


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



local function combat_spell_line(known, limit)
   local ranked = damage_spells_ranked(known)
   if #ranked == 0 then return nil end
   local names = {}
   for i = 1, math.min(#ranked, limit or 6) do names[#names + 1] = ranked[i].name end
   return "YOUR DAMAGE SPELLS (cast one, exact name): " .. table.concat(names, ", ")
end



local function best_damage_spell(known, cur_mana)
   local ranked = damage_spells_ranked(known)
   if #ranked == 0 then return nil end
   for _, s in ipairs(ranked) do if (s.mana or 0) <= (cur_mana or 0) then return s end end
   local cheapest = ranked[1]
   for _, s in ipairs(ranked) do if (s.mana or 1e9) < (cheapest.mana or 1e9) then cheapest = s end end
   return cheapest
end



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





local function combat_substitute(cmd, known, cur_mana)
   if not (type(cmd) == "string") then return cmd end
   if #damage_spells_ranked(known) == 0 then return cmd end
   local verb = (cmd:match("^(%S+)") or ""):lower()
   local is_melee = (verb == "kill" or verb == "attack" or verb == "k")
   local rest = cmd:match("^%S+%s+(.+)$")
   if verb == "cast" or verb == "c" then
      if rest and names_known_spell(rest, known) then return cmd end
   elseif not is_melee then
      return cmd
   end
   local best = best_damage_spell(known, cur_mana)
   if not best then return cmd end
   local tgt = combat_target(cmd)
   return "cast '" .. best.name .. "'" .. (tgt ~= "" and (" " .. tgt) or "")
end








local function build_combat_user(st, world, convo, directive)
   local world_block = (world and world ~= "") and ("\n=== WHAT'S HERE ===\n" .. world .. "\n") or ""
   local dir_block = directive and ("\n=== DIRECTOR NOTE (act on it now) ===\n" .. directive .. "\n") or ""
   local spell_line = combat_spell_line(state.spells_known, nil)
   local spell_block = spell_line and ("\n" .. spell_line) or ""
   return "=== CHARACTER STATE ===\n" .. st .. world_block ..
   "\n=== RECENT GAME OUTPUT ===\n" .. convo .. "\n" .. dir_block .. spell_block ..
   "\nYou are IN COMBAT — call attack or cast NOW. No reasoning."
end


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








local json = {}
function json.encode(v)
   local t = type(v)
   if t == "nil" then return "null"
   elseif t == "boolean" then return tostring(v)
   elseif t == "number" then return tostring(v)
   elseif t == "string" then return '"' .. json_escape(v) .. '"'
   elseif t == "table" then
      local n = 0; for _ in pairs(v) do n = n + 1 end
      if n == 0 then return "{}" end
      local vt = v
      if #vt == n then
         local parts = {}
         for _, x in ipairs(vt) do parts[#parts + 1] = json.encode(x) end
         return "[" .. table.concat(parts, ",") .. "]"
      end
      local parts = {}
      for k, x in pairs(v) do parts[#parts + 1] = '"' .. json_escape(tostring(k)) .. '":' .. json.encode(x) end
      return "{" .. table.concat(parts, ",") .. "}"
   end
   return "null"
end

function json.decode(s)
   if not (type(s) == "string") then return nil end
   local str = s
   local i = 1
   local parse_value
   local function skip() while i <= #str and str:sub(i, i):match("%s") do i = i + 1 end end
   local function parse_string()
      i = i + 1
      local buf = {}
      while i <= #str do
         local c = str:sub(i, i)
         if c == '"' then i = i + 1; return table.concat(buf)
         elseif c == "\\" then
            local n = str:sub(i + 1, i + 1)
            if n == "u" then
               local code = tonumber(str:sub(i + 2, i + 5), 16) or 0; i = i + 6
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
      if str:sub(i, i) == "}" then i = i + 1; return obj end
      while true do
         skip(); local key = parse_string(); skip(); i = i + 1
         skip(); obj[key] = parse_value(); skip()
         local c = str:sub(i, i); i = i + 1
         if c == "}" or c ~= "," then break end
      end
      return obj
   end
   local function parse_array()
      i = i + 1; local arr = {}; skip()
      if str:sub(i, i) == "]" then i = i + 1; return arr end
      while true do
         skip(); arr[#arr + 1] = parse_value(); skip()
         local c = str:sub(i, i); i = i + 1
         if c == "]" or c ~= "," then break end
      end
      return arr
   end
   parse_value = function()
      skip()
      local c = str:sub(i, i)
      if c == '"' then return parse_string()
      elseif c == "{" then return parse_object()
      elseif c == "[" then return parse_array()
      elseif c == "t" then i = i + 4; return true
      elseif c == "f" then i = i + 5; return false
      elseif c == "n" then i = i + 4; return nil
      else
         local num = str:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
         if num and #num > 0 then i = i + #num; return tonumber(num) end
         i = i + 1; return nil
      end
   end
   local ok, result = pcall(parse_value)
   if ok then return result end
   return nil
end






local DIRECTIONS = { "north", "south", "east", "west", "up", "down",
"northeast", "northwest", "southeast", "southwest", }
local SETTLE = { rest = true, sleep = true, sit = true, meditate = true, nap = true }
local MOVE = { n = true, s = true, e = true, w = true, u = true, d = true, ne = true, nw = true,
se = true, sw = true, north = true, south = true, east = true, west = true, up = true, down = true,
northeast = true, northwest = true, southeast = true, southwest = true, }
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
build = function(a) return a.direction end, },
   { name = "navigate", ends_turn = true, nav = true,
desc = "Auto-walk a whole route across rooms you've ALREADY explored. Give an area or room name " ..
"(e.g. 'the cemetery', 'town hall'), or 'unexplored' to head to the nearest place with " ..
"unexplored exits. Use this instead of stepping one direction at a time when crossing known " ..
"ground or when you feel stuck — the script walks the route and stops if combat starts.",
props = { destination = { type = "string", description = "area/room name you've visited, or 'unexplored'" } },
required = { "destination" }, },
   { name = "attack",
desc = "Start attacking a MONSTER in this room (never another player).",
props = { target = { type = "string", description = "short keyword for the creature, e.g. 'goblin'" } },
required = { "target" },
build = function(a) return "kill " .. (a.target) end, },
   { name = "cast",
desc = "Cast a spell. Give the spell's exact full name; a target keyword if it needs one. Cast an attack spell only when there's an enemy (in combat, target is optional — it hits what you're fighting).",
props = { spell = { type = "string", description = "exact full spell name, e.g. 'shower of sparks'" },
target = { type = "string", description = "optional target keyword" }, },
required = { "spell" },
build = function(a) return "cast '" .. trim(a.spell) .. "'" .. opt(a.target) end, },
   { name = "get",
desc = "Pick up an item from the room or a container.",
props = { item = { type = "string", description = "short keyword for the item" },
container = { type = "string", description = "optional container to take it from" }, },
required = { "item" },
build = function(a) return "get " .. (a.item) .. opt(a.container) end, },
   { name = "put",
desc = "Put an item into a container/bag.",
props = { item = { type = "string" }, container = { type = "string" } },
required = { "item", "container" },
build = function(a) return "put " .. (a.item) .. " in " .. (a.container) end, },
   { name = "drop",
desc = "Drop an item you are carrying.",
props = { item = { type = "string" } }, required = { "item" },
build = function(a) return "drop " .. (a.item) end, },
   { name = "wear",
desc = "Wear or wield a piece of equipment.",
props = { item = { type = "string" } }, required = { "item" },
build = function(a) return "wear " .. (a.item) end, },
   { name = "recover", ends_turn = true,
desc = "Rest or sleep to recover hp/mana/stamina (only when no enemy is here). This is your whole turn; then wait.",
props = { method = { type = "string", enum = { "rest", "sleep" }, description = "sleep recovers fastest; rest stays alert" } },
required = { "method" },
build = function(a) return a.method end, },
   { name = "stand",
desc = "Stand up after resting/sleeping, once your state shows you are recovered.",
props = {}, build = function(a) return "stand" end, },
   { name = "look",
desc = "Look at the current room, or at a specific thing.",
props = { at = { type = "string", description = "optional thing to look at" } },
build = function(a) return "look" .. opt(a.at) end, },
   { name = "inventory",
desc = "List what you are carrying.",
props = {}, build = function(a) return "inventory" end, },
   { name = "flee", ends_turn = true,
desc = "Flee from combat.",
props = {}, build = function(a) return "flee" end, },
   { name = "command",
desc = "Run any other game command verbatim (spells, skills, help, train, buy, list, etc.). Use ONLY when no specific tool fits.",
props = { text = { type = "string", description = "the exact command line to send" } },
required = { "text" },
build = function(a) return a.text end, },
   { name = "wait",
desc = "Do nothing this turn (e.g. while recovering). No command is sent.",
props = {}, build = function(a) return nil end, },
   { name = "remember", note = true,
desc = "Save a durable fact worth keeping all session (trainer/vendor location, which spell hits hardest, a good xp spot + level, a danger).",
props = { fact = { type = "string" } }, required = { "fact" }, },
   { name = "make_script", note = true,
desc = "Request a PERMANENT reflex you'll repeat all session (e.g. 'loot every corpse', 'flee under 30% hp'). Rare.",
props = { description = { type = "string" } }, required = { "description" }, },
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
["function"] = { name = t.name, description = t.desc, parameters = params }, }
   end
   tools_json_cache = json.encode(arr)
   return tools_json_cache
end


local function from_tool_calls(calls)
   local actions = {}
   local mems = {}
   local scripts = {}
   for _, call in ipairs(calls) do
      local rawargs = call.args
      local args = (type(rawargs) == "table") and rawargs or {}
      local fact = args.fact
      local descr = args.description
      local dest = args.destination
      if call.name == "remember" then
         if type(fact) == "string" then mems[#mems + 1] = fact end
      elseif call.name == "make_script" then
         if type(descr) == "string" then scripts[#scripts + 1] = descr end
      elseif call.name == "navigate" then
         actions[#actions + 1] = { nav = (type(dest) == "string") and dest or "", ends_turn = true }
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
      local spell, tgt = orig:match("'([^']+)'%s*(.*)$")
      if spell then
         tgt = trim(tgt or "")
         return "cast", (tgt ~= "" and { spell = spell, target = tgt } or { spell = spell })
      end
   end
   return "command", { text = orig }
end


local function request_script_change(req)
   local key = trim(req):lower()
   if P.requested[key] then return end
   P.requested[key] = true
   local f = io.open(cfg.dir .. "/.ai-script-requests.jsonl", "a")
   if f then f:write('{"request":"' .. json_escape(req) .. '"}\n'); f:close() end
   echo("[ai] ✎ requested a script change: \"" .. req .. "\" (queued; edit a script + pilot.reload() to apply)")
end


local function strip_fences(s)
   s = s:gsub("^[%s`*]+", ""):gsub("[%s`*]+$", "")
   s = s:gsub("%.+$", "")
   return (s:gsub("^[%s`*]+", ""):gsub("[%s`*]+$", ""))
end



function execute(actions, thoughts, scripts, mems)
   if #thoughts > 0 then echo("[ai] " .. table.concat(thoughts, " ")) end
   for i = 1, math.min(2, #mems) do remember(mems[i]) end
   if scripts[1] then request_script_change(scripts[1]) end


   for _, a in ipairs(actions) do
      if a.nav ~= nil then
         if P.enabled then start_navigation(a.nav) end
         return
      end
   end

   while #actions > cfg.max_cmds do table.remove(actions) end




   for i, a in ipairs(actions) do
      if a.ends_turn then
         for j = #actions, i + 1, -1 do table.remove(actions, j) end
         break
      end
   end




   local commands = {}
   for _, a in ipairs(actions) do
      local acmd = a.cmd
      if type(acmd) == "string" and trim(acmd) ~= "" then
         local cmd = acmd
         local verb = (cmd:match("^(%S+)") or ""):lower()
         local is_melee_cmd = (verb == "kill" or verb == "attack" or verb == "k")



         if in_combat() or is_melee_cmd then
            local sub = combat_substitute(cmd, state.spells_known, state.mana)
            if sub ~= cmd then echo("[ai] (cast real spell: `" .. cmd .. "` -> `" .. sub .. "`)"); cmd = sub end
         end
         commands[#commands + 1] = cmd
      end
   end






   local loop_cmd = nil
   local looping = false
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


      P.self_sent[c] = (P.self_sent[c] or 0) + 1
      local cdir = CANON[c:lower()]
      if cdir then P.last_move_dir = cdir end
      send(c)
   end
end









local PRIMARY_ARG = {
   move = "direction", attack = "target", cast = "spell", get = "item", put = "item",
   drop = "item", wear = "item", recover = "method", look = "at", command = "text",
   remember = "fact", make_script = "description", navigate = "destination",
}





local function normalize_call(obj)
   if not (type(obj) == "table") then return nil end
   local o = obj
   local name = o.name or o.action or o.call or o.tool or o.function_name
   if not (type(name) == "string") or trim(name) == "" then return nil end
   local nm = trim(name):lower()
   if nm == "kill" then nm = "attack" end

   local args = o.arguments or o.args or o.parameters
   if type(args) == "string" then local ok, d = pcall(json.decode, args); if ok then args = d end end
   if type(args) == "table" then return { name = nm, args = args } end

   local pk = PRIMARY_ARG[nm]
   if pk == nil then return { name = nm, args = {} } end
   local generic = o.text or o.spell or o.target or o.direction or o.item or
   o.destination or o.method or o.at or o.fact or o.value or o.arg
   if generic ~= nil then return { name = nm, args = { [pk] = generic } } end
   return nil
end



local function extract_calls(reply)
   if not (type(reply) == "string") then return {} end
   local objs = {}
   local found = false
   for block in reply:gmatch("<tool_call>(.-)</tool_call>") do
      found = true
      local ok, o = pcall(json.decode, trim(block)); if ok then objs[#objs + 1] = o end
   end
   if not found then
      local i, n = 1, #reply
      while true do
         local a = reply:find("{", i, true); if not a then break end
         local depth = 0
         local b = nil
         local instr, esc = false, false
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



function handle_reply(reply)
   reply = reply or ""
   local calls = extract_calls(reply)
   if #calls > 0 then
      local actions, mems, scripts = from_tool_calls(calls)
      execute(actions, {}, scripts, mems)
      return
   end
   local actions = {}
   local thoughts = {}
   local scripts = {}
   local mems = {}
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




local MEM_SYS = "You maintain compact structured state for an autonomous text-MUD player. You are " ..
"given the CURRENT state (JSON) and the most recent raw game output. Return the UPDATED state as " ..
"a single JSON object, nothing else, with keys: creatures_here (array of short keywords for " ..
"monsters/NPCs present in the CURRENT room right now), items_here (array of short keywords for " ..
"items on the ground here), inventory (array of items the player is carrying, only if the output " ..
"shows it; else keep the prior value), summary (one or two short sentences: what just happened " ..
"and the immediate objective). Rules: use SHORT keywords (the main noun) — 'kobold', not 'a thin " ..
"kobold standing here'. If the player MOVED to a new room, the previous room's creatures/items " ..
"are gone — reset them to what the new room shows. Never invent things not in the output. Output " ..
"ONLY the JSON object."


local function extract_json(s)
   if not (type(s) == "string") then return nil end
   local str = s
   local a = str:find("{", 1, true); if not a then return nil end
   local b = str:find("}[^}]*$"); if not b then b = #str end
   return json.decode(str:sub(a, b))
end

local function as_strings(v)
   local out = {}
   if type(v) == "table" then for _, x in ipairs(v) do if type(x) == "string" and trim(x) ~= "" then out[#out + 1] = trim(x) end end end
   return out
end



local function run_memory_head(done)
   if not cfg.use_memory then return done() end
   local user = "CURRENT STATE:\n" .. json.encode(P.world) .. "\n\nRECENT GAME OUTPUT:\n" .. current_room_slice(nil)
   ai_memory_request(MEM_SYS, user, 400, function(reply, err)
      if EPOCH ~= (_AIP).epoch then return end
      if err then
         P.mem_fail = P.mem_fail + 1
         echo("[ai] (memory head error: " .. err .. ")")
         if P.mem_fail >= 2 then cfg.use_memory = false
echo("[ai] memory head disabled — set ANTHROPIC_API_KEY or pilot.memkey('<key>'), then pilot.mem('on').") end
      else
         P.mem_fail = 0
         local t = extract_json(reply)
         if type(t) == "table" then
            local tt = t
            P.world.creatures = as_strings(tt.creatures_here)
            P.world.items = as_strings(tt.items_here)
            local inv = as_strings(tt.inventory)
            if #inv > 0 then P.world.inventory = inv end
            local summ = tt.summary
            if type(summ) == "string" then P.world.summary = trim(summ) end
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



local function rag_query()
   return current_room_slice(nil):sub(-700) .. "\nGoal: " .. P.goal
end
local function format_manual(chunks_json)
   local arr = json.decode(chunks_json)
   if not (type(arr) == "table") or #(arr) == 0 then return "" end
   local lines = {}
   for _, c in ipairs(arr) do if type(c) == "string" then lines[#lines + 1] = "- " .. (c) end end
   return table.concat(lines, "\n")
end





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


   nav.gen = (nav.gen or 0) + 1
   local g = nav.gen
   after(4, function()
      if EPOCH == (_AIP).epoch and P.nav and P.nav.gen == g then
         echo("[ai] (navigation stalled — handing back to you)"); P.nav = nil; P.nav_cooldown = os.time() + 12; arm()
      end
   end)
end

function start_navigation(dest)



   if os.time() < (P.nav_cooldown or 0) then
      echo("[ai] (navigation paused — a recent route failed; move manually for a moment)")
      arm(); return
   end
   local d = trim(dest or ""):lower()
   local path
   local desc
   if d == "" or d == "unexplored" or d == "new" or d == "frontier" or d:find("explore", 1, true) then
      path, desc = path_to_unexplored(), "unexplored ground"
   else
      local matches
      matches, desc = resolve_nav(dest); path = find_path(matches)
   end
   if not path or #path == 0 then
      echo("[ai] (no known route to '" .. desc .. "')")
      P.nudge = "There is no known route to '" .. desc .. "' in your explored map — explore toward it by " ..
      "taking unexplored exits, one at a time."
      arm(); return
   end
   echo("[ai] (routing to " .. desc .. " — " .. #path .. " steps)")
   P.nav = { path = path, idx = 1, dest = desc, gen = 0 }
   nav_step()
end





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









function noexit(args) return noexit_command(args) end
doc(noexit, { name = "noexit", sig = "noexit([dir])", group = "map",
text = "Block a direction out of the current room so explore()/navigate never route that way — for the " ..
"locked doors, guards and one-way exits the auto-detector (which only knows \"cannot go that " ..
"way\") misses. noexit() lists this room's blocks; noexit('clear <dir>') unblocks one; " ..
"noexit('clear') clears them all here. Per-room, persists with the map, hidden on the minimap.",
example = "noexit('north')   -- the north door is locked; stop routing through it", })
function noexit_command(args)
   args = trim(args or "")
   local id = P.current_room
   local r = id and P.rooms[id]
   if not r then echo("[noexit] no current room yet — move once so the map knows where you are."); return end

   if args == "" then
      local dirs = {}
      for d in pairs(r.blocked or {}) do dirs[#dirs + 1] = d end
      if #dirs == 0 then echo("[noexit] nothing blocked here. `noexit <dir>` blocks a direction (e.g. noexit north).")
      else table.sort(dirs); echo("[noexit] blocked out of " .. (r.name or "this room") .. ": " .. table.concat(dirs, ", ")) end
      return
   end

   local low = args:lower()
   if low == "clear" or low == "reset" or low == "clear all" then
      if r.blocked then r.blocked = nil; schedule_save(); echo("[noexit] cleared every block in " .. (r.name or "this room") .. ".")
      else echo("[noexit] nothing blocked here.") end
      return
   end

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

   local d = CANON[low]
   if not d then echo("[noexit] '" .. args .. "' isn't a direction. Use n/s/e/w/u/d/ne/nw/se/sw (or 'clear <dir>')."); return end
   r.blocked = r.blocked or {}
   if r.blocked[d] then echo("[noexit] " .. d .. " is already blocked here."); return end
   r.blocked[d] = true
   schedule_save()
   echo("[noexit] blocked " .. d .. " out of " .. (r.name or "this room") .. " — explore won't route that way. `noexit clear " .. d .. "` to undo.")
end


alias([[^noexit$]], function() noexit_command("") end)
alias([[^noexit (.+)$]], function(_, rest) noexit_command(rest) end)








function addexit(args) return addexit_command(args) end
doc(addexit, { name = "addexit", sig = "addexit([dir])", group = "map",
text = "Add a HIDDEN exit out of the current room so explore()/navigate will route through it — for the " ..
"secret doors and unlisted passages the game doesn't advertise (the opposite of noexit). " ..
"addexit() lists this room's added exits; addexit('clear <dir>') removes one; addexit('clear') " ..
"removes them all here. Per-room, persists with the map; also clears any noexit on that direction.",
example = "addexit('down')   -- an unlisted trapdoor leads down; let explore route through it", })
function addexit_command(args)
   args = trim(args or "")
   local id = P.current_room
   local r = id and P.rooms[id]
   if not r then echo("[addexit] no current room yet — move once so the map knows where you are."); return end

   if args == "" then
      local dirs = {}
      for d in pairs(r.added or {}) do dirs[#dirs + 1] = d end
      if #dirs == 0 then echo("[addexit] no hidden exits added here. `addexit <dir>` adds one (e.g. addexit down).")
      else table.sort(dirs); echo("[addexit] added exits out of " .. (r.name or "this room") .. ": " .. table.concat(dirs, ", ")) end
      return
   end

   local low = args:lower()
   if low == "clear" or low == "reset" or low == "clear all" then
      if r.added then
         for d in pairs(r.added) do if r.exits then r.exits[d] = nil end end
         r.added = nil; schedule_save(); echo("[addexit] removed every added exit in " .. (r.name or "this room") .. ".")
      else echo("[addexit] nothing added here.") end
      return
   end

   local un = args:match("^clear%s+(.+)$") or args:match("^remove%s+(.+)$") or args:match("^%-%s*(.+)$")
   if un then
      local d = CANON[trim(un):lower()]
      if not d then echo("[addexit] '" .. trim(un) .. "' isn't a direction."); return end
      if r.added and r.added[d] then
         r.added[d] = nil; if not next(r.added) then r.added = nil end
         if r.exits then r.exits[d] = nil end
         schedule_save(); echo("[addexit] removed the added " .. d .. " exit here.")
      else echo("[addexit] " .. d .. " wasn't an added exit here.") end
      return
   end

   local d = CANON[low]
   if not d then echo("[addexit] '" .. args .. "' isn't a direction. Use n/s/e/w/u/d/ne/nw/se/sw (or 'clear <dir>')."); return end
   r.added = r.added or {}
   if r.added[d] then echo("[addexit] " .. d .. " is already added here."); return end
   r.added[d] = true
   r.exits = r.exits or {}
   r.exits[d] = true
   if r.blocked then r.blocked[d] = nil; if not next(r.blocked) then r.blocked = nil end end
   schedule_save()
   echo("[addexit] added " .. d .. " out of " .. (r.name or "this room") .. " — explore may route that way now. `addexit clear " .. d .. "` to undo.")
end
alias([[^addexit$]], function() addexit_command("") end)
alias([[^addexit (.+)$]], function(_, rest) addexit_command(rest) end)










local SINGLETON_MARKS = { death = true, ["return"] = true }
local function drop_mark_everywhere(label)
   for _, rr in pairs(P.rooms) do
      if rr.marks and rr.marks[label] then
         rr.marks[label] = nil
         if not next(rr.marks) then rr.marks = nil end
      end
   end
end

function mark(label) return mark_command(label) end
doc(mark, { name = "mark", sig = "mark([label])", group = "map",
text = "Tag the current room with a landmark label; mark() lists all marks; mark('del <label>') removes one. Marks persist with the map, show as ★ on the minimap, and are travel()/navigate() targets. 'return' and 'death' are singletons — you only ever have one, so re-marking MOVES it here instead of adding a second.", })
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
   if SINGLETON_MARKS[label] then

      drop_mark_everywhere(label)
   elseif r.marks and r.marks[label] then
      echo("[mark] already marked '" .. label .. "'."); return
   end
   r.marks = r.marks or {}
   r.marks[label] = true
   schedule_save()
   echo("[mark] tagged " .. (r.name or "this room") .. (r.area and (" (" .. r.area .. ")") or "") ..
   " as '" .. label .. "'. `goto " .. label .. "` to return.")
end







function mark_death()
   local id = P.current_room
   local r = id and P.rooms[id]
   if not r or not r.coord then

      echo("\27[1;31m☠ you DIED — but the map hasn't placed this room, so I can't mark it (any earlier " ..
      "death mark is kept).\27[0m")
      return
   end

   drop_mark_everywhere("death")
   r.marks = r.marks or {}
   r.marks.death = true
   schedule_save()
   echo("\27[1;31m☠ you DIED at " .. (r.name or ("room " .. tostring(id))) ..
   (r.area and (" — " .. r.area) or "") .. ". `goto death` to return for your corpse.\27[0m")
end









local HOP_COST, RECALL_COST, BRIDGE_MIN_SAVINGS = 3, 5, 5





local function network_entry(here)
   if P.rooms[here] and P.rooms[here].waypoint then return 0, nil end
   local wpath = find_path_from(here, function(id) return id ~= here and P.rooms[id] and P.rooms[id].waypoint end)
   if wpath and #wpath > 0 and #wpath < RECALL_COST then return #wpath, wpath end
   return RECALL_COST, nil
end












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
entry_path = entry_path, final_leg = final_leg, }
end






















local function plan_goto_route(label)
   local here = P.current_room
   local walk_path = find_path_from(here, function(id) return id ~= here and has_mark(P.rooms[id], label) end)
   local walk_cost = (walk_path and #walk_path > 0) and #walk_path or math.huge

   local target_wp = nearest_waypoint_for(label)
   local be = bridge_estimate(here, label, target_wp)
   local function bridge_result()
      return { mode = "bridge", target_wp = target_wp, walk_cost = walk_cost, bridge_cost = be.cost,
entry_cost = be.entry_cost, entry_path = be.entry_path, final_leg = be.final_leg, }
   end

   if be and be.cost + BRIDGE_MIN_SAVINGS < walk_cost then return bridge_result() end
   if walk_path and #walk_path > 0 then return { mode = "walk", path = walk_path, walk_cost = walk_cost } end
   if be then return bridge_result() end

   local exists = false
   for _, r in pairs(P.rooms) do if has_mark(r, label) then exists = true; break end end
   return { mode = "none", reason = exists and "unreachable" or "unmarked" }
end









function human_goto(label)
   label = trim(label or ""):lower()
   if label == "" then echo("[goto] usage: travel('<mark>') or the game alias `goto <mark>`  (see mark(); travel('stop') cancels)"); return end
   if label == "stop" then
      P.goto_bridge = nil
      if P.nav then P.nav = nil; echo("[goto] stopped.") else echo("[goto] not navigating.") end
      return
   end
   if in_combat() then echo("[goto] not while you're fighting."); return end





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

      local near = nearest_reachable_to_coord(P.rooms[dead_id].coord)
      local npath = near and find_path(function(id) return id == near end)
      if npath and #npath > 0 then
         echo(string.format("[goto] can't retrace the exact room you died in — routing to the nearest " ..
         "reachable point (%d step%s) — 'goto stop' to cancel.", #npath, #npath == 1 and "" or "s"))
         P.nav = { path = npath, idx = 1, dest = "near your corpse", gen = 0 }
         nav_step(); return
      end
      echo("[goto] can't reach where you died from here on foot. `goto waypoint` to get onto the " ..
      "fast-travel network first, then try again.")
      return
   end



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

         echo(string.format("[goto] '%s' is %d step%s on foot — bridging via waypoint (~%d) instead ('goto stop' to cancel).",
         label, plan.walk_cost, plan.walk_cost == 1 and "" or "s", plan.bridge_cost))
      else

         echo("[goto] '" .. label .. "' isn't walkable from here — bridging via recall/waypoint ('goto stop' to cancel).")
      end
      goto_bridge_advance()
      return
   end

   if plan.reason == "unmarked" then
      echo("[goto] nothing is marked '" .. label .. "'. Stand in the room and mark('" .. label .. "') first.")
      return
   end



   local target_coord
   for _, r in pairs(P.rooms) do
      if has_mark(r, label) and r.coord then target_coord = r.coord; break end
   end
   local near = target_coord and nearest_reachable_to_coord(target_coord)
   local npath = near and near ~= P.current_room and find_path(function(id) return id == near end)
   if npath and #npath > 0 then
      P.goto_bridge = nil
      echo(string.format("[goto] can't reach '%s' exactly from here — routing to the nearest reachable point" ..
      " (%d step%s) — 'goto stop' to cancel.", label, #npath, #npath == 1 and "" or "s"))
      P.nav = { path = npath, idx = 1, dest = "near '" .. label .. "'", gen = 0 }
      nav_step()
      return
   end



   local wp = nearest_waypoint_for(label)
   if wp then
      local rn = P.rooms[wp] and P.rooms[wp].name
      echo("[goto] '" .. label .. "' is walkable from " .. (rn and ("'" .. rn .. "'") or "a waypoint") ..
      ", but I don't know that waypoint's number yet — run `waypoint`, or hop there once with" ..
      " `waypoint <n>`, so I can learn it.")
      echo(waypoints_hint())
   else
      echo("[goto] '" .. label .. "' is marked, but not reachable on foot from any waypoint you've walked. " ..
      "Explore a route, or set a waypoint near it.")
   end
end
alias([[^goto (.+)$]], function(_, label) human_goto(label) end)




function travel(label) return human_goto(label) end
doc(travel, { name = "travel", sig = "travel(mark)", group = "map",
text = "Route to a marked room (or 'death'/'corpse'), costing walking vs. recall/waypoint bridging and taking the cheaper. travel('stop') cancels. Same engine as the in-game `goto <mark>` alias (goto is a Lua keyword, so use travel() from the REPL).", })


function waypoints() echo(waypoints_hint()) end
doc(waypoints, { name = "waypoints", sig = "waypoints()", group = "map",
text = "List the fast-travel waypoints learned from `waypoint` listings this session (number, name, reachability).", })

local RECALL_MAX_TRIES, HOP_MAX = 6, 5








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


   if P._recall_await then (P._recall_await):cancel(); P._recall_await = nil end
   send("recall")
   if not rx then return end
   local head = rx.merge(
   roomChangeS:map(function(_) return "landed" end),
   recallFizzleS:map(function(_) return "fizzle" end)):
   first():toPromise(nil)
   untrack_flow(head)
   P._recall_await = head:andThen(function(ev)
      P._recall_await = nil
      if ev == "fizzle" and P.goto_bridge == b then

         after(2, function() if P.goto_bridge == b then goto_recall_attempt() end end)
      end
   end)
end






function goto_bridge_advance()
   local b = P.goto_bridge
   if not b then return end
   if in_combat() then echo("[goto] combat — stopping the bridge."); P.goto_bridge = nil; return end


   if P.nav then return end
   local here = P.current_room



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

   end
   if has_mark(P.rooms[here], b.label) then
      P.goto_bridge = nil; echo("[goto] arrived at '" .. b.label .. "'."); return
   end


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
         echo("[goto] I don't know which waypoint number reaches " .. (rn and ("'" .. rn .. "'") or "that room") ..
         " (its name doesn't match any in your list) — hop manually, then `goto " .. b.label .. "` again:")
         echo(waypoints_hint()); return
      end
      if b.hops >= HOP_MAX then echo("[goto] too many waypoint hops — stopping."); P.goto_bridge = nil; return end
      b.hops = b.hops + 1
      b.gen = (b.gen or 0) + 1
      local g = b.gen
      echo("[goto] hopping to waypoint " .. num .. " …")
      send("waypoint " .. num)

      after(6, function()
         if P.goto_bridge == b and b.gen == g then
            echo("[goto] that waypoint hop didn't land (may be out of range or need a bridge) — hop manually:")
            echo(waypoints_hint()); P.goto_bridge = nil
         end
      end)
      return
   end





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




function reset(args) return reset_command(args) end
doc(reset, { name = "reset", sig = "reset('room <dir>' | 'here')", group = "map",
text = "Forget a mis-mapped room and every edge pointing at it, so its direction reads unexplored again — reset('room <dir>') for a neighbour, reset('here') for the current room. Walk back to remap it clean.", })
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
   for _, r in pairs(P.rooms) do
      if r.moves then
         for d, dest in pairs(r.moves) do
            if dest == target then r.moves[d] = nil; edges = edges + 1 end
         end
      end
   end
   if target == cur then
      P.rooms[cur] = { exits = {}, moves = {} }
      if state and state.room_name then P.rooms[cur].name = state.room_name end
   end
   schedule_save()
   echo(string.format("[reset] forgot '%s' and %d edge%s to it — walk there again to remap it.",
   name, edges, edges == 1 and "" or "s"))
end



local RATES = {
   ["claude-sonnet-4-6"] = { 3, 15, 0.30, 3.75 },
   ["claude-haiku-4-5-20251001"] = { 1, 5, 0.10, 1.25 },
}
local function usage_cost(u, model)
   local r = RATES[model]; if not r then return 0 end
   return (u[1] * r[1] + u[2] * r[2] + u[3] * r[3] + u[4] * r[4]) / 1e6
end










local function session_cost()
   if not ai_usage then return 0, 0, 0, {}, {} end
   local i, o, cr, cw = ai_usage()
   local mi, mo, mcr, mcw = ai_mem_usage()
   local bmodel = (cfg.brain == "haiku") and "claude-haiku-4-5-20251001" or "claude-sonnet-4-6"
   local dc = (cfg.brain ~= "local") and usage_cost({ i, o, cr, cw }, bmodel) or 0
   local mc = cfg.use_memory and usage_cost({ mi, mo, mcr, mcw }, cfg.mem_model) or 0
   return dc + mc, dc, mc, { i = i, o = o, cr = cr, cw = cw }, { i = mi, o = mo, cr = mcr, cw = mcw }
end




function take_turn()
   local function then_decide()
      if cfg.use_rag and ai_rag_count() > 0 then
         ai_retrieve(rag_query(), cfg.rag_k, function(chunks_json, err)
            if EPOCH ~= (_AIP).epoch then return end
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



   local lean = fighting and not cfg.use_tools
   local convo = current_room_slice(lean and cfg.combat_context_lines or cfg.context_lines)
   local user = lean and
   build_combat_user(describe_state_dyn(), world_summary(), convo, directive) or
   build_user(describe_state_dyn(), exploration_summary(), memory_summary(), world_summary(), convo, directive, nudge, fighting)

   local tools = cfg.use_tools and tools_json() or ""
   ai_request(sys, user, max_tokens, tools, cfg.think_prefill, function(reply, tool_calls_json, err)
      if EPOCH ~= (_AIP).epoch then return end
      local function finish()
         P.busy = false; P.last_turn = os.time()
         if cfg.budget and cfg.budget > 0 then
            local spent = session_cost()
            if spent >= cfg.budget then
               echo(string.format("[ai] budget cap $%.2f reached (~$%.2f spent this session) — disarming. pilot.budget(0) to lift it, then pilot.on().", cfg.budget, spent))
               P.enabled = false; (_AIP).enabled = false; return
            end
         end
         if P.enabled and P.input_seq ~= P.snap_seq then arm() end
      end
      if err then echo("[ai] request failed: " .. err .. " (is LM Studio running?)"); finish(); return end



      local fighting_now = in_combat()
      if fighting_now ~= P.snap_fighting then
         echo(fighting_now and "[ai] (combat started while thinking — reassessing)" or
         "[ai] (combat ended while thinking — reassessing)")
         P.stale_skips = 0
         if not P.pending then P.pending = directive end
         finish(); return
      end



      local moved = P.input_seq ~= P.snap_seq
      if not fighting_now and moved and P.stale_skips < cfg.max_stale_skips then
         P.stale_skips = P.stale_skips + 1
         if not P.pending then P.pending = directive end
         echo("[ai] (situation changed while thinking — re-reading before acting)")
         finish(); return
      end
      P.stale_skips = 0
      log_trace(sys, user, reply or "")


      local tcs = tool_calls_json and json.decode(tool_calls_json)
      if type(tcs) == "table" and #(tcs) > 0 then
         local calls = {}
         for _, c in ipairs(tcs) do
            local cc = c
            local a = cc.arguments
            if type(a) == "string" then a = json.decode(a) end
            calls[#calls + 1] = { name = cc.name, args = (type(a) == "table") and a or {} }
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






function build_human_demo(cmd)
   local name, args = tool_call_for(cmd)
   local sys = system_prompt()
   local user = build_user(describe_state_dyn(), exploration_summary(), memory_summary(), "",
   current_room_slice(nil), nil, nil, in_combat())
   local record = {



      ts = os.time(),
      dt = (P.last_human > 0) and (os.time() - P.last_human) or 0,
      messages = {
         { role = "system", content = sys },
         { role = "user", content = user },
         { role = "assistant", content = "", tool_calls = { {
   id = "call_1", type = "function",
   ["function"] = { name = name, arguments = json.encode(args) },
}, }, },
      }, }
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
   if EPOCH ~= (_AIP).epoch then return end
   if g ~= P.gen or not P.enabled or P.busy or P.nav then return end



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
   P.enabled = on;
   (_AIP).enabled = on
   if on then
      P.recent_cmds = {}; P.stale_skips = 0



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
   elseif verb == "goal" then if rest ~= "" then P.goal = rest; (_AIP).goal = rest end; echo("[ai] goal: " .. P.goal)
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
      echo("[ai] combat-only: " .. (cfg.combat_only and
      "ON — acts only during fights, dormant (hands-off) between them; auto-resumes each new fight" or
      "off — the pilot drives continuously (explore/loot/move) when armed"))
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

      if cfg.use_rag then
         after(0.5, function()
            local n = ai_rag_count()
            echo("[ai] manual (RAG): on — " .. n .. " passages indexed" ..
            (n == 0 and "  (run tools/finetune/build_rag_index.py to build the index)" or ""))
         end)
      else echo("[ai] manual (RAG): off") end
   elseif verb == "trace" then
      if rest:lower() == "off" then P.trace = false elseif rest:lower() == "on" then P.trace = true end
      echo("[ai] trace: " .. (P.trace and cfg.trace_file or "off"))
   elseif verb == "tools" then
      echo(tools_json())
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





pilot = {}





local PILOT_CMDS = {
   on = { sig = "pilot.on()", text = "Arm the pilot: the decision model starts driving." },
   off = { sig = "pilot.off()", text = "Disengage the pilot." },
   once = { sig = "pilot.once()", text = "Take a single pilot turn without arming." },
   status = { sig = "pilot.status()", text = "Show armed state, brain/memory/RAG config, and the current goal." },
   goal = { sig = "pilot.goal([text])", text = "Set (or, with no arg, show) the standing goal the pilot pursues." },
   tell = { sig = "pilot.tell(text)", text = "Queue a one-off director note for the pilot's next turn." },
   model = { sig = "pilot.model(id)", text = "Set the decision model id directly." },
   brain = { sig = "pilot.brain(which)", text = "Choose the decision brain: 'local' | 'haiku' | 'sonnet'." },
   mode = { sig = "pilot.mode(m)", text = "Force 'tools' (base models) or 'text'/'cmd' (fine-tuned) mode." },
   combat_only = { sig = "pilot.combat_only(on)", text = "When ON (the DEFAULT), the pilot acts ONLY during fights and stays dormant (hands-off) between them, auto-resuming each new fight — you explore/move manually. 'off' makes it fully autonomous (explores/loots/navigates too). A modifier on pilot.on()." },
   url = { sig = "pilot.url(base)", text = "Set the decision client's API endpoint." },
   mem = { sig = "pilot.mem(on_off)", text = "Turn the memory head on or off ('on'/'off')." },
   memmodel = { sig = "pilot.memmodel(which)", text = "Set the memory head's model ('haiku' | 'sonnet' | <id>)." },
   memkey = { sig = "pilot.memkey(key)", text = "Set the memory head's Anthropic API key and enable it." },
   cost = { sig = "pilot.cost()", text = "Report this session's estimated token spend." },
   usagereset = { sig = "pilot.usagereset()", text = "Zero the token/cost counters." },
   budget = { sig = "pilot.budget([dollars])", text = "Set a session $ cap that auto-disarms the pilot when crossed (0 = off)." },
   rag = { sig = "pilot.rag(on_off)", text = "Toggle RAG manual retrieval ('on'/'off')." },
   trace = { sig = "pilot.trace(on_off)", text = "Toggle turn tracing to the trace file ('on'/'off')." },
   tools = { sig = "pilot.tools()", text = "Print the exact tool definitions sent to the model each turn." },
   demo = { sig = "pilot.demo(command)", text = "Preview the training example a command maps to." },
   remember = { sig = "pilot.remember(fact)", text = "Add a memory the pilot will carry." },
   memories = { sig = "pilot.memories()", text = "List the pilot's remembered facts." },
   forget = { sig = "pilot.forget(what)", text = "Forget memories (pilot.forget('all'))." },
}
local pilot_tbl = pilot
for verb, info in pairs(PILOT_CMDS) do
   pilot_tbl[verb] = function(arg) return ai_command(trim(verb .. " " .. (arg == nil and "" or tostring(arg)))) end
   doc(pilot_tbl[verb], { name = "pilot." .. verb, sig = info.sig, text = info.text, group = "pilot" })
end
pilot_tbl.reload = function() return reload() end
doc(pilot_tbl.reload, { name = "pilot.reload", sig = "pilot.reload()", group = "pilot",
text = "Hot-reload the Scripts/ directory (same as reload() / legacy `#ai reload`).", })




pilot_tbl.restore_map = function(path)
   path = (path ~= nil and path ~= "") and tostring(path) or (cfg.dir .. "/explored.lua.bak")
   local p = path
   if not p:find("/") then p = cfg.dir .. "/" .. p end
   local loader = persist.load
   local t = loader(p, function(m) if echo then echo(m, "yellow") end end)
   if not (type(t) == "table") or not (t).rooms then
      echo("[map] restore failed: " .. p .. " is not a valid map file.", "red"); return
   end
   local tt = t
   P.rooms = tt.rooms or {}
   P.dir_deltas = tt.dir_deltas or {}
   P.memories = tt.memories or {}
   P.waypoints = tt.waypoints or {}
   P.wp_room = tt.wp_room or {}
   P.room_wp = tt.room_wp or {}
   schedule_save()
   echo(string.format("[map] restored %d rooms, %d memories from %s (saving safely now).",
   count_map(P.rooms), count_map(P.memories), p), "green")
end
doc(pilot_tbl.restore_map, { name = "pilot.restore_map", sig = "pilot.restore_map([path])", group = "pilot",
text = "Import a saved/backup map file into the live map (replaces the in-memory rooms/marks/notes/waypoints, then saves). `path` defaults to explored.lua.bak; a bare name resolves under ~/Documents/MudClient. Use it to recover from a backup mid-session.", })
setmetatable(pilot_tbl, { __call = function(_, args) return ai(args) end })



doc("ai", { sig = "ai(args)", group = "pilot",
text = "Deprecated: use the pilot.* table (pilot.on(), pilot.status(), …). Thin wrapper kept for the legacy `#ai …` typed form; ai('reload') re-runs scripts, else forwards to the pilot.", })




load_map()





if smap_on_map_update then smap_on_map_update() end
local brain_desc = set_brain(cfg.brain)
if cfg.use_memory then ai_set_memory_model(cfg.mem_model) end
if cfg.use_rag then ai_rag_load(cfg.rag_index) end
echo("[ai] brain: " .. (brain_desc or cfg.brain) .. " | memory: " .. (cfg.use_memory and cfg.mem_model or "off"))
if P.enabled then
   echo("[ai] pilot reloaded — still ARMED.")
   arm()
else
   echo("[ai] pilot loaded. pilot.on() to start.")
end



_AIP_TEST = {
   has_mark = has_mark, marks_list = marks_list, find_path = find_path,
   nearest_reachable_to_coord = nearest_reachable_to_coord, mark_death = mark_death,
   mark_command = mark_command,
   find_path_from = find_path_from, has_frontier = has_frontier, coord_key = coord_key, P = P,
   smap_coord_grid = smap_coord_grid, smap_apply = smap_apply, smap_on_map_update = smap_on_map_update,
   SM = SM,
   parse_waypoint_list = parse_waypoint_list, recall_failed = recall_failed,
   learn_waypoint = learn_waypoint, nearest_waypoint_for = nearest_waypoint_for,
   waypoint_num_for_room = waypoint_num_for_room, waypoint_cmd_num = waypoint_cmd_num,
   parse_exits = parse_exits, cmd_ends_turn = cmd_ends_turn, untaken_exit = untaken_exit,
   path_to_unexplored = path_to_unexplored, resolve_nav = resolve_nav,
   best_explore_dir = best_explore_dir, block_last_move = block_last_move, noexit_command = noexit_command,
   addexit_command = addexit_command,
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
