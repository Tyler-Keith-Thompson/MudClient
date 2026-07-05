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
local SHOP = [[a wizard's apprentice tells you, 'The following items are available for sale at this time'
[  Price] Held ---------------------------------------
[     28] (lvl   0) a wand of scorch
[    126] (lvl   1) a wand of crystal light
[  Price] Miscellaneous ---------------------------------------
[    155] (lvl   1) a scroll of detect magic
[  Price] Worn on neck ---------------------------------------
[    335] (lvl   1) a soapstone necklace
To see a specific item in detail, give the item name.]]

test("parse_shop_row: category header vs priced item row", function()
  local cat = parse_shop_row("[  Price] Worn on neck ---------------------------------------")
  expect(cat.category):eq("Worn on neck")
  local row = parse_shop_row("[     28] (lvl   0) a wand of scorch")
  expect(row.price):eq(28); expect(row.level):eq(0); expect(row.name):eq("a wand of scorch")
end)

test("parse_shop_list: seller, rows tagged with their category", function()
  local p = parse_shop_list(SHOP)
  expect(p.seller):eq("a wizard's apprentice")
  expect(#p.rows):eq(4)
  expect(p.rows[1].category):eq("Held")
  expect(p.rows[4].name):eq("a soapstone necklace")
  expect(p.rows[4].category):eq("Worn on neck")
end)

test("parse_shop_list: recognizes the not-at-a-shop message", function()
  local p = parse_shop_list("There is nothing here to list (no shopkeeper, donation, priest, or guildmaster.)")
  expect(p.no_shop):eq(true)
end)

test("shortlist_shop: keeps the wearable necklace, skips wands/scrolls", function()
  local kept, skipped = shortlist_shop(parse_shop_list(SHOP), 8)
  expect(#kept):eq(1)
  expect(kept[1].name):eq("a soapstone necklace")
  expect(#skipped):eq(3)
  expect(is_consumable("a wand of scorch")):eq(true)
  expect(is_consumable("a soapstone necklace")):eq(false)
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
  expect(user):contains("#eq id")
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
