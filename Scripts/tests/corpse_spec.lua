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

test("a corpse holding loot is BSAC'd (blood only) but never SAC'd (removed)", function()
  with_corpse({ on = true, active = true, idx = 1, cur_name = "a jaguar",
                with_items = { ["a jaguar"] = true } }, function(sent)
    corpse_finish()
    expect(sent[1]):eq("bsac 1.corpse")           -- bsac only drains blood → safe on a loot corpse
    expect(corpse.cur_empty):eq(false)            -- but flagged not-empty, so NOT sac-safe
    corpse_sac()                                  -- bsac reply → decide
    expect(corpse.idx):eq(2)                      -- stepped PAST it, items intact
    for _, c in ipairs(sent) do expect(c:find("^sac ") == nil):eq(true) end   -- never REMOVED
  end)
end)

test("an EMPTY corpse (no auto-printed contents) is blood-sacrificed", function()
  with_corpse({ on = true, active = true, idx = 1, cur_name = "a jaguar cub", with_items = {} }, function(sent)
    corpse_finish()
    expect(sent[1]):eq("bsac 1.corpse")
  end)
end)

test("a fully barren corpse (no name learned) IS sacrificed when the batch printed no loot", function()
  -- The reported case: "a wall of sludge" with no teeth and no spellcomps never names itself, but nothing
  -- in the room printed "…contains:", so it's safe (and correct) to bsac it rather than leave it forever.
  with_corpse({ on = true, active = true, idx = 1, cur_name = nil, with_items = {} }, function(sent)
    corpse_finish()
    expect(sent[1]):eq("bsac 1.corpse")
  end)
end)

test("an un-named corpse (batch held loot somewhere) is bsac'd but left intact — never removed", function()
  with_corpse({ on = true, active = true, idx = 1, cur_name = nil,
                with_items = { ["a jaguar"] = true } }, function(sent)
    corpse_finish()
    expect(sent[1]):eq("bsac 1.corpse")             -- blood is always safe
    expect(corpse.cur_empty):eq(false)              -- but can't prove it's empty → not sac-safe
    corpse_sac()
    expect(corpse.idx):eq(2)                        -- stepped past, not removed
    for _, c in ipairs(sent) do expect(c:find("^sac ") == nil):eq(true) end
  end)
end)

test("sac is STREAM-driven: for an EMPTY corpse, corpse_sac sends `sac` and WAITS for the god's reply", function()
  with_corpse({ on = true, active = true, idx = 1, step = "bsac", remaining = 2, cur_name = nil,
                cur_empty = true, with_items = {} }, function(sent)
    corpse_sac()
    expect(sent[1]):eq("sac 1.corpse")
    expect(#sent):eq(1)                              -- nothing else until the sac is confirmed
  end)
end)

test("a CONFIRMED sac drops `remaining` and re-processes the SAME index (the next corpse shifted in)", function()
  with_corpse({ on = true, active = true, idx = 1, step = "sac", remaining = 2, cur_name = "old",
                with_items = {} }, function(sent)
    corpse_sac_done("ok")                            -- "Draak appreciates your sacrifice of the corpse of X."
    expect(corpse.remaining):eq(1)                   -- one fewer corpse in the room
    expect(sent[1]):eq("harvest teeth 1.corpse")     -- re-harvest the index the next corpse shifted into
    expect(corpse.cur_name):eq(nil)                  -- name re-learned per corpse
  end)
end)

test("a sac that FAILS (corpse too big) leaves it intact and steps PAST it — no decrement", function()
  with_corpse({ on = true, active = true, idx = 1, step = "sac", remaining = 3, with_items = {} }, function(sent)
    corpse_sac_done("fail")                          -- "…is too big for you to sacrifice."
    expect(corpse.remaining):eq(3)                   -- still there → not removed
    expect(corpse.idx):eq(2)                         -- stepped past it, next corpse
    expect(sent[1]):eq("harvest teeth 2.corpse")
  end)
end)

test("a duplicate sac reply (god line + gold line) is ignored — step already advanced", function()
  with_corpse({ on = true, active = true, idx = 1, step = "sac", remaining = 2, with_items = {} }, function(sent)
    corpse_sac_done("ok")                            -- first reply advances (step -> teeth)
    local n = #sent
    corpse_sac_done("ok")                            -- second reply for the same sac: gated out (step ~= "sac")
    expect(#sent):eq(n)
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

-- ---- the walk is bounded by how many we actually killed (no phantom 2.corpse probe) --------------

test("note_kill counts every corpse we made (not just distinct kinds)", function()
  local snap = corpse.kills; corpse.kills = {}; corpse.kill_count = 0
  _AA_TEST.note_kill("a jaguar")
  _AA_TEST.note_kill("a jaguar")     -- same KIND, but a second corpse
  _AA_TEST.note_kill("a kobold")
  expect(corpse.kill_count):eq(3)
  corpse.kills = snap; corpse.kill_count = 0
end)

test("the walk STOPS once idx passes the corpses that REMAIN — no probe of a corpse we never made", function()
  -- One corpse remains but it was left intact (loot/unknown name) so idx advanced to 2. There is no
  -- 2.corpse, so the pass must end WITHOUT sending `harvest ... 2.corpse`.
  with_corpse({ on = true, active = true, idx = 2, remaining = 1, killed = true, settle = nil }, function(sent)
    corpse_process()
    for _, c in ipairs(sent) do expect(c:find("harvest") == nil):eq(true) end   -- nothing probed
    expect(corpse.active):eq(false)                                             -- pass wrapped up
  end)
end)

test("the walk still harvests every index UP TO the remaining count", function()
  with_corpse({ on = true, active = true, idx = 2, remaining = 2, killed = true, with_items = {} }, function(sent)
    corpse_process()
    expect(sent[1]):eq("harvest teeth 2.corpse")   -- idx 2 <= 2 remaining → still processed
    expect(corpse.active):eq(true)
  end)
end)

test("an unknown remaining count (nil) falls back to walking until the game says no such corpse", function()
  with_corpse({ on = true, active = true, idx = 2, remaining = nil, killed = true, with_items = {} }, function(sent)
    corpse_process()
    expect(sent[1]):eq("harvest teeth 2.corpse")   -- no cap → old behaviour (miss line terminates)
    expect(corpse.active):eq(true)
  end)
end)

test("after sacrificing corpse 1, a leftover LOOT corpse doesn't cause a phantom 2.corpse probe", function()
  -- The reported bug: two kills, corpse 1 empty (sac'd → remaining 2->1, and corpse 2 shifted into idx 1),
  -- corpse 2 holds loot so it's left intact and idx advances to 2. Only one corpse remains (now at idx 1),
  -- so there is NO 2.corpse — the walk must end instead of probing it.
  with_corpse({ on = true, active = true, idx = 1, step = "spellcomps", remaining = 1,
                cur_name = "a jaguar", with_items = { ["a jaguar"] = true } }, function(sent)
    corpse_finish()                                  -- loot corpse → bsac (blood), then decide
    expect(sent[1]):eq("bsac 1.corpse")
    corpse_sac()                                     -- not empty → leave intact, idx->2 > remaining 1 → done
    expect(corpse.active):eq(false)                  -- walk ended (corpse_done also resets idx)
    for _, c in ipairs(sent) do expect(c:find("2%.corpse") == nil):eq(true) end   -- never probed 2.corpse
  end)
end)

test("end-to-end: a barren empty corpse harvests ONCE each and never re-harvests after the sac", function()
  -- The reported bug (old synchronous sac): teeth barren → learn no-teeth, spellcomps barren → bsac →
  -- bsac fails ("only blood sacrifice corpses with blood in them") → sac. The old code re-processed the
  -- index right after sending `sac`, and since no-teeth was just learned it fired a SECOND
  -- `harvest spellcomps 1.corpse` at the corpse the sac had already removed. Stream-driven sac waits for
  -- the god's reply, drops `remaining` to 0, and ends — no phantom re-harvest.
  local hm = _AA_TEST.corpse_harvest()
  for k in pairs(hm.no_teeth) do hm.no_teeth[k] = nil end
  for k in pairs(hm.no_spellcomps) do hm.no_spellcomps[k] = nil end
  local saved_send, sent = send, {}
  send = function(c) sent[#sent + 1] = c end
  local snap = {}; for k, v in pairs(corpse) do snap[k] = v end
  corpse.on, corpse.active, corpse.idx, corpse.remaining = true, true, 1, 1
  corpse.kills = { ["wall of slime"] = true }; corpse.with_items = {}; corpse.cur_name = nil; corpse.step = nil

  corpse_process()                                                     -- harvest teeth 1.corpse
  _AA_TEST.learn_no_teeth(_AA_TEST.batch_kind()); corpse_harvest_done() -- barren teeth → harvest spellcomps 1.corpse
  _AA_TEST.learn_no_spellcomps(_AA_TEST.batch_kind()); corpse_harvest_done() -- barren spellcomps → corpse_finish → bsac
  corpse_sac()                                                          -- bsac-fail path → sac 1.corpse, then WAIT
  corpse_sac_done("ok")                                                -- "Draak appreciates…" → remaining 0 → done

  local active = corpse.active
  send = saved_send
  for k in pairs(corpse) do corpse[k] = nil end
  for k, v in pairs(snap) do corpse[k] = v end
  for k in pairs(hm.no_teeth) do hm.no_teeth[k] = nil end
  for k in pairs(hm.no_spellcomps) do hm.no_spellcomps[k] = nil end

  expect(table.concat(sent, " | ")):eq(
    "harvest teeth 1.corpse | harvest spellcomps 1.corpse | bsac 1.corpse | sac 1.corpse")
  expect(active):eq(false)
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
