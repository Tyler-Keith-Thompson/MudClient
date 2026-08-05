-- Archery.tl — automate the periodic archery contest (help 'archery contest').
--
-- THE FLOW (a phased state machine driven by real server lines — NO timers). On the contest's
-- "USE 'EVENT START CONTEST' TO JOIN" announcement we arm a prompt; the user confirms with `arch` /
-- `#archery`, then:
--   PREP    read `equipment`, remove everything in a hand EXCEPT the ranged weapon (frees the hand the
--           game needs to load the weapon), wield the weapon, recall, pull a batch of ammo from the container.
--   JOIN    on the `THE ARCHERY CONTEST HAS STARTED!` line (before it the join is rejected), send
--           `event start contest` ONCE — no retry/spam.
--   FIRE    react to TARGET APPEARANCES, not a blind cycle. Fire the highest-PRIORITY target that's up
--           (pigeon → archery target → dummy) and keep firing the same one until it's hit or gone; a clay
--           pigeon self-destructs ("shatters into dust") so it goes first. One shot in flight at a time —
--           each result line drives the next (respects the fire cooldown). Ammo is COUNTED (get +1 / load
--           -1) and we `get all` to recollect spent darts BEFORE the inventory runs out — not on a cadence.
--   DONE    on "Your final score is N points": `put all.<ammo> <container>`, then re-equip what we removed.
--
-- Pure, unit-tested seams: parse_hand_slots, restore_verb, pick_target, target_of, and the state functions.
-- "equipment list complete" and other batch boundaries are read off real lines — never a timer.

global _ARCHERY_TEST: {string:any}
global archery: function()

-- ── config (edit + #reload) ─────────────────────────────────────────────────────────────────────────
local cfg = {
  weapon    = "blowgun",   -- ranged weapon keyword (kept/put back in hand for the contest)
  ammo      = "dart",      -- ammo keyword (get/put use it)
  container = "vortex",    -- the carried ammo container keyword
  priority  = { "pigeon", "target", "dummy" },  -- fire priority: pigeon self-destructs + is hard → first;
                                                -- then the 50-pt archery target; then the low-value dummy
  ammo_low  = 8,           -- recollect spent darts (`get all`) when the tracked inventory drops to this
  recall    = true,        -- recall during prep (a clean, known staging spot)
}

-- How each target type announces its arrival, and the keyword you `fire` at it with.
local APPEAR: {string:string} = {
  ["practice dummy pops up"]        = "dummy",
  ["clay pigeon flies through the air"] = "pigeon",
  ["archery target pops up"]        = "target",
}

-- Hand slots the game reports in `equipment` — these occupy a hand and block loading the weapon.
local HAND_SLOTS: {string:boolean} = { weapon = true, shield = true, held = true, light = true, second = true, dual = true }

local record HandItem
  slot: string
  kw:   string   -- keyword the game matches for remove/wield/hold (last word of the item name)
end

-- Parse an `equipment` listing into the items currently IN YOUR HANDS. Rows look like
-- `weapon      - (crafted)    a quartz-tipped wooden cane (light)`; key off the leading slot label, then
-- take the item's last word as a match keyword. Pure → unit-tested.
local function parse_hand_slots(block: string): {HandItem}
  local out: {HandItem} = {}
  for line in (block .. "\n"):gmatch("([^\n]*)\n") do
    local slot, rest = line:match("^%s*(%a+)%s+%-%s*(.-)%s*$")
    if slot and HAND_SLOTS[slot:lower()] and rest ~= "" then
      rest = rest:gsub("^%b()%s*", "")           -- drop a leading "(crafted)"/"(rare)" quality tag
      rest = rest:gsub("%s*%b()%s*$", "")         -- drop a trailing "(light)"/"(glow)" tag
      local last = rest:match("(%S+)%s*$")        -- last word → the match keyword
      if last then out[#out + 1] = { slot = slot:lower(), kw = last:lower() } end
    end
  end
  return out
end

-- The command that re-equips a slot: weapon → wield, shield → wear, anything else in hand → hold.
local function restore_verb(slot: string): string
  if slot == "weapon" then return "wield"
  elseif slot == "shield" then return "wear"
  else return "hold" end
end

-- Which target type a result line refers to ("… a practice dummy …, 20 points awarded!" → "dummy"). Pure.
local function target_of(line: string): string
  if line:find("clay pigeon") then return "pigeon"
  elseif line:find("archery target") then return "target"
  elseif line:find("practice dummy") then return "dummy"
  end
  return nil
end

-- ── live state machine ──────────────────────────────────────────────────────────────────────────────
local record State
  phase:      string        -- idle | prep | ready | joining | firing | done
  capturing:  boolean       -- reading the `equipment` block right now
  started:    boolean       -- the contest "HAS STARTED" line was seen → joining is now allowed
  snapshot:   {HandItem}     -- hand items we removed (restored after, minus the ranged weapon)
  removed:    integer
  up:         {string:integer}  -- currently-present target counts by type
  ammo:       integer           -- tracked inventory dart count (get +1 / load -1)
  in_flight:  boolean           -- a shot is out, awaiting its result line
  last_fired: string            -- target type of the in-flight shot
  recollecting: boolean         -- a `get all` is in flight; don't stack another
end
local function fresh(phase: string): State
  return { phase = phase, capturing = false, started = false, snapshot = {}, removed = 0,
           up = {}, ammo = 0, in_flight = false, last_fired = "", recollecting = false }
end
local S: State = fresh("idle")

local function say(msg: string) if echo then echo("[archery] " .. msg, "brightcyan") end end
local function active(): boolean return S.phase ~= "idle" and S.phase ~= "done" end

-- Highest-priority target type that is currently up (count > 0), or nil if the range is empty right now.
local function pick_target(): string
  for _, t in ipairs(cfg.priority) do
    if (S.up[t] or 0) > 0 then return t end
  end
  return nil
end

-- One shot at a time: recollect first if ammo is low, then fire the priority target. Each result line
-- calls this again; target appearances call it too (to start firing when the range had been empty).
local function fire_step()
  if S.phase ~= "firing" or S.in_flight then return end
  if S.ammo <= cfg.ammo_low and not S.recollecting then
    send("get all"); S.recollecting = true          -- pick spent darts back up before we run dry
  end
  local t = pick_target()
  if not t then return end                          -- nothing up; wait for the next appearance
  S.in_flight = true; S.last_fired = t
  send("fire " .. t)
end

-- ── join / prep ───────────────────────────────────────────────────────────────────────────────────────
local function try_join()
  if S.phase == "ready" and S.started then
    S.phase = "joining"; say("joining the contest"); send("event start contest")
  end
end

local function prep_done()
  send("wield " .. cfg.weapon)
  if cfg.recall then send("recall") end
  send("get all." .. cfg.ammo .. " " .. cfg.container)   -- pull a batch of ammo (each dart counts via `get`)
  S.phase = "ready"
  say(S.started and "joining" or "prepped — waiting for the contest to start")
  try_join()
end

local function start_removes()
  if #S.snapshot == 0 then prep_done(); return end
  for _, h in ipairs(S.snapshot) do send("remove " .. h.kw) end
end

local function finish()
  if S.phase == "done" then return end
  S.phase = "done"
  send("put all." .. cfg.ammo .. " " .. cfg.container)         -- stow remaining ammo
  for i = #S.snapshot, 1, -1 do                                 -- re-equip in reverse → original order
    local h = S.snapshot[i]
    send(restore_verb(h.slot) .. " " .. h.kw)
  end
  say("done — score is posted above; gear restored")
end

local function begin()
  if active() then say("already running (" .. S.phase .. ")"); return end
  S = fresh("prep"); S.capturing = true
  say("prepping — reading equipment")
  send("equipment")
end
function archery() begin() end

-- ── wiring ────────────────────────────────────────────────────────────────────────────────────────────
trigger([[EVENT START CONTEST' TO JOIN]], function(): any
  if S.phase == "idle" or S.phase == "done" then say("archery contest is starting — run  #archery  to auto-compete") end
end)

-- PREP: capture the hand-slot rows of `equipment`; the kxwt prompt (GA) ends the block → issue removes.
trigger([[^You are using:]], function(): any if S.phase == "prep" then S.capturing = true; S.snapshot = {} end end)
trigger([[^\s*[A-Za-z]+\s+-]], function(line: string): any
  if S.phase == "prep" and S.capturing then
    for _, h in ipairs(parse_hand_slots(line)) do
      if h.kw ~= cfg.weapon then S.snapshot[#S.snapshot + 1] = h end
    end
  end
end)
trigger([[^kxw[tq]_prompt ]], function(): any
  if S.phase == "prep" and S.capturing then S.capturing = false; start_removes() end
end)
trigger([[^You (stop using|remove) ]], function(): any
  if S.phase == "prep" and not S.capturing then
    S.removed = S.removed + 1
    if S.removed >= #S.snapshot then prep_done() end
  end
end)

-- JOIN: enabled by the "HAS STARTED" line (before it, the join is rejected). Join once.
trigger([[THE ARCHERY CONTEST HAS STARTED]], function(): any S.started = true; try_join() end)
-- JOIN → FIRE: the range greeting arms the fire loop; targets then drive it via APPEAR below.
trigger([[Ready your ranged weapon|must use ranged weapons to destroy]], function(): any
  if S.phase == "joining" then S.phase = "firing"; say("firing"); fire_step() end
end)

-- AMMO tracking: keyed off the load/get lines (a push source), so we recollect before running dry.
trigger([[^You load your weapon with a bone ]] .. cfg.ammo, function(): any if active() then S.ammo = S.ammo - 1 end end)
trigger([[^You get a bone ]] .. cfg.ammo, function(): any
  if active() then S.ammo = S.ammo + 1; if S.ammo > cfg.ammo_low then S.recollecting = false end end
end)

-- TARGET APPEARANCES → the target is now up; fire at it (if idle / higher priority than what we're on).
trigger([[SNAP, and a[n]? .+ (pops up|flies through the air)]], function(line: string): any
  if S.phase ~= "firing" then return end
  for phrase, kind in pairs(APPEAR) do
    if line:find(phrase, 1, true) then S.up[kind] = (S.up[kind] or 0) + 1; break end
  end
  fire_step()
end)

-- RESULTS drive the next shot. Hit → that target is destroyed (decrement). Miss → still up (keep trying).
trigger([[points awarded]], function(line: string): any
  if S.phase == "firing" then
    local k = target_of(line); if k then S.up[k] = math.max(0, (S.up[k] or 0) - 1) end
    S.in_flight = false; fire_step()
  end
end)
trigger([[but miss\.]], function(): any if S.phase == "firing" then S.in_flight = false; fire_step() end end)
-- The target we shot at is gone (fell just as we fired): clear it and move on.
trigger([[You do not see that character here]], function(): any
  if S.phase == "firing" then if S.last_fired ~= "" then S.up[S.last_fired] = 0 end; S.in_flight = false; fire_step() end
end)
-- A clay pigeon self-destructs on its own (independent of our shot): it's no longer a target.
trigger([[clay pigeon shatters into dust]], function(): any
  if S.phase == "firing" then S.up["pigeon"] = math.max(0, (S.up["pigeon"] or 0) - 1) end
end)

-- DONE: your run is scored and you're bounced back to recall.
trigger([[Your final score is \d+ points]], function(): any if S.phase == "firing" then finish() end end)

alias([[^arch(ery)?$]], function(): any begin() end)
if doc then doc("archery", { sig = "archery()  (or  arch)", group = "pilot",
  text = "Auto-run the archery contest (help 'archery contest'). Snapshots + clears your hands, wields the "
      .. "ranged weapon, recalls, pulls ammo from the container, joins on the contest-start line, then fires "
      .. "at whichever target is up (priority: clay pigeon → archery target → practice dummy), keeping at "
      .. "one until it's hit or shatters, and recollecting spent ammo before it runs out. On your final "
      .. "score it stows the ammo and re-equips your gear. Config at the top of Archery.tl (blowgun / dart / "
      .. "vortex). When a contest is announced, run this to compete.",
  example = "arch" }) end

_ARCHERY_TEST = {
  parse_hand_slots = parse_hand_slots, restore_verb = restore_verb, target_of = target_of,
  pick_target = pick_target, fire_step = fire_step, finish = finish, try_join = try_join,
  prep_done = prep_done, state = function(): State return S end, cfg = cfg, fresh = fresh,
}
