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

-- ---- model tool-calling helpers (look answers up via in-game commands) --------------------------
local parse_tool_call = _TRIVIA_TEST.parse_tool_call
local tool_command    = _TRIVIA_TEST.tool_command
local capture_keep    = _TRIVIA_TEST.capture_keep

test("parse_tool_call pulls the tool name + argument out of the escaped tool_calls JSON", function()
  -- the shape ai_local_tools_request hands back: [{name, arguments}] with arguments an escaped json string
  local n, a = parse_tool_call('[{"name":"area_info","arguments":"{\\"area_name\\":\\"Cliffside Island\\"}"}]')
  expect(n):eq("area_info")
  expect(a.area_name):eq("Cliffside Island")
  local n2, a2 = parse_tool_call('[{"name":"library_entry","arguments":"{\\"entry_number\\":48043}"}]')
  expect(n2):eq("library_entry")
  expect(a2.entry_number):eq(48043)
end)

test("tool_command builds the right in-game command (area uses the distinctive keyword)", function()
  expect(tool_command("area_info", { area_name = "Cliffside Island" })):eq("area Cliffside")
  expect(tool_command("library_entry", { entry_number = 48043 })):eq("library read 48043")
  expect(tool_command("area_info", { area_name = "" })):eq(nil)      -- no usable arg
  expect(tool_command("library_entry", {})):eq(nil)
  expect(tool_command("bogus", { x = 1 })):eq(nil)                   -- unknown tool
end)

test("capture_keep drops noise (blanks, kxwt, the [event] channel, our echoed command) but keeps real output", function()
  expect(capture_keep("The Continent of Gianasi", "area Cliffside")):eq(true)
  expect(capture_keep("Grp 183  4 Cliffside Island   creators", "area Cliffside")):eq(true)
  expect(capture_keep("", "area Cliffside")):eq(false)
  expect(capture_keep("   ", "area Cliffside")):eq(false)
  expect(capture_keep("kxwt_prompt 1 2 3", "area Cliffside")):eq(false)
  expect(capture_keep("[event] trivia answer: ...", "area Cliffside")):eq(false)
  expect(capture_keep("area Cliffside", "area Cliffside")):eq(false)  -- our own echoed command
  -- combat text is KEPT (the model reads through it) — we only strip machinery
  expect(capture_keep("A gnoll's claw hits you.", "area Cliffside")):eq(true)
end)

-- ---- Great Library: never read a fabricated book number ----------------------------------------
local library_read_failed   = _TRIVIA_TEST.library_read_failed
local parse_library_list    = _TRIVIA_TEST.parse_library_list
local library_title         = _TRIVIA_TEST.library_title
local library_keyword       = _TRIVIA_TEST.library_keyword
local question_book_number  = _TRIVIA_TEST.question_book_number
local library_pick_entry    = _TRIVIA_TEST.library_pick_entry

test("library_read_failed recognizes the game's invalid-book-number rejection", function()
  -- The real line that ended the buggy trace — this must trigger the discovery/retry path, not a blind answer.
  expect(library_read_failed("Sorry, that's not a valid book number. ('library list' for a list)")):eq(true)
  expect(library_read_failed("some combat\nSorry, that's not a valid book number.\nmore")):eq(true)
  -- A successful read is NOT a failure.
  expect(library_read_failed("48043 - a scriber's book of runes     Topic: philosophy")):eq(false)
  expect(library_read_failed("")):eq(false)
  expect(library_read_failed(nil)):eq(false)
end)

test("parse_library_list reads numbered catalog entries and ignores non-catalog lines", function()
  local out = table.concat({
    "Welcome to the Alter Aeon Historical Archive!",
    "2110 - the book of the sea     Topic: geography",
    "37364 - a book called 'The Origin of Tartan and Plaid Cloth'     Topic: history and artifacts",
    "48043 - a scriber's book of runes     Topic: philosophy",
    "A scorpion bat's bite scratches you.",
  }, "\n")
  local e = parse_library_list(out)
  expect(#e):eq(3)
  expect(e[1].num):eq(2110)
  expect(e[1].title):eq("the book of the sea")
  expect(e[1].topic):eq("geography")
  expect(e[3].num):eq(48043)
  expect(e[3].topic):eq("philosophy")
  -- an entry with no Topic column still parses (title = whole rest)
  local e2 = parse_library_list("16105 - a lightly scorched letter")
  expect(e2[1].num):eq(16105)
  expect(e2[1].title):eq("a lightly scorched letter")
end)

test("library_title / library_keyword pull the book title out of a topic question", function()
  local q = 'What is the topic of a book entitled "A Magic Primer: Constructs" in the Great Library?'
  expect(library_title(q)):eq("A Magic Primer: Constructs")
  expect(library_keyword(q)):eq("Constructs")           -- longest distinctive title word → `library list Constructs`
  expect(library_title("What class is the lunge skill?")):eq(nil)
  expect(library_keyword("What class is the lunge skill?")):eq(nil)
  -- alternate phrasings the game uses
  expect(library_title("a book called 'The Origin of Tartan and Plaid Cloth'")):eq("The Origin of Tartan and Plaid Cloth")
  expect(library_title("titled, 'The History of Pellam, volume 2'")):eq("The History of Pellam, volume 2")
end)

test("question_book_number trusts a number stated in the question, nothing else", function()
  expect(question_book_number("What is entry 16105 in the Great Library?")):eq(16105)
  expect(question_book_number("What is book #48043?")):eq(48043)
  -- A topic question states NO number, so there's nothing to trust — the model's guess must never be read.
  expect(question_book_number('What is the topic of a book entitled "A Magic Primer: Constructs"?')):eq(nil)
end)

test("library_pick_entry only yields a number that actually appeared in the catalog", function()
  local entries = parse_library_list(table.concat({
    "2110 - the book of the sea     Topic: geography",
    "37364 - a book called 'The Origin of Tartan and Plaid Cloth'     Topic: history and artifacts",
    "48043 - a scriber's book of runes     Topic: philosophy",
  }, "\n"))
  -- Title match resolves to the listed number (which we then `library read`) — a real, validated number.
  local q = "What is the topic of a book called 'The Origin of Tartan and Plaid Cloth'?"
  expect(library_pick_entry(entries, q)):eq(37364)
  -- No entry matches the title → nil, so the caller GIVES UP the lookup instead of reading a guess.
  expect(library_pick_entry(entries, 'What is the topic of "A Nonexistent Tome"?')):eq(nil)
  -- Empty catalog → nil (never invent a number).
  expect(library_pick_entry({}, q)):eq(nil)
  expect(library_pick_entry(parse_library_list(""), q)):eq(nil)
  -- No title in the question but the search pinned exactly one entry → trust it.
  local one = parse_library_list("2110 - the book of the sea     Topic: geography")
  expect(library_pick_entry(one, "What book is this?")):eq(2110)
end)
