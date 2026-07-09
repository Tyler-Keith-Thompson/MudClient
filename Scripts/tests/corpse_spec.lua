-- Specs for the after-kill corpse automation (AlterAeon.lua). We HARVEST corpses (teeth + spellcomps),
-- never `get all`, and bsac/sac ONLY the corpses we're sure are empty — a corpse still holding loot is
-- left intact (sacrificing it would destroy the items, incl. binding/quest gear — the medallion bug).
-- "Has loot" comes from the contents the game auto-prints at the kill ("...the corpse of X contains:"),
-- recorded per NAME; each corpse's name is learned from its own harvest reply. The trigger REGEXES run in
-- Swift; here we test the pure decision (corpse_finish/corpse_sac) given the recorded state.

local corpse = _AA_TEST.corpse

-- Run `fn(sent)` with the corpse table set to `fields` and `send` capturing, then restore both.
local function with_corpse(fields, fn)
  local saved_send, sent = send, {}
  send = function(c) sent[#sent + 1] = c end
  local snap = {}; for k, v in pairs(corpse) do snap[k] = v end
  for k, v in pairs(fields) do corpse[k] = v end
  local ok, err = pcall(function() fn(sent) end)
  send = saved_send
  for k in pairs(corpse) do corpse[k] = nil end
  for k, v in pairs(snap) do corpse[k] = v end
  if not ok then error(err, 2) end
end

test("a corpse still holding loot (its name auto-printed 'contains:') is NEVER sacrificed", function()
  with_corpse({ on = true, active = true, idx = 1, cur_name = "a jaguar",
                with_items = { ["a jaguar"] = true } }, function(sent)
    corpse_finish()
    for _, c in ipairs(sent) do
      expect(c:find("^bsac") == nil):eq(true)    -- never blood-sacrificed
      expect(c:find("^sac ") == nil):eq(true)    -- never sacrificed
    end
    expect(corpse.idx):eq(2)                      -- stepped PAST it, leaving it intact
  end)
end)

test("an EMPTY corpse (no auto-printed contents) is blood-sacrificed", function()
  with_corpse({ on = true, active = true, idx = 1, cur_name = "a jaguar cub", with_items = {} }, function(sent)
    corpse_finish()
    expect(sent[1]):eq("bsac 1.corpse")
  end)
end)

test("a corpse whose name we never learned is left intact (never risk destroying loot)", function()
  with_corpse({ on = true, active = true, idx = 1, cur_name = nil, with_items = {} }, function(sent)
    corpse_finish()
    for _, c in ipairs(sent) do expect(c:find("^bsac") == nil):eq(true) end
    expect(corpse.idx):eq(2)
  end)
end)

test("the bsac result advances to sac (removes the corpse), then re-processes the same index", function()
  with_corpse({ on = true, active = true, idx = 1, step = "bsac", cur_name = nil, with_items = {} }, function(sent)
    corpse_sac()
    expect(sent[1]):eq("sac 1.corpse")
    expect(sent[2]):eq("harvest teeth 1.corpse")   -- corpse_process re-runs at the SAME index (no `get all`)
    expect(corpse.cur_name):eq(nil)                 -- name re-learned per corpse
  end)
end)

test("a SUCCESSFUL spellcomps harvest (a yield line, no 'done' line) advances to the decision — no stall", function()
  -- The bug: `harvest spellcomps` that SUCCEEDS just prints its yield with no terminal, so the machine
  -- used to hang at the spellcomps step forever. The yield triggers call corpse_harvest_done; from the
  -- spellcomps step that must reach corpse_finish (→ bsac for an empty corpse).
  with_corpse({ on = true, active = true, idx = 1, step = "spellcomps", cur_name = "a rat", with_items = {} }, function(sent)
    corpse_harvest_done()
    expect(sent[1]):eq("bsac 1.corpse")
    expect(corpse.step):eq("bsac")
  end)
end)

-- ---- the harvest pass surfaces as a tracked promise (the HUD promise widget) --------------------

local function widget_has(desc)
  for _, e in ipairs(active_promises()) do if e.desc == desc then return true end end
  return false
end

test("a stall watchdog is armed while harvesting and cleared when the pass ends", function()
  local saved_state, saved_send = state, send
  state = { opponents = {}, engaged_until = nil }   -- in_combat() false
  send = function() end
  local snap = {}; for k, v in pairs(corpse) do snap[k] = v end
  corpse.on, corpse.active, corpse.watchdog, corpse.killed, corpse.settle = true, false, nil, true, nil
  corpse_start()
  local armed = corpse.watchdog ~= nil      -- after() stub returned a timer id
  corpse_done()
  local cleared = corpse.watchdog == nil     -- cancel() cleared it
  for k in pairs(corpse) do corpse[k] = nil end
  for k, v in pairs(snap) do corpse[k] = v end
  state, send = saved_state, saved_send
  expect(armed):eq(true)
  expect(cleared):eq(true)
end)

test("corpse_start surfaces a 'harvesting corpses' promise; corpse_done settles it off the widget", function()
  _PROMISE_TEST.cancel_all()                       -- clear any leftovers from other specs
  local saved_state, saved_send = state, send
  state = { opponents = {}, engaged_until = nil }  -- in_combat() → false so the pass may start
  send = function() end
  local snap = {}; for k, v in pairs(corpse) do snap[k] = v end
  corpse.on, corpse.active, corpse.settle, corpse.killed = true, false, nil, true
  corpse_start()
  -- corpse_start starts the promise SYNCHRONOUSLY (it must, or corpse_done can fire before the executor
  -- wires corpse.settle and the row leaks). No manual __start here — if the sync-start regressed, `after`
  -- below would be true (the row never resolves) and this test fails.
  local during = widget_has("harvesting corpses")   -- shows while harvesting
  corpse_done()
  local after = widget_has("harvesting corpses")     -- gone once the pass ends
  corpse_done()                                      -- second settle is a no-op (no double-resolve error)
  for k in pairs(corpse) do corpse[k] = nil end
  for k, v in pairs(snap) do corpse[k] = v end
  state, send = saved_state, saved_send
  expect(during):eq(true)
  expect(after):eq(false)
end)
