-- Specs for the after-kill corpse automation (Corpse.lua).
--
-- CHARACTERIZATION suite. These assert OBSERVABLE BEHAVIOUR — the exact `send` sequence the pass emits
-- (`harvest teeth N.corpse`, `harvest spellcomps N.corpse`, `bsac N.corpse`, `sac N.corpse`), the echo
-- narration, and the OUTCOMES (which corpses get sacrificed vs left intact, whether the pass wraps up) —
-- NOT the internal step-machine fields (corpse.active/step/idx/cur_empty/remaining/watchdog/promise). The
-- point: a reactive reimplementation that stores its progress completely differently (a promise/stream
-- flow instead of a step counter) must still turn these green, because it reproduces the same sends/
-- echoes/outcomes. Any change to the actual command sequence — or to the loot-safety guarantee (never
-- `sac` a corpse that might hold items) — breaks a test.
--
-- We HARVEST corpses (teeth + spellcomps), never `get all`, and bsac/sac ONLY the corpses we're sure are
-- empty — a corpse still holding loot is left intact (sacrificing it would destroy the items, incl.
-- binding/quest gear — the medallion bug). "Has loot" comes from the contents the game auto-prints at the
-- kill ("...the corpse of X contains:"), recorded per NAME; each corpse's name is learned from its own
-- harvest reply.
--
-- The scenario is DRIVEN through the same surface the live Swift triggers drive: corpse_start() kicks the
-- pass off (out of combat), then the reply-line seams advance it — corpse_harvest_done() (a harvest
-- terminal), corpse_sac() (the bsac reply), corpse_sac_done("ok"/"fail") (the sac reply), and setting
-- corpse.cur_name / corpse.with_items (the harvest-name / contents lines). Reading the corpse table is
-- used only to DRIVE; every ASSERTION is on captured send/echo or a pass outcome.

local corpse = _AA_TEST.corpse

-- Clear the learned per-kind harvest memory so each case is hermetic (module load may have read a file).
local function clear_mem()
  local hm = _AA_TEST.corpse_harvest()
  for k in pairs(hm.no_teeth) do hm.no_teeth[k] = nil end
  for k in pairs(hm.no_spellcomps) do hm.no_spellcomps[k] = nil end
end

-- Is a "harvesting corpses" promise row live in the HUD widget?
local function widget_has(desc)
  for _, e in ipairs(active_promises()) do if e.desc == desc then return true end end
  return false
end
local function harvesting() return widget_has("harvesting corpses") end

-- Run a corpse pass. `cfg` seeds the batch inputs (kill count, per-name contents, learned memory has been
-- cleared); we force OUT-of-combat (corpse_start's in_combat gate), start the pass, then hand `drive` a
-- table of reply-line seams + the captured send/echo logs. Everything is restored afterwards and any live
-- promise is cancelled so cases stay hermetic. Returns (sent, echoed).
local function pass(cfg, drive)
  local saved_state, saved_send, saved_echo = state, send, echo
  local sent, echoed = {}, {}
  _PROMISE_TEST.cancel_all()
  clear_mem()
  cfg = cfg or {}
  -- Seed learned per-kind harvest memory AFTER the wipe (arrays of normalized keys).
  local hm = _AA_TEST.corpse_harvest()
  for _, k in ipairs(cfg.no_teeth or {}) do hm.no_teeth[k] = true end
  for _, k in ipairs(cfg.no_spellcomps or {}) do hm.no_spellcomps[k] = true end
  for _, k in ipairs(cfg.no_bsac or {}) do hm.no_bsac[k] = true end
  local snap = {}; for k, v in pairs(corpse) do snap[k] = v end
  for k in pairs(corpse) do corpse[k] = nil end
  corpse.on, corpse.active, corpse.killed = true, false, true
  corpse.kills, corpse.kill_count, corpse.with_items, corpse.room = {}, 0, {}, nil
  corpse.idx = 1
  for k, v in pairs(cfg) do
    if k ~= "no_teeth" and k ~= "no_spellcomps" and k ~= "no_bsac" then corpse[k] = v end
  end
  state = { opponents = {}, engaged_until = nil, fighting = false, action = 0 }
  send = function(c) sent[#sent + 1] = c end
  echo = function(s) echoed[#echoed + 1] = (tostring(s):gsub("\27%[[%d;]*m", "")) end
  local api = {
    sent = sent, echoed = echoed,
    name         = function(n) corpse.cur_name = n end,          -- "You start harvesting teeth from the corpse of X"
    contents     = function(n) corpse.with_items[n] = true end,  -- "(on ground) the corpse of X contains:"
    harvest_done = function() corpse_harvest_done() end,         -- a harvest terminal / spellcomps yield line
    bsac_reply   = function() corpse_sac() end,                  -- "You sacrifice blood from …"
    cant_bsac    = function()  -- "You can only blood sacrifice fresh, intact corpses of known provenance."
      if corpse.active then _AA_TEST.learn_no_bsac(_AA_TEST.corpse_kind_key(corpse.cur_name) or _AA_TEST.batch_kind()) end
      corpse_sac()
    end,
    sac_reply    = function(r) corpse_sac_done(r) end,           -- "… appreciates your sacrifice" / "too big …"
    miss         = function() corpse_done() end,                 -- "You don't see anything named 'N.corpse'"
    harvesting   = harvesting,
  }
  local ok, err = pcall(function()
    corpse_start()
    if drive then drive(api) end
  end)
  _PROMISE_TEST.cancel_all()
  send, echo, state = saved_send, saved_echo, saved_state
  for k in pairs(corpse) do corpse[k] = nil end
  for k, v in pairs(snap) do corpse[k] = v end
  if not ok then error(err, 2) end
  return sent, echoed
end

local function joined(sent) return table.concat(sent, " | ") end
local function has_send(sent, needle)
  for _, c in ipairs(sent) do if c:find(needle, 1, true) then return true end end
  return false
end
-- Count sends whose whole command matches `pat` (anchor with ^ so "sac " doesn't match "bsac …").
local function sends_matching(sent, pat)
  local n = 0
  for _, c in ipairs(sent) do if c:match(pat) then n = n + 1 end end
  return n
end
local function sacs(sent)  return sends_matching(sent, "^sac ") end   -- true corpse REMOVALS
local function bsacs(sent) return sends_matching(sent, "^bsac ") end  -- blood drains (safe on any corpse)

-- ---- loot safety: bsac drains blood from ANY corpse; sac (removal) only on a proven-empty one ---------

test("a corpse holding loot is BSAC'd (blood only) but never SAC'd (removed)", function()
  local sent = pass({ kill_count = 1 }, function(api)
    api.contents("a jaguar")            -- the game auto-printed its contents at the kill → holds loot
    api.name("a jaguar")                -- learned from its own harvest reply
    api.harvest_done()                  -- teeth done → spellcomps
    api.harvest_done()                  -- spellcomps done → decide → bsac
    api.bsac_reply()                    -- blood taken → NOT empty → left intact, step past → pass ends
  end)
  expect(has_send(sent, "bsac 1.corpse")):eq(true)   -- blood is safe to take from a loot corpse
  expect(sacs(sent)):eq(0)                           -- but it is NEVER removed (would destroy the loot)
  expect(harvesting()):eq(false)                     -- one corpse, left intact → pass wrapped up
end)

test("an un-bsac-able corpse ('only blood sacrifice … known provenance') is LEARNED by kind", function()
  local hm = _AA_TEST.corpse_harvest()
  local sent = pass({ kill_count = 1 }, function(api)
    api.name("a raised skeleton")
    api.harvest_done(); api.harvest_done()   -- teeth → spellcomps → decide → bsac
    api.cant_bsac()                          -- rejected: can't bsac this one → resolve + LEARN the kind
  end)
  expect(has_send(sent, "bsac 1.corpse")):eq(true)   -- it still TRIED once (that's how it learned)
  expect(hm.no_bsac["raised skeleton"]):eq(true)     -- ...and remembered the kind
end)

test("a KNOWN un-bsac-able kind SKIPS the wasted bsac and goes straight to the sac decision", function()
  local sent = pass({ kill_count = 1, no_bsac = { "raised skeleton" } }, function(api)
    api.name("a raised skeleton")
    api.harvest_done(); api.harvest_done()   -- teeth → spellcomps → decide
    api.sac_reply("ok")                      -- empty → sac directly (no bsac reply to feed — none was sent)
  end)
  expect(bsacs(sent)):eq(0)                  -- the bsac was skipped entirely
  expect(has_send(sent, "sac 1.corpse")):eq(true)   -- but the empty corpse is still removed
end)

test("an EMPTY corpse (no auto-printed contents) is blood-sacrificed AND removed", function()
  local sent = pass({ kill_count = 1 }, function(api)
    api.name("a jaguar cub")
    api.harvest_done(); api.harvest_done()   -- teeth → spellcomps → decide
    api.bsac_reply()                         -- empty → sac it
    api.sac_reply("ok")                      -- god accepted → gone → pass ends
  end)
  expect(joined(sent)):eq(
    "harvest teeth 1.corpse | harvest spellcomps 1.corpse | bsac 1.corpse | sac 1.corpse")
  expect(harvesting()):eq(false)
end)

test("a fully barren corpse (no name learned) IS sacrificed when the batch printed no loot", function()
  -- "a wall of sludge" with no teeth and no spellcomps never names itself, but nothing in the room
  -- printed "…contains:", so it's safe (and correct) to sac it rather than leave it forever.
  local sent = pass({ kill_count = 1 }, function(api)
    -- never learns a name (barren), never sees contents
    api.harvest_done(); api.harvest_done()
    api.bsac_reply()                         -- unknown name, but batch held no loot anywhere → sac-safe
    api.sac_reply("ok")
  end)
  expect(has_send(sent, "bsac 1.corpse")):eq(true)
  expect(has_send(sent, "sac 1.corpse")):eq(true)
  expect(harvesting()):eq(false)
end)

test("an un-named corpse (batch held loot somewhere) is bsac'd but left intact — never removed", function()
  local sent = pass({ kill_count = 1 }, function(api)
    api.contents("a jaguar")            -- SOME corpse in the batch printed loot…
    -- …and THIS one never names itself, so we can't prove it's empty → mustn't remove it
    api.harvest_done(); api.harvest_done()
    api.bsac_reply()
  end)
  expect(has_send(sent, "bsac 1.corpse")):eq(true)   -- blood is always safe
  expect(sacs(sent)):eq(0)                           -- can't prove empty → never removed
  expect(harvesting()):eq(false)
end)

-- ---- the sac step is STREAM-driven (waits for the god's reply before re-indexing) --------------------

test("sac is STREAM-driven: an EMPTY corpse sends `sac` and then WAITS for the god's reply", function()
  local sent = pass({ kill_count = 2 }, function(api)
    api.name("a rat")
    api.harvest_done(); api.harvest_done()
    api.bsac_reply()                         -- empty → sends `sac 1.corpse`…
    expect(api.sent[#api.sent]):eq("sac 1.corpse")
    local n = #api.sent
    -- …and NOTHING more until the sac is confirmed (no optimistic re-index — sacrificing shifts indices).
    expect(#api.sent):eq(n)
  end)
  expect(sent[#sent]):eq("sac 1.corpse")
end)

test("a CONFIRMED sac re-processes the SAME index (the next corpse shifted into it)", function()
  -- Two empty corpses. Sac'ing #1 removes it and shifts #2 into index 1, so the pass re-harvests index 1.
  local sent = pass({ kill_count = 2 }, function(api)
    api.name("a rat")
    api.harvest_done(); api.harvest_done()
    api.bsac_reply(); api.sac_reply("ok")    -- corpse 1 gone → re-process index 1
    expect(api.sent[#api.sent]):eq("harvest teeth 1.corpse")
  end)
  -- second corpse then processes at index 1 too
  expect(sent[1]):eq("harvest teeth 1.corpse")
end)

test("a sac that FAILS (corpse too big) leaves it intact and steps PAST it to the next index", function()
  local sent = pass({ kill_count = 3 }, function(api)
    api.name("a rat")
    api.harvest_done(); api.harvest_done()
    api.bsac_reply()
    api.sac_reply("fail")                    -- "…is too big for you to sacrifice." → still here → step past
    expect(api.sent[#api.sent]):eq("harvest teeth 2.corpse")   -- next index, not re-index 1
  end)
end)

test("a duplicate sac reply (god line + gold line) is ignored — the step already advanced", function()
  local sent = pass({ kill_count = 2 }, function(api)
    api.name("a rat")
    api.harvest_done(); api.harvest_done()
    api.bsac_reply(); api.sac_reply("ok")    -- first reply advances (re-harvests index 1)
    local n = #api.sent
    api.sac_reply("ok")                      -- second reply for the SAME sac → gated out
    expect(#api.sent):eq(n)
  end)
end)

test("a SUCCESSFUL spellcomps harvest (a yield line, no 'done' line) advances to the decision", function()
  -- The bug: `harvest spellcomps` that SUCCEEDS just prints its yield with no terminal, so the machine
  -- used to hang at the spellcomps step forever. The yield line drives corpse_harvest_done, which from the
  -- spellcomps step must reach the bsac decision (→ bsac for an empty corpse).
  local sent = pass({ kill_count = 1 }, function(api)
    api.name("a rat")
    api.harvest_done()                       -- teeth done → harvest spellcomps
    expect(api.sent[#api.sent]):eq("harvest spellcomps 1.corpse")
    api.harvest_done()                       -- the spellcomps YIELD line → decision → bsac
    expect(api.sent[#api.sent]):eq("bsac 1.corpse")
  end)
end)

-- ---- the walk is bounded by how many we actually killed (no phantom N.corpse probe) ------------------

test("note_kill counts every corpse we made (not just distinct kinds)", function()
  local snap = corpse.kills; corpse.kills = {}; corpse.kill_count = 0
  _AA_TEST.note_kill("a jaguar")
  _AA_TEST.note_kill("a jaguar")     -- same KIND, but a second corpse
  _AA_TEST.note_kill("a kobold")
  expect(corpse.kill_count):eq(3)
  corpse.kills = snap; corpse.kill_count = 0
end)

test("the walk STOPS once it passes the corpses that remain — no probe of one we never made", function()
  -- One kill, but it's left intact (loot). After bsac the pass must END rather than probe a 2.corpse that
  -- was never there.
  local sent = pass({ kill_count = 1 }, function(api)
    api.contents("a jaguar"); api.name("a jaguar")
    api.harvest_done(); api.harvest_done()
    api.bsac_reply()                         -- loot → left intact → idx would advance past remaining → done
  end)
  expect(has_send(sent, "2.corpse")):eq(false)
  expect(harvesting()):eq(false)
end)

test("an unknown remaining count (no kill tally) walks until the game says no such corpse", function()
  -- With no kill count, the pass has no bound and walks index by index until the miss line terminates it.
  local sent = pass({ kill_count = 0 }, function(api)
    api.name("a rat")
    api.harvest_done(); api.harvest_done()
    api.bsac_reply(); api.sac_reply("ok")    -- corpse 1 gone → keeps going (re-harvests index 1)
    expect(api.sent[#api.sent]):eq("harvest teeth 1.corpse")
    api.miss()                               -- "You don't see anything named '1.corpse'" → done
  end)
  expect(harvesting()):eq(false)
end)

test("after sacrificing corpse 1, a leftover LOOT corpse doesn't cause a phantom 2.corpse probe", function()
  -- Two kills: corpse 1 empty (sac'd → the next shifts into index 1), corpse 2 holds loot so it's left
  -- intact. Only one corpse ever remains at a time, so the walk must never probe a 2.corpse.
  local sent = pass({ kill_count = 2 }, function(api)
    api.contents("a jaguar")                 -- corpse 2's loot (a different name than corpse 1)
    api.name("a jaguar cub")                 -- corpse 1: empty
    api.harvest_done(); api.harvest_done()
    api.bsac_reply(); api.sac_reply("ok")     -- corpse 1 removed → re-harvest index 1 (corpse 2 shifted in)
    api.name("a jaguar")                      -- corpse 2: holds loot
    api.harvest_done(); api.harvest_done()
    api.bsac_reply()                          -- loot → left intact → pass ends
  end)
  expect(has_send(sent, "2.corpse")):eq(false)         -- never probed a corpse that isn't there
  expect(sacs(sent)):eq(1)                             -- exactly ONE removal: corpse 1 (empty)…
  expect(bsacs(sent)):eq(2)                            -- …but BOTH got their blood drained
  expect(harvesting()):eq(false)
end)

test("a whole batch of EMPTY corpses is harvested and removed one by one", function()
  -- Two empty kills: each is harvested (teeth + spellcomps) then bsac'd + sac'd. Because a sac removes the
  -- corpse and shifts the next into index 1, every corpse is worked at index 1 — no 2.corpse ever appears —
  -- and the pass ends once the kill count is exhausted.
  local sent = pass({ kill_count = 2 }, function(api)
    api.name("a rat")
    api.harvest_done(); api.harvest_done(); api.bsac_reply(); api.sac_reply("ok")   -- corpse 1
    api.name("a rat")
    api.harvest_done(); api.harvest_done(); api.bsac_reply(); api.sac_reply("ok")   -- corpse 2 (shifted in)
  end)
  expect(sacs(sent)):eq(2)                         -- BOTH removed
  expect(bsacs(sent)):eq(2)
  expect(has_send(sent, "2.corpse")):eq(false)     -- always worked at index 1
  expect(harvesting()):eq(false)                   -- kill count exhausted → pass ended
end)

test("end-to-end: a barren empty corpse harvests ONCE each and never re-harvests after the sac", function()
  -- The reported bug (old synchronous sac): teeth barren → learn no-teeth, spellcomps barren → bsac →
  -- bsac fails → sac. The old code re-processed the index right after sending `sac`, and since no-teeth was
  -- just learned it fired a SECOND `harvest spellcomps` at the corpse the sac had already removed. The
  -- stream-driven sac waits for the god's reply, drops the count to 0, and ends — no phantom re-harvest.
  local sent = pass({ kill_count = 1, kills = { ["wall of slime"] = true } }, function(api)
    -- barren teeth reply learns the kind, then advances:
    _AA_TEST.learn_no_teeth(_AA_TEST.batch_kind()); api.harvest_done()
    -- barren spellcomps reply learns the kind, then advances → bsac:
    _AA_TEST.learn_no_spellcomps(_AA_TEST.batch_kind()); api.harvest_done()
    api.bsac_reply()                          -- bsac-fail path → sac 1.corpse, then WAIT
    api.sac_reply("ok")                       -- confirmed gone → count 0 → done
  end)
  expect(joined(sent)):eq(
    "harvest teeth 1.corpse | harvest spellcomps 1.corpse | bsac 1.corpse | sac 1.corpse")
  expect(harvesting()):eq(false)
end)

-- ---- learned per-kind harvest memory (skip barren teeth/spellcomps) ----------------------------------

-- Reset the learned tables + kill tally so each case is hermetic.
local function reset_harvest_mem()
  clear_mem()
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
  reset_harvest_mem()
end)

test("a known no-teeth kind SKIPS the teeth harvest (jumps straight to spellcomps)", function()
  -- Learned barren-teeth kind: don't waste the teeth command; the spellcomps harvest doubles as the
  -- "does this index exist?" probe, so we still send exactly one harvest. cur_name stays un-learned (as it
  -- would on any teeth failure), so the sacrifice decision is unchanged.
  local sent = pass({ kill_count = 1, kills = { jaguar = true }, no_teeth = { "jaguar" } })
  expect(sent[1]):eq("harvest spellcomps 1.corpse")     -- teeth skipped
  expect(has_send(sent, "harvest teeth")):eq(false)
end)

test("a both-barren kind still sends ONE harvest (the probe) — teeth skipped, spellcomps stands in", function()
  -- We can skip AT MOST one command: the harvest doubles as the existence probe that terminates the walk,
  -- so a both-barren kind skips teeth but must still send spellcomps.
  local sent = pass({ kill_count = 1, kills = { rat = true }, no_teeth = { "rat" }, no_spellcomps = { "rat" } })
  expect(sent[1]):eq("harvest spellcomps 1.corpse")     -- teeth skipped; spellcomps is the probe
  expect(has_send(sent, "harvest teeth")):eq(false)
end)

test("a known no-spellcomps kind harvests teeth but SKIPS spellcomps (name known → sac still works)", function()
  local sent = pass({ kill_count = 1, kills = { ["jaguar cub"] = true }, no_spellcomps = { "jaguar cub" } },
    function(api)
      api.name("a jaguar cub")             -- learned from the teeth harvest reply
      api.harvest_done()                   -- teeth finished → normally sends harvest spellcomps
    end)
  expect(has_send(sent, "harvest teeth 1.corpse")):eq(true)   -- teeth still harvested
  expect(has_send(sent, "harvest spellcomps")):eq(false)      -- spellcomps skipped
  expect(sent[#sent]):eq("bsac 1.corpse")                     -- straight to the empty-corpse sacrifice
end)

test("an ambiguous (mixed) kill batch never skips — teeth is harvested normally", function()
  local sent = pass({ kill_count = 1, kills = { jaguar = true, kobold = true }, no_teeth = { "jaguar" } })
  expect(sent[1]):eq("harvest teeth 1.corpse")   -- batch_kind nil → no skip
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

-- ---- the harvest pass surfaces as a tracked promise (the HUD promise widget) -------------------------

test("corpse_start surfaces a 'harvesting corpses' promise; corpse_done settles it off the widget", function()
  _PROMISE_TEST.cancel_all()
  local saved_state, saved_send = state, send
  state = { opponents = {}, engaged_until = nil }  -- in_combat() → false so the pass may start
  send = function() end
  local snap = {}; for k, v in pairs(corpse) do snap[k] = v end
  corpse.on, corpse.active, corpse.settle, corpse.killed = true, false, nil, true
  corpse_start()
  local during = harvesting()                       -- shows while harvesting
  corpse_done()
  local after_done = harvesting()                    -- gone once the pass ends
  corpse_done()                                      -- second settle is a no-op (no double-resolve error)
  for k in pairs(corpse) do corpse[k] = nil end
  for k, v in pairs(snap) do corpse[k] = v end
  state, send = saved_state, saved_send
  expect(during):eq(true)
  expect(after_done):eq(false)
end)

test("corpse OFF mid-pass CANCELS the promise (not resolve) and sends `stop` when busy", function()
  _PROMISE_TEST.cancel_all()
  local saved_state, saved_send, sent = state, send, {}
  state = { opponents = {}, engaged_until = nil, action = 60 }   -- in_combat() false; action>=50 = busy
  send = function(c) sent[#sent + 1] = c end
  local snap = {}; for k, v in pairs(corpse) do snap[k] = v end
  corpse.on, corpse.active, corpse.settle, corpse.killed = true, false, nil, true
  corpse_start()                                     -- begins the pass + its tracked promise
  expect(harvesting()):eq(true)
  autoHarvest.off()                                  -- autoHarvest.off() while a harvest is running
  local stopped = false; for _, c in ipairs(sent) do if c == "stop" then stopped = true end end
  expect(stopped):eq(true)                           -- busy → interrupt the MUD action
  expect(harvesting()):eq(false)                     -- promise cancelled → row gone
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
  autoHarvest.off()
  local stopped = false; for _, c in ipairs(sent) do if c == "stop" then stopped = true end end
  expect(stopped):eq(false)
  expect(harvesting()):eq(false)
  for k in pairs(corpse) do corpse[k] = nil end
  for k, v in pairs(snap) do corpse[k] = v end
  state, send = saved_state, saved_send
end)

test("a stalled loot pass wraps itself up (the watchdog safety net)", function()
  -- Pacing is stream-driven, but if a terminal line is ever MISSED the pass would hang forever (blocking
  -- every future loot pass and leaking the widget row). The watchdog is the net: after CORPSE_WATCHDOG
  -- seconds with no progress it forces the pass closed with a "loot pass stalled" notice.
  _PROMISE_TEST.cancel_all()
  local saved_state, saved_send, saved_echo, saved_after, saved_cancel = state, send, echo, after, cancel
  local timers, echoed = {}, {}
  state = { opponents = {}, engaged_until = nil, action = 0 }
  send = function() end
  echo = function(s) echoed[#echoed + 1] = (tostring(s):gsub("\27%[[%d;]*m", "")) end
  _G.after = function(delay, cb) timers[#timers + 1] = { delay = delay, cb = cb, id = #timers + 1 }; return #timers end
  _G.cancel = function(id) if id then for _, t in ipairs(timers) do if t.id == id then t.cb = nil end end end end
  local snap = {}; for k, v in pairs(corpse) do snap[k] = v end
  corpse.on, corpse.active, corpse.settle, corpse.killed = true, false, nil, true
  corpse.kill_count = 1
  corpse_start()
  local during = harvesting()
  -- Fire the stall watchdog (the CORPSE_WATCHDOG-delay timer, the only long-delay one still armed).
  for _, t in ipairs(timers) do if t.cb and (t.delay or 0) >= 5 then t.cb() end end
  local after_fire = harvesting()
  for k in pairs(corpse) do corpse[k] = nil end
  for k, v in pairs(snap) do corpse[k] = v end
  state, send, echo, _G.after, _G.cancel = saved_state, saved_send, saved_echo, saved_after, saved_cancel
  expect(during):eq(true)                                   -- pass was running…
  expect(after_fire):eq(false)                              -- …and the watchdog wrapped it up
  expect(table.concat(echoed, "\n")):contains("stalled")    -- with the stall notice
end)
