-- HUD.lua — a declarative top-of-screen panel, fed by the shared `state` table (populated by the
-- kxwt triggers in AlterAeon.lua). The generic Swift PanelHost freezes the top rows of the terminal
-- and scrolls the game output beneath them; here we just describe what to draw.
--
-- The spec handed to panel.render is a list of ROWS. A row is either:
--   { text = "..", fg = "..", ... }                       -- one plain styled line
--   { spans = { {text=..,fg=..}, {text=..} } }            -- one line of several styled runs
--   { cols  = { <cell>, <cell>, ... } }                   -- equal-width columns; each cell is a
--                                                            -- { text=.. } / { spans=.. } like above
-- A span/style table understands: text, fg, bg (named 16-colour or {r,g,b}), bold, dim, reverse,
-- underline. Widget/layout logic lives entirely here — edit + `#ai reload` to iterate live.

-- concat several span-lists into one (for building a line out of pieces)
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

-- A little bar: `width` cells, filled proportionally, filled part in `color`, empty part dim.
local function gauge(cur, max, width, color)
  local w = width or 8
  local filled = math.floor(pct(cur, max) * w + 0.5)
  return {
    { text = string.rep("█", filled), fg = color },
    { text = string.rep("░", w - filled), fg = "brightblack" },
  }
end

-- "LABEL cur/max ███░░░" as one column cell.
local function vital(label, cur, max, color)
  return { spans = cat(
    { { text = label .. " ", dim = true },
      { text = string.format("%d/%d ", cur or 0, max or 0), fg = "white" } },
    gauge(cur, max, 8, color)
  ) }
end

local function vitals_row()
  return { cols = {
    vital("HP", state.hp, state.maxhp, "red"),
    vital("MP", state.mana, state.maxmana, "blue"),
    vital("SP", state.stam, state.maxstam, "green"),
  } }
end

local function combat_row()
  if state.fighting then
    return { spans = cat(
      { { text = "⚔ ", fg = "yellow" },
        { text = (state.fight_name or "?") .. " ", fg = "brightred" } },
      gauge(state.fight_pct, 100, 14, "red"),
      { { text = string.format(" %d%%", state.fight_pct or 0), dim = true } }
    ) }
  end
  return { text = "— not in combat —", fg = "brightblack" }
end

local function room_row()
  return { cols = {
    { spans = { { text = "◈ ", fg = "cyan" },
                { text = state.room_name or "somewhere", fg = "brightcyan" } } },
    { spans = { { text = state.area or "", dim = true } } },
    { spans = { { text = state.position and ("(" .. state.position .. ")") or "", dim = true } } },
  } }
end

-- Called by the host once per server batch, after triggers have refreshed `state`.
function on_update()
  if not state or not state.hp then return end   -- nothing worth showing until the first prompt
  panel.render({
    vitals_row(),
    combat_row(),
    room_row(),
  })
end
