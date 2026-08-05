






















local cfg = {
   weapon = "blowgun",
   ammo = "dart",
   container = "vortex",
   priority = { "pigeon", "target", "dummy" },

   ammo_low = 8,
   recall = true,
}


local APPEAR = {
   ["practice dummy pops up"] = "dummy",
   ["clay pigeon flies through the air"] = "pigeon",
   ["archery target pops up"] = "target",
}


local HAND_SLOTS = { weapon = true, shield = true, held = true, light = true, second = true, dual = true }









local function parse_hand_slots(block)
   local out = {}
   for line in (block .. "\n"):gmatch("([^\n]*)\n") do
      local slot, rest = line:match("^%s*(%a+)%s+%-%s*(.-)%s*$")
      if slot and HAND_SLOTS[slot:lower()] and rest ~= "" then
         rest = rest:gsub("^%b()%s*", "")
         rest = rest:gsub("%s*%b()%s*$", "")
         local last = rest:match("(%S+)%s*$")
         if last then out[#out + 1] = { slot = slot:lower(), kw = last:lower() } end
      end
   end
   return out
end


local function restore_verb(slot)
   if slot == "weapon" then return "wield"
   elseif slot == "shield" then return "wear"
   else return "hold" end
end


local function target_of(line)
   if line:find("clay pigeon") then return "pigeon"
   elseif line:find("archery target") then return "target"
   elseif line:find("practice dummy") then return "dummy"
   end
   return nil
end














local function fresh(phase)
   return { phase = phase, capturing = false, started = false, snapshot = {}, removed = 0,
up = {}, ammo = 0, in_flight = false, last_fired = "", recollecting = false, }
end
local S = fresh("idle")

local function say(msg) if echo then echo("[archery] " .. msg, "brightcyan") end end
local function active() return S.phase ~= "idle" and S.phase ~= "done" end


local function pick_target()
   for _, t in ipairs(cfg.priority) do
      if (S.up[t] or 0) > 0 then return t end
   end
   return nil
end



local function fire_step()
   if S.phase ~= "firing" or S.in_flight then return end
   if S.ammo <= cfg.ammo_low and not S.recollecting then
      send("get all"); S.recollecting = true
   end
   local t = pick_target()
   if not t then return end
   S.in_flight = true; S.last_fired = t
   send("fire " .. t)
end


local function try_join()
   if S.phase == "ready" and S.started then
      S.phase = "joining"; say("joining the contest"); send("event start contest")
   end
end

local function prep_done()
   send("wield " .. cfg.weapon)
   if cfg.recall then send("recall") end
   send("get all." .. cfg.ammo .. " " .. cfg.container)
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
   send("put all." .. cfg.ammo .. " " .. cfg.container)
   for i = #S.snapshot, 1, -1 do
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


trigger([[EVENT START CONTEST' TO JOIN]], function()
   if S.phase == "idle" or S.phase == "done" then say("archery contest is starting — run  #archery  to auto-compete") end
end)


trigger([[^You are using:]], function() if S.phase == "prep" then S.capturing = true; S.snapshot = {} end end)
trigger([[^\s*[A-Za-z]+\s+-]], function(line)
   if S.phase == "prep" and S.capturing then
      for _, h in ipairs(parse_hand_slots(line)) do
         if h.kw ~= cfg.weapon then S.snapshot[#S.snapshot + 1] = h end
      end
   end
end)
trigger([[^kxw[tq]_prompt ]], function()
   if S.phase == "prep" and S.capturing then S.capturing = false; start_removes() end
end)
trigger([[^You (stop using|remove) ]], function()
   if S.phase == "prep" and not S.capturing then
      S.removed = S.removed + 1
      if S.removed >= #S.snapshot then prep_done() end
   end
end)


trigger([[THE ARCHERY CONTEST HAS STARTED]], function() S.started = true; try_join() end)

trigger([[Ready your ranged weapon|must use ranged weapons to destroy]], function()
   if S.phase == "joining" then S.phase = "firing"; say("firing"); fire_step() end
end)


trigger([[^You load your weapon with a bone ]] .. cfg.ammo, function() if active() then S.ammo = S.ammo - 1 end end)
trigger([[^You get a bone ]] .. cfg.ammo, function()
   if active() then S.ammo = S.ammo + 1; if S.ammo > cfg.ammo_low then S.recollecting = false end end
end)


trigger([[SNAP, and a[n]? .+ (pops up|flies through the air)]], function(line)
   if S.phase ~= "firing" then return end
   for phrase, kind in pairs(APPEAR) do
      if line:find(phrase, 1, true) then S.up[kind] = (S.up[kind] or 0) + 1; break end
   end
   fire_step()
end)


trigger([[points awarded]], function(line)
   if S.phase == "firing" then
      local k = target_of(line); if k then S.up[k] = math.max(0, (S.up[k] or 0) - 1) end
      S.in_flight = false; fire_step()
   end
end)
trigger([[but miss\.]], function() if S.phase == "firing" then S.in_flight = false; fire_step() end end)

trigger([[You do not see that character here]], function()
   if S.phase == "firing" then if S.last_fired ~= "" then S.up[S.last_fired] = 0 end; S.in_flight = false; fire_step() end
end)

trigger([[clay pigeon shatters into dust]], function()
   if S.phase == "firing" then S.up["pigeon"] = math.max(0, (S.up["pigeon"] or 0) - 1) end
end)


trigger([[Your final score is \d+ points]], function() if S.phase == "firing" then finish() end end)

alias([[^arch(ery)?$]], function() begin() end)
if doc then doc("archery", { sig = "archery()  (or  arch)", group = "pilot",
text = "Auto-run the archery contest (help 'archery contest'). Snapshots + clears your hands, wields the " ..
"ranged weapon, recalls, pulls ammo from the container, joins on the contest-start line, then fires " ..
"at whichever target is up (priority: clay pigeon → archery target → practice dummy), keeping at " ..
"one until it's hit or shatters, and recollecting spent ammo before it runs out. On your final " ..
"score it stows the ammo and re-equips your gear. Config at the top of Archery.tl (blowgun / dart / " ..
"vortex). When a contest is announced, run this to compete.",
example = "arch", }) end

_ARCHERY_TEST = {
   parse_hand_slots = parse_hand_slots, restore_verb = restore_verb, target_of = target_of,
   pick_target = pick_target, fire_step = fire_step, finish = finish, try_join = try_join,
   prep_done = prep_done, state = function() return S end, cfg = cfg, fresh = fresh,
}
