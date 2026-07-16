




























































local corpse









state = state or {}
_AA_TEST = _AA_TEST or {}



local function boot(name) pcall(require, name) end
boot("_dsl"); if not __dsl then dofile("Scripts/Foundation/_dsl.lua") end
local on_all = (__dsl).on_all
boot("_rx"); if not __rx then dofile("Scripts/Foundation/_rx.lua") end
local rx = __rx
boot("_persist"); if not __persist then dofile("Scripts/Foundation/_persist.lua") end
local persist = __persist










local function corpse_kind_key(name)
   if not name then return nil end
   local k = tostring(name):lower():gsub("^%s+", ""):gsub("%s+$", "")
   k = k:gsub("^an? ", ""):gsub("^the ", "")
   return (k ~= "" and k) or nil
end
local CORPSE_HARVEST_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/corpse_harvest.lua"
local function save_corpse_harvest()
   local function set_parts(t)
      local p = {}; for k in pairs(t) do p[#p + 1] = string.format("[%q]=true", k) end
      return table.concat(p, ",")
   end
   persist.write(CORPSE_HARVEST_FILE, string.format("return {no_teeth={%s},no_spellcomps={%s},no_bsac={%s}}",
   set_parts(_CORPSE_HARVEST.no_teeth), set_parts(_CORPSE_HARVEST.no_spellcomps), set_parts(_CORPSE_HARVEST.no_bsac)))
end
local corpse_save_timer
local function schedule_corpse_save()
   if cancel and corpse_save_timer then cancel(corpse_save_timer) end
   corpse_save_timer = after and after(2, save_corpse_harvest) or nil
end
if not _CORPSE_HARVEST then
   _CORPSE_HARVEST = { no_teeth = {}, no_spellcomps = {}, no_bsac = {} }
   local t = persist.load(CORPSE_HARVEST_FILE)
   if type(t) == "table" then
      local no_teeth = t.no_teeth
      local no_spellcomps = t.no_spellcomps
      local no_bsac = t.no_bsac
      if type(no_teeth) == "table" then for k in pairs(no_teeth) do _CORPSE_HARVEST.no_teeth[k] = true end end
      if type(no_spellcomps) == "table" then for k in pairs(no_spellcomps) do _CORPSE_HARVEST.no_spellcomps[k] = true end end
      if type(no_bsac) == "table" then for k in pairs(no_bsac) do _CORPSE_HARVEST.no_bsac[k] = true end end
   end
end
_CORPSE_HARVEST.no_bsac = _CORPSE_HARVEST.no_bsac or {}
local function learn_no_teeth(key)
   if key and not _CORPSE_HARVEST.no_teeth[key] then _CORPSE_HARVEST.no_teeth[key] = true; schedule_corpse_save() end
end
local function learn_no_spellcomps(key)
   if key and not _CORPSE_HARVEST.no_spellcomps[key] then _CORPSE_HARVEST.no_spellcomps[key] = true; schedule_corpse_save() end
end


local function learn_no_bsac(key)
   if key and not _CORPSE_HARVEST.no_bsac[key] then _CORPSE_HARVEST.no_bsac[key] = true; schedule_corpse_save() end
end




corpse = { on = true, active = false, room = nil, killed = false,
settle = nil, promise = nil, remaining = nil,
kills = {}, kill_count = 0, with_items = {}, cur_name = nil, }
if _AA_TEST then _AA_TEST.corpse = corpse end





local function note_kill(name)
   if not name or (is_ally and is_ally(name)) then return end
   local k = corpse_kind_key(name); if not k then return end




   if (corpse.kill_count or 0) == 0 then corpse.with_items = {} end
   corpse.kills[k] = true
   corpse.kill_count = (corpse.kill_count or 0) + 1
end
local function batch_kind()
   local only = nil
   local n = 0
   for k in pairs(corpse.kills) do only, n = k, n + 1 end
   return (n == 1) and only or nil
end
if _AA_TEST then
   _AA_TEST.corpse_harvest = function() return _CORPSE_HARVEST end
   _AA_TEST.note_kill = note_kill
   _AA_TEST.batch_kind = batch_kind
   _AA_TEST.corpse_kind_key = corpse_kind_key
   _AA_TEST.learn_no_teeth = learn_no_teeth
   _AA_TEST.learn_no_spellcomps = learn_no_spellcomps
   _AA_TEST.learn_no_bsac = learn_no_bsac
end
local CORPSE_MAX = 20





local CORPSE_WATCHDOG = 5


















local harvestDoneS = rx and rx.subject() or nil
local spellYieldS = rx and rx.subject() or nil
local toothS = rx and rx.subject() or nil
local bsacReplyS = rx and rx.subject() or nil
local sacReplyS = rx and rx.subject() or nil
local passEndS = rx and rx.subject() or nil















local function P(executor)
   local p = __promise(executor, "corpse-flow")
   if __untrack_promise then __untrack_promise(p) end
   if p and p.__start then p.__start() end
   return p
end









trigger([[^(.+) is DEAD!$]], function(_, name)
   if is_ally and is_ally(name) then return end
   corpse.killed = true
   note_kill(name)
   if after then after(1.5, function() if corpse.killed and not in_combat() then corpse_start() end end) end
end)




local ABORT = {}
local function await_event(obs)
   local p = P(function(resolve, _, onCancel)
      local sub = nil
      local esub = nil
      local done = false
      local function cleanup()
         if sub then sub:unsubscribe(); sub = nil end
         if esub then esub:unsubscribe(); esub = nil end
      end
      local function fin(v) if done then return end; done = true; cleanup(); resolve(v) end
      sub = obs:subscribe(function(v) fin(v) end)
      esub = passEndS:subscribe(function() fin(ABORT) end)
      onCancel(function() done = true; cleanup() end)
   end)
   return p:timeout(CORPSE_WATCHDOG, "corpse stall")
end





local await_harvest
await_harvest = function(yield)
   local terms = { harvestDoneS:map(function(_) return "done" end),
toothS:map(function(_) return "tick" end), }
   if yield then terms[#terms + 1] = spellYieldS:map(function(_) return "done" end) end


   local merged = (rx).merge(table.unpack(terms))
   return await_event(merged):andThen(function(ev)
      if ev == "tick" then return await_harvest(yield) end
      return ev
   end)
end







local function corpse_is_empty()
   local name = corpse.cur_name
   return (name ~= nil and not corpse.with_items[name]) or (name == nil and next(corpse.with_items) == nil)
end



local function skip_teeth()
   local kind = batch_kind()
   return (kind and _CORPSE_HARVEST.no_teeth[kind]) and true or false
end
local function skip_spellcomps()
   local key = corpse_kind_key(corpse.cur_name) or batch_kind()
   return (key and _CORPSE_HARVEST.no_spellcomps[key]) and true or false
end

local function skip_bsac()
   local key = corpse_kind_key(corpse.cur_name) or batch_kind()
   return (key and _CORPSE_HARVEST.no_bsac[key]) and true or false
end

local process





function corpse_done()
   corpse.active = false; corpse.killed = false
   corpse.kills = {}; corpse.kill_count = 0; corpse.remaining = nil
   corpse.cur_name = nil
   if passEndS then passEndS:onNext(nil) end
   local s = corpse.settle; corpse.settle = nil
   corpse.promise = nil
   if s then (s.resolve)() end
end







local function bsac_then_sac(idx)
   if not corpse.active then return end
   local empty = corpse_is_empty()

   local function after_bsac()
      if not corpse.active then return end
      if not empty then return process(idx + 1) end
      send("sac " .. idx .. ".corpse")
      return await_event(sacReplyS):andThen(function(result)
         if not corpse.active then return end
         if result == "fail" then return process(idx + 1) end
         if corpse.remaining then corpse.remaining = corpse.remaining - 1 end
         return process(idx)
      end)
   end


   if skip_bsac() then return after_bsac() end
   send("bsac " .. idx .. ".corpse")
   return await_event(bsacReplyS):andThen(after_bsac)
end





process = function(idx)
   if not corpse.active then return end
   if idx > CORPSE_MAX then corpse_done(); return end
   if corpse.remaining and idx > corpse.remaining then corpse_done(); return end
   corpse.cur_name = nil


   if skip_teeth() then
      send("harvest spellcomps " .. idx .. ".corpse")
      return await_harvest(true):andThen(function() return bsac_then_sac(idx) end)
   end
   send("harvest teeth " .. idx .. ".corpse")
   return await_harvest(false):andThen(function()
      if not corpse.active then return end
      if skip_spellcomps() then return bsac_then_sac(idx) end
      send("harvest spellcomps " .. idx .. ".corpse")
      return await_harvest(true):andThen(function() return bsac_then_sac(idx) end)
   end)
end

function corpse_start()
   if not corpse.on or corpse.active or in_combat() then return end
   corpse.active = true






   corpse.remaining = (corpse.kill_count and corpse.kill_count > 0) and corpse.kill_count or nil




   if __promise then
      local p = __promise(function(resolve, reject, onCancel)
         corpse.settle = { resolve = resolve, reject = reject }
         onCancel(function() corpse.settle = nil; if corpse.active then corpse_done() end end)
      end, "harvesting corpses")
      if p and p.__start then p.__start() end
      corpse.promise = p
   end





   local flow = process(1)
   if flow and flow.catch then
      flow:catch(function(why)
         if why ~= nil and (why) ~= ABORT and corpse.active then
            echo("\27[33m[corpse] loot pass stalled — wrapping it up.\27[0m")
            corpse_done()
         end
      end)
   end
end





function corpse_harvest_done() if corpse.active and harvestDoneS then harvestDoneS:onNext(nil) end end
function corpse_sac() if corpse.active and bsacReplyS then bsacReplyS:onNext(nil) end end
function corpse_sac_done(result) if corpse.active and sacReplyS then sacReplyS:onNext(result) end end
local function corpse_spell_yield() if corpse.active and spellYieldS then spellYieldS:onNext(nil) end end
local function corpse_tooth() if corpse.active and toothS then toothS:onNext(nil) end end









trigger([[the corpses? of (.+) contains:]], function(_, name) corpse.with_items[name] = true end)

trigger([[^You start harvesting teeth from the corpses? of (.+?)\.?$]], function(_, name) corpse.cur_name = name end)



gag([[^You don't see anything named '\d+\.corpse']])
trigger([[^You don't see anything named]], function() if corpse.active then corpse_done() end end)
trigger([[^You don't see that here]], function() if corpse.active then corpse_done() end end)

trigger([[^You do not see anything like that here]], function() if corpse.active then corpse_done() end end)




on_all({
   [[^You don't see any usable]],
   [[^You can't safely carry any more teeth]],
   [[^Your collected teeth grow restless]],
   [[^You don't know enough about the undead]],
   [[^You can't harvest spell components from that]],
}, corpse_harvest_done)



trigger([[^You carefully extract one tooth]], corpse_tooth)
trigger([[^You shatter one of the teeth]], corpse_tooth)






trigger([[^You don't see any usable teeth here]],
function() if corpse.active then learn_no_teeth(batch_kind()) end end)
trigger([[^You can't harvest spell components from that]],
function() if corpse.active then learn_no_spellcomps(corpse_kind_key(corpse.cur_name) or batch_kind()) end end)
trigger([[^Looks like the corpses? of .+ (is|are) too damaged for you to use]], function() corpse_harvest_done() end)






trigger([[^You .+ drain .+ into a vial]], corpse_spell_yield)
trigger([[^You .+ tie off the ends]], corpse_spell_yield)


trigger([[^You sacrifice blood from]], corpse_sac)



trigger([[^You can only blood sacrifice]], function()
   if corpse.active then learn_no_bsac(corpse_kind_key(corpse.cur_name) or batch_kind()) end
   corpse_sac()
end)






trigger([[appreciates your sacrifice of]], function() corpse_sac_done("ok") end)
trigger([[^You receive \d+ gold coins? for your sacrifice of]], function() corpse_sac_done("ok") end)
trigger([[is too big for you to sacrifice]], function() corpse_sac_done("fail") end)


autoHarvest = {}

function autoHarvest.on()
   corpse.on = true
   echo("[harvest] corpse automation ON — out of combat, per corpse (by index): harvest teeth -> harvest spellcomps -> (if EMPTY) bsac -> sac; corpses holding loot are left intact (never `get all`, never sac loot)")
end
doc(autoHarvest.on, { name = "autoHarvest.on", sig = "autoHarvest.on()", group = "corpse",
text = "Arm the after-kill corpse-harvest automation: out of combat, per corpse (by index), harvest teeth " ..
"-> harvest spellcomps -> (if EMPTY) bsac -> sac; corpses holding loot are left intact.", })

function autoHarvest.off()
   corpse.on = false
   if corpse.active then


      if (state.action or 0) >= 50 then send("stop") end



      if corpse.promise and corpse.promise.cancel then corpse.promise:cancel() else corpse_done() end
   else
      corpse_done()
   end
   echo("[harvest] off")
end
doc(autoHarvest.off, { name = "autoHarvest.off", sig = "autoHarvest.off()", group = "corpse",
text = "Disarm the corpse-harvest automation. Mid-pass, interrupts a running MUD action with `stop` " ..
"(if busy) and cancels the in-flight harvest promise rather than letting it resolve.", })

function autoHarvest.status()
   echo(string.format("[harvest] %s | active=%s",
   corpse.on and "ON" or "off", tostring(corpse.active)))
end
doc(autoHarvest.status, { name = "autoHarvest.status", sig = "autoHarvest.status()", group = "corpse",
text = "Report whether corpse-harvest automation is armed (on/off) and whether a loot pass is active.", })


setmetatable(autoHarvest, { __call = function(_, rest)
   local m = (rest or ""):lower():match("^%s*(%S*)")
   if m == "on" then autoHarvest.on()
   elseif m == "off" then autoHarvest.off()
   else autoHarvest.status() end
end, })
