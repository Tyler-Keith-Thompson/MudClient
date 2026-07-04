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
