-- Specs for HUD.lua's panel LAYOUT building (the part slated to become width-aware). These pin the
-- current row/column structure of the bottom (combat) and top (reference) panels — how many rows, and
-- which cells go where in the fighting vs out-of-combat modes — plus the pure cell builders (compass,
-- group_member_row, append_col) those layouts are assembled from. The exact styling of the vital bars is
-- already covered by hud_spec.lua; here we lock the SHAPE that the width-aware refactor must preserve.

local compass          = _HUD_TEST.compass
local group_member_row = _HUD_TEST.group_member_row
local append_col       = _HUD_TEST.append_col

test("compass builds a centered 12-wide rose cell, lighting only the available exits", function()
  local saved = state
  state = { exits = { north = true } }
  local row = compass(1)                       -- top rose line: NW  N  NE
  expect(row.width):eq(12)
  expect(row.align):eq("center")
  -- spans are { NW, gap, N, gap, NE }; index 3 is the N badge.
  expect(row.spans[3].text):eq("N")
  expect(row.spans[3].fg):eq("brightgreen")    -- north is open -> lit
  expect(row.spans[3].bold):truthy()
  expect(row.spans[1].fg):eq("brightblack")    -- NW closed -> dim
  state = saved
end)

test("group_member_row lays out a 26-wide name cell plus three vital bars, decoding the flags", function()
  local saved = state
  state = {}
  -- Leader + player: a ★ badge, bright-white name, four columns (name + HP/MP/MV bars).
  local you = group_member_row({ flags = "XL", name = "You",
    hp = 50, maxhp = 50, mana = 30, maxmana = 30, stam = 40, maxstam = 40 })
  expect(#you.cols):eq(4)
  expect(you.cols[1].width):eq(26)
  expect(you.cols[1].spans[1].text):eq("★")               -- leader badge first
  local name_span = you.cols[1].spans[#you.cols[1].spans]
  expect(name_span.text):eq("You")
  expect(name_span.fg):eq("brightwhite")

  -- Your minion, currently absent (flag '-'): cyan name, dimmed, with a " ·away" suffix.
  local pet = group_member_row({ flags = "M-", name = "a wolf",
    hp = 10, maxhp = 20, mana = 0, maxmana = 0, stam = 5, maxstam = 5 })
  local pet_name = pet.cols[1].spans[1]
  expect(pet_name.text):eq("a wolf")
  expect(pet_name.fg):eq("cyan")
  expect(pet_name.dim):truthy()
  local last = pet.cols[1].spans[#pet.cols[1].spans]
  expect(last.text):eq(" ·away")
  state = saved
end)

test("append_col wraps a plain row into columns, or extends an existing column row", function()
  local cell = { text = "X", width = 4 }
  local wrapped = append_col({ text = "hello" }, cell)
  expect(#wrapped.cols):eq(2)
  expect(wrapped.cols[2]):eq(cell)                         -- appended as the last column

  local extended = append_col({ cols = { { text = "a" }, { text = "b" } } }, cell)
  expect(#extended.cols):eq(3)
  expect(extended.cols[3]):eq(cell)
end)

-- ---- whole-panel layout, driven through the live on_update (capture_update nils the minimap) --------

local function paint(st)
  local saved = state
  state = st
  local top, bottom = capture_update()
  state = saved
  return top, bottom
end

local BASE = { hp = 60, maxhp = 100, mana = 40, maxmana = 100, stam = 90, maxstam = 100,
               spells = {}, exits = { north = true, east = true }, room_name = "a field" }

test("out-of-combat bottom panel: 3 rows, vitals+rose on line 1, rose stacked down the right", function()
  local st = {}
  for k, v in pairs(BASE) do st[k] = v end
  st.fighting = false
  local _, bottom = paint(st)
  expect(#bottom):eq(3)
  expect(#bottom[1].cols):eq(4)      -- 3 vitals + compass row 1 in the 4th slot
  expect(#bottom[2].cols):eq(2)      -- spells | compass row 2
  expect(#bottom[3].cols):eq(2)      -- room name | compass row 3
end)

test("in-combat bottom panel: target rides the stats line; spells + room name go full-width", function()
  local st = {}
  for k, v in pairs(BASE) do st[k] = v end
  st.fighting = true; st.fight_name = "a goblin"; st.fight_pct = 50
  local top, bottom = paint(st)
  expect(#bottom):eq(3)
  expect(#bottom[1].cols):eq(4)      -- 3 vitals + the target cell
  expect(bottom[2].cols):eq(nil)     -- spells row is now a full-width spans row...
  expect(bottom[2].spans):truthy()
  expect(bottom[3].cols):eq(nil)     -- ...and so is the room-name row
  expect(bottom[3].spans):truthy()
  -- The exits rose relocates to the TOP panel while fighting (3 compass rows, each a 2-col row).
  local compass_rows = 0
  for _, r in ipairs(top) do if r.cols and #r.cols == 2 then compass_rows = compass_rows + 1 end end
  expect(compass_rows >= 3):truthy()
end)

-- Collect every text fragment painted into a panel spec (rows -> cols/spans -> text).
local function all_text(rows)
  local out = {}
  local function walk(node)
    if type(node) ~= "table" then return end
    if node.text then out[#out + 1] = node.text end
    for _, key in ipairs({ "cols", "spans" }) do
      if node[key] then for _, c in ipairs(node[key]) do walk(c) end end
    end
    if node[1] then for _, c in ipairs(node) do walk(c) end end
  end
  for _, r in ipairs(rows) do walk(r) end
  return table.concat(out, "\1")
end

test("buffs are shown by exactly ONE widget: the bottom 'spells' row, never a separate 'effects' one", function()
  local st = {}
  for k, v in pairs(BASE) do st[k] = v end
  st.fighting = false
  st.spells = { ["mana shield"] = true }        -- live buff (kxwt_spellup)
  st.effects = { blur = "one hour" }            -- stale kxwt_spst data must NOT surface anywhere
  local top, bottom = paint(st)
  -- Present: the single spells widget on the bottom panel.
  expect(all_text(bottom)):contains("spells:")
  expect(all_text(bottom)):contains("mana shield")
  -- Absent: no "effects:" widget on either panel (state.effects is not rendered at all now).
  expect(all_text(bottom):find("effects:", 1, true)):eq(nil)
  expect(all_text(top):find("effects:", 1, true)):eq(nil)
  expect(all_text(top):find("blur", 1, true)):eq(nil)
end)

test("on_connect wipes session-scoped buff state so a reconnect never shows stale spells/effects", function()
  local saved = state
  state = { spells = { fly = true, haste = true }, effects = { blur = "one hour" } }
  on_connect()
  expect(next(state.spells)):eq(nil)            -- spells cleared for the fresh connection
  expect(next(state.effects)):eq(nil)           -- timed effects cleared too
  state = saved
end)

test("in-combat bottom panel grows an inferred bar row per OTHER opponent, between target and spells", function()
  local st = {}
  for k, v in pairs(BASE) do st[k] = v end
  st.fighting = true; st.fight_name = "a goblin"; st.fight_pct = 50
  -- Two OTHER engaged mobs, seen just now (fresh timestamps so they survive the 30s prune).
  local now = os.time()
  st.opponents = {
    ["a goblin"] = { pct = 50, exact = true,  t = now },   -- current target: excluded (own exact bar)
    ["a rat"]    = { pct = 3,  exact = false, t = now },
    ["an orc"]   = { pct = 55, exact = false, t = now },
  }
  local _, bottom = paint(st)
  -- Baseline in-combat block is 3 rows (stats+target, spells, room); +2 inferred opponent rows here.
  expect(#bottom):eq(5)
  expect(all_text(bottom)):contains("a rat")
  expect(all_text(bottom)):contains("an orc")
  expect(all_text(bottom):find("a goblin", 1, true)):ne(nil)   -- target still shown (on the stats line)
end)

test("nomelee fight (NO kxwt_fighting): combat layout renders with the best estimate PROMOTED to the target slot", function()
  -- Raw-capture-proven state: with nocombat on the server never sends kxwt_fighting, so
  -- state.fighting is false for the whole fight; only the text-inferred engaged window is open.
  local now = os.time()
  local st = {}
  for k, v in pairs(BASE) do st[k] = v end
  st.fighting = false
  st.engaged_until = now + 10
  st.opponents = { ["an orc bachelor"] = { display = "An orc bachelor", pct = 3, exact = false, t = now } }
  local top, bottom = paint(st)
  -- Combat layout: 3 rows (stats+promoted target, spells, room) — the single opponent is promoted, so
  -- no extra bar rows; spells/room are full-width spans rows just like a kxwt fight.
  expect(#bottom):eq(3)
  expect(#bottom[1].cols):eq(4)
  expect(bottom[2].cols):eq(nil); expect(bottom[2].spans):truthy()
  expect(all_text(bottom)):contains("An orc bachelor")
  expect(all_text(bottom)):contains("near death")             -- pct 3 -> the estimate's condition word
  expect(all_text(bottom)):contains("~")                      -- flagged as an estimate, not exact
  -- The exits rose relocates to the top panel, exactly as in a kxwt-confirmed fight.
  local compass_rows = 0
  for _, r in ipairs(top) do if r.cols and #r.cols == 2 then compass_rows = compass_rows + 1 end end
  expect(compass_rows >= 3):truthy()
end)

test("nomelee fight with no opponent named yet still shows an 'engaged' target flag", function()
  local st = {}
  for k, v in pairs(BASE) do st[k] = v end
  st.fighting = false
  st.engaged_until = os.time() + 10
  st.opponents = {}
  local _, bottom = paint(st)
  expect(#bottom):eq(3)                                       -- combat layout even without a name
  expect(all_text(bottom)):contains("engaged")
end)

test("engaged window expired: the HUD is back to the out-of-combat layout (block clears)", function()
  local now = os.time()
  local st = {}
  for k, v in pairs(BASE) do st[k] = v end
  st.fighting = false
  st.engaged_until = now - 1                                  -- window closed (fight over)
  st.opponents = { ["an orc bachelor"] = { display = "An orc bachelor", pct = 3, exact = false, t = now - 60 } }
  local _, bottom = paint(st)
  expect(#bottom):eq(3)
  expect(#bottom[2].cols):eq(2)                               -- spells | compass -> out-of-combat shape
  expect(all_text(bottom):find("An orc bachelor", 1, true)):eq(nil)
end)

test("top panel shows the group roster header only once you have 2+ members", function()
  local st = {}
  for k, v in pairs(BASE) do st[k] = v end
  st.fighting = false
  st.group = {
    { flags = "XL", name = "You",   hp = 50, maxhp = 50, mana = 30, maxmana = 30, stam = 40, maxstam = 40 },
    { flags = "M",  name = "a wolf", hp = 20, maxhp = 20, mana = 0,  maxmana = 0,  stam = 5,  maxstam = 5 },
  }
  local top = paint(st)
  expect(top[1].text):contains("group (2)")   -- roster header for the 2-member party
end)
