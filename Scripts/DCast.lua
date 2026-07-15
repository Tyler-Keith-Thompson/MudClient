





state = state or {}
_AA_TEST = _AA_TEST or {}






local function boot(name) pcall(require, name) end
boot("_rx"); if not __rx then dofile("Scripts/_rx.lua") end
boot("Promise")
boot("_persist"); if not __persist then dofile("Scripts/_persist.lua") end

local rx = __rx
local persist = __persist

local CAST_WAIT = 4
local DEFAULT_TRIES = 25
local MANA_WAIT = 6
local MANA_CAP = 40










local SEED = {
   ["lightning"] = [[^A .* bolt of lightning leaps from you to ]],
   ["icebolt"] = [[^You create and magically throw bolts of ice at ]],
   ["fireball"] = [[^You (?:conjure and )?throw a .* fireball at ]],
   ["prism"] = [[^You use a small crystal to focus your powers and throw a confusing wash of color and force at ]],
   ["frostflower"] = [[^Spiked flowers of ice quickly form on everything in a ring around you!$]],
   ["refresh"] = [[^You feel less tired\.$]],
}

local SPELLS_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/dcast_spells.lua"
local registry = {}
for k, v in pairs(SEED) do registry[k] = v end
do
   local t = persist and persist.load(SPELLS_FILE)
   if type(t) == "table" then
      for k, v in pairs(t) do registry[k] = v end
   end
end

local function save_learned()
   if not persist then return end
   local parts = {}
   for k, v in pairs(registry) do
      if SEED[k] ~= v then parts[#parts + 1] = string.format("[%q]=%q", k, v) end
   end
   persist.write(SPELLS_FILE, "return {" .. table.concat(parts, ",") .. "}")
end


local function resolve_spell(args)
   local low = args:lower()
   local best = nil
   for key in pairs(registry) do
      if low == key or low:sub(1, #key + 1) == key .. " " then
         if not best or #key > #best then best = key end
      end
   end
   return best
end
_AA_TEST.dcast_resolve = resolve_spell


local function decide(outcome, tries, cap)
   if outcome == "ok" then return "resolve" end
   if outcome == "mana" then return "wait" end
   if outcome == "cant" then return "reject", "can't concentrate enough" end
   if tries >= cap then return "reject", "gave up — couldn't land it in " .. tostring(tries) .. " tries" end
   return "retry"
end
_AA_TEST.dcast_decide = decide


local fizzleS = rx and rx.subject() or nil
local manaS = rx and rx.subject() or nil
local concentS = rx and rx.subject() or nil
if trigger then
   trigger([[^You fail to cast the spell ']], function() if fizzleS then fizzleS:onNext(nil) end end)
   trigger([[^You don't have enough mana\.$]], function() if manaS then manaS:onNext(nil) end end)
   trigger([[^You can't concentrate enough]], function() if concentS then concentS:onNext(nil) end end)
end



local function attempt(args, landed_pat)
   local p = __promise(function(resolve, _, onCancel)
      local subs = {}
      local timer = nil
      local done = false
      local function cleanup()
         for _, s in ipairs(subs) do s:unsubscribe() end
         subs = {}
         if timer and cancel then cancel(timer); timer = nil end
      end
      local function fin(v)
         if done then return end
         done = true; cleanup(); resolve(v)
      end
      if rx then subs[#subs + 1] = rx.fromTrigger(landed_pat):subscribe(function() fin("ok") end) end
      if fizzleS then subs[#subs + 1] = fizzleS:subscribe(function() fin("fail") end) end
      if manaS then subs[#subs + 1] = manaS:subscribe(function() fin("mana") end) end
      if concentS then subs[#subs + 1] = concentS:subscribe(function() fin("cant") end) end
      timer = after and after(CAST_WAIT, function() fin("miss") end) or nil
      onCancel(function() done = true; cleanup() end)
      send("c " .. args)
   end, "dcast-try")
   if __untrack_promise then __untrack_promise(p) end
   return p
end







local function do_dcast(args, opts)
   args = (args or ""):gsub("^%s+", ""):gsub("%s+$", "")
   if args == "" then echo("[dcast] usage: dcast <spell> [target]  — re-casts until it lands"); return nil end
   local spell = resolve_spell(args)
   if not spell then
      echo("\27[33m[dcast]\27[0m I don't know the landed line for '" .. (args:match("^%S+") or args) ..
      "', so I can't tell when it lands. Teach me: dcast.learn('<spell>', '<landed-line pattern>').")
      return nil
   end
   local landed_pat = registry[spell]
   local cap = (opts and opts.tries) or DEFAULT_TRIES
   return __promise(function(resolve, reject, onCancel)
      local n, mana_waits = 0, 0
      local waiting_mana, stopped = false, false
      local cur = nil
      local wait_timer = nil
      local try
      try = function()
         if stopped then return end
         n = n + 1
         cur = attempt(args, landed_pat)
         cur:andThen(function(r)
            local act, why = decide(r, n, cap)
            if act == "resolve" then
               echo(string.format("\27[32m[dcast]\27[0m '%s' landed%s.", args, n > 1 and (" (" .. tostring(n) .. " tries)") or ""))
               resolve(n)
            elseif act == "reject" then
               echo("\27[33m[dcast]\27[0m '" .. args .. "' — " .. (why or "") .. ".")
               reject(why or "failed")
            elseif act == "wait" then

               n = n - 1
               mana_waits = mana_waits + 1
               if mana_waits > MANA_CAP then
                  echo("\27[33m[dcast]\27[0m '" .. args .. "' — still out of mana after a long wait; stopping.")
                  reject("out of mana")
               else
                  if not waiting_mana then
                     waiting_mana = true
                     echo("\27[36m[dcast]\27[0m out of mana — waiting for it to regen, then I'll keep casting.")
                  end
                  wait_timer = after and after(MANA_WAIT, try) or nil
               end
            else
               waiting_mana = false
               try()
            end
         end)
      end
      onCancel(function()
         stopped = true
         if wait_timer and cancel then cancel(wait_timer) end
         if cur then cur:cancel() end
      end)
      try()
   end, "dcast " .. args)
end









local D = setmetatable({}, { __call = function(_, args, opts)
   return do_dcast(args, opts)
end, })

function D.learn(spell, pattern)
   spell = (spell or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
   if spell == "" or not pattern or pattern == "" then echo("[dcast] usage: dcast.learn('<spell>', '<landed-line pattern>')"); return end
   registry[spell] = pattern
   save_learned()
   echo("[dcast] learned '" .. spell .. "' → " .. pattern)
end
function D.forget(spell)
   spell = (spell or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
   registry[spell] = SEED[spell]
   save_learned()
   echo("[dcast] forgot '" .. spell .. "'" .. (registry[spell] and " (restored the built-in)" or ""))
end
function D.known()
   local names = {}
   for k in pairs(registry) do names[#names + 1] = k end
   table.sort(names)
   echo("[dcast] knows: " .. (next(names) and table.concat(names, ", ") or "(nothing)"))
end

dcast = D


if alias then
   alias([[^dcast (.+)$]], function(_, rest) return do_dcast(rest, nil) end)
   alias([[^dcast$]], function() return do_dcast("", nil) end)
end

_AA_TEST.dcast_registry = registry

doc(D, { name = "dcast", sig = "dcast('<spell> [target]')", group = "combat",
text = "\"Definite cast\": send `c <spell> [target]` and keep re-casting on a fizzle until the spell's own " ..
"landed line prints. Halts on out-of-mana or after ~25 misses; returns a promise so it chains/pipes. " ..
"It only casts spells whose landed line it knows — otherwise it tells you and stops. `dcast.learn(" ..
"'<spell>','<landed-pattern>')` teaches one (persists), `dcast.forget('<spell>')` / `dcast.known()`.", })
