



















state = state or {}
_AA_TEST = _AA_TEST or {}




local function boot(n) pcall(require, n) end
boot("_rx")
if not __rx then dofile("Scripts/_rx.lua") end









state.opponents = state.opponents or {}









local function opps() return state.opponents end









local CONDITION_LADDER = {
   { phrase = "near death", pct = 3 },
   { phrase = "mortally wounded", pct = 8 },
   { phrase = "big nasty wounds", pct = 42 },
   { phrase = "quite a few wounds", pct = 55 },
   { phrase = "small wounds and bruises", pct = 68 },
   { phrase = "a few scratches", pct = 82 },
   { phrase = "pretty hurt", pct = 28 },
   { phrase = "awful", pct = 15 },
   { phrase = "excellent", pct = 95 },
}

local function condition_pct(text)
   local low = (text or ""):lower()
   for _, e in ipairs(CONDITION_LADDER) do
      if low:find(e.phrase, 1, true) then return e.pct end
   end
   return nil
end




local function parse_opponent(line)
   local pct = condition_pct(line)
   if not pct then return nil end
   local subj = line:match("^(.-)%s+[Ii]s%s") or line:match("^(.-)%s+[Hh]as%s") or
   line:match("^(.-)%s+[Ll]ooks?%s")
   if not subj then return nil end
   subj = subj:gsub("^%s+", ""):gsub("%s+$", "")
   if subj == "" or #subj > 40 or subj:find("[%.!%?]") then return nil end
   local lw = subj:lower()
   if lw:find("^your?%f[%A]") then return nil end
   return subj, pct
end





local function opponent_note(tbl, name, pct, now, exact)
   if not name then return end
   local key = name:lower()
   local e = tbl[key]
   if e then
      e.t = now
      if pct ~= nil then e.pct, e.exact = pct, exact == true end
   else
      tbl[key] = { display = name, pct = pct, exact = exact == true, t = now }
   end
end










local function opponents_active(tbl, now, ttl, exclude)
   local exl = exclude and exclude:lower() or nil
   local out = {}
   for key, o in pairs(tbl or {}) do
      if now - (o.t or 0) > ttl then
         tbl[key] = nil
      elseif key ~= exl then
         out[#out + 1] = { name = o.display or key, pct = o.pct, est = not o.exact, t = o.t }
      end
   end
   table.sort(out, function(a, b)
      if a.t ~= b.t then return a.t > b.t end
      return a.name < b.name
   end)
   return out
end

local OPP_TTL = 30


function active_opponents(now)
   return opponents_active(opps(), now or os.time(), OPP_TTL, state.fight_name)
end
doc(active_opponents, { name = "active_opponents", sig = "active_opponents([now])", group = "combat",
text = "Inferred list of the OTHER mobs you're fighting (not the current kxwt_fighting target), health estimated from the condition ladder. Returns an array of {name, pct, est} newest-first; prunes entries older than 30s.", })







function is_ally(name)
   if not name then return false end
   local low = name:lower()
   if low == "you" then return true end
   if state.name and low == (state.name):lower() then return true end
   for _, m in ipairs((state.group) or {}) do if m.name:lower() == low then return true end end
   return false
end
doc(is_ally, { name = "is_ally", sig = "is_ally(name) -> bool", group = "combat",
text = "True when `name` is you (incl. the \"you\" pronoun / your kxwt_myname) or a current group " ..
"member/minion — i.e. a combat line about them is friendly, not an enemy sighting.", })









local ENGAGE_TTL = 10



local MELEE_VERBS = {
   annoys = true, scratches = true, hits = true, injures = true, wounds = true, mauls = true,
   decimates = true, devastates = true, maims = true, mutilates = true, dismembers = true,
   disembowels = true, massacres = true, obliterates = true, demolishes = true, destroys = true,
   annihilates = true, misses = true,

   nicks = true, cuts = true, gouges = true, gashes = true, lacerates = true, shreds = true,
   mangles = true, rends = true, thumps = true, mars = true, batters = true, thrashes = true,
   clobbers = true, smashes = true, pulverizes = true,
}







local function parse_melee(line)
   local t = (line or ""):gsub("%*", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
   local attacker, rest = t:match("^(.+)'s (.+)$")
   if not attacker then
      rest = t:match("^[Yy]our (.+)$")
      if rest then attacker = "you" end
   end
   if not rest then return nil end
   local body = rest:match("^(.-)[%.!]+$")
   if not body then return nil end
   local before = 0
   for s, word in body:gmatch("()(%S+)") do
      if MELEE_VERBS[word:lower()] and before >= 1 and before <= 4 then
         local target = body:sub(s + #word + 1)
         if target ~= "" then return attacker, target end
      end
      before = before + 1
   end
   return nil
end



local function melee_enemy(attacker, target)
   local a_ally, t_ally = is_ally(attacker), is_ally(target)
   if a_ally and not t_ally then return target end
   if t_ally and not a_ally then return attacker end
   return nil
end



function engaged(now)
   if state.fighting then return true end
   return ((state.engaged_until) or 0) > (now or os.time())
end
doc(engaged, { name = "engaged", sig = "engaged([now])", group = "combat",
text = "True when you're in a fight: the kxwt_fighting target is live OR combat text (melee-round lines) was seen within the last ~10s. Covers nomelee fights, where the server sends NO kxwt_fighting at all.", })









local function maybe_assist(now)
   if not state.auto_assist then return end
   if state.assisted then return end
   state.assisted = true
   if state.fighting then return end
   send("assist")
end


local function reset_assist() state.assisted = nil end



local function is_self(name)
   if not name then return false end
   local low = name:lower()
   return low == "you" or (state.name ~= nil and low == (state.name):lower())
end












local function parse_target_line(line)
   local t = line or ""
   local name = t:match("^You keep a steady eye on (.+)%.$")
   if name then return "acquire", name end
   if t:match("^You are already targeting %a+%.$") then return "already", nil end
   name = t:match("^You are targeting (.+)%.$")
   if name then return "report", name end
   name = t:match("^You stop targeting (.+)%.$") or t:match("^You are no longer targeting (.+)%.$")
   if name then return "clear", name end
   if t:match("^You no longer have a target") then return "clear", nil end
   return nil
end
















local rx = __rx
if rx then
   local T = rx.fromTrigger









   T([[^kxw[tq]_fighting (\d+) \S+ (.+)$]]):
   map(function(c) return { pct = tonumber(c[1]), name = c[2] } end):
   subscribe(function(f)
      state.fighting, state.fight_pct, state.fight_name = true, f.pct, f.name
      opponent_note(opps(), f.name, f.pct, os.time(), true)
      if __recovery_cancel then __recovery_cancel("combat started") end
   end)






   T([[^kxw[tq]_fighting -1$]]):subscribe(function(_)
      state.fighting, state.fight_name, state.fight_pct = false, nil, nil
      state.opponents = {}
      state.engaged_until = nil
      reset_assist()
   end)











   T([[\S+'s [a-z *]*(?i:annoys|scratches|hits|injures|wounds|mauls|decimates|devastates|maims|mutilates|dismembers|disembowels|massacres|obliterates|demolishes|destroys|annihilates|misses|nicks|cuts|gouges|gashes|lacerates|shreds|mangles|rends|thumps|mars|batters|thrashes|clobbers|smashes|pulverizes) ]]):
   subscribe(function(c)
      local cap = c
      local attacker, target = parse_melee(cap.line)
      if not attacker then return end
      local enemy = melee_enemy(attacker, target)
      if not enemy then return end
      local now = os.time()
      opponent_note(opps(), enemy, nil, now, false)
      maybe_assist(now)
      if is_self(attacker) or is_self(target) then
         state.engaged_until = now + ENGAGE_TTL
         if __recovery_cancel then __recovery_cancel("combat started") end
      end
   end)





   T([[jumps to your side in battle!]]):subscribe(function(_) maybe_assist(os.time()) end)
   T([[rescues you and takes over the battle!]]):subscribe(function(_) maybe_assist(os.time()) end)



   T([[(near death|mortally wounded|awful|pretty hurt|nasty wounds|a few wounds|small wounds|few scratches|excellent)]]):
   subscribe(function(c)
      if not engaged() then return end
      local cap = c
      local name, pct = parse_opponent(cap.line)
      if name and not is_ally(name) then
         state.engaged_until = os.time() + ENGAGE_TTL
         opponent_note(opps(), name, pct, os.time(), false)
      end
   end)






   T([[^You keep a steady eye on .+\.$]]):subscribe(function(c)
      local cap = c
      local _, name = parse_target_line(cap.line)
      if not name or is_ally(name) then return end
      local now = os.time()
      state.engaged_until = now + ENGAGE_TTL
      opponent_note(opps(), name, nil, now, false)
   end)
   T([[^You are already targeting \w+\.$]]):subscribe(function(c)
      local cap = c
      if parse_target_line(cap.line) == "already" then state.engaged_until = os.time() + ENGAGE_TTL end
   end)
   T([[^You are targeting .+\.$]]):subscribe(function(c)
      local cap = c
      local kind, name = parse_target_line(cap.line)
      if kind == "report" and name and engaged() and not is_ally(name) then
         opponent_note(opps(), name, nil, os.time(), false)
      end
   end)



   T([[^You (stop targeting .+|are no longer targeting .+|no longer have a target.*)$]]):subscribe(function(c)
      local cap = c
      local kind, name = parse_target_line(cap.line)
      if kind ~= "clear" or not name then return end
      local e = opps()[name:lower()]
      if e and e.pct == nil then opps()[name:lower()] = nil end
   end)




   T([[^kxw[tq]_rvnum ]]):subscribe(function(_)
      state.opponents = {}; state.engaged_until = nil
   end)
   T([[^kxw[tq]_mdeath (.+)$]]):subscribe(function(c)
      local name = c[1]
      opps()[name:lower()] = nil
      if not state.fighting and not next(opps()) then state.engaged_until = nil end
   end)
end










state.auto_victory = (state.auto_victory == nil) and true or state.auto_victory
local VICTORY_DEDUP = 2
local last_victory_at = 0
local function maybe_victory(name, now)
   if not state.auto_victory then return end
   if is_ally(name) then return end
   if not engaged(now) then return end
   now = now or os.time()
   if now - last_victory_at < VICTORY_DEDUP then return end
   last_victory_at = now
   send("victory")
end
if _AA_TEST then
   _AA_TEST.maybe_victory = maybe_victory
   _AA_TEST.reset_victory = function() last_victory_at = 0 end
end
trigger([[^(.+) is DEAD!$]], function(_, name) maybe_victory(name, nil) end)










autoVictory = setmetatable(autoVictory or {}, { __call = function(_, args)
   local verb = ((args or ""):match("^%s*(%S*)") or ""):lower()
   if verb == "on" then state.auto_victory = true; echo("[victory] cry of victory ON")
   elseif verb == "off" then state.auto_victory = false; echo("[victory] cry of victory OFF")
   else echo("[victory] cry of victory is " .. (state.auto_victory and "ON" or "OFF")) end
end, })
function autoVictory.on() state.auto_victory = true end
function autoVictory.off() state.auto_victory = false end
function autoVictory.status() return state.auto_victory end
doc(autoVictory, { name = "autoVictory", sig = "autoVictory('on'|'off'|'status')", group = "combat",
text = "Auto-`victory` (warrior 'cry of victory' warcry): after you land a killing blow it's cried " ..
"automatically for the hp/move/anti-stun refund. `#autoVictory off` disables; on by default.", })


_AA_TEST.condition_pct = condition_pct
_AA_TEST.parse_opponent = parse_opponent
_AA_TEST.opponent_note = opponent_note
_AA_TEST.opponents_active = opponents_active
_AA_TEST.parse_melee = parse_melee
_AA_TEST.melee_enemy = melee_enemy
_AA_TEST.is_ally = is_ally
_AA_TEST.ENGAGE_TTL = ENGAGE_TTL
_AA_TEST.parse_target_line = parse_target_line
_AA_TEST.maybe_assist = maybe_assist
_AA_TEST.reset_assist = reset_assist
_AA_TEST.is_self = is_self






function in_combat() return engaged() end
