


































state = state or {}
do
   local defaults = {
      classes = {},
      fighting = false,
      opponents = {},
      spells = {}, recover = false,
      lifetapping = false,
      inventory = {}, inv_known = false,
      equipment = {}, eq_known = false,
      group = {},
      exits = {},
      effects = {},
      action = 0,
      music = {},
      auto_assist = true,
   }
   for k, v in pairs(defaults) do if state[k] == nil then state[k] = v end end


end

_AA_TEST = _AA_TEST or {}



pcall(require, "_dsl")
if not __dsl then dofile("Scripts/Foundation/_dsl.lua") end








local dsl = __dsl
local field = dsl.field
local number = dsl.number
local flag = dsl.flag

local function boot(name) pcall(require, name) end
boot("_persist")
if not __persist then dofile("Scripts/Foundation/_persist.lua") end
local persist = __persist



trigger([[^kxw[tq]_supported$]], function() return send("set kxwt on") end)









local function __leading_ansi(s)
   local codes = {}
   local rest = s or ""
   while true do
      local c = rest:match("^(\27%[[%d;]*[A-Za-z])")
      if not c then break end
      codes[#codes + 1] = c
      rest = rest:sub(#c + 1)
   end
   return table.concat(codes)
end






local kxwt_ring = {}
local KXWT_RING_MAX = 300






trigger([[^kxw[tq]_]], function(...)
   local a = { ... }
   kxwt_ring[#kxwt_ring + 1] = a[1]
   if #kxwt_ring > KXWT_RING_MAX then table.remove(kxwt_ring, 1) end
   return __leading_ansi(a[#a])
end, { priority = -100 })



local WALK = { ["0"] = "north", ["1"] = "east", ["2"] = "south", ["3"] = "west", ["4"] = "northeast",
["5"] = "southeast", ["6"] = "southwest", ["7"] = "northwest", ["20"] = "up", ["30"] = "down", }
local function walk_name(code) return WALK[code] end





field([[^kxw[tq]_myname (.+)$]]):into("name")
field([[^kxw[tq]_gold (-?\d+)]]):into("gold"):as(number)


field([[^kxw[tq]_exp (-?\d+)]]):into("exp"):as(number)
field([[^kxw[tq]_expcap (-?\d+)]]):into("expcap"):as(number)
field([[^kxw[tq]_rshort (.+)$]]):into("room_name")
field([[^kxw[tq]_area \d+ (.+)$]]):into("area")
field([[^kxw[tq]_terrain (\d+)]]):into("terrain"):as(number)
field([[^kxw[tq]_precipitation (\d+)]]):into("precip"):as(number)


field([[^kxw[tq]_action (\d+)]]):into("action"):as(number)
field([[^kxw[tq]_walkdir (\d+)]]):into("walkdir"):via(walk_name)











local kxwt_tbl = {}
kxwt = kxwt_tbl

kxwt_tbl.dump = function(n)
   n = tonumber(n) or 15
   if (n) < 1 then n = 15 end
   local nn = n
   if #kxwt_ring == 0 then echo("[kxwt] no kxwt lines captured yet"); return end
   local first = math.max(1, #kxwt_ring - nn + 1)
   echo(string.format("[kxwt] last %d of %d captured kxwt lines:", #kxwt_ring - first + 1, #kxwt_ring))
   for i = first, #kxwt_ring do echo("  " .. kxwt_ring[i]) end
end

doc(kxwt_tbl.dump, { name = "kxwt.dump", sig = "kxwt.dump([n])", group = "protocol",
text = "Show the last n (default 15) captured kxwt_ protocol lines — the machinery normally hidden from the display.", })


setmetatable(kxwt_tbl, { __call = function(_, args)
   args = (args or ""):match("^%s*(.-)%s*$")
   local verb = (args:match("^%S*") or ""):lower()
   local rest = args:match("^%S*%s+(.*)$") or ""
   if verb == "" or verb == "dump" or verb:match("^%d+$") then
      kxwt_tbl.dump(tonumber(rest) or tonumber(verb))
   else
      echo("[kxwt] commands: kxwt.dump([n])")
   end
end, })







state.classes = state.classes or {}




local CLASSES_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/classes.lua"
local function save_classes()
   local parts = {}
   local classes = state.classes
   for name, c in pairs(classes) do
      local cc = c
      local micro = cc.micro
      local micro_s = micro and string.format(",micro={done=%d,total=%d}", (micro.done) or 0, (micro.total) or 0) or ""
      parts[#parts + 1] = string.format("[%q]={level=%d,cost=%d%s}", name, (cc.level) or 0, (cc.cost) or 0, micro_s)
   end
   persist.write(CLASSES_FILE, "return {" .. table.concat(parts, ",") .. "}")
end



local classes_save_timer = nil
local function schedule_classes_save()
   if cancel and classes_save_timer then cancel(classes_save_timer) end
   classes_save_timer = after(2, save_classes)
end

if not next(state.classes) then
   local t = persist.load(CLASSES_FILE)
   if type(t) == "table" then state.classes = t end
end

trigger([[^Class +Level +.*Exp Cost]], function() state.classes = {} end)





trigger([[^(Mage|Cleric|Thief|Warrior|Necromancer|Druid) +(\d+)(?: +(\d+)/ *(\d+))? +(\d+) +\( *\d+%\)]],
function(_, cls, lvl, mdone, mtotal, cost)
   local micro = (mdone and mtotal) and { done = tonumber(mdone), total = tonumber(mtotal) } or nil
   local classes = state.classes
   classes[cls] = { level = tonumber(lvl), cost = tonumber(cost), micro = micro }
   schedule_classes_save()
end)



field([[^kxw[tq]_prompt (\d+) (\d+) (\d+) (\d+) (\d+) (\d+)]]):
into("hp", "maxhp", "mana", "maxmana", "stam", "maxstam"):as(number):
then_(function() if __recovery_on_vitals then __recovery_on_vitals() end end)



local function set_position(p)
   local changed = (state.position ~= p)
   state.position = p
   if __recovery_on_position then __recovery_on_position(p, changed) end
end
if _AA_TEST then _AA_TEST.set_position = set_position end
trigger([[^kxw[tq]_position (.+)$]], function(_, p) set_position(p) end)






trigger([[^You stand up\.]], function() set_position("standing") end)
trigger([[^You are already standing]], function() set_position("standing") end)
trigger([[^You scramble to your feet]], function() set_position("standing") end)
trigger([[^You sit down and rest]], function() set_position("resting") end)
trigger([[^You wake up and begin resting]], function() set_position("resting") end)
trigger([[^You are (?:already )?resting]], function() set_position("resting") end)
trigger([[^You sit down\.]], function() set_position("sitting") end)
trigger([[^You are (?:already )?sitting]], function() set_position("sitting") end)
trigger([[^You go to sleep\.]], function() set_position("sleeping") end)
trigger([[^You are (?:already sound )?asleep]], function() set_position("sleeping") end)
trigger([[^You kneel]], function() set_position("kneeling") end)





local function note_room(nid, nx, ny, nz, np)
   local oc = state.room_coord
   local moved = (state.room_id ~= nid) or
   not oc or oc[1] ~= nx or oc[2] ~= ny or oc[3] ~= nz or oc[4] ~= np
   state.room_id = nid
   state.room_coord = { nx, ny, nz, np }
   if moved and __recovery_cancel then __recovery_cancel("moved") end
end


trigger([[^kxw[tq]_rvnum (-?\d+) -?\d+ -?\d+ (-?\d+) (-?\d+) (-?\d+) (\d+)]], function(_, vnum, x, y, z, plane)
   note_room(tonumber(vnum), tonumber(x), tonumber(y), tonumber(z), tonumber(plane))
end)
if _AA_TEST then _AA_TEST.note_room = note_room end






trigger([=[^\[Exits: (.*?)\]]=], function(_, list)
   local set = {}
   for dir in (list or ""):gmatch("%a+") do set[dir:lower()] = true end
   state.exits = set
end)



alias([[^dsac (.+)$]], function(_, t)
   t = t:gsub("^%s+", ""):gsub("%s+$", "")
   send("drop " .. t)
   send("sac " .. t)
end)





local MAINTAINABLE = {}
for _, name in ipairs({
      "armor aegis", "detect invisibility", "detect evil", "infravision", "sense life", "fly",
      "water breathing", "darken", "detect undead", "dread portent", "unburden", "walk on water",
      "feather fall",
   }) do    MAINTAINABLE[name] = true end





local function maybe_maintain(s)
   local maintained = (state.maintained) or {}
   state.maintained = maintained
   if MAINTAINABLE[(s or ""):lower()] and not maintained[s] then
      maintained[s] = true
      send("maintain " .. s)
   end
end


trigger([[^kxw[tq]_spellup (.+)$]], function(_, s)
   local spells = state.spells
   spells[s] = true
   maybe_maintain(s)
   if __recovery_on_spellup then __recovery_on_spellup(s) end
end)
trigger([[^kxw[tq]_spelldown (.+)$]], function(_, s)
   local spells = state.spells
   spells[s] = nil
   local maintained = state.maintained
   if maintained then maintained[s] = nil end
   if __recovery_on_spelldown then __recovery_on_spelldown(s) end
end)









state.group_flags = state.group_flags or {}
local gflag_capturing, gflag_buf = false, {}



trigger([[^kxw[tq]_group_start$]], function() gflag_capturing = true; gflag_buf = {} end)
trigger([[^kxw[tq]_group (\d+) (\d+) (\d+) (\d+) (\d+) (\d+) (\S+) (.+)$]],
function(_, _chp, _mhp, _cm, _mm, _cs, _ms, flags, name)
   if not gflag_capturing then return end
   gflag_buf[name] = flags
end)
trigger([[^kxw[tq]_group_end$]], function()
   if not gflag_capturing then return end
   gflag_capturing = false
   state.group_flags = gflag_buf


   local group = (state.group) or {}
   for _, m in ipairs(group) do
      local mm = m
      if gflag_buf[mm.name] then mm.flags = gflag_buf[mm.name] end
   end
   if on_update then on_update() end
end)




trigger([[^kxw[tq]_time (\d+) (\S+) (\S+) (\S+)$]], function(_, _mins, part, clock, ampm)
   state.daypart = part; state.clock = clock .. " " .. ampm
end)
field([[^kxw[tq]_sky (\d+) (\d+) (\d+)]]):
into("outdoors", "sky_visible", "overcast"):as(flag)



trigger([[^kxw[tq]_rvnum ]], function() state.action = 0 end)




trigger([[^kxw[tq]_event (\S+) ?(.*)$]], function(_, kw, data)
   echo("\27[1;33m★ " .. kw .. (data ~= "" and (": " .. data) or "") .. "\27[0m")
end)
trigger([[^kxw[tq]_pdeath (.+)$]], function(_, n) echo("\27[1;31m☠ " .. n .. " has DIED!\27[0m") end)
trigger([[^kxw[tq]_ydeath (.+)$]], function(_, n) echo("\27[31m☠ your " .. n .. " has died.\27[0m") end)
trigger([[^kxw[tq]_gdeath (.+)$]], function(_, n) echo("\27[31m☠ " .. n .. " (a group minion) has died.\27[0m") end)







state.effects = state.effects or {}
trigger([[^kxw[tq]_spst (.+)$]], function(_, s)
   local effects = state.effects
   local name, rest = s:match("^(.-),%s*(.+)$")
   if name then effects[name] = rest else effects[s] = "" end
end)







function on_connect()
   state.spells = {}
   state.effects = {}
   state.opponents = {}
   state.maintained = {}
end













local function parse_affect_row(line)
   local name, lvl = (line or ""):match("^Spell '(.-)', .- remaining, level (%d+)")
   if not name then return nil end
   return { name = name, level = tonumber(lvl) }
end


local function affects_to_spells(rows)
   local fresh = {}
   for _, e in ipairs(rows or {}) do fresh[e.name] = { level = e.level } end
   return fresh
end

local affects_capturing, affects_buf = false, nil
trigger([[^You are affected by:]], function() affects_capturing = true; affects_buf = {} end)
trigger([[^Spell '.+', .+ remaining, level \d+]], function(line)
   if affects_capturing then
      local r = parse_affect_row(line)
      if r then affects_buf[#affects_buf + 1] = r end
   end
end)
trigger([[.*]], function(line)
   if not affects_capturing then return end
   if line:match("^Spell '") or line:match("^You are affected by") then return end
   affects_capturing = false
   state.spells = affects_to_spells(affects_buf)
end)





local LVL_ABBR = { Ma = "Mage", Cl = "Cleric", Th = "Thief", Wa = "Warrior", Nc = "Necromancer", Dr = "Druid" }
local function parse_levels(rest)
   local out = {}
   for ab, lv in (rest or ""):gmatch("(%a%a)%s+(%d+)") do
      if LVL_ABBR[ab] then out[LVL_ABBR[ab]] = tonumber(lv) end
   end
   return out
end
trigger([[^Your levels are: (.+)$]], function(_, rest)
   local classes = state.classes
   for full, lv in pairs(parse_levels(rest)) do
      classes[full] = classes[full] or {};
      (classes[full]).level = lv
   end
end)

_AA_TEST.parse_affect_row = parse_affect_row
_AA_TEST.affects_to_spells = affects_to_spells
_AA_TEST.parse_levels = parse_levels
_AA_TEST.maybe_maintain = maybe_maintain
_AA_TEST.MAINTAINABLE = MAINTAINABLE













local SPELL_DB = {
   ["ball lightning"] = { mana = 13, tier = "massive" },
   ["blaze"] = { mana = 5, tier = "moderate" },
   ["blizzard"] = { mana = 35, tier = "massive", area = true },
   ["blue dart"] = { mana = 4, tier = "low" },
   ["burning hands"] = { mana = 5, tier = "moderate" },
   ["call thunder"] = { mana = 15, tier = "massive" },
   ["chasten"] = { mana = 7, tier = "low" },
   ["chill touch"] = { mana = 5, tier = "low" },
   ["coffin"] = { mana = 51, tier = "massive" },
   ["coldfire"] = { mana = 6, tier = "minor" },
   ["color spray"] = { mana = 6, tier = "low" },
   ["condemnation"] = { mana = 34, tier = "high" },
   ["cone of cold"] = { mana = 16, tier = "high" },
   ["crystal spear"] = { mana = 12, tier = "high" },
   ["death and decay"] = { mana = 27, tier = "high", area = true },
   ["dust devil"] = { mana = 16, tier = "moderate" },
   ["earthquake"] = { mana = 19, tier = "moderate", area = true },
   ["field of the grasping dead"] = { mana = 35, tier = "low", area = true },
   ["fireball"] = { mana = 10, tier = "high" },
   ["firefield"] = { mana = 10, tier = "moderate", area = true },
   ["fireweb"] = { mana = 13, tier = "moderate" },
   ["fist of the earth"] = { mana = 14, tier = "moderate" },
   ["flamestrike"] = { mana = 15, tier = "moderate" },
   ["frost bite"] = { mana = 13, tier = "high" },
   ["frostflower"] = { mana = 4, tier = "moderate", area = true },
   ["fury of the heavens"] = { mana = 15, tier = "massive", area = true },
   ["gust of wind"] = { mana = 8, tier = "minor" },
   ["hailstone"] = { mana = 20, tier = "high" },
   ["harm"] = { mana = 21, tier = "high" },
   ["ice fog"] = { mana = 23, tier = "high", area = true },
   ["icebolt"] = { mana = 8, tier = "moderate" },
   ["inflict suffering"] = { mana = 13, tier = "moderate" },
   ["inflict wounds"] = { mana = 4, tier = "minor" },
   ["kaleidoscope"] = { mana = 16, tier = "high" },
   ["landslide"] = { mana = 39, tier = "massive" },
   ["lightning bolt"] = { mana = 9, tier = "moderate" },
   ["maelstrom"] = { mana = 40, tier = "massive", area = true },
   ["mage hand"] = { mana = 17, tier = "moderate" },
   ["magic missile"] = { mana = 2, tier = "minor" },
   ["noxious cloud"] = { mana = 12, tier = "moderate" },
   ["prism"] = { mana = 6, tier = "moderate" },
   ["radiant orbs"] = { mana = 7, tier = "minor" },
   ["riptide"] = { mana = 25, tier = "moderate" },
   ["rotting sphere"] = { mana = 27, tier = "moderate" },
   ["sacred touch"] = { mana = 15, tier = "massive" },
   ["sandstorm"] = { mana = 20, tier = "minor", area = true },
   ["scorch"] = { mana = 8, tier = "moderate" },
   ["shard storm"] = { mana = 18, tier = "high", area = true },
   ["shards"] = { mana = 4, tier = "moderate" },
   ["shocking grasp"] = { mana = 5, tier = "moderate" },
   ["shower of sparks"] = { mana = 4, tier = "low" },
   ["sickening touch"] = { mana = 10, tier = "moderate" },
   ["solar flare"] = { mana = 10, tier = "high" },
   ["spectral claw"] = { mana = 20, tier = "moderate" },
   ["static blast"] = { mana = 5, tier = "minor" },
   ["storm of roses"] = { mana = 29, tier = "high", area = true },
   ["sunbeam"] = { mana = 8, tier = "low" },
   ["sunblind"] = { mana = 30, tier = "moderate" },
   ["sunstorm"] = { mana = 85, tier = "massive", area = true },
   ["tarrants spectral hand"] = { mana = 12, tier = "low" },
   ["tempest"] = { mana = 20, tier = "low", area = true },
   ["thistles"] = { mana = 6, tier = "low" },
   ["thunder seeds"] = { mana = 7, tier = "low" },
}


local SPELL_TIER = { minor = 1, low = 2, moderate = 3, high = 4, massive = 5 }











local function parse_spell_row(line)
   local name, prof, pctv = (line or ""):match("^(%S.-%S)%s%s+(%S.-)%s+(%d+)%%")
   if not name then return nil end
   return { name = name, prof = prof, pct = tonumber(pctv) }
end



local function classify_spell(name)
   local e = SPELL_DB[(name or ""):lower()]
   if e then return true, e.mana, e.tier, e.area end
   return false, nil, nil, nil
end




local function annotate_spells(rows)
   local out = {}
   for _, r in ipairs(rows or {}) do
      if not (r.prof and r.prof:lower():match("not learned")) then
         local off, mana, tier, area = classify_spell(r.name)
         out[#out + 1] = { name = r.name, prof = r.prof, pct = r.pct,
offensive = off, mana = mana, tier = tier, area = area, }
      end
   end
   return out
end





local function parse_spells_block(block)
   local rows = {}
   local capturing = false
   for line in (block or ""):gmatch("[^\n]+") do
      if line:match("^You know the following spells:") then
         capturing = true
      elseif capturing then
         local r = parse_spell_row(line)
         if r then rows[#rows + 1] = r
         elseif line:match("^%-+%s*$") or line:match("^%s*%u%a+%s*$") then
         else break end
      end
   end
   return annotate_spells(rows)
end




local spells_capturing, spells_buf = false, nil
trigger([[^You know the following spells:]], function() spells_capturing = true; spells_buf = {} end)
trigger([[.*]], function(line)
   if not spells_capturing then return end
   if line:match("^You know the following spells:") then return end
   local r = parse_spell_row(line)
   if r then spells_buf[#spells_buf + 1] = r; return end
   if line:match("^%-+%s*$") or line:match("^%s*%u%a+%s*$") then return end
   spells_capturing = false
   state.spells_known = annotate_spells(spells_buf)
end)

_AA_TEST.SPELL_DB = SPELL_DB
_AA_TEST.SPELL_TIER = SPELL_TIER
_AA_TEST.parse_spell_row = parse_spell_row
_AA_TEST.classify_spell = classify_spell
_AA_TEST.annotate_spells = annotate_spells
_AA_TEST.parse_spells_block = parse_spells_block




local inv_capturing = false
trigger([[^You are carrying:]], function() inv_capturing = true; state.inventory = {}; state.inv_known = true end)
trigger([[.*]], function(line)
   if not inv_capturing then return end
   local t = (line:gsub("^%s+", ""):gsub("%s+$", ""))
   if t:match("^You are carrying") then return end
   if t == "" or t:match("^<%d+hp") or t:match("^kxw[tq]_") or
      t:match("^You are using") or t:match("^You are wearing") or t:match("^You can't carry") then
      inv_capturing = false




      state.inv_seq = ((state.inv_seq) or 0) + 1
      if on_inventory then pcall(on_inventory) end
      return
   end
   local low = t:lower()
   local inventory = state.inventory
   if low ~= "nothing." and low ~= "nothing" then inventory[#inventory + 1] = t end
end)



local eq_capturing = false
trigger([[^You are using:]], function() eq_capturing = true; state.equipment = {}; state.eq_known = true end)
trigger([[^You are wearing:]], function() eq_capturing = true; state.equipment = {}; state.eq_known = true end)
trigger([[.*]], function(line)
   if not eq_capturing then return end
   local t = (line:gsub("^%s+", ""):gsub("%s+$", ""))
   if t:match("^You are using") or t:match("^You are wearing") then return end
   if t == "" or t:match("^<%d+hp") or t:match("^kxw[tq]_") or t:match("^You are carrying") then
      eq_capturing = false; return
   end
   local low = t:lower()
   local equipment = state.equipment
   if low ~= "nothing." and low ~= "nothing" then equipment[#equipment + 1] = t end
end)


function describe_state()
   local out = {}
   out[#out + 1] = "name: " .. ((state.name) or "unknown")
   if state.hp then
      out[#out + 1] = string.format("hp: %d/%d, mana: %d/%d, stamina: %d/%d%s",
      state.hp, (state.maxhp) or 0, (state.mana) or 0, (state.maxmana) or 0,
      (state.stam) or 0, (state.maxstam) or 0, (__ready and __ready(nil)) and " (ready)" or "")
   end
   if state.position then out[#out + 1] = "position: " .. (state.position) end
   if state.room_name then out[#out + 1] = "room: " .. (state.room_name) end
   if state.area then out[#out + 1] = "area: " .. (state.area) end
   if state.fighting then
      out[#out + 1] = string.format("combat: fighting %s (%d%%)", (state.fight_name) or "?", (state.fight_pct) or 0)
   elseif engaged() then

      local opps = active_opponents()
      local names = {}
      for _, o in ipairs(opps) do
         local oo = o
         names[#names + 1] = (oo.name) .. (oo.pct and string.format(" (~%d%%)", oo.pct) or "")
      end
      out[#out + 1] = "combat: ENGAGED (nomelee — no exact target data)" ..
      (#names > 0 and (": " .. table.concat(names, ", ")) or "")
   else
      out[#out + 1] = "combat: not fighting"
   end
   local sp = {}
   local spells = state.spells
   for k in pairs(spells) do sp[#sp + 1] = k end
   if #sp > 0 then out[#out + 1] = "active spells: " .. table.concat(sp, ", ") end


   if state.regen and (state.regen).hp then
      local r = state.regen
      out[#out + 1] = string.format("regen per tick: %d hp, %d mana, %d move (while %s%s)",
      r.hp, (r.mana) or 0, (r.move) or 0, (r.position) or (state.position) or "standing",
      state.sharp and ", sharp" or "")
   end


   if state.gold then out[#out + 1] = "gold: " .. tostring(state.gold) end
   out[#out + 1] = "recovery mode: " .. (state.recover and "on" or "off")
   return table.concat(out, "\n")
end





function game_command_reference()
   return [[MOVEMENT: type a direction or its abbreviation — north/n south/s east/e west/w up/u down/d northeast/ne northwest/nw southeast/se southwest/sw. 'recall' returns to your waypoint; 'waypoint' travels between set waypoints.
LOOKING/INFO: 'look' (room), 'look <thing>', 'exits', 'hp', 'score', 'inventory' (i/inv), 'equipment' (what you're wearing/wielding), 'spells', 'skills', 'consider <target>' (gauge a fight), 'who', 'help <topic>'.
ITEMS/GEAR: 'get <item>' / 'get all' / 'get all corpse' (loot) / 'get <item> <container>'; 'drop <item>'; 'put <item> in <container>'; 'wear <armor>'; 'wield <weapon>'; 'use <item>' (auto-pick best slot); 'remove <item>' (take off, to swap to better gear); 'donate <item>'.
COMBAT: 'kill <target>' / 'attack <target>'; 'flee' or 'run' to escape; class skills 'kick', 'trip', 'backstab'. Check 'hp' when hurt.
SPELLS: cast '<spell name>' [target]. Names may be abbreviated. With no target while fighting, it targets your current enemy; a self/buff spell with no target hits you. Only cast attack spells when there's an enemy. 'spells' lists yours.
RECOVER: 'rest' or 'sleep' to heal hp/mana/stamina; 'stand' or 'wake' when recovered.
PROGRESS: at a trainer, 'level', 'train', and 'practice' improve you; 'slist' shows newly available spells/skills.]]
end










function test() return run_test_suite() end
doc("test", { sig = "test() -> (pass, fail)", group = "scripts",
text = "Run the Lua spec suite (Scripts/tests/*.lua) against the live, currently-loaded scripts and report pass/fail per case — verify an edit right after pilot.reload().", })
function run_test_suite()
   local pass, fail = 0, 0
   local ok, err = pcall(function()
      dofile("Scripts/Foundation/testing.lua")
      local reset_tests_fn = (_G).reset_tests
      reset_tests_fn()


      local files = {}
      local p = io.popen and io.popen("ls Scripts/tests/*.lua 2>/dev/null")
      if p then for f in p:lines() do files[#files + 1] = f end; p:close() end
      if #files == 0 then
         local g = _G
         g.TEST_SPECS = g.TEST_SPECS or { "Scripts/tests/hud_spec.lua", "Scripts/tests/aipilot_spec.lua" }
         for _, f in ipairs(g.TEST_SPECS) do
            local fh = io.open(f, "r")
            if fh then fh:close(); files[#files + 1] = f end
         end
      end
      table.sort(files)
      if #files == 0 then echo("[test] no spec files found under Scripts/tests/"); return nil end
      echo(string.format("[test] running %d spec file(s)…", #files))
      for _, f in ipairs(files) do
         local okf, e = pcall(dofile, f)
         if not okf then
            fail = fail + 1
            echo("[test] \27[31mfailed to load " .. f .. ": " .. tostring(e) .. "\27[0m")
         end
      end
      local run_tests_fn = (_G).run_tests
      local p2, fl = run_tests_fn()
      pass, fail = pass + p2, fail + fl
      return nil
   end)
   if not ok then echo("[test] \27[31mharness error: " .. tostring(err) .. "\27[0m"); return 0, 1 end
   return pass, fail
end
