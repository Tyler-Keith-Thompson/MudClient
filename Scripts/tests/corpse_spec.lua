-- Specs for the after-kill corpse automation (AlterAeon.lua): the invariant that a corpse still holding
-- loot we couldn't auto-take is NEVER sacrificed. The trigger REGEXES that set `dirty` (binding object /
-- can't-carry / must-get-by-name) run in Swift; here we test the pure decision in corpse_finish given
-- the flag. (This is the "sacrificed a corpse with a binding medallion in it" bug.)

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

test("a DIRTY corpse (loot left behind, e.g. a binding object) is NOT sacrificed", function()
  with_corpse({ on = true, active = true, idx = 1, dirty = true }, function(sent)
    corpse_finish()
    for _, c in ipairs(sent) do
      expect(c:find("^bsac") == nil):eq(true)    -- never blood-sacrificed
      expect(c:find("^sac ") == nil):eq(true)    -- never sacrificed
    end
    expect(corpse.idx):eq(2)                      -- stepped PAST the dirty corpse, leaving it intact
  end)
end)

test("a CLEAN corpse is blood-sacrificed", function()
  with_corpse({ on = true, active = true, idx = 1, dirty = false }, function(sent)
    corpse_finish()
    expect(sent[1]):eq("bsac 1.corpse")
  end)
end)

test("a SUCCESSFUL spellcomps harvest (a yield line, no 'done' line) advances to bsac — no stall", function()
  -- This is the bug: `harvest spellcomps` that SUCCEEDS just prints its yield ("...drain...into a vial
  -- of bile." / "...tie off the ends...") with no terminal, so the machine used to hang at the spellcomps
  -- step forever. The yield triggers call corpse_harvest_done; from the spellcomps step that must bsac.
  with_corpse({ on = true, active = true, idx = 1, step = "spellcomps", dirty = false }, function(sent)
    corpse_harvest_done()
    expect(sent[1]):eq("bsac 1.corpse")
    expect(corpse.step):eq("bsac")
  end)
end)

-- ---- the loot pass surfaces as a tracked promise (the HUD promise widget) -----------------------

local function widget_has(desc)
  for _, e in ipairs(active_promises()) do if e.desc == desc then return true end end
  return false
end

test("a stall watchdog is armed while looting and cleared when the pass ends", function()
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

test("corpse_start surfaces a 'looting corpses' promise; corpse_done settles it off the widget", function()
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
  local during = widget_has("looting corpses")     -- shows while looting
  corpse_done()
  local after = widget_has("looting corpses")       -- gone once the pass ends
  corpse_done()                                     -- second settle is a no-op (no double-resolve error)
  for k in pairs(corpse) do corpse[k] = nil end
  for k, v in pairs(snap) do corpse[k] = v end
  state, send = saved_state, saved_send
  expect(during):eq(true)
  expect(after):eq(false)
end)
