-- Specs for Equipment.lua's pure parsers, the variant cache, equippability, and prompt builders.
-- Samples are verbatim from real player traces (~/Documents/MudClient/human-traces.jsonl). The triggers,
-- collectors, model call, and file cache run in Swift/the live state and aren't unit-testable here.

local E                     = _EQ_TEST
local parse_identify        = E.parse_identify
local fingerprint           = E.fingerprint
local ingest                = E.ingest
local resolve_item          = E.resolve_item
local precheck_equip        = E.precheck_equip
local parse_item_line       = E.parse_item_line
local parse_container_header = E.parse_container_header
local parse_eq_line         = E.parse_eq_line
local parse_shop_row        = E.parse_shop_row
local parse_shop_list       = E.parse_shop_list
local shortlist_shop        = E.shortlist_shop
local is_consumable         = E.is_consumable
local looks_like_container  = E.looks_like_container
local build_compare_prompt  = E.build_compare_prompt
local build_shop_prompt     = E.build_shop_prompt

-- ---- verbatim trace samples ----------------------------------------------------------------------
local RING = [[Item: 'dull gray lead ring'
Weight: 1  Size: 0'1"  Total levels: 20   (you can't use this yet)  Item Quality: WELL CRAFTED
Type: TREASURE   Composition: BASE METAL, LEAD
Object is:  QUEST_ITEM
Wear locations are:  FINGERS
Item has other effects:
Affects:  DAMROLL by 2
You are carrying a lost lead ring.]]

local SICKLE = [[Item: 'blackened bronze sickle'
Weight: 2  Size: 2'0"  Level: 1  Item Quality: WELL CRAFTED
Type: WEAPON   Composition: METAL ALLOY, BRONZE
Weapon damage: 2 to 20 average, slice, 11 strength to use.
Object is:  NECR
Item has other effects:
Affects:  HITROLL by 2
Affects:  DAMROLL by 2
This item is bound to you.
You are wielding a blackened bronze sickle.]]

local GLOVES = [[Item: 'gloves leather'
Weight: 1  Size: 0'6"  Level: 0  Item Quality: WELL CRAFTED
Type: ARMOR   Composition: FLESH, SKIN   Defense: 4 ac-apply
Object is:  RARE
Wear locations are:  HANDS
Item has other effects:
Affects:  PARRY by 1
Affects:  HITROLL by 1
Affects:  HIT_POINTS by 3
This item is bound to you.
You are carrying well made leather gloves.]]

-- ---- identify parsing ----------------------------------------------------------------------------
test("parse_identify: ring block — total-level req, can't-use flag, wear, affects, display key", function()
  local v = parse_identify(RING)
  expect(v):truthy()
  expect(v.name):eq("lost lead ring")            -- keyed by the DISPLAY name, article-stripped
  expect(v.item_name):eq("dull gray lead ring")  -- the identify keyword name kept too
  expect(v.type):eq("TREASURE")
  expect(v.total_levels):eq(20)
  expect(v.level):eq(nil)
  expect(v.cant_use_yet):eq(true)
  expect(v.wear[1]):eq("FINGERS")
  expect(v.affects[1].stat):eq("DAMROLL")
  expect(v.affects[1].by):eq("2")
  expect(#v.flags):eq(1)
end)

test("parse_identify: weapon block — damage range + strength, NECR class restriction", function()
  local v = parse_identify(SICKLE)
  expect(v.type):eq("WEAPON")
  expect(v.level):eq(1)
  expect(v.weapon.min):eq(2)
  expect(v.weapon.max):eq(20)
  expect(v.weapon.verb):eq("slice")
  expect(v.weapon.str):eq(11)
  expect(v.class_flags[1]):eq("NECR")
  expect(#v.align_flags):eq(0)
  expect(v.bound):eq(true)
end)

test("parse_identify: armor block — defense, display name differs from keyword name", function()
  local v = parse_identify(GLOVES)
  expect(v.type):eq("ARMOR")
  expect(v.defense):eq(4)
  expect(v.name):eq("well made leather gloves")   -- inventory listing shows this, not 'gloves leather'
  expect(#v.affects):eq(3)
end)

test("parse_identify: separates class flags from alignment flags in a mixed Object-is line", function()
  local block = "Item: 'shadow band'\nWeight: 1  Size: 0'1\"  Level: 5  Item Quality: WELL CRAFTED\n"
    .. "Type: TREASURE   Composition: METAL\nObject is:  GLOW ANTI_GOOD THIEF\nWear locations are:  WRISTS\n"
    .. "You are carrying a shadow band."
  local v = parse_identify(block)
  expect(v.class_flags[1]):eq("THIEF")
  expect(#v.class_flags):eq(1)
  expect(v.align_flags[1]):eq("ANTI_GOOD")
  expect(#v.flags):eq(3)                          -- GLOW + ANTI_GOOD + THIEF all recorded
end)

test("parse_identify: returns nil for a block with no Item line", function()
  expect(parse_identify("You don't see that here.")):eq(nil)
end)

-- ---- variant dedup, ambiguity, session binding ---------------------------------------------------
test("fingerprint: same block twice dedupes to one variant; a differing block adds a second", function()
  E.reset()
  ingest(parse_identify(GLOVES))
  ingest(parse_identify(GLOVES))                  -- identical -> refresh, not a new variant
  local entry = E.items["well made leather gloves"]
  local n = 0; for _ in pairs(entry.variants) do n = n + 1 end
  expect(n):eq(1)

  local gloves2 = GLOVES:gsub("Defense: 4", "Defense: 6")   -- a genuinely different variant, same name
  ingest(parse_identify(gloves2))
  n = 0; for _ in pairs(entry.variants) do n = n + 1 end
  expect(n):eq(2)
end)

test("resolve_item: prefers a this-session id, then unique cached, then reports multi as ambiguous", function()
  E.reset()
  ingest(parse_identify(GLOVES))
  local r = resolve_item("well made leather gloves")
  expect(r.status):eq("session")                  -- just identified this session -> trustworthy

  E.session["well made leather gloves"] = nil      -- simulate the item leaving possession
  r = resolve_item("well made leather gloves")
  expect(r.status):eq("cached")                   -- one known variant, usable but "re-id to confirm"

  ingest(parse_identify(GLOVES:gsub("Defense: 4", "Defense: 9")))
  E.session["well made leather gloves"] = nil
  r = resolve_item("well made leather gloves")
  expect(r.status):eq("multi")
  expect(r.count):eq(2)
end)

test("resolve_item: unknown name", function()
  E.reset()
  expect(resolve_item("a nonexistent trinket").status):eq("unknown")
end)

-- ---- inventory / container / equipment parsing ---------------------------------------------------
test("parse_item_line: plain, count-prefixed, trailing tag; rejects headers/prompts/totals", function()
  expect(parse_item_line("a torn and blood-stained journal")):eq("a torn and blood-stained journal")
  expect(parse_item_line("(    1) a red leather cap")):eq("a red leather cap")
  expect(parse_item_line("a mining torch (light)")):eq("a mining torch")
  expect(parse_item_line("10 items total.")):eq(nil)
  expect(parse_item_line("You are carrying:")):eq(nil)
  expect(parse_item_line("<80hp 85m 156mv>")):eq(nil)
  expect(parse_item_line("nothing.")):eq(nil)
end)

test("parse_container_header: carried and on-ground containers", function()
  expect(parse_container_header("(carried) a small sack contains:")):eq("a small sack")
  expect(parse_container_header("(on ground) a cedar chest contains:")):eq("a cedar chest")
  expect(parse_container_header("just a normal line")):eq(nil)
end)

test("parse_eq_line: slot + item, optional flag column, two-word slots, rejects non-slots", function()
  local s, i = parse_eq_line("head        -              a circlet of dried vines")
  expect(s):eq("head"); expect(i):eq("circlet of dried vines")
  s, i = parse_eq_line("neck        - (rare)       a necklace of human ears")
  expect(s):eq("neck"); expect(i):eq("necklace of human ears")   -- (rare) flag column stripped
  s, i = parse_eq_line("on body     -              black feathered robes")
  expect(s):eq("on body"); expect(i):eq("black feathered robes")
  expect(parse_eq_line("This stone hut has been - gutted")):eq(nil)  -- not a known slot
end)

-- ---- shop list parsing + shortlist ---------------------------------------------------------------
-- VERBATIM shape from a live `list` (mud_raw): the game INDENTS every priced row three spaces. The
-- fixtures MUST keep that indent — without it the `^[`-anchored parser silently matched nothing and a
-- fully-stocked shop reported "nothing to buy" (the bug this locks down).
local SHOP = [[a wizard's apprentice tells you, 'The following items are available for sale at this time'
   [  Price] Held ---------------------------------------
   [     28] (lvl   0) a wand of scorch
   [    126] (lvl   1) a wand of crystal light
   [  Price] Miscellaneous ---------------------------------------
   [    155] (lvl   1) a scroll of detect magic
   [  Price] Worn on neck ---------------------------------------
   [    335] (lvl   1) a soapstone necklace
To see a specific item in detail, give the item name.]]

test("parse_shop_row: category header vs priced item row (leading indent tolerated)", function()
  local cat = parse_shop_row("   [  Price] Worn on neck ---------------------------------------")
  expect(cat.category):eq("Worn on neck")
  local row = parse_shop_row("   [     28] (lvl   0) a wand of scorch")
  expect(row.price):eq(28); expect(row.level):eq(0); expect(row.name):eq("a wand of scorch")
  -- un-indented still parses too (robust either way)
  expect(parse_shop_row("[     28] (lvl   0) a wand of scorch").name):eq("a wand of scorch")
end)

test("parse_shop_list: seller, rows tagged with their category", function()
  local p = parse_shop_list(SHOP)
  expect(p.seller):eq("a wizard's apprentice")
  expect(#p.rows):eq(4)
  expect(p.rows[1].category):eq("Held")
  expect(p.rows[4].name):eq("a soapstone necklace")
  expect(p.rows[4].category):eq("Worn on neck")
end)

-- VERBATIM from the raw log (The Hidden Homunculus necromancer shop) — the exact indentation and the
-- mid-list pager line the collector strips. This is the "#eq.shop() said nothing to buy" report.
local NECRO_SHOP = [[a bony old man tells you, 'The following items are available for sale at this time'

   [  Price] Worn on head ---------------------------------------
   [    178] (lvl  16) a drake bone circlet

   [  Price] Worn on neck ---------------------------------------
   [    158] (lvl  16) an amulet of mandrake root

   [  Price] Worn on wrists ---------------------------------------
   [    436] (lvl  16) a drake horn bracer

   [  Price] Worn on body ---------------------------------------
   [    300] (lvl  17) black leather shirt with skull shoulder pads

   [  Price] Worn on legs ---------------------------------------
   [    300] (lvl  17) black leather pants with skull kneecaps

   [  Price] Held ---------------------------------------
   [    649] (lvl   2) a wand of preservation
   [    740] (lvl  16) a drake bone sickle

   [  Price] Miscellaneous ---------------------------------------
   [     20] (lvl  13) a scroll of soulsteal

To see a specific item in detail, give the item name.]]

test("parse_shop_list: the real indented necromancer shop parses ALL its rows (regression)", function()
  local p = parse_shop_list(NECRO_SHOP)
  expect(p.seller):eq("a bony old man")
  expect(#p.rows):eq(8)                                   -- was 0 before the indent fix → "nothing to buy"
  expect(p.rows[1].name):eq("a drake bone circlet")
  expect(p.rows[1].category):eq("Worn on head")
  expect(p.rows[1].price):eq(178); expect(p.rows[1].level):eq(16)
  -- the wearable armour survives the shortlist; the wands/scrolls are dropped as consumables
  local kept = shortlist_shop(p)
  expect(#kept >= 5):eq(true)
  local names = {}; for _, r in ipairs(kept) do names[r.name] = true end
  expect(names["a drake bone circlet"]):eq(true)
  expect(names["a wand of preservation"]):eq(nil)        -- consumable, filtered
end)

test("parse_shop_list: recognizes the not-at-a-shop message", function()
  local p = parse_shop_list("There is nothing here to list (no shopkeeper, donation, priest, or guildmaster.)")
  expect(p.no_shop):eq(true)
end)

test("shortlist_shop: keeps the wearable necklace, skips wands/scrolls", function()
  local kept, skipped = shortlist_shop(parse_shop_list(SHOP))
  expect(#kept):eq(1)
  expect(kept[1].name):eq("a soapstone necklace")
  expect(#skipped):eq(3)
  expect(is_consumable("a wand of scorch")):eq(true)
  expect(is_consumable("a soapstone necklace")):eq(false)
end)

-- ---- donation / "up for grabs" room (no prices, R flag, lvl/tot reqs) -----------------------------
local DONATE = [[The following items are currently up for grabs:

   Worn on head ---------------------------------------
 R (lvl  12) a crown of finger bones
 R (lvl  18) a jet black helmet

   Worn on neck ---------------------------------------
 R (lvl  17) a brown scarf
 R (tot  42) a platinum torsade necklace with a lustrous amethyst pendant

Press <return> or 'cont' to continue, anything else to quit...]]

test("parse_shop_row: donation category + free lvl/tot item rows", function()
  local cat = parse_shop_row("   Worn on head ---------------------------------------")
  expect(cat.category):eq("Worn on head")
  local lvl = parse_shop_row(" R (lvl  12) a crown of finger bones")
  expect(lvl.free):eq(true); expect(lvl.price):eq(0)
  expect(lvl.level):eq(12); expect(lvl.level_kind):eq("lvl")
  expect(lvl.name):eq("a crown of finger bones")
  local tot = parse_shop_row(" R (tot  42) a platinum torsade necklace with a lustrous amethyst pendant")
  expect(tot.free):eq(true); expect(tot.level):eq(42); expect(tot.level_kind):eq("tot")
  expect(tot.name):eq("a platinum torsade necklace with a lustrous amethyst pendant")
end)

test("parse_shop_list: donation room parses rows and flags donation (not no_shop)", function()
  local p = parse_shop_list(DONATE)
  expect(p.donation):eq(true)
  expect(p.no_shop):eq(nil)
  expect(#p.rows):eq(4)
  expect(p.rows[1].category):eq("Worn on head")
  expect(p.rows[4].category):eq("Worn on neck")
  expect(p.rows[4].free):eq(true)
end)

test("shortlist_shop: donation wearables are all kept (headers are worn slots)", function()
  local kept = shortlist_shop(parse_shop_list(DONATE))
  expect(#kept):eq(4)
  expect(kept[1].name):eq("a crown of finger bones")
end)

-- A many-item, many-slot donation listing (trimmed from the real log) — the old shortlist kept the
-- first N in listing order and never looked past the first slot or two.
local BIG_DONATE = [[The following items are currently up for grabs:

   Worn on head ---------------------------------------
 R (lvl  12) a crown of finger bones
 R (lvl  13) a broad copper headband
 R (lvl  15) a bronze helm
 R (lvl  18) a jet black helmet

   Worn on wrists ---------------------------------------
 R (lvl  12) a mystical blue band
 R (lvl  15) a bone armguard
 R (lvl  15) a jade bracelet edged in silver

   Worn on fingers ---------------------------------------
 R (lvl  15) a hematite ring
 R (lvl  16) a finger-bone ring
 R (lvl  18) a silver serpent ring

   Worn on body ---------------------------------------
 R (lvl  14) a nightforge black tunic
 R (lvl  22) a charred steel breastplate]]

test("shortlist_shop: round-robins across slots so no slot is starved", function()
  local parsed = parse_shop_list(BIG_DONATE)
  local kept = shortlist_shop(parsed, nil, 4)   -- ceiling 4, 4 slots → exactly one from EACH slot
  expect(#kept):eq(4)
  local slots = {}
  for _, r in ipairs(kept) do slots[r.category] = (slots[r.category] or 0) + 1 end
  expect(slots["Worn on head"]):eq(1)
  expect(slots["Worn on wrists"]):eq(1)
  expect(slots["Worn on fingers"]):eq(1)
  expect(slots["Worn on body"]):eq(1)
  -- round 1 takes the FIRST row of each slot in listing order
  expect(kept[1].name):eq("a crown of finger bones")
  expect(kept[4].name):eq("a nightforge black tunic")
end)

test("shortlist_shop: no ceiling → evaluates every fitting wearable, breadth-first", function()
  local kept = shortlist_shop(parse_shop_list(BIG_DONATE))   -- no fit filter, no ceiling
  expect(#kept):eq(12)                      -- all 12 wearable rows across the 4 slots (4+3+3+2)
  -- ordered round-robin: the first 4 are one-per-slot (round 1), then a second per slot, …
  expect(kept[1].name):eq("a crown of finger bones")
  expect(kept[5].name):eq("a broad copper headband")   -- head's 2nd
end)

test("shortlist_shop: drops items whose level requirement the character can't meet", function()
  local kept = shortlist_shop(parse_shop_list(BIG_DONATE), { level = 15, total = 30 })
  local names = {}
  for _, r in ipairs(kept) do names[r.name] = true end
  expect(names["a jet black helmet"]):eq(nil)            -- lvl 18 > 15 → dropped
  expect(names["a charred steel breastplate"]):eq(nil)   -- lvl 22 > 15 → dropped
  expect(names["a silver serpent ring"]):eq(nil)         -- lvl 18 > 15 → dropped
  expect(names["a crown of finger bones"]):eq(true)      -- lvl 12 → kept
  expect(names["a bone armguard"]):eq(true)              -- lvl 15 → kept (== best class level)
end)

test("shortlist_shop: filters (tot N) items against the character's TOTAL levels", function()
  local TOT = [[The following items are currently up for grabs:

   Held ---------------------------------------
 R (tot  49) a lapis lazuli orb
 R (tot  25) a chameleon ring
 R (lvl  12) a plain glass marble]]
  -- total 30: "tot 49" is out of reach → dropped; "tot 25" is met → kept; the lvl-12 item is fine.
  local kept = shortlist_shop(parse_shop_list(TOT), { level = 18, total = 30 })
  local names = {}
  for _, r in ipairs(kept) do names[r.name] = true end
  expect(names["a lapis lazuli orb"]):eq(nil)            -- tot 49 > 30 → dropped
  expect(names["a chameleon ring"]):eq(true)             -- tot 25 ≤ 30 → kept
  expect(names["a plain glass marble"]):eq(true)         -- lvl 12 ≤ 18 → kept
  -- with a higher total, the orb comes back
  local kept2 = shortlist_shop(parse_shop_list(TOT), { level = 18, total = 60 })
  local n2 = {}; for _, r in ipairs(kept2) do n2[r.name] = true end
  expect(n2["a lapis lazuli orb"]):eq(true)              -- tot 49 ≤ 60 → kept
end)

-- ---- per-slot prompts (used when a shop is too big for one call) ----------------------------------
test("slot_for_category maps shop categories to worn slots", function()
  expect(E.slot_for_category("Worn on head")):eq("head")
  expect(E.slot_for_category("Worn on wrists")):eq("wrist")
  expect(E.slot_for_category("Worn on fingers")):eq("finger")
  expect(E.slot_for_category("Worn on hands")):eq("hands")   -- plural slot preserved, not de-pluralized
  expect(E.slot_for_category("Worn about body")):eq("about body")
  expect(E.slot_for_category("Wielded")):eq("weapon")
  expect(E.slot_for_category("Held")):eq("held")
  expect(E.slot_for_category("Shields")):eq("shield")
  expect(E.slot_for_category("Miscellaneous")):eq(nil)       -- unknown → nil (no current-worn match)
end)

test("build_slot_prompt scopes to one slot: its worn item + only that slot's candidates", function()
  E.reset()
  local items = {
    { name = "a crown of finger bones", category = "Worn on head", free = true, level = 12, level_kind = "lvl" },
    { name = "a bronze helm", category = "Worn on head", free = true, level = 15, level_kind = "lvl" },
  }
  local worn = { { slot = "head", name = "a horned imp-hide hood" }, { slot = "neck", name = "a white ocarina" } }
  local _, user = E.build_slot_prompt({ name = "T", gold = 5 }, "Worn on head", items, worn)
  expect(user:find("SLOT: Worn on head", 1, true) ~= nil):eq(true)
  expect(user:find("a horned imp-hide hood", 1, true) ~= nil):eq(true)   -- current HEAD item shown
  expect(user:find("a white ocarina", 1, true)):eq(nil)                  -- other-slot worn NOT shown
  expect(user:find("a crown of finger bones", 1, true) ~= nil):eq(true)
  expect(user:find("a bronze helm", 1, true) ~= nil):eq(true)
  expect(user:find("FREE", 1, true) ~= nil):eq(true)
  expect(user:find("THIS slot only", 1, true) ~= nil):eq(true)
end)

-- ---- ambiguous `list <kw>` → ordinal retry (the game demands "list 1.helm") -----------------------
test("ambiguous_list_arg: picks the target's position among the shown matches", function()
  -- `list helm` showed: 1) a bronze helm, 2) a jet black helmet (game stems helm→helmet)
  local shown = { "a bronze helm", "a jet black helmet" }
  expect(E.ambiguous_list_arg(shown, "a jet black helmet", "helm")):eq("2.helm")
  expect(E.ambiguous_list_arg(shown, "a bronze helm", "helm")):eq("1.helm")
  -- `list bones` showed: 1) a crown of finger bones, 2) a bone armguard
  local shown2 = { "a crown of finger bones", "a bone armguard" }
  expect(E.ambiguous_list_arg(shown2, "a crown of finger bones", "bones")):eq("1.bones")
  -- target not among the shown matches → safe fallback to 1.<kw>
  expect(E.ambiguous_list_arg(shown, "a death mask", "mask")):eq("1.mask")
end)

-- A shop/donation `list <item>` block: identify format, but NO "You are wearing/carrying/wielding"
-- line (you don't own it), so parse_identify never learns the display name on its own.
local SHOP_DETAIL = {
  "Item: 'brown scarf strip cloth'",
  "Weight: 1  Size: 1'0\"  Level: 17  Item Quality: WELL CRAFTED",
  "Type: CLOTHING   Composition: TEXTILE, FABRIC",
  "Wear locations are:  NECK",
  "Affects:  DEX by 1",
  "Affects:  SAVING_COLD by 5%",
  "a brown scarf is WELL CRAFTED in quality.",
  "<100hp 200m 90mv>",   -- prompt line: the hard boundary that finalizes a no-display-line block
}

test("shop detail binds to the listing name via id_expect (fixes shop 'unidentified')", function()
  E.reset()
  -- Without a binding, the block caches under the KEYWORD name — a lookup by the listing name misses.
  E.feed_id_stream(SHOP_DETAIL)
  expect(resolve_item("a brown scarf").status):eq("unknown")
  -- With id_expect set to the listing name (what eq.shop now does before each `list <item>`), the same
  -- block binds to "a brown scarf" and resolves as identified with its stats.
  E.reset()
  E.set_id_expect(E.norm_name("a brown scarf"))
  E.feed_id_stream(SHOP_DETAIL)
  local r = resolve_item("a brown scarf")
  expect(r.status):eq("session")   -- identified THIS session (bound via id_expect), not "unknown"
  expect(r.variant.level):eq(17)
  local has_dex = false
  for _, a in ipairs(r.variant.affects) do if a.stat == "DEX" then has_dex = true end end
  expect(has_dex):eq(true)
end)

test("build_shop_prompt: donation items render FREE + TAKE/SKIP task", function()
  local kept = shortlist_shop(parse_shop_list(DONATE))
  local _, user = build_shop_prompt({ name = "Tester" }, {}, kept)
  expect(user:find("FREE", 1, true) ~= nil):eq(true)
  expect(user:find("DONATION room", 1, true) ~= nil):eq(true)
  expect(user:find("TAKE or SKIP", 1, true) ~= nil):eq(true)
  expect(user:find("tot lvl 42", 1, true) ~= nil):eq(true)
end)

-- ---- equippability -------------------------------------------------------------------------------
test("precheck_equip: 'can't use yet' (level) blocks equipping", function()
  local v = parse_identify(RING)
  local pc = precheck_equip(v, { classes = { Mage = 20 } })
  expect(pc.ok):eq(false)
  expect(table.concat(pc.reasons, " ")):contains("level too high")
end)

test("precheck_equip: class flag requires that class", function()
  local v = parse_identify(SICKLE)                        -- NECR only
  local mage = precheck_equip(v, { classes = { Mage = 30 } })
  expect(mage.ok):eq(false)
  expect(table.concat(mage.reasons, " ")):contains("Necromancer")
  local necro = precheck_equip(v, { classes = { Necromancer = 5 } })
  expect(necro.ok):eq(true)
end)

test("precheck_equip: alignment and strength gates (only when known)", function()
  local antigood = parse_identify("Item: 'holy ward'\nWeight: 1  Size: 0'1\"  Level: 1  Item Quality: WELL CRAFTED\n"
    .. "Type: ARMOR   Composition: METAL   Defense: 2 ac-apply\nObject is:  ANTI_GOOD\nWear locations are:  NECK\n"
    .. "You are carrying a holy ward.")
  expect(precheck_equip(antigood, { alignment = "good" }).ok):eq(false)
  expect(precheck_equip(antigood, { alignment = "neutral" }).ok):eq(true)
  expect(precheck_equip(antigood, {}).ok):eq(true)         -- alignment unknown -> not blocked

  local sickle = parse_identify(SICKLE)                    -- needs 11 strength
  expect(precheck_equip(sickle, { classes = { Necromancer = 5 }, str = 8 }).ok):eq(false)
  expect(precheck_equip(sickle, { classes = { Necromancer = 5 }, str = 15 }).ok):eq(true)
end)

-- ---- prompt builders -----------------------------------------------------------------------------
test("build_compare_prompt: character sheet, distilled rules, and per-item verdicts land in the prompt", function()
  E.reset()
  ingest(parse_identify(GLOVES))                           -- session-known, RARE armor, equippable at any level
  local char = { name = "Testchar", classes = { Necromancer = 12 }, alignment = "neutral", gold = 500 }
  local worn = { { slot = "hands", name = "a ragged mitten" } }   -- unidentified worn item
  local cands = { "well made leather gloves", "a nonexistent trinket" }
  local sys, user = build_compare_prompt(char, worn, cands, "")

  expect(sys):contains("EQUIPPABILITY RULES")             -- distilled rules go in the SYSTEM prompt
  expect(sys):contains("ANTI_GOOD")
  expect(user):contains("Necromancer 12")                 -- character sheet
  expect(user):contains("Total levels: 12")
  expect(user):contains("Gold: 500")
  expect(user):contains("well made leather gloves")       -- known candidate with stats
  expect(user):contains("AC 4")
  expect(user):contains("equippable")
  expect(user):contains("unidentified")                   -- the unknown items flagged, not judged
  expect(user):contains("eq.id(")                          -- migrated hint form (was "#eq id")
end)

test("build_compare_prompt: a multi-variant name is surfaced as AMBIGUOUS, never silently resolved", function()
  E.reset()
  ingest(parse_identify(GLOVES))
  ingest(parse_identify(GLOVES:gsub("Defense: 4", "Defense: 8")))
  E.session["well made leather gloves"] = nil              -- not currently held -> fall back to the cache
  local sys, user = build_compare_prompt({ classes = { Mage = 5 } }, {}, { "well made leather gloves" }, "")
  expect(user):contains("AMBIGUOUS")
  expect(user):contains("2 different")
  expect(user):contains("re-identify")
end)

test("build_shop_prompt: shop items with prices and gold land in the prompt", function()
  E.reset()
  local kept = { { price = 335, level = 1, name = "a soapstone necklace" } }
  local sys, user = build_shop_prompt({ classes = { Mage = 3 }, gold = 400 }, {}, kept)
  expect(sys):contains("shopping adviser")
  expect(user):contains("335 gold")
  expect(user):contains("a soapstone necklace")
  expect(user):contains("400 gold")
end)

test("looks_like_container: by keyword and by cached CONTAINER type", function()
  E.reset()
  expect(looks_like_container("a small sack")):eq(true)
  expect(looks_like_container("a leather backpack")):eq(true)
  expect(looks_like_container("a lost lead ring")):eq(false)
end)

-- ====================================================================================================
-- Live-wire identify capture + the auto-identify queue.
--
-- Every fixture below is VERBATIM from a raw session capture (mud_raw_copy.log, decoded off the wire —
-- ANSI/IAC stripped, split on \r\n) where the user identified their whole loadout by hand. This is the
-- exact line stream the trigger pipeline saw, kxwt_ wrappers and all (the earlier human-traces samples
-- were POST-gag, which hid the wrappers and the "You are wearing" display form and led to the bug).
-- ====================================================================================================

local feed_id_stream = E.feed_id_stream
local assign_ordinals = E.assign_ordinals
local build_id_queue  = E.build_id_queue

-- A WORN item's identify block: keyword name in Item:'…', display name only in "You are wearing …",
-- which arrives AFTER two blank lines, quality footers, and the kxwt_id_end marker.
local HOOD_LINES = {
  "kxwt_id_start",
  "Item: 'imp scalp horned imp-hide hide hood'  ",
  'Weight: 2  Size: 1\'0"  Level: 11  Item Quality: WELL CRAFTED',
  "Type: CLOTHING   Composition: FLESH, SKIN",
  "Object is:  NECR ",
  "Wear locations are:  HEAD ",
  "Item has other effects:",
  "Affects:  NECR_CAST_LEVEL by 1",
  "Affects:  MANA_REGEN by 0.5",
  "",
  "",
  "a horned imp-hide hood is WELL CRAFTED in quality.",
  "A horned imp-hide hood has not much room for improvement.",
  "kxwt_id_end",
  "You are wearing a horned imp-hide hood.",
}

-- A CARRIED item's block, ending "You are carrying a chameleon ring."
local RING_LINES = {
  "kxwt_id_start",
  "Item: 'ring chameleon'  ",
  'Weight: 1  Size: 0\'1"  Total levels: 25   Item Quality: WELL CRAFTED',
  "Type: TREASURE   Composition: MINERAL, CRYSTAL",
  "Object is: ",
  "Wear locations are:  FINGERS ",
  "Item has other effects:",
  "Affects:  HITROLL by 2",
  "",
  "",
  "a chameleon ring is WELL CRAFTED in quality.",
  "kxwt_id_end",
  "You are carrying a chameleon ring.",
}

test("PASSIVE CAPTURE (the bug): a worn-item block caches under the DISPLAY name the listing shows", function()
  E.reset()
  feed_id_stream(HOOD_LINES)
  -- Equipment listing shows "head - a horned imp-hide hood"; parse_eq_line -> "horned imp-hide hood".
  local r = resolve_item("horned imp-hide hood")
  expect(r.status):ne("unknown")                          -- BEFORE the fix this was "unknown" -> inert
  expect(r.status):eq("session")                          -- freshly identified this session
  expect(r.variant.type):eq("CLOTHING")
  expect(r.variant.class_flags[1]):eq("NECR")
  -- NOT keyed under the raw Item: keyword string.
  expect(resolve_item("imp scalp horned imp-hide hide hood").status):eq("unknown")
end)

test("PASSIVE CAPTURE: capture runs THROUGH the two blank lines + kxwt_id_end to reach the display line", function()
  E.reset()
  feed_id_stream(RING_LINES)
  local r = resolve_item("chameleon ring")                -- inventory shows "a chameleon ring"
  expect(r.status):eq("session")
  expect(r.variant.affects[1].stat):eq("HITROLL")
end)

test("PASSIVE CAPTURE: interleaved kxwt_ protocol lines inside a block are skipped, not terminators", function()
  E.reset()
  local lines = {}
  for _, l in ipairs(HOOD_LINES) do
    lines[#lines + 1] = l
    if l:match("^Affects:  MANA_REGEN") then
      lines[#lines + 1] = "kxwt_prompt 113 159 187 259 199 199"   -- a prompt tick lands mid-block
      lines[#lines + 1] = "kxwt_group_start"
    end
  end
  feed_id_stream(lines)
  expect(resolve_item("horned imp-hide hood").status):eq("session")   -- still fully captured
end)

test("PASSIVE CAPTURE: 'You are carrying N/M items' is NOT mistaken for a display line", function()
  E.reset()
  -- If the inventory summary bled into a block it must not bind as a display name.
  local v = parse_identify(table.concat({
    "Item: 'ring chameleon'", "Type: TREASURE   Composition: X",
    "You are carrying 5/9 items with weight 85/180 pounds.  Encumbrance:  10%",
  }, "\n"))
  expect(v.display):eq(nil)                               -- fell back to the keyword name, not the summary
  expect(v.name):eq("ring chameleon")
end)

-- ---- ordinal assignment ---------------------------------------------------------------------------
test("assign_ordinals: duplicate keywords get bare, then 2.kw, 3.kw in listing order", function()
  local es = assign_ordinals({
    { name = "a chameleon ring" }, { name = "a small silver ring" }, { name = "an imp eye ring" },
    { name = "a studded belt" },
  })
  expect(es[1].kw):eq("ring")       -- first ring is bare
  expect(es[2].kw):eq("2.ring")
  expect(es[3].kw):eq("3.ring")
  expect(es[4].kw):eq("belt")       -- a lone keyword stays bare
  expect(es[1].base_kw):eq("ring")
  expect(es[3].ordinal):eq(3)
end)

-- ---- build_id_queue -------------------------------------------------------------------------------
test("build_id_queue: skips session-bound AND single-variant cached; includes unknown, dedups", function()
  E.reset()
  -- 'a chameleon ring' identified THIS session (trustworthy) -> SKIPPED as already-known.
  feed_id_stream(RING_LINES)
  -- 'well made leather gloves' cached (one persisted variant), NOT session-bound -> now TRUSTED and
  -- SKIPPED (the persistence change: don't re-identify what one cached variant already tells us).
  ingest(parse_identify(GLOVES))
  E.session["well made leather gloves"] = nil

  local worn = { "a chameleon ring", "well made leather gloves" }
  local inv  = { "a horned imp-hide hood", "a horned imp-hide hood", "a mysterious orb" }  -- dup + unknown
  local queue, known = build_id_queue(worn, inv, {})

  expect(known):eq(2)                                    -- ring (session) + gloves (single cached variant)
  local names = {}
  for _, e in ipairs(queue) do names[e.name] = (names[e.name] or 0) + 1 end
  expect(names["chameleon ring"]):eq(nil)               -- skipped (session); names are article-stripped
  expect(names["well made leather gloves"]):eq(nil)     -- skipped (trusted cache)
  expect(names["horned imp-hide hood"]):eq(1)            -- duplicate display collapsed to one
  expect(names["mysterious orb"]):eq(1)                  -- unknown -> included
end)

test("build_id_queue: a MULTI-variant name (same name, 2 stat blocks) is STILL re-identified", function()
  E.reset()
  -- The only case the persistence change still pays for: two different variants cached under one name.
  ingest(parse_identify(GLOVES))
  E.items["well made leather gloves"].variants["fake-second-fp"] =
    { name = "well made leather gloves", fp = "fake-second-fp" }
  E.session["well made leather gloves"] = nil
  local queue = build_id_queue({ "well made leather gloves" }, {}, {})
  local byname = {}
  for _, e in ipairs(queue) do byname[e.name] = e.status end
  expect(byname["well made leather gloves"]):eq("multi")  -- ambiguous -> queued for re-id
end)

test("build_id_queue: ordinals span worn+carried as one scope (identify sees both)", function()
  E.reset()
  -- two different rings, one worn one carried: identify's scope is worn+carried, so the carried one is
  -- the SECOND ring overall and must be targeted as 2.ring, not bare 'ring'.
  local queue = build_id_queue({ "a small silver ring" }, { "an imp eye ring" }, {})
  local byname = {}
  for _, e in ipairs(queue) do byname[e.name] = e.kw end
  expect(byname["small silver ring"]):eq("ring")
  expect(byname["imp eye ring"]):eq("2.ring")
end)

test("build_id_queue: container items carry their container name + within-container ordinal", function()
  E.reset()
  local queue = build_id_queue({}, {}, {
    ["a small sack"] = { "an iridescent black sequined sash", "sleeves of the warmage", "a chameleon ring" },
  })
  local byname = {}
  for _, e in ipairs(queue) do byname[e.name] = e end
  expect(byname["iridescent black sequined sash"].container):eq("a small sack")
  expect(byname["iridescent black sequined sash"].kw):eq("sash")
  expect(byname["chameleon ring"].kw):eq("ring")         -- its own keyword, bare (one ring in this sack)
end)

-- ---- the identify pass, at the BEHAVIOUR level (send order / echo narration / outcome tally) -------
-- The pass is driven through the SAME reply seams the live Swift triggers push through — idq_start()
-- kicks it off, then idq_get_result(ok)/idq_advance(ok)/idq_put_result(ok) are the get/identify/put
-- replies, and d.tick() fires the one pacing timer the flow is currently waiting on (the inter-item gap
-- or the combat-retry beat). Every ASSERTION below is on captured send/echo or the pass outcome — NOT on
-- any internal queue field (index/phase/cursor/pending flags) — so the reactive reimplementation, which
-- stores its progress as a promise flow rather than a step counter, must still turn them green.
--
-- Timer capture is representation-agnostic (like corpse_spec): we record every after() and fire the most
-- recently-armed LIVE one. A reply seam cancels its phase watchdog before the next step arms the pacing
-- beat, so the newest live timer is always that beat — whether it lives in an S.idq field or a promise.
local function drive(queue, known)
  local sent, echoes, timers = {}, {}, {}
  local o_send, o_after, o_cancel, o_echo, o_incombat = send, after, cancel, echo, in_combat
  send = function(s) sent[#sent + 1] = s end
  after = function(_d, cb) timers[#timers + 1] = { delay = _d, cb = cb }; return #timers end
  cancel = function(id) if id and timers[id] then timers[id].cb = false end end
  echo = function(s) echoes[#echoes + 1] = tostring(s) end
  in_combat = nil
  local ctx = {
    sent = sent, echoes = echoes,
    -- Fire the single pacing timer the flow is waiting on (the gap between items, or the combat-retry).
    tick = function()
      for i = #timers, 1, -1 do
        local t = timers[i]
        if t.cb then local cb = t.cb; t.cb = false; cb(); return end
      end
    end,
    set_combat = function(f) in_combat = f end,
    restore = function() send, after, cancel, echo, in_combat = o_send, o_after, o_cancel, o_echo, o_incombat end,
    summary = function() for _, e in ipairs(echoes) do if e:find("identify pass:", 1, true) then return e end end end,
  }
  E.idq_start(queue, known)
  return ctx
end

test("QUEUE: paces inventory identifies one at a time and reports the summary counts", function()
  E.reset()
  local queue = {
    { name = "a steel longsword", kw = "longsword", base_kw = "longsword" },
    { name = "a lost lead ring",  kw = "ring",      base_kw = "ring" },
  }
  local d = drive(queue, 3)
  expect(d.sent[1]):eq("identify longsword")             -- first identify fired synchronously on start
  E.idq_advance(true); d.tick()                          -- block parsed -> gap -> next entry
  expect(d.sent[2]):eq("identify ring")
  E.idq_advance(true); d.tick()                          -- done
  expect(#d.sent):eq(2)                                  -- exactly the two identifies — pass wrapped up
  expect(d.summary()):contains("2 identified, 0 failed, 3 already known")
  d.restore()
end)

test("QUEUE: an identify failure is counted and skipped, the pass continues", function()
  E.reset()
  local queue = {
    { name = "a ghost sword", kw = "sword", base_kw = "sword" },
    { name = "a real ring",   kw = "ring",  base_kw = "ring" },
  }
  local d = drive(queue, 0)
  expect(d.sent[1]):eq("identify sword")
  E.idq_advance(false); d.tick()                         -- "You don't seem to be carrying…" / timeout
  expect(d.sent[2]):eq("identify ring")
  E.idq_advance(true); d.tick()
  expect(d.summary()):contains("1 identified, 1 failed")
  d.restore()
end)

test("QUEUE: a container item is get -> identify -> put, in that order", function()
  E.reset()
  local queue = { { name = "an iridescent black sequined sash", kw = "sash", base_kw = "sash",
                    container = "a small sack" } }
  local d = drive(queue, 0)
  expect(d.sent[1]):eq("get sash sack")                  -- pulled out first
  E.idq_get_result(true)
  expect(d.sent[2]):eq("identify sash")                  -- identified in inventory
  E.idq_advance(true)
  expect(d.sent[3]):eq("put sash sack")                  -- returned to the sack
  E.idq_put_result(true); d.tick()
  expect(d.summary()):contains("1 identified, 0 failed")
  d.restore()
end)

test("QUEUE: identify FAILING on a container item STILL puts it back (never left out)", function()
  E.reset()
  local queue = { { name = "a cursed idol", kw = "idol", base_kw = "idol", container = "a chest" } }
  local d = drive(queue, 0)
  expect(d.sent[1]):eq("get idol chest")
  E.idq_get_result(true)
  E.idq_advance(false)                                   -- identify failed
  expect(d.sent[3]):eq("put idol chest")                 -- restored anyway
  E.idq_put_result(true); d.tick()
  expect(d.summary()):contains("0 identified, 1 failed")   -- pass completed: id failed but item restored
  d.restore()
end)

test("QUEUE: a get failure skips the item WITHOUT any put (nothing was pulled out)", function()
  E.reset()
  local queue = { { name = "a wedged gem", kw = "gem", base_kw = "gem", container = "a sack" } }
  local d = drive(queue, 0)
  expect(d.sent[1]):eq("get gem sack")
  E.idq_get_result(false)                                -- "You don't see anything named…" / can't carry
  d.tick()
  expect(#d.sent):eq(1)                                  -- no identify, no put
  expect(d.summary()):contains("0 identified, 1 failed")
  d.restore()
end)

test("QUEUE: a PUT-BACK failure is reported LOUDLY with the item left on you", function()
  E.reset()
  local queue = { { name = "a heavy anvil", kw = "anvil", base_kw = "anvil", container = "a bag" } }
  local d = drive(queue, 0)
  E.idq_get_result(true)                                 -- got it out
  E.idq_advance(true)                                    -- identified
  E.idq_put_result(false); d.tick()                      -- put back FAILED
  local warned
  for _, e in ipairs(d.echoes) do if e:find("could NOT return", 1, true) then warned = e end end
  expect(warned):contains("a heavy anvil")
  d.restore()
end)

test("QUEUE: combat pause defers the next entry until combat clears", function()
  E.reset()
  local queue = {
    { name = "a sword", kw = "sword", base_kw = "sword" },
    { name = "a ring",  kw = "ring",  base_kw = "ring" },
  }
  local d = drive(queue, 0)
  expect(d.sent[1]):eq("identify sword")
  d.set_combat(function() return true end)
  E.idq_advance(true); d.tick()                          -- gap fires -> next entry sees combat -> pauses
  expect(#d.sent):eq(1)                                  -- 2nd identify NOT sent yet
  d.set_combat(nil)
  d.tick()                                               -- combat-retry timer -> now proceeds
  expect(d.sent[2]):eq("identify ring")
  E.idq_advance(true); d.tick()
  expect(d.summary()):contains("2 identified")             -- both identified once combat cleared
  d.restore()
end)

test("QUEUE + binding: finalize binds the parsed block to the possession name the queue asked about", function()
  E.reset()
  -- The queue sets id_expect to the possession-list display; a matching block binds under it.
  E.set_id_expect("horned imp-hide hood")
  feed_id_stream(HOOD_LINES)
  expect(resolve_item("horned imp-hide hood").status):eq("session")
  E.set_id_expect(nil)
end)

-- ====================================================================================================
-- Flag markers in listings ("(glow)" et al) — the live 'glow' bug.
--
-- Verbatim from a raw session capture (mud_raw_glow.log): four DIFFERENT worn items carry a trailing
-- "(glow)" display marker. The old parse_eq_line stripped only the LEADING "(rare)" column, so all four
-- kept "(glow)" in their names; first_kw (last word) derived the keyword 'glow' for every one of them —
-- the queue sent `identify glow` / `2.glow` / `3.glow` / `4.glow` (all failed on the wire:
-- "You don't seem to be carrying anything named 'glow'."), the compare prompt called them 'glow', and a
-- manual identify could never bind because the possession key ("imp eye ring (glow)") never matched the
-- clean display name ("imp eye ring"). Markers now split into a separate flags field.
-- ====================================================================================================

local split_flags = E.split_flags

-- The exact wire lines for the four items (equipment listing), plus flag-column and plain rows.
local GLOW_EQ_LINES = {
  "head        -              a horned imp-hide hood",
  "neck        - (artifact)   a skull necklace",
  "hands       - (rare)       a minstrel's glove",
  "finger      -              a small silver ring",
  "finger      -              an imp eye ring (glow)",
  "on body     -              a neon blue tiara (glow)",
  "feet        -              neon blue sweatsocks (glow)",
  "held        -              the harp of healing (glow)",
  "weapon      -              a blackened bronze sickle",
}

test("GLOW BUG: parse_eq_line strips a trailing '(glow)' into flags, name stays the real item", function()
  local slot, item, flags = parse_eq_line("finger      -              an imp eye ring (glow)")
  expect(slot):eq("finger")
  expect(item):eq("imp eye ring")                        -- NOT "imp eye ring (glow)"
  expect(flags.glow):eq(true)
  slot, item, flags = parse_eq_line("held        -              the harp of healing (glow)")
  expect(item):eq("harp of healing")
  expect(flags.glow):eq(true)
  -- the leading flag column still parses, and lands in flags too now
  slot, item, flags = parse_eq_line("neck        - (artifact)   a skull necklace")
  expect(item):eq("skull necklace")
  expect(flags.artifact):eq(true)
  slot, item, flags = parse_eq_line("hands       - (rare)       a minstrel's glove")
  expect(item):eq("minstrel's glove")
  expect(flags.rare):eq(true)
end)

test("GLOW BUG: first_kw never derives a keyword from a flag word or paren group", function()
  expect(E.first_kw("an imp eye ring (glow)")):eq("ring")
  expect(E.first_kw("a neon blue tiara (glow)")):eq("tiara")
  expect(E.first_kw("neon blue sweatsocks (glow)")):eq("sweatsocks")
  expect(E.first_kw("the harp of healing (glow)")):eq("healing")   -- last non-flag noun ('healing' is a real keyword)
  expect(E.first_kw("imp eye ring")):eq("ring")                     -- clean names unchanged
end)

test("GLOW BUG: norm_name defensively drops trailing known markers so possession keys match bindings", function()
  expect(E.norm_name("an imp eye ring (glow)")):eq("imp eye ring")
  expect(E.norm_name("sleeves of the warmage (glow)")):eq("sleeves of the warmage")
  expect(E.norm_name("a quartz-tipped wooden cane (light)")):eq("quartz-tipped wooden cane")
  expect(E.norm_name("an obsidian doom-ring (hum)")):eq("obsidian doom-ring")
end)

test("split_flags: peels stacked markers, canonicalizes, and never eats a fully-parenthesized string", function()
  local name, flags = split_flags("a wand of light (glowing) (humming)")
  expect(name):eq("a wand of light")
  expect(flags.glow):eq(true)                            -- glowing -> glow (canonical)
  expect(flags.hum):eq(true)                             -- humming -> hum
  local n2 = split_flags("(carried)")                    -- whole-string parens: not a trailing marker
  expect(n2):eq("(carried)")
end)

test("GLOW BUG: parse_item_line keeps flags as metadata off the inventory name", function()
  local name, flags = parse_item_line("sleeves of the warmage (glow)")
  expect(name):eq("sleeves of the warmage")
  expect(flags.glow):eq(true)
  local n2, f2 = parse_item_line("(    1) an iridescent black sequined sash")   -- count prefix intact
  expect(n2):eq("an iridescent black sequined sash")
  expect(f2 == nil or next(f2) == nil):truthy()
end)

test("REGRESSION: a listing with N glowing items -> N distinct possession entries, each glowing=true", function()
  E.reset(); E.scan_reset()
  E.scan_begin("eq")
  for _, l in ipairs(GLOW_EQ_LINES) do E.scan_feed(l) end
  local sc = E.scan_state()
  expect(#sc.eq):eq(9)
  local glowing, names = {}, {}
  for _, e in ipairs(sc.eq) do
    names[e.item] = true
    expect(e.item):ne("glow")                            -- no entry collapsed to the marker word
    if e.flags and e.flags.glow then glowing[#glowing + 1] = e.item end
  end
  expect(#glowing):eq(4)                                 -- exactly the four glowing items…
  table.sort(glowing)
  expect(glowing[1]):eq("harp of healing")               -- …with their REAL distinct names
  expect(glowing[2]):eq("imp eye ring")
  expect(glowing[3]):eq("neon blue sweatsocks")
  expect(glowing[4]):eq("neon blue tiara")
  expect(names["skull necklace"]):eq(true)               -- flag-column items unharmed
  E.scan_reset()
end)

test("GLOW BUG: build_id_queue targets real keywords for the four items — never 'glow' ordinals", function()
  E.reset()
  local worn = {}
  -- feed the parsed (clean) names exactly as finish_scan would after the fix
  for _, l in ipairs(GLOW_EQ_LINES) do
    local _, item = parse_eq_line(l)
    worn[#worn + 1] = item
  end
  local queue = build_id_queue(worn, {}, {})
  for _, e in ipairs(queue) do
    expect(e.kw:match("glow")):eq(nil)                   -- the old queue sent glow/2.glow/3.glow/4.glow
  end
  local kws = {}
  for _, e in ipairs(queue) do kws[e.name] = e.kw end
  expect(kws["imp eye ring"]):eq("2.ring")               -- 'small silver ring' is ring #1 in the scope
  expect(kws["neon blue tiara"]):eq("tiara")
  expect(kws["neon blue sweatsocks"]):eq("sweatsocks")
  expect(kws["harp of healing"]):eq("healing")
end)

test("GLOW BUG: identify now BINDS — possession key from a '(glow)' listing resolves after the id block", function()
  E.reset()
  -- The user's manual identify of the tiara (verbatim block shape: keyword header, worn display line).
  E.feed_id_stream({
    "kxwt_id_start",
    "Item: 'neon blue tiara clothing piece'  ",
    'Weight: 1  Size: 0\'6"  Level: 11  Item Quality: WELL CRAFTED',
    "Type: CLOTHING   Composition: TEXTILE, CLOTH",
    "Object is:  GLOW ",
    "Wear locations are:  BODY ",
    "Affects:  MANA by 5",
    "",
    "",
    "a neon blue tiara is WELL CRAFTED in quality.",
    "kxwt_id_end",
    "You are wearing a neon blue tiara.",
  })
  -- Possession key comes from the eq listing WITH the marker; before the fix this stayed 'unknown'
  -- ("Even after I identified it, it told me to identify it").
  local _, item = parse_eq_line("on body     -              a neon blue tiara (glow)")
  expect(resolve_item(item).status):eq("session")
end)

test("GLOW BUG: the compare prompt carries the real display names (with glowing as a property)", function()
  E.reset()
  local worn = {}
  for _, l in ipairs({ GLOW_EQ_LINES[5], GLOW_EQ_LINES[6] }) do   -- imp eye ring / neon blue tiara
    local slot, item, flags = parse_eq_line(l)
    worn[#worn + 1] = { slot = slot, name = item, flags = flags }
  end
  local _, user = build_compare_prompt({ classes = { Necromancer = 20 } }, worn, {}, "")
  expect(user):contains("imp eye ring")                  -- the model sees the REAL names…
  expect(user):contains("neon blue tiara")
  expect(user):contains("glowing")                       -- …and the marker as a property
  expect(user:find("- glow:", 1, true)):eq(nil)          -- never an item literally named 'glow'
  expect(user:find("eq.id('glow')", 1, true)):eq(nil)    -- and never an identify-'glow' hint
end)

-- ---- eq operations as promises -------------------------------------------------------------------

local function eq_widget_has(desc)
  for _, e in ipairs(active_promises()) do if e.desc == desc then return true end end
  return false
end

test("an eq op runs as a tracked promise that shows in the widget and settles on resolve", function()
  _PROMISE_TEST.cancel_all()
  local p = E.eq_begin("eq.test")
  expect(p ~= nil):eq(true)
  local during = eq_widget_has("eq.test")
  E.eq_resolve()
  local after = eq_widget_has("eq.test")
  expect(during):eq(true)
  expect(after):eq(false)
end)

test("starting a new eq op supersedes (rejects) the running one", function()
  _PROMISE_TEST.cancel_all()
  local p1 = E.eq_begin("eq.one")
  local rejected
  p1.catch(function(reason) rejected = reason end)
  E.eq_begin("eq.two")                 -- supersedes p1
  expect(rejected):eq("superseded")
  E.eq_resolve()                        -- settle p2 so it doesn't linger
  expect(eq_widget_has("eq.one")):eq(false)
end)

test("eq_instant returns an already-settling promise (for the synchronous stats/forget ops)", function()
  _PROMISE_TEST.cancel_all()
  local p = E.eq_instant("eq.stats")
  expect(p ~= nil):eq(true)
  p.__start()                           -- CLI harness doesn't auto-fire the builder's next-tick start
  expect(eq_widget_has("eq.stats")):eq(false)   -- resolved immediately → not pending
end)
