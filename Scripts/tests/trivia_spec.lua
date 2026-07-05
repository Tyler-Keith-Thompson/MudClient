-- Specs for Trivia.lua's pure parsing/lookup helpers — the parts that decide which letter we send.
-- (The triggers, model call, and file cache run in Swift/the live state and aren't unit-testable here.)

local parse_choices    = _TRIVIA_TEST.parse_choices
local extract_letter   = _TRIVIA_TEST.extract_letter
local norm             = _TRIVIA_TEST.norm
local letter_for_text  = _TRIVIA_TEST.letter_for_text
local parse_area_row   = _TRIVIA_TEST.parse_area_row
local pick_keyword     = _TRIVIA_TEST.pick_keyword
local choice_for_level = _TRIVIA_TEST.choice_for_level

test("parse_choices splits the standard triple-space choice line", function()
  local c = parse_choices("A: 3.   B: 2.   C: 18.   D: 8.")
  expect(c.a):eq("3")
  expect(c.b):eq("2")
  expect(c.c):eq("18")
  expect(c.d):eq("8")
end)

test("parse_choices handles two-space separators and multi-word answers", function()
  -- Real line: "A: brew focus.  B: crystal shield.  C: lesser crystal elemental.  D: dancing lights."
  local c = parse_choices("A: brew focus.  B: crystal shield.  C: lesser crystal elemental.  D: dancing lights.")
  expect(c.a):eq("brew focus")
  expect(c.b):eq("crystal shield")
  expect(c.c):eq("lesser crystal elemental")
  expect(c.d):eq("dancing lights")
end)

test("extract_letter reads a bare letter, a sentence, and lowercase", function()
  expect(extract_letter("C")):eq("c")
  expect(extract_letter("The answer is C.")):eq("c")   -- skips multi-letter words, finds the isolated C
  expect(extract_letter("b")):eq("b")
  expect(extract_letter("I think it's B")):eq("b")     -- skips the non-choice single letter "I"
  expect(extract_letter("D) mage")):eq("d")            -- "D" isolated (bounded by start and ")")
  expect(extract_letter("Answer: c")):eq("c")          -- labeled-delimiter fallback
end)

test("extract_letter returns nil when there is no choice letter", function()
  -- "idea" contains a 'd', but only buried in a word — must NOT be mistaken for choice D.
  expect(extract_letter("no idea")):eq(nil)
  expect(extract_letter("")):eq(nil)
end)

test("norm canonicalizes for stable cache keys and text matching", function()
  expect(norm("  What LEVEL is the  area  Darring Road? ")):eq("what level is the area darring road?")
  expect(norm("18.")):eq("18")                          -- trailing period dropped so answer text matches
  expect(norm("Brew Focus.")):eq("brew focus")
end)

test("parse_area_row reads normal (Lvl) and group (Grp) rows from real `area` output", function()
  local n = parse_area_row("Lvl  34    Ruined Temple                          occam phaug kelnale gandor")
  expect(n.kind):eq("Lvl")
  expect(n.n1):eq(34)
  expect(n.desc):eq("ruined temple")                 -- leading "The" only stripped when present
  local g = parse_area_row("Grp 195 10 The nightmare plane, The temple of bones         morpheus inessa")
  expect(g.kind):eq("Grp")
  expect(g.n1):eq(195)
  expect(g.n2):eq(10)
  expect(g.desc):eq("nightmare plane, the temple of bones")
  local f = parse_area_row("Lvl   8    The False Temple                                 morpheus dentin")
  expect(f.n1):eq(8)
  expect(f.desc):eq("false temple")
end)

test("parse_area_row rejects headers, dashes, and sector titles", function()
  expect(parse_area_row("Level      Description                Creators")):eq(nil)
  expect(parse_area_row("----------------------------------------")):eq(nil)
  expect(parse_area_row("The Mainland of Atmir")):eq(nil)
  expect(parse_area_row("")):eq(nil)
end)

test("pick_keyword picks the most distinctive word, skipping stopwords", function()
  expect(pick_keyword("The Ryuu Graveyard")):eq("Graveyard")
  expect(pick_keyword("The Mines of Minos")):eq("Mines")   -- first of equal-length non-stopwords
  expect(pick_keyword("Darring Road")):eq("Darring")
end)

test("choice_for_level maps a level to the right choice, phrasing-aware", function()
  -- Normal area (Lvl 11) with "level N" choices — like the real Polliwog Swamp question.
  local poll = parse_choices("A: level 11.  B: level 12.  C: level 9.  D: level 8.")
  expect(choice_for_level(poll, 11, false)):eq("a")
  -- Group area (Grp 165) where choices mix "N total levels" and "level N" — the real Ryuu Graveyard.
  local ryuu = parse_choices("A: 165 total levels.  B: level 39.  C: level 38.  D: 171 total levels.")
  expect(choice_for_level(ryuu, 165, true)):eq("a")       -- prefers the "total levels" phrasing
  expect(choice_for_level(ryuu, 999, true)):eq(nil)       -- no matching number
end)

test("letter_for_text finds the answer regardless of A-D order (shuffle-proof memory)", function()
  local first  = parse_choices("A: 3.   B: 2.   C: 18.   D: 8.")
  expect(letter_for_text(first, norm("18."))):eq("c")
  -- Same question asked again with the choices reordered — the cached ANSWER TEXT still resolves.
  local reshuffled = parse_choices("A: 18.   B: 8.   C: 3.   D: 2.")
  expect(letter_for_text(reshuffled, norm("18."))):eq("a")
  -- A cached answer that isn't among this asking's choices resolves to nil (caller falls back to model).
  expect(letter_for_text(first, norm("99"))):eq(nil)
end)
