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

-- ---- learned per-kind harvest memory (skip barren teeth/spellcomps) ------------------------------

-- Reset the learned tables + kill tally so each case is hermetic (module-load may have read a real file).
local function reset_harvest_mem()
  local hm = _AA_TEST.corpse_harvest()
  for k in pairs(hm.no_teeth) do hm.no_teeth[k] = nil end
  for k in pairs(hm.no_spellcomps) do hm.no_spellcomps[k] = nil end
  for k in pairs(corpse.kills) do corpse.kills[k] = nil end
end

test("batch_kind: one killed kind is trusted; a mixed pack (or an ally) yields nil", function()
  reset_harvest_mem()
  _AA_TEST.note_kill("a jaguar")
  expect(_AA_TEST.batch_kind()):eq("jaguar")            -- normalized (article dropped), unambiguous
  _AA_TEST.note_kill("A jaguar")                        -- same kind, different casing/article → still one kind
  expect(_AA_TEST.batch_kind()):eq("jaguar")
  _AA_TEST.note_kill("a kobold")                        -- second distinct kind → ambiguous
  expect(_AA_TEST.batch_kind()):eq(nil)
  reset_harvest_mem()
  local saved = state; state = { name = "Me", group = { { name = "A skeletal spider" } } }
  _AA_TEST.note_kill("A skeletal spider")               -- our minion (is_ally) → not a kill kind
  expect(_AA_TEST.batch_kind()):eq(nil)
  state = saved
end)

test("a known no-teeth kind SKIPS the teeth harvest (jumps to spellcomps), leaving the corpse un-named", function()
  reset_harvest_mem()
  _AA_TEST.corpse_harvest().no_teeth["jaguar"] = true
  with_corpse({ on = true, active = true, idx = 1, kills = { jaguar = true } }, function(sent)
    corpse_process()
    expect(sent[1]):eq("harvest spellcomps 1.corpse")   -- teeth skipped
    for _, c in ipairs(sent) do expect(c:find("harvest teeth") == nil):eq(true) end
    expect(corpse.step):eq("spellcomps")
    expect(corpse.cur_name):eq(nil)                      -- still un-named → sac decision unchanged (left intact)
  end)
end)

test("a both-barren kind still sends ONE harvest (the existence probe) — teeth skipped, spellcomps stands in", function()
  -- We can skip AT MOST one command: the harvest doubles as the "does this corpse index exist?" probe that
  -- terminates the walk, so a both-barren kind skips teeth but must still send spellcomps.
  reset_harvest_mem()
  local hm = _AA_TEST.corpse_harvest(); hm.no_teeth["rat"] = true; hm.no_spellcomps["rat"] = true
  with_corpse({ on = true, active = true, idx = 1, with_items = {}, kills = { rat = true } }, function(sent)
    corpse_process()
    expect(sent[1]):eq("harvest spellcomps 1.corpse")    -- teeth skipped; spellcomps is the probe
    for _, c in ipairs(sent) do expect(c:find("harvest teeth") == nil):eq(true) end
    expect(corpse.idx):eq(1)                             -- still on this index, awaiting the probe reply
  end)
end)

test("a known no-spellcomps kind harvests teeth but SKIPS spellcomps (name known → sac still works)", function()
  reset_harvest_mem()
  _AA_TEST.corpse_harvest().no_spellcomps["jaguar cub"] = true   -- stored under the NORMALIZED key
  with_corpse({ on = true, active = true, idx = 1, step = "teeth", cur_name = "a jaguar cub",
                with_items = {} }, function(sent)
    corpse_harvest_done()                                -- teeth finished → normally sends harvest spellcomps
    for _, c in ipairs(sent) do expect(c:find("harvest spellcomps") == nil):eq(true) end  -- skipped
    expect(sent[1]):eq("bsac 1.corpse")                  -- straight to the empty-corpse sacrifice (name was known)
  end)
end)

test("an ambiguous (mixed) kill batch never skips — teeth is harvested normally", function()
  reset_harvest_mem()
  _AA_TEST.corpse_harvest().no_teeth["jaguar"] = true
  with_corpse({ on = true, active = true, idx = 1, kills = { jaguar = true, kobold = true } }, function(sent)
    corpse_process()
    expect(sent[1]):eq("harvest teeth 1.corpse")         -- batch_kind nil → no skip
  end)
end)

test("learn_no_teeth / learn_no_spellcomps record the kind (deduped)", function()
  reset_harvest_mem()
  _AA_TEST.learn_no_teeth("jaguar")
  _AA_TEST.learn_no_teeth("jaguar")                      -- dedupe (no error / no double)
  _AA_TEST.learn_no_spellcomps("kobold")
  expect(_AA_TEST.corpse_harvest().no_teeth["jaguar"]):eq(true)
  expect(_AA_TEST.corpse_harvest().no_spellcomps["kobold"]):eq(true)
  reset_harvest_mem()
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

test("corpse OFF mid-pass CANCELS the promise (not resolve) and sends `stop` when busy", function()
  _PROMISE_TEST.cancel_all()
  local saved_state, saved_send, sent = state, send, {}
  state = { opponents = {}, engaged_until = nil, action = 60 }   -- in_combat() false; action>=50 = busy
  send = function(c) sent[#sent + 1] = c end
  local snap = {}; for k, v in pairs(corpse) do snap[k] = v end
  corpse.on, corpse.active, corpse.settle, corpse.killed = true, false, nil, true
  corpse_start()                                     -- begins the pass + its tracked promise
  expect(widget_has("harvesting corpses")):eq(true)
  corpse_command("corpse", "off")                    -- kxwt.corpse("off") while a harvest is running
  local stopped = false; for _, c in ipairs(sent) do if c == "stop" then stopped = true end end
  expect(stopped):eq(true)                           -- busy → interrupt the MUD action
  expect(widget_has("harvesting corpses")):eq(false) -- promise cancelled → row gone
  expect(corpse.active):eq(false)
  for k in pairs(corpse) do corpse[k] = nil end
  for k, v in pairs(snap) do corpse[k] = v end
  state, send = saved_state, saved_send
end)

test("corpse OFF when NOT busy still cancels the pass but sends no `stop`", function()
  _PROMISE_TEST.cancel_all()
  local saved_state, saved_send, sent = state, send, {}
  state = { opponents = {}, engaged_until = nil, action = 0 }     -- not busy
  send = function(c) sent[#sent + 1] = c end
  local snap = {}; for k, v in pairs(corpse) do snap[k] = v end
  corpse.on, corpse.active, corpse.settle, corpse.killed = true, false, nil, true
  corpse_start()
  corpse_command("corpse", "off")
  local stopped = false; for _, c in ipairs(sent) do if c == "stop" then stopped = true end end
  expect(stopped):eq(false)
  expect(widget_has("harvesting corpses")):eq(false)
  for k in pairs(corpse) do corpse[k] = nil end
  for k, v in pairs(snap) do corpse[k] = v end
  state, send = saved_state, saved_send
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
