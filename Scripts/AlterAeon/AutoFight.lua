






















































state = state or {}






local function boot(name) pcall(require, name) end
boot("_rx")
if not __rx then dofile("Scripts/Foundation/_rx.lua") end

boot("_persist")
if not __persist then dofile("Scripts/Foundation/_persist.lua") end
local persist = __persist




boot("Events")
if not onSpellLanded then dofile("Scripts/AlterAeon/Events.lua") end

























local cfg = {




   max_tries = 4,
   resume_after = 6,
   soulsteal_pct = 15,
   new_target_jump = 20,

   aoe_min = 2,
   room_burst = 2,

   opener_tarrants = "c tarrants",
   bloodmist_cmd = "c bloodmist",

   bloodmist_hp_min = 0.5,
   lightning_cmd = "cast 'lightning bolt'",
   icebolt_cmd = "c icebolt",
   fireball_cmd = "c fireball",
   prism_cmd = "c prism",
   probe_enough = 5,


   fireball_bias = 5,


   soulsteal_cmd = "c soulsteal",
   aoe_cmd = "c frostflower",



   shower_cmd = "c shower",

   clay_cmd = "cast 'clay man'",
   clay_retry = 4,
   clay_max_tries = 8,
}








































































_AUTOFIGHT = _AUTOFIGHT or { on = true }
local F = _AUTOFIGHT

F.fighting = F.fighting or false
F.phase = F.phase or "idle"
F.suspended = F.suspended or false
F.self_sent = F.self_sent or {}
F.no_mana = F.no_mana or {}
F.lightning_drop = F.lightning_drop or 0
F.icebolt_drop = F.icebolt_drop or 0
F.fireball_drop = F.fireball_drop or 0
F.prism_drop = F.prism_drop or 0
F.fallback_tried = F.fallback_tried or false
F.finish_ready = F.finish_ready or false



F.engaging = F.engaging or false
F.engage_busy = F.engage_busy or false
F.engage_tries = F.engage_tries or 0
F.opener_primed = F.opener_primed or false
F.on_dead = F.on_dead or nil
F.on_fail = F.on_fail or nil





F.fought = F.fought or false
F.soul_latched = F.soul_latched or false




F.aoe_mode = F.aoe_mode or "auto"
F.pack = F.pack or false
F.room_seen = F.room_seen or 0
F.enemy_est = F.enemy_est or 0





F.fight_settle = nil
F.fight_promise = nil



local sent = {}
local function clear_sent() for i = #sent, 1, -1 do sent[i] = nil end end

local function say(s) if echo then echo("\27[1;35m[autofight]\27[0m " .. s) end end







local function winner_key(name)
   if not name then return nil end
   local k = tostring(name):lower():gsub("^%s+", ""):gsub("%s+$", "")
   k = k:gsub("^an? ", ""):gsub("^the ", "")
   return (k ~= "" and k) or nil
end




local PROBE_SPELLS = { "lightning", "icebolt", "fireball", "prism" }
local function is_probe_spell(s) for _, v in ipairs(PROBE_SPELLS) do if v == s then return true end end; return false end
local function probe_spellset_key() local t = {}; for _, v in ipairs(PROBE_SPELLS) do t[#t + 1] = v end; table.sort(t); return table.concat(t, ",") end

local WINNERS_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/autofight_winners.lua"


local function save_winners()
   local parts = {}


   for name, spell in pairs(_AUTOFIGHT.winners) do
      if is_probe_spell(spell) then parts[#parts + 1] = string.format("[%q]=%q", name, spell) end
   end
   persist.write(WINNERS_FILE, string.format("return {[%q]=%q,[%q]={%s}}", "spells", probe_spellset_key(), "winners", table.concat(parts, ",")))
end

local winners_save_timer
local function schedule_winners_save()
   if cancel and winners_save_timer then cancel(winners_save_timer) end
   winners_save_timer = after and after(2, save_winners) or nil
end







local function migrate_winners(raw, recorded)
   local matched = recorded == probe_spellset_key()
   local kept = {}
   if matched then
      for name, spell in pairs(raw or {}) do
         if is_probe_spell(spell) then kept[name] = spell end
      end
   end
   return kept, matched
end



if not _AUTOFIGHT.winners then
   local raw = {}
   local recorded = nil
   local t = persist.load(WINNERS_FILE)
   if type(t) == "table" then
      local w = t.winners
      if type(w) == "table" then raw = w else raw = t end
      recorded = t.spells
   end
   local kept, matched = migrate_winners(raw, recorded)
   _AUTOFIGHT.winners = kept
   if not matched then
      local n = 0
      for _ in pairs(raw) do n = n + 1 end
      if n > 0 then
         if echo then
            echo("\27[1;35m[autofight]\27[0m spell set changed → cleared all learned winners, re-probing every target.")
         end
         if after then after(0, save_winners) end
      end
   end
   _AUTOFIGHT.winners_spellset = probe_spellset_key()
end





do
   local key = probe_spellset_key()
   if _AUTOFIGHT.winners_spellset and _AUTOFIGHT.winners_spellset ~= key then
      local n = 0
      for _ in pairs(_AUTOFIGHT.winners) do n = n + 1 end
      _AUTOFIGHT.winners = {}
      if n > 0 then
         if echo then
            echo("\27[1;35m[autofight]\27[0m spell set changed → cleared all learned winners, re-probing every target.")
         end
         if after then after(0, save_winners) end
      end
   end
   _AUTOFIGHT.winners_spellset = key
end


local function remember_winner(name, spell)
   local key = winner_key(name)
   if not key or not is_probe_spell(spell) then return end
   if _AUTOFIGHT.winners[key] ~= spell then
      _AUTOFIGHT.winners[key] = spell
      schedule_winners_save()
      say(string.format("learned: %s → %s", key, spell))
   end
end








local UNSTEALABLE_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/autofight_unstealable.lua"
local function save_unstealable()
   local parts = {}
   for name in pairs(_AUTOFIGHT.unstealable) do parts[#parts + 1] = string.format("[%q]=true", name) end
   persist.write(UNSTEALABLE_FILE, "return {" .. table.concat(parts, ",") .. "}")
end

local unstealable_save_timer
local function schedule_unstealable_save()
   if cancel and unstealable_save_timer then cancel(unstealable_save_timer) end
   unstealable_save_timer = after and after(2, save_unstealable) or nil
end

if not _AUTOFIGHT.unstealable then
   _AUTOFIGHT.unstealable = {}
   local t = persist.load(UNSTEALABLE_FILE)
   if type(t) == "table" then for name, v in pairs(t) do if v then _AUTOFIGHT.unstealable[name] = true end end end
end


local function is_unstealable(name)
   local key = winner_key(name)
   return (key and _AUTOFIGHT.unstealable[key]) or false
end


local function remember_unstealable(name)
   local key = winner_key(name)
   if not key then return end
   if not _AUTOFIGHT.unstealable[key] then
      _AUTOFIGHT.unstealable[key] = true
      schedule_unstealable_save()
      say(string.format("learned: %s has no soul — won't try to soulsteal it again", key))
   end
end






local NIL = {}
local FIGHT_RESET = {
   busy = false,
   busy_spell = NIL,
   lightning_drop = 0,
   icebolt_drop = 0,
   fireball_drop = 0,
   prism_drop = 0,
   fallback_tried = false,
   last_damage_spell = NIL,
   soul_latched = false,
   finish_ready = false,
   renuke_pending = false,
   probe_ptr = NIL,
   suspended = false,
   no_mana = function() return {} end,
   self_sent = function() return {} end,
}
local function reset_fight_state()
   local Fd = F
   for k, v in pairs(FIGHT_RESET) do
      if v == NIL then Fd[k] = nil
      elseif type(v) == "function" then Fd[k] = (v)()
      else Fd[k] = v end
   end
   if not F.known_winner then F.winner, F.winner_spell = nil, nil end
end



local function af_send(cmd)
   F.self_sent[cmd] = (F.self_sent[cmd] or 0) + 1
   sent[#sent + 1] = cmd
   if send then send(cmd) end
end










local function opener_cmd()
   local hp = state.hp
   local mhp = state.maxhp
   if hp and mhp and mhp > 0 and (hp / mhp) > cfg.bloodmist_hp_min then return cfg.bloodmist_cmd, "bloodmist" end
   return cfg.opener_tarrants, "tarrants"
end
local function send_opener() F.engage_busy = true; af_send((opener_cmd())) end


local engage_giveup
local function engage_retry(reason)
   F.engage_busy = false
   F.engage_tries = F.engage_tries + 1
   if F.engage_tries >= cfg.max_tries then engage_giveup(reason) else send_opener() end
end

engage_giveup = function(reason)
   F.engaging, F.engage_busy, F.opener_primed = false, false, false
   local cb = F.on_fail; F.on_fail, F.on_dead = nil, nil
   say("couldn't start the fight (" .. reason .. ")")
   if cb then cb(reason) end
end




local function engage_target_missing()
   if F.engaging and not F.fighting then engage_giveup("target not here") end
end




local function aoe_active()
   if F.aoe_mode == "on" then return true end
   if F.aoe_mode == "off" then return false end
   return F.pack
end





local function aoe_cast()
   if F.winner_spell == "fireball" then return cfg.fireball_cmd, "fireball" end
   return cfg.aoe_cmd, "frostflower"
end





























local rx = __rx










































local function safe_subject()
   if not rx then return nil end
   local s = rx.subject()
   s.onNext = function(self, ...)
      if self.closed then return end
      local snap = {}
      for o in pairs(self.observers) do snap[#snap + 1] = o end
      for _, o in ipairs(snap) do if self.observers[o] then o.onNext(...) end end
   end
   return s
end



local landedS = safe_subject()
local openerS = safe_subject()
local failedS = safe_subject()
local resistS = safe_subject()
local manaS = safe_subject()
local soulPullS = safe_subject()
local soulLatchS = safe_subject()
local deadS = safe_subject()
local resumeS = safe_subject()
local combatStartS = safe_subject()






local barS = safe_subject()














local function P(executor)
   local p = __promise(executor, "autofight-flow")
   if __untrack_promise then __untrack_promise(p) end
   p.__start()
   return p
end
local function resolved(v) return P(function(res) res(v) end) end
local function never_p() return P(function() end) end



local opener
local probe
local fightLoop
local afterOpener
local runCombatObs
local route_landed
local note_mdeath


if rx then
   combatStartS:
   switchMap(function() return runCombatObs():takeUntil(deadS) end):
   subscribe(function() end)


   onSpellLanded:subscribe(function(s) route_landed(s) end)
   onEnemyDied:subscribe(function(name) note_mdeath(name) end)
end









local function castStep(cmd, wantSpell, landStream)
   landStream = landStream or landedS
   return P(function(resolve, _, onCancel)
      local tries, cancelled = 0, false
      local sub_ = nil
      local rsub_ = nil
      local function cleanup()
         if sub_ then sub_:unsubscribe(); sub_ = nil end
         if rsub_ then rsub_:unsubscribe(); rsub_ = nil end
      end
      local function fin(v) cleanup(); resolve(v) end
      local function begin()



         sub_ = (rx).merge(
         landStream:filter(function(s) return wantSpell == nil or s == wantSpell end):map(function() return "landed" end),
         failedS:map(function() return "fail" end),
         resistS:map(function() return "fail" end),
         manaS:map(function() return "mana" end)):
         takeUntil(deadS):subscribe(function(ev)
            if ev == "landed" then fin("landed")
            elseif ev == "mana" then fin("mana")
            else
               tries = tries + 1
               if tries >= cfg.max_tries then fin("gaveup") else af_send(cmd) end
            end
         end)
         af_send(cmd)
      end
      onCancel(function() cancelled = true; cleanup() end)
      if F.suspended then
         rsub_ = resumeS:takeUntil(deadS):subscribe(function()
            if cancelled then return end
            if rsub_ then rsub_:unsubscribe(); rsub_ = nil end
            begin()
         end)
      else
         begin()
      end
   end)
end







local function soulstealStep()
   return P(function(resolve, _, onCancel)
      local sub_ = nil
      local rsub_ = nil
      local cancelled = false
      local function cleanup()
         if sub_ then sub_:unsubscribe(); sub_ = nil end
         if rsub_ then rsub_:unsubscribe(); rsub_ = nil end
      end
      local function fin(v) cleanup(); resolve(v) end
      local function begin()
         sub_ = (rx).merge(
         soulPullS:map(function() return "pulled" end),
         soulLatchS:map(function() return "latched" end),
         resistS:map(function() return "resisted" end),
         failedS:map(function() return "fizzled" end),
         manaS:map(function() return "mana" end)):
         takeUntil(deadS):subscribe(function(ev) fin(ev) end)
         af_send(cfg.soulsteal_cmd)
      end
      onCancel(function() cancelled = true; cleanup() end)
      if F.suspended then
         rsub_ = resumeS:takeUntil(deadS):subscribe(function()
            if cancelled then return end
            if rsub_ then rsub_:unsubscribe(); rsub_ = nil end
            begin()
         end)
      else
         begin()
      end
   end)
end



local function nextBar()
   return P(function(resolve)
      local sub = nil
      sub = barS:takeUntil(deadS):subscribe(function()
         if sub then sub:unsubscribe(); sub = nil end
         resolve(nil)
      end)
   end)
end



opener = function()
   F.phase = "opener"
   if F.opener_primed or aoe_active() then return resolved(nil) end
   local cmd = (opener_cmd())
   return castStep(cmd, nil, openerS)
end







local PROBE_NEXT = { lightning = "fireball", fireball = "decide", icebolt = "prism", prism = "decide" }
probe = function()
   F.phase = "probe"
   F.probe_ptr = "lightning"
   local step
   step = function()



      if F.known_winner then return resolved(F.known_winner) end
      if aoe_active() then
         local acmd, atag = aoe_cast()
         F.last_damage_spell = (atag == "fireball") and "fireball" or "aoe"; F.phase = "aoe"
         return castStep(acmd, atag, nil):andThen(function(o)
            if o == "mana" then return never_p() end
            F.phase = "probe"
            return step()
         end)
      end
      local ptr = F.probe_ptr
      if ptr == "decide" then


         if not F.fallback_tried and math.max(F.lightning_drop, F.fireball_drop) < cfg.probe_enough then
            F.fallback_tried, F.probe_ptr = true, "icebolt"
            return step()
         end



         local ld, sd, id, pd = F.lightning_drop, F.fireball_drop, F.icebolt_drop, F.prism_drop or 0
         local winner, best = "fireball", sd + cfg.fireball_bias
         if ld > best then winner, best = "lightning", ld end
         if id > best then winner, best = "icebolt", id end
         if pd > best then winner, best = "prism", pd end
         remember_winner(F.name, winner)
         return resolved(winner)
      end
      F.last_damage_spell = ptr
      return castStep((cfg)[ptr .. "_cmd"], ptr, nil):andThen(function(o)
         if o == "mana" then return never_p() end
         F.probe_ptr = PROBE_NEXT[ptr] or "decide"
         return step()
      end)
   end
   return step()
end





fightLoop = function(winner)
   if winner then F.winner_spell, F.winner = winner, (cfg)[winner .. "_cmd"] end
   local step
   step = function()
      if aoe_active() then
         local acmd, atag = aoe_cast()
         F.last_damage_spell = (atag == "fireball") and "fireball" or "aoe"; F.phase = "aoe"
         return castStep(acmd, atag, nil):andThen(function(o)
            if o == "mana" then return never_p() end
            return step()
         end)
      end



      if winner and (F.finish_ready or (F.pct and F.pct > 0 and F.pct <= cfg.soulsteal_pct)) and
         not F.soul_latched and not F.renuke_pending and not F.known_unstealable then
         F.phase = "soulsteal"
         return soulstealStep():andThen(function(r)
            if r == "pulled" then return resolved(nil) end
            if r == "latched" then F.soul_latched = true; return step() end
            if r == "resisted" then F.renuke_pending = true; return step() end
            if r == "fizzled" then return step() end


            if r == "mana" then return never_p() end
            return step()
         end)
      end
      F.renuke_pending = false



      local w = F.winner_spell or winner or "lightning"
      F.last_damage_spell = w; F.phase = "nuke"
      return castStep((cfg)[w .. "_cmd"], w, nil):andThen(function(o)
         if o == "mana" then return never_p() end
         return nextBar():andThen(step)
      end)
   end
   return step()
end



afterOpener = function()
   if aoe_active() then return fightLoop(nil) end
   if F.known_winner then return fightLoop(F.known_winner) end
   return probe():andThen(function(winner) return fightLoop(winner) end)
end



local function runCombat()
   return opener():
   andThen(afterOpener):
   catch(function(why) if why ~= nil then say("fight aborted: " .. tostring(why)) end end)
end


runCombatObs = function()
   return (rx).Observable.create(function()
      local tail = runCombat()
      return function() if tail and tail.cancel then tail.cancel() end end
   end)
end







local function begin_fight_promise(name)
   local desc = "autofight: " .. (name or "?")
   if F.fight_settle then
      if __track_promise and F.fight_promise then (__track_promise)(F.fight_promise, desc) end
      return
   end
   if not __promise then return end
   local p = __promise(function(resolve, reject, onCancel)
      F.fight_settle = { resolve = resolve, reject = reject }
      onCancel(function() F.fight_settle = nil end)
   end, desc)
   local fp = p
   if p and fp.__start then fp.__start() end
   F.fight_promise = p
end
local function settle_fight_promise()
   local s = F.fight_settle; F.fight_settle, F.fight_promise = nil, nil
   if s then s.resolve() end
end

local function start_fight(pct, name)
   F.fighting, F.pct, F.name = true, pct, name
   F.fought = true
   begin_fight_promise(name)

   local key = winner_key(name)
   local known = key and _AUTOFIGHT.winners[key]
   F.known_winner = is_probe_spell(known) and known or nil
   if F.known_winner then
      F.winner, F.winner_spell = (cfg)[F.known_winner .. "_cmd"], F.known_winner
      say(string.format("%s known → %s (skipping probe)", key, F.known_winner))
   end


   F.known_unstealable = is_unstealable(name)
   if F.known_unstealable then say(string.format("%s has no soul → skipping soulsteal, nuking it down", key)) end
   reset_fight_state()
   F.engaging, F.engage_busy = false, false
   if F.suspend_timer and cancel then cancel(F.suspend_timer); F.suspend_timer = nil end
   clear_sent()



   if deadS then deadS:onNext() end
   if combatStartS then combatStartS:onNext(true) end
   F.opener_primed = false
end

local function end_fight()
   if deadS then deadS:onNext() end
   F.fighting, F.phase = false, "idle"
   F.suspended = false
   if F.suspend_timer and cancel then cancel(F.suspend_timer); F.suspend_timer = nil end
end












local function enter_pack_mode() F.pack = true end
local function exit_pack_mode() F.pack = false end


local function reeval_pack()
   if (F.enemy_est or 0) >= cfg.aoe_min then enter_pack_mode() else exit_pack_mode() end
end






local function note_room_fighter(subject)
   if not F.on or not F.fighting then return end
   if is_ally and is_ally(subject) then return end
   if not F.room_burst_timer then F.room_seen = 0 end
   F.room_seen = F.room_seen + 1
   F.enemy_est = F.room_seen
   reeval_pack()
   if F.room_burst_timer and cancel then cancel(F.room_burst_timer) end
   F.room_burst_timer = after and after(cfg.room_burst, function() F.room_burst_timer = nil end) or nil
end




note_mdeath = function(name)
   if is_ally and is_ally(name) then return end
   if (F.enemy_est or 0) > 0 then F.enemy_est = F.enemy_est - 1 end
   reeval_pack()
end





local last_prompt = 0





local function on_fight(pct, name)
   if not F.on then return end
   local was, prev, prevname = F.fighting, F.pct, F.name
   F.pct, F.name = pct, name
   if barS then barS:onNext() end
   if not was then start_fight(pct, name); return end








   if name ~= prevname or (prev and pct >= prev + cfg.new_target_jump) then




      start_fight(pct, name); return
   end
   if prev and pct < prev then
      local d = prev - pct
      if F.last_damage_spell == "lightning" then F.lightning_drop = F.lightning_drop + d
      elseif F.last_damage_spell == "icebolt" then F.icebolt_drop = F.icebolt_drop + d
      elseif F.last_damage_spell == "fireball" then F.fireball_drop = F.fireball_drop + d
      elseif F.last_damage_spell == "prism" then F.prism_drop = F.prism_drop + d end
   end



end

local function on_fight_end()




   local was_engaged_fight = F.fought and F.on_dead
   F.pack, F.enemy_est = false, 0
   if deadS then deadS:onNext() end
   if F.fighting then end_fight() end
   F.fought = false
   settle_fight_promise()

   if was_engaged_fight then
      local cb = F.on_dead; F.on_dead, F.on_fail = nil, nil
      if cb then cb() end
   end
end





local PROMPT_FRESH = 10
function __autofight_prompt(pct, name)
   last_prompt = os.time()
   if pct and name and name ~= "" then on_fight(pct, name)
   else on_fight_end() end
end



local function on_kxwt_fight(pct, name)
   if os.time() - last_prompt < PROMPT_FRESH then return end
   on_fight(pct, name)
end
local function on_kxwt_end()
   if os.time() - last_prompt < PROMPT_FRESH then return end
   on_fight_end()
end






local function hit_lightning() if landedS then landedS:onNext("lightning") end end
local function hit_icebolt() if landedS then landedS:onNext("icebolt") end end
local function hit_fireball() if landedS then landedS:onNext("fireball") end end
local function hit_prism() if landedS then landedS:onNext("prism") end end
local function hit_frostflower() if landedS then landedS:onNext("frostflower") end end


local function hit_shower() if landedS then landedS:onNext("shower") end end


local function opener_landed(spell)
   if F.engaging and not F.fighting then F.engage_busy = false; return end
   if openerS then openerS:onNext(spell) end
end



route_landed = function(spell)
   if spell == "tarrants" or spell == "bloodmist" then opener_landed(spell)
   elseif landedS then landedS:onNext(spell) end
end
local function hit_tarrants() opener_landed("tarrants") end
local function hit_bloodmist() opener_landed("bloodmist") end
local function hit_resist()


   if F.engaging and not F.fighting then return engage_retry("resisted") end


   if resistS then resistS:onNext() end
end
local function hit_mana()

   if F.engaging and not F.fighting then return engage_giveup("out of mana") end
   if manaS then manaS:onNext() end
end
local function hit_fail()
   if F.engaging and not F.fighting then return engage_retry("cast failed") end
   if failedS then failedS:onNext() end
end

local function hit_soulsteal_ok()



   if soulPullS then soulPullS:onNext() end
end

local function hit_soul_latched()



   if soulLatchS then soulLatchS:onNext() end
end

local function hit_soul_nolatch()





   say("target has no individual soul to steal — nuking it down instead")
   remember_unstealable(F.name)
   F.known_unstealable = true
   if soulLatchS then soulLatchS:onNext() end
end

local function hit_soul_unstealable()





   say("target can't be soul-stolen (not living) — nuking it down instead")
   remember_unstealable(F.name)
   F.known_unstealable = true
   if soulLatchS then soulLatchS:onNext() end
end

local function hit_dead()
   if deadS then deadS:onNext() end
   end_fight()
end




local function same_name(a, b)
   if not a or not b then return false end
   local x = (a:gsub("^%s+", ""):gsub("%s+$", "")):lower()
   local y = (b:gsub("^%s+", ""):gsub("%s+$", "")):lower()
   return x == y
end




local function note_near_death(name)
   if F.fighting and F.name and name and same_name(name, F.name) then F.finish_ready = true end
end







local function is_dead_line_our_target(name)
   if not name then return false end
   if F.fighting and F.name and same_name(name, F.name) then return true end
   if active_opponents then
      for _, o in ipairs(active_opponents(os.time())) do
         if same_name(o.name, name) then return true end
      end
   end
   return false
end




local function observe_input(cmd)
   cmd = (cmd or ""):gsub("^%s+", ""):gsub("%s+$", "")
   if cmd == "" or cmd:sub(1, 1) == "#" then return end
   if (F.self_sent[cmd] or 0) > 0 then F.self_sent[cmd] = F.self_sent[cmd] - 1; return end
   if not F.on or not F.fighting then return end
   F.suspended = true
   if F.suspend_timer and cancel then cancel(F.suspend_timer) end
   F.suspend_timer = after and after(cfg.resume_after, function()
      F.suspend_timer = nil; F.suspended = false
      if resumeS then resumeS:onNext() end
   end) or nil
end
















local TANK = { on = true, name = nil, resummoning = false, tries = 0, timer = nil, death_at = nil }








local function current_tank_name()
   for name, f in pairs((state.group_flags) or {}) do
      if f:find("M", 1, true) and f:find("T", 1, true) then return name end
   end
   return nil
end

local function stop_resummon()
   TANK.resummoning, TANK.tries = false, 0
   if TANK.timer and cancel then cancel(TANK.timer); TANK.timer = nil end
end



local resummon_tick
resummon_tick = function()
   TANK.timer = nil
   if not TANK.resummoning then return end
   if TANK.tries >= cfg.clay_max_tries then
      say(string.format("gave up re-summoning a tank after %d tries (need clay/dirt nearby?)", TANK.tries))
      stop_resummon(); return
   end
   TANK.tries = TANK.tries + 1
   say(string.format("tank down — re-summoning clay man (try %d/%d)", TANK.tries, cfg.clay_max_tries))
   af_send(cfg.clay_cmd)
   TANK.timer = after and after(cfg.clay_retry, resummon_tick) or nil
end

local function tank_died()
   if not TANK.on then return end
   say("tank died — disabling corpse automation and re-summoning a clay man")


   local g = _G
   if g.autoHarvest then
      local ah = g.autoHarvest
      if ah.off then (ah.off)() end
   end
   if TANK.resummoning then return end
   TANK.resummoning, TANK.tries = true, 0
   resummon_tick()
end


local function tank_resummoned()
   if not TANK.resummoning then return end
   say("new tank up")
   stop_resummon()
end



local function minion_in_group(name)
   if not name then return false end
   local low = name:lower()
   for n in pairs((state.group_flags) or {}) do
      if n:lower() == low then return true end
   end
   return false
end





local TANK_DEATH_WINDOW = 6
local function tank_ydeath() TANK.death_at = os.time() end








local function refresh_tank()
   local t = current_tank_name()
   if t then TANK.name = t; return end
   if TANK.name and not minion_in_group(TANK.name) then
      local recent = TANK.death_at and (os.time() - TANK.death_at) <= TANK_DEATH_WINDOW
      TANK.death_at = nil
      TANK.name = nil
      if recent then tank_died() end
   end
end

















local rx = __rx
if rx then
   local T = rx.fromTrigger











   T([[^Your fireball backfires]]):subscribe(function(_) hit_fail() end)



   local soulPulled = T([[^You cast the spell to separate soul from body]])
   local soulLatched = T([[^You magically latch onto .+ soul and wait for .+ to weaken]])
   soulPulled:subscribe(function(_) hit_soulsteal_ok() end)
   soulLatched:subscribe(function(_) hit_soul_latched() end)


   local soulNoLatch = T([[^Your spell fails to latch on to an individual soul!$]])
   soulNoLatch:subscribe(function(_) hit_soul_nolatch() end)



   local soulNotLiving = T([[^You can only soulsteal from living things\.$]])
   soulNotLiving:subscribe(function(_) hit_soul_unstealable() end)



   local castFailed = T([[^You fail to cast the spell]])
   local castResisted = T([[^.+ resists the spell\.$]])
   local outOfMana = T([[^You don't have enough mana\.$]])
   castFailed:subscribe(function(_) hit_fail() end)
   castResisted:subscribe(function(_) hit_resist() end)
   outOfMana:subscribe(function(_) hit_mana() end)




   local combatBar = T([[^kxw[tq]_fighting (\d+) \S+ (.+)$]])
   local combatEnd = T([[^kxw[tq]_fighting -1$]])
   local enemyDead = T([[^(.+) is DEAD!$]])
   combatBar:subscribe(function(c) on_kxwt_fight(tonumber(c[1]), c[2]) end)
   combatEnd:subscribe(function(_) on_kxwt_end() end)




   enemyDead:subscribe(function(c) if is_dead_line_our_target(c[1]) then hit_dead() end end)



   trigger([[^(.+) is near death!$]], function(n) note_near_death(n) end)
   trigger([[^(.+) is mortally wounded, and will die soon]], function(n) note_near_death(n) end)



   T([[^Target who\?]]):subscribe(function(_) engage_target_missing() end)






   local roomFighter = T([[^(.+) is here, fighting .+$]])
   roomFighter:subscribe(function(c) note_room_fighter(c[1]) end)





   T([[^kxw[tq]_ydeath ]]):subscribe(function(_) tank_ydeath() end)
   T([[^kxw[tq]_group_end$]]):subscribe(function(_) refresh_tank() end)
   T([[^You add .*clay man to your group\.$]]):subscribe(function(_) tank_resummoned() end)
   T([[^You already have .*clay man at your side\.$]]):subscribe(function(_) tank_resummoned() end)



end




local userInput = rx and safe_subject() or nil
if userInput then userInput:subscribe(function(cmd) observe_input(cmd) end) end
local _prev_on_user_input = on_user_input
function on_user_input(cmd)
   if userInput then userInput:onNext(cmd) end
   if _prev_on_user_input then return _prev_on_user_input(cmd) end
end


local function status_line()
   local bits = string.format("%s · phase=%s", F.on and "ON" or "OFF", F.phase)
   if F.fighting then bits = bits .. string.format(" · %s %s%%", F.name or "?", tostring(F.pct or "?")) end
   if F.winner then bits = bits .. " · winner=" .. F.winner end
   bits = bits .. " · aoe=" .. F.aoe_mode .. (aoe_active() and "*" or "")
   if F.suspended then bits = bits .. " · SUSPENDED (manual)" end
   return "[autofight] " .. bits
end
















autofight = {}



function autofight.tank(mode)
   mode = (mode or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
   if mode == "on" then TANK.on = true; say("tank rescue on")
   elseif mode == "off" then TANK.on = false; stop_resummon(); say("tank rescue off")
   else
      say("tank rescue " .. (TANK.on and "on" or "off") ..
      (TANK.name and (" — tank: " .. TANK.name) or " — no tank seen") ..
      (TANK.resummoning and (" (re-summoning, try " .. TANK.tries .. ")") or ""))
   end
end
doc(autofight.tank, { name = "autofight.tank", sig = "autofight.tank(['on'|'off'|'status'])", group = "combat",
text = "When your TANK — a minion of yours that's tanking (kxwt group flags M+T), e.g. a summoned clay " ..
"man or flesh beast — dies, turn OFF corpse automation and re-cast 'clay man' on a pace until one " ..
"rejoins the group, restoring your front line. On by default; runs whether or not auto-fight is armed.", })

function autofight.on()
   F.on = true
   say("armed — tarrants → lightning/fireball probe → nuke winner → soulsteal")

   if F.fighting and combatStartS then combatStartS:onNext(true) end
end

function autofight.off()
   F.on = false
   end_fight()
   F.fought = false
   say("disarmed")
end

function autofight.status() if echo then echo(status_line()) end end





function autofight.current() return F.fight_promise end
doc(autofight.current, { name = "autofight.current", sig = "autofight.current() -> promise|nil", group = "combat",
text = "The current fight as a promise (nil when not fighting), resolving when combat ends. Chain off " ..
"it — autofight.current().andThen(...) — to act once the fight is over. Also shown as an " ..
"'autofight: <enemy>' row in the HUD promise widget.", })



function autofight.aoe(mode)
   mode = (mode or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
   if mode == "" then
      say(string.format("AOE mode: %s%s", F.aoe_mode, aoe_active() and " (active now)" or ""))
   elseif mode == "on" or mode == "off" or mode == "auto" then
      F.aoe_mode = mode
      say("AOE mode → " .. mode .. (mode == "auto" and " (frostflower once a pack is detected)" or ""))
   else
      say("usage: autofight aoe on|off|auto")
   end
end
doc(autofight.aoe, { name = "autofight.aoe", sig = "autofight.aoe(['on'|'off'|'auto'])", group = "combat",
text = "Control room-AOE. In a pack the routine casts frostflower on repeat instead of the " ..
"single-target probe/nuke. 'auto' (default) switches to AOE once a kill rolls straight onto " ..
"another enemy (no combat break); 'on' always AOEs; 'off' never does. No arg reports the mode.", })



function autofight.winners()
   if not echo then return end
   local keys = {}
   for k in pairs(_AUTOFIGHT.winners) do keys[#keys + 1] = k end
   table.sort(keys)
   if #keys == 0 then echo("[autofight] no learned winners yet"); return end
   echo(string.format("[autofight] learned winners (%d):", #keys))
   for _, k in ipairs(keys) do echo(string.format("  %s → %s", k, _AUTOFIGHT.winners[k])) end
end

function autofight.forget(name)
   if name == nil then
      _AUTOFIGHT.winners = {}; schedule_winners_save(); say("forgot ALL learned winners"); return
   end
   local key = winner_key(name)
   if key and _AUTOFIGHT.winners[key] then
      _AUTOFIGHT.winners[key] = nil; schedule_winners_save(); say("forgot " .. key)
   else
      say("nothing learned for " .. (key or tostring(name)))
   end
end

doc(autofight.winners, { name = "autofight.winners", sig = "autofight.winners()", group = "combat",
text = "List the learned best-spell-per-target memory: for each target name the script has probed, " ..
"which of icebolt/fireball/prism won. Known names skip the probe on the next fight.", })
doc(autofight.forget, { name = "autofight.forget", sig = "autofight.forget([name])", group = "combat",
text = "Forget a learned winner so it re-probes next time: pass a target name to drop just that one, " ..
"or call with no argument to clear the whole memory. Persists the change.", })




function autofight.unstealable(name)
   if name == nil then
      if not echo then return end
      local keys = {}
      for k in pairs(_AUTOFIGHT.unstealable) do keys[#keys + 1] = k end
      table.sort(keys)
      if #keys == 0 then echo("[autofight] no known soulless targets yet"); return end
      echo(string.format("[autofight] soulless targets (%d) — soulsteal is skipped for these:", #keys))
      for _, k in ipairs(keys) do echo("  " .. k) end
      return
   end
   local arg = tostring(name):lower():gsub("^%s+", ""):gsub("%s+$", "")
   if arg == "all" or arg == "clear" then
      _AUTOFIGHT.unstealable = {}; schedule_unstealable_save(); say("forgot ALL soulless targets"); return
   end
   local key = winner_key(name)
   if key and _AUTOFIGHT.unstealable[key] then
      _AUTOFIGHT.unstealable[key] = nil; schedule_unstealable_save()
      say("forgot soulless '" .. key .. "' — will try soulsteal again")
   else
      say("'" .. (key or arg) .. "' isn't marked soulless")
   end
end
doc(autofight.unstealable, { name = "autofight.unstealable", sig = "autofight.unstealable([name])",
group = "combat", text = "The persisted 'no soul — never soulsteal' memory: targets the game rejected " ..
"with \"You can only soulsteal from living things\" (undead, constructs, dead bodies). The routine " ..
"skips the soulsteal stage for these and just nukes them down. No arg lists them; a target name " ..
"forgets that one (it'll try soulsteal again); 'all' clears the whole memory. Persists.", })






function autofight.winner(name, spell)
   local key = name and winner_key(name)
   if not key or key == "" then
      say("usage: autofight.winner('<enemy name>', '" .. table.concat(PROBE_SPELLS, "'|'") .. "')  — force which spell to nuke it with")
      return
   end
   local s = (spell or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
   if s == "" then
      local cur = _AUTOFIGHT.winners[key]
      say(cur and (key .. " → " .. cur) or ("no learned winner for '" .. key .. "'"))
      return
   end
   if s == "none" or s == "clear" or s == "forget" then
      _AUTOFIGHT.winners[key] = nil; schedule_winners_save(); say("forgot '" .. key .. "' — will re-probe")
      return
   end
   if not is_probe_spell(s) then
      say("winner must be one of " .. table.concat(PROBE_SPELLS, "/") .. " (the spells the routine nukes with) — got '" .. s .. "'")
      return
   end
   remember_winner(name, s)


   if F.fighting and F.name and winner_key(F.name) == key then


      F.known_winner, F.winner, F.winner_spell = s, (cfg)[s .. "_cmd"], s
      say("overriding the CURRENT fight → " .. s)
   end
   say("'" .. key .. "' → " .. s .. " (set, persisted)")
end
doc(autofight.winner, { name = "autofight.winner", sig = "autofight.winner(name[, 'icebolt'|'fireball'])",
group = "combat", text = "Manually override the learned attack spell for a target NAME — for when the " ..
"probe mislearned and picked the element the enemy RESISTS or is HEALED by. 'icebolt' (cold) or " ..
"'fireball' (fire); no spell reports the current winner; 'none' forgets it. Persists, skips the " ..
"probe for that name, and switches the current fight immediately if you're fighting it.", })






function autofight.engage(target, on_dead, on_fail)
   F.on = true
   end_fight()
   F.fought = false
   F.on_dead, F.on_fail = on_dead, on_fail
   F.engaging, F.engage_busy, F.engage_tries = true, false, 0




   state.assisted = true
   F.opener_primed = true
   say(string.format("engaging %s — casting the opener to start the fight", tostring(target)))
   af_send("target " .. tostring(target))
   send_opener()
end
doc(autofight.engage, { name = "autofight.engage", sig = "autofight.engage(target[, on_dead][, on_fail])",
group = "combat", text = "Start a fight from out of combat: set the target and cast the opener " ..
"(tarrants) to aggro it, retrying until it lands, then hand off to the normal auto-fight " ..
"routine. on_dead() fires when the fight ends; on_fail(reason) if the opener can't be landed. " ..
"attack() wraps this into a chainable promise.", })



function attack(target)
   return __promise(function(resolve, reject, onCancel)
      autofight.engage(target, function() resolve(nil) end, function(reason) reject(reason) end)
      onCancel(function() autofight.off() end)
   end, "attack")
end
doc("attack", { sig = "attack(target) -> promise", group = "combat",
text = "Engage `target` (via autofight.engage) and return a promise that resolves when it dies and " ..
"rejects if the fight can't be started. Chain with .andThen — e.g. recover(95).andThen(attack('orc')).",
example = "#attack('orc')", })

doc(autofight.on, { name = "autofight.on", sig = "autofight.on()", group = "combat",
text = "Arm the deterministic auto-fight routine: on combat start it casts tarrants (once), probes " ..
"icebolt vs fireball and keeps the harder-hitting one, then soulsteals when the enemy is nearly " ..
"dead (re-nuking on a resist). Paced (one cast per resolution) and OFF by default; any command " ..
"YOU type suspends it briefly so you can intervene.", })
doc(autofight.off, { name = "autofight.off", sig = "autofight.off()", group = "combat",
text = "Disarm the auto-fight routine and end any in-progress fight tracking.", })
doc(autofight.status, { name = "autofight.status", sig = "autofight.status()", group = "combat",
text = "Show whether auto-fight is armed, the current phase, the target/health%, and the chosen " ..
"winner spell.", })


setmetatable(autofight, { __call = function(_, rest)
   rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
   local verb, arg = rest:match("^(%S*)%s*(.*)$")
   verb = (verb or ""):lower()
   if verb == "on" then autofight.on()
   elseif verb == "off" then autofight.off()
   elseif verb == "aoe" then autofight.aoe(arg)
   elseif verb == "winners" then autofight.winners()
   elseif verb == "forget" then autofight.forget(arg ~= "" and arg or nil)
   elseif verb == "winner" then


      local last = arg:match("(%S+)%s*$")
      local lw = last and last:lower()
      if is_probe_spell(lw) or lw == "none" or lw == "clear" or lw == "forget" then
         autofight.winner(arg:match("^(.-)%s+%S+%s*$"), last)
      else
         autofight.winner(arg ~= "" and arg or nil)
      end
   else autofight.status() end
end, })




if alias then
   alias([[^autofight$]], function() autofight() end)
   alias([[^autofight (.+)$]], function(_, rest) autofight(rest) end)
end






_AF_TEST = {
   cfg = cfg,
   sent = sent,
   state = function() return F end,
   on_fight = on_fight,
   on_fight_end = on_fight_end,
   on_input = observe_input,
   lightning = hit_lightning, icebolt = hit_icebolt, fireball = hit_fireball,
   tarrants = hit_tarrants,
   prism = hit_prism, bloodmist = hit_bloodmist, opener_cmd = opener_cmd,
   is_probe_spell = is_probe_spell, probe_spells = PROBE_SPELLS, save_winners = save_winners,
   spellset_key = probe_spellset_key, migrate_winners = migrate_winners,
   frostflower = hit_frostflower, aoe_active = aoe_active, room_fighter = note_room_fighter,
   mdeath = note_mdeath,
   tank = function() return TANK end,
   tank_scan = current_tank_name,
   tank_refresh = refresh_tank,
   tank_ydeath = tank_ydeath,
   tank_resummoned = tank_resummoned,
   shower = hit_shower,
   resist = hit_resist, mana = hit_mana, fail = hit_fail,
   target_missing = engage_target_missing,
   soulsteal_ok = hit_soulsteal_ok, soul_latched = hit_soul_latched, dead = hit_dead,
   soul_nolatch = hit_soul_nolatch, soul_unstealable = hit_soul_unstealable,


   dead_line = function(name) if is_dead_line_our_target(name) then hit_dead() end end,
   is_our_target_death = is_dead_line_our_target,
   near_death = function(name) note_near_death(name) end,
   winner_key = winner_key,
   winners = function() return _AUTOFIGHT.winners end,
   remember = remember_winner,
   unstealable = function() return _AUTOFIGHT.unstealable end,
   is_unstealable = is_unstealable,
   expire_resume = function()
      if F.suspend_timer and cancel then cancel(F.suspend_timer) end
      F.suspend_timer, F.suspended = nil, false
      if resumeS then resumeS:onNext() end
   end,
   begin_promise = begin_fight_promise,
   settle_promise = settle_fight_promise,
   fight_promise = function() return F.fight_promise end,
   prompt_bridge = function(pct, name) return __autofight_prompt(pct, name) end,
   mark_prompt = function(t) last_prompt = t end,
   kxwt_fight = on_kxwt_fight,
   kxwt_end = on_kxwt_end,
   reset = function()
      F.on = true
      end_fight()
      settle_fight_promise()
      F.self_sent = {}
      F.aoe_mode, F.pack, F.room_seen, F.enemy_est = "auto", false, 0, 0
      F.room_burst_timer = nil
      clear_sent()
      _AUTOFIGHT.winners = {}
      _AUTOFIGHT.unstealable = {}
   end,
}

if echo then echo(status_line()) end
