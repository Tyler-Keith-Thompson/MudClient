-- Archery.tl — pure seams (equipment parse, target parsing/priority) and the command sequences the state
-- machine emits. `send` is stubbed by the harness; we capture it to assert the exact commands.
local T = _ARCHERY_TEST

local orig_send = send
local function capture()
  local sent = {}
  send = function(c) sent[#sent + 1] = c end
  return sent
end
-- reset the module state into a clean `firing` setup (mutating the live S the functions close over)
local function firing(fields)
  local S = T.state()
  for k in pairs(S) do S[k] = nil end
  S.phase = "firing"; S.capturing = false; S.started = true; S.snapshot = {}; S.removed = 0
  S.up = {}; S.ammo = 100; S.in_flight = false; S.last_fired = ""; S.recollecting = false
  for k, v in pairs(fields or {}) do S[k] = v end
  return S
end

test("parse_hand_slots pulls only hand-occupying slots, keyed by the item's last word", function()
  local block = [[
You are using:
head        - (rare)       a silvery headband (glow)
on body     -              a robe of black satin
weapon      - (crafted)    a quartz-tipped wooden cane (light)
shield      -              a battered oak shield
held        -              a bone walking cane
finger      - (crafted)    a bone band ring
]]
  local by = {}
  for _, h in ipairs(T.parse_hand_slots(block)) do by[h.slot] = h.kw end
  expect(by.weapon):eq("cane")
  expect(by.shield):eq("shield")
  expect(by.held):eq("cane")
  expect(by.head):eq(nil)
end)

test("restore_verb maps a slot to its re-equip command", function()
  expect(T.restore_verb("weapon")):eq("wield")
  expect(T.restore_verb("shield")):eq("wear")
  expect(T.restore_verb("held")):eq("hold")
end)

test("target_of reads the target type from a result line", function()
  expect(T.target_of("Your dart sticks in a practice dummy's head, 20 points awarded!")):eq("dummy")
  expect(T.target_of("Your dart solidly strikes a clay pigeon, 50 points awarded!")):eq("pigeon")
  expect(T.target_of("Your dart goes through the bull's eye of an archery target, 50 points awarded!")):eq("target")
  expect(T.target_of("nothing relevant")):eq(nil)
end)

test("pick_target honours priority (pigeon > target > dummy) and is nil on an empty range", function()
  local S = firing()
  S.up = { dummy = 1, target = 1 };            expect(T.pick_target()):eq("target")
  S.up = { pigeon = 1, target = 1, dummy = 1 }; expect(T.pick_target()):eq("pigeon")
  S.up = {};                                    expect(T.pick_target()):eq(nil)
end)

test("fire_step fires the priority target and holds to one shot in flight", function()
  local sent = capture()
  firing({ up = { pigeon = 1, dummy = 1 } })
  T.fire_step()
  expect(sent[#sent]):eq("fire pigeon")        -- pigeon beats dummy
  expect(T.state().in_flight):truthy()
  local n = #sent
  T.fire_step()                                 -- a shot is already out → no second fire
  expect(#sent):eq(n)
  send = orig_send
end)

test("fire_step does nothing when the range is empty (waits for an appearance)", function()
  local sent = capture()
  firing({ up = {} })
  T.fire_step()
  expect(#sent):eq(0)
  expect(T.state().in_flight):falsy()
  send = orig_send
end)

test("fire_step recollects (get all) BEFORE firing when ammo is low, without stacking", function()
  local sent = capture()
  firing({ up = { dummy = 1 }, ammo = 5 })
  T.fire_step()
  local gi, fi
  for i, c in ipairs(sent) do if c == "get all" then gi = i elseif c == "fire dummy" then fi = i end end
  expect(gi):truthy(); expect(fi):truthy()
  expect(gi < fi):truthy()                      -- recollect first, then fire
  expect(T.state().recollecting):truthy()       -- flag set so we don't stack another `get all`
  send = orig_send
end)

test("join waits for the contest-start line — never spams `event start contest`", function()
  local sent = capture()
  local S = firing({ phase = "ready", started = false })
  T.try_join()
  local joins = 0; for _, c in ipairs(sent) do if c == "event start contest" then joins = joins + 1 end end
  expect(joins):eq(0)
  S.started = true
  T.try_join(); T.try_join()                    -- once started: join exactly once
  joins = 0; for _, c in ipairs(sent) do if c == "event start contest" then joins = joins + 1 end end
  expect(joins):eq(1)
  expect(T.state().phase):eq("joining")
  send = orig_send
end)

test("finish stows ammo, then re-equips the snapshot in reverse (original) order", function()
  local sent = capture()
  local S = firing()
  S.snapshot = { { slot = "held", kw = "cane" }, { slot = "shield", kw = "buckler" } }
  T.finish()
  expect(sent[1]):eq("put all.dart vortex")
  expect(sent[2]):eq("wear buckler")
  expect(sent[3]):eq("hold cane")
  expect(T.state().phase):eq("done")
  send = orig_send
end)
