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

-- Defensive: reads of the shared `state` (char sheet / loadout) always see a table, so there's no
-- load-order dependency on AlterAeon (which owns/fills the schema, merging into this if we ran first).
state = state or {}

-- Reactive core (__rx) for the auto-identify FLOW (Subjects + await_reply); the promise layer (__promise)
-- is pulled in by bootstrap. require() live, dofile fallback in the bare test harness. `_rx` is
-- `_`-prefixed so load("Scripts") never auto-runs it — it's consumer-pulled here.
pcall(require, "_rx")
if not __rx then dofile("Scripts/_rx.lua") end
pcall(require, "_persist")
if not __persist then dofile("Scripts/_persist.lua") end
local persist = __persist
local rx = __rx

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
  detail_ceiling = 1000, -- pure runaway backstop on `list <item>` detail pulls (NOT a shortlist cap):
                         -- after dropping non-wearables/consumables/level-unmeetable rows we evaluate
                         -- everything left. Set absurdly high so it never bites a real room; it only
                         -- exists so a malformed/huge listing can't spam thousands of commands.
  single_call_max = 4,   -- if this many items or fewer survive the filter, review them in ONE model
                         -- call (fast, whole-loadout context). More than this and one call gets big/slow
                         -- (and the local model times out), so we SPLIT into a call per slot. Kept low
                         -- because a full shop of ~8 wearables in one prompt reliably timed the local
                         -- MLX model out — small per-slot calls are far more dependable.
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
  if S.idq.out_item then
    echo("[eq] reload interrupted the identify pass — '" .. tostring(S.idq.out_item)
      .. "' may still be OUT of its container; check your inventory and put it back.", "red")
  end
  S.idq = nil
end
S.id_expect = nil
S.id_cap = nil
S.id_resolve = nil   -- a manual eq.id's one-shot promise resolver (see finalize_id); stale across reload

-- items[name] = { variants = { [fingerprint] = variant, ... } }   (persistent, name -> LIST of variants)
-- session[name] = { fp, variant, ts }                             (this-session id while holding the item)
local items = S.items
local session = S.session

local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end
local function strip_ansi(s) return (s or ""):gsub("\27%[[%d;]*%a", "") end
local function now() return os.time() end

local ARTICLE = { a = true, an = true, the = true, some = true, pair = true, of = true }

-- Trailing display markers the listings tack onto item names: "an imp eye ring (glow)",
-- "a quartz-tipped wooden cane (light)", "an obsidian doom-ring (hum)". These are item PROPERTIES,
-- not part of the name — they MUST NOT reach the identity key or the keyword derivation (a real live
-- bug: four glowing items all keyed/keyworded as 'glow', and identify bindings never matched).
-- They ARE worth keeping, so parsers split them into a separate flags table.
local FLAG_MARKERS = { glow = true, glowing = true, hum = true, humming = true, light = true,
                       rare = true, artifact = true, invis = true, invisible = true,
                       magic = true, magical = true, unique = true }
local CANON_FLAG = { glowing = "glow", humming = "hum", invisible = "invis", magical = "magic" }
-- Split trailing "(marker)" groups off a listing name into `flags` (canonicalized for known markers,
-- literal for unknown ones — they're still display metadata, not name words). Loops: "(glow) (hum)".
local function split_flags(s, flags)
  flags = flags or {}
  s = trim(s or "")
  while true do
    local body, mark = s:match("^(.-)%s*%(([%a%s]+)%)$")
    if not body or body == "" then break end       -- no trailing group / whole string parenthesized
    s = trim(body)
    local m = trim(mark):lower()
    flags[CANON_FLAG[m] or m:gsub("%s+", "_")] = true
  end
  return s, flags
end

-- Cache key: lowercased, article-stripped, whitespace-collapsed, trailing-period-dropped, and any
-- trailing KNOWN flag markers dropped (defence in depth — upstream parsers already split them, but raw
-- lines from `state.inventory` etc. can still carry "(glow)"). Matches an inventory line
-- ("a lost lead ring") to its identify display name ("a lost lead ring").
local function norm_name(s)
  s = trim((strip_ansi(s):lower():gsub("%s+", " "):gsub("%.%s*$", "")))
  while true do
    local body, mark = s:match("^(.-)%s*%((%a+)%)$")
    if body and body ~= "" and FLAG_MARKERS[mark] then s = trim(body) else break end
  end
  s = s:gsub("^a ", ""):gsub("^an ", ""):gsub("^the ", ""):gsub("^some ", "")
  return trim(s)
end

-- The keyword AlterAeon expects for `identify`/`look in` is usually the last noun of the name:
-- "a small sack" -> "sack", "well made leather gloves" -> "gloves", "a lost lead ring" -> "ring".
-- Parenthesized groups and flag words are never keywords: "an imp eye ring (glow)" -> "ring", not "glow".
local function first_kw(name)
  local clean = (name or ""):gsub("%b()", " ")
  local last
  for w in clean:gmatch("%a+") do
    local lw = w:lower()
    if not ARTICLE[lw] and not FLAG_MARKERS[lw] then last = w end
  end
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

-- ---- persistence (via the shared crash-safe persist module) -----------------------------------------
local save_timer
local function save_items()
  persist.save(cfg.cache_file, items)
end
-- Debounced write (cancellable-timer pattern, same as AlterAeon/AIPilot): a burst of identifies coalesces
-- into one write 2s after the last.
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
-- A single inventory/container line -> item name + flags, or nil for non-items (headers, prompts,
-- counts). Handles plain lines ("a red leather cap"), the count-prefixed container form
-- ("(    1) a red leather cap"), and trailing display markers ("sleeves of the warmage (glow)").
local function parse_item_line(line)
  local L = trim(strip_ansi(line))
  if L == "" then return nil end
  if L:match("^<%d+hp") or L:match("^kxw[tq]_") or L:match("^%[the human typed%]") or L:match("BLOCKSEP") then return nil end
  if L:match("^You are ") or L:find("contains:", 1, true) or L:match("items? total%.?$") then return nil end
  L = L:gsub("^%(%s*%d+%s*%)%s*", "")               -- drop a "(    1)" count prefix
  local flags
  L, flags = split_flags(L)                          -- "(glow)"/"(light)"/… -> metadata, off the name
  local low = L:lower()
  if low == "" or low == "nothing" or low == "nothing." then return nil end
  return L, flags
end

-- A container header: "(carried) a small sack contains:" / "(on ground) a cedar chest contains:".
-- Returns the container name ("a small sack") or nil.
local function parse_container_header(line)
  local L = trim(strip_ansi(line))
  local name = L:match("^%(.-%)%s*(.-)%s+contains:%s*$")
  return name and trim(name) or nil
end

-- An `equipment`/`eq` slot line -> slot, item, flags. e.g.
--   "head        -              a circlet of dried vines"
--   "neck        - (rare)       a necklace of human ears"    (an optional leading (flag) column)
--   "finger      -              an imp eye ring (glow)"      (and/or a trailing display marker)
-- Both marker positions land in `flags` (canonical keys: rare/artifact/glow/hum/light/…), never in
-- the item name — the live 'glow' bug was this trailing marker leaking into names and keywords.
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
  local flags = {}
  local col, tail = rest:match("^(%b())%s*(.+)$")        -- optional leading "(rare)"/"(artifact)" column
  if col then
    local m = trim(col:sub(2, -2)):lower()
    if m ~= "" then flags[CANON_FLAG[m] or m:gsub("%s+", "_")] = true end
    rest = tail
  end
  local item
  item, flags = split_flags(rest, flags)                 -- trailing "(glow)" etc. -> flags, off the name
  item = norm_name(item)
  if item == "" then return nil end
  return slot, item, flags
end

-- ---- shop `list` parsing -------------------------------------------------------------------------
-- A single shop-list row, or a category header, or nil.
--   Category: "[  Price] Worn on neck ---------------------------------------"  -> {category="Worn on neck"}
--   Item:     "[    28] (lvl   0) a wand of scorch"                             -> {price=28,level=0,name=...}
local function parse_shop_row(line)
  -- The game INDENTS every shop row three spaces ("   [    178] (lvl 16) a drake bone circlet"), so trim
  -- leading/trailing whitespace before the `^[`-anchored priced patterns — without this every priced row
  -- failed to parse and a stocked shop read as "nothing to buy". (The donation patterns tolerate leading
  -- space on their own, but trimming is harmless for them.)
  local L = trim(strip_ansi(line))
  -- Priced shop category: "[  Price] Worn on neck ------------"
  local cat = L:match("^%[%s*Price%]%s*(.-)%s*%-%-%-")
  if cat then return { category = trim(cat) } end
  -- Priced shop item: "[    28] (lvl   0) a wand of scorch"
  local price, lvl, name = L:match("^%[%s*(%d+)%]%s*%(lvl%s*(%d+)%)%s*(.+)$")
  if price then return { price = tonumber(price), level = tonumber(lvl), name = trim(name) } end
  -- Donation / "up for grabs" room category: "   Worn on head ------------------" (no price bracket,
  -- a run of 4+ trailing dashes). Must be tried AFTER the priced forms (those start with '[').
  local dcat = L:match("^%s*([%a][%a '/&%-]-)%s*%-%-%-%-+%s*$")
  if dcat then return { category = trim(dcat) } end
  -- Donation item: " R (lvl  12) a crown of finger bones"  or  " R (tot  42) a ... necklace". A flag
  -- column (R = restrung/restricted etc.), then a level OR total-levels requirement, then the name.
  -- These are FREE (no price), so mark them so the shortlist/prompt treat cost as zero.
  local flag, kind, num, dname = L:match("^%s*(%a?)%s*%(%s*(%a+)%s*(%d+)%s*%)%s*(.+)$")
  if kind == "lvl" or kind == "tot" then
    return { price = 0, free = true, level = tonumber(num), level_kind = kind,
             name = trim(dname), flag = (flag ~= "" and flag or nil) }
  end
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
-- Shortlist the wearable/wieldable rows worth pulling detail for. This is a FILTER, not a cap: it drops
-- what definitely can't be used — non-wearable categories, consumables, and items whose level
-- requirement the character can't meet. Both requirement kinds the listing gives us are checked: a
-- `(lvl N)` against the character's highest class level, and a `(tot N)` against their TOTAL levels
-- (summed across classes — e.g. "tot 49" needs 49 combined). It does NOT judge class/alignment fit —
-- that needs the identify block, so those pass through to the model.
--
-- What survives is ordered ROUND-ROBIN across slots (one per slot, then a second per slot, …) so if the
-- safety `ceiling` is ever hit it's breadth — not "the first slot, 40 times." fit = { level=, total= }
-- (character's max class level + total levels); nil (or a nil field) skips that part of the filter.
-- Returns kept, skipped.
local function shortlist_shop(parsed, fit, ceiling)
  ceiling = ceiling or math.huge
  local function unfit(r)
    if not (fit and r.level) then return false end
    if r.level_kind == "tot" then return fit.total ~= nil and r.level > fit.total   -- total-levels req
    else return fit.level ~= nil and r.level > fit.level end                          -- primary level req
  end
  local buckets, order, skipped = {}, {}, {}
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
  local kept, round = {}, 1
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

-- Given the ORDERED item names the game showed for an ambiguous `list <kw>` ("you must give the item
-- number") and our target's display name, return the ordinal `list` argument ("2.helm"). The game
-- numbers the shown matches from 1 in display order. Falls back to "1.<kw>" if the target isn't found.
-- Pure/testable — the reactive retry in the detail phase calls this.
local function ambiguous_list_arg(shown, target, kw)
  local t = norm_name(target)
  for i, nm in ipairs(shown or {}) do
    if norm_name(nm) == t then return i .. "." .. kw end
  end
  return "1." .. kw
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

-- Pretty print a listing-flags table ({glow=true,hum=true}) for the prompts. Canonical keys get their
-- reader-friendly words back.
local FLAG_PRETTY = { glow = "glowing", hum = "humming", invis = "invisible" }
local function flags_str(flags)
  if not flags or not next(flags) then return nil end
  local out = {}
  for f in pairs(flags) do out[#out + 1] = FLAG_PRETTY[f] or f end
  table.sort(out)
  return table.concat(out, ", ")
end

-- One prompt line for an item, resolving its knowledge status. NEVER silently picks a variant for a
-- multi-variant name — it surfaces the ambiguity to the model instead. `flags` are the listing's
-- display markers (glowing/humming/rare/…), appended as properties.
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
    local src = (r.status == "session") and "identified this session (you're holding it)"
      or "stats from a previous identify — re-id to confirm"
    return string.format("- %s%s [%s] — %s — %s", name, suffix, variant_stats_str(v), verdict, src)
  end
end

-- Build the compare prompt. worn = {{slot, name[, flags]}}, candidates = {name-or-{name,flags}, ...}.
-- Pure: resolves each name from the shared cache and formats. Returns system, user.
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
    else u[#u + 1] = describe_item_for_prompt(c, char) end
  end
  u[#u + 1] = "\n=== TASK ==="
  u[#u + 1] = (focus and focus ~= "") and "Advise on the focus above." or "Review the whole loadout, slot by slot."
  return EQ_SYS, table.concat(u, "\n")
end

-- Build the shop prompt. kept = shortlisted shop rows ({price, level, name, category}). Pure.
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
    local info = describe_item_for_prompt(r.name, char):gsub("^%- ", "")
    local cost = r.free and "FREE" or (tostring(r.price or "?") .. " gold")
    local req = (r.level_kind == "tot") and ("tot lvl " .. tostring(r.level))
                or ("shop lvl " .. tostring(r.level or "?"))
    if r.free then donation = true end
    u[#u + 1] = string.format("- [%s] (%s) %s", cost, req, info)
  end
  u[#u + 1] = "\n=== TASK ==="
  if donation then
    u[#u + 1] = "This is a DONATION room — every item is FREE. Ignore cost; for each item say TAKE or SKIP "
      .. "based purely on whether it's an upgrade you can equip, then name the best pieces to grab."
  else
    u[#u + 1] = "You have " .. (char.gold and (char.gold .. " gold") or "unknown gold")
      .. ". For each shop item say BUY or SKIP with one line why."
  end
  return EQ_SHOP_SYS, table.concat(u, "\n")
end

-- Map a shop CATEGORY header ("Worn on wrists") to the worn-equipment SLOT key parse_eq_line uses
-- ("wrist"), so a per-slot prompt can show what you currently wear there. Plurals and the odd "worn
-- about body" are handled explicitly (naive de-pluralizing would break hands/ears/arms). nil for an
-- unrecognized category (the prompt then just omits a current item). Pure/testable.
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

-- Build a prompt for ONE slot: the character sheet, what they wear in that slot right now, and only
-- that slot's candidate items. Used when a shop has too many items to review in a single call — small
-- focused context per slot keeps the local model fast and sharp. Pure. Returns system, user.
local function build_slot_prompt(char, category, items, worn)
  local slot = slot_for_category(category)
  local u = { "=== CHARACTER ===", char_sheet_lines(char),
              "\n=== SLOT: " .. tostring(category) .. " ===", "\n--- WHAT YOU WEAR HERE NOW ---" }
  local any, donation = false, false
  for _, w in ipairs(worn or {}) do
    if slot and w.slot == slot then
      u[#u + 1] = describe_item_for_prompt(w.name, char, w.flags); any = true
    end
  end
  if not any then u[#u + 1] = "(nothing worn in this slot)" end
  u[#u + 1] = "\n--- AVAILABLE HERE ---"
  for _, r in ipairs(items or {}) do
    local info = describe_item_for_prompt(r.name, char):gsub("^%- ", "")
    local cost = r.free and "FREE" or (tostring(r.price or "?") .. " gold")
    local req = (r.level_kind == "tot") and ("tot lvl " .. tostring(r.level))
                or ("shop lvl " .. tostring(r.level or "?"))
    if r.free then donation = true end
    u[#u + 1] = string.format("- [%s] (%s) %s", cost, req, info)
  end
  u[#u + 1] = "\n=== TASK ==="
  u[#u + 1] = donation
    and "DONATION room — items are FREE. For THIS slot only, say TAKE or SKIP per item (one line why), then name the single best piece to wear here (or 'keep current')."
    or ("For THIS slot only, say BUY or SKIP per item (one line why), then the best pick (or 'keep current'). You have "
        .. (char.gold and (char.gold .. " gold") or "unknown gold") .. ".")
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
    -- ALWAYS hand control back to on_reply — even on error — with reply="" so the caller advances/settles
    -- (a per-slot review moves to the next slot; a single review resolves its promise) instead of hanging
    -- until the watchdog. The error itself is surfaced here.
    if err then echo("[eq] model error: " .. tostring(err), "red"); on_reply("", err); return end
    on_reply(reply or "")
  end, cfg.model)
end

-- ---- eq operations as promises -------------------------------------------------------------------
-- Every eq operation (scan/quick/compare/shop/id) runs as ONE tracked promise, so it shows in the HUD
-- promise widget and can be chained (`eq scan | eq compare`, `recover | eq shop`, or
-- eq.scan().andThen(...)). One op runs at a time; starting a new one supersedes (rejects) the running
-- one. Because these flows fan out through many capture triggers, paced timers and model callbacks —
-- with lots of early-return paths — a missed terminal would leak a widget row forever (the corpse-widget
-- lesson). So a watchdog, RE-ARMED on every step of real progress (eq_touch), force-settles the promise
-- if the op ever goes quiet without finishing. The promise is started SYNCHRONOUSLY so eq_op is wired
-- before any capture fires.
local eq_op = nil                 -- { resolve, reject, timer, label }
-- Seconds of NO progress before the watchdog force-settles the op. MUST exceed the local-model request
-- timeout (LLMClient: 180s) so a single slow compare/shop model call — which makes no intermediate
-- progress — can't trip it; run_model's own timeout fires first and settles the op cleanly.
local EQ_OP_IDLE = 210
local function eq_settle(ok, reason)
  local op = eq_op; eq_op = nil
  if not op then return end
  if op.timer and cancel then cancel(op.timer) end
  if ok == false then op.reject(reason or "eq interrupted") else op.resolve() end
end
local function eq_resolve() eq_settle(true) end
local function eq_reject(reason) eq_settle(false, reason) end
local function eq_touch()         -- progress: re-arm the idle watchdog
  local op = eq_op; if not op then return end
  if op.timer and cancel then cancel(op.timer) end
  if after then op.timer = after(EQ_OP_IDLE, function()
    echo("[eq] " .. (op.label or "operation") .. " stalled — wrapping up.", "yellow")
    eq_settle(false, "stalled")
  end) end
end
-- Begin an op: supersede any running one, create+track the promise, wire eq_op, arm the watchdog.
-- Returns the promise (nil only if the promise layer isn't loaded, so callers still run bare).
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
  if p and p.__start then p.__start() end   -- run the executor NOW so eq_op is set before any capture
  eq_touch()
  return p
end
-- An instantly-completed op (stats/forget/usage) as a resolved promise, for uniform chaining — does NOT
-- touch the eq_op slot, so it never supersedes a running scan/shop.
local function eq_instant(label)
  if not __promise then return nil end
  return __promise(function(resolve) resolve() end, label)
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
  -- A manual `eq.id` waits on the block it asked for: resolve its promise when it lands (one-shot).
  if S.id_resolve then local cb = S.id_resolve; S.id_resolve = nil; cb() end
end
local function id_begin() S.id_cap = { lines = {} } end
local function id_feed(line)
  local cap = S.id_cap
  if not cap then return end
  local L = strip_ansi(line)
  if L:match("^kxw[tq]_id_end") then cap.body_done = true; return end   -- body done; display line follows
  if L:match("^kxw[tq]_") then return end                               -- interleaved protocol line: skip
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
trigger([[^kxw[tq]_id_start]], function() id_begin() end)
trigger([[^Item: '(.+)']], function() if not S.id_cap then id_begin() end end)  -- replay/#test have no kxwt_
trigger([[.*]], function(line) id_feed(line) end)

-- Test helper: faithfully replays the processLine dispatch of the id-capture triggers over a line list.
local function feed_id_stream(lines)
  for _, line in ipairs(lines) do
    if line:match("^kxw[tq]_id_start") then id_begin()
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
    -- Trust the PERSISTED cache: a name with exactly one known variant ("cached") is taken as-is instead
    -- of re-identifying it every scan. (A "multi" — two+ stat-blocks seen for the same name — stays
    -- ambiguous and IS re-identified; that rare same-name-different-stats case is the only one we pay for.)
    if r.status == "session" or r.status == "cached" then known = known + 1; return end
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

-- ===== the auto-identify FLOW (reactive rewrite of the old phase machine) ==========================
-- The scan→identify→(wear/keep) pass used to be a hand-walked machine: S.idq.i / .phase / .cur / .got
-- plus a single armed after/cancel timer, stepped by mutually-recursive callbacks. It's now a PROMISE
-- FLOW over the game's reply STREAMS (mirrors Corpse.lua's harvest→bsac→sac):
--
--     process(i) = [combat-gate] → (in a container? get) → identify → (if we pulled it) put → process(i+1)
--
-- Each step SENDS its command then AWAITS its reply off a hot Subject — idResultS / getResultS /
-- putResultS — fed by the reply SEAMS below (idq_advance / idq_get_result / idq_put_result) that BOTH the
-- live triggers AND the specs push through (one path, no second matcher to drift). The single in-flight
-- await IS the pacing gate: a stray reply with no await subscribed is dropped (so a duplicate reply is
-- harmless). Per phase a stall watchdog is the await's own timeout, which — matching the ORIGINAL
-- behaviour — RESOLVES to a FAIL sentinel (count it, keep going) rather than aborting the whole pass:
-- a get-timeout skips the item (no put), an id-timeout counts a failure, a put-timeout leaves it on you
-- (left_out, reported loudly). The op-level idle watchdog (eq_op / EQ_OP_IDLE) remains the last-resort net
-- that force-settles the tracked scan promise. `i` / `phase` / `cur` / `got` have DISSOLVED into the flow
-- (i is a process() parameter; the entry is a closure local); S.idq now carries only the running TALLIES
-- and the reload-safety `out_item` marker (an item currently pulled OUT of its container).

-- Internal hot streams the per-item sequence awaits; fed by the SEAMS below.
local idResultS  = rx and rx.subject() or nil   -- identify result: a parsed block (idq_advance) / fail line
local getResultS = rx and rx.subject() or nil   -- `get <item> <container>` reply (success / can't)
local putResultS = rx and rx.subject() or nil   -- `put <item> <container>` reply (success)
local idqEndS    = rx and rx.subject() or nil   -- the pass ended → tear down any in-flight await

local FAIL  = {}   -- await sentinel: the reply said fail, OR the phase timed out — count it, continue
local ABORT = {}   -- await sentinel: the pass was torn down (finish / reload) — bail out of the flow

-- ---- reply SEAMS: the triggers AND the specs push game replies through these ----------------------
-- Each pushes onto the Subject the in-flight await subscribes to; with no await subscribed the push is
-- dropped. `idq_advance` is the forward-declared upvalue finalize_id (defined earlier) notifies.
idq_advance = function(ok)        if S.idq and idResultS  then idResultS:onNext(ok and "ok" or FAIL) end end
local function idq_get_result(ok) if S.idq and getResultS then getResultS:onNext(ok and "ok" or FAIL) end end
local function idq_put_result(ok) if S.idq and putResultS then putResultS:onNext(ok and "ok" or FAIL) end end

-- A flow promise: __promise but STARTED synchronously at construction (a step is built exactly when it
-- runs) and kept OUT of the HUD widget (only the enclosing eq.scan op is a widget row). Same helper
-- Corpse.lua uses.
local function IDP(executor)
  local p = __promise(executor, "eq-idflow")
  if __untrack_promise then __untrack_promise(p) end
  if p and p.__start then p.__start() end
  return p
end

-- Await the next value from a reply Subject, guarded by a per-phase watchdog that RESOLVES `FAIL` (a
-- single slow/absent reply is a counted failure, NOT a pass abort) and torn down by idqEndS (resolves
-- ABORT). The single active subscription is the pacing gate.
local function await_reply(subject, secs)
  return IDP(function(resolve, _, onCancel)
    local sub, esub, tid, done = nil, nil, nil, false
    local function cleanup()
      if sub  then sub:unsubscribe();  sub  = nil end
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

-- A politeness beat (be nice to the server), then run fn. A no-op wait when `after` is absent (bare
-- harness) so the flow still completes. Returns fn's promise so the chain composes.
local function idq_gap(fn)
  return IDP(function(resolve, _, onCancel)
    local id = after and after(cfg.id_gap, function() id = nil; resolve() end)
    if not id then resolve() end
    onCancel(function() if id and cancel then cancel(id) end end)
  end):andThen(fn)
end

local idq_process   -- fwd (recursive: do_put/do_identify call it, it calls them)

-- Tear the pass down: drop its triggers, abort any in-flight await, echo the summary + any left-out
-- warning, and settle the scan op. Exact original messages / echo order preserved.
local function idq_finish()
  local q = S.idq; if not q then return end
  S.idq = nil
  if class_remove then class_remove("eqid") end
  if idqEndS then idqEndS:onNext() end        -- tear down any lingering await
  echo(string.format("[eq] identify pass: %d identified, %d failed, %d already known.",
    q.ident, q.failed, q.known), "cyan")
  if #q.left_out > 0 then
    echo("[eq] WARNING — could NOT return to their container, they are ON YOU now: "
      .. table.concat(q.left_out, ", ") .. " — put them back manually.", "red")
  end
  echo("[eq] now try eq.compare().", "cyan")
  eq_resolve()   -- the scan's identify pass is the scan op's terminal
end

-- Put a pulled container item back, then step on. There is no put-FAILURE line on the wire: success is
-- "You put X in …" (idq_put_result(true)); a MISSING reply (timeout → FAIL) OR an explicit
-- idq_put_result(false) means it never went back — so it's LEFT ON YOU and reported loudly (left_out).
local function idq_do_put(i, e)
  send(string.format("put %s %s", e.base_kw, first_kw(e.container)))
  return await_reply(putResultS, cfg.id_timeout):andThen(function(res)
    local q = S.idq; if not q then return end
    if res == ABORT then return end
    q.out_item = nil                                       -- resolved either way: no longer unexpectedly OUT
    if res == FAIL then q.left_out[#q.left_out + 1] = e.name end
    return idq_gap(function() return idq_process(i + 1) end)
  end)
end

-- Send `identify` and await the parsed-block result (finalize_id → idq_advance), the failure line, or the
-- timeout. `pulled` = it came out of a container, so it MUST be put back regardless of the identify
-- outcome (a failed identify STILL puts it back — never left out). A just-pulled item uses its bare
-- keyword; finalize_id verifies the parsed display against S.id_expect.
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

-- Process the item at index `i`: combat-gate, then (get if it's in a container) → identify → put → next.
idq_process = function(i)
  local q = S.idq; if not q then return end
  if EPOCH ~= _EQUIP.epoch then return end               -- died on reload
  if in_combat and in_combat() then                      -- pause (don't advance) until combat clears
    if not q.paused_msg then echo("[eq] identify pass paused (in combat) — resuming when clear.", "yellow"); q.paused_msg = true end
    eq_touch()   -- a combat pause is NOT a stall — keep the op promise alive across the fight
    return IDP(function(resolve, _, onCancel)
      local id = after and after(cfg.id_combat_retry, function() id = nil; resolve() end)
      if not id then resolve() end
      onCancel(function() if id and cancel then cancel(id) end end)
    end):andThen(function() return idq_process(i) end)
  end
  q.paused_msg = nil
  eq_touch()   -- progress on the identify pass: keep the op promise alive
  if i > #q.list then idq_finish(); return end
  local e = q.list[i]
  echo(string.format("[eq] identifying %d/%d: %s%s", i, #q.list, e.name,
    e.container and (" (from " .. e.container .. ")") or ""), "cyan")
  if e.container then
    send(string.format("get %s %s", e.kw, first_kw(e.container)))
    return await_reply(getResultS, cfg.id_timeout):andThen(function(res)
      local q2 = S.idq; if not q2 then return end
      if res == ABORT then return end
      if res == FAIL then                                 -- never pulled out → NO put, just skip
        q2.failed = q2.failed + 1
        return idq_gap(function() return idq_process(i + 1) end)
      end
      q2.out_item = e.name                                -- now OUT of its container → must go back
      return idq_do_identify(i, e, true)
    end)
  end
  return idq_do_identify(i, e, false)
end

local function idq_install_triggers()
  trigger([[^You get .+ from ]],                       function() idq_get_result(true) end,  { class = "eqid" })
  trigger([[^You don't see anything named]],           function() idq_get_result(false) end, { class = "eqid" })
  trigger([[^You can't carry that many items]],        function() idq_get_result(false) end, { class = "eqid" })
  trigger([[^You can't safely carry]],                 function() idq_get_result(false) end, { class = "eqid" })
  trigger([[^You put .+ in ]],                         function() idq_put_result(true) end,  { class = "eqid" })
  trigger([[^You don't seem to be carrying anything named]], function() idq_advance(false) end, { class = "eqid" })
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
  -- Kick the flow. A watchdog FAIL deep in the chain becomes a normal resolve (fail-and-continue), so the
  -- only rejections reaching here are genuine faults — turn one into a clean close (ABORT is a deliberate
  -- teardown, not a fault, so it passes through as a resolve and never trips this).
  local flow = idq_process(1)
  if flow and flow.catch then
    flow:catch(function(why)
      if why ~= nil and why ~= ABORT and S.idq then
        echo("[eq] identify pass stalled — wrapping up.", "yellow")
        idq_finish()
      end
    end)
  end
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

-- Record a parsed item's display markers under its normalized name, so the compare/shop prompts can
-- surface "glowing"/"humming" as item properties without them ever touching the identity key.
local function note_flags(sc, name, flags)
  if not flags or not next(flags) then return end
  local k = norm_name(name)
  if k == "" then return end
  sc.flagmap = sc.flagmap or {}
  sc.flagmap[k] = sc.flagmap[k] or {}
  for f in pairs(flags) do sc.flagmap[k][f] = true end
end

-- Feed a streamed line into the active scan (mode set by the section-header triggers below).
local function scan_feed(line)
  local sc = S.scan
  if not sc or not sc.mode then return end
  local L = strip_ansi(line)
  if L:match("^kxw[tq]_") then return end   -- interleaved protocol line: skip, don't end the section
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
  trigger([[^You are using:]],   function() S.scan.mode = "eq";  S.scan.eq = {} end,  { class = "eq" })
  trigger([[^You are wearing:]], function() S.scan.mode = "eq";  S.scan.eq = {} end,  { class = "eq" })
  trigger([[^You are carrying:]], function() S.scan.mode = "inv"; S.scan.inv = {} end, { class = "eq" })
  trigger([[^.+ contains:$]], function(line)   -- anchored: a player's say "…bag contains:'" (quoted) can't spoof it
    local cname = parse_container_header(line)
    S.scan.mode = "cont"; S.scan.curcont = cname or "a container"
    S.scan.containers[S.scan.curcont] = S.scan.containers[S.scan.curcont] or {}
  end, { class = "eq" })
  trigger([[.*]], function(line) scan_feed(line) end, { class = "eq" })
end

local function finish_scan()
  if not S.scan then return end
  eq_touch()   -- gear collection done → keep the op alive into the (quick end / identify pass)
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
    eq_resolve()   -- quick scan has no identify pass, so this is its terminal
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

-- ---- current loadout (from the last scan, else the shared `state`) --------------------------------
local function current_worn()
  if S.scan and S.scan.eq and #S.scan.eq > 0 then
    local out = {}
    for _, e in ipairs(S.scan.eq) do out[#out + 1] = { slot = e.slot, name = e.item, flags = e.flags } end
    return out
  end
  local out = {}
  for _, line in ipairs((state and state.equipment) or {}) do
    local slot, item, flags = parse_eq_line(line)
    if item then out[#out + 1] = { slot = slot, name = item, flags = flags } end
  end
  return out
end
-- Candidate items for compare: {{name, flags}, ...}, deduped by normalized name, flags from the scan's
-- flagmap (or parsed off the raw `state.inventory` lines on the no-scan fallback path).
local function current_candidates()
  local seen, out = {}, {}
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
    for _, line in ipairs((state and state.inventory) or {}) do
      local n, flags = parse_item_line(line)
      if n then add(n, flags) end
    end
  end
  return out
end

-- ---- #eq compare ---------------------------------------------------------------------------------
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
  eq_touch()   -- anchor the watchdog window at the model call
  run_model(sys, user, function(reply)
    if trim(reply) ~= "" then echo("[eq] " .. trim(reply), "cyan") end
    eq_resolve()
  end)
  return p
end

-- ---- #eq id ---------------------------------------------------------------------------------------
local function eq_id(arg)
  arg = trim(arg)
  if arg == "" then echo("[eq] usage: eq.id('<item keyword>')", "yellow"); return end
  if combat_block() then return end
  local p = eq_begin("eq.id " .. arg)
  echo("[eq] identifying '" .. arg .. "' (higher-level items need an identify scroll/spell)…", "cyan")
  S.id_resolve = eq_resolve   -- one-shot: finalize_id resolves the op when the block lands (else watchdog)
  send("identify " .. arg)    -- the passive capture folds the resulting block into the cache
  return p
end

-- ---- #eq shop ------------------------------------------------------------------------------------
local function finish_shop()
  if not S.shop then return end
  eq_touch()   -- list collected → keep the op alive through detail pulls + model review
  local parsed = parse_shop_list(table.concat(S.shop.rows_text, "\n"))
  if parsed.no_shop then echo("[eq] you're not at a shop (no shopkeeper/donation/priest/guildmaster here).", "yellow"); eq_resolve(); return end
  if #parsed.rows == 0 then echo("[eq] nothing listed here to buy.", "yellow"); eq_resolve(); return end
  -- The character's level fit from the tracked classes: highest class level (for `(lvl N)` reqs) and
  -- total levels (for `(tot N)`). Nil when we have no class data, which just skips the level filter.
  local char = char_from_state()
  local fit
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
  -- One call when the model can handle the whole loadout quickly; SPLIT into a call per slot when there
  -- are too many items (a big single prompt is slow and the local model starts timing out).
  local function ask_single()
    if EPOCH ~= _EQUIP.epoch then return end
    local sys, user = build_shop_prompt(char_from_state(), current_worn(), kept)
    echo("[eq] asking " .. cfg.model .. (parsed.donation and " what's worth grabbing…" or " what's worth buying…"), "cyan")
    eq_touch()   -- anchor the watchdog window at the model call (a single call makes no interim progress)
    run_model(sys, user, function(reply)
      if trim(reply) ~= "" then echo("[eq] " .. trim(reply), "cyan") end
      eq_resolve()
    end)
  end
  local function ask_per_slot()
    if EPOCH ~= _EQUIP.epoch then return end
    local groups, order = {}, {}
    for _, r in ipairs(kept) do
      local c = r.category or "?"
      if not groups[c] then groups[c] = {}; order[#order + 1] = c end
      groups[c][#groups[c] + 1] = r
    end
    local ch, worn = char_from_state(), current_worn()
    echo(string.format("[eq] %d items across %d slots — too many for one pass, reviewing a slot at a time…",
      #kept, #order), "cyan")
    local function do_slot(i)
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
  -- Pull `list <item>` detail for each shortlisted row (identify-format, passively ingested into the
  -- cache) so the model reasons about real stats — donation rooms answer `list <item>` too.
  --
  -- Two wrinkles this handles:
  --  * Shop/donation items aren't owned, so their `list <item>` block has NO "You are wearing/carrying/
  --    wielding …" line — parse_identify can't learn the display name and would cache under the keyword
  --    name ("brown scarf strip cloth"), so a lookup by the listing name ("a brown scarf") misses and
  --    the item reads "unidentified". We bind the block to the exact listing name via S.id_expect.
  --  * A keyword can be AMBIGUOUS ("list helm" matches "a bronze helm" AND "a jet black helmet"); the
  --    game then refuses and lists the matches, demanding "list 1.helm". We collect those shown matches
  --    and resend `list <N>.<kw>` for our exact target (ambiguous_list_arg).
  local retried = false
  local function pull(i)
    if EPOCH ~= _EQUIP.epoch then return end
    if i > #kept then
      if class_remove then class_remove("eqdetail") end
      ask_model(); return
    end
    eq_touch()
    -- CACHE HIT: shop `list <item>` details are ingested under the listing name, so if we've already got
    -- a trustworthy entry for this exact name (this session, or one persisted variant) don't re-`list` it
    -- — just move on. This is the same "don't re-identify what we already know" the scan does, applied to
    -- shop detail pulls (the biggest time sink at a busy shop).
    local r = resolve_item(kept[i].name)
    if r.status == "session" or r.status == "cached" then
      after(0, function() pull(i + 1) end); return
    end
    S.shop.cur = kept[i]; S.shop.dis = {}; retried = false
    S.id_expect = norm_name(kept[i].name)
    send("list " .. first_kw(kept[i].name))
    after(cfg.look_wait, function() pull(i + 1) end)
  end
  -- Detail-phase observer: gather the match names the game shows, and on the "give the item number"
  -- prompt resend the current target as an ordinal. (The item detail itself is folded in by the
  -- always-on id-capture; this trigger only handles disambiguation.)
  trigger([[.*]], function(line)
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

-- Is this a pager "more" prompt? Long listings (donation rooms, big shops) pause with e.g.
--   "Press <return> or 'cont' to continue, anything else to quit..."
local function is_more_prompt(L)
  return L:find("' to continue", 1, true) ~= nil or L:find("<return> or 'cont'", 1, true) ~= nil
end

local function eq_shop()
  if combat_block() then return end
  local p = eq_begin("eq.shop")
  S.shop = { rows_text = {}, collecting = true }
  local finish_timer
  -- Idle-debounced finish: re-armed on every real shop line and every page turn, so the collector
  -- stays open across a multi-page listing and only wraps up once the output actually goes quiet.
  local function arm_finish()
    if cancel and finish_timer then cancel(finish_timer) end
    finish_timer = after(cfg.look_wait, function()
      if not (S.shop and S.shop.collecting) then return end
      S.shop.collecting = false
      if class_remove then class_remove("eqshop") end
      finish_shop()
    end)
  end
  trigger([[.*]], function(line)
    if not (S.shop and S.shop.collecting) then return end
    local L = strip_ansi(line)
    if is_more_prompt(L) then
      send("cont")     -- fetch the next page; keep collecting
      arm_finish()
      return           -- don't store the prompt itself
    end
    S.shop.rows_text[#S.shop.rows_text + 1] = L
    -- Re-arm only on actual shop content (not unrelated chatter) so idle-detect stays reliable.
    if parse_shop_row(L) then arm_finish() end
  end, { class = "eqshop" })
  echo("[eq] reading the shop's list…", "cyan")
  send("list")
  arm_finish()
  return p
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

-- Each op returns its tracked promise (nil only if the promise layer isn't loaded), so it shows in the
-- HUD widget and chains: `eq scan | eq compare`, `recover | eq shop`, eq.scan().andThen(eq.compare).
function eq.scan(mode)
  if type(mode) == "table" then mode = mode.quick and "quick" or "" end
  return eq_scan(mode)
end
function eq.quick() return eq_scan("quick") end
function eq.compare(slot_or_item) return eq_compare(slot_or_item) end
function eq.id(item) return eq_id(item) end
function eq.shop() return eq_shop() end
function eq.stats() eq_stats(); return eq_instant("eq.stats") end
function eq.forget()
  for k in pairs(items) do items[k] = nil end
  for k in pairs(session) do session[k] = nil end
  save_items(); echo("[eq] cleared the item cache")
  return eq_instant("eq.forget")
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
  -- Return the member's promise so `eq("scan")` / the pipe (`eq scan | …`) can chain on it.
  if verb == "scan" then return eq.scan(arg ~= "" and arg or nil)
  elseif verb == "quick" then return eq.quick()
  elseif verb == "compare" or verb == "cmp" then return eq.compare(arg)
  elseif verb == "id" or verb == "identify" then return eq.id(arg)
  elseif verb == "shop" then return eq.shop()
  elseif verb == "stats" or verb == "cache" then return eq.stats()
  elseif verb == "forget" then return eq.forget()
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
  -- scan collector: drive verbatim listing lines through the same feed the triggers use.
  scan_feed = scan_feed,
  scan_begin = function(mode)     -- start a scan buffer + section, as the header triggers would
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
  eq_begin = eq_begin, eq_resolve = eq_resolve, eq_reject = eq_reject, eq_instant = eq_instant,
  reset = function() for k in pairs(items) do items[k] = nil end; for k in pairs(session) do session[k] = nil end end,
}

load_items()
echo("[eq] equipment adviser ready (model " .. cfg.model .. "). help(eq) for commands.", "dim")
