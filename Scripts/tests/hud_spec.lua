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
