


















state = state or {}


























local update_top
local update_bottom



function on_update()
   if not state or not state.hp then return end
   update_top()
   update_bottom()
end


local function cat(...)
   local out = {}
   for _, list in ipairs({ ... }) do
      for _, s in ipairs(list) do out[#out + 1] = s end
   end
   return out
end

local function pct(cur, max)
   if not cur or not max or max == 0 then return 0 end
   return math.max(0, math.min(1, cur / max))
end




local HUE = { hp = { 210, 45, 45 }, mp = { 55, 110, 235 }, mv = { 70, 195, 90 } }
local function vital_rgb(kind, p)
   local base = HUE[kind] or HUE.hp
   local danger = 1 - math.max(0, math.min(1, p))
   local lift = math.floor(danger * danger * 145)
   return {
      math.min(255, base[1] + lift),
      math.min(255, base[2] + lift),
      math.min(255, base[3] + lift),
   }
end




local BLOCKS = { "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" }
local function gauge(cur, max, width, kind)
   local w = width or 8
   local p = pct(cur, max)
   local eighths = math.floor(p * w * 8 + 0.5)
   local full = math.floor(eighths / 8)
   local rem = eighths % 8
   local filled = string.rep("█", full) .. (rem > 0 and BLOCKS[rem] or "")
   local pad = w - full - (rem > 0 and 1 or 0)
   return {
      { text = filled, fg = vital_rgb(kind, p), bold = (p <= 0.25) },
      { text = string.rep("░", math.max(0, pad)), fg = "brightblack" },
   }
end

local function vital(label, cur, max, kind)
   return { spans = cat(
{ { text = label .. " ", dim = true },
{ text = string.format("%d/%d ", cur or 0, max or 0), fg = "white" }, },
gauge(cur, max, 8, kind)),
   }
end

local WALK_ARROW = { north = "↑", south = "↓", east = "→", west = "←",
northeast = "↗", northwest = "↖", southeast = "↘", southwest = "↙", up = "⤒", down = "⤓", }






local function in_fight()
   return (state.fighting) or (engaged ~= nil and engaged())
end





local OPP_CAP = 4
local COND_WORD = { [3] = "near death", [8] = "mortally wounded", [15] = "awful", [28] = "pretty hurt",
[42] = "nasty wounds", [55] = "many wounds", [68] = "small wounds",
[82] = "scratches", [95] = "healthy", }
local function cond_word(pct)
   if pct == nil then return "?" end
   return COND_WORD[pct] or (tostring(pct) .. "%")
end

local function est_gauge(p100, width)
   local w = width or 8
   local full = math.floor(math.max(0, math.min(1, (p100 or 0) / 100)) * w + 0.5)
   return {
      { text = string.rep("▓", full), fg = "brightblack", dim = true },
      { text = string.rep("░", math.max(0, w - full)), fg = "brightblack", dim = true },
   }
end











local function target_cell(promoted)
   if state.fighting then
      return { flex = 1.6, spans = cat(
{ { text = "⚔ ", fg = "yellow" },
{ text = ((state.fight_name) or "?") .. " ", fg = "brightred" }, },
gauge(state.fight_pct, 100, 10, "hp"),
{ { text = string.format(" %d%%", (state.fight_pct) or 0), dim = true } }),
      }
   end
   if promoted then
      return { flex = 1.6, spans = cat(
{ { text = "⚔ ", fg = "yellow" },
{ text = (promoted.name or "?") .. " ", fg = "brightred", dim = true }, },
est_gauge(promoted.pct, 10),
{ { text = " ~" .. cond_word(promoted.pct), fg = "brightblack", dim = true } }),
      }
   end
   if in_fight() then
      return { flex = 1.6, spans = { { text = "⚔ engaged", fg = "yellow", dim = true } } }
   end
   return { flex = 1.6, text = "⚔ —", fg = "brightblack" }
end


local function vital_cells()
   return {
      vital("HP", state.hp, state.maxhp, "hp"),
      vital("MP", state.mana, state.maxmana, "mp"),
      vital("MV", state.stam, state.maxstam, "mv"),
   }
end


local function spells_row()
   local spans = {}

   if state.action and (state.action) >= 50 then
      spans[#spans + 1] = { text = "⊘ can't cast   ", fg = "brightred", bold = true }
   end
   local names = {}
   for k in pairs((state.spells) or {}) do names[#names + 1] = k end
   table.sort(names)
   if #names == 0 then
      spans[#spans + 1] = { text = "spells: none", fg = "brightblack" }
   else
      spans[#spans + 1] = { text = "spells: ", dim = true }
      for i, n in ipairs(names) do
         spans[#spans + 1] = { text = n, fg = "brightgreen" }
         if i < #names then spans[#spans + 1] = { text = ", ", dim = true } end
      end
   end
   return { spans = spans }
end







local opponent_bars
opponent_bars = function(list, cap)
   cap = cap or OPP_CAP
   local rows = {}
   local n = #list
   local shown = math.min(n, cap)
   for i = 1, shown do
      local o = list[i]
      local word = cond_word(o.pct)
      rows[#rows + 1] = { spans = cat(
{ { text = "⚔ ", fg = "brightblack", dim = true },
{ text = (o.name or "?") .. " ", fg = "brightred", dim = true }, },
est_gauge(o.pct, 8),
{ { text = "  ~" .. word, fg = "brightblack", dim = true } }),
      }
   end
   if n > cap then
      rows[#rows + 1] = { spans = { { text = string.format("  +%d more engaged", n - cap),
fg = "brightblack", dim = true, }, }, }
   end
   return rows
end



local function dir_span(label, on)
   return { text = label, fg = on and "brightgreen" or "brightblack", bold = on or false }
end

local function compass(line)
   local e = (state.exits) or {}
   local rows = {
      { dir_span("NW", e.northwest), { text = "  " }, dir_span("N", e.north), { text = "  " }, dir_span("NE", e.northeast) },
      { dir_span("W ", e.west), { text = "  " }, { text = "◈", fg = "cyan" }, { text = "  " }, dir_span(" E", e.east) },
      { dir_span("SW", e.southwest), { text = "  " }, dir_span("S", e.south), { text = "  " }, dir_span("SE", e.southeast) },
   }
   return { spans = rows[line], width = 12, align = "center" }
end


local function room_name_cell()
   local e = (state.exits) or {}
   local spans = { { text = "◈ ", fg = "cyan" }, { text = (state.room_name) or "somewhere", fg = "brightcyan" } }
   if e.up then spans[#spans + 1] = { text = "  ⤒U", fg = "brightgreen" } end
   if e.down then spans[#spans + 1] = { text = "  ⤓D", fg = "brightgreen" } end
   return { spans = spans }
end




update_bottom = function()
   local fighting = in_fight()


   local others = {}
   local promoted = nil
   if fighting and active_opponents then
      others = active_opponents(os.time())
      if not state.fighting and #others > 0 then promoted = table.remove(others, 1) end
   end
   local stats = vital_cells()
   stats[#stats + 1] = fighting and target_cell(promoted) or compass(1)
   local rows = { { cols = stats } }
   if fighting then

      for _, r in ipairs(opponent_bars(others)) do rows[#rows + 1] = r end
      rows[#rows + 1] = spells_row()
      rows[#rows + 1] = room_name_cell()
   else
      rows[#rows + 1] = { cols = { spells_row(), compass(2) } }
      rows[#rows + 1] = { cols = { room_name_cell(), compass(3) } }
   end
   panel.render(rows)
end







local function truncate_middle(s, max)
   local n = utf8.len(s)
   if not n or n <= max or max < 2 then return s end
   local keep = max - 1
   local left = math.floor(keep / 2)
   local right = keep - left
   local lend = utf8.offset(s, left + 1) - 1
   local rstart = utf8.offset(s, n - right + 1)
   return s:sub(1, lend) .. "…" .. s:sub(rstart)
end
local MUSIC_NAMES_MAX = 36


local function place_spans()
   local b = {}
   if state.position then b[#b + 1] = { text = "(" .. (state.position) .. ")", dim = true } end
   if state.walkdir and WALK_ARROW[state.walkdir] then
      b[#b + 1] = { text = "  " .. WALK_ARROW[state.walkdir], fg = "brightblue" }
   end
   if state.gold then b[#b + 1] = { text = string.format("  %dg", state.gold), fg = "yellow" } end
   return b
end

local function env_spans()
   local b = {}
   if state.daypart then b[#b + 1] = { text = state.daypart, fg = "yellow" } end
   if state.clock then b[#b + 1] = { text = "  " .. (state.clock), dim = true } end

   if state.outdoors == false then
      b[#b + 1] = { text = "  ⌂ indoors", fg = "brightblack" }
   elseif state.outdoors == true then
      if state.overcast then
         b[#b + 1] = { text = "  ☁ overcast", fg = "brightblack" }
      elseif state.sky_visible == false then
         b[#b + 1] = { text = "  ⛰ sheltered", fg = "brightblack" }
      else
         local daypart = state.daypart
         local night = daypart ~= nil and (daypart:find("night") ~= nil or daypart:find("evening") ~= nil or
         daypart == "midnight" or daypart:find("dusk") ~= nil)
         b[#b + 1] = { text = night and "  ☾ clear" or "  ☀ clear", fg = "brightyellow" }
      end
   end
   if state.precip and (state.precip) > 0 then b[#b + 1] = { text = "  ☔", fg = "brightblue" } end

   local playing = {}
   for _, tr in pairs((state.music) or {}) do
      playing[#playing + 1] = tr:gsub("^.*/", ""):gsub("^track_", "")
   end
   if #playing > 0 then
      table.sort(playing)
      b[#b + 1] = { text = "  ♪ " .. truncate_middle(table.concat(playing, " · "), MUSIC_NAMES_MAX),
fg = "brightmagenta", }
   end
   return b
end
























local function next_level(exp, classes)
   local min_cost
   for _, c in pairs(classes or {}) do
      if c.cost and (not min_cost or c.cost < min_cost) then min_cost = c.cost end
   end
   if not min_cost then return nil end
   local names = {}
   local level_of = {}
   local micro_of = {}
   for name, c in pairs(classes or {}) do
      if c.cost == min_cost then names[#names + 1] = name; level_of[name] = c.level; micro_of[name] = c.micro end
   end
   table.sort(names)
   return { names = names, name = names[1], level = level_of[names[1]],
micro = micro_of[names[1]], cost = min_cost, need = min_cost - (exp or 0), }
end






local EXP_CLASSES = { "Mage", "Cleric", "Thief", "Warrior", "Necromancer", "Druid" }
local function exp_pairs_spans()
   local vals = state.exp_to_level
   if not vals or #vals == 0 then return nil end
   local best = 0
   for _, v in ipairs(vals) do if (v or 0) > best then best = v end end
   local names = {}
   for i, v in ipairs(vals) do if v == best then names[#names + 1] = EXP_CLASSES[i] or ("class" .. i) end end
   local who = table.concat(names, ", ")
   if best >= 1000 then
      return { { text = "exp ", dim = true }, { text = "level: " .. who, fg = "brightgreen", bold = true } }
   end
   return { { text = "exp ", dim = true },
{ text = string.format("next: %s (%.0f%%)", who, best / 10), fg = "magenta" }, }
end

local function exp_spans()
   if not state.exp then
      return exp_pairs_spans() or {}
   end
   local b = { { text = "exp ", dim = true }, { text = tostring(state.exp), fg = "brightmagenta" } }




   local nl = next_level(state.exp, state.classes)
   if nl then
      local label = table.concat(nl.names, "/")


      local micro = (#nl.names == 1) and nl.micro or nil




      local pctstr = ""
      if nl.cost and nl.cost > 0 then
         local pctnum = math.floor((nl.cost - nl.need) / nl.cost * 100)
         pctnum = (pctnum < 0 and 0) or (pctnum > 99 and 99) or pctnum
         pctstr = string.format(" (%d%%)", pctnum)
      end
      if nl.need <= 0 then
         local verb = micro and "micro " or "level "
         b[#b + 1] = { text = "  ▲ " .. verb .. label .. " now", fg = "brightgreen", bold = true }
      elseif micro then
         b[#b + 1] = { text = string.format("  ▲ %s micro %d/%d in %d%s", label, micro.done, micro.total, nl.need, pctstr), fg = "magenta" }
      elseif #nl.names == 1 and nl.level then
         b[#b + 1] = { text = string.format("  ▲ %s %d in %d%s", label, nl.level + 1, nl.need, pctstr), fg = "magenta" }
      else
         b[#b + 1] = { text = string.format("  ▲ %s in %d%s", label, nl.need, pctstr), fg = "magenta" }
      end
   end

   if state.expcap then b[#b + 1] = { text = string.format("  cap/kill %d", state.expcap), dim = true } end
   return b
end






local function reference_rows()
   local sep = { { text = "   " } }
   local area_place = { spans = cat({ { text = (state.area) or "", dim = true } }, sep, place_spans()) }
   local env_prog = { spans = cat(env_spans(), sep, exp_spans()) }
   return { area_place, env_prog }
end


local function member_bar(label, cur, max, kind)
   return { spans = cat(
{ { text = label .. " ", dim = true } },
gauge(cur, max, 6, kind),
{ { text = string.format(" %d/%d", cur or 0, max or 0), fg = "white" } }),
   }
end















local function group_member_row(m)
   local tag = m.flags or ""
   local absent = tag:find("-", 1, true) ~= nil
   local name_fg = "brightwhite"
   if tag:find("O", 1, true) then name_fg = "brightblack"
   elseif tag:find("M", 1, true) then name_fg = "cyan"
   elseif tag:find("?", 1, true) then name_fg = "yellow" end
   local spans = {}



   local is_minion = tag:find("M", 1, true) ~= nil or tag:find("O", 1, true) ~= nil
   if is_minion then spans[#spans + 1] = { text = "  ↳ ", fg = "brightblack" } end
   if tag:find("L", 1, true) then spans[#spans + 1] = { text = "★", fg = "brightyellow" } end
   if tag:find("T", 1, true) then spans[#spans + 1] = { text = "⛨", fg = "brightcyan" } end
   if tag:find("N", 1, true) then spans[#spans + 1] = { text = "∅", fg = "brightblack" } end
   if #spans > 0 and not is_minion then spans[#spans + 1] = { text = " " } end
   spans[#spans + 1] = { text = m.name, fg = name_fg, dim = absent }
   if absent then spans[#spans + 1] = { text = " ·away", fg = "brightblack" } end
   return { cols = {
      { spans = spans, width = 26 },
      member_bar("HP", m.hp, m.maxhp, "hp"),
      member_bar("MP", m.mana, m.maxmana, "mp"),
      member_bar("MV", m.stam, m.maxstam, "mv"),
   }, }
end









local function group_ordered(g)
   local self_row
   local mine = {}
   local others = {}
   local cur = nil
   for _, m in ipairs(g) do
      local f = m.flags or ""
      if f:find("X", 1, true) or (state.name and m.name == state.name) then self_row = m
      elseif f:find("P", 1, true) then cur = { member = m, pets = {} }; others[#others + 1] = cur
      elseif f:find("O", 1, true) then
         if cur then cur.pets[#cur.pets + 1] = m else mine[#mine + 1] = m end
      else mine[#mine + 1] = m end
   end
   local out = {}
   if self_row then out[#out + 1] = self_row end
   for _, m in ipairs(mine) do out[#out + 1] = m end
   for _, o in ipairs(others) do
      out[#out + 1] = o.member
      for _, p in ipairs(o.pets) do out[#out + 1] = p end
   end
   return out
end



local function dclient_map_rows(raw)
   local rows = {}
   for line in (raw .. "\n"):gmatch("([^\n]*)\n") do rows[#rows + 1] = (line:gsub("\r$", "")) end
   while #rows > 0 and rows[#rows] == "" do rows[#rows] = nil end
   return rows
end






local MAP_PALETTE = { "green", "brightgreen", "yellow", "brightyellow", "cyan", "brightcyan",
"blue", "brightblue", "magenta", "brightmagenta", "red", "brightred", }
local function map_glyph(code)
   if code <= 0 then return "·", "brightblack" end
   return "▪", MAP_PALETTE[((code - 1) % #MAP_PALETTE) + 1]
end






local MAP_LAYER_MAX = 13
local function dclient_terrain_section(rows)
   local i, n = 1, #rows
   while i <= n do
      local w = #rows[i]
      local j = i
      while j <= n and #rows[j] == w do j = j + 1 end
      local len = j - i
      if w >= 6 and w <= 26 and len >= 6 then
         local sec = {}
         local last = math.min(j - 1, i + MAP_LAYER_MAX - 1)
         for k = i, last do sec[#sec + 1] = rows[k] end
         return sec
      end
      i = j
   end
   return nil
end




local MAP_CLIP_H = 9
local function minimap_cells_from_dclient(raw)
   local sec = dclient_terrain_section(dclient_map_rows(raw))
   if not sec then return nil end
   local total_h, w = #sec, #sec[1]
   local h = math.min(MAP_CLIP_H, total_h)
   local row_off = math.floor((total_h - h) / 2)
   local you_r, you_c = math.floor(total_h / 2) + 1, math.floor(w / 2) + 1
   local out = {}
   for r = 1, h do
      local line = sec[row_off + r] or ""
      local spans = { { text = "  " } }
      for c = 1, w do
         local ch = line:sub(c, c)
         local code = (ch ~= "" and ch ~= " ") and (ch:byte() - 0x40) or 0
         if (row_off + r) == you_r and c == you_c then
            spans[#spans + 1] = { text = "◉", fg = "brightwhite", bold = true }
         else
            local g, fg = map_glyph(code)
            spans[#spans + 1] = { text = g, fg = fg }
         end
      end
      out[r] = { spans = spans, width = w + 2 }
   end
   return out
end



local function dclient_map_usable(raw)
   return dclient_terrain_section(dclient_map_rows(raw)) ~= nil
end


















local function minimap_window(m)
   local out = {}
   for r = 1, m.h do
      local line = m.cells[r] or {}
      local spans = { { text = "  " } }
      for c = 1, m.w do
         local cell = line[c]
         if cell then spans[#spans + 1] = { text = cell.ch, fg = cell.fg, bold = cell.bold }
         else spans[#spans + 1] = { text = " " } end
      end
      out[r] = { spans = spans, width = m.w + 2 }
   end
   return out
end





local function minimap_cells()





   local g = _G
   if g.minimap then
      local mm = g.minimap
      local m = mm(3, 2)
      if m then return minimap_window(m) end
   end
   if state.dclient_map and dclient_map_usable(state.dclient_map) then
      local out = minimap_cells_from_dclient(state.dclient_map)
      if out then return out end
   end
   return nil
end






local function append_col(row, cell)
   local cols = {}
   if row.cols then for _, c in ipairs(row.cols) do cols[#cols + 1] = c end
   else cols[#cols + 1] = row end
   if cell.cols then for _, c in ipairs(cell.cols) do cols[#cols + 1] = c end
   else cols[#cols + 1] = cell end
   return { cols = cols }
end











local PROMISE_CAP = 6
local function promise_rows(width)
   if not active_promises then return {} end
   local list = active_promises()
   if #list == 0 then return {} end
   local rows = { { spans = { { text = "  promises", fg = "cyan", dim = true } }, width = width } }
   local textw = math.max(6, width - 4)
   local shown = math.min(#list, PROMISE_CAP)
   for i = 1, shown do
      local p = list[i]
      local desc = p.desc or "?"
      if #desc > textw then desc = desc:sub(1, textw - 1) .. "…" end
      rows[#rows + 1] = { spans = { { text = "  " },
{ text = desc, fg = "magenta", dim = (p.state == "cold") }, }, width = width, }
   end
   if #list > shown then
      rows[#rows + 1] = { spans = { { text = string.format("  +%d more", #list - shown), dim = true } },
width = width, }
   end
   return rows
end







local LAG_UI_ALERT = 100
local LAG_NET_ALERT = 300
local LAG_RECENT_MS = 6000
local function lag_row(label, ms, alert)
   local val = string.format("%dms", math.floor((ms or 0) + 0.5))
   if alert then
      return { spans = { { text = "  ⚠ " .. label .. " ", fg = "brightred", bold = true },
{ text = val, fg = "brightred", bold = true }, }, }
   end
   return { spans = { { text = "  " .. label .. " ", dim = true }, { text = val, fg = "green", dim = true } } }
end
local function lag_rows(width)
   if not lag_status then return {} end
   local s = lag_status()
   if type(s) ~= "table" then return {} end
   local ui_ms, ui_age = s.ui_ms or 0, s.ui_age_ms or -1
   local net_ms, net_age = s.net_ms or 0, s.net_age_ms or -1
   local ui_hit = ui_age >= 0 and ui_ms > LAG_UI_ALERT
   local net_ok = net_age >= 0
   if not (ui_hit or net_ok) then return {} end
   local ui_now = ui_hit and ui_age < LAG_RECENT_MS
   local net_bad = net_ok and net_ms > LAG_NET_ALERT and net_age < LAG_RECENT_MS
   local rows = {}
   local function W(r) r.width = width; rows[#rows + 1] = r end
   W({ spans = { { text = "  lag", fg = (ui_now or net_bad) and "brightred" or "cyan",
dim = not (ui_now or net_bad), }, }, })
   if net_ok then W(lag_row("net", net_ms, net_bad)) end
   if ui_hit then W(lag_row(ui_now and "UI hitch" or "UI last", ui_ms, ui_now)) end
   return rows
end







local GROUP_NAME_W = 26
local STAM_W = 18
local LAG_COL_W = 20
local function term_width()
   if type(__term_cols) ~= "function" then return 80 end
   local ok, n = pcall(__term_cols)
   return (ok and type(n) == "number" and n > 0) and n or 80
end
local function widget_width(mw)
   local W = term_width()
   local vital_w = (W - GROUP_NAME_W - mw) / 3
   local left_edge = GROUP_NAME_W + 2 * vital_w + STAM_W
   local w = math.floor(W - left_edge + 0.5)
   return math.max(mw, math.min(w, W - 40))
end

update_top = function()
   local left = {}
   local g = (state.group) or {}
   if #g >= 2 then
      left[#left + 1] = { text = string.format("── group (%d) ──", #g), fg = "cyan", dim = true }
      for _, m in ipairs(group_ordered(g)) do left[#left + 1] = group_member_row(m) end
   end
   if in_fight() then
      left[#left + 1] = { cols = { { text = "" }, compass(1) } }
      left[#left + 1] = { cols = { { spans = { { text = "exits", dim = true } } }, compass(2) } }
      left[#left + 1] = { cols = { { text = "" }, compass(3) } }
   end
   for _, r in ipairs(reference_rows()) do left[#left + 1] = r end






   local mini = minimap_cells()
   local mw = (mini and mini[1] and mini[1].width) or 26


   local ww = widget_width(mw)
   local right = {}
   if mini then for _, m in ipairs(mini) do right[#right + 1] = m end end




   local lrows = lag_rows(math.min(LAG_COL_W, ww))
   local have_lag = #lrows > 0
   local prom_w = have_lag and math.max(10, ww - LAG_COL_W) or ww
   local lag_w = have_lag and (ww - prom_w) or ww
   local prows = promise_rows(prom_w)






   if #prows > 0 or #lrows > 0 then
      local group_rows = (#g >= 2) and (1 + #g) or 0
      while #right < group_rows do right[#right + 1] = { text = "", width = mw } end
      if #right > 0 then right[#right + 1] = { text = "", width = ww } end


      local nrows = math.max(#prows, #lrows)
      for i = 1, nrows do
         if have_lag then
            local lcell = lrows[i] or { text = "" }
            local pcell = prows[i] or { text = "" }
            lcell.width, pcell.width = lag_w, prom_w
            right[#right + 1] = { cols = { lcell, pcell }, width = ww }
         else
            local pcell = prows[i] or { text = "" }
            pcell.width = ww
            right[#right + 1] = pcell
         end
      end
   end
   if #right == 0 then panel.top(left); return end
   local blank = { text = "", width = mw }
   local rows = {}
   local n = math.max(#left, #right)
   for i = 1, n do
      local m = right[i] or blank
      if left[i] then rows[i] = append_col(left[i], m)
      else rows[i] = append_col({ text = "" }, m) end
   end
   panel.top(rows)
end



_HUD_TEST = { pct = pct, gauge = gauge, vital_rgb = vital_rgb, next_level = next_level,
exp_spans = exp_spans, compass = compass, group_member_row = group_member_row,
append_col = append_col, opponent_bars = opponent_bars,
target_cell = target_cell, cond_word = cond_word, in_fight = in_fight,
truncate_middle = truncate_middle, lag_rows = lag_rows,
minimap_cells_from_dclient = minimap_cells_from_dclient, map_glyph = map_glyph,
dclient_map_rows = dclient_map_rows, dclient_terrain_section = dclient_terrain_section,
group_ordered = group_ordered, }
