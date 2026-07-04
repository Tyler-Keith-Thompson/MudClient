-- HUD.lua — the status panels, fed by the shared `state` table that AlterAeon.lua's kxwt triggers
-- keep up to date. The generic Swift screen owner freezes two bands and scrolls game output between
-- them:
--   BOTTOM panel (next to where you act) = combat essentials: vitals, the enemy, your buffs.
--   TOP panel (reference) = the group roster plus room / navigation / exits / time / progress.
--
-- The spec handed to panel.render / panel.top is a list of ROWS. A row is either:
--   { text = "..", fg = "..", ... }                       -- one plain styled line
--   { spans = { {text=..,fg=..}, {text=..} } }            -- one line of several styled runs
--   { cols  = { <col>, <col>, ... } }                     -- columns laid out left-to-right
-- A COLUMN is a cell (`{text=..}` / `{spans=..}`) that may also carry layout keys:
--   width = N   (fixed cells)   flex = F   (share of leftover width, default 1)
--   align = "left" | "right" | "center"
-- A SPAN understands: text, fg, bg (named 16-colour, "#rrggbb", or {r,g,b}), bold, dim, reverse,
-- underline. All widget/layout logic lives here — edit + `#ai reload` to iterate live.

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

-- Vitals keep a fixed HUE (hp=red, mana=blue, moves=green) but LIGHTEN toward an alarming tint as
-- they drain, so a low bar reads as danger without changing colour identity. Eased-in (danger²) so it
-- only brightens noticeably once things actually get low.
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

local function gauge(cur, max, width, kind)
  local w = width or 8
  local p = pct(cur, max)
  local filled = math.floor(p * w + 0.5)
  return {
    { text = string.rep("█", filled), fg = vital_rgb(kind, p), bold = (p <= 0.25) },
    { text = string.rep("░", w - filled), fg = "brightblack" },
  }
end

local function vital(label, cur, max, kind)
  return { spans = cat(
    { { text = label .. " ", dim = true },
      { text = string.format("%d/%d ", cur or 0, max or 0), fg = "white" } },
    gauge(cur, max, 8, kind)
  ) }
end

local WALK_ARROW = { north = "↑", south = "↓", east = "→", west = "←",
  northeast = "↗", northwest = "↖", southeast = "↘", southwest = "↙", up = "⤒", down = "⤓" }

-- ============================ BOTTOM PANEL (combat) ============================

-- The enemy: name + health bar + %, as a column that rides alongside the vitals (wider via flex so
-- the name has room). Idle when not fighting.
local function target_cell()
  if state.fighting then
    return { flex = 1.6, spans = cat(
      { { text = "⚔ ", fg = "yellow" },
        { text = (state.fight_name or "?") .. " ", fg = "brightred" } },
      gauge(state.fight_pct, 100, 10, "hp"),
      { { text = string.format(" %d%%", state.fight_pct or 0), dim = true } }
    ) }
  end
  return { flex = 1.6, text = "⚔ —", fg = "brightblack" }
end

-- The three vitals cells (hp / mana / moves) — the left of the stats line.
local function vital_cells()
  return {
    vital("HP", state.hp, state.maxhp, "hp"),
    vital("MP", state.mana, state.maxmana, "mp"),
    vital("MV", state.stam, state.maxstam, "mv"),
  }
end

-- Active spells (buffs) — what's currently up on you.
local function spells_row()
  local names = {}
  for k in pairs(state.spells or {}) do names[#names + 1] = k end
  table.sort(names)
  if #names == 0 then return { text = "spells: none", fg = "brightblack" } end
  local spans = { { text = "spells: ", dim = true } }
  for i, n in ipairs(names) do
    spans[#spans + 1] = { text = n, fg = "brightgreen" }
    if i < #names then spans[#spans + 1] = { text = ", ", dim = true } end
  end
  return { spans = spans }
end

-- Exits compass rose (three lines) + the room name — kept at the BOTTOM, next to where you act, so
-- you glance at exits constantly.
local function dir_span(label, on)
  return { text = label, fg = on and "brightgreen" or "brightblack", bold = on or false }
end

local function compass(line)
  local e = state.exits or {}
  local rows = {
    { dir_span("NW", e.northwest), { text = "  " }, dir_span("N", e.north), { text = "  " }, dir_span("NE", e.northeast) },
    { dir_span("W ", e.west),      { text = "  " }, { text = "◈", fg = "cyan" }, { text = "  " }, dir_span(" E", e.east) },
    { dir_span("SW", e.southwest), { text = "  " }, dir_span("S", e.south), { text = "  " }, dir_span("SE", e.southeast) },
  }
  return { spans = rows[line], width = 12, align = "center" }
end

-- Room name (+ up/down exits as badges, since the rose only covers the compass directions).
local function room_name_cell()
  local e = state.exits or {}
  local spans = { { text = "◈ ", fg = "cyan" }, { text = state.room_name or "somewhere", fg = "brightcyan" } }
  if e.up then spans[#spans + 1] = { text = "  ⤒U", fg = "brightgreen" } end
  if e.down then spans[#spans + 1] = { text = "  ⤓D", fg = "brightgreen" } end
  return { spans = spans }
end

-- Out of combat the exits rose sits on the RIGHT of the bottom panel, spanning the three rows next to
-- the stats. In combat the target takes the stats line's 4th slot and the rose shoots up to the top
-- panel (see update_top), so it's always the full rose — never a one-liner.
local function update_bottom()
  local fighting = state.fighting
  local stats = vital_cells()
  stats[#stats + 1] = fighting and target_cell() or compass(1)   -- 4th slot: target, or rose row 1
  local rows = { { cols = stats } }
  if fighting then
    rows[#rows + 1] = spells_row()
    rows[#rows + 1] = room_name_cell()
  else
    rows[#rows + 1] = { cols = { spells_row(),      compass(2) } }
    rows[#rows + 1] = { cols = { room_name_cell(),  compass(3) } }
  end
  panel.render(rows)
end

-- ============================ TOP PANEL (reference) ============================

-- span-list builders for the reference block (packed onto flex lines)
local function place_spans()
  local b = {}
  if state.position then b[#b + 1] = { text = "(" .. state.position .. ")", dim = true } end
  if state.walkdir and WALK_ARROW[state.walkdir] then
    b[#b + 1] = { text = "  " .. WALK_ARROW[state.walkdir], fg = "brightblue" }
  end
  if state.gold then b[#b + 1] = { text = string.format("  %dg", state.gold), fg = "yellow" } end
  return b
end

local function env_spans()
  local b = {}
  if state.daypart then b[#b + 1] = { text = state.daypart, fg = "yellow" } end
  if state.clock then b[#b + 1] = { text = "  " .. state.clock, dim = true } end
  if state.precip and state.precip > 0 then b[#b + 1] = { text = "  ☔", fg = "brightblue" } end
  return b
end

local function exp_spans()
  if not state.exp then return {} end
  local togo = state.expcap and (state.expcap - state.exp) or nil
  local b = { { text = "exp ", dim = true }, { text = tostring(state.exp), fg = "brightmagenta" } }
  if togo then
    b[#b + 1] = { text = string.format(" (%d to cap)", math.max(0, togo)),
                  fg = (togo <= 0 and "brightgreen") or "magenta" }
  end
  return b
end

local function effects_spans()
  local names = {}
  for k in pairs(state.effects or {}) do names[#names + 1] = k end
  table.sort(names)
  if #names == 0 then return {} end
  local b = { { text = "effects: ", dim = true } }
  for i, n in ipairs(names) do
    b[#b + 1] = { text = n, fg = "brightcyan" }
    if i < #names then b[#b + 1] = { text = ", ", dim = true } end
  end
  return b
end

-- Reference block: area + position/gold, then time/weather + progress/effects. (Room name and the
-- exits compass live at the bottom now; area name stays up here.)
local function reference_rows()
  local sep = { { text = "   " } }
  local area_place = { spans = cat({ { text = state.area or "", dim = true } }, sep, place_spans()) }
  local env_prog = { spans = cat(env_spans(), sep, exp_spans(), sep, effects_spans()) }
  return { area_place, env_prog }
end

-- Group roster (you + pets/groupmates): compact HP/MP/MV bars per member.
local function member_bar(label, cur, max, kind)
  return { spans = cat(
    { { text = label .. " ", dim = true } },
    gauge(cur, max, 6, kind),
    { { text = string.format(" %d/%d", cur or 0, max or 0), fg = "white" } }
  ) }
end

local function group_member_row(m)
  return { cols = {
    { spans = { { text = (m.flags and (m.flags .. " ") or ""), fg = "brightblack" },
                { text = m.name, fg = "brightwhite" } }, width = 26 },
    member_bar("HP", m.hp, m.maxhp, "hp"),
    member_bar("MP", m.mana, m.maxmana, "mp"),
    member_bar("MV", m.stam, m.maxstam, "mv"),
  } }
end

-- Minimap (top-right). Pulls the local map grid from AIPilot's `minimap()` and turns each grid line
-- into a fixed-width cell (a 2-space gutter keeps it off the left content). nil if the map is unknown.
local function minimap_cells()
  if not minimap then return nil end          -- AIPilot (which owns the map) not loaded
  local m = minimap(3, 3)                      -- 7×7 rooms, rendered ~13×7 (compact & square), trimmed
  if not m then return nil end
  -- Trim blank rows above/below the drawn content so the map top-aligns with the other widgets
  -- (otherwise the current room sits at the grid's centre and the empty padding reads as "below").
  local first, last
  for r = 1, m.h do
    if m.cells[r] and next(m.cells[r]) then first = first or r; last = r end
  end
  if not first then return nil end
  local out = {}
  for r = first, last do
    local line = m.cells[r] or {}
    local spans = { { text = "  " } }
    for c = 1, m.w do
      local cell = line[c]
      if cell then spans[#spans + 1] = { text = cell.ch, fg = cell.fg, bold = cell.bold }
      else spans[#spans + 1] = { text = " " } end
    end
    out[#out + 1] = { spans = spans, width = m.w + 2 }
  end
  return out
end

-- Append a fixed-width cell as the last column of a row (wrapping a single-line row into columns).
local function append_col(row, cell)
  if row.cols then
    local cols = {}
    for _, c in ipairs(row.cols) do cols[#cols + 1] = c end
    cols[#cols + 1] = cell
    return { cols = cols }
  end
  return { cols = { row, cell } }
end

local function update_top()
  local left = {}
  local g = state.group or {}
  if #g >= 2 then   -- show the roster only when you actually have pets/groupmates
    left[#left + 1] = { text = string.format("── group (%d) ──", #g), fg = "cyan", dim = true }
    for _, m in ipairs(g) do left[#left + 1] = group_member_row(m) end
  end
  if state.fighting then   -- the stats line is busy with the target, so the exits rose lives up here
    left[#left + 1] = { cols = { { text = "" }, compass(1) } }
    left[#left + 1] = { cols = { { spans = { { text = "exits", dim = true } } }, compass(2) } }
    left[#left + 1] = { cols = { { text = "" }, compass(3) } }
  end
  for _, r in ipairs(reference_rows()) do left[#left + 1] = r end

  -- Compose the minimap as a right-hand column, aligned row-for-row with the left content.
  local mini = minimap_cells()
  if not mini then panel.top(left); return end
  local rows, n = {}, math.max(#left, #mini)
  for i = 1, n do
    if left[i] and mini[i] then rows[i] = append_col(left[i], mini[i])
    elseif left[i] then rows[i] = left[i]
    else rows[i] = { cols = { { text = "" }, mini[i] } } end
  end
  panel.top(rows)
end

-- Called by the host once per server batch, after triggers have refreshed `state`.
function on_update()
  if not state or not state.hp then return end   -- nothing worth showing until the first prompt
  update_top()
  update_bottom()
end
