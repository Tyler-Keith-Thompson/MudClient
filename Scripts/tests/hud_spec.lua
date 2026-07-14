-- Specs for HUD.lua — the health/vital bars. These lock in the gauge math the player noticed drifting:
-- the fill is a pure function of (cur, max, width), so the SAME state must always draw the SAME bar.

local g = _HUD_TEST.gauge
local pct = _HUD_TEST.pct

-- gauge returns { {text=<filled>}, {text=<empty>} }; the filled run is the █s plus one partial block.
local function filled(cur, max, w) return g(cur, max, w or 8, "hp")[1].text end

test("pct clamps to [0,1] and guards divide-by-zero", function()
  expect(pct(50, 100)):near(0.5)
  expect(pct(150, 100)):eq(1)      -- overheal never overflows the bar
  expect(pct(-5, 100)):eq(0)
  expect(pct(10, 0)):eq(0)         -- max=0 -> 0, not nan/inf
  expect(pct(nil, nil)):eq(0)
end)

test("gauge endpoints: empty and full", function()
  expect(count(filled(0, 100), "█")):eq(0)
  expect(filled(0, 100)):eq("")
  expect(count(filled(100, 100), "█")):eq(8)   -- a full 8-wide bar is 8 solid cells, no partial
end)

test("gauge fills proportionally (whole cells)", function()
  expect(count(filled(50, 100), "█")):eq(4)    -- 50% of 8 == 4 solid cells
  expect(count(filled(25, 100), "█")):eq(2)
end)

test("gauge uses sub-cell resolution so it isn't rounded to the wrong whole cell", function()
  -- 80% of an 8-wide bar is 6.4 cells. Old whole-cell rounding drew 6 (=75%, visibly low); sub-cell
  -- draws 6 solid + a partial block, tracking the true ratio far more closely.
  expect(count(filled(80, 100), "█")):eq(6)
  expect(filled(80, 100)):contains("▍")        -- the 4/8 partial cell for the extra 0.4
end)

test("gauge is deterministic — identical state never drifts between render cycles", function()
  local first = filled(731, 950)
  for _ = 1, 25 do expect(filled(731, 950)):eq(first) end
  -- and a value with a partial cell, to cover the fractional path too
  local frac = filled(617, 900)
  for _ = 1, 25 do expect(filled(617, 900)):eq(frac) end
end)

test("next_level picks the cheapest class and computes remaining exp from the live pool", function()
  local nl = _HUD_TEST.next_level
  local classes = { Mage = { level = 8, cost = 27000 }, Cleric = { level = 3, cost = 32000 } }
  local r = nl(20000, classes)
  expect(r.name):eq("Mage")            -- cheapest cost is the "next class that can level up"
  expect(r.level):eq(8)
  expect(r.need):eq(7000)              -- 27000 cost - 20000 live pool
  local r2 = nl(30000, classes)        -- enough to afford the cheapest -> can level now
  expect(r2.need <= 0):truthy()
  expect(nl(1000, {})):falsy()         -- no class data yet
  expect(nl(1000, nil)):falsy()
end)

test("next_level returns ALL classes tied for cheapest, sorted deterministically", function()
  local nl = _HUD_TEST.next_level
  -- Single winner: names has exactly the one class, name/level mirror it.
  local one = nl(0, { Mage = { level = 5, cost = 1200 }, Cleric = { level = 4, cost = 1500 } })
  expect(#one.names):eq(1)
  expect(one.names[1]):eq("Mage")
  expect(one.name):eq("Mage")
  expect(one.level):eq(5)

  -- Two-way tie at the min cost: both names, sorted alphabetically (Thief < Warrior), same need.
  local two = nl(200, { Warrior = { level = 3, cost = 1200 }, Thief = { level = 7, cost = 1200 },
                        Mage = { level = 9, cost = 5000 } })
  expect(#two.names):eq(2)
  expect(two.names[1]):eq("Thief")     -- deterministic sort, not pairs() order
  expect(two.names[2]):eq("Warrior")
  expect(two.need):eq(1000)            -- 1200 - 200, shared by the tied pair

  -- Three-way tie: all three, sorted.
  local three = nl(0, { Warrior = { level = 1, cost = 900 }, Thief = { level = 2, cost = 900 },
                        Druid = { level = 3, cost = 900 } })
  expect(#three.names):eq(3)
  expect(three.names[1]):eq("Druid")
  expect(three.names[2]):eq("Thief")
  expect(three.names[3]):eq("Warrior")

  -- Determinism across repaints: the pick never flaps for a tie.
  for _ = 1, 25 do
    local r = nl(0, { Warrior = { level = 3, cost = 800 }, Thief = { level = 7, cost = 800 } })
    expect(r.names[1]):eq("Thief"); expect(r.names[2]):eq("Warrior")
  end
end)

-- join an exp_spans() result into one string so tie rendering is easy to assert on.
local function exp_text()
  local parts = {}
  for _, s in ipairs(_HUD_TEST.exp_spans()) do parts[#parts + 1] = s.text end
  return table.concat(parts)
end

test("exp_spans renders a tie as a slashed class list, single class keeps its next level number", function()
  local saved = state
  -- Single class: shows the target level number (5+1) and the need.
  state = { exp = 500, classes = { Mage = { level = 5, cost = 1200 } } }
  local single = exp_text()
  expect(single):contains("Mage 6 in 700")     -- 1200 - 500

  -- Two-way tie: both names slashed, no per-class level (levels differ), shared need.
  state = { exp = 200, classes = { Warrior = { level = 3, cost = 1200 }, Thief = { level = 7, cost = 1200 } } }
  local tie = exp_text()
  expect(tie):contains("Thief/Warrior in 1000")

  -- Tie you can already afford: "level a/b now".
  state = { exp = 2000, classes = { Warrior = { level = 3, cost = 1200 }, Thief = { level = 7, cost = 1200 } } }
  expect(exp_text()):contains("level Thief/Warrior now")
  state = saved
end)

test("exp_spans shows the live percent of the way to the next level (exp/cost)", function()
  local saved = state
  -- 960 of a 1200 cost = 80% of the way; need = 240.
  state = { exp = 960, classes = { Warrior = { level = 4, cost = 1200 } } }
  expect(exp_text()):contains("Warrior 5 in 240 (80%)")
  -- A micro step carries the percent too (100/500 = 20%).
  state = { exp = 100, classes = { Thief = { level = 0, cost = 500, micro = { done = 0, total = 2 } } } }
  expect(exp_text()):contains("Thief micro 0/2 in 400 (20%)")
  -- A tie shares one percent (300/1200 = 25%).
  state = { exp = 300, classes = { Warrior = { level = 3, cost = 1200 }, Thief = { level = 7, cost = 1200 } } }
  expect(exp_text()):contains("Thief/Warrior in 900 (25%)")
  -- Rounding never reads 100% while the level is still unaffordable (need > 0): clamped to 99%.
  state = { exp = 1199, classes = { Mage = { level = 5, cost = 1200 } } }
  expect(exp_text()):contains("(99%)")
  state = saved
end)

test("next_level carries the cheapest class's micro fraction (partial level-up)", function()
  local nl = _HUD_TEST.next_level
  local r = nl(0, { Thief = { level = 0, cost = 500, micro = { done = 0, total = 2 } },
                    Mage  = { level = 17, cost = 9000 } })
  expect(r.name):eq("Thief")
  expect(r.micro.done):eq(0); expect(r.micro.total):eq(2)
  expect(nl(0, { Mage = { level = 17, cost = 100 } }).micro):eq(nil)   -- full level-up → no micro
end)

test("exp_spans flags a partial (micro) level-up instead of showing a full next level", function()
  local saved = state
  -- Partial single class: show the micro fraction, NOT "Thief 1 in 400".
  state = { exp = 100, classes = { Thief = { level = 0, cost = 500, micro = { done = 0, total = 2 } } } }
  expect(exp_text()):contains("Thief micro 0/2 in 400")
  -- Affordable partial → "micro <class> now", not "level <class> now".
  state = { exp = 600, classes = { Thief = { level = 0, cost = 500, micro = { done = 1, total = 2 } } } }
  local now = exp_text()
  expect(now):contains("micro Thief now")
  expect(now:find("level Thief now", 1, true) == nil):truthy()
  state = saved
end)

-- ---- exp widget on the new 1.105 RPC model: state.exp_to_level = per-class % to next level, PER-MILLE --

test("exp_spans names the class(es) CLOSEST to levelling (max %) from state.exp_to_level (1.105 RPC)", function()
  local saved = state
  -- Per-mille %s indexed Mage/Cleric/Thief/Warrior/Necro/Druid: the two 94.4s are Cleric+Warrior (closest).
  state = { exp_to_level = { 603, 944, 517, 944, 724, 804 } }
  local t = exp_text()
  expect(t):contains("Cleric, Warrior")
  expect(t):contains("(94%)")
  state = saved
end)

test("exp_spans shows 'level:' with the class name when one has hit 100% (1000 per-mille)", function()
  local saved = state
  state = { exp_to_level = { 500, 1000, 300 } }   -- Cleric (index 2) at 100%
  local t = exp_text()
  expect(t):contains("level:")
  expect(t):contains("Cleric")
  state = saved
end)

test("exp_spans shows nothing when neither exp pool nor exp_to_level data is present", function()
  local saved = state
  state = {}
  expect(exp_text()):eq("")
  state = { exp_to_level = {} }
  expect(exp_text()):eq("")
  state = saved
end)

-- ---- inferred multi-opponent bars ------------------------------------------------------------------

local function bar_text(row)
  local parts = {}
  for _, s in ipairs(row.spans) do parts[#parts + 1] = s.text end
  return table.concat(parts)
end

test("opponent_bars renders one dim estimate row per other opponent, with the condition word", function()
  local ob = _HUD_TEST.opponent_bars
  local list = { { name = "a rat", pct = 3, est = true }, { name = "an orc", pct = 55, est = true } }
  local rows = ob(list, 4)
  expect(#rows):eq(2)
  expect(bar_text(rows[1])):contains("a rat")
  expect(bar_text(rows[1])):contains("near death")   -- pct 3 -> condition word
  expect(bar_text(rows[2])):contains("an orc")
  expect(bar_text(rows[2])):contains("many wounds")  -- pct 55
  -- estimates render dim (so they read as guesses, not exact readings)
  expect(rows[1].spans[1].dim):truthy()
end)

test("opponent_bars caps the list and shows a '+N more' tail on overflow", function()
  local ob = _HUD_TEST.opponent_bars
  local list = {}
  for i = 1, 6 do list[i] = { name = "mob" .. i, pct = 28, est = true } end
  local rows = ob(list, 4)
  expect(#rows):eq(5)                          -- 4 capped bars + the overflow tail
  expect(bar_text(rows[5])):contains("+2 more")
end)

test("opponent_bars is empty when there are no other opponents", function()
  expect(#_HUD_TEST.opponent_bars({}, 4)):eq(0)
end)

test("on_update paints the vitals from state (end-to-end smoke)", function()
  local saved = state
  state = { hp = 60, maxhp = 100, mana = 40, maxmana = 100, stam = 90, maxstam = 100 }
  local ok = pcall(function()
    local _, bottom = capture_update()
    expect(bottom):truthy()          -- it produced a bottom-panel spec
    expect(#bottom):ne(0)
  end)
  state = saved                       -- always restore the live state
  expect(ok):truthy()
end)

-- ---- middle truncation (the ♪ now-playing line) --------------------------------------------------

local tm = _HUD_TEST.truncate_middle

test("truncate_middle leaves short strings alone", function()
  expect(tm("combat_01", 36)):eq("combat_01")
end)

test("truncate_middle keeps both ends with an ellipsis, to the exact visible width", function()
  local s = "combat_01 · jungle_night · dungeon_ambient · cavern_drip"
  local out = tm(s, 20)
  expect(utf8.len(out)):eq(20)                 -- exactly the budget, in visible columns
  expect(out:sub(1, 4)):eq("comb")             -- kept the start
  expect(out:find("…") ~= nil):eq(true)        -- middle replaced
  expect(out:sub(-4)):eq("drip")               -- kept the end
end)

test("truncate_middle is UTF-8 safe across the multibyte '·' separator", function()
  -- 12 chars: "aa · bb · cc" — force a cut that lands near the separators
  local out = tm("aa · bb · cc", 7)
  expect(utf8.len(out)):eq(7)                  -- valid UTF-8, correct visible length (no split bytes)
end)

-- ---- lag widget (lag_rows) — differentiates a local UI hitch from server round-trip latency --------

local lag_rows = _HUD_TEST.lag_rows
local function row_text(row)
  local parts = {}
  for _, s in ipairs(row.spans or {}) do parts[#parts + 1] = s.text end
  return table.concat(parts)
end
local function lag_text(rows)
  local t = {}
  for _, r in ipairs(rows) do t[#t + 1] = row_text(r) end
  return table.concat(t, "\n")
end
local function with_lag(snapshot, fn)
  local saved = lag_status
  _G.lag_status = function() return snapshot end
  local ok, err = pcall(fn)
  _G.lag_status = saved
  if not ok then error(err, 2) end
end

test("lag widget is hidden until there's a real sample", function()
  with_lag({ ui_ms = 0, ui_age_ms = -1, net_ms = 0, net_age_ms = -1 }, function()
    expect(#lag_rows(22)):eq(0)
  end)
end)

test("lag widget: a healthy round-trip shows a dim net readout, no alert", function()
  with_lag({ ui_ms = 0, ui_age_ms = -1, net_ms = 48, net_age_ms = 200 }, function()
    local txt = lag_text(lag_rows(22))
    expect(txt):contains("net 48ms")
    expect(txt:find("⚠")):eq(nil)
  end)
end)

test("lag widget: a recent slow round-trip raises a ⚠ net alert with its duration", function()
  with_lag({ ui_ms = 0, ui_age_ms = -1, net_ms = 620, net_age_ms = 500 }, function()
    expect(lag_text(lag_rows(22))):contains("⚠ net 620ms")
  end)
end)

test("lag widget: a recent UI hitch raises a ⚠ UI alert, DISTINCT from the network line", function()
  with_lag({ ui_ms = 350, ui_age_ms = 400, net_ms = 45, net_age_ms = 1000 }, function()
    local txt = lag_text(lag_rows(22))
    expect(txt):contains("⚠ UI hitch 350ms")   -- the UI hitch is flagged...
    expect(txt):contains("net 45ms")             -- ...and the healthy network line is shown, un-alerted
  end)
end)

test("lag widget: an OLD UI hitch reads dim as 'UI last', not a live alert", function()
  with_lag({ ui_ms = 350, ui_age_ms = 30000, net_ms = 45, net_age_ms = 500 }, function()
    local txt = lag_text(lag_rows(22))
    expect(txt):contains("UI last 350ms")
    expect(txt:find("⚠")):eq(nil)
  end)
end)

-- ---- minimap on the new 1.105 RPC model (the ;smap; server-rendered grid, state.dclient_map) ---------

local map_glyph = _HUD_TEST.map_glyph
local dclient_map_rows = _HUD_TEST.dclient_map_rows
local dclient_terrain_section = _HUD_TEST.dclient_terrain_section
local minimap_cells_from_dclient = _HUD_TEST.minimap_cells_from_dclient

-- A real ;smap; block (captured live): 11 terrain rows (width 11), then a 3-row 4-chars-per-cell
-- room-id/coords section (width 44) that must be IGNORED by terrain extraction.
local SMAP = table.concat({
  "@@@@@@@@@@@", "@@@@@@@@@@@", "@@@DD@@@@@D", "@@@D@D@@@@@", "@@@D@@D@DB@",
  "@@DD@D@D@DC", "@@@DA@CD@D@", "@@@@D@@@C@@", "@@@@@@@@@DD", "@@@@@@@@@@@", "@@@@@@@@@@@",
  "@@@@@@@@@@@@A@IPBDL@@@@@@@@@@@@@@@@@@@@@BDO@",
  "@@@@@@@@@@@@A@LABDC@APAH@@@@@@@@@@@@@@@@BFF@",
  "@@@@@@@@DBV@BBR@BDZ@A@F@B@Q@@@@@BDB@BDT@BD]@",
}, "\r\n")

test("dclient_map_rows splits \\r\\n-separated rows and drops a trailing blank", function()
  local rows = dclient_map_rows("@@@\r\nABC\r\n@@@")
  expect(#rows):eq(3)
  expect(rows[1]):eq("@@@"); expect(rows[2]):eq("ABC"); expect(rows[3]):eq("@@@")
  -- a trailing \r\n shouldn't add a phantom 4th blank row
  local rows2 = dclient_map_rows("@@@\r\nABC\r\n")
  expect(#rows2):eq(2)
end)

test("map_glyph: empty code is a dim dot, terrain codes are coloured blocks", function()
  local g0, fg0 = map_glyph(0)
  expect(g0):eq("·"); expect(fg0):eq("brightblack")
  local g1, fg1 = map_glyph(1)
  expect(g1):eq("▪"); expect(fg1):eq("green")          -- first palette colour
  local _, fg2 = map_glyph(2)
  expect(fg2):eq("brightgreen")                        -- second palette colour
end)

test("dclient_terrain_section picks the widest-run terrain grid, ignoring the coords section", function()
  local sec = dclient_terrain_section(dclient_map_rows(SMAP))
  expect(sec):truthy()
  expect(#sec):eq(11)                                  -- the 11 terrain rows, not the 3 coord rows
  expect(#sec[1]):eq(11)                               -- width 11 (not the 44-wide coord section)
end)

test("minimap_cells_from_dclient renders the terrain section, player-centered", function()
  local out = minimap_cells_from_dclient(SMAP)
  expect(out):truthy()
  expect(#out):eq(11)
  expect(out[1].width):eq(11 + 2)                      -- width + 2-space gutter
  expect(out[1].spans[1].text):eq("  ")                -- gutter
  expect(out[1].spans[2].text):eq("·")                 -- code 0 -> dim dot
  -- dead-center cell (row 6, col 6) is marked as "you"
  expect(out[6].spans[1 + 6].text):eq("◉")
  expect(out[6].spans[1 + 6].fg):eq("brightwhite")
end)

test("minimap_cells_from_dclient returns nil when there is no terrain section", function()
  expect(minimap_cells_from_dclient("")):eq(nil)
  expect(minimap_cells_from_dclient("@@@\r\nABC")):eq(nil)   -- too few rows to be a grid
end)
