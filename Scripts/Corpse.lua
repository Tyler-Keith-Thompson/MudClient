-- AlterAeon corpse automation (kxwt_mdeath-driven).
--
-- Split out of AlterAeon.lua. Fully stream/promise-driven. Reads the shared combat predicate
-- in_combat()/is_ally() (Combat.lua) and the reactive + promise layers (__rx/__promise); all globals,
-- resolved at call time, so file load order is irrelevant.
--
-- ARCHITECTURE (promise + reactive, mirrors AutoFight/Recovery/Combat): the after-kill loot pass is a
-- SEQUENTIAL machine — per corpse: harvest teeth → harvest spellcomps → bsac → (if empty) sac, walked
-- across the batch by index. It's written as a PROMISE FLOW that resolves off the game's own reply
-- STREAMS, not a hand-walked step counter:
--
--     process(idx) = harvest teeth              -- await the harvest terminal off harvestDoneS
--                    → harvest spellcomps        -- await it again (+ the successful-yield line)
--                    → bsac_then_sac(idx)        -- decide empty vs loot; sac only proven-empty ones
--                    → process(idx' )            -- next corpse (a sac shifts the next into THIS index)
--
-- Each step SENDS its command then awaits ITS reply line off a hot Subject (harvestDoneS/bsacReplyS/
-- sacReplyS), fed by the reply SEAMS below (corpse_harvest_done/corpse_sac/corpse_sac_done) that BOTH the
-- live triggers AND the specs call — one path, no second matcher to drift. The single in-flight await IS
-- the pacing gate: a stray reply with no await subscribed is simply dropped. `corpse.step`/`idx` have
-- dissolved into the flow (idx is a process() parameter; there is no step string). The stall watchdog is
-- the awaits' `:timeout(CORPSE_WATCHDOG)` — no hand-managed after/cancel id — and a tooth-progress tick
-- re-arms it (a fresh await) so a slow multi-tooth harvest can't trip it.
--
-- BEHAVIOUR (unchanged): ON by default (kxwt.corpse('off') to stop). Runs only after an actual KILL (not
-- a flee). When OUT OF COMBAT, walk the corpses in the room BY INDEX (1.corpse, 2.corpse, …) and HARVEST
-- each (teeth then spellcomps), then:
--   * EMPTY corpse -> bsac -> sac. `sac` removes it, so the next corpse shifts into THIS index (re-process).
--   * HAS LOOT -> drain its blood (bsac) but leave it INTACT and step to the NEXT index. We never
--     `get all` (looting was removed by request), and we must NEVER sacrifice a corpse that still holds
--     items — that would destroy them, incl. binding/quest gear (the medallion bug). "Has loot" is read
--     from the contents the game auto-prints at the kill ("(on ground) the corpse of X contains:"); each
--     corpse's NAME comes from its own "You start harvesting…" reply, so we only sac the ones we're sure
--     are empty.

state = state or {}
_AA_TEST = _AA_TEST or {}

-- Shared declarative DSL (on_all list-registrar) + reactive core (__rx) + promise layer (__promise).
-- require() live, dofile fallback in the bare test harness. `_`-prefixed files aren't auto-loaded.
pcall(require, "_dsl")
if not __dsl then dofile("Scripts/_dsl.lua") end
local on_all = __dsl.on_all
pcall(require, "_rx")
if not __rx then dofile("Scripts/_rx.lua") end
local rx = __rx

-- ---- learned per-KIND harvest memory (persisted) -------------------------------------------------
-- We learn which mob KINDS yield no teeth / no spellcomps and skip that harvest command on the next
-- corpse of the same kind. The barren-teeth reply ("You don't see any usable teeth here.") does NOT name
-- the corpse (only a SUCCESSFUL teeth harvest prints "You start harvesting teeth from the corpse of X"),
-- so the identity comes from what we KILLED (kxwt_mdeath) — batch_kind() below — trusted only when the
-- kill batch is a single unambiguous kind. Keyed by a normalized name (lowercased, leading article
-- stripped), exactly like the autofight winners; persisted to disk and kept on a global so a live reload
-- doesn't lose it. SAFETY: skipping teeth never changes the sacrifice decision — a barren-teeth corpse is
-- already left un-named and therefore intact today, so we only drop the wasted command.
local function corpse_kind_key(name)
  if not name then return nil end
  local k = tostring(name):lower():gsub("^%s+", ""):gsub("%s+$", "")
  k = k:gsub("^an? ", ""):gsub("^the ", "")     -- drop a leading "a "/"an "/"the "
  return (k ~= "" and k) or nil
end
local CORPSE_HARVEST_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/corpse_harvest.lua"
local function save_corpse_harvest()
  local f = io.open(CORPSE_HARVEST_FILE, "w"); if not f then return end
  local function set_parts(t)
    local p = {}; for k in pairs(t) do p[#p + 1] = string.format("[%q]=true", k) end
    return table.concat(p, ",")
  end
  f:write(string.format("return {no_teeth={%s},no_spellcomps={%s}}",
    set_parts(_CORPSE_HARVEST.no_teeth), set_parts(_CORPSE_HARVEST.no_spellcomps)))
  f:close()
end
local corpse_save_timer
local function schedule_corpse_save()   -- debounce a burst of learns into one write (like the winners file)
  if cancel and corpse_save_timer then cancel(corpse_save_timer) end
  corpse_save_timer = after and after(2, save_corpse_harvest) or nil
end
if not _CORPSE_HARVEST then             -- load ONCE per session (a live reload keeps the in-memory table)
  _CORPSE_HARVEST = { no_teeth = {}, no_spellcomps = {} }
  local chunk = loadfile and loadfile(CORPSE_HARVEST_FILE)
  if chunk then
    local ok, t = pcall(chunk)
    if ok and type(t) == "table" then
      if type(t.no_teeth) == "table" then for k in pairs(t.no_teeth) do _CORPSE_HARVEST.no_teeth[k] = true end end
      if type(t.no_spellcomps) == "table" then for k in pairs(t.no_spellcomps) do _CORPSE_HARVEST.no_spellcomps[k] = true end end
    end
  end
end
local function learn_no_teeth(key)
  if key and not _CORPSE_HARVEST.no_teeth[key] then _CORPSE_HARVEST.no_teeth[key] = true; schedule_corpse_save() end
end
local function learn_no_spellcomps(key)
  if key and not _CORPSE_HARVEST.no_spellcomps[key] then _CORPSE_HARVEST.no_spellcomps[key] = true; schedule_corpse_save() end
end

-- The corpse-automation state. `on` = armed; `active` = a loot pass is currently running; the batch inputs
-- (kills/kill_count for the harvest memory + walk bound, with_items for loot safety, cur_name learned per
-- corpse). The pass's PROGRESS (which index, which step) is NOT here — it lives in the promise flow below.
local corpse = { on = true, active = false, room = nil, killed = false,
                 settle = nil, promise = nil, remaining = nil,
                 kills = {}, kill_count = 0, with_items = {}, cur_name = nil }
if _AA_TEST then _AA_TEST.corpse = corpse end   -- exposed so the empty/has-loot decision is unit-tested

-- The distinct mob KIND(s) killed since the last pass reset — the identity for the harvest memory above.
-- note_kill records each non-ally kill; batch_kind() returns the single kind when the batch is
-- unambiguous (one kind of mob), else nil — we only trust a learned skip then, so we can never mis-skip a
-- different mob's corpse.
local function note_kill(name)
  if not name or (is_ally and is_ally(name)) then return end   -- our own minions also emit mdeath
  local k = corpse_kind_key(name); if not k then return end
  corpse.kills[k] = true                                        -- kinds (dedup) for the harvest memory
  corpse.kill_count = (corpse.kill_count or 0) + 1              -- COUNT of corpses we made this batch
end
local function batch_kind()
  local only, n = nil, 0
  for k in pairs(corpse.kills) do only, n = k, n + 1 end
  return (n == 1) and only or nil
end
if _AA_TEST then
  _AA_TEST.corpse_harvest = function() return _CORPSE_HARVEST end
  _AA_TEST.note_kill = note_kill
  _AA_TEST.batch_kind = batch_kind
  _AA_TEST.corpse_kind_key = corpse_kind_key
  _AA_TEST.learn_no_teeth = learn_no_teeth          -- what the barren-line triggers call
  _AA_TEST.learn_no_spellcomps = learn_no_spellcomps
end
local CORPSE_MAX = 20   -- safety cap on how many corpse indices we'll walk (guards a missed terminator)
-- Stall watchdog. Pacing stays STREAM-DRIVEN (each step awaits a real game line); this is only a
-- last-resort net: the harvest replies vary a lot (a successful `harvest spellcomps` just yields its
-- comps with no distinct "done" line), so if we ever miss a terminal the machine would hang forever —
-- corpse.active stuck true (blocking every future loot pass) and the promise row leaking. Each await is
-- guarded by CORPSE_WATCHDOG seconds (:timeout); a tooth-progress tick re-arms it (a fresh await).
local CORPSE_WATCHDOG = 5

-- ===== the reactive flow =========================================================================
-- Internal hot streams the per-corpse sequence awaits. Fed by the SEAMS below (corpse_harvest_done /
-- corpse_sac / corpse_sac_done + the yield/tooth adapters), which BOTH the live reply triggers AND the
-- specs call. The re-entrancy-safe Subject (see _rx) lets a resolving await SYNCHRONOUSLY subscribe the
-- next one on the same stream without the classic "invalid key to 'next'" mid-dispatch crash.
local harvestDoneS = rx and rx.subject() or nil   -- a harvest terminal line (teeth OR spellcomps)
local spellYieldS  = rx and rx.subject() or nil   -- a SUCCESSFUL spellcomps yield (its own terminal)
local toothS       = rx and rx.subject() or nil   -- mid-harvest tooth progress → re-arm the watchdog
local bsacReplyS   = rx and rx.subject() or nil   -- the blood-sacrifice reply
local sacReplyS    = rx and rx.subject() or nil   -- the sacrifice reply: emits "ok"/"fail"
local passEndS     = rx and rx.subject() or nil   -- the pass ended/cancelled → tear down any in-flight await

-- A flow promise: __promise but STARTED synchronously at construction (a step is built exactly when it
-- should run — inside the previous step's andThen — so construct == execute) and kept OUT of the HUD
-- promise widget (only corpse_start()'s own "harvesting corpses" promise is a widget row).
local function P(executor)
  local p = __promise(executor, "corpse-flow")
  if __untrack_promise then __untrack_promise(p) end
  if p and p.__start then p.__start() end
  return p
end

-- Await the next value from `obs`, guarded by the stall watchdog (:timeout) and torn down by passEndS.
-- The single active subscription IS the pacing gate: a stray reply with no await in flight is dropped.
local ABORT = {}
local function await_event(obs)
  local p = P(function(resolve, _, onCancel)
    local sub, esub, done = nil, nil, false
    local function cleanup()
      if sub  then sub:unsubscribe();  sub  = nil end
      if esub then esub:unsubscribe(); esub = nil end
    end
    local function fin(v) if done then return end; done = true; cleanup(); resolve(v) end
    sub  = obs:subscribe(function(...) fin((...)) end)          -- a reply → resolve with its value
    esub = passEndS:subscribe(function() fin(ABORT) end)        -- pass ended → resolve ABORT (flow bails)
    onCancel(function() done = true; cleanup() end)
  end)
  return p:timeout(CORPSE_WATCHDOG, "corpse stall")              -- the watchdog net (rejects on a stall)
end

-- Await the harvest terminal for ONE harvest command. A tooth-progress tick re-arms the watchdog (a slow
-- multi-tooth harvest must not trip the stall net), so on a "tick" we simply await again (fresh :timeout).
-- `yield` adds the successful-spellcomps yield line as an alternate terminal (the spellcomps step only, so
-- a stray yield during a teeth harvest — which has no yield subscriber — can't advance it early).
local function await_harvest(yield)
  local terms = { harvestDoneS:map(function() return "done" end),
                  toothS:map(function() return "tick" end) }
  if yield then terms[#terms + 1] = spellYieldS:map(function() return "done" end) end
  return await_event(rx.merge(table.unpack(terms))):andThen(function(ev)
    if ev == "tick" then return await_harvest(yield) end
    return ev
  end)
end

-- ---- loot safety + skip decisions (clean named functions the flow calls) --------------------------
-- corpse_is_empty() — is the CURRENT corpse safe to REMOVE (sac)? Two safe ways to know:
--   * we learned its NAME (from a harvest reply) and it never printed "…contains:" at the kill; OR
--   * we never learned a name — a FULLY barren corpse names itself in neither reply — but NO corpse in
--     this batch printed contents, so there's no loot anywhere to destroy.
-- Otherwise (name unknown while SOME corpse held loot, or it printed contents) it's NOT sac-safe.
local function corpse_is_empty()
  local name = corpse.cur_name
  return (name and not corpse.with_items[name]) or (not name and next(corpse.with_items) == nil)
end
-- Learned-skip predicates. We can skip AT MOST one of the two harvest commands — the harvest doubles as
-- the "does this index exist?" probe that ends the walk — so skip_teeth and skip_spellcomps are never both
-- honoured on one corpse (process() only consults skip_spellcomps on the teeth-first path).
local function skip_teeth()
  local kind = batch_kind()
  return (kind and _CORPSE_HARVEST.no_teeth[kind]) and true or false
end
local function skip_spellcomps()
  local key = corpse_kind_key(corpse.cur_name) or batch_kind()
  return (key and _CORPSE_HARVEST.no_spellcomps[key]) and true or false
end

local process   -- fwd (recursive)

-- `killed` = a mob actually DIED this fight (kxwt_mdeath), so combat ending means we have corpses to
-- work. Cleared here (and on a room change), so ending combat by FLEEING never kicks off looting.
-- Settling the promise (resolve) drops the row from the promise widget, whether the pass finished
-- naturally or was stopped (off / room change / stall).
function corpse_done()
  corpse.active = false; corpse.killed = false
  corpse.kills = {}; corpse.kill_count = 0; corpse.remaining = nil   -- fresh tallies for the next batch
  corpse.cur_name = nil
  if passEndS then passEndS:onNext() end          -- tear down any in-flight await (the flow then bails)
  local s = corpse.settle; corpse.settle = nil
  corpse.promise = nil
  if s then s.resolve() end
end

-- Blood-sacrifice this corpse, then REMOVE it only if it's proven empty. `bsac` drains blood safely from
-- ANY corpse (even one holding items); `sac` REMOVES the whole thing (and destroys any items). So we
-- BLOOD-SACRIFICE every corpse for the mana and only truly SAC the ones we're sure are empty. A confirmed
-- sac removes the corpse and shifts the next one into THIS index; a loot/unknown corpse (or a sac the god
-- refuses — too big) is left intact and we step PAST it. Doing the sac off the real reply (not
-- optimistically) is what keeps the index bookkeeping honest — sacrificing shifts the indices.
local function bsac_then_sac(idx)
  if not corpse.active then return end
  local empty = corpse_is_empty()                 -- decided BEFORE bsac (cur_name won't change now)
  send("bsac " .. idx .. ".corpse")               -- blood is safe to take from ANY corpse
  return await_event(bsacReplyS):andThen(function()
    if not corpse.active then return end
    if not empty then return process(idx + 1) end          -- held items → drained but NOT removed → next
    send("sac " .. idx .. ".corpse")                       -- empty → remove — but WAIT for the god's reply
    return await_event(sacReplyS):andThen(function(result)
      if not corpse.active then return end
      if result == "fail" then return process(idx + 1) end -- too big → leave intact, step past
      if corpse.remaining then corpse.remaining = corpse.remaining - 1 end   -- confirmed gone → one fewer
      return process(idx)                                   -- next corpse shifted into THIS index
    end)
  end)
end

-- Harvest + dispose the corpse at `idx`, then move on. Returns a promise for the REST of the pass.
-- Bounded by `corpse.remaining` (starts at the kill count, drops on each confirmed sac) so once idx passes
-- it we're done, instead of probing a `<n>.corpse` a sac already collapsed. nil remaining (kill count
-- unknown) = walk until the gagged miss line ends it.
process = function(idx)
  if not corpse.active then return end
  if idx > CORPSE_MAX then corpse_done(); return end                          -- absolute safety net
  if corpse.remaining and idx > corpse.remaining then corpse_done(); return end
  corpse.cur_name = nil                                                       -- re-learned per corpse
  -- Learned skip: a known no-teeth kind goes straight to spellcomps (which doubles as the existence
  -- probe). cur_name stays nil (as on any teeth failure), so the sacrifice decision is unchanged.
  if skip_teeth() then
    send("harvest spellcomps " .. idx .. ".corpse")
    return await_harvest(true):andThen(function() return bsac_then_sac(idx) end)
  end
  send("harvest teeth " .. idx .. ".corpse")
  return await_harvest(false):andThen(function()
    if not corpse.active then return end
    if skip_spellcomps() then return bsac_then_sac(idx) end                   -- known no-spellcomps → skip
    send("harvest spellcomps " .. idx .. ".corpse")
    return await_harvest(true):andThen(function() return bsac_then_sac(idx) end)
  end)
end

function corpse_start()
  if not corpse.on or corpse.active or in_combat() then return end
  corpse.active = true
  -- How many of OUR corpses to expect this pass. Decremented on each confirmed sac (bsac_then_sac). nil
  -- when we didn't count any kills → walk to the miss line (old behaviour).
  corpse.remaining = (corpse.kill_count and corpse.kill_count > 0) and corpse.kill_count or nil
  -- Surface the harvest pass as a tracked promise so it shows in the HUD widget ("harvesting corpses")
  -- and disappears when corpse_done() resolves it. Guarded so the driver runs without Promise.lua.
  -- CRITICAL: start it SYNCHRONOUSLY (p.__start()) so corpse.settle is wired before the flow runs — a
  -- stream line can end the pass before the builder's next-tick auto-start would otherwise fire.
  if __promise then
    local p = __promise(function(resolve, reject, onCancel)
      corpse.settle = { resolve = resolve, reject = reject }
      onCancel(function() corpse.settle = nil; if corpse.active then corpse_done() end end)
    end, "harvesting corpses")
    if p and p.__start then p.__start() end
    corpse.promise = p   -- keep the handle so turning corpse OFF mid-pass can CANCEL (abort) it, not resolve it
  end
  -- Kick the per-corpse sequence flow. A watchdog timeout deep in the chain rejects up to this catch, the
  -- single place that turns a missed reply into a clean close (ABORT — a deliberate teardown — is not a
  -- stall, so it passes through as a normal resolve and never trips the notice).
  local flow = process(1)
  if flow and flow.catch then
    flow:catch(function(why)
      if why ~= nil and why ~= ABORT and corpse.active then
        echo("\27[33m[corpse] loot pass stalled — wrapping it up.\27[0m")
        corpse_done()
      end
    end)
  end
end

-- ---- reply SEAMS: the triggers AND the specs push game replies through these -----------------------
-- Each pushes onto the stream the in-flight await subscribes to; when no step is awaiting a given event
-- the push has no subscriber and is dropped (the pacing guarantee — this is also why a duplicate sac
-- reply is harmless: the first resolves + unsubscribes the await, the second finds no subscriber).
function corpse_harvest_done()   if corpse.active and harvestDoneS then harvestDoneS:onNext() end end
function corpse_sac()            if corpse.active and bsacReplyS then bsacReplyS:onNext() end end
function corpse_sac_done(result) if corpse.active and sacReplyS then sacReplyS:onNext(result) end end
local function corpse_spell_yield() if corpse.active and spellYieldS then spellYieldS:onNext() end end
local function corpse_tooth()       if corpse.active and toothS then toothS:onNext() end end

-- ===== live wire -> seams ========================================================================
-- A mob DIED -> remember it and try to start (usually a no-op: you're still fighting, so corpse_start
-- bails; the real start is when combat ENDS below). kxwt_fighting -1 fires when combat ends for ANY
-- reason, so only walk corpses if a kill actually happened this fight — fleeing ends combat with no
-- corpse of ours (and moves us), and must NOT trigger looting.
trigger([[^kxwt_mdeath (.+)$]], function(_, name) corpse.killed = true; note_kill(name); corpse_start() end)
trigger([[^kxwt_fighting -1$]], function() if corpse.killed then corpse_start() end end)

-- Room change abandons this room's corpses (they don't follow you) -> stop, so we never target a corpse
-- in the wrong room (e.g. after fleeing).
trigger([[^kxwt_rvnum (-?\d+)]], function(_, vnum)
  if corpse.room ~= nil and corpse.room ~= vnum then
    corpse_done()
    corpse.with_items = {}   -- has-loot knowledge is per-room; forget it when we leave
  end
  corpse.room = vnum
end)

-- Loot detection WITHOUT looting: the game auto-prints a corpse's contents at the kill — "(on ground)
-- the corpse(s) of <name> contains:" — whenever it holds items. Record those names; the harvest walk then
-- bsac/sacs only the corpses that never showed contents (see corpse_is_empty). Loose (unanchored) on
-- purpose: over-recording just leaves a corpse un-sacrificed, while missing one would destroy its loot.
trigger([[the corpses? of (.+) contains:]], function(_, name) corpse.with_items[name] = true end)
-- Learn the current corpse's name from its own harvest reply so we can match it against with_items.
trigger([[^You start harvesting teeth from the corpses? of (.+?)\.?$]], function(_, name) corpse.cur_name = name end)

-- No corpse at the current index -> the room's corpses are done. The `'<n>.corpse'` miss is how the
-- index-walk detects "no more corpses", so gag it: it's internal plumbing, not something you did.
gag([[^You don't see anything named '\d+\.corpse']])
trigger([[^You don't see anything named]], function() if corpse.active then corpse_done() end end)
trigger([[^You don't see that here]], function() if corpse.active then corpse_done() end end)
-- Harvest/sac aimed at an index that isn't there any more (e.g. a corpse a sac just removed) -> done.
trigger([[^You do not see anything like that here]], function() if corpse.active then corpse_done() end end)

-- Harvest terminal lines (^-anchored so another player can't fire them). Success-complete OR the instant
-- "full"/"no skill" rejection — either way the harvest step is finished, so advance. Every one is the
-- same unconditional advance, so on_all binds the whole list to corpse_harvest_done at a glance.
on_all({
  [[^You don't see any usable]],             -- teeth (likely spellcomps too)
  [[^You can't safely carry any more teeth]], -- teeth full
  [[^Your collected teeth grow restless]],    -- teeth full
  [[^You don't know enough about the undead]], -- no spellcomp skill
  [[^You can't harvest spell components from that]], -- this corpse yields no spellcomps
}, corpse_harvest_done)
-- Mid-harvest PROGRESS (NOT a terminal): a single `harvest teeth` works through several teeth, printing
-- one of these per tooth before the terminal line. They're real activity, so re-arm the stall watchdog off
-- them — otherwise a slow multi-tooth harvest trips the false "loot pass stalled" timeout mid-work.
trigger([[^You carefully extract one tooth]], corpse_tooth)
trigger([[^You shatter one of the teeth]], corpse_tooth)

-- Learn barren KINDS (persisted) so the next corpse of the same kind skips the wasted harvest command.
-- Only "no teeth HERE" (a truly barren kind) teaches no_teeth — "no teeth REMAINING" just means THIS
-- corpse is already picked clean. Keyed by the single killed kind (batch_kind); a mixed-kind pack teaches
-- nothing (batch_kind nil), so we can never mislearn. These only RECORD — the terminal triggers above
-- still advance the pass. Guarded on corpse.active alone so firing order vs the advance doesn't matter.
trigger([[^You don't see any usable teeth here]],
  function() if corpse.active then learn_no_teeth(batch_kind()) end end)
trigger([[^You can't harvest spell components from that]],
  function() if corpse.active then learn_no_spellcomps(corpse_kind_key(corpse.cur_name) or batch_kind()) end end)
trigger([[^Looks like the corpses? of .+ (is|are) too damaged for you to use]], function() corpse_harvest_done() end) -- corpse(s) too mangled to harvest -> skip, keep going (plural for swarm/group mobs)
-- A SUCCESSFUL `harvest spellcomps` has no distinct "done" line — it just yields the component(s) and
-- stops (unlike teeth, which end on "grow restless"). So the yield line IS the terminal for the spellcomps
-- step — routed to spellYieldS, which ONLY the spellcomps await subscribes (so a stray yield can't advance
-- a teeth harvest early, nor can an earlier fight's line fire it). Necromancer comps come in a few shapes:
--   * "…drain <X> into <Y>"   ("You make a small incision and drain some fluid into a vial of bile.")
--   * "…tie off the ends…"    (hack-out/find a bladder of coloured fluid)
trigger([[^You .+ drain .+ into a vial]], corpse_spell_yield)
trigger([[^You .+ tie off the ends]], corpse_spell_yield)

-- Blood-sacrifice result (success OR the undead/"not intact" refusal) -> drives the sac decision.
trigger([[^You sacrifice blood from]], corpse_sac)
trigger([[^You can only blood sacrifice]], corpse_sac)

-- The `sac` result. The god's acceptance comes in a few shapes — a god/pantheon "appreciates your
-- sacrifice of <…>" or a "You receive N gold coins for your sacrifice of <…>" — all meaning the corpse is
-- GONE (indices shift). A too-big corpse can't be sacrificed and stays: the failure path. corpse_sac_done
-- ignores a duplicate reply (the god line + a gold line can both fire) because the first resolves the
-- await and unsubscribes it — the second push then has no subscriber.
trigger([[appreciates your sacrifice of]], function() corpse_sac_done("ok") end)
trigger([[^You receive \d+ gold coins? for your sacrifice of]], function() corpse_sac_done("ok") end)
trigger([[is too big for you to sacrifice]], function() corpse_sac_done("fail") end)

-- kxwt.corpse('on'|'off'|'status') (dispatched from the kxwt table). Returns true if it handled the verb.
function corpse_command(verb, rest)
  if verb ~= "corpse" then return false end
  local m = (rest or ""):lower():match("^%s*(%S*)")
  if m == "on" then
    corpse.on = true
    echo("[kxwt] corpse automation ON — out of combat, per corpse (by index): harvest teeth -> harvest spellcomps -> (if EMPTY) bsac -> sac; corpses holding loot are left intact (never `get all`, never sac loot)")
  elseif m == "off" then
    corpse.on = false
    if corpse.active then
      -- Mid-pass: if a timed action is actually running (state.action >= 50 — the same "busy" the HUD
      -- can't-cast widget shows, e.g. a harvest in progress), interrupt it on the MUD with `stop`.
      if (state.action or 0) >= 50 then send("stop") end
      -- Abort the pass by CANCELLING its promise — not resolving it, since the harvest didn't finish.
      -- cancel() runs the onCancel hook, which tears the pass state down (corpse_done, which fires
      -- passEndS to unsubscribe any in-flight await). Falls back to corpse_done() if the promise layer's off.
      if corpse.promise and corpse.promise.cancel then corpse.promise.cancel() else corpse_done() end
    else
      corpse_done()   -- nothing running; keep the original tidy-up
    end
    echo("[kxwt] corpse automation OFF")
  else
    echo(string.format("[kxwt] corpse %s | active=%s",
      corpse.on and "ON" or "off", tostring(corpse.active)))
  end
  return true
end
