-- Equipment finder / comparer, driven by a LOCAL LLM (LM Studio at localhost:1234).
--
-- What it does:
--   * PASSIVELY parses EVERY `identify` block that appears in the game output — whether you or this
--     script triggered it — into a persistent per-item knowledge cache, so the more you identify the
--     smarter the adviser gets. `list <item>` in a shop emits the SAME block, so shop details feed the
--     same cache.
--   * `#eq scan` — reads worn gear (`equipment`), inventory (`inventory`), then `look in <container>`
--     for every container it finds, and reports counts per location.
--   * `#eq compare [item-or-slot]` — asks the model to review your loadout: per-slot keep/swap verdicts,
--     knowing (from identify data + your class/level/alignment) whether you can actually equip each item.
--   * `#eq shop` — at a shopkeeper, reads `list`, shortlists the wearable rows, pulls `list <item>` detail
--     for each, and asks the model what's worth buying given your gold and current gear.
--   * `#eq id <item>` — convenience: sends the game's `identify` (free for items <= level 30; higher-level
--     items need an identify scroll/spell, exactly as a player would).
--
-- ITEM NAMES ARE NOT UNIQUE on AlterAeon and there is no stable item id on the wire, so the cache keys a
-- name to a LIST of distinct variants (deduped by a stat fingerprint), each with a last-seen time. A name
-- with one known variant is used but labelled "from a previous identify — re-id to confirm"; a name with
-- several is surfaced as AMBIGUOUS ("re-identify the one you hold") and never silently resolved. An item
-- identified THIS SESSION while you're still holding it is the one trustworthy name->stats binding, tracked
-- separately and preferred over the persistent cache.
--
-- It uses the LOCAL model (ai_local_request) with a per-CALL model override — the smarter dense
-- qwen3.6-27b — so it never disturbs Trivia's pinned local model. Hot-reloadable: edit + `#ai reload`.
--
-- Controls: `#eq scan` · `#eq compare [slot|item]` · `#eq shop` · `#eq id <item>` · `#eq stats` · `#eq forget`.

local cfg = {
  home = os.getenv("HOME") or "",
  -- Comparisons/shop reviews need room to reason and enumerate; give the model a generous budget.
  max_tokens = 900,
  -- Same closed empty <think> prefill the pilot/Trivia use: qwen3.x otherwise spends the whole budget
  -- "thinking" and returns nothing. Harmless to non-reasoning models.
  think_prefill = "<think>\n\n</think>\n\n",
  -- The SMARTER dense model for crafted gear prompts, requested PER CALL so Trivia's pinned local model
  -- (a smaller MoE) is untouched. Override with EQ_MODEL if yours is named differently.
  model = os.getenv("EQ_MODEL") or "qwen3.6-27b-mlx@8bit",
  look_wait = 1.0,   -- seconds to let a collector's rows arrive before the next step
  shortlist_cap = 8, -- most shop rows we'll pull `list <item>` detail for
  id_gap = 0.4,      -- pause between auto-identify steps (be polite to the game/server)
  id_timeout = 4.0,  -- give up on one identify block if no result parses in this long
  id_combat_retry = 2.0, -- how often to re-check for combat-clear while the id pass is paused
}
cfg.dir = cfg.home .. "/Documents/MudClient"
cfg.cache_file = cfg.dir .. "/equipment_items.lua"

-- Survive `#ai reload`: keep the item cache, the this-session bindings, scan/shop buffers and generation
-- counter in a global, and bump an epoch so a model reply landing after a reload is dropped.
_EQUIP = _EQUIP or { items = {}, session = {}, gen = 0 }
_EQUIP.epoch = (_EQUIP.epoch or 0) + 1
local EPOCH = _EQUIP.epoch
local S = _EQUIP

-- items[name] = { variants = { [fingerprint] = variant, ... } }   (persistent, name -> LIST of variants)
-- session[name] = { fp, variant, ts }                             (this-session id while holding the item)
local items = S.items
local session = S.session

local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function strip_ansi(s) return (s or ""):gsub("\27%[[%d;]*%a", "") end
local function now() return os.time() end

local ARTICLE = { a = true, an = true, the = true, some = true, pair = true, of = true }
-- Cache key: lowercased, article-stripped, whitespace-collapsed, trailing-period-dropped. Matches an
-- inventory line ("a lost lead ring") to its identify display name ("a lost lead ring").
local function norm_name(s)
  s = trim((strip_ansi(s):lower():gsub("%s+", " "):gsub("%.%s*$", "")))
  s = s:gsub("^a ", ""):gsub("^an ", ""):gsub("^the ", ""):gsub("^some ", "")
  return trim(s)
end

-- The keyword AlterAeon expects for `identify`/`look in` is usually the last noun of the name:
-- "a small sack" -> "sack", "well made leather gloves" -> "gloves", "a lost lead ring" -> "ring".
local function first_kw(name)
  local last
  for w in (name or ""):gmatch("%a+") do if not ARTICLE[w:lower()] then last = w end end
  return last or trim(name or "")
end

-- ---- identify-block parsing ----------------------------------------------------------------------
-- The six class restriction flags and the alignment flags, from articles/equipment_flags. NECR is how the
-- Necromancer flag prints on the wire; map every class flag to the `state.classes` key it restricts.
local CLASS_TO_STATE = { MAGE = "Mage", CLERIC = "Cleric", THIEF = "Thief", WARRIOR = "Warrior",
                         DRUID = "Druid", NECR = "Necromancer", NECROMANCER = "Necromancer" }
local ALIGN_FLAGS = { ANTI_GOOD = true, ANTI_EVIL = true, ANTI_NEUTRAL = true,
                      ANTIGOOD = true, ANTIEVIL = true, ANTINEUTRAL = true, EVIL = true, GOOD = true }

-- Parse a full `identify`/`list <item>` block into a variant table. Returns nil if there's no "Item:" line.
--   Item: 'dull gray lead ring'
--   Weight: 1  Size: 0'1"  Total levels: 20   (you can't use this yet)  Item Quality: WELL CRAFTED
--   Type: ARMOR   Composition: FLESH, SKIN   Defense: 4 ac-apply
--   Weapon damage: 2 to 20 average, slice, 11 strength to use.
--   Object is:  GLOW ANTI_GOOD THIEF          (class + alignment + misc flags, space-separated)
--   Wear locations are:  FINGERS
--   Affects:  DAMROLL by 2
--   You are carrying a lost lead ring.        (or "You are wielding X." / "to start using X.")
local function parse_identify(block)
  if not block then return nil end
  block = strip_ansi(block)
  local iname = block:match("Item:%s*'(.-)'")
  if not iname then return nil end
  local v = { item_name = iname, flags = {}, class_flags = {}, align_flags = {},
              wear = {}, affects = {}, raw = trim(block) }
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
    elseif L:match("^You are carrying ") then
      v.display = norm_name(L:gsub("^You are carrying ", ""))
    elseif L:match("^You are wielding ") then
      v.display = norm_name(L:gsub("^You are wielding ", ""))
    elseif L:match("to start using ") then
      v.display = v.display or norm_name(L:match("to start using (.+)$") or "")
    end
  end
  -- Prefer the DISPLAY name (what appears in inventory listings) as the cache key; fall back to the
  -- identify keyword name. Both kept so callers can show either.
  v.name = (v.display and v.display ~= "" and v.display) or norm_name(iname)
  return v
end

-- A stat fingerprint: two blocks with the same fingerprint are the SAME variant. Built only from
-- meaningful fields (type, level reqs, defense, weapon, flags, wear, affects) — not cosmetic weight/size —
-- so re-identifying an item refreshes recency instead of forking a phantom variant.
local function fingerprint(v)
  local p = { "t=" .. (v.type or ""),
              "lv=" .. tostring(v.level or "") .. "/" .. tostring(v.total_levels or ""),
              "df=" .. tostring(v.defense or "") }
  if v.weapon then
    p[#p + 1] = "wp=" .. tostring(v.weapon.min) .. "-" .. tostring(v.weapon.max)
      .. (v.weapon.verb or "") .. "/" .. tostring(v.weapon.str)
  end
  local function sorted(list, f)
    local out = {}; for _, x in ipairs(list) do out[#out + 1] = f(x) end; table.sort(out); return table.concat(out, ",")
  end
  p[#p + 1] = "fl=" .. sorted(v.flags, function(x) return x end)
  p[#p + 1] = "wr=" .. sorted(v.wear, function(x) return x end)
  p[#p + 1] = "af=" .. sorted(v.affects, function(a) return a.stat .. "=" .. a.by end)
  return table.concat(p, "|")
end

-- ---- persistence (Lua serialization, like AIPilot's map) -----------------------------------------
local function ser(x)
  local t = type(x)
  if t == "number" or t == "boolean" then return tostring(x) end
  if t == "string" then return string.format("%q", x) end
  if t == "table" then
    local parts = {}
    for k, val in pairs(x) do
      local key = (type(k) == "number") and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
      parts[#parts + 1] = key .. "=" .. ser(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end

local save_timer
local function save_items()
  local f = io.open(cfg.cache_file, "w")
  if not f then return end
  f:write("return " .. ser(items))
  f:close()
end
-- Debounced write (cancellable-timer pattern, same as AlterAeon/AIPilot): a burst of identifies coalesces
-- into one write 2s after the last.
local function schedule_save()
  if cancel and save_timer then cancel(save_timer) end
  if after then save_timer = after(2, save_items) else save_items() end
end
local function load_items()
  local chunk = loadfile(cfg.cache_file)
  if not chunk then return end
  local ok, t = pcall(chunk)
  if ok and type(t) == "table" then
    for k in pairs(items) do items[k] = nil end
    for k, val in pairs(t) do items[k] = val end
  end
end

-- Fold a parsed variant into the cache: dedup by fingerprint (refresh recency on a repeat, add on a diff),
-- and record it as the this-session binding for its name (a fresh id always wins the session slot).
local function ingest(v)
  if not v or not v.name or v.name == "" then return end
  v.fp = fingerprint(v)
  v.last_seen = now()
  local entry = items[v.name]
  if not entry then entry = { variants = {} }; items[v.name] = entry end
  if entry.variants[v.fp] then
    entry.variants[v.fp].last_seen = v.last_seen        -- same variant seen again — just refresh recency
  else
    entry.variants[v.fp] = v                            -- a genuinely different variant of this name
  end
  session[v.name] = { fp = v.fp, variant = v, ts = v.last_seen }
  schedule_save()
end

-- Resolve a name to what we know, PREFERRING a this-session id (trustworthy while held):
--   session  -> identified this session; name->stats is trustworthy
--   cached   -> exactly one known variant; usable but "re-id to confirm"
--   multi    -> several known variants; AMBIGUOUS, must re-identify
--   unknown  -> never identified
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

-- ---- equippability -------------------------------------------------------------------------------
-- char = { name, classes = {Mage=8,...} (name->level) or nil, alignment = "good"/"neutral"/"evil"/nil,
--          str = number/nil, gold = number/nil }
-- Returns { ok = bool, reasons = {..} }. Alignment/strength checks apply only when those are known; the
-- game's own "(you can't use this yet)" verdict (level too high) and class-membership are always checked.
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

-- ---- inventory / equipment / container parsing ---------------------------------------------------
-- A single inventory/container line -> item name, or nil for non-items (headers, prompts, counts). Handles
-- both plain lines ("a red leather cap") and the count-prefixed container form ("(    1) a red leather cap").
local function parse_item_line(line)
  local L = trim(strip_ansi(line))
  if L == "" then return nil end
  if L:match("^<%d+hp") or L:match("^kxwt_") or L:match("^%[the human typed%]") or L:match("BLOCKSEP") then return nil end
  if L:match("^You are ") or L:find("contains:", 1, true) or L:match("items? total%.?$") then return nil end
  L = L:gsub("^%(%s*%d+%s*%)%s*", "")               -- drop a "(    1)" count prefix
  L = trim((L:gsub("%s*%(.-%)%s*$", "")))           -- drop a trailing "(light)"/"(glow)" tag
  local low = L:lower()
  if low == "" or low == "nothing" or low == "nothing." then return nil end
  return L
end

-- A container header: "(carried) a small sack contains:" / "(on ground) a cedar chest contains:".
-- Returns the container name ("a small sack") or nil.
local function parse_container_header(line)
  local L = trim(strip_ansi(line))
  local name = L:match("^%(.-%)%s*(.-)%s+contains:%s*$")
  return name and trim(name) or nil
end

-- An `equipment`/`eq` slot line -> slot, item. e.g.
--   "head        -              a circlet of dried vines"
--   "neck        - (rare)       a necklace of human ears"   (an optional (flag) column)
--   "weapon      - (rare)       a charred black staff"
local EQ_SLOTS = { head = true, neck = true, arms = true, wrist = true, hands = true, finger = true,
                   waist = true, legs = true, feet = true, held = true, weapon = true, shield = true,
                   back = true, ears = true, eyes = true, face = true, floating = true, body = true,
                   ["on body"] = true, ["about body"] = true }
local function parse_eq_line(line)
  local L = strip_ansi(line)
  local slot, rest = L:match("^(%a[%a ]-)%s+%-%s+(.+)$")
  if not slot then return nil end
  slot = trim(slot):lower()
  if not EQ_SLOTS[slot] then return nil end
  local item = rest:match("^%b()%s*(.+)$") or rest       -- strip an optional leading "(rare)" flag column
  item = norm_name(item)
  if item == "" then return nil end
  return slot, item
end

-- ---- shop `list` parsing -------------------------------------------------------------------------
-- A single shop-list row, or a category header, or nil.
--   Category: "[  Price] Worn on neck ---------------------------------------"  -> {category="Worn on neck"}
--   Item:     "[    28] (lvl   0) a wand of scorch"                             -> {price=28,level=0,name=...}
local function parse_shop_row(line)
  local L = strip_ansi(line)
  local cat = L:match("^%[%s*Price%]%s*(.-)%s*%-%-%-")
  if cat then return { category = trim(cat) } end
  local price, lvl, name = L:match("^%[%s*(%d+)%]%s*%(lvl%s*(%d+)%)%s*(.+)$")
  if price then return { price = tonumber(price), level = tonumber(lvl), name = trim(name) } end
  return nil
end

-- Parse a whole `list` capture into { seller, spell_shop, no_shop, rows = {{price,level,name,category}} }.
local function parse_shop_list(text)
  local out = { rows = {} }
  local cur_cat
  for raw in ((text or "") .. "\n"):gmatch("(.-)\n") do
    local L = strip_ansi(raw)
    if L:find("no shopkeeper", 1, true) or L:find("nothing here to list", 1, true) then out.no_shop = true end
    if L:find("spell castings may be purchased", 1, true) then out.spell_shop = true end
    local seller = L:match("^(.-) tells you, 'The following items are available")
    if seller then out.seller = seller end
    local r = parse_shop_row(L)
    if r then
      if r.category then cur_cat = r.category
      else r.category = cur_cat; out.rows[#out.rows + 1] = r end
    end
  end
  return out
end

-- Keep the plausible-upgrade (wearable/wieldable) rows; drop obvious consumables by keyword and cap the
-- count. Returns kept, skipped. A "Worn on.."/"Wielded" category always keeps (armor named like a potion
-- is still armor); everything else is filtered by consumable keyword first.
local CONSUMABLE_KW = { "scroll", "potion", "wand", "food", "drink", "bread", "waterskin", "ration",
                        "torch", "lantern", " oil", "bandage", "spellcomp", "vial", "elixir", "mushroom",
                        "pill", "cont light", "map of", "recall stone" }
local function is_consumable(name)
  local n = (name or ""):lower()
  for _, kw in ipairs(CONSUMABLE_KW) do if n:find(kw, 1, true) then return true end end
  return false
end
local function shortlist_shop(parsed, cap)
  cap = cap or 8
  local kept, skipped = {}, {}
  for _, r in ipairs(parsed.rows or {}) do
    local cat = (r.category or ""):lower()
    local worn = cat:find("worn") or cat:find("wield")
    if not worn and is_consumable(r.name) then
      skipped[#skipped + 1] = r
    elseif #kept < cap then
      kept[#kept + 1] = r
    else
      skipped[#skipped + 1] = r
    end
  end
  return kept, skipped
end

-- ---- prompt building (pure) ----------------------------------------------------------------------
-- Distilled equippability rules (from articles/equipment_flags + identify formats) — written INTO the
-- system prompt so the model reasons about restrictions instead of us dumping raw help.
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

local EQ_SYS = "You are an expert Alter Aeon equipment adviser. Given a character sheet and their gear "
  .. "with parsed identify stats, recommend what to wear.\n\n" .. EQ_RULES .. "\n\n"
  .. "Rules for your answer: NEVER recommend equipping anything marked CANNOT EQUIP, AMBIGUOUS, or "
  .. "unidentified — for AMBIGUOUS/unidentified items, tell the player to identify it first. Give a terse, "
  .. "structured reply: one line per slot (keep / swap-to-<item> / can't-equip-because-<reason>), then a "
  .. "short 'Top actions:' list. No preamble."

local EQ_SHOP_SYS = "You are an expert Alter Aeon shopping adviser. Given a character sheet, their current "
  .. "gear, and a shop's items with prices, decide what is worth buying.\n\n" .. EQ_RULES .. "\n\n"
  .. "Rules for your answer: NEVER say BUY for an item marked CANNOT EQUIP, AMBIGUOUS, or unidentified. "
  .. "Weigh price against your gold and whether it upgrades the slot you'd wear it in. Reply terse: one "
  .. "line per shop item (BUY/SKIP + one-line why), then the single best purchase (or 'buy nothing')."

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

-- Compact stat string for a known variant.
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

-- One prompt line for an item, resolving its knowledge status. NEVER silently picks a variant for a
-- multi-variant name — it surfaces the ambiguity to the model instead.
local function describe_item_for_prompt(name, char)
  local r = resolve_item(name)
  if r.status == "unknown" then
    return string.format("- %s: unidentified — cannot judge; run `#eq id %s`", name, first_kw(name))
  elseif r.status == "multi" then
    return string.format("- %s: AMBIGUOUS — %d different '%s' variants known; re-identify the one you hold (`#eq id %s`)",
      name, r.count, name, first_kw(name))
  else
    local v = r.variant
    local pc = precheck_equip(v, char)
    local verdict = pc.ok and "equippable" or ("CANNOT EQUIP: " .. table.concat(pc.reasons, "; "))
    local src = (r.status == "session") and "identified this session (you're holding it)"
      or "stats from a previous identify — re-id to confirm"
    return string.format("- %s [%s] — %s — %s", name, variant_stats_str(v), verdict, src)
  end
end

-- Build the compare prompt. worn = {{slot, name}}, candidates = {name,...}. Pure: resolves each name from
-- the shared cache and formats. Returns system, user.
local function build_compare_prompt(char, worn, candidates, focus)
  local u = { "=== CHARACTER ===", char_sheet_lines(char) }
  if focus and focus ~= "" then u[#u + 1] = "\n=== FOCUS ===\nAdvise specifically about: " .. focus end
  u[#u + 1] = "\n=== CURRENTLY WORN ==="
  if #worn == 0 then u[#u + 1] = "(no worn gear recorded — run #eq scan)" end
  for _, w in ipairs(worn) do
    u[#u + 1] = (w.slot and (w.slot .. ": ") or "- ") .. (describe_item_for_prompt(w.name, char):gsub("^%- ", ""))
  end
  u[#u + 1] = "\n=== CANDIDATE ITEMS (carried / in containers) ==="
  if #candidates == 0 then u[#u + 1] = "(none)" end
  for _, name in ipairs(candidates) do u[#u + 1] = describe_item_for_prompt(name, char) end
  u[#u + 1] = "\n=== TASK ==="
  u[#u + 1] = (focus and focus ~= "") and "Advise on the focus above." or "Review the whole loadout, slot by slot."
  return EQ_SYS, table.concat(u, "\n")
end

-- Build the shop prompt. kept = shortlisted shop rows ({price, level, name, category}). Pure.
local function build_shop_prompt(char, worn, kept)
  local u = { "=== CHARACTER ===", char_sheet_lines(char), "\n=== CURRENTLY WORN ===" }
  if #worn == 0 then u[#u + 1] = "(no worn gear recorded)" end
  for _, w in ipairs(worn) do
    u[#u + 1] = (w.slot and (w.slot .. ": ") or "- ") .. (describe_item_for_prompt(w.name, char):gsub("^%- ", ""))
  end
  u[#u + 1] = "\n=== SHOP ITEMS FOR SALE ==="
  if #kept == 0 then u[#u + 1] = "(nothing wearable shortlisted)" end
  for _, r in ipairs(kept) do
    local info = describe_item_for_prompt(r.name, char):gsub("^%- ", "")
    u[#u + 1] = string.format("- [%s gold] (shop lvl %s) %s", tostring(r.price or "?"), tostring(r.level or "?"), info)
  end
  u[#u + 1] = "\n=== TASK ===\nYou have " .. (char.gold and (char.gold .. " gold") or "unknown gold")
    .. ". For each shop item say BUY or SKIP with one line why."
  return EQ_SHOP_SYS, table.concat(u, "\n")
end

-- ---- character sheet from the shared `state` -----------------------------------------------------
local function char_from_state()
  local classes = {}
  for cls, c in pairs((state and state.classes) or {}) do classes[cls] = c.level end
  return {
    name = state and state.name,
    classes = next(classes) and classes or nil,
    gold = state and state.gold,
    alignment = state and state.alignment,   -- not a kxwt field; "unknown" unless something scraped it
    str = state and state.str,
  }
end

-- ============ runtime plumbing (triggers, collectors, model calls) ============
-- (Everything below is stream/timer-driven and touches the host; the pure helpers above are what specs
--  exercise via _EQ_TEST.)

local function combat_block()
  if in_combat and in_combat() then echo("[eq] not while you're fighting.", "yellow"); return true end
  return false
end

-- One local-model call with the per-request dense-model override, generation-guarded so a reply landing
-- after `#ai reload` or a newer request is dropped.
local function run_model(sys, user, on_reply)
  if not ai_local_request then echo("[eq] no local model available (ai_local_request missing — relaunch).", "red"); return end
  S.gen = (S.gen or 0) + 1
  local g = S.gen
  ai_local_request(sys, user, cfg.max_tokens, cfg.think_prefill, function(reply, err)
    if EPOCH ~= _EQUIP.epoch or g ~= S.gen then return end
    if err then echo("[eq] model error: " .. tostring(err), "red"); return end
    on_reply(reply or "")
  end, cfg.model)
end

-- ---- PASSIVE identify capture (always on) --------------------------------------------------------
-- Every identify/list block that scrolls by is folded into the cache, whoever triggered it. We capture
-- from the "Item: '...'" header until a terminator (prompt/blank/typed-echo), then parse+ingest.
local function finalize_id()
  local cap = S.id_cap
  S.id_cap = nil
  if not cap then return end
  local v = parse_identify(table.concat(cap.lines, "\n"))
  if v then ingest(v) end
end
trigger([[^Item: '(.+)']], function(line)
  S.id_cap = { lines = { strip_ansi(line) } }
end)
trigger([[.*]], function(line)
  if not S.id_cap then return end
  local L = strip_ansi(line)
  if L:match("^<%d+hp") or trim(L) == "" or L:match("^%[the human typed%]") or L:match("^kxwt_") then
    finalize_id(); return
  end
  local cap = S.id_cap
  cap.lines[#cap.lines + 1] = L
  if #cap.lines > 40 then finalize_id() end   -- safety: never grow unbounded on a missed terminator
end)

-- ---- #eq scan: worn gear + inventory + look-in every container -----------------------------------
local CONTAINER_KW = { "sack", "bag", "backpack", "pack", "pouch", "chest", "box", "quiver", "basket",
                       "container", "purse", "case", "satchel", "crate", "barrel", "trunk", "distortion" }
local function looks_like_container(name)
  local r = resolve_item(name)
  if r.variant and r.variant.type == "CONTAINER" then return true end
  local n = (name or ""):lower()
  for _, kw in ipairs(CONTAINER_KW) do if n:find(kw, 1, true) then return true end end
  return false
end

-- Feed a streamed line into the active scan (mode set by the section-header triggers below).
local function scan_feed(line)
  local sc = S.scan
  if not sc or not sc.mode then return end
  local L = strip_ansi(line)
  if L:match("^<%d+hp") or trim(L) == "" or L:match("^%[the human typed%]") or L:match("^kxwt_") then
    sc.mode = nil; return
  end
  if sc.mode == "eq" then
    local slot, item = parse_eq_line(L)
    if item then sc.eq[#sc.eq + 1] = { slot = slot, item = item } end
  elseif sc.mode == "inv" then
    local it = parse_item_line(L)
    if it then sc.inv[#sc.inv + 1] = it end
  elseif sc.mode == "cont" then
    local it = parse_item_line(L)
    if it and sc.curcont then
      sc.containers[sc.curcont] = sc.containers[sc.curcont] or {}
      table.insert(sc.containers[sc.curcont], it)
    end
  end
end

local function install_scan_triggers()
  trigger([[^You are using:]],   function() S.scan.mode = "eq";  S.scan.eq = {} end,  { class = "eq" })
  trigger([[^You are wearing:]], function() S.scan.mode = "eq";  S.scan.eq = {} end,  { class = "eq" })
  trigger([[^You are carrying:]], function() S.scan.mode = "inv"; S.scan.inv = {} end, { class = "eq" })
  trigger([[contains:]], function(line)
    local cname = parse_container_header(line)
    S.scan.mode = "cont"; S.scan.curcont = cname or "a container"
    S.scan.containers[S.scan.curcont] = S.scan.containers[S.scan.curcont] or {}
  end, { class = "eq" })
  trigger([[.*]], function(line) scan_feed(line) end, { class = "eq" })
end

local function finish_scan()
  if not S.scan then return end
  if class_remove then class_remove("eq") end
  local sc = S.scan
  -- Rebuild the possession set and invalidate stale session bindings (items no longer on us).
  local possess = {}
  for _, e in ipairs(sc.eq) do possess[e.item] = true end
  for _, n in ipairs(sc.inv) do possess[norm_name(n)] = true end
  local ccount = 0
  for _, its in pairs(sc.containers) do ccount = ccount + #its; for _, n in ipairs(its) do possess[norm_name(n)] = true end end
  for name in pairs(session) do if not possess[name] then session[name] = nil end end
  echo(string.format("[eq] scan: %d worn, %d in inventory, %d in %d container(s). Now try `#eq compare`.",
    #sc.eq, #sc.inv, ccount, (function() local n = 0; for _ in pairs(sc.containers) do n = n + 1 end; return n end)()), "cyan")
end

-- Send `look in <container>` for each detected container, one at a time with a beat between, then finish.
local function scan_containers(list, i)
  if EPOCH ~= _EQUIP.epoch then return end
  if i > #list then after(cfg.look_wait, finish_scan); return end
  send("look in " .. first_kw(list[i]))
  after(cfg.look_wait, function() scan_containers(list, i + 1) end)
end

local function eq_scan()
  if combat_block() then return end
  S.scan = { eq = {}, inv = {}, containers = {}, mode = nil, curcont = nil }
  install_scan_triggers()
  echo("[eq] scanning gear, inventory, and containers…", "cyan")
  send("equipment")
  after(cfg.look_wait, function()
    send("inventory")
    after(cfg.look_wait, function()
      local conts = {}
      for _, n in ipairs(S.scan.inv) do if looks_like_container(n) then conts[#conts + 1] = n end end
      scan_containers(conts, 1)
    end)
  end)
end

-- ---- current loadout (from the last scan, else the shared `state`) --------------------------------
local function current_worn()
  if S.scan and S.scan.eq and #S.scan.eq > 0 then
    local out = {}; for _, e in ipairs(S.scan.eq) do out[#out + 1] = { slot = e.slot, name = e.item } end; return out
  end
  local out = {}
  for _, line in ipairs((state and state.equipment) or {}) do
    local slot, item = parse_eq_line(line)
    if item then out[#out + 1] = { slot = slot, name = item } end
  end
  return out
end
local function current_candidates()
  local seen, out = {}, {}
  local function add(n) n = norm_name(n); if n ~= "" and not seen[n] then seen[n] = true; out[#out + 1] = n end end
  if S.scan and ((S.scan.inv and #S.scan.inv > 0) or next(S.scan.containers or {})) then
    for _, n in ipairs(S.scan.inv or {}) do add(n) end
    for _, its in pairs(S.scan.containers or {}) do for _, n in ipairs(its) do add(n) end end
  else
    for _, n in ipairs((state and state.inventory) or {}) do add(n) end
  end
  return out
end

-- ---- #eq compare ---------------------------------------------------------------------------------
local function eq_compare(focus)
  focus = trim(focus)
  local char = char_from_state()
  local worn, cands = current_worn(), current_candidates()
  if #worn == 0 and #cands == 0 then echo("[eq] nothing to compare — run `#eq scan` first.", "yellow"); return end
  local sys, user = build_compare_prompt(char, worn, cands, focus)
  echo("[eq] asking " .. cfg.model .. " to review your gear…", "cyan")
  run_model(sys, user, function(reply) echo("[eq] " .. trim(reply), "cyan") end)
end

-- ---- #eq id ---------------------------------------------------------------------------------------
local function eq_id(arg)
  arg = trim(arg)
  if arg == "" then echo("[eq] usage: #eq id <item keyword>", "yellow"); return end
  if combat_block() then return end
  echo("[eq] identifying '" .. arg .. "' (higher-level items need an identify scroll/spell)…", "cyan")
  send("identify " .. arg)   -- the passive capture folds the resulting block into the cache
end

-- ---- #eq shop ------------------------------------------------------------------------------------
local function finish_shop()
  if not S.shop then return end
  local parsed = parse_shop_list(table.concat(S.shop.rows_text, "\n"))
  if parsed.no_shop then echo("[eq] you're not at a shop (no shopkeeper/donation/priest/guildmaster here).", "yellow"); return end
  if #parsed.rows == 0 then echo("[eq] nothing listed here to buy.", "yellow"); return end
  local kept, skipped = shortlist_shop(parsed, cfg.shortlist_cap)
  echo(string.format("[eq] shop: %d items, shortlisted %d, skipped %d (consumables/overflow).",
    #parsed.rows, #kept, #skipped), "cyan")
  if #kept == 0 then echo("[eq] no wearable/wieldable upgrades to evaluate here.", "yellow"); return end
  S.shop.kept = kept
  -- Pull `list <item>` detail for each shortlisted row (passively ingested), then ask the model.
  local function detail(i)
    if EPOCH ~= _EQUIP.epoch then return end
    if i > #kept then
      local sys, user = build_shop_prompt(char_from_state(), current_worn(), kept)
      echo("[eq] asking " .. cfg.model .. " what's worth buying…", "cyan")
      run_model(sys, user, function(reply) echo("[eq] " .. trim(reply), "cyan") end)
      return
    end
    send("list " .. first_kw(kept[i].name))
    after(cfg.look_wait, function() detail(i + 1) end)
  end
  detail(1)
end

local function eq_shop()
  if combat_block() then return end
  S.shop = { rows_text = {}, collecting = true }
  trigger([[.*]], function(line)
    if S.shop and S.shop.collecting then S.shop.rows_text[#S.shop.rows_text + 1] = strip_ansi(line) end
  end, { class = "eqshop" })
  echo("[eq] reading the shop's list…", "cyan")
  send("list")
  after(cfg.look_wait, function()
    if S.shop then S.shop.collecting = false end
    if class_remove then class_remove("eqshop") end
    finish_shop()
  end)
end

-- ---- #eq stats / forget / usage ------------------------------------------------------------------
local function eq_stats()
  local names, variants = 0, 0
  for _, e in pairs(items) do names = names + 1; for _ in pairs(e.variants) do variants = variants + 1 end end
  local sess = 0; for _ in pairs(session) do sess = sess + 1 end
  echo(string.format("[eq] cache: %d item names, %d total variants, %d this-session id(s). Model: %s.",
    names, variants, sess, cfg.model), "cyan")
end

local function eq_usage()
  return "[eq] usage: #eq scan | compare [slot|item] | shop | id <item> | stats | forget"
end

if command then command("eq", function(rest)
  rest = trim(rest)
  local verb = (rest:match("^%S*") or ""):lower()
  local arg = rest:match("^%S+%s+(.*)$") or ""
  if verb == "scan" then eq_scan()
  elseif verb == "compare" or verb == "cmp" then eq_compare(arg)
  elseif verb == "id" or verb == "identify" then eq_id(arg)
  elseif verb == "shop" then eq_shop()
  elseif verb == "stats" or verb == "cache" then eq_stats()
  elseif verb == "forget" then
    for k in pairs(items) do items[k] = nil end
    for k in pairs(session) do session[k] = nil end
    save_items(); echo("[eq] cleared the item cache")
  else echo(eq_usage(), "cyan") end
end) end

-- Pure helpers exposed for the test harness (Scripts/tests/equipment_spec.lua). The cache tables are
-- exposed too so specs can seed/inspect variant dedup, ambiguity, and session-binding preference.
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
  is_consumable = is_consumable,
  looks_like_container = looks_like_container,
  build_compare_prompt = build_compare_prompt,
  build_shop_prompt = build_shop_prompt,
  variant_stats_str = variant_stats_str,
  norm_name = norm_name,
  first_kw = first_kw,
  items = items,
  session = session,
  reset = function() for k in pairs(items) do items[k] = nil end; for k in pairs(session) do session[k] = nil end end,
}

load_items()
echo("[eq] equipment adviser ready (model " .. cfg.model .. "). `#eq` for commands.", "dim")
