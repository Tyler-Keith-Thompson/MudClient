-- AlterAeon corpse automation (kxwt_mdeath-driven).
--
-- Split out of AlterAeon.lua. Fully stream/trigger-driven. Reads the shared combat predicate
-- in_combat()/is_ally() (Combat.lua) and the promise layer (__promise); all globals, resolved at
-- call time, so file load order is irrelevant.

state = state or {}
_AA_TEST = _AA_TEST or {}

-- ===== Corpse automation (kxwt_mdeath-driven) — fully stream/trigger-driven =====
-- ON by default (kxwt.corpse('off') to stop). Runs only after an actual KILL (not a flee — see below).
-- When you're OUT OF COMBAT, walk the corpses in the room BY INDEX (1.corpse, 2.corpse, ...) and HARVEST
-- each: harvest teeth -> harvest spellcomps, then:
--   * EMPTY corpse -> bsac -> sac. `sac` removes it, so the next corpse shifts into THIS index (re-process).
--   * HAS LOOT -> leave it INTACT and step to the NEXT index. We never `get all` (looting was removed by
--     request), and we must never sacrifice a corpse that still holds items — that would destroy them,
--     incl. binding/quest gear (the bug fixed earlier). "Has loot" is read from the contents the game
--     auto-prints at the kill ("(on ground) the corpse of X contains:"); each corpse's NAME comes from its
--     own "You start harvesting…" reply, so we only sac the ones we're sure are empty.
-- We stop when there's no corpse at the current index. Each step advances off a real STREAM line; the
-- watchdog below is only a last-resort net for a missed line.
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

local corpse = { on = true, active = false, idx = 1, step = nil, room = nil,
                 killed = false, settle = nil, promise = nil, watchdog = nil,
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

-- Stall watchdog. Pacing stays STREAM-DRIVEN (each step advances off a real game line); this is only a
-- last-resort net: the harvest replies vary a lot (a successful `harvest spellcomps` just yields its
-- comps with no distinct "done" line), so if we ever miss a terminal the machine would hang forever —
-- corpse.active stuck true (blocking every future loot pass) and the promise row leaking. If no step
-- has advanced within CORPSE_WATCHDOG seconds, force the pass closed so nothing stays wedged.
local CORPSE_WATCHDOG = 5
local function corpse_touch()
  if corpse.watchdog then cancel(corpse.watchdog); corpse.watchdog = nil end
  if not corpse.active then return end
  corpse.watchdog = after(CORPSE_WATCHDOG, function()
    corpse.watchdog = nil
    if corpse.active then echo("\27[33m[corpse] loot pass stalled — wrapping it up.\27[0m"); corpse_done() end
  end)
end

-- `killed` = a mob actually DIED this fight (kxwt_mdeath), so combat ending means we have corpses to
-- work. Cleared here (and on a room change), so ending combat by FLEEING — which changes rooms and
-- leaves no corpse of ours — never kicks off looting. Settling the promise (resolve) drops the row from
-- the promise widget, whether the pass finished naturally or was stopped (off / room change).
function corpse_done()
  corpse.active = false; corpse.step = nil; corpse.idx = 1; corpse.killed = false
  corpse.promise = nil; corpse.kills = {}; corpse.kill_count = 0; corpse.remaining = nil   -- fresh tallies for the next batch
  corpse.cur_empty = nil
  if corpse.watchdog then cancel(corpse.watchdog); corpse.watchdog = nil end
  local s = corpse.settle; corpse.settle = nil
  if s then s.resolve() end
end

function corpse_start()
  if not corpse.on or corpse.active or in_combat() then return end
  corpse.active = true; corpse.idx = 1
  -- How many of OUR corpses to expect in the room this pass. Decremented on each confirmed sac (see
  -- corpse_sac_done). nil when we didn't count any kills → walk to the miss line (old behaviour).
  corpse.remaining = (corpse.kill_count and corpse.kill_count > 0) and corpse.kill_count or nil
  -- Surface the harvest pass as a tracked promise so it shows in the HUD promise widget ("harvesting
  -- corpses") and disappears when corpse_done() resolves it. Guarded so the driver runs without Promise.lua.
  -- CRITICAL: start the promise SYNCHRONOUSLY (p.__start()) so corpse.settle is wired *before* we harvest.
  -- The builder otherwise runs its executor on the next tick (after(0)); but corpse_done() — driven by
  -- stream lines — can fire before that tick, find corpse.settle still nil, and never resolve, leaking
  -- the widget row forever. Running the executor now removes the timing dependency entirely.
  if __promise then
    local p = __promise(function(resolve, reject, onCancel)
      corpse.settle = { resolve = resolve, reject = reject }
      onCancel(function() corpse.settle = nil; if corpse.active then corpse_done() end end)
    end, "harvesting corpses")
    if p and p.__start then p.__start() end
    corpse.promise = p   -- keep the handle so turning corpse OFF mid-pass can CANCEL (abort) it, not resolve it
  end
  corpse_process()
end

-- Loot + harvest the corpse at corpse.idx. Loot triggers set `dirty`; harvest terminals advance us.
function corpse_process()
  if not corpse.active then return end
  if corpse.idx > CORPSE_MAX then corpse_done(); return end   -- absolute safety net
  -- Bound the walk by how many of OUR corpses are still in the room. `remaining` starts at the kill count
  -- and DROPS on each confirmed sac — a sac removes the corpse and shifts every higher index down one — so
  -- once idx passes it we're done, instead of probing a `<n>.corpse` a sac already collapsed (the "look at
  -- 2.corpse after sacrificing the first" bug). nil = kill count unknown → walk to the gagged miss line.
  if corpse.remaining and corpse.idx > corpse.remaining then corpse_done(); return end
  corpse_touch()          -- progress: (re)arm the stall watchdog
  corpse.step, corpse.cur_name = "teeth", nil   -- cur_name is re-learned from this corpse's harvest reply
  -- Learned skip: if we've killed a single, unambiguous kind and know it has no teeth, don't waste the
  -- teeth harvest — go straight to spellcomps. cur_name stays nil (as it already is on any teeth failure),
  -- so the sacrifice decision is unchanged. NOTE: we must still send SOMETHING — the harvest doubles as
  -- the "does this index exist?" probe that ends the walk ("You don't see anything named '<n>.corpse'"),
  -- so we can skip AT MOST one of the two commands, never both.
  local kind = batch_kind()
  if kind and _CORPSE_HARVEST.no_teeth[kind] then
    corpse.step = "spellcomps"
    send("harvest spellcomps " .. corpse.idx .. ".corpse")
    return
  end
  -- Harvest is the FIRST thing we send now — no `get all`. On a missing corpse this yields "You don't see
  -- anything named '<n>.corpse'" (or the watchdog fires), which ends the walk.
  send("harvest teeth " .. corpse.idx .. ".corpse")
end

-- A harvest terminal line was seen -> next harvest, or on to the empty/has-loot decision.
function corpse_harvest_done()
  if not corpse.active then return end
  corpse_touch()          -- progress: (re)arm the stall watchdog
  if corpse.step == "teeth" then
    corpse.step = "spellcomps"
    -- Learned skip: this corpse's kind (named by the teeth harvest we just finished, else the batch kill)
    -- is known to yield no spellcomps → don't send the harvest, go straight to the empty/has-loot decision.
    local key = corpse_kind_key(corpse.cur_name) or batch_kind()
    if key and _CORPSE_HARVEST.no_spellcomps[key] then corpse_finish(); return end
    send("harvest spellcomps " .. corpse.idx .. ".corpse")
  elseif corpse.step == "spellcomps" then
    corpse_finish()
  end
end

-- Done harvesting this corpse. `bsac` only DRAINS the blood (safe even on a corpse holding items), while
-- `sac` REMOVES the whole thing (and destroys any items). So we BLOOD-SACRIFICE every corpse for the mana,
-- and only truly SAC (remove) the ones we're sure are EMPTY. A corpse we know holds loot — or can't
-- identify — gets its blood taken and is then left INTACT (never sac'd).
function corpse_finish()
  if not corpse.active then return end
  local name = corpse.cur_name
  -- Empty enough to REMOVE (sac)? Two safe ways to know:
  --   * we learned its NAME (from a harvest reply) and it never printed "…contains:" at the kill; OR
  --   * we never learned a name — a FULLY barren corpse names itself in neither reply — but NO corpse in
  --     this batch printed "…contains:", so there's no loot anywhere to destroy.
  -- Otherwise (name unknown while SOME corpse held loot, or it printed contents) it's NOT sac-safe.
  corpse.cur_empty = (name and not corpse.with_items[name]) or (not name and next(corpse.with_items) == nil)
  corpse.step = "bsac"
  send("bsac " .. corpse.idx .. ".corpse")     -- blood is safe to take from ANY corpse; sac decision comes next
end

-- The blood-sacrifice resolved (its reply drives us here). bsac took the blood; now REMOVE the corpse only
-- if it's empty. A corpse holding loot (or one we couldn't identify) keeps its items — leave it intact and
-- step to the next index, exactly like a sac that fails.
function corpse_sac()
  if not corpse.active or corpse.step == "sac" then return end
  corpse_touch()          -- progress: (re)arm the stall watchdog
  if not corpse.cur_empty then
    corpse.idx = corpse.idx + 1               -- held items → drained but NOT removed; on to the next corpse
    corpse_process()
    return
  end
  corpse.step = "sac"
  send("sac " .. corpse.idx .. ".corpse")   -- empty → remove it — but WAIT for the god's reply before re-processing
end

-- The `sac` resolved (STREAM-driven, like every other step). "ok" = the god accepted it (an "appreciates
-- your sacrifice"/"gold coins for your sacrifice" line): the corpse is GONE, so one fewer remains and the
-- next corpse has shifted into THIS index — drop `remaining` and re-process the same idx. "fail" (e.g. the
-- corpse is too big to sacrifice) = it's still here: leave it intact and step PAST it, exactly like a
-- loot corpse. Doing this off the real reply (not optimistically) is what keeps the index/`remaining`
-- bookkeeping honest — sacrificing shifts the indices, so we must not re-index until it's confirmed gone.
function corpse_sac_done(result)
  if not corpse.active or corpse.step ~= "sac" then return end
  corpse_touch()
  if result == "fail" then
    corpse.idx = corpse.idx + 1                              -- couldn't sac it → leave it, next index
  elseif corpse.remaining then
    corpse.remaining = corpse.remaining - 1                  -- confirmed gone → one fewer corpse in the room
  end
  corpse_process()                                           -- re-process (same idx on success — the next shifted in)
end

-- A mob DIED -> remember it and try to start (usually a no-op: you're still fighting, so corpse_start
-- bails; the real start is when combat ENDS below). kxwt_fighting -1 fires when combat ends for ANY
-- reason, so only walk corpses if a kill actually happened this fight — fleeing ends combat with no
-- corpse of ours (and moves us), and must NOT trigger looting.
trigger([[^kxwt_mdeath (.+)$]], function(_, name) corpse.killed = true; note_kill(name); corpse_start() end)
trigger([[^kxwt_fighting -1$]], function() if corpse.killed then corpse_start() end end)

-- Room change abandons this room's corpses (they don't follow you) -> stop, so we never target a
-- corpse in the wrong room (e.g. after fleeing).
trigger([[^kxwt_rvnum (-?\d+)]], function(_, vnum)
  if corpse.room ~= nil and corpse.room ~= vnum then
    corpse_done()
    corpse.with_items = {}   -- has-loot knowledge is per-room; forget it when we leave
  end
  corpse.room = vnum
end)

-- Loot detection WITHOUT looting: the game auto-prints a corpse's contents at the kill — "(on ground)
-- the corpse(s) of <name> contains:" — whenever it holds items. Record those names; the harvest walk
-- then bsac/sacs only the corpses that never showed contents (see corpse_finish). Loose (unanchored) on
-- purpose: over-recording just leaves a corpse un-sacrificed, while missing one would destroy its loot.
trigger([[the corpses? of (.+) contains:]], function(_, name) corpse.with_items[name] = true end)
-- Learn the current corpse's name from its own harvest reply so we can match it against with_items.
trigger([[^You start harvesting teeth from the corpses? of (.+?)\.?$]], function(_, name) corpse.cur_name = name end)

-- No corpse at the current index -> the room's corpses are done. The `'<n>.corpse'` miss is how the
-- index-walk detects "no more corpses", so gag it: it's internal plumbing, not something you did.
gag([[^You don't see anything named '\d+\.corpse']])
trigger([[^You don't see anything named]], function() if corpse.active then corpse_done() end end)
trigger([[^You don't see that here]], function() if corpse.active then corpse_done() end end)
-- Harvest/sac aimed at an index that isn't there any more (e.g. a corpse a sac just removed) -> the
-- room's corpses are done. Same "no such target" meaning as above, just the harvest/sac phrasing.
trigger([[^You do not see anything like that here]], function() if corpse.active then corpse_done() end end)

-- Harvest terminal lines (^-anchored so another player can't fire them). Success-complete OR the
-- instant "full"/"no skill" rejection — either way the harvest step is finished, so advance. Declared as
-- data: every one is the same unconditional advance, so the list of terminals reads at a glance.
for _, pat in ipairs({
  [[^You don't see any usable]],             -- teeth (likely spellcomps too)
  [[^You can't safely carry any more teeth]], -- teeth full
  [[^Your collected teeth grow restless]],    -- teeth full
  [[^You don't know enough about the undead]], -- no spellcomp skill
  [[^You can't harvest spell components from that]], -- this corpse yields no spellcomps
}) do trigger(pat, function() corpse_harvest_done() end) end
-- Mid-harvest PROGRESS (NOT a step advance): a single `harvest teeth` works through several teeth, printing
-- one of these per tooth before the terminal line. They're real activity, so re-arm the stall watchdog off
-- them — otherwise a slow multi-tooth harvest trips the false "loot pass stalled" timeout mid-work.
trigger([[^You carefully extract one tooth]], function() if corpse.active then corpse_touch() end end)
trigger([[^You shatter one of the teeth]], function() if corpse.active then corpse_touch() end end)

-- Learn barren KINDS (persisted) so the next corpse of the same kind skips the wasted harvest command.
-- Only "no teeth HERE" (a truly barren kind) teaches no_teeth — "no teeth REMAINING" just means THIS
-- corpse is already picked clean, not that the kind never has any. Keyed by the single killed kind
-- (batch_kind); a mixed-kind pack teaches nothing (batch_kind nil), so we can never mislearn. These only
-- RECORD — the terminal triggers above still advance the pass. Guarded on corpse.active alone (not step)
-- so firing order vs the advance trigger doesn't matter.
trigger([[^You don't see any usable teeth here]],
  function() if corpse.active then learn_no_teeth(batch_kind()) end end)
trigger([[^You can't harvest spell components from that]],
  function() if corpse.active then learn_no_spellcomps(corpse_kind_key(corpse.cur_name) or batch_kind()) end end)
trigger([[^Looks like the corpses? of .+ (is|are) too damaged for you to use]], function() corpse_harvest_done() end) -- corpse(s) too mangled to harvest -> skip, keep going (plural for swarm/group mobs)
-- A SUCCESSFUL `harvest spellcomps` has no distinct "done" line — it just yields the component(s) and
-- stops (unlike teeth, which end on "grow restless"). So the yield line IS the terminal for the
-- spellcomps step. Necromancer comps come in a few shapes; generalized to catch every colour/type:
--   * "…drain <X> into <Y>"          ("You make a small incision and drain some fluid into a vial of
--                                      bile.", "You find a dark cyst and drain it into a vial of melancholy.")
--   * "…tie off the ends…"           (hack-out/find a bladder of coloured fluid)
-- Gated to the spellcomps step so a stray yield can't advance a teeth harvest early — and so an earlier
-- fight's line can't fire it.
trigger([[^You .+ drain .+ into a vial]],
  function() if corpse.active and corpse.step == "spellcomps" then corpse_harvest_done() end end)
trigger([[^You .+ tie off the ends]],
  function() if corpse.active and corpse.step == "spellcomps" then corpse_harvest_done() end end)

-- Blood-sacrifice result (success OR the undead/"not intact" refusal) -> the final sacrifice.
trigger([[^You sacrifice blood from]], function() if corpse.active and corpse.step == "bsac" then corpse_sac() end end)
trigger([[^You can only blood sacrifice]], function() if corpse.active and corpse.step == "bsac" then corpse_sac() end end)

-- The `sac` result. The god's acceptance comes in a few shapes — either a god/pantheon "appreciates your
-- sacrifice of <the corpse/gutted carcass/skinned corpse/… of X>" or a "You receive N gold coins for your
-- sacrifice of <…>" — all meaning the corpse is GONE (indices shift). We gate on step=="sac", so we don't
-- need to match the exact corpse wording: any acceptance during our sac IS our sac. A too-big corpse can't
-- be sacrificed and stays, so that's the failure path. corpse_sac_done ignores a duplicate reply (the god
-- line + a gold line can both fire) because it changes the step on the first.
local function on_sac_ok() if corpse.active and corpse.step == "sac" then corpse_sac_done("ok") end end
trigger([[appreciates your sacrifice of]], on_sac_ok)
trigger([[^You receive \d+ gold coins? for your sacrifice of]], on_sac_ok)
trigger([[is too big for you to sacrifice]], function() if corpse.active and corpse.step == "sac" then corpse_sac_done("fail") end end)

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
      -- cancel() runs the onCancel hook, which tears the pass state down (corpse_done) and cascades the
      -- cancellation to anything chained off it. Falls back to corpse_done() if the promise layer is off.
      if corpse.promise and corpse.promise.cancel then corpse.promise.cancel() else corpse_done() end
    else
      corpse_done()   -- nothing running; keep the original tidy-up
    end
    echo("[kxwt] corpse automation OFF")
  else
    echo(string.format("[kxwt] corpse %s | active=%s idx=%d step=%s",
      corpse.on and "ON" or "off", tostring(corpse.active), corpse.idx, tostring(corpse.step)))
  end
  return true
end
