






































state = state or {}
_EVENTS_TEST = _EVENTS_TEST or {}

local function boot(n) pcall(require, n) end
boot("_rx")
if not __rx then dofile("Scripts/Foundation/_rx.lua") end
local rx = __rx













if rx then
   local T = rx.fromTrigger


   onSpellUp = T([[^kxw[tq]_spellup (.+)$]]):map(function(c) return c[1] end)
   onSpellDown = T([[^kxw[tq]_spelldown (.+)$]]):map(function(c) return c[1] end)
   onMinionDied = T([[^kxw[tq]_ydeath (.+)$]]):map(function(c) return c[1] end)
   onEnemyDied = T([[^kxw[tq]_mdeath (.+)$]]):map(function(c) return c[1] end)





   onCryOfVictory = T([[^(.+) is DEAD!$]]):
   map(function(c) return c[1] end):
   filter(function(name) return (engaged and engaged()) and not (is_ally and is_ally(name)) end)




   local function tag(pattern, spell)
      return T(pattern):map(function(_) return spell end)
   end
   onSpellLanded = (rx).merge(
   tag([[^A .* bolt of lightning leaps from you to ]], "lightning"),
   tag([[^You create and magically throw bolts of ice at ]], "icebolt"),
   tag([[^You (?:conjure and )?throw a .* fireball at ]], "fireball"),
   tag([[^You use a small crystal to focus your powers and throw a confusing wash of color and force at ]], "prism"),
   tag([[^Spiked flowers of ice quickly form on everything in a ring around you!$]], "frostflower"),
   tag([[^A shower of .* sparks suddenly engulfs]], "shower"),
   tag([[^An ethereal hand appears and attacks .+ from behind!$]], "tarrants"),
   tag([[^You tap your life, and .* toward ]], "bloodmist"))










   local tickSub = rx.subject()
   T([[^kxw[tq]_prompt (\d+) (\d+) (\d+) (\d+) (\d+) (\d+)]]):subscribe(function(c) tickSub:onNext(c) end)
   local tickS = tickSub:asObservable()
   _EVENTS_TEST.tick = function() tickSub:onNext({}) end

   local MANA_LOW_FRAC = 0.2
   local HP_LOW_FRAC = 0.3

   local function mana_ratio()
      local m, mm = state.mana, state.maxmana
      if not m or not mm or mm <= 0 then return nil end
      return m / mm
   end
   local function hp_ratio()
      local h, mh = state.hp, state.maxhp
      if not h or not mh or mh <= 0 then return nil end
      return h / mh
   end









   local function combat_edge()
      return tickS:
      map(function(_) return (engaged and engaged()) or false end):
      scan(function(acc, cur) return { prev = acc.cur, cur = cur } end, { prev = nil, cur = nil })

   end
   onCombatStart = combat_edge():
   filter(function(e) return e.prev ~= nil and e.prev ~= e.cur and e.cur end):
   map(function(e) return e.cur end)

   onCombatEnd = combat_edge():
   filter(function(e) return e.prev ~= nil and e.prev ~= e.cur and not e.cur end):
   map(function(e) return e.cur end)








   onManaLow = tickS:
   map(function(_) local r = mana_ratio(); return { low = (r ~= nil and r < MANA_LOW_FRAC), ratio = r } end):
   distinctUntilChanged(function(a, b) return a.low == b.low end):
   filter(function(r) return r.low end):
   map(function(r) return r.ratio end)

   onHPLow = tickS:
   map(function(_) local r = hp_ratio(); return { low = (r ~= nil and r < HP_LOW_FRAC), ratio = r } end):
   distinctUntilChanged(function(a, b) return a.low == b.low end):
   filter(function(r) return r.low end):
   map(function(r) return r.ratio end)


   onPostureChange = T([[^kxw[tq]_position (.+)$]]):
   map(function(c) return c[1] end):
   distinctUntilChanged()





   onNewOpponent = T([[^kxw[tq]_fighting (\d+) \S+ (.+)$]]):
   map(function(c) return c[2] end):
   distinctUntilChanged()








   local function current_tank_name()
      for name, f in pairs((state.group_flags) or {}) do
         if f:find("M", 1, true) and f:find("T", 1, true) then return name end
      end
      return nil
   end
   local TANK_DEATH_WINDOW = 6
   local tank_name = nil
   local tank_ydeath_at = nil
   local tankDownS = rx.subject()

   local function on_tank_ydeath(_) tank_ydeath_at = os.time() end
   local function on_tank_group_end(_)
      local t = current_tank_name()
      if t then tank_name = t; return end
      if tank_name then
         local recent = tank_ydeath_at and (os.time() - tank_ydeath_at) <= TANK_DEATH_WINDOW
         local dead = tank_name
         tank_ydeath_at, tank_name = nil, nil
         if recent then tankDownS:onNext(dead) end
      end
   end
   T([[^kxw[tq]_ydeath ]]):subscribe(on_tank_ydeath)
   T([[^kxw[tq]_group_end$]]):subscribe(on_tank_group_end)
   onTankDown = tankDownS:asObservable()




   _EVENTS_TEST.mana_ratio = mana_ratio
   _EVENTS_TEST.hp_ratio = hp_ratio
   _EVENTS_TEST.current_tank_name = current_tank_name
   _EVENTS_TEST.tank_ydeath = function() on_tank_ydeath({}) end
   _EVENTS_TEST.tank_group_end = function() on_tank_group_end({}) end
   _EVENTS_TEST.tank_death_window = TANK_DEATH_WINDOW
   _EVENTS_TEST.reset_tank = function() tank_name, tank_ydeath_at = nil, nil end
end
