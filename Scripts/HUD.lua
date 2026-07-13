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
-- underline. All widget/layout logic lives here — edit + pilot.reload() to iterate live.

-- Defensive: read the shared state through a table that always exists, so HUD has no load-order
-- dependency on AlterAeon. AlterAeon owns and fills the schema (merging into this if we ran first);
-- if it hasn't yet, on_update's `not state.hp` guard keeps the panels blank until the first prompt.
state = state or {}

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

-- Fractional block glyphs (1/8 .. 8/8 of a cell). Sub-cell resolution means the bar tracks the true
-- ratio to within 1/8 of a cell instead of a whole cell, so it isn't "slightly off" from the % and
-- grows smoothly as HP changes rather than jumping a full cell at a time.
local BLOCKS = { "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" }
local function gauge(cur, max, width, kind)
  local w = width or 8
  local p = pct(cur, max)
  local eighths = math.floor(p * w * 8 + 0.5)                    -- total eighths-of-a-cell to fill
  local full = math.floor(eighths / 8)                           -- whole filled cells
  local rem = eighths % 8                                        -- leftover eighths → one partial cell
  local filled = string.rep("█", full) .. (rem > 0 and BLOCKS[rem] or "")
  local pad = w - full - (rem > 0 and 1 or 0)                    -- keep total visible width == w
  return {
    { text = filled, fg = vital_rgb(kind, p), bold = (p <= 0.25) },
    { text = string.rep("░", math.max(0, pad)), fg = "brightblack" },
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

-- Fighting, by ANY evidence: the exact kxwt_fighting target, or the text-inferred engaged() state
-- (nomelee fights get NO kxwt_fighting at all — proven by raw captures — so the combat block must not
-- gate on state.fighting alone). `engaged` is AlterAeon's; guard for load order.
local function in_fight()
  return state.fighting or (engaged ~= nil and engaged())
end

-- Estimate rendering shared by the promoted target cell and the opponent bars. COND_WORD maps the
-- ladder pcts back to a short condition word; est_gauge is a dim hollow bar so estimates never read
-- as exact readings. pct may be nil (mob sighted in melee lines but no condition line yet) -> empty
-- bar, "?" word.
local OPP_CAP = 4
local COND_WORD = { [3] = "near death", [8] = "mortally wounded", [15] = "awful", [28] = "pretty hurt",
                    [42] = "nasty wounds", [55] = "many wounds", [68] = "small wounds",
                    [82] = "scratches", [95] = "healthy" }
local function cond_word(pct)
  if pct == nil then return "?" end
  return COND_WORD[pct] or (tostring(pct) .. "%")
end
-- A dim, hollow gauge to visually separate an ESTIMATE from the solid exact vital/target bars.
local function est_gauge(p100, width)
  local w = width or 8
  local full = math.floor(math.max(0, math.min(1, (p100 or 0) / 100)) * w + 0.5)
  return {
    { text = string.rep("▓", full), fg = "brightblack", dim = true },
    { text = string.rep("░", math.max(0, w - full)), fg = "brightblack", dim = true },
  }
end

-- The enemy: name + health bar + %, as a column that rides alongside the vitals (wider via flex so
-- the name has room). With an exact kxwt target that's the solid bar; in an engaged-only (nomelee)
-- fight the best-known inferred opponent is PROMOTED here as a clearly-marked estimate ("~"), so the
-- fight is never bar-less; engaged with no name known yet shows a plain "engaged" flag.
local function target_cell(promoted)
  if state.fighting then
    return { flex = 1.6, spans = cat(
      { { text = "⚔ ", fg = "yellow" },
        { text = (state.fight_name or "?") .. " ", fg = "brightred" } },
      gauge(state.fight_pct, 100, 10, "hp"),
      { { text = string.format(" %d%%", state.fight_pct or 0), dim = true } }
    ) }
  end
  if promoted then
    return { flex = 1.6, spans = cat(
      { { text = "⚔ ", fg = "yellow" },
        { text = (promoted.name or "?") .. " ", fg = "brightred", dim = true } },
      est_gauge(promoted.pct, 10),
      { { text = " ~" .. cond_word(promoted.pct), fg = "brightblack", dim = true } }
    ) }
  end
  if in_fight() then
    return { flex = 1.6, spans = { { text = "⚔ engaged", fg = "yellow", dim = true } } }
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

-- Active spells (buffs) — what's currently up on you. Membership is the point; no timing is tracked.
local function spells_row()
  local spans = {}
  -- Can't-cast warning first (kxwt_action >= 50 blocks spellcasting — butchering, turning, etc.).
  if state.action and state.action >= 50 then
    spans[#spans + 1] = { text = "⊘ can't cast   ", fg = "brightred", bold = true }
  end
  local names = {}
  for k in pairs(state.spells or {}) do names[#names + 1] = k end
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

-- Inferred bars for the OTHER mobs you're fighting (the current target — exact or promoted-estimate —
-- has its own bar on the stats line). The protocol only reports one target, so these healths are
-- ESTIMATED from AlterAeon's condition ladder (see AlterAeon.lua) — rendered dim, with a hollow ▓ fill
-- and the condition WORD, so they read plainly as guesses rather than exact readings. A tilde marks the
-- estimate. One row per opponent (capped; a "+N more" tail on overflow). `list` is active_opponents()'s
-- output: { {name, pct, est}, ... }, already newest-first.
local function opponent_bars(list, cap)
  cap = cap or OPP_CAP
  local rows, n = {}, #list
  local shown = math.min(n, cap)
  for i = 1, shown do
    local o = list[i]
    local word = cond_word(o.pct)
    rows[#rows + 1] = { spans = cat(
      { { text = "⚔ ", fg = "brightblack", dim = true },
        { text = (o.name or "?") .. " ", fg = "brightred", dim = true } },
      est_gauge(o.pct, 8),
      { { text = "  ~" .. word, fg = "brightblack", dim = true } }
    ) }
  end
  if n > cap then
    rows[#rows + 1] = { spans = { { text = string.format("  +%d more engaged", n - cap),
                                    fg = "brightblack", dim = true } } }
  end
  return rows
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
  local fighting = in_fight()                    -- kxwt target OR text-inferred (nomelee) engagement
  -- Inferred opponents. Without an exact kxwt target (nomelee) the best-known one is PROMOTED into
  -- the target slot; the rest render as estimate bars below.
  local others, promoted = {}, nil
  if fighting and active_opponents then
    others = active_opponents(os.time())
    if not state.fighting and #others > 0 then promoted = table.remove(others, 1) end
  end
  local stats = vital_cells()
  stats[#stats + 1] = fighting and target_cell(promoted) or compass(1)   -- 4th slot: target, or rose row 1
  local rows = { { cols = stats } }
  if fighting then
    -- Inferred bars for any OTHER mobs you're engaged with, between the target line and your buffs.
    for _, r in ipairs(opponent_bars(others)) do rows[#rows + 1] = r end
    rows[#rows + 1] = spells_row()
    rows[#rows + 1] = room_name_cell()
  else
    rows[#rows + 1] = { cols = { spells_row(),      compass(2) } }
    rows[#rows + 1] = { cols = { room_name_cell(),  compass(3) } }
  end
  panel.render(rows)
end

-- ============================ TOP PANEL (reference) ============================

-- Middle-truncate to `max` VISIBLE columns with an ellipsis, keeping both ends. UTF-8 safe: the "·"
-- track separator is multibyte, so we slice on CHARACTER offsets (utf8.offset), never bytes — a byte
-- slice could split a "·" and print garbage. Used to keep the ♪ now-playing line bounded when several
-- soundtracks are layered.
local function truncate_middle(s, max)
  local n = utf8.len(s)
  if not n or n <= max or max < 2 then return s end
  local keep = max - 1                          -- one column for the ellipsis
  local left = math.floor(keep / 2)
  local right = keep - left
  local lend = utf8.offset(s, left + 1) - 1     -- last byte of the first `left` characters
  local rstart = utf8.offset(s, n - right + 1)  -- first byte of the last `right` characters
  return s:sub(1, lend) .. "…" .. s:sub(rstart)
end
local MUSIC_NAMES_MAX = 36                       -- max width of the joined track list on the ♪ line

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
  -- Sky/weather from kxwt_sky (outdoors / sky-visible / overcast).
  if state.outdoors == false then
    b[#b + 1] = { text = "  ⌂ indoors", fg = "brightblack" }
  elseif state.outdoors == true then
    if state.overcast then
      b[#b + 1] = { text = "  ☁ overcast", fg = "brightblack" }
    elseif state.sky_visible == false then
      b[#b + 1] = { text = "  ⛰ sheltered", fg = "brightblack" }
    else
      local night = state.daypart and (state.daypart:find("night") or state.daypart:find("evening")
                     or state.daypart == "midnight" or state.daypart:find("dusk"))
      b[#b + 1] = { text = night and "  ☾ clear" or "  ☀ clear", fg = "brightyellow" }
    end
  end
  if state.precip and state.precip > 0 then b[#b + 1] = { text = "  ☔", fg = "brightblue" } end
  -- ♪ now-playing mood, from the kxwt_music channels (soundtrack/track_combat_01 -> combat_01).
  local playing = {}
  for _, tr in pairs(state.music or {}) do
    playing[#playing + 1] = tr:gsub("^.*/", ""):gsub("^track_", "")
  end
  if #playing > 0 then
    table.sort(playing)
    b[#b + 1] = { text = "  ♪ " .. truncate_middle(table.concat(playing, " · "), MUSIC_NAMES_MAX),
                  fg = "brightmagenta" }
  end
  return b
end

-- Given the live exp POOL and the per-class costs scraped from the `level` table, return the cheapest
-- class(es) to level next and how much more experience it needs (need <= 0 means you can level it now),
-- or nil when we have no class data yet. The game itself advises levelling your cheapest class.
-- When SEVERAL classes tie for the minimum cost, ALL of them are returned in `names`, sorted by name so
-- the pick is deterministic across repaints — pairs() order is unstable, and without the sort a tie
-- would flap between class names between paints. `name`/`level` mirror names[1] for the single case.
local function next_level(exp, classes)
  local min_cost
  for _, c in pairs(classes or {}) do
    if c.cost and (not min_cost or c.cost < min_cost) then min_cost = c.cost end
  end
  if not min_cost then return nil end
  local names, level_of, micro_of = {}, {}, {}
  for name, c in pairs(classes or {}) do
    if c.cost == min_cost then names[#names + 1] = name; level_of[name] = c.level; micro_of[name] = c.micro end
  end
  table.sort(names)
  return { names = names, name = names[1], level = level_of[names[1]],
           micro = micro_of[names[1]], cost = min_cost, need = min_cost - (exp or 0) }
end

local function exp_spans()
  if not state.exp then return {} end
  local b = { { text = "exp ", dim = true }, { text = tostring(state.exp), fg = "brightmagenta" } }
  -- Experience to level the cheapest class (the actually-useful number). Uses live exp + cached costs.
  -- On a tie for cheapest, name EVERY tied class ("warrior/thief") so the pick reads as deliberate
  -- rather than an arbitrary winner. The per-class next-level number is only shown for a single class
  -- (in a tie the levels differ and the point is the shared cost/need, so it's dropped to stay compact).
  local nl = next_level(state.exp, state.classes)
  if nl then
    local label = table.concat(nl.names, "/")
    -- A partial (micro) level-up: the game splits this class's next level into `total` steps. Flag it so
    -- "▲ thief 1" doesn't read as a full level-up when it's really the next micro step ("micro 0/2").
    local micro = (#nl.names == 1) and nl.micro or nil
    -- How far the LIVE exp pool has come toward this cost — exp/cost, i.e. (cost - need)/cost. This is the
    -- same number the game prints in its `( 80%)` column, but computed live so it climbs as you gain exp
    -- between `level` runs (the column freezes until you re-scrape). Clamped to 99 for the not-yet cases so
    -- rounding never shows "100%" while `need` is still positive. `%%` for a literal percent sign.
    local pctstr = ""
    if nl.cost and nl.cost > 0 then
      local pct = math.floor((nl.cost - nl.need) / nl.cost * 100)
      pct = (pct < 0 and 0) or (pct > 99 and 99) or pct
      pctstr = string.format(" (%d%%)", pct)
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
  -- The per-kill cap, labelled honestly (it's a ceiling on one kill's exp, not progress to a level).
  if state.expcap then b[#b + 1] = { text = string.format("  cap/kill %d", state.expcap), dim = true } end
  return b
end

-- Reference block: area + position/gold, then time/weather + progress. (Room name and the exits
-- compass live at the bottom now; area name stays up here.) Active buffs are shown by the single
-- `spells` widget on the bottom panel (state.spells, kept live by kxwt_spellup/spelldown) — there is
-- deliberately no separate "effects" widget: state.effects (kxwt_spst) has no expiry signal, so it
-- accumulates stale entries and would show buffs that already dropped.
local function reference_rows()
  local sep = { { text = "   " } }
  local area_place = { spans = cat({ { text = state.area or "", dim = true } }, sep, place_spans()) }
  local env_prog = { spans = cat(env_spans(), sep, exp_spans()) }
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

-- Interpret the kxwt group <tag> (composable): X=you, P=player, M=your minion, O=other's minion,
-- ?=mob; L=leader, T=tanking, N=no-melee, -=NOT in the room with you.
local function group_member_row(m)
  local tag = m.flags or ""
  local absent = tag:find("-", 1, true) ~= nil
  local name_fg = "brightwhite"                                   -- you / player
  if tag:find("O", 1, true) then name_fg = "brightblack"          -- someone else's minion
  elseif tag:find("M", 1, true) then name_fg = "cyan"             -- your minion/pet
  elseif tag:find("?", 1, true) then name_fg = "yellow" end       -- some other mob
  local spans = {}
  if tag:find("L", 1, true) then spans[#spans + 1] = { text = "★", fg = "brightyellow" } end  -- leader
  if tag:find("T", 1, true) then spans[#spans + 1] = { text = "⛨", fg = "brightcyan" } end    -- tanking
  if tag:find("N", 1, true) then spans[#spans + 1] = { text = "∅", fg = "brightblack" } end    -- no-melee
  if #spans > 0 then spans[#spans + 1] = { text = " " } end
  spans[#spans + 1] = { text = m.name, fg = name_fg, dim = absent }
  if absent then spans[#spans + 1] = { text = " ·away", fg = "brightblack" } end
  return { cols = {
    { spans = spans, width = 26 },
    member_bar("HP", m.hp, m.maxhp, "hp"),
    member_bar("MP", m.mana, m.maxmana, "mp"),
    member_bar("MV", m.stam, m.maxstam, "mv"),
  } }
end

-- Minimap (top-right). Pulls the local map grid from AIPilot's `minimap()` and turns each grid line
-- into a fixed-width cell (a 2-space gutter keeps it off the left content). nil if the map is unknown.
local function minimap_cells()
  if not minimap then return nil end          -- AIPilot (which owns the map) not loaded
  local m = minimap(3, 2)                      -- 7×5 rooms, rendered ~25×9 (explicit connectors)
  if not m then return nil end
  -- Return the FULL window (no trimming): the grid is built with you at its centre, so keeping every
  -- row keeps you centred — with empty space to the north when there's nothing mapped that way, rather
  -- than ramming you against the top edge.
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

-- Append a fixed-width cell as the last column of a row (wrapping a single-line row into columns).
-- Append `cell` as a new column of `row`. IMPORTANT: the panel renderer does NOT recurse into a nested
-- `cols` (a column value only ever exposes `spans`/`text` — see PanelHost.parseColumn), so a cell that is
-- ITSELF a multi-column band (`{ cols = { a, b } }`) must be FLATTENED into sibling columns here, not
-- nested (nesting renders blank). Leaf cells (spans/text) append as one column as before.
local function append_col(row, cell)
  local cols = {}
  if row.cols then for _, c in ipairs(row.cols) do cols[#cols + 1] = c end
  else cols[#cols + 1] = row end
  if cell.cols then for _, c in ipairs(cell.cols) do cols[#cols + 1] = c end
  else cols[#cols + 1] = cell end
  return { cols = cols }
end

-- Promise widget — sits UNDER the minimap (right column). One row per in-flight promise from
-- active_promises(): the typed pipe line ("recover | explore") or the action's label, truncated to the
-- column, dimmed while still cold, capped with a "+N more" tail. Empty when nothing's pending, so the
-- widget simply isn't there. `width` matches the minimap so the columns line up.
local PROMISE_CAP = 6
local function promise_rows(width)
  if not active_promises then return {} end          -- Promise.lua not loaded
  local list = active_promises()
  if #list == 0 then return {} end
  local rows = { { spans = { { text = "  promises", fg = "cyan", dim = true } }, width = width } }
  local textw = math.max(6, width - 4)               -- 2-space gutter + a little breathing room
  local shown = math.min(#list, PROMISE_CAP)
  for i = 1, shown do
    local p = list[i]
    local desc = p.desc or "?"
    if #desc > textw then desc = desc:sub(1, textw - 1) .. "…" end
    rows[#rows + 1] = { spans = { { text = "  " },
                                  { text = desc, fg = "magenta", dim = (p.state == "cold") } }, width = width }
  end
  if #list > shown then
    rows[#rows + 1] = { spans = { { text = string.format("  +%d more", #list - shown), dim = true } },
                        width = width }
  end
  return rows
end

-- Lag widget — sits to the LEFT of the promise widget (right column; see update_top's side-by-side zip).
-- Differentiates a LOCAL UI hitch (the
-- terminal's own main loop stalling — a surprisingly common thing, measured by a Swift heartbeat on the
-- UI queue) from SERVER round-trip latency (time from your last command to the next prompt). A recent
-- spike shows a bright ⚠ alert with its duration; otherwise a dim readout of the last figures. lag_status()
-- returns {ui_ms, ui_age_ms, net_ms, net_age_ms}; an age of -1 means "never measured yet".
local LAG_UI_ALERT  = 100     -- ms: a UI hitch this big is worth flagging
local LAG_NET_ALERT = 300     -- ms: a server round-trip this slow is worth flagging
local LAG_RECENT_MS = 6000    -- ms: a spike counts as "happening now" (bright alert) for this long after
local function lag_row(label, ms, alert)
  local val = string.format("%dms", math.floor((ms or 0) + 0.5))
  if alert then
    return { spans = { { text = "  ⚠ " .. label .. " ", fg = "brightred", bold = true },
                       { text = val, fg = "brightred", bold = true } } }
  end
  return { spans = { { text = "  " .. label .. " ", dim = true }, { text = val, fg = "green", dim = true } } }
end
local function lag_rows(width)
  if not lag_status then return {} end                 -- host builtin not present
  local s = lag_status()
  if type(s) ~= "table" then return {} end
  local ui_ms, ui_age  = s.ui_ms or 0, s.ui_age_ms or -1
  local net_ms, net_age = s.net_ms or 0, s.net_age_ms or -1
  local ui_hit  = ui_age >= 0 and ui_ms > LAG_UI_ALERT               -- a UI hitch has been recorded
  local net_ok  = net_age >= 0                                       -- we have a round-trip sample
  if not (ui_hit or net_ok) then return {} end                       -- nothing to show yet
  local ui_now  = ui_hit and ui_age < LAG_RECENT_MS                  -- ...and it just happened
  local net_bad = net_ok and net_ms > LAG_NET_ALERT and net_age < LAG_RECENT_MS
  local rows = {}
  local function W(r) r.width = width; rows[#rows + 1] = r end
  W({ spans = { { text = "  lag", fg = (ui_now or net_bad) and "brightred" or "cyan",
                  dim = not (ui_now or net_bad) } } })
  if net_ok then W(lag_row("net", net_ms, net_bad)) end
  if ui_hit  then W(lag_row(ui_now and "UI hitch" or "UI last", ui_ms, ui_now)) end
  return rows
end

-- The promise/lag widgets used to inherit the minimap's narrow width, leaving them jammed into the far
-- right column. Instead, widen them so their LEFT edge lands just past the group's stamina (MV) numbers.
-- We reproduce the group-row column math ([name:26][HP|MP|MV: flex 1 each][minimap: mw]): each vital is
-- (W - 26 - mw)/3 wide and MV's "MV �<gauge> nnn/nnn" sits in its first ~STAM_W cells, so the widget should
-- span from there to the right edge. Falls back gracefully (never NARROWER than the minimap) on skinny
-- terminals or when the width is unknown.
local GROUP_NAME_W = 26      -- group_member_row's name cell width
local STAM_W       = 18      -- "MV " + 6-cell gauge + " nnn/nnn": where the stamina numbers end
local LAG_COL_W    = 20      -- fixed left sub-column for the lag widget (longest line "  ⚠ UI hitch nnnms")
local function term_width()
  if type(__term_cols) ~= "function" then return 80 end
  local ok, n = pcall(__term_cols)
  return (ok and type(n) == "number" and n > 0) and n or 80
end
local function widget_width(mw)
  local W = term_width()
  local vital_w = (W - GROUP_NAME_W - mw) / 3           -- one HP/MP/MV column
  local left_edge = GROUP_NAME_W + 2 * vital_w + STAM_W -- just past the MV numbers
  local w = math.floor(W - left_edge + 0.5)
  return math.max(mw, math.min(w, W - 40))              -- never narrower than the minimap; leave room for ref text
end

local function update_top()
  local left = {}
  local g = state.group or {}
  if #g >= 2 then   -- show the roster only when you actually have pets/groupmates
    left[#left + 1] = { text = string.format("── group (%d) ──", #g), fg = "cyan", dim = true }
    for _, m in ipairs(g) do left[#left + 1] = group_member_row(m) end
  end
  if in_fight() then   -- the stats line is busy with the target, so the exits rose lives up here
    left[#left + 1] = { cols = { { text = "" }, compass(1) } }
    left[#left + 1] = { cols = { { spans = { { text = "exits", dim = true } } }, compass(2) } }
    left[#left + 1] = { cols = { { text = "" }, compass(3) } }
  end
  for _, r in ipairs(reference_rows()) do left[#left + 1] = r end

  -- Compose the minimap as a right-hand column, aligned row-for-row with the left content. EVERY left
  -- row gets a minimap cell of the SAME fixed width — a blank one where the map has no content — so the
  -- left columns (the group bars) keep identical widths whether or not the map reaches that row.
  -- Right column = the minimap, then the promise widget beneath it. Width tracks the minimap (or a
  -- default when there's no map) so both stay aligned with the left content.
  local mini = minimap_cells()
  local mw = (mini and mini[1] and mini[1].width) or 26
  -- The minimap keeps its own (narrow) width; the promise/lag widgets get a WIDER one so they line up just
  -- after the group's stamina column instead of being crammed under the minimap.
  local ww = widget_width(mw)
  local right = {}
  if mini then for _, m in ipairs(mini) do right[#right + 1] = m end end
  -- The LAG widget sits to the LEFT of the PROMISES widget (side by side), so the two short readouts SHARE
  -- rows instead of stacking — the widget band stays vertically compact. lag takes a fixed narrow left
  -- sub-column (its text is never truncated); promises flex into the rest. When there's no lag, promises
  -- reclaim the full width (no empty left gutter).
  local lrows = lag_rows(math.min(LAG_COL_W, ww))     -- width only tags the cell; lag text isn't truncated
  local have_lag = #lrows > 0
  local prom_w = have_lag and math.max(10, ww - LAG_COL_W) or ww
  local lag_w  = have_lag and (ww - prom_w) or ww
  local prows = promise_rows(prom_w)
  -- Every GROUP-MEMBER row carries the HP/MP/MV bars, and their flex widths depend on the right cell's
  -- width — so those rows MUST get a minimap-width (mw) cell or the bars compress and misalign (the "last
  -- spider offset" bug). The group is often TALLER than the minimap, so when we're about to place the WIDER
  -- widget band, first pad the right column with blank mw cells to cover every group row; the widgets then
  -- land on the reference rows below, where the wider width is fine. (No widgets → no padding, so a
  -- widget-less panel stays plain and the group rows fall back to the mw `blank` below.)
  if #prows > 0 or #lrows > 0 then
    local group_rows = (#g >= 2) and (1 + #g) or 0   -- header + one row per member
    while #right < group_rows do right[#right + 1] = { text = "", width = mw } end
    if #right > 0 then right[#right + 1] = { text = "", width = ww } end   -- gap under the map
    -- Zip lag (left) + promises (right) row-for-row into one band of width ww, blank-filling the shorter
    -- side. With no lag, each promise row goes in at full width (no empty lag column on the left).
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
  local rows, n = {}, math.max(#left, #right)
  for i = 1, n do
    local m = right[i] or blank
    if left[i] then rows[i] = append_col(left[i], m)
    else rows[i] = append_col({ text = "" }, m) end   -- append_col flattens a widget-band cell (m.cols)
  end
  panel.top(rows)
end

-- Called by the host once per server batch, after triggers have refreshed `state`.
function on_update()
  if not state or not state.hp then return end   -- nothing worth showing until the first prompt
  update_top()
  update_bottom()
end

-- Pure, side-effect-free helpers exposed for the test harness (see Scripts/tests/hud_spec.lua). Not
-- used by the live client — kept in one place so the split-out of this file stays honest about seams.
_HUD_TEST = { pct = pct, gauge = gauge, vital_rgb = vital_rgb, next_level = next_level,
              exp_spans = exp_spans, compass = compass, group_member_row = group_member_row,
              append_col = append_col, opponent_bars = opponent_bars,
              target_cell = target_cell, cond_word = cond_word, in_fight = in_fight,
              truncate_middle = truncate_middle, lag_rows = lag_rows }
