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
test("build_id_queue: skips session-bound, includes unknown/multi/stale, dedups identical displays", function()
  E.reset()
  -- 'a chameleon ring' identified THIS session (trustworthy) -> must be SKIPPED as already-known.
  feed_id_stream(RING_LINES)
  -- 'well made leather gloves' cached but NOT session-bound (stale) -> must be INCLUDED.
  ingest(parse_identify(GLOVES))
  E.session["well made leather gloves"] = nil

  local worn = { "a chameleon ring", "well made leather gloves" }
  local inv  = { "a horned imp-hide hood", "a horned imp-hide hood", "a mysterious orb" }  -- dup + unknown
  local queue, known = build_id_queue(worn, inv, {})

  expect(known):eq(1)                                     -- the chameleon ring
  local names = {}
  for _, e in ipairs(queue) do names[e.name] = (names[e.name] or 0) + 1 end
  expect(names["chameleon ring"]):eq(nil)               -- skipped (session); names are article-stripped
  expect(names["well made leather gloves"]):eq(1)        -- stale cache -> re-id
  expect(names["horned imp-hide hood"]):eq(1)            -- duplicate display collapsed to one
  expect(names["mysterious orb"]):eq(1)                  -- unknown -> included
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

-- ---- the phase machine (pacing / get-id-put / failure-skip / summary) ------------------------------
-- Drive the queue deterministically: capture sends + echoes, record timers, fire the pending one to step.
local function drive(queue, known)
  local sent, echoes, timers = {}, {}, {}
  local o_send, o_after, o_cancel, o_echo, o_incombat = send, after, cancel, echo, in_combat
  send = function(s) sent[#sent + 1] = s end
  after = function(_d, cb) timers[#timers + 1] = cb; return #timers end
  cancel = function(id) if id then timers[id] = false end end
  echo = function(s) echoes[#echoes + 1] = tostring(s) end
  local ctx = {
    sent = sent, echoes = echoes,
    -- fire whatever timer the queue is currently waiting on (a gap step or combat-retry).
    tick = function()
      local q = E.idq_state()
      if q and q.timer and timers[q.timer] then local cb = timers[q.timer]; timers[q.timer] = false; cb() end
    end,
    set_combat = function(f) in_combat = f end,
    restore = function() send, after, cancel, echo, in_combat = o_send, o_after, o_cancel, o_echo, o_incombat end,
    summary = function() for _, e in ipairs(echoes) do if e:find("identify pass:", 1, true) then return e end end end,
  }
  in_combat = nil
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
  expect(E.idq_state()):eq(nil)                          -- queue torn down
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
  expect(E.idq_state()):eq(nil)
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
  expect(E.idq_state()):eq(nil)
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
