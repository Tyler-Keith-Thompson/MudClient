-- Specs for AlterAeon.lua's authoritative spell membership from the `score`/affects block and the
-- per-class levels line. Rows are the user's VERBATIM `score` output. MEMBERSHIP ONLY: we extract name
-- (+ free level); the "<duration> remaining" middle is an opaque blob — no timing is parsed or stored,
-- which is why the varied duration grammars below must all still yield the right name/level.

local parse_affect_row = _AA_TEST.parse_affect_row
local affects_to_spells = _AA_TEST.affects_to_spells
local parse_levels     = _AA_TEST.parse_levels

-- The verbatim affects block (10 rows) with the expected name + level. The duration forms vary wildly
-- (minutes / numeric hours / spelled hours / "one hour, N minutes") and MUST all be skipped as noise.
local ROWS = {
  { "Spell 'bless', 0 minutes remaining, level 6",                     "bless",         6 },
  { "Spell 'mana shield', 20 minutes remaining, level 12",             "mana shield",   12 },
  { "Spell 'fire shield', 40 minutes remaining, level 12",             "fire shield",   12 },
  { "Spell 'infravision', 40 minutes remaining, level 12",             "infravision",   12 },
  { "Spell 'faith shield', 40 minutes remaining, level 6",             "faith shield",  6 },
  { "Spell 'fly', one hour, 10 minutes remaining, level 12",           "fly",           12 },
  { "Spell 'armor aegis', one hour, 20 minutes remaining, level 6",    "armor aegis",   6 },
  { "Spell 'force shield', two hours, 40 minutes remaining, level 12", "force shield",  12 },
  { "Spell 'dread portent', 5 hours remaining, level 19",             "dread portent", 19 },
  { "Spell 'foulblood', 4 hours remaining, level 19",                 "foulblood",     19 },
}

test("parse_affect_row parses every verbatim block row into name + level, ignoring the duration blob", function()
  for _, r in ipairs(ROWS) do
    local got = parse_affect_row(r[1])
    expect(got):truthy()
    expect(got.name):eq(r[2])
    expect(got.level):eq(r[3])
    expect(got.minutes):eq(nil)     -- no timing data is stored, whatever the duration phrase
  end
  -- A non-affect line is rejected.
  expect(parse_affect_row("You have 164/164 hit, 236/263 mana, 199/199 movement.")):eq(nil)
end)

test("affects_to_spells reconciles WHOLESALE — the block replaces stale spell state, not merges it", function()
  -- Start from a stale set (an old kxwt_spellup that already expired, plus one still-real spell).
  local stale = { ["stale buff"] = true, bless = true }
  local rows = {}
  for _, r in ipairs(ROWS) do rows[#rows + 1] = parse_affect_row(r[1]) end
  local fresh = affects_to_spells(rows)
  -- Every block spell is present with its level; the stale one is GONE (wholesale replace).
  expect(fresh["stale buff"]):eq(nil)
  expect(fresh["bless"].level):eq(6)
  expect(fresh["force shield"].level):eq(12)
  local n = 0
  for _ in pairs(fresh) do n = n + 1 end
  expect(n):eq(10)                          -- exactly the 10 block spells, nothing extra
  -- (fresh replaces state.spells at the trigger's commit; `stale` is untouched by the pure builder.)
  expect(stale["stale buff"]):truthy()
end)

test("parse_levels reads the abbreviated per-class levels line into full class names", function()
  local lv = parse_levels("Ma 12  Cl 6  Th 0  Wa 0  Nc 17  Dr 0")
  expect(lv.Mage):eq(12)
  expect(lv.Cleric):eq(6)
  expect(lv.Thief):eq(0)
  expect(lv.Warrior):eq(0)
  expect(lv.Necromancer):eq(17)
  expect(lv.Druid):eq(0)
end)
