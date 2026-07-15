





























state = state or {}




local function boot(name) pcall(require, name) end
boot("_rx"); if not __rx then dofile("Scripts/_rx.lua") end
boot("_persist"); if not __persist then dofile("Scripts/_persist.lua") end
local persist = __persist
local rx = __rx




local trigger_c = trigger
















local cfg = {
   home = os.getenv("HOME") or "",

   max_tokens = 900,


   think_prefill = "<think>\n\n</think>\n\n",


   model = os.getenv("EQ_MODEL") or "qwen3.6-27b-mlx@8bit",
   look_wait = 1.0,
   detail_ceiling = 1000,



   single_call_max = 4,




   id_gap = 0.4,
   id_timeout = 4.0,
   id_combat_retry = 2.0,
}
cfg.dir = cfg.home .. "/Documents/MudClient"
cfg.cache_file = cfg.dir .. "/equipment_items.lua"



















































































































_EQUIP = _EQUIP or { items = {}, session = {}, gen = 0 }
_EQUIP.epoch = (_EQUIP.epoch or 0) + 1
local EPOCH = _EQUIP.epoch
local S = _EQUIP




if S.idq then
   if S.idq.out_item then
      echo("[eq] reload interrupted the identify pass — '" .. tostring(S.idq.out_item) ..
      "' may still be OUT of its container; check your inventory and put it back.", "red")
   end
   S.idq = nil
end
S.id_expect = nil
S.id_cap = nil
S.id_resolve = nil



local items = S.items
local session = S.session

local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function strip_ansi(s) return ((s or ""):gsub("\27%[[%d;]*%a", "")) end
local function now() return os.time() end

local ARTICLE = { a = true, an = true, the = true, some = true, pair = true, of = true }






local FLAG_MARKERS = { glow = true, glowing = true, hum = true, humming = true, light = true,
rare = true, artifact = true, invis = true, invisible = true,
magic = true, magical = true, unique = true, }
local CANON_FLAG = { glowing = "glow", humming = "hum", invisible = "invis", magical = "magic" }


local function split_flags(s, flags)
   flags = flags or {}
   s = trim(s or "")
   while true do
      local body, mark = s:match("^(.-)%s*%(([%a%s]+)%)$")
      if not body or body == "" then break end
      s = trim(body)
      local m = trim(mark):lower()
      flags[CANON_FLAG[m] or m:gsub("%s+", "_")] = true
   end
   return s, flags
end





local function norm_name(s)
   s = trim((strip_ansi(s):lower():gsub("%s+", " "):gsub("%.%s*$", "")))
   while true do
      local body, mark = s:match("^(.-)%s*%((%a+)%)$")
      if body and body ~= "" and FLAG_MARKERS[mark] then s = trim(body) else break end
   end
   s = s:gsub("^a ", ""):gsub("^an ", ""):gsub("^the ", ""):gsub("^some ", "")
   return trim(s)
end




local function first_kw(name)
   local clean = (name or ""):gsub("%b()", " ")
   local last = nil
   for w in clean:gmatch("%a+") do
      local lw = w:lower()
      if not ARTICLE[lw] and not FLAG_MARKERS[lw] then last = w end
   end
   return last or trim(name or "")
end




local CLASS_TO_STATE = { MAGE = "Mage", CLERIC = "Cleric", THIEF = "Thief", WARRIOR = "Warrior",
DRUID = "Druid", NECR = "Necromancer", NECROMANCER = "Necromancer", }
local ALIGN_FLAGS = { ANTI_GOOD = true, ANTI_EVIL = true, ANTI_NEUTRAL = true,
ANTIGOOD = true, ANTIEVIL = true, ANTINEUTRAL = true, EVIL = true, GOOD = true, }










local function parse_identify(block)
   if not block then return nil end
   block = strip_ansi(block)
   local iname = block:match("Item:%s*'(.-)'")
   if not iname then return nil end
   local v = { item_name = iname, flags = {}, class_flags = {}, align_flags = {},
wear = {}, affects = {}, raw = trim(block), }
   for raw in (block .. "\n"):gmatch("(.-)\n") do
      local L = trim(raw)
      if L:match("^Weight:") then
         v.weight = tonumber(L:match("Weight:%s*(%d+)"))
         v.size = L:match("Size:%s*(%S+)")
         local tot, lvl = L:match("Total levels:%s*(%d+)"), L:match("[^%a]Level:%s*(%d+)") or L:match("^Level:%s*(%d+)")
         if not lvl then lvl = L:match("Level:%s*(%d+)") end
         if tot then v.total_levels = tonumber(tot) end
         if lvl then v.level = tonumber(lvl) end
         if L:find("you can't use this", 1, true) then v.cant_use_yet = true end
         v.quality = L:match("Item Quality:%s*(.+)$")
      elseif L:match("^Type:") then
         v.type = L:match("^Type:%s*(%S+)")
         v.composition = trim(L:match("Composition:%s*(.-)%s*Defense:") or L:match("Composition:%s*(.+)$") or "")
         v.defense = tonumber(L:match("Defense:%s*(%d+)"))
      elseif L:match("^Weapon damage:") then
         local mn, mx, verb, str = L:match("Weapon damage:%s*(%d+)%s*to%s*(%d+)%s*average,%s*(%a+),%s*(%d+)%s*strength")
         if mn then v.weapon = { min = tonumber(mn), max = tonumber(mx), verb = verb, str = tonumber(str) } end
      elseif L:match("^Object is:") then
         for f in (L:match("^Object is:%s*(.*)$") or ""):gmatch("%S+") do
            v.flags[#v.flags + 1] = f
            if CLASS_TO_STATE[f] then v.class_flags[#v.class_flags + 1] = f end
            if ALIGN_FLAGS[f] then v.align_flags[#v.align_flags + 1] = f end
         end
      elseif L:match("^Wear locations are:") then
         for w in (L:match("^Wear locations are:%s*(.*)$") or ""):gmatch("%S+") do v.wear[#v.wear + 1] = w end
      elseif L:match("^Affects:") then
         local stat, by = L:match("^Affects:%s*(.-)%s+by%s+(.+)$")
         if stat then v.affects[#v.affects + 1] = { stat = trim(stat), by = trim(by) } end
      elseif L:match("^This item is bound") then
         v.bound = true
      elseif L:match("^You are carrying ") and not L:match("^You are carrying %d") then

         v.display = norm_name((L:gsub("^You are carrying ", "")))
      elseif L:match("^You are wearing ") then


         v.display = norm_name((L:gsub("^You are wearing ", "")))
      elseif L:match("^You are wielding ") then
         v.display = norm_name((L:gsub("^You are wielding ", "")))
      elseif L:match("to start using ") then
         v.display = v.display or norm_name(L:match("to start using (.+)$") or "")
      end
   end


   v.name = (v.display and v.display ~= "" and v.display) or norm_name(iname)
   return v
end




local function sorted(list, f)
   local out = {}
   for _, x in ipairs(list) do out[#out + 1] = f(x) end
   table.sort(out)
   return table.concat(out, ",")
end
local function fingerprint(v)
   local p = { "t=" .. (v.type or ""),
"lv=" .. tostring(v.level or "") .. "/" .. tostring(v.total_levels or ""),
"df=" .. tostring(v.defense or ""), }
   if v.weapon then
      p[#p + 1] = "wp=" .. tostring(v.weapon.min) .. "-" .. tostring(v.weapon.max) ..
      (v.weapon.verb or "") .. "/" .. tostring(v.weapon.str)
   end
   p[#p + 1] = "fl=" .. sorted(v.flags, function(x) return x end)
   p[#p + 1] = "wr=" .. sorted(v.wear, function(x) return x end)
   p[#p + 1] = "af=" .. sorted(v.affects, function(a) return a.stat .. "=" .. a.by end)
   return table.concat(p, "|")
end


local save_timer
local function save_items()
   persist.save(cfg.cache_file, items)
end


local function schedule_save()
   if cancel and save_timer then cancel(save_timer) end
   if after then save_timer = after(2, save_items) else save_items() end
end
local function load_items()
   local t = persist.load(cfg.cache_file)
   if type(t) == "table" then
      for k in pairs(items) do items[k] = nil end
      for k, val in pairs(t) do items[k] = val end
   end
end



local function ingest(v)
   if not v or not v.name or v.name == "" then return end
   v.fp = fingerprint(v)
   v.last_seen = now()
   local entry = items[v.name]
   if not entry then entry = { variants = {} }; items[v.name] = entry end
   if entry.variants[v.fp] then
      entry.variants[v.fp].last_seen = v.last_seen
   else
      entry.variants[v.fp] = v
   end
   session[v.name] = { fp = v.fp, variant = v, ts = v.last_seen }
   schedule_save()
end

















local function resolve_item(name)
   local key = norm_name(name)
   local sess = session[key]
   if sess then return { status = "session", variant = sess.variant, key = key } end
   local entry = items[key]
   if not entry then return { status = "unknown", key = key } end
   local vs = {}
   for _, v in pairs(entry.variants) do vs[#vs + 1] = v end
   if #vs == 0 then return { status = "unknown", key = key } end
   if #vs == 1 then return { status = "cached", variant = vs[1], key = key } end
   return { status = "multi", count = #vs, variants = vs, key = key }
end

















local function precheck_equip(v, char)
   local ok, reasons = true, {}
   if v.cant_use_yet then ok = false; reasons[#reasons + 1] = "level too high (game says: you can't use this yet)" end
   for _, cf in ipairs(v.class_flags) do
      local cls = CLASS_TO_STATE[cf] or cf
      if char.classes and not char.classes[cls] then
         ok = false; reasons[#reasons + 1] = "requires the " .. cls .. " class (you have none)"
      end
   end
   if char.alignment then
      for _, af in ipairs(v.align_flags) do
         local a = af:gsub("_", "")
         if a == "ANTIGOOD" and char.alignment == "good" then ok = false; reasons[#reasons + 1] = "ANTI_GOOD blocks your good alignment" end
         if a == "ANTIEVIL" and char.alignment == "evil" then ok = false; reasons[#reasons + 1] = "ANTI_EVIL blocks your evil alignment" end
         if a == "ANTINEUTRAL" and char.alignment == "neutral" then ok = false; reasons[#reasons + 1] = "ANTI_NEUTRAL blocks your neutral alignment" end
      end
   end
   if v.weapon and v.weapon.str and char.str and char.str < v.weapon.str then
      ok = false; reasons[#reasons + 1] = string.format("needs %d strength (you have %d)", v.weapon.str, char.str)
   end
   return { ok = ok, reasons = reasons }
end





local function parse_item_line(line)
   local L = trim(strip_ansi(line))
   if L == "" then return nil end
   if L:match("^<%d+hp") or L:match("^kxw[tq]_") or L:match("^%[the human typed%]") or L:match("BLOCKSEP") then return nil end
   if L:match("^You are ") or L:find("contains:", 1, true) or L:match("items? total%.?$") then return nil end
   L = L:gsub("^%(%s*%d+%s*%)%s*", "")
   local flags
   L, flags = split_flags(L, nil)
   local low = L:lower()
   if low == "" or low == "nothing" or low == "nothing." then return nil end
   return L, flags
end



local function parse_container_header(line)
   local L = trim(strip_ansi(line))
   local name = L:match("^%(.-%)%s*(.-)%s+contains:%s*$")
   return name and trim(name) or nil
end







local EQ_SLOTS = { head = true, neck = true, arms = true, wrist = true, hands = true, finger = true,
waist = true, legs = true, feet = true, held = true, weapon = true, shield = true,
back = true, ears = true, eyes = true, face = true, floating = true, body = true,
["on body"] = true, ["about body"] = true, }
local function parse_eq_line(line)
   local L = strip_ansi(line)
   local slot, rest = L:match("^(%a[%a ]-)%s+%-%s+(.+)$")
   if not slot then return nil end
   slot = trim(slot):lower()
   if not EQ_SLOTS[slot] then return nil end
   local flags = {}
   local col, tail = rest:match("^(%b())%s*(.+)$")
   if col then
      local m = trim(col:sub(2, -2)):lower()
      if m ~= "" then flags[CANON_FLAG[m] or m:gsub("%s+", "_")] = true end
      rest = tail
   end
   local item
   item, flags = split_flags(rest, flags)
   item = norm_name(item)
   if item == "" then return nil end
   return slot, item, flags
end





local function parse_shop_row(line)




   local L = trim(strip_ansi(line))

   local cat = L:match("^%[%s*Price%]%s*(.-)%s*%-%-%-")
   if cat then return { category = trim(cat) } end

   local price, lvl, name = L:match("^%[%s*(%d+)%]%s*%(lvl%s*(%d+)%)%s*(.+)$")
   if price then return { price = tonumber(price), level = tonumber(lvl), name = trim(name) } end


   local dcat = L:match("^%s*([%a][%a '/&%-]-)%s*%-%-%-%-+%s*$")
   if dcat then return { category = trim(dcat) } end



   local flag, kind, num, dname = L:match("^%s*(%a?)%s*%(%s*(%a+)%s*(%d+)%s*%)%s*(.+)$")
   if kind == "lvl" or kind == "tot" then
      return { price = 0, free = true, level = tonumber(num), level_kind = kind,
name = trim(dname), flag = (flag ~= "" and flag or nil), }
   end
   return nil
end










local function parse_shop_list(text)
   local out = { rows = {} }
   local cur_cat = nil
   for raw in ((text or "") .. "\n"):gmatch("(.-)\n") do
      local L = strip_ansi(raw)
      if L:find("no shopkeeper", 1, true) or L:find("nothing here to list", 1, true) then out.no_shop = true end
      if L:find("spell castings may be purchased", 1, true) then out.spell_shop = true end
      local seller = L:match("^(.-) tells you, 'The following items are available")
      if seller then out.seller = seller end
      if L:find("up for grabs", 1, true) then out.donation = true end
      local r = parse_shop_row(L)
      if r then
         if r.category then cur_cat = r.category
         else r.category = cur_cat; out.rows[#out.rows + 1] = r
if r.free then out.donation = true end
         end
      end
   end
   return out
end




local CONSUMABLE_KW = { "scroll", "potion", "wand", "food", "drink", "bread", "waterskin", "ration",
"torch", "lantern", " oil", "bandage", "spellcomp", "vial", "elixir", "mushroom",
"pill", "cont light", "map of", "recall stone", }
local function is_consumable(name)
   local n = (name or ""):lower()
   for _, kw in ipairs(CONSUMABLE_KW) do if n:find(kw, 1, true) then return true end end
   return false
end

















local function shortlist_shop(parsed, fit, ceiling)
   ceiling = ceiling or math.huge
   local function unfit(r)
      if not (fit and r.level) then return false end
      if r.level_kind == "tot" then return fit.total ~= nil and r.level > fit.total
      else return fit.level ~= nil and r.level > fit.level end
   end
   local buckets = {}
   local order = {}
   local skipped = {}
   for _, r in ipairs(parsed.rows or {}) do
      local cat = (r.category or ""):lower()
      local wearable = cat:find("worn") or cat:find("wield") or cat:find("held") or cat:find("shield")
      if not wearable or is_consumable(r.name) or unfit(r) then
         skipped[#skipped + 1] = r
      else
         local key = r.category or "?"
         if not buckets[key] then buckets[key] = {}; order[#order + 1] = key end
         local b = buckets[key]; b[#b + 1] = r
      end
   end
   local kept = {}
   local round = 1
   while #kept < ceiling do
      local added = false
      for _, key in ipairs(order) do
         local r = buckets[key][round]
         if r and #kept < ceiling then kept[#kept + 1] = r; added = true end
      end
      if not added then break end
      round = round + 1
   end
   local keptset = {}
   for _, r in ipairs(kept) do keptset[r] = true end
   for _, key in ipairs(order) do
      for _, r in ipairs(buckets[key]) do if not keptset[r] then skipped[#skipped + 1] = r end end
   end
   return kept, skipped
end





local function ambiguous_list_arg(shown, target, kw)
   local t = norm_name(target)
   for i, nm in ipairs(shown or {}) do
      if norm_name(nm) == t then return i .. "." .. kw end
   end
   return "1." .. kw
end




local EQ_RULES = [[EQUIPPABILITY RULES (AlterAeon):
- "(you can't use this yet)" on the identify line means your level is too low RIGHT NOW — not equippable.
- Class flags (MAGE, CLERIC, THIEF, WARRIOR, NECR=Necromancer, DRUID) require that class at/above the
  item's level. Multiple class flags mean you must meet ALL of them (e.g. paladin gear is CLERIC + WARRIOR).
- Level reqs are either primary ("Level: N": your highest class level >= N) or total ("Total levels: N":
  your total levels across classes >= N, with a per-class floor).
- Alignment: ANTI_GOOD can't be worn by good chars, ANTI_EVIL by evil, ANTI_NEUTRAL by neutral. EVIL/GOOD
  flags are usable but slowly shift your alignment.
- Weapons list a strength requirement ("N strength to use"); below it you can't wield effectively.
- Higher damage range, more armor (AC/Defense), and useful Affects (HITROLL, DAMROLL, HP, MANA, stats,
  regen) are what make one piece better than another for a given slot.]]

local EQ_SYS = "You are an expert Alter Aeon equipment adviser. Given a character sheet and their gear " ..
"with parsed identify stats, recommend what to wear.\n\n" .. EQ_RULES .. "\n\n" ..
"Rules for your answer: NEVER recommend equipping anything marked CANNOT EQUIP, AMBIGUOUS, or " ..
"unidentified — for AMBIGUOUS/unidentified items, tell the player to identify it first. Give a terse, " ..
"structured reply: one line per slot (keep / swap-to-<item> / can't-equip-because-<reason>), then a " ..
"short 'Top actions:' list. No preamble."

local EQ_SHOP_SYS = "You are an expert Alter Aeon shopping adviser. Given a character sheet, their current " ..
"gear, and a shop's items with prices, decide what is worth buying.\n\n" .. EQ_RULES .. "\n\n" ..
"Rules for your answer: NEVER say BUY for an item marked CANNOT EQUIP, AMBIGUOUS, or unidentified. " ..
"Weigh price against your gold and whether it upgrades the slot you'd wear it in. Reply terse: one " ..
"line per shop item (BUY/SKIP + one-line why), then the single best purchase (or 'buy nothing')."

local function char_sheet_lines(char)
   local out = { "Name: " .. (char.name or "unknown") }
   if char.classes and next(char.classes) then
      local cs, total = {}, 0
      for cls, lvl in pairs(char.classes) do cs[#cs + 1] = cls .. " " .. tostring(lvl); total = total + (lvl or 0) end
      table.sort(cs)
      out[#out + 1] = "Classes: " .. table.concat(cs, ", ")
      out[#out + 1] = "Total levels: " .. total
   else
      out[#out + 1] = "Classes: unknown"
   end
   out[#out + 1] = "Alignment: " .. (char.alignment or "unknown")
   out[#out + 1] = "Strength: " .. (char.str and tostring(char.str) or "unknown")
   out[#out + 1] = "Gold: " .. (char.gold and tostring(char.gold) or "unknown")
   return table.concat(out, "\n")
end


local function variant_stats_str(v)
   local parts = {}
   if v.type then parts[#parts + 1] = v.type end
   if #v.wear > 0 then parts[#parts + 1] = "wear " .. table.concat(v.wear, "/") end
   if v.level then parts[#parts + 1] = "req level " .. v.level end
   if v.total_levels then parts[#parts + 1] = "req total-levels " .. v.total_levels end
   if v.defense then parts[#parts + 1] = "AC " .. v.defense end
   if v.weapon then
      parts[#parts + 1] = string.format("dmg %s-%s %s (STR %s)", v.weapon.min, v.weapon.max, v.weapon.verb or "?", v.weapon.str or "?")
   end
   local af = {}
   for _, a in ipairs(v.affects) do af[#af + 1] = a.stat .. "+" .. a.by end
   if #af > 0 then parts[#parts + 1] = table.concat(af, " ") end
   if #v.class_flags > 0 then parts[#parts + 1] = "class:" .. table.concat(v.class_flags, "/") end
   if #v.align_flags > 0 then parts[#parts + 1] = "align:" .. table.concat(v.align_flags, "/") end
   if v.cant_use_yet then parts[#parts + 1] = "(you can't use this yet)" end
   return table.concat(parts, ", ")
end



local FLAG_PRETTY = { glow = "glowing", hum = "humming", invis = "invisible" }
local function flags_str(flags)
   if not flags or not next(flags) then return nil end
   local out = {}
   for f in pairs(flags) do out[#out + 1] = FLAG_PRETTY[f] or f end
   table.sort(out)
   return table.concat(out, ", ")
end




local function describe_item_for_prompt(name, char, flags)
   local fs = flags_str(flags)
   local suffix = fs and (" [" .. fs .. "]") or ""
   local r = resolve_item(name)
   if r.status == "unknown" then
      return string.format("- %s%s: unidentified — cannot judge; run eq.id('%s')", name, suffix, first_kw(name))
   elseif r.status == "multi" then
      return string.format("- %s%s: AMBIGUOUS — %d different '%s' variants known; re-identify the one you hold (eq.id('%s'))",
      name, suffix, r.count, name, first_kw(name))
   else
      local v = r.variant
      local pc = precheck_equip(v, char)
      local verdict = pc.ok and "equippable" or ("CANNOT EQUIP: " .. table.concat(pc.reasons, "; "))
      local src = (r.status == "session") and "identified this session (you're holding it)" or
      "stats from a previous identify — re-id to confirm"
      return string.format("- %s%s [%s] — %s — %s", name, suffix, variant_stats_str(v), verdict, src)
   end
end









local function build_compare_prompt(char, worn, candidates, focus)
   local u = { "=== CHARACTER ===", char_sheet_lines(char) }
   if focus and focus ~= "" then u[#u + 1] = "\n=== FOCUS ===\nAdvise specifically about: " .. focus end
   u[#u + 1] = "\n=== CURRENTLY WORN ==="
   if #worn == 0 then u[#u + 1] = "(no worn gear recorded — run eq.scan())" end
   for _, w in ipairs(worn) do
      u[#u + 1] = (w.slot and (w.slot .. ": ") or "- ") .. (describe_item_for_prompt(w.name, char, w.flags):gsub("^%- ", ""))
   end
   u[#u + 1] = "\n=== CANDIDATE ITEMS (carried / in containers) ==="
   if #candidates == 0 then u[#u + 1] = "(none)" end
   for _, c in ipairs(candidates) do
      if type(c) == "table" then u[#u + 1] = describe_item_for_prompt(c.name, char, c.flags)
      else u[#u + 1] = describe_item_for_prompt(c, char, nil) end
   end
   u[#u + 1] = "\n=== TASK ==="
   u[#u + 1] = (focus and focus ~= "") and "Advise on the focus above." or "Review the whole loadout, slot by slot."
   return EQ_SYS, table.concat(u, "\n")
end


local function build_shop_prompt(char, worn, kept)
   local u = { "=== CHARACTER ===", char_sheet_lines(char), "\n=== CURRENTLY WORN ===" }
   if #worn == 0 then u[#u + 1] = "(no worn gear recorded)" end
   for _, w in ipairs(worn) do
      u[#u + 1] = (w.slot and (w.slot .. ": ") or "- ") .. (describe_item_for_prompt(w.name, char, w.flags):gsub("^%- ", ""))
   end
   local donation = false
   u[#u + 1] = "\n=== SHOP ITEMS FOR SALE ==="
   if #kept == 0 then u[#u + 1] = "(nothing wearable shortlisted)" end
   for _, r in ipairs(kept) do
      local info = describe_item_for_prompt(r.name, char, nil):gsub("^%- ", "")
      local cost = r.free and "FREE" or (tostring(r.price or "?") .. " gold")
      local req = (r.level_kind == "tot") and ("tot lvl " .. tostring(r.level)) or
      ("shop lvl " .. tostring(r.level or "?"))
      if r.free then donation = true end
      u[#u + 1] = string.format("- [%s] (%s) %s", cost, req, info)
   end
   u[#u + 1] = "\n=== TASK ==="
   if donation then
      u[#u + 1] = "This is a DONATION room — every item is FREE. Ignore cost; for each item say TAKE or SKIP " ..
      "based purely on whether it's an upgrade you can equip, then name the best pieces to grab."
   else
      u[#u + 1] = "You have " .. (char.gold and (char.gold .. " gold") or "unknown gold") ..
      ". For each shop item say BUY or SKIP with one line why."
   end
   return EQ_SHOP_SYS, table.concat(u, "\n")
end





local CAT_SLOT = {
   head = "head", neck = "neck", arms = "arms", wrists = "wrist", hands = "hands", fingers = "finger",
   waist = "waist", legs = "legs", feet = "feet", back = "back", ears = "ears", eyes = "eyes",
   face = "face", body = "body", ["about body"] = "about body", held = "held", shields = "shield",
   wielded = "weapon", ["one handed weapon"] = "weapon", ["two handed weapon"] = "weapon",
   floating = "floating",
}
local function slot_for_category(cat)
   local c = (cat or ""):lower():gsub("^worn on ", ""):gsub("^worn ", "")
   return CAT_SLOT[c]
end




local function build_slot_prompt(char, category, slot_items, worn)
   local slot = slot_for_category(category)
   local u = { "=== CHARACTER ===", char_sheet_lines(char),
"\n=== SLOT: " .. tostring(category) .. " ===", "\n--- WHAT YOU WEAR HERE NOW ---", }
   local any_worn, donation = false, false
   for _, w in ipairs(worn or {}) do
      if slot and w.slot == slot then
         u[#u + 1] = describe_item_for_prompt(w.name, char, w.flags); any_worn = true
      end
   end
   if not any_worn then u[#u + 1] = "(nothing worn in this slot)" end
   u[#u + 1] = "\n--- AVAILABLE HERE ---"
   for _, r in ipairs(slot_items or {}) do
      local info = describe_item_for_prompt(r.name, char, nil):gsub("^%- ", "")
      local cost = r.free and "FREE" or (tostring(r.price or "?") .. " gold")
      local req = (r.level_kind == "tot") and ("tot lvl " .. tostring(r.level)) or
      ("shop lvl " .. tostring(r.level or "?"))
      if r.free then donation = true end
      u[#u + 1] = string.format("- [%s] (%s) %s", cost, req, info)
   end
   u[#u + 1] = "\n=== TASK ==="
   u[#u + 1] = donation and
   "DONATION room — items are FREE. For THIS slot only, say TAKE or SKIP per item (one line why), then name the single best piece to wear here (or 'keep current')." or
   ("For THIS slot only, say BUY or SKIP per item (one line why), then the best pick (or 'keep current'). You have " ..
   (char.gold and (char.gold .. " gold") or "unknown gold") .. ".")
   return EQ_SHOP_SYS, table.concat(u, "\n")
end


local function char_from_state()
   local classes = {}
   local raw_classes = state and state.classes
   if type(raw_classes) == "table" then
      for cls, c in pairs(raw_classes) do
         if type(c) == "table" then classes[cls] = c.level end
      end
   end
   return {
      name = state and state.name,
      classes = next(classes) and classes or nil,
      gold = state and state.gold,
      alignment = state and state.alignment,
      str = state and state.str,
   }
end





local function combat_block()
   if in_combat and in_combat() then echo("[eq] not while you're fighting.", "yellow"); return true end
   return false
end



local function run_model(sys, user, on_reply)
   if not ai_local_request then echo("[eq] no local model available (ai_local_request missing — relaunch).", "red"); return end
   S.gen = (S.gen or 0) + 1
   local g = S.gen
   ai_local_request(sys, user, cfg.max_tokens, cfg.think_prefill, function(reply, err)
      if EPOCH ~= _EQUIP.epoch or g ~= S.gen then return end



      if err then echo("[eq] model error: " .. tostring(err), "red"); on_reply("", err); return end
      on_reply(reply or "")
   end, cfg.model)
end
















local eq_op = nil



local EQ_OP_IDLE = 210
local function eq_settle(ok, reason)
   local op = eq_op; eq_op = nil
   if not op then return end
   if op.timer and cancel then cancel(op.timer) end
   if ok == false then op.reject(reason or "eq interrupted") else op.resolve(nil) end
end
local function eq_resolve() eq_settle(true, nil) end
local function eq_reject(reason) eq_settle(false, reason) end
local function eq_touch()
   local op = eq_op; if not op then return end
   if op.timer and cancel then cancel(op.timer) end
   if after then    op.timer = after(EQ_OP_IDLE, function()
      echo("[eq] " .. (op.label or "operation") .. " stalled — wrapping up.", "yellow")
      eq_settle(false, "stalled")
   end) end
end














local function eq_begin(label)
   eq_reject("superseded")
   if not __promise then return nil end
   local p = __promise(function(resolve, reject, onCancel)
      eq_op = { resolve = resolve, reject = reject, label = label, timer = nil }
      onCancel(function()
         if eq_op and eq_op.timer and cancel then cancel(eq_op.timer) end
         eq_op = nil
      end)
   end, label)
   if p and p.__start then p.__start() end
   eq_touch()
   return p
end


local function eq_instant(label)
   if not __promise then return nil end
   return __promise(function(resolve) resolve(nil) end, label)
end























local idq_advance
local function finalize_id()
   local cap = S.id_cap
   S.id_cap = nil
   if not cap then return end
   local v = parse_identify(table.concat(cap.lines, "\n"))
   local expect = S.id_expect
   S.id_expect = nil
   local matched = true
   if v then
      if expect and expect ~= "" then
         if v.display and v.display ~= "" and v.display ~= expect then
            matched = false
         else
            v.name = expect
         end
      end
      ingest(v)
   end
   if idq_advance then idq_advance(v ~= nil and matched) end

   if S.id_resolve then local cb = S.id_resolve; S.id_resolve = nil; cb() end
end
local function id_begin() S.id_cap = { lines = {} } end
local function id_feed(line)
   local cap = S.id_cap
   if not cap then return end
   local L = strip_ansi(line)
   if L:match("^kxw[tq]_id_end") then cap.body_done = true; return end
   if L:match("^kxw[tq]_") then return end

   local disp = L:match("^You are wearing (.+)$") or L:match("^You are wielding (.+)$") or
   (L:match("^You are carrying (.+)$") and not L:match("^You are carrying %d") and L:match("^You are carrying (.+)$"))
   if disp then cap.lines[#cap.lines + 1] = L; finalize_id(); return end

   if L:match("^<%d+hp") or L:match("^%[the human typed%]") then finalize_id(); return end
   if cap.body_done and trim(L) ~= "" then finalize_id(); return end
   cap.lines[#cap.lines + 1] = L
   if #cap.lines > 60 then finalize_id() end
end
trigger([[^kxw[tq]_id_start]], function() id_begin() end)
trigger([[^Item: '(.+)']], function() if not S.id_cap then id_begin() end end)
trigger([[.*]], function(line) id_feed(line) end)


local function feed_id_stream(lines)
   for _, line in ipairs(lines) do
      if line:match("^kxw[tq]_id_start") then id_begin()
      elseif line:match("^Item: '") and not S.id_cap then id_begin() end
      id_feed(line)
   end
end



























local function assign_ordinals(entries)
   local counts = {}
   for _, e in ipairs(entries) do
      local k = first_kw(e.name)
      counts[k] = (counts[k] or 0) + 1
      e.base_kw = k
      e.ordinal = counts[k]
      e.kw = (counts[k] == 1) and k or (counts[k] .. "." .. k)
   end
   return entries
end






local function build_id_queue(worn, inv, containers)
   local queue = {}
   local known = 0
   local seen = {}
   local function consider(e, container)
      if not e.name or e.name == "" then return end
      local dkey = (container or "person") .. "|" .. e.name
      if seen[dkey] then return end
      seen[dkey] = true
      local r = resolve_item(e.name)



      if r.status == "session" or r.status == "cached" then known = known + 1; return end
      queue[#queue + 1] = { name = e.name, kw = e.kw, base_kw = e.base_kw, ordinal = e.ordinal,
status = r.status, container = container, }
   end

   local person = {}
   for _, n in ipairs(worn or {}) do person[#person + 1] = { name = norm_name(n) } end
   for _, n in ipairs(inv or {}) do person[#person + 1] = { name = norm_name(n) } end
   assign_ordinals(person)
   for _, e in ipairs(person) do consider(e, nil) end

   for cname, list in pairs(containers or {}) do
      local cont = {}
      for _, n in ipairs(list or {}) do cont[#cont + 1] = { name = norm_name(n) } end
      assign_ordinals(cont)
      for _, e in ipairs(cont) do consider(e, cname) end
   end
   return queue, known
end





























local idResultS = rx and rx.subject() or nil
local getResultS = rx and rx.subject() or nil
local putResultS = rx and rx.subject() or nil
local idqEndS = rx and rx.subject() or nil

local FAIL = {}
local ABORT = {}




idq_advance = function(ok) if S.idq and idResultS then idResultS:onNext(ok and "ok" or FAIL) end end
local function idq_get_result(ok) if S.idq and getResultS then getResultS:onNext(ok and "ok" or FAIL) end end
local function idq_put_result(ok) if S.idq and putResultS then putResultS:onNext(ok and "ok" or FAIL) end end




local function IDP(executor)
   local p = __promise(executor, "eq-idflow")
   if __untrack_promise then __untrack_promise(p) end
   if p and p.__start then p.__start() end
   return p
end




local function await_reply(subject, secs)
   return IDP(function(resolve, _, onCancel)
      local sub = nil
      local esub = nil
      local tid = nil
      local done = false
      local function cleanup()
         if sub then sub:unsubscribe(); sub = nil end
         if esub then esub:unsubscribe(); esub = nil end
         if tid and cancel then cancel(tid); tid = nil end
      end
      local function fin(v) if done then return end; done = true; cleanup(); resolve(v) end
      if subject then sub = subject:subscribe(function(v) fin(v) end) end
      if idqEndS then esub = idqEndS:subscribe(function() fin(ABORT) end) end
      if secs and after then tid = after(secs, function() tid = nil; fin(FAIL) end) end
      onCancel(function() done = true; cleanup() end)
   end)
end



local function idq_gap(fn)
   return IDP(function(resolve, _, onCancel)
      local id = nil
      id = after and after(cfg.id_gap, function() id = nil; resolve(nil) end)
      if not id then resolve(nil) end
      onCancel(function() if id and cancel then cancel(id) end end)
   end):andThen(fn)
end

local idq_process



local function idq_finish()
   local q = S.idq; if not q then return end
   S.idq = nil
   if class_remove then class_remove("eqid") end
   if idqEndS then idqEndS:onNext(nil) end
   echo(string.format("[eq] identify pass: %d identified, %d failed, %d already known.",
   q.ident, q.failed, q.known), "cyan")
   if #q.left_out > 0 then
      echo("[eq] WARNING — could NOT return to their container, they are ON YOU now: " ..
      table.concat(q.left_out, ", ") .. " — put them back manually.", "red")
   end
   echo("[eq] now try eq.compare().", "cyan")
   eq_resolve()
end




local function idq_do_put(i, e)
   send(string.format("put %s %s", e.base_kw, first_kw(e.container)))
   return await_reply(putResultS, cfg.id_timeout):andThen(function(res)
      local q = S.idq; if not q then return end
      if res == ABORT then return end
      q.out_item = nil
      if res == FAIL then q.left_out[#q.left_out + 1] = e.name end
      return idq_gap(function() return idq_process(i + 1) end)
   end)
end





local function idq_do_identify(i, e, pulled)
   S.id_expect = e.name
   send("identify " .. (e.container and e.base_kw or e.kw))
   return await_reply(idResultS, cfg.id_timeout):andThen(function(res)
      local q = S.idq; if not q then return end
      S.id_expect = nil
      if res == ABORT then return end
      if res == FAIL then q.failed = q.failed + 1 else q.ident = q.ident + 1 end
      if pulled then return idq_do_put(i, e) end
      return idq_gap(function() return idq_process(i + 1) end)
   end)
end


idq_process = function(i)
   local q = S.idq; if not q then return end
   if EPOCH ~= _EQUIP.epoch then return end
   if in_combat and in_combat() then
      if not q.paused_msg then echo("[eq] identify pass paused (in combat) — resuming when clear.", "yellow"); q.paused_msg = true end
      eq_touch()
      return IDP(function(resolve, _, onCancel)
         local id = nil
         id = after and after(cfg.id_combat_retry, function() id = nil; resolve(nil) end)
         if not id then resolve(nil) end
         onCancel(function() if id and cancel then cancel(id) end end)
      end):andThen(function() return idq_process(i) end)
   end
   q.paused_msg = nil
   eq_touch()
   if i > #q.list then idq_finish(); return end
   local e = q.list[i]
   echo(string.format("[eq] identifying %d/%d: %s%s", i, #q.list, e.name,
   e.container and (" (from " .. e.container .. ")") or ""), "cyan")
   if e.container then
      send(string.format("get %s %s", e.kw, first_kw(e.container)))
      return await_reply(getResultS, cfg.id_timeout):andThen(function(res)
         local q2 = S.idq; if not q2 then return end
         if res == ABORT then return end
         if res == FAIL then
            q2.failed = q2.failed + 1
            return idq_gap(function() return idq_process(i + 1) end)
         end
         q2.out_item = e.name
         return idq_do_identify(i, e, true)
      end)
   end
   return idq_do_identify(i, e, false)
end

local function idq_install_triggers()
   trigger_c([[^You get .+ from ]], function() idq_get_result(true) end, { class = "eqid" })
   trigger_c([[^You don't see anything named]], function() idq_get_result(false) end, { class = "eqid" })
   trigger_c([[^You can't carry that many items]], function() idq_get_result(false) end, { class = "eqid" })
   trigger_c([[^You can't safely carry]], function() idq_get_result(false) end, { class = "eqid" })
   trigger_c([[^You put .+ in ]], function() idq_put_result(true) end, { class = "eqid" })
   trigger_c([[^You don't seem to be carrying anything named]], function() idq_advance(false) end, { class = "eqid" })
end

local function idq_start(queue, known)
   if #queue == 0 then
      echo(string.format("[eq] nothing to auto-identify — %d item(s) already known (cached/identified).", known), "cyan")
      echo("[eq] now try eq.compare().", "cyan")
      eq_resolve()
      return
   end
   S.idq = { list = queue, known = known, ident = 0, failed = 0, left_out = {}, out_item = nil }
   idq_install_triggers()
   echo(string.format("[eq] auto-identifying %d item(s) (%d already known this session)…", #queue, known), "cyan")



   local flow = idq_process(1)
   if flow and flow.catch then
      flow:catch(function(why)
         if why ~= nil and (why) ~= ABORT and S.idq then
            echo("[eq] identify pass stalled — wrapping up.", "yellow")
            idq_finish()
         end
      end)
   end
end


local CONTAINER_KW = { "sack", "bag", "backpack", "pack", "pouch", "chest", "box", "quiver", "basket",
"container", "purse", "case", "satchel", "crate", "barrel", "trunk", "distortion", }
local function looks_like_container(name)
   local r = resolve_item(name)
   if r.variant and r.variant.type == "CONTAINER" then return true end
   local n = (name or ""):lower()
   for _, kw in ipairs(CONTAINER_KW) do if n:find(kw, 1, true) then return true end end
   return false
end



local function note_flags(sc, name, flags)
   if not flags or not next(flags) then return end
   local k = norm_name(name)
   if k == "" then return end
   sc.flagmap = sc.flagmap or {}
   sc.flagmap[k] = sc.flagmap[k] or {}
   for f in pairs(flags) do sc.flagmap[k][f] = true end
end


local function scan_feed(line)
   local sc = S.scan
   if not sc or not sc.mode then return end
   local L = strip_ansi(line)
   if L:match("^kxw[tq]_") then return end
   if L:match("^<%d+hp") or trim(L) == "" or L:match("^%[the human typed%]") then
      sc.mode = nil; return
   end
   if sc.mode == "eq" then
      local slot, item, flags = parse_eq_line(L)
      if item then
         sc.eq[#sc.eq + 1] = { slot = slot, item = item, flags = flags }
         note_flags(sc, item, flags)
      end
   elseif sc.mode == "inv" then
      local it, flags = parse_item_line(L)
      if it then sc.inv[#sc.inv + 1] = it; note_flags(sc, it, flags) end
   elseif sc.mode == "cont" then
      local it, flags = parse_item_line(L)
      if it and sc.curcont then
         sc.containers[sc.curcont] = sc.containers[sc.curcont] or {}
         table.insert(sc.containers[sc.curcont], it)
         note_flags(sc, it, flags)
      end
   end
end

local function install_scan_triggers()
   trigger_c([[^You are using:]], function() S.scan.mode = "eq"; S.scan.eq = {} end, { class = "eq" })
   trigger_c([[^You are wearing:]], function() S.scan.mode = "eq"; S.scan.eq = {} end, { class = "eq" })
   trigger_c([[^You are carrying:]], function() S.scan.mode = "inv"; S.scan.inv = {} end, { class = "eq" })
   trigger_c([[^.+ contains:$]], function(line)
      local cname = parse_container_header(line)
      S.scan.mode = "cont"; S.scan.curcont = cname or "a container"
      S.scan.containers[S.scan.curcont] = S.scan.containers[S.scan.curcont] or {}
   end, { class = "eq" })
   trigger_c([[.*]], function(line) scan_feed(line) end, { class = "eq" })
end

local function finish_scan()
   if not S.scan then return end
   eq_touch()
   if class_remove then class_remove("eq") end
   local sc = S.scan

   local possess = {}
   for _, e in ipairs(sc.eq) do possess[e.item] = true end
   for _, n in ipairs(sc.inv) do possess[norm_name(n)] = true end
   local ccount = 0
   for _, its in pairs(sc.containers) do ccount = ccount + #its; for _, n in ipairs(its) do possess[norm_name(n)] = true end end
   for name in pairs(session) do if not possess[name] then session[name] = nil end end
   echo(string.format("[eq] scan: %d worn, %d in inventory, %d in %d container(s).",
   #sc.eq, #sc.inv, ccount, (function() local n = 0; for _ in pairs(sc.containers) do n = n + 1 end; return n end)()), "cyan")
   if sc.quick then
      echo("[eq] quick scan — collected names only (no identify). Run eq.scan() to auto-identify.", "dim")
      echo("[eq] now try eq.compare() (items you've never identified will read 'unidentified').", "cyan")
      eq_resolve()
      return
   end


   local worn = {}
   for _, e in ipairs(sc.eq) do worn[#worn + 1] = e.item end
   local queue, known = build_id_queue(worn, sc.inv, sc.containers)
   idq_start(queue, known)
end


local function scan_containers(list, i)
   if EPOCH ~= _EQUIP.epoch then return end
   if i > #list then after(cfg.look_wait, finish_scan); return end
   send("look in " .. first_kw(list[i]))
   after(cfg.look_wait, function() scan_containers(list, i + 1) end)
end

local function eq_scan(mode)
   if combat_block() then return nil end
   local quick = (trim(mode or ""):lower() == "quick")
   local p = eq_begin(quick and "eq.quick" or "eq.scan")
   S.scan = { eq = {}, inv = {}, containers = {}, mode = nil, curcont = nil, quick = quick }
   install_scan_triggers()
   echo(quick and "[eq] quick scan — collecting names only…" or "[eq] scanning gear, inventory, containers, then auto-identifying…", "cyan")
   send("equipment")
   after(cfg.look_wait, function()
      send("inventory")
      after(cfg.look_wait, function()
         local conts = {}
         for _, n in ipairs(S.scan.inv) do if looks_like_container(n) then conts[#conts + 1] = n end end
         scan_containers(conts, 1)
      end)
   end)
   return p
end


local function current_worn()
   if S.scan and S.scan.eq and #S.scan.eq > 0 then
      local out = {}
      for _, e in ipairs(S.scan.eq) do out[#out + 1] = { slot = e.slot, name = e.item, flags = e.flags } end
      return out
   end
   local out = {}
   local eq_lines = state and state.equipment
   if type(eq_lines) == "table" then
      for _, line in ipairs(eq_lines) do
         local slot, item, flags = parse_eq_line(line)
         if item then out[#out + 1] = { slot = slot, name = item, flags = flags } end
      end
   end
   return out
end






local function current_candidates()
   local seen = {}
   local out = {}
   local function add(n, flags)
      n = norm_name(n)
      if n ~= "" and not seen[n] then seen[n] = true; out[#out + 1] = { name = n, flags = flags } end
   end
   local sc = S.scan
   if sc and ((sc.inv and #sc.inv > 0) or next(sc.containers or {})) then
      local fm = sc.flagmap or {}
      for _, n in ipairs(sc.inv or {}) do add(n, fm[norm_name(n)]) end
      for _, its in pairs(sc.containers or {}) do for _, n in ipairs(its) do add(n, fm[norm_name(n)]) end end
   else
      local inv_lines = state and state.inventory
      if type(inv_lines) == "table" then
         for _, line in ipairs(inv_lines) do
            local n, flags = parse_item_line(line)
            if n then add(n, flags) end
         end
      end
   end
   return out
end


local function eq_compare(focus)
   focus = trim(focus)
   local char = char_from_state()
   local worn, cands = current_worn(), current_candidates()
   local p = eq_begin("eq.compare")
   if #worn == 0 and #cands == 0 then
      echo("[eq] nothing to compare — run eq.scan() first.", "yellow"); eq_resolve(); return p
   end
   local sys, user = build_compare_prompt(char, worn, cands, focus)
   echo("[eq] asking " .. cfg.model .. " to review your gear…", "cyan")
   eq_touch()
   run_model(sys, user, function(reply)
      if trim(reply) ~= "" then echo("[eq] " .. trim(reply), "cyan") end
      eq_resolve()
   end)
   return p
end


local function eq_id(arg)
   arg = trim(arg)
   if arg == "" then echo("[eq] usage: eq.id('<item keyword>')", "yellow"); return nil end
   if combat_block() then return nil end
   local p = eq_begin("eq.id " .. arg)
   echo("[eq] identifying '" .. arg .. "' (higher-level items need an identify scroll/spell)…", "cyan")
   S.id_resolve = eq_resolve
   send("identify " .. arg)
   return p
end


local function finish_shop()
   if not S.shop then return end
   eq_touch()
   local parsed = parse_shop_list(table.concat(S.shop.rows_text, "\n"))
   if parsed.no_shop then echo("[eq] you're not at a shop (no shopkeeper/donation/priest/guildmaster here).", "yellow"); eq_resolve(); return end
   if #parsed.rows == 0 then echo("[eq] nothing listed here to buy.", "yellow"); eq_resolve(); return end


   local char = char_from_state()
   local fit = nil
   if char and char.classes and next(char.classes) then
      local maxl, tot = 0, 0
      for _, lv in pairs(char.classes) do maxl = math.max(maxl, lv or 0); tot = tot + (lv or 0) end
      fit = { level = maxl, total = tot }
   end
   local kept, skipped = shortlist_shop(parsed, fit, cfg.detail_ceiling)
   local fitnote = fit and string.format(" (fit: ≤ lvl %d, ≤ tot %d)", fit.level, fit.total) or ""
   echo(string.format("[eq] shop: %d items · evaluating %d wearable%s · skipped %d (consumables/too-high-level).",
   #parsed.rows, #kept, fitnote, #skipped), "cyan")
   if #kept >= cfg.detail_ceiling then
      echo(string.format("[eq] hit the %d-item safety ceiling — raise cfg.detail_ceiling to look at more.", cfg.detail_ceiling), "yellow")
   end
   if #kept == 0 then echo("[eq] no wearable/wieldable upgrades to evaluate here.", "yellow"); eq_resolve(); return end
   S.shop.kept = kept


   local function ask_single()
      if EPOCH ~= _EQUIP.epoch then return end
      local sys, user = build_shop_prompt(char_from_state(), current_worn(), kept)
      echo("[eq] asking " .. cfg.model .. (parsed.donation and " what's worth grabbing…" or " what's worth buying…"), "cyan")
      eq_touch()
      run_model(sys, user, function(reply)
         if trim(reply) ~= "" then echo("[eq] " .. trim(reply), "cyan") end
         eq_resolve()
      end)
   end
   local function ask_per_slot()
      if EPOCH ~= _EQUIP.epoch then return end
      local groups = {}
      local order = {}
      for _, r in ipairs(kept) do
         local c = r.category or "?"
         if not groups[c] then groups[c] = {}; order[#order + 1] = c end
         groups[c][#groups[c] + 1] = r
      end
      local ch, worn = char_from_state(), current_worn()
      echo(string.format("[eq] %d items across %d slots — too many for one pass, reviewing a slot at a time…",
      #kept, #order), "cyan")
      local do_slot
      do_slot = function(i)
         if EPOCH ~= _EQUIP.epoch then return end
         if i > #order then echo("[eq] shop review complete.", "cyan"); eq_resolve(); return end
         eq_touch()
         local cat = order[i]
         echo("[eq] " .. cat .. " —", "cyan")
         local sys, user = build_slot_prompt(ch, cat, groups[cat], worn)
         run_model(sys, user, function(reply)
            if trim(reply) ~= "" then echo("[eq] " .. trim(reply), "cyan") end
            do_slot(i + 1)
         end)
      end
      do_slot(1)
   end
   local function ask_model()
      if #kept <= cfg.single_call_max then ask_single() else ask_per_slot() end
   end











   local retried = false
   local function pull(i)
      if EPOCH ~= _EQUIP.epoch then return end
      if i > #kept then
         if class_remove then class_remove("eqdetail") end
         ask_model(); return
      end
      eq_touch()




      local r = resolve_item(kept[i].name)
      if r.status == "session" or r.status == "cached" then
         after(0, function() pull(i + 1) end); return
      end
      S.shop.cur = kept[i]; S.shop.dis = {}; retried = false
      S.id_expect = norm_name(kept[i].name)
      send("list " .. first_kw(kept[i].name))
      after(cfg.look_wait, function() pull(i + 1) end)
   end



   trigger_c([[.*]], function(line)
      if not (S.shop and S.shop.cur) then return end
      local L = strip_ansi(line)
      local r = parse_shop_row(L)
      if r and r.name and S.shop.dis then S.shop.dis[#S.shop.dis + 1] = r.name end
      if not retried and L:find("must give the item number", 1, true) then
         retried = true
         local cur = S.shop.cur
         local arg = ambiguous_list_arg(S.shop.dis, cur.name, first_kw(cur.name))
         S.id_expect = norm_name(cur.name)
         send("list " .. arg)
      end
   end, { class = "eqdetail" })
   pull(1)
end



local function is_more_prompt(L)
   return L:find("' to continue", 1, true) ~= nil or L:find("<return> or 'cont'", 1, true) ~= nil
end

local function eq_shop()
   if combat_block() then return nil end
   local p = eq_begin("eq.shop")
   S.shop = { rows_text = {}, collecting = true }
   local finish_timer


   local function arm_finish()
      if cancel and finish_timer then cancel(finish_timer) end
      finish_timer = after(cfg.look_wait, function()
         if not (S.shop and S.shop.collecting) then return end
         S.shop.collecting = false
         if class_remove then class_remove("eqshop") end
         finish_shop()
      end)
   end
   trigger_c([[.*]], function(line)
      if not (S.shop and S.shop.collecting) then return end
      local L = strip_ansi(line)
      if is_more_prompt(L) then
         send("cont")
         arm_finish()
         return
      end
      S.shop.rows_text[#S.shop.rows_text + 1] = L

      if parse_shop_row(L) then arm_finish() end
   end, { class = "eqshop" })
   echo("[eq] reading the shop's list…", "cyan")
   send("list")
   arm_finish()
   return p
end


local function eq_stats()
   local names, variants = 0, 0
   for _, e in pairs(items) do names = names + 1; for _ in pairs(e.variants) do variants = variants + 1 end end
   local sess = 0; for _ in pairs(session) do sess = sess + 1 end
   echo(string.format("[eq] cache: %d item names, %d total variants, %d this-session id(s). Model: %s.",
   names, variants, sess, cfg.model), "cyan")
end

local function eq_usage()
   return "[eq] usage: eq.scan(['quick']) | eq.compare([slot|item]) | eq.shop() | eq.id(item) | eq.stats() | eq.forget()  —  help(eq)"
end


















local eq_tbl = {}
eq = eq_tbl



function eq_tbl.scan(mode)
   local m = nil
   if type(mode) == "table" then m = (mode.quick and "quick" or "")
   elseif type(mode) == "string" then m = mode end
   return eq_scan(m)
end
function eq_tbl.quick() return eq_scan("quick") end
function eq_tbl.compare(slot_or_item) return eq_compare(slot_or_item) end
function eq_tbl.id(item) return eq_id(item) end
function eq_tbl.shop() return eq_shop() end
function eq_tbl.stats() eq_stats(); return eq_instant("eq.stats") end
function eq_tbl.forget()
   for k in pairs(items) do items[k] = nil end
   for k in pairs(session) do session[k] = nil end
   save_items(); echo("[eq] cleared the item cache")
   return eq_instant("eq.forget")
end

doc(eq_tbl.scan, { name = "eq.scan", sig = "eq.scan(['quick'])", group = "equipment",
text = "Read worn gear, inventory, and every container, then auto-identify anything not cached so compare/shop can reason about stats. Pass 'quick' (or eq.quick()) to only collect names.", })
doc(eq_tbl.quick, { name = "eq.quick", sig = "eq.quick()", group = "equipment",
text = "Fast scan: collect worn/inventory/container names only, no identify. Same as eq.scan('quick').", })
doc(eq_tbl.compare, { name = "eq.compare", sig = "eq.compare([slot_or_item])", group = "equipment",
text = "Ask the equipment model to review your loadout (per-slot keep/swap verdicts). Optional focus narrows it to one slot or item.", })
doc(eq_tbl.id, { name = "eq.id", sig = "eq.id(item)", group = "equipment",
text = "Identify a carried/worn item by keyword (game `identify`; higher-level items need a scroll/spell). The result folds into the item cache.", })
doc(eq_tbl.shop, { name = "eq.shop", sig = "eq.shop()", group = "equipment",
text = "At a shopkeeper, read `list`, shortlist the wearable rows, pull per-item detail, then ask the model what's worth buying.", })
doc(eq_tbl.stats, { name = "eq.stats", sig = "eq.stats()", group = "equipment",
text = "Report the item-cache size (names, variants, this-session identifies) and the model in use.", })
doc(eq_tbl.forget, { name = "eq.forget", sig = "eq.forget()", group = "equipment",
text = "Clear the persisted item cache and this-session identify bindings.", })



setmetatable(eq_tbl, { __call = function(_, rest)
   rest = trim(rest or "")
   local verb = (rest:match("^%S*") or ""):lower()
   local arg = rest:match("^%S+%s+(.*)$") or ""

   if verb == "scan" then return eq_tbl.scan(arg ~= "" and arg or nil)
   elseif verb == "quick" then return eq_tbl.quick()
   elseif verb == "compare" or verb == "cmp" then return eq_tbl.compare(arg)
   elseif verb == "id" or verb == "identify" then return eq_tbl.id(arg)
   elseif verb == "shop" then return eq_tbl.shop()
   elseif verb == "stats" or verb == "cache" then return eq_tbl.stats()
   elseif verb == "forget" then return eq_tbl.forget()
   else echo(eq_usage(), "cyan") end
end, })




_EQ_TEST = {
   parse_identify = parse_identify,
   fingerprint = fingerprint,
   ingest = ingest,
   resolve_item = resolve_item,
   precheck_equip = precheck_equip,
   parse_item_line = parse_item_line,
   parse_container_header = parse_container_header,
   parse_eq_line = parse_eq_line,
   parse_shop_row = parse_shop_row,
   parse_shop_list = parse_shop_list,
   shortlist_shop = shortlist_shop,
   ambiguous_list_arg = ambiguous_list_arg,
   is_consumable = is_consumable,
   looks_like_container = looks_like_container,
   build_compare_prompt = build_compare_prompt,
   build_shop_prompt = build_shop_prompt,
   build_slot_prompt = build_slot_prompt,
   slot_for_category = slot_for_category,
   variant_stats_str = variant_stats_str,
   norm_name = norm_name,
   first_kw = first_kw,
   split_flags = split_flags,
   describe_item_for_prompt = describe_item_for_prompt,

   scan_feed = scan_feed,
   scan_begin = function(mode)
      S.scan = S.scan or { eq = {}, inv = {}, containers = {}, quick = true }
      if mode == "eq" then S.scan.mode = "eq"; S.scan.eq = {}
      elseif mode == "inv" then S.scan.mode = "inv"; S.scan.inv = {}
      elseif mode then S.scan.mode = "cont"; S.scan.curcont = mode; S.scan.containers[mode] = S.scan.containers[mode] or {} end
      return S.scan
   end,
   scan_state = function() return S.scan end,
   scan_reset = function() S.scan = nil end,
   current_worn = current_worn,
   current_candidates = current_candidates,

   assign_ordinals = assign_ordinals,
   build_id_queue = build_id_queue,
   feed_id_stream = feed_id_stream,
   idq_start = idq_start,
   idq_get_result = function(ok) idq_get_result(ok) end,
   idq_put_result = function(ok) idq_put_result(ok) end,
   idq_advance = function(ok) if idq_advance then idq_advance(ok) end end,
   idq_state = function() return S.idq end,
   set_id_expect = function(name) S.id_expect = name end,
   items = items,
   session = session,
   eq_begin = eq_begin, eq_resolve = eq_resolve, eq_reject = eq_reject, eq_instant = eq_instant,
   reset = function() for k in pairs(items) do items[k] = nil end; for k in pairs(session) do session[k] = nil end end,
}

load_items()
echo("[eq] equipment adviser ready (model " .. cfg.model .. "). help(eq) for commands.", "dim")
