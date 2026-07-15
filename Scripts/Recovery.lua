






state = state or {}
_AA_TEST = _AA_TEST or {}





local function boot(n) pcall(require, n) end
boot("_rx")
if not __rx then dofile("Scripts/_rx.lua") end
boot("_persist")
if not __persist then dofile("Scripts/_persist.lua") end



boot("Promise")
local persist = __persist




local function N(v) return v end
local function S(v) return v end
local function B(v) return v end

local function pct(cur, max)
   local c, m = N(cur), N(max)
   if not c or not m or m == 0 then return 0 end
   return c / m
end


local READY_PCT = 0.90



local SPELLUP_WAIT = 12



local function ready(p)
   p = p or READY_PCT
   return pct(state.hp, state.maxhp) >= p and pct(state.mana, state.maxmana) >= p and
   pct(state.stam, state.maxstam) >= p
end





local RECOVERY_DEPTH = { standing = 0, kneeling = 0, sitting = 1, resting = 1, sleeping = 2 }
local function recovery_depth(posn) return RECOVERY_DEPTH[posn or ""] or 0 end

















local function group_roster() return (state.group) or {} end





local minions_pending_spell_heal
local all_minions_ready
local heal_minions_kick
local reset_minion_heal












local recovery
local self_cast_wanted









local pick_self_cast
local lifetap_hold_rest


local minion_needs_spell_heal

local ticks_to_target








local STAT_FIELDS = { hp = { "hp", "maxhp" }, mana = { "mana", "maxmana" }, stam = { "stam", "maxstam" } }
local STAT_LABEL = { hp = "HP", mana = "mana", stam = "stamina" }
local STAT_ALIASES = {
   hp = "hp", health = "hp", hitpoints = "hp",
   mana = "mana", mp = "mana",
   stamina = "stam", stam = "stam", sta = "stam", sp = "stam",
}


local function one_stat_ready(key, p)
   local f = STAT_FIELDS[key]; if not f then return true end
   return pct(state[f[1]], state[f[2]]) >= (p or READY_PCT)
end
local function stat_ready(p)
   local st = recovery and recovery.stat
   if st then return one_stat_ready(st, p) end
   return ready(p)
end














local POSTURE_CONFIRM_WAIT = 8



local POSTURE_TARGET_DEPTH = { stand = 0, rest = 1, sleep = 2 }





local POSTURE_FLIP_HOLD = 5
local last_posture_cmd
local last_posture_at = 0
local prev_posture_cmd
local function posture_confirmed(cmd)
   local target = POSTURE_TARGET_DEPTH[cmd]
   if target == nil then return false end
   local d = recovery_depth(S(state.position))
   if target == 0 then return d == 0 end
   return d >= target
end
local function send_posture(cmd)
   local now = os.time()



   if cmd == last_posture_cmd and not posture_confirmed(cmd) and
      (now - last_posture_at) < POSTURE_CONFIRM_WAIT then
      return
   end



   if cmd ~= "stand" and cmd == prev_posture_cmd and cmd ~= last_posture_cmd and
      (now - last_posture_at) < POSTURE_FLIP_HOLD then
      return
   end
   prev_posture_cmd = last_posture_cmd
   last_posture_cmd, last_posture_at = cmd, now
   send(cmd)
end
local function reset_posture() last_posture_cmd, last_posture_at, prev_posture_cmd = nil, 0, nil end






local function note_already_posture(posn)
   state.position = posn
   last_posture_cmd, last_posture_at = nil, 0
end





local last_posture_key
local last_cast_key
local function narrate(chan, key, msg)
   if chan == "posture" then
      if key == last_posture_key then return end
      last_posture_key = key
   else
      if key == last_cast_key then return end
      last_cast_key = key
   end
   if echo then echo("\27[36m[recover]\27[0m " .. msg) end
end
local function reset_narration() last_posture_key, last_cast_key = nil, nil end





local function choose_recovery_position()
   if recovery and recovery.minions_only then return end
   local player_done = stat_ready(recovery and recovery.pct or nil)


   local cast_pending = (not (recovery and recovery.stat)) and
   minions_pending_spell_heal and minions_pending_spell_heal()


   if recovery and recovery.await_spell and os.time() >= (recovery.await_until or 0) then
      recovery.await_spell, recovery.await_until = nil, nil
   end
   local awaiting_spellup = recovery and recovery.await_spell ~= nil
   if player_done then




      if cast_pending then
         narrate("posture", "done-minions-cast", "you're topped off — resting to finish healing your minions")

         if recovery_depth(S(state.position)) >= 2 then send_posture("rest") end
      else
         narrate("posture", "done-minions-wait", "you're topped off — standing, waiting on your minions to regen")


         if recovery_depth(S(state.position)) > 0 then send_posture("stand") end
      end
      return
   end



   local hp, mp, sp = pct(state.hp, state.maxhp), pct(state.mana, state.maxmana), pct(state.stam, state.maxstam)
   local want = (hp > 0.85 and mp < 1 and sp > 0.75) and "rest" or "sleep"





   local self_want = self_cast_wanted()
   local cast_now = self_want and (pick_self_cast() ~= nil)
   if cast_now then want = "rest"
   elseif self_want and not state.sharp then want = "sleep" end
   if want == "sleep" and (cast_pending or awaiting_spellup) then want = "rest" end





   local tap_rest = lifetap_hold_rest and lifetap_hold_rest()
   if tap_rest then want = "rest" end


   if tap_rest then
      narrate("posture", "rest-lifetap", "resting to bleed surplus hp into mana")
   elseif awaiting_spellup then
      narrate("posture", "rest-spellup", "staying up until " .. recovery.await_spell .. " is recast (or it times out)")
   elseif cast_now then
      narrate("posture", "rest-cast", "resting so I can cast to top off your " .. pick_self_cast().label)
   elseif self_want and not state.sharp then
      narrate("posture", "sleep-sharp", "sleeping to get sharp first — faster regen; I'll cast after if it's still worth it")
   elseif cast_pending then
      narrate("posture", "rest-minions", "resting so I can cast heals on your minions")
   elseif want == "rest" then
      narrate("posture", "rest-mana", "hp and stamina are set — just resting out mana now")
   else
      narrate("posture", "sleep-deep", "sleeping — deepest heal for your hp/stamina")
   end




   if want == "rest" then
      if recovery_depth(S(state.position)) ~= 1 then send_posture("rest") end
      return
   end
   if recovery_depth(S(state.position)) >= 2 then return end
   send_posture("sleep")
end





recovery = { pct = READY_PCT, settle = nil }
local function end_recovery(completed, reason)
   state.recover = false
   reset_narration()



   state.lifetap_manafull, state.lifetap_retry_at, state.lifetap_send_at = false, nil, 0
   if reset_minion_heal then reset_minion_heal() end
   local s = recovery.settle
   recovery.settle, recovery.pct, recovery.minions_only, recovery.stat = nil, READY_PCT, nil, nil
   recovery.await_spell, recovery.await_until = nil, nil
   state.recover_pct, state.recover_stat, state.recover_minions_only = nil, nil, nil
   if s then if completed then s.resolve(nil) else s.reject(reason or "recovery interrupted") end end
end



local function maybe_complete_recovery()



   if recovery.minions_only then
      if state.recover and not (minions_pending_spell_heal and minions_pending_spell_heal()) then
         echo("Minions topped off.")
         end_recovery(true, nil)
         return true
      end
      return false
   end






   if state.recover and stat_ready(recovery.pct) and
      (recovery.stat or (all_minions_ready and all_minions_ready(recovery.pct))) then
      if recovery.stat then echo(string.format("Your %s is recovered — standing up.", STAT_LABEL[recovery.stat]))
      else echo("You have recovered and are ready to adventure!") end
      send_posture("stand")
      end_recovery(true, nil)
      return true
   end



   if state.recover then choose_recovery_position() end
   return false
end






















local LIFETAP_FLOOR = 0.55
local LIFETAP_START = 0.75
local LIFETAP_MIN = 15
local LIFETAP_MANA_TICKS = 1
local LIFETAP_MIN_LEVEL = 21
local LIFETAP_RETRY = 5
local LIFETAP_COOLDOWN = 15
local LIFETAP_SEND_WAIT = 3



local function lifetap_floor_hp() return math.floor(N(state.maxhp or 0) * LIFETAP_FLOOR + 0.5) end
local function has_lifetap()
   local classes = state.classes
   local n = classes and classes.Necromancer
   return n and (n.level or 0) >= LIFETAP_MIN_LEVEL
end













local function lifetap_mana_low()
   local r = state.regen
   local mt = ticks_to_target(N(state.mana), N(state.maxmana), r and r.mana, 1.0)
   if mt == nil then return true end
   return mt > LIFETAP_MANA_TICKS
end

local function lifetap_mana_case()
   if not state.recover or state.fighting then return false end
   if state.lifetap_manafull then return false end
   if recovery and recovery.minions_only then return false end
   if recovery and recovery.stat and recovery.stat ~= "mana" then return false end
   if not has_lifetap() then return false end
   local frac = (recovery and recovery.pct) or READY_PCT
   if pct(state.mana, state.maxmana) >= frac then return false end
   if not lifetap_mana_low() then return false end
   return N(state.hp or 0) > lifetap_floor_hp() - LIFETAP_MIN
end





local function lifetap_worth_it()
   return lifetap_mana_case() and
   pct(state.hp, state.maxhp) > LIFETAP_START and
   (N(state.hp or 0) - lifetap_floor_hp()) >= LIFETAP_MIN
end




lifetap_hold_rest = function() return lifetap_mana_case() end



local function lifetap_wanted()
   return lifetap_worth_it() and recovery_depth(S(state.position)) < 2
end


local function lifetap_amount()
   if not lifetap_wanted() then return nil end
   return N(state.hp or 0) - lifetap_floor_hp()
end





local function maybe_lifetap()
   if state.lifetapping then return end
   local now = os.time()
   if state.lifetap_retry_at and now < N(state.lifetap_retry_at) then return end
   if (now - N(state.lifetap_send_at or 0)) < LIFETAP_SEND_WAIT then return end
   local amt = lifetap_amount()
   if amt and amt > 0 then
      send("lifetap " .. amt)
      state.lifetap_send_at = now
      if echo then echo(string.format(
"\27[36m[recover]\27[0m tapping %d hp into mana (keeping you above %d%% hp)",
math.floor(amt), math.floor(LIFETAP_FLOOR * 100 + 0.5))) end
   end
end





local function lifetap_bound()
   state.lifetapping = false
   if state.recover then state.lifetap_retry_at = os.time() + LIFETAP_COOLDOWN end
end





























local MINION_FULL_BELOW = 100
local function minion_ready_target(m, frac)
   if minion_needs_spell_heal(m.name) then return 1.0 end
   if (m.maxhp or 0) < MINION_FULL_BELOW then return 1.0 end
   return frac or (recovery and recovery.pct) or READY_PCT
end





local BOLSTER_MIN_MISSING = 25
local function heal_spell(cur, max)
   return ((max or 0) - (cur or 0)) >= BOLSTER_MIN_MISSING and "bolster" or "soothe"
end











local REFRESH_COST = 15
local HEAL_COST = 14
local CAST_MIN_TICKS = 3
local SELF_CAST_MANA_MIN = 0.50



local MINION_HEAL_MANA_MIN = 0.30




ticks_to_target = function(cur, max, rate, frac)
   local target = (frac or READY_PCT) * (max or 0)
   local deficit = target - (cur or 0)
   if deficit <= 0 then return 0 end
   if not rate or rate <= 0 then return nil end
   return deficit / rate
end





local function cast_beats_waiting(cur, max, rate, cost)
   local r = state.regen
   if not r then return false end
   local st = ticks_to_target(cur, max, rate, recovery and recovery.pct)
   if not st or st <= CAST_MIN_TICKS then return false end
   local mt = ticks_to_target(N(state.mana or 0) - cost, N(state.maxmana), r.mana, recovery and recovery.pct)
   if mt == nil then return false end
   return mt < st
end




self_cast_wanted = function()
   if recovery and recovery.minions_only then return false end
   if not state.maxmana or pct(state.mana, state.maxmana) < SELF_CAST_MANA_MIN then return false end
   local st = recovery and recovery.stat
   local frac = (recovery and recovery.pct) or READY_PCT
   local want_hp = (st == nil or st == "hp") and pct(state.hp, state.maxhp) < frac
   local want_stam = (st == nil or st == "stam") and pct(state.stam, state.maxstam) < frac
   return want_hp or want_stam
end




local regen_query_pending = false
local function query_regen()
   if regen_query_pending then return end
   regen_query_pending = true
   send("show regen")
   after(2, function() regen_query_pending = false end)
end
local function reset_regen_query() regen_query_pending = false end









local REGEN_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/regen_cache.lua"
local REGEN_TTL = 2 * 24 * 3600







local regen_cache = {}


local function total_level()
   local n = 0
   for _, c in pairs((state.classes) or {}) do n = n + (c.level or 0) end
   return n
end


local function regen_key(posn, sharp)
   if sharp == nil then return nil end
   return recovery_depth(posn) .. ":" .. (sharp and "1" or "0")
end
local function regen_fresh(entry)
   return entry and entry.at and (os.time() - entry.at) < REGEN_TTL and (entry.lvl or 0) == total_level()
end

local function save_regen_cache()
   local parts = {}
   for k, v in pairs(regen_cache) do
      parts[#parts + 1] = string.format("[%q]={hp=%d,mana=%d,move=%d,at=%d,lvl=%d}",
      k, math.floor(v.hp or 0), math.floor(v.mana or 0), math.floor(v.move or 0), math.floor(v.at or 0), math.floor(v.lvl or 0))
   end
   persist.write(REGEN_FILE, "return {" .. table.concat(parts, ",") .. "}")
end
local function load_regen_cache()
   regen_cache = {}
   local t = persist.load(REGEN_FILE)
   if type(t) == "table" then
      for k, v in pairs(t) do
         if type(v) == "table" then
            regen_cache[k] = { hp = v.hp, mana = v.mana, move = v.move,
at = v.at, lvl = v.lvl, }
         end
      end
   end
end


local function cache_regen(posn, sharp, hp, mana, move)
   local key = regen_key(posn, sharp)
   if not key then return end
   regen_cache[key] = { hp = hp, mana = mana, move = move, at = os.time(), lvl = total_level() }
   save_regen_cache()
end



local function ensure_regen()
   local key = regen_key(S(state.position), B(state.sharp))
   local entry = key and regen_cache[key]
   if regen_fresh(entry) then
      state.regen = { hp = entry.hp, mana = entry.mana, move = entry.move, position = state.position }
   else
      query_regen()
   end
end

load_regen_cache()








local regen_warm_armed = false
local _prev_on_connect_regen = on_connect
function on_connect()
   if _prev_on_connect_regen then _prev_on_connect_regen() end
   regen_warm_armed = true
end

local function warm_regen_on_first_vitals()
   if not regen_warm_armed then return end
   regen_warm_armed = false
   if not state.fighting then ensure_regen() end
end



minion_needs_spell_heal = function(name)
   local low = (name or ""):lower()
   return low:find("skelet", 1, true) ~= nil or low:find("bone ", 1, true) ~= nil
end




local function is_self_row(m) return state.name and m.name == state.name end
local function minion_target_word(name)


   return (name or ""):match("(%S+)%s*$") or ""
end

local ARTICLES = { a = true, an = true, the = true }




local function minion_target_words(name)
   local words = {}
   for w in (name or ""):gmatch("%S+") do
      local lw = w:lower()
      if not ARTICLES[lw] then words[#words + 1] = lw end
   end
   local out = {}
   for i = #words, 1, -1 do out[#out + 1] = words[i] end
   return out
end


local function player_recovered()
   return stat_ready(recovery and recovery.pct or nil)
end








local function minion_heal_eligible(m, f)
   if is_self_row(m) then return false end
   f = f or pct(m.hp, m.maxhp)
   if f >= minion_ready_target(m, nil) then return false end
   if minion_needs_spell_heal(m.name) then return true end
   if (m.flags or ""):find("M", 1, true) == nil then return false end
   return player_recovered()
end



minions_pending_spell_heal = function()
   for _, m in ipairs(group_roster()) do
      if minion_heal_eligible(m, nil) then return true end
   end
   return false
end



all_minions_ready = function(frac)
   for _, m in ipairs(group_roster()) do
      if not is_self_row(m) and pct(m.hp, m.maxhp) < minion_ready_target(m, frac) then return false end
   end
   return true
end








local rx = __rx




local function P(executor)
   local p = __promise(executor, "recover-flow")
   if __untrack_promise then __untrack_promise(p) end
   (p).__start()
   return p
end




local castReplyS = rx and rx.subject() or nil
local castInvalidS = rx and rx.subject() or nil
local recoveryEndS = rx and rx.subject() or nil

local heal_inflight
local advance_after_reply
local handle_invalid_target
local minion_target_invalid
local try_cast_heal









local function begin_cast_step()
   if not rx then return end
   heal_inflight = P(function(resolve, _, onCancel)
      local sub
      local timer
      local done = false
      local function cleanup()
         if sub then sub:unsubscribe(); sub = nil end
         if timer and cancel then cancel(timer); timer = nil end
      end
      local function fin(ev, arg)
         if done then return end
         done = true; cleanup(); resolve({ ev = ev, arg = arg })
      end
      sub = rx.merge(
      castReplyS:map(function(kind) return { ev = "reply", arg = kind } end),
      castInvalidS:map(function(w) return { ev = "invalid", arg = w } end)):
      takeUntil(recoveryEndS:asObservable()):subscribe(function(e) fin(e.ev, e.arg) end)
      timer = after and after(3, function() fin("timeout", nil) end) or nil
      onCancel(function() done = true; cleanup() end)
   end):andThen(function(r)
      local re = r
      heal_inflight = nil
      if re.ev == "reply" then advance_after_reply(re.arg)
      elseif re.ev == "invalid" then handle_invalid_target(re.arg)
      else try_cast_heal() end
   end)
end






















local minion_heal = { sweep = {}, blocked = {}, tried = {}, word_blocked = {}, refuse_streak = 0, last = nil }

reset_minion_heal = function()
   minion_heal.refuse_streak = 0
   minion_heal.sweep, minion_heal.blocked, minion_heal.last = {}, {}, nil
   minion_heal.tried, minion_heal.word_blocked = {}, {}
   minion_heal.self_hp_blocked, minion_heal.self_stam_blocked = false, false
   if recoveryEndS then recoveryEndS:onNext(nil) end
   if heal_inflight and heal_inflight.cancel then heal_inflight:cancel() end
   heal_inflight = nil
end



local function next_untried_word(name)
   local tried = minion_heal.tried[name]
   for _, w in ipairs(minion_target_words(name)) do
      if not (tried and tried[w]) then return w end
   end
   return nil
end




local function most_hurt_spell_minion()
   local best
   local best_frac
   for _, m in ipairs(group_roster()) do
      local f = pct(m.hp, m.maxhp)
      if minion_heal_eligible(m, f) and not minion_heal.blocked[minion_target_word(m.name)] and
         not minion_heal.word_blocked[m.name] then
         if not best_frac or f < best_frac then best, best_frac = m, f end
      end
   end
   return best, best_frac
end








local function keyword_matches(word, name)
   if word == "skeleton" then return (name or ""):lower():find("skelet", 1, true) ~= nil end
   return minion_target_word(name) == word
end



local function keyword_count(word)
   local n = 0
   for _, m in ipairs(group_roster()) do
      if not is_self_row(m) and keyword_matches(word, m.name) then n = n + 1 end
   end
   return n
end















local function cast(spell)
   local c = { spell = spell, target = nil, last = nil }
   c.at = function(self, t) self.target = t; return self end
   c.records = function(self, l) self.last = l; return self end
   c.go = function(self)
      minion_heal.last = self.last
      send("c " .. self.spell .. (self.target and (" " .. self.target) or ""))
      begin_cast_step()
   end
   return c
end

local try_self_cast




try_cast_heal = function()
   if not state.recover or heal_inflight then return end
   if N(state.action or 0) >= 50 then return end
   if state.position == "sleeping" then return end


   local m
   local f
   if not (recovery and recovery.stat) then m, f = most_hurt_spell_minion() end
   if not m then try_self_cast(); return end



   if pct(state.mana, state.maxmana) < MINION_HEAL_MANA_MIN then return end
   local word = next_untried_word(m.name)
   if not word then
      minion_heal.word_blocked[m.name] = true
      try_cast_heal(); return
   end
   local K = keyword_count(word)
   local target = word
   local ord
   if K > 1 then
      ord = minion_heal.sweep[word] or 1
      if ord > K then ord = 1 end
      target = ord .. "." .. word
   end
   local spell = heal_spell(m.hp, m.maxhp)
   cast(spell):at(target):
   records({ word = word, ord = ord, K = K, kind = "minion", name = m.name }):
   go()
end







pick_self_cast = function()
   if not self_cast_wanted() then return nil end
   local frac = (recovery and recovery.pct) or READY_PCT
   local st = recovery and recovery.stat
   local r = state.regen
   if (st == nil or st == "hp") and not minion_heal.self_hp_blocked and state.name then
      local hpf = pct(state.hp, state.maxhp)
      if hpf < frac and cast_beats_waiting(N(state.hp), N(state.maxhp), r and r.hp, HEAL_COST) then
         return { stat = "hp", label = "hp", spell = heal_spell(N(state.hp), N(state.maxhp)),
target = S(state.name), pctv = hpf, ticks = ticks_to_target(N(state.hp), N(state.maxhp), r and r.hp, frac) or 0,
kind = "self_hp", }
      end
   end
   if (st == nil or st == "stam") and not minion_heal.self_stam_blocked and not engaged(nil) then
      local spf = pct(state.stam, state.maxstam)
      if spf < frac and cast_beats_waiting(N(state.stam), N(state.maxstam), r and r.move, REFRESH_COST) then
         return { stat = "stam", label = "stamina", spell = "refresh", target = nil, pctv = spf,
ticks = ticks_to_target(N(state.stam), N(state.maxstam), r and r.move, frac) or 0, kind = "self_stam", }
      end
   end
   return nil
end

try_self_cast = function()
   local pick = pick_self_cast()
   if not pick then



      if self_cast_wanted() and state.sharp then
         if not state.regen then
            narrate("cast", "nodata", "no regen numbers yet — I'll check `show regen` and decide once I have them")
         else
            narrate("cast", "wait", "sharp now and natural regen is fast enough — not worth spending mana")
         end
      end
      return
   end
   narrate("cast", pick.stat, string.format("casting %s%s — %s %d%% is ~%d ticks of regen away; mana to spare",
   pick.spell, (pick.stat == "hp") and " on yourself" or "", pick.label,
   math.floor(pick.pctv * 100 + 0.5), math.ceil(pick.ticks)))
   cast(pick.spell):at(pick.target):records({ kind = pick.kind }):go()
end





local MINION_REFUSE_CAP = 3


advance_after_reply = function(kind)
   local last = minion_heal.last



   if last and last.kind and last.kind ~= "minion" then
      if kind == "ok" then minion_heal.refuse_streak = 0
      elseif kind == "fail" then
      else
         if last.kind == "self_hp" then minion_heal.self_hp_blocked = true
         elseif last.kind == "self_stam" then minion_heal.self_stam_blocked = true end
      end
      try_cast_heal()
      return
   end
   if kind == "ok" then
      minion_heal.refuse_streak = 0
      return
   elseif kind == "fail" then
      try_cast_heal()
      return
   end

   if last and (last.K or 1) > 1 then
      minion_heal.sweep[last.word] = ((last.ord or 1) % last.K) + 1
   end
   minion_heal.refuse_streak = minion_heal.refuse_streak + 1
   if last and minion_heal.refuse_streak > (last.K or 1) + MINION_REFUSE_CAP then


      if last.word then
         minion_heal.blocked[last.word] = true
         echo("\27[33m[recover] can't seem to heal '" .. last.word .. "'; skipping it.\27[0m")
      end
      minion_heal.refuse_streak = 0
   end
   try_cast_heal()
end




local function minion_cast_settled(kind)
   if not heal_inflight then return end
   if castReplyS then castReplyS:onNext(kind) end
end


heal_minions_kick = function() try_cast_heal() end


local test_exports = { ready = ready, pct = pct, READY_PCT = READY_PCT,
stat_ready = stat_ready, one_stat_ready = one_stat_ready, STAT_ALIASES = STAT_ALIASES,
choose_recovery_position = choose_recovery_position, recovery_depth = recovery_depth,
recovery = recovery, end_recovery = end_recovery,
maybe_complete_recovery = maybe_complete_recovery,
minion_needs_spell_heal = minion_needs_spell_heal, minion_target_word = minion_target_word,
heal_spell = heal_spell, BOLSTER_MIN_MISSING = BOLSTER_MIN_MISSING,
minion_target_words = minion_target_words, next_untried_word = next_untried_word,
keyword_count = keyword_count, keyword_matches = keyword_matches,
minions_pending_spell_heal = minions_pending_spell_heal, all_minions_ready = all_minions_ready,
minion_heal = minion_heal, try_cast_heal = try_cast_heal,
MINION_HEAL_MANA_MIN = MINION_HEAL_MANA_MIN,
minion_cast_settled = minion_cast_settled, reset_minion_heal = reset_minion_heal,
reset_posture = reset_posture, send_posture = send_posture,
posture_confirmed = posture_confirmed, note_already_posture = note_already_posture,
POSTURE_CONFIRM_WAIT = POSTURE_CONFIRM_WAIT,
ticks_to_target = ticks_to_target, cast_beats_waiting = cast_beats_waiting,
self_cast_wanted = self_cast_wanted, try_self_cast = try_self_cast,
lifetap_wanted = lifetap_wanted, lifetap_amount = lifetap_amount,
lifetap_mana_case = lifetap_mana_case, lifetap_worth_it = lifetap_worth_it,
lifetap_hold_rest = lifetap_hold_rest, maybe_lifetap = maybe_lifetap,
lifetap_bound = lifetap_bound, lifetap_floor_hp = lifetap_floor_hp,
lifetap_mana_low = lifetap_mana_low,
LIFETAP_START = LIFETAP_START, LIFETAP_COOLDOWN = LIFETAP_COOLDOWN,
LIFETAP_MANA_TICKS = LIFETAP_MANA_TICKS,
has_lifetap = has_lifetap, LIFETAP_FLOOR = LIFETAP_FLOOR, LIFETAP_MIN = LIFETAP_MIN,
pick_self_cast = pick_self_cast, reset_narration = reset_narration,
regen_cache = regen_cache, regen_key = regen_key, regen_fresh = regen_fresh,
total_level = total_level, ensure_regen = ensure_regen, cache_regen = cache_regen,
reset_regen_query = reset_regen_query, REGEN_TTL = REGEN_TTL, }
for k, v in pairs(test_exports) do _AA_TEST[k] = v end





trigger([[^You make a shallow yet bloody cut and begin tapping your life\.]], function()
   state.lifetapping, state.lifetap_send_at = true, 0
end)
trigger([[^You will now tap \d+ hitpoints from this point on\.]], function()
   state.lifetapping, state.lifetap_send_at = true, 0
end)
trigger([[^You are busy tapping your life for mana\.]], function()
   state.lifetapping = true
end)
trigger([[^You quickly bind your wound and stop tapping your life\.]], function()
   lifetap_bound()
end)




trigger([[^You are too weak to do that right now\.]], function()
   if not state.recover then return end
   state.lifetapping, state.lifetap_send_at = false, 0
   state.lifetap_retry_at = os.time() + LIFETAP_RETRY
end)


trigger([[^Your mana is already almost full\.]], function()
   state.lifetapping, state.lifetap_send_at, state.lifetap_manafull = false, 0, true
end)








if rx then
   local T = rx.fromTrigger
   local function on_reply(pat, kind) T(pat, nil):subscribe(function(_) minion_cast_settled(kind) end) end
   on_reply([[^You repair the damage to .+'s body\.$]], "ok")
   on_reply([[^You feel less tired\.$]], "ok")
   on_reply([[^You feel a little better\.$]], "ok")
   on_reply([[^You will your injuries to heal and your soul to take courage\.$]], "ok")
   on_reply([[^You fail to cast the spell '(soothe wounds|bolster|refresh)'\.$]], "fail")
   on_reply([[^.+ doesn't need that much healing right now\.$]], "full")
   on_reply([[^If you really want to cast that on yourself, you must use your name\.$]], "notgt")


   T([[^Sorry, '([^']+)' isn't a valid target for the spell '[^']+'\.$]], nil):
   subscribe(function(c) minion_target_invalid(c[1]) end)
end




minion_target_invalid = function(word)
   if not heal_inflight then return end
   local last = minion_heal.last
   if not (last and last.kind == "minion" and last.name) then return end
   if castInvalidS then castInvalidS:onNext(word) end
end




handle_invalid_target = function(word)
   local last = minion_heal.last
   if not (last and last.kind == "minion" and last.name) then return end
   local name = last.name
   local bad = last.word or word
   minion_heal.tried[name] = minion_heal.tried[name] or {}
   minion_heal.tried[name][bad] = true
   local nextw = next_untried_word(name)
   if nextw then
      echo("\27[33m[recover] '" .. bad .. "' isn't a target for " .. name .. "; trying '" .. nextw .. "'.\27[0m")
   else
      minion_heal.word_blocked[name] = true
      echo("\27[33m[recover] no working keyword to heal " .. name .. " — giving up on it this recovery.\27[0m")
   end
   try_cast_heal()
end
_AA_TEST.minion_target_invalid = minion_target_invalid





trigger([[^You (feel sharp, and )?currently gain (\d+) hitpoints, (\d+) mana, and (\d+) movement while (\w+)\.$]],
function(_, sharp, hp, mana, move, posn)
   local is_sharp = (sharp ~= nil and sharp ~= "")
   local H, M, V = tonumber(hp), tonumber(mana), tonumber(move)
   state.sharp = is_sharp
   state.regen = { hp = H, mana = M, move = V, position = posn }
   cache_regen(posn, is_sharp, H, M, V)
   if regen_query_pending then regen_query_pending = false; return false end
end)

trigger([[^You find yourself feeling sharp and ready to take on anything!$]], function()
   state.sharp = true; if state.recover then ensure_regen() end
end)
trigger([[^You no longer feel sharp and at your best\.$]], function()
   state.sharp = false; if state.recover then ensure_regen() end
end)







trigger([[^You are already sound asleep!$]], function()
   if not state.recover then return end
   note_already_posture("sleeping"); return false
end)
trigger([[^You are already resting\.$]], function()
   if not state.recover then return end
   note_already_posture("resting"); return false
end)
trigger([[^You are already standing\.$]], function()
   if not state.recover then return end
   note_already_posture("standing"); return false
end)




local function begin_recovery(frac)
   recovery.pct = frac
   state.recover = true



   state.recover_pct, state.recover_stat, state.recover_minions_only = frac, recovery.stat, recovery.minions_only
   local pctlabel = math.floor(frac * 100 + 0.5)
   if recovery.stat then
      echo(string.format("Recovering %s — resting/sleeping; I'll stand you up once %s hits %d%%.",
      STAT_LABEL[recovery.stat], STAT_LABEL[recovery.stat], pctlabel))
   else
      echo(string.format("Recovering — resting/sleeping; I'll stand you up once every vital hits %d%%.", pctlabel))
   end
   reset_posture()
   reset_narration()
   choose_recovery_position()



   heal_minions_kick()


   if not recovery.minions_only then ensure_regen() end
end









function recover(target)
   local frac = READY_PCT
   if target ~= nil then
      local n = tonumber(target)
      if n and n > 0 then frac = (n > 1) and (n / 100) or n end
   end
   if frac > 1 then frac = 1 end
   return __promise(function(resolve, reject, onCancel)


      if ready(frac) and all_minions_ready(frac) then
         echo("Already recovered — vitals at target and minions topped off."); resolve(nil); return
      end



      if recovery.settle then local old = recovery.settle; recovery.settle = nil; old.reject("superseded") end
      recovery.settle = { resolve = resolve, reject = reject }
      recovery.stat, recovery.minions_only = nil, nil
      begin_recovery(frac)
      onCancel(function()


         if state.recover then send_posture("stand") end
         recovery.settle, recovery.pct, state.recover = nil, READY_PCT, false
         reset_minion_heal()
      end)
   end, "recover")
end
doc("recover", { sig = "recover([pct]) -> promise", group = "combat",
text = "Start a recovery and return a promise that resolves once every vital reaches `pct` (95 or " ..
"0.95; default 90%) and rejects if interrupted (you move, a fight starts, you cancel). Chain " ..
"the next action with .andThen — e.g. recover(95).andThen(attack('orc')).",
example = "#recover(95).andThen(attack('orc'))", })








function recover_minions()
   return __promise(function(resolve, reject, onCancel)
      if not minions_pending_spell_heal() then
         echo("No minions need healing right now."); resolve(nil); return
      end
      if recovery.settle then local old = recovery.settle; recovery.settle = nil; old.reject("superseded") end
      recovery.settle = { resolve = resolve, reject = reject }
      recovery.minions_only, recovery.stat, state.recover = true, nil, true

      state.recover_minions_only, state.recover_stat, state.recover_pct = true, nil, recovery.pct
      echo("Healing your minions — casting until they're topped off (leaving your own vitals alone).")
      heal_minions_kick()
      onCancel(function()
         recovery.settle, recovery.minions_only, state.recover = nil, nil, false
         reset_minion_heal()
      end)
   end, "recover minions")
end
doc("recover_minions", { sig = "recover_minions() -> promise", group = "combat",
text = "Heal ONLY your skeletal minions (bolster/soothe) until topped off, leaving your own vitals and " ..
"posture alone — no rest/sleep. Returns a promise; resolves when no minion needs a cast. Typed " ..
"form: `recover minions` (and `recover minions off` to stop).", })






function recover_stat(stat, target)
   local key = STAT_ALIASES[tostring(stat):lower()]
   return __promise(function(resolve, reject, onCancel)
      if not key then echo("Unknown stat '" .. tostring(stat) .. "' — use hp, mana, or stamina."); resolve(nil); return end
      local frac = READY_PCT
      if target ~= nil then
         local n = tonumber(target)
         if n and n > 0 then frac = (n > 1) and (n / 100) or n end
      end
      if frac > 1 then frac = 1 end
      if one_stat_ready(key, frac) then
         echo(string.format("Already recovered — %s at target.", STAT_LABEL[key])); resolve(nil); return
      end
      if recovery.settle then local old = recovery.settle; recovery.settle = nil; old.reject("superseded") end
      recovery.settle = { resolve = resolve, reject = reject }
      recovery.minions_only, recovery.stat = nil, key
      begin_recovery(frac)
      onCancel(function()
         if state.recover then send_posture("stand") end
         recovery.settle, recovery.pct, recovery.stat, state.recover = nil, READY_PCT, nil, false
         reset_minion_heal()
      end)
   end, "recover " .. STAT_LABEL[key or "hp"])
end
doc("recover_stat", { sig = "recover_stat(stat[, pct]) -> promise", group = "combat",
text = "Recover ONE vital only — `stat` is hp/health, mana/mp, or stamina/sp. Same rest/sleep flow as " ..
"recover(), but done as soon as that single stat hits `pct` (default 90%); ignores the other " ..
"vitals and never heals minions. Typed form: `recover hp` / `recover mana` / `recover stamina`.",
example = "#recover_stat('mana', 95)", })






alias([[^state$]], function() echo(describe_state()) end)





alias([[^recover$]], function()
   if state.recover then
      echo("Already recovering — 'recover off' to stop.")
   elseif ready(nil) and all_minions_ready(nil) then
      echo("Already recovered — all vitals at 90%+ and minions topped off.")
   else
      recover(nil)
   end
end)


alias([[^autoassist\s*(\w*)$]], function(_, arg)
   local a = (arg or ""):lower()
   if a == "on" then state.auto_assist = true
   elseif a == "off" then state.auto_assist = false
   elseif a ~= "" then echo("Usage: autoassist [on|off]"); return end
   echo("Auto-assist is " .. (state.auto_assist and "ON" or "OFF") ..
   " — I " .. (state.auto_assist and "will" or "won't") .. " `assist` when your minions are fighting and you aren't.")
end)



alias([[^recover minions$]], function()
   if state.recover then
      echo("Already recovering — 'recover off' to stop.")
   elseif not minions_pending_spell_heal() then
      echo("No minions need healing right now.")
   else
      recover_minions()
   end
end)
alias([[^recover minions off$]], function()
   if state.recover then echo("Ending minion healing."); end_recovery(false, "cancelled")
   else echo("Not recovering.") end
end)





alias([[^recover (hp|health|hitpoints|mana|mp|stamina|stam|sta|sp)(?: +(\d+))?$]], function(_, word, pct)
   local key = STAT_ALIASES[word:lower()]
   local n = tonumber(pct)
   local frac = n and ((n > 1) and (n / 100) or n) or nil
   if state.recover then
      echo("Already recovering — 'recover off' to stop.")
   elseif one_stat_ready(key, frac) then
      echo(string.format("Already recovered — %s at %s.", STAT_LABEL[key], n and (math.min(n, 100) .. "%") or "90%+"))
   else
      recover_stat(word, n)
   end
end)


alias([[^recover off$]], function()
   if state.recover then
      echo("Ending recovery."); end_recovery(false, "cancelled")
   else
      echo("Not recovering.")
   end
end)













local vitalsS = rx and rx.subject() or nil
local positionS = rx and rx.subject() or nil
local groupS = rx and rx.subject() or nil
local spellupS = rx and rx.subject() or nil
local spelldownS = rx and rx.subject() or nil

if rx then

   vitalsS:subscribe(function(_)
      maybe_complete_recovery()
      if state.recover then maybe_lifetap() end
   end)

   positionS:subscribe(function(e)
      local pe = e
      if state.recover and recovery_depth(pe.posn) == 0 then choose_recovery_position() end
      if state.recover and pe.changed and (not state.regen or (state.regen).position ~= pe.posn) then ensure_regen() end
   end)

   groupS:subscribe(function(_)
      heal_minions_kick(); maybe_complete_recovery()
   end)

   spellupS:subscribe(function(s)
      if recovery and recovery.await_spell == s then recovery.await_spell, recovery.await_until = nil, nil end
   end)

   spelldownS:subscribe(function(s)
      if state.recover and state.position == "sleeping" and pct(state.mana, state.maxmana) > 0.3 then
         send("rest"); state.position = "sitting"
         if recovery then recovery.await_spell, recovery.await_until = S(s), os.time() + SPELLUP_WAIT end
      end
   end)
end

function __recovery_on_vitals() warm_regen_on_first_vitals(); if vitalsS then vitalsS:onNext(nil) end end
function __recovery_on_position(p, changed) if positionS then positionS:onNext({ posn = p, changed = changed }) end end
function __recovery_on_group() if groupS then groupS:onNext(nil) end end
function __recovery_on_spellup(s) if spellupS then spellupS:onNext(s) end end
function __recovery_on_spelldown(s) if spelldownS then spelldownS:onNext(s) end end

function __recovery_cancel(reason)
   end_recovery(false, reason)
end

function __ready(p) return ready(p) end

















local function resume_recovery()
   recovery.pct = N(state.recover_pct) or READY_PCT
   recovery.stat = S(state.recover_stat)
   recovery.minions_only = B(state.recover_minions_only)
   local label = recovery.minions_only and "recover minions" or
   (recovery.stat and ("recover " .. STAT_LABEL[recovery.stat]) or "recover")
   local p = __promise(function(resolve, reject, onCancel)
      if recovery.settle then local old = recovery.settle; recovery.settle = nil; old.reject("superseded") end
      recovery.settle = { resolve = resolve, reject = reject }
      onCancel(function()
         if state.recover then send_posture("stand") end
         recovery.settle, recovery.pct, recovery.stat, recovery.minions_only, state.recover =
         nil, READY_PCT, nil, nil, false
         state.recover_pct, state.recover_stat, state.recover_minions_only = nil, nil, nil
         reset_minion_heal()
      end)
   end, label)
   heal_minions_kick()
   return p
end
_AA_TEST.resume_recovery = resume_recovery



if state.recover and __promise then resume_recovery() end
