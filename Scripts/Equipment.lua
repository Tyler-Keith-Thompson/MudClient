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
-- qwen3.6-27b — so it never disturbs Trivia's pinned local model. Hot-reloadable: edit + pilot.reload().
--
-- Controls: eq.scan(['quick']) · eq.compare([slot|item]) · eq.shop() · eq.id(item) · eq.stats() · eq.forget()  (help(eq)).

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

-- Survive pilot.reload(): keep the item cache, the this-session bindings, scan/shop buffers and generation
-- counter in a global, and bump an epoch so a model reply landing after a reload is dropped.
_EQUIP = _EQUIP or { items = {}, session = {}, gen = 0 }
_EQUIP.epoch = (_EQUIP.epoch or 0) + 1
local EPOCH = _EQUIP.epoch
local S = _EQUIP

-- Reload safety: a hot-reload (pilot.reload()) wipes every trigger/timer, so an in-flight auto-identify
-- queue is orphaned. Drop it — its pending timers no-op on the EPOCH check — and warn loudly if a
-- container item was OUT of its container when the reload hit, so the user knows to put it back.
if S.idq then
  if S.idq.got and S.idq.cur then
    echo("[eq] reload interrupted the identify pass — '" .. tostring(S.idq.cur.name)
      .. "' may still be OUT of its container; check your inventory and put it back.", "red")
  end
  S.idq = nil
end
S.id_expect = nil
S.id_cap = nil

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
    elseif L:match("^You are carrying ") and not L:match("^You are carrying %d") then
      -- "You are carrying a chameleon ring." (a display line) — NOT "You are carrying 5/9 items ...".
      v.display = norm_name(L:gsub("^You are carrying ", ""))
    elseif L:match("^You are wearing ") then
      -- Worn items report their display name as "You are wearing a horned imp-hide hood." — the live
      -- wire form the earlier trace mining missed (traces only had carrying/wielding samples).
      v.display = norm_name(L:gsub("^You are wearing ", ""))
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
    return string.format("- %s: unidentified — cannot judge; run eq.id('%s')", name, first_kw(name))
  elseif r.status == "multi" then
    return string.format("- %s: AMBIGUOUS — %d different '%s' variants known; re-identify the one you hold (eq.id('%s'))",
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
  if #worn == 0 then u[#u + 1] = "(no worn gear recorded — run eq.scan())" end
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
-- after pilot.reload() or a newer request is dropped.
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
-- Every identify/list block that scrolls by is folded into the cache, whoever triggered it.
--
-- LIVE WIRE FORMAT (from a raw session capture — the earlier trace mining was misleading because traces
-- are POST-gag, so the kxwt_ wrappers are absent there):
--
--   kxwt_id_start                                          <- gagged, but triggers still fire on it
--   Item: 'imp scalp horned imp-hide hide hood'            <- the KEYWORD string (not the display name)
--   Weight: ...  / Type: ... / Object is: ... / Affects: ...
--                                                          <- TWO blank lines here
--   a horned imp-hide hood is WELL CRAFTED in quality.     <- quality footer
--   A horned imp-hide hood has not much room for improvement.
--   kxwt_id_end                                            <- gagged; marks the body's end
--   You are wearing a horned imp-hide hood.                <- the DISPLAY name (worn items say "wearing")
--
-- The OLD capture had three fatal bugs against this: (1) it terminated on the FIRST blank line — long
-- before the display line — so v.display was never set; (2) parse_identify didn't recognise "You are
-- wearing"; (3) so blocks were cached under the KEYWORD name ("imp scalp horned imp-hide hide hood")
-- while inventory/equipment listings show the DISPLAY name ("a horned imp-hide hood") — every resolve
-- missed and everything read "unidentified". We now capture THROUGH the display line, skip interleaved
-- kxwt_ lines instead of terminating on them, and (for our own queued/#eq id requests) bind the block to
-- the exact possession-list name we asked about via S.id_expect.
local idq_advance   -- forward decl: finalize_id notifies the auto-identify queue when a block parses.
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
        matched = false            -- keyword/ordinal collision: we identified a DIFFERENT item than asked
      else
        v.name = expect            -- bind to the EXACT possession-list entry the queue/#eq id asked about
      end
    end
    ingest(v)
  end
  if idq_advance then idq_advance(v ~= nil and matched) end
end
local function id_begin() S.id_cap = { lines = {} } end
local function id_feed(line)
  local cap = S.id_cap
  if not cap then return end
  local L = strip_ansi(line)
  if L:match("^kxwt_id_end") then cap.body_done = true; return end   -- body done; display line follows
  if L:match("^kxwt_") then return end                               -- interleaved protocol line: skip
  -- The definitive end AND the display-name binding: "You are (wearing|carrying|wielding) <display>."
  local disp = L:match("^You are wearing (.+)$") or L:match("^You are wielding (.+)$")
    or (L:match("^You are carrying (.+)$") and not L:match("^You are carrying %d") and L:match("^You are carrying (.+)$"))
  if disp then cap.lines[#cap.lines + 1] = L; finalize_id(); return end
  -- Hard boundaries for the no-display-line case (item on ground / shop `list`, or replay without kxwt).
  if L:match("^<%d+hp") or L:match("^%[the human typed%]") then finalize_id(); return end
  if cap.body_done and trim(L) ~= "" then finalize_id(); return end  -- kxwt_id_end passed, no display line
  cap.lines[#cap.lines + 1] = L
  if #cap.lines > 60 then finalize_id() end   -- safety: never grow unbounded on a missed terminator
end
trigger([[^kxwt_id_start]], function() id_begin() end)
trigger([[^Item: '(.+)']], function() if not S.id_cap then id_begin() end end)  -- replay/#test have no kxwt_
trigger([[.*]], function(line) id_feed(line) end)

-- Test helper: faithfully replays the processLine dispatch of the id-capture triggers over a line list.
local function feed_id_stream(lines)
  for _, line in ipairs(lines) do
    if line:match("^kxwt_id_start") then id_begin()
    elseif line:match("^Item: '") and not S.id_cap then id_begin() end
    id_feed(line)
  end
end

-- ---- auto-identify queue (the heart of `#eq scan`) ----------------------------------------------
-- Scan collects NAMES; on its own that's inert — resolve_item can't judge an item it's never seen the
-- stats of. So after collection we walk everything that lacks a trustworthy binding and identify it,
-- paced one at a time, folding each block into the cache via the passive capture above.
--
-- Ground truth for the mechanics below is a raw session where the user did all of this by hand:
--   * identify is a plain command that works on anything you CARRY or WEAR: `identify <keyword>`.
--   * a duplicate keyword is disambiguated by an ordinal PREFIX counted in listing order within a
--     scope: `ring`, `2.ring`, `3.ring`. identify's scope is worn+carried together, so ordinals must be
--     assigned across the WHOLE person list (skipped/known items still occupy an ordinal slot), or a
--     `2.ring` targets the wrong ring.
--   * items INSIDE a container can't be identified in place — the user pulled each out and put it back:
--       get <kw> <container-kw>   ->  "You get <display> from a small sack."
--       identify <kw>             ->  the id block
--       put <kw> <container-kw>   ->  "You put <display> in a small sack."
--     Failure forms seen: "You don't see anything named 'x' in a small sack." / "You can't carry that
--     many items." (get); "You don't seem to be carrying anything named 'x'." (identify).

-- Assign the game's `N.keyword` ordinals across an ordered entry list: entries that share a first_kw get
-- bare kw, then 2.kw, 3.kw ... in list order (how the game counts within a scope). Pure/testable.
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

-- Build the identify work-list from a scan's collected possessions. worn/inv are ordered display-name
-- lists; containers is { [container-display] = { item-display, ... } }. Skips items already identified
-- THIS session (they're trustworthy); includes unknown, ambiguous(multi), and cached-but-stale — re-id
-- to confirm is exactly the point. Dedups identical display names within a scope (identical items have
-- identical stats — identify once). Returns queue, known_count. Pure/testable.
local function build_id_queue(worn, inv, containers)
  local queue, known, seen = {}, 0, {}
  local function consider(e, container)
    if not e.name or e.name == "" then return end
    local dkey = (container or "person") .. "|" .. e.name
    if seen[dkey] then return end
    seen[dkey] = true
    local r = resolve_item(e.name)
    if r.status == "session" then known = known + 1; return end
    queue[#queue + 1] = { name = e.name, kw = e.kw, base_kw = e.base_kw, ordinal = e.ordinal,
                          status = r.status, container = container }
  end
  -- identify sees worn + carried as ONE scope, so ordinals span the combined list in listing order.
  local person = {}
  for _, n in ipairs(worn or {}) do person[#person + 1] = { name = norm_name(n) } end
  for _, n in ipairs(inv or {}) do person[#person + 1] = { name = norm_name(n) } end
  assign_ordinals(person)
  for _, e in ipairs(person) do consider(e, nil) end
  -- each container is its own scope for `get N.kw <container>`.
  for cname, list in pairs(containers or {}) do
    local cont = {}
    for _, n in ipairs(list or {}) do cont[#cont + 1] = { name = norm_name(n) } end
    assign_ordinals(cont)
    for _, e in ipairs(cont) do consider(e, cname) end
  end
  return queue, known
end

-- Forward decls for the mutually-recursive phase machine.
local idq_next_entry, idq_do_get, idq_do_identify, idq_do_put, idq_gap_then_next, idq_finish, idq_put_result_fail

local function idq_clear_timer()
  if S.idq and S.idq.timer and cancel then cancel(S.idq.timer) end
  if S.idq then S.idq.timer = nil end
end
local function idq_arm(fn)
  idq_clear_timer()
  if after and S.idq then S.idq.timer = after(cfg.id_timeout, fn) end
end

idq_gap_then_next = function()
  local q = S.idq; if not q then return end
  q.phase = "gap"
  if after then q.timer = after(cfg.id_gap, function() q.timer = nil; idq_next_entry() end)
  else idq_next_entry() end
end

idq_finish = function()
  local q = S.idq; if not q then return end
  idq_clear_timer()
  if class_remove then class_remove("eqid") end
  S.idq = nil
  echo(string.format("[eq] identify pass: %d identified, %d failed, %d already known.",
    q.ident, q.failed, q.known), "cyan")
  if #q.left_out > 0 then
    echo("[eq] WARNING — could NOT return to their container, they are ON YOU now: "
      .. table.concat(q.left_out, ", ") .. " — put them back manually.", "red")
  end
  echo("[eq] now try eq.compare().", "cyan")
end

idq_next_entry = function()
  local q = S.idq; if not q then return end
  if EPOCH ~= _EQUIP.epoch then return end          -- died on reload
  if in_combat and in_combat() then                 -- pause (don't advance) until combat clears
    if not q.paused_msg then echo("[eq] identify pass paused (in combat) — resuming when clear.", "yellow"); q.paused_msg = true end
    if after then q.timer = after(cfg.id_combat_retry, function() q.timer = nil; idq_next_entry() end) end
    return
  end
  q.paused_msg = nil
  q.i = q.i + 1
  if q.i > #q.list then idq_finish(); return end
  q.cur = q.list[q.i]; q.got = false
  echo(string.format("[eq] identifying %d/%d: %s%s", q.i, #q.list, q.cur.name,
    q.cur.container and (" (from " .. q.cur.container .. ")") or ""), "cyan")
  if q.cur.container then idq_do_get() else idq_do_identify() end
end

idq_do_get = function()
  local q = S.idq; local e = q.cur
  q.phase = "get"
  send(string.format("get %s %s", e.kw, first_kw(e.container)))
  idq_arm(function() q.timer = nil; if S.idq and S.idq.phase == "get" then S.idq.failed = S.idq.failed + 1; idq_gap_then_next() end end)
end

-- get result signal (from triggers). ok=true => item is now in inventory and MUST be put back.
local function idq_get_result(ok)
  local q = S.idq; if not q or q.phase ~= "get" then return end
  idq_clear_timer()
  if not ok then q.failed = q.failed + 1; idq_gap_then_next(); return end
  q.got = true
  idq_do_identify()
end

idq_do_identify = function()
  local q = S.idq; local e = q.cur
  q.phase = "id"
  S.id_expect = e.name
  -- A just-gotten container item is now in inventory; use its bare keyword and let finalize_id verify the
  -- parsed display against S.id_expect (guards against another same-keyword item already in inventory).
  send("identify " .. (e.container and e.base_kw or e.kw))
  idq_arm(function() q.timer = nil; if idq_advance then idq_advance(false) end end)
end

-- identify result (from finalize_id on a parsed block, or the failure trigger / timeout). Assigned to the
-- forward-declared upvalue so finalize_id (defined earlier) can see it.
idq_advance = function(ok)
  local q = S.idq; if not q or q.phase ~= "id" then return end
  idq_clear_timer()
  S.id_expect = nil
  if ok then q.ident = q.ident + 1 else q.failed = q.failed + 1 end
  if q.got then idq_do_put() else idq_gap_then_next() end
end

idq_do_put = function()
  local q = S.idq; local e = q.cur
  q.phase = "put"
  send(string.format("put %s %s", e.base_kw, first_kw(e.container)))
  idq_arm(function() q.timer = nil; if S.idq and S.idq.phase == "put" then idq_put_result_fail() end end)
end
-- put result signals.
idq_put_result_fail = function()
  local q = S.idq; if not q or q.phase ~= "put" then return end
  idq_clear_timer(); q.got = false
  q.left_out[#q.left_out + 1] = q.cur.name
  idq_gap_then_next()
end
local function idq_put_result(ok)
  local q = S.idq; if not q or q.phase ~= "put" then return end
  if not ok then idq_put_result_fail(); return end
  idq_clear_timer(); q.got = false
  idq_gap_then_next()
end

local function idq_install_triggers()
  trigger([[^You get .+ from ]],                       function() idq_get_result(true) end,  { class = "eqid" })
  trigger([[^You don't see anything named]],           function() idq_get_result(false) end, { class = "eqid" })
  trigger([[^You can't carry that many items]],        function() idq_get_result(false) end, { class = "eqid" })
  trigger([[^You can't safely carry]],                 function() idq_get_result(false) end, { class = "eqid" })
  trigger([[^You put .+ in ]],                         function() idq_put_result(true) end,  { class = "eqid" })
  trigger([[^You don't seem to be carrying anything named]], function()
    if S.idq and S.idq.phase == "id" and idq_advance then idq_advance(false) end
  end, { class = "eqid" })
end

local function idq_start(queue, known)
  if #queue == 0 then
    echo(string.format("[eq] nothing to auto-identify — %d item(s) already identified this session.", known), "cyan")
    echo("[eq] now try eq.compare().", "cyan")
    return
  end
  S.idq = { list = queue, i = 0, known = known, ident = 0, failed = 0, left_out = {},
            phase = nil, cur = nil, got = false, timer = nil }
  idq_install_triggers()
  echo(string.format("[eq] auto-identifying %d item(s) (%d already known this session)…", #queue, known), "cyan")
  idq_next_entry()
end

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
  if L:match("^kxwt_") then return end   -- interleaved protocol line: skip, don't end the section
  if L:match("^<%d+hp") or trim(L) == "" or L:match("^%[the human typed%]") then
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
  echo(string.format("[eq] scan: %d worn, %d in inventory, %d in %d container(s).",
    #sc.eq, #sc.inv, ccount, (function() local n = 0; for _ in pairs(sc.containers) do n = n + 1 end; return n end)()), "cyan")
  if sc.quick then
    echo("[eq] quick scan — collected names only (no identify). Run eq.scan() to auto-identify.", "dim")
    echo("[eq] now try eq.compare() (items you've never identified will read 'unidentified').", "cyan")
    return
  end
  -- The point of `#eq scan`: identify everything that lacks a trustworthy binding so compare/shop can
  -- actually reason about stats. worn/inv/containers feed the paced auto-identify queue.
  local worn = {}
  for _, e in ipairs(sc.eq) do worn[#worn + 1] = e.item end
  local queue, known = build_id_queue(worn, sc.inv, sc.containers)
  idq_start(queue, known)
end

-- Send `look in <container>` for each detected container, one at a time with a beat between, then finish.
local function scan_containers(list, i)
  if EPOCH ~= _EQUIP.epoch then return end
  if i > #list then after(cfg.look_wait, finish_scan); return end
  send("look in " .. first_kw(list[i]))
  after(cfg.look_wait, function() scan_containers(list, i + 1) end)
end

local function eq_scan(mode)
  if combat_block() then return end
  local quick = (trim(mode or ""):lower() == "quick")
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
  if #worn == 0 and #cands == 0 then echo("[eq] nothing to compare — run eq.scan() first.", "yellow"); return end
  local sys, user = build_compare_prompt(char, worn, cands, focus)
  echo("[eq] asking " .. cfg.model .. " to review your gear…", "cyan")
  run_model(sys, user, function(reply) echo("[eq] " .. trim(reply), "cyan") end)
end

-- ---- #eq id ---------------------------------------------------------------------------------------
local function eq_id(arg)
  arg = trim(arg)
  if arg == "" then echo("[eq] usage: eq.id('<item keyword>')", "yellow"); return end
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
  return "[eq] usage: eq.scan(['quick']) | eq.compare([slot|item]) | eq.shop() | eq.id(item) | eq.stats() | eq.forget()  —  help(eq)"
end

-- ---- public command surface: the `eq` table ------------------------------------------------------
-- First-class, documented Lua API (Phase-2 migration off the old `command("eq", …)` string parser).
-- Every member is individually doc()'d so `help(eq)` lists them, and the table is *callable* so the
-- legacy typed `#eq scan` (rewritten by the host to `eq("scan")`) still dispatches to the right member.
eq = {}

function eq.scan(mode)
  if type(mode) == "table" then mode = mode.quick and "quick" or "" end
  eq_scan(mode)
end
function eq.quick() eq_scan("quick") end
function eq.compare(slot_or_item) eq_compare(slot_or_item) end
function eq.id(item) eq_id(item) end
function eq.shop() eq_shop() end
function eq.stats() eq_stats() end
function eq.forget()
  for k in pairs(items) do items[k] = nil end
  for k in pairs(session) do session[k] = nil end
  save_items(); echo("[eq] cleared the item cache")
end

doc(eq.scan, { name = "eq.scan", sig = "eq.scan(['quick'])", group = "equipment",
  text = "Read worn gear, inventory, and every container, then auto-identify anything not cached so compare/shop can reason about stats. Pass 'quick' (or eq.quick()) to only collect names." })
doc(eq.quick, { name = "eq.quick", sig = "eq.quick()", group = "equipment",
  text = "Fast scan: collect worn/inventory/container names only, no identify. Same as eq.scan('quick')." })
doc(eq.compare, { name = "eq.compare", sig = "eq.compare([slot_or_item])", group = "equipment",
  text = "Ask the equipment model to review your loadout (per-slot keep/swap verdicts). Optional focus narrows it to one slot or item." })
doc(eq.id, { name = "eq.id", sig = "eq.id(item)", group = "equipment",
  text = "Identify a carried/worn item by keyword (game `identify`; higher-level items need a scroll/spell). The result folds into the item cache." })
doc(eq.shop, { name = "eq.shop", sig = "eq.shop()", group = "equipment",
  text = "At a shopkeeper, read `list`, shortlist the wearable rows, pull per-item detail, then ask the model what's worth buying." })
doc(eq.stats, { name = "eq.stats", sig = "eq.stats()", group = "equipment",
  text = "Report the item-cache size (names, variants, this-session identifies) and the model in use." })
doc(eq.forget, { name = "eq.forget", sig = "eq.forget()", group = "equipment",
  text = "Clear the persisted item cache and this-session identify bindings." })

-- Callable table: forward a legacy subcommand string (`eq("scan")`, `eq("id sword")`) to the member,
-- so both `eq.scan()` and the legacy `#eq scan` typed form work.
setmetatable(eq, { __call = function(_, rest)
  rest = trim(rest or "")
  local verb = (rest:match("^%S*") or ""):lower()
  local arg = rest:match("^%S+%s+(.*)$") or ""
  if verb == "scan" then eq.scan(arg ~= "" and arg or nil)
  elseif verb == "quick" then eq.quick()
  elseif verb == "compare" or verb == "cmp" then eq.compare(arg)
  elseif verb == "id" or verb == "identify" then eq.id(arg)
  elseif verb == "shop" then eq.shop()
  elseif verb == "stats" or verb == "cache" then eq.stats()
  elseif verb == "forget" then eq.forget()
  else echo(eq_usage(), "cyan") end
end })

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
  -- auto-identify: pure construction + the phase machine's signal surface (drive it with a stubbed after()).
  assign_ordinals = assign_ordinals,
  build_id_queue = build_id_queue,
  feed_id_stream = feed_id_stream,     -- replay verbatim id-block lines through the passive capture
  idq_start = idq_start,
  idq_get_result = function(ok) idq_get_result(ok) end,
  idq_put_result = function(ok) idq_put_result(ok) end,
  idq_advance = function(ok) if idq_advance then idq_advance(ok) end end,
  idq_state = function() return S.idq end,
  set_id_expect = function(name) S.id_expect = name end,
  items = items,
  session = session,
  reset = function() for k in pairs(items) do items[k] = nil end; for k in pairs(session) do session[k] = nil end end,
}

load_items()
echo("[eq] equipment adviser ready (model " .. cfg.model .. "). help(eq) for commands.", "dim")
