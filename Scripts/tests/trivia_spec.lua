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

test("tool_command builds the area lookup; library is NOT an in-game command (it reads the local mirror)", function()
  expect(tool_command("area_info", { area_name = "Cliffside Island" })):eq("area Cliffside")
  expect(tool_command("area_info", { area_name = "" })):eq(nil)             -- no usable arg
  expect(tool_command("library_entry", { entry_number = 48043 })):eq(nil)  -- library resolves from disk now
  expect(tool_command("bogus", { x = 1 })):eq(nil)                         -- unknown tool
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

-- ---- Great Library: resolve entries from the local mirror (never a fabricated book number) -------
local parse_library_list    = _TRIVIA_TEST.parse_library_list
local library_title         = _TRIVIA_TEST.library_title
local library_keyword       = _TRIVIA_TEST.library_keyword
local question_book_number  = _TRIVIA_TEST.question_book_number
local library_pick_entry    = _TRIVIA_TEST.library_pick_entry

test("parse_library_list reads numbered catalog entries and ignores non-catalog lines (incl. '#' comments)", function()
  local out = table.concat({
    "# AlterAeon book catalog — 474 entries",           -- the local books_catalog.txt header (must be skipped)
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

-- ==================================================================================================
-- ASYNC LOOKUP FLOW — behaviour-level characterization (the SEND SEQUENCE, narration, and outcome)
-- ==================================================================================================
-- CHARACTERIZATION suite for the async answer flow (run_lookup / resolve_library / feed_lookup / the
-- area query). These assert OBSERVABLE BEHAVIOUR — the exact `send` sequence the flow emits (`library
-- list <kw>`, `library read <n>`, `area <kw>`, the `event answer <letter>` lock-in), the `[trivia]`
-- narration, and the outcome (which letter is locked, labeled `library`/`area`/`guess`) — NOT the
-- internal async-machine state (capture.active, T.area_rows, the callback nesting). The point: the
-- reactive reimplementation (a promise chain over reply streams) must turn these green because it
-- reproduces the same sends/echoes/outcomes. The library-hallucination fix is pinned here: a model's
-- FABRICATED book number is NEVER `library read`, and an unresolved lookup degrades to a NARRATED guess
-- (never a fabricated `library`-sourced answer).
--
-- The scenario is driven through the SAME seams the live triggers drive (on_question / on_choices kick
-- the flow; collect_line / on_area_line feed reply lines). `send`/`echo` are captured, `after` is made
-- fireable (a lookup's collection window is fired on demand), and ai_local_tools_request is stubbed with
-- a queue of canned model turns. Every ASSERTION is on captured send/echo; reading nothing internal.

local TT = _TRIVIA_TEST
local LIBRARY_TOOL = '[{"name":"library_entry","arguments":"{\\"entry_number\\":%d}"}]'
local function has_send(sent, needle)
  for _, c in ipairs(sent) do if c:find(needle, 1, true) then return true end end
  return false
end

-- Drive one trivia question end-to-end. `model` is a FIFO of canned ai_local_tools_request turns, each
-- { tool = <tool_calls_json> } | { answer = "<letter>" } | { err = "<msg>" }. `drive(api)` feeds reply
-- lines (api.line / api.area) and fires each lookup's window (api.fire, FIFO — lookups are sequential).
local function flow(question, choices, model, drive)
  local s_send, s_echo, s_after, s_cancel = send, echo, after, cancel
  local s_tools, s_retr, s_rc = ai_local_tools_request, ai_retrieve, ai_rag_count
  local sent, echoed, timers = {}, {}, {}
  local mq, mi = model or {}, 0
  send   = function(c) sent[#sent + 1] = c end
  echo   = function(x) echoed[#echoed + 1] = (tostring(x):gsub("\27%[[%d;]*m", "")) end
  -- Record timers with their delay: the promise layer schedules zero-delay auto-starts (and unhandled-
  -- rejection surfacing) alongside the lookup COLLECTION windows (delay > 0). api.fire() advances to the
  -- next real window, leaving the zero-delay housekeeping timers inert (the promise already ran synchronously).
  after  = function(d, cb) timers[#timers + 1] = { delay = d, cb = cb }; return #timers end
  cancel = function() end
  ai_retrieve   = nil                       -- skip RAG grounding → decide("") straight away
  ai_rag_count  = function() return 0 end
  ai_local_tools_request = function(_sys, _user, _mt, _pf, _tools, cb)
    mi = mi + 1
    local r = mq[mi] or { answer = "a" }
    if r.err then cb(nil, nil, r.err)
    elseif r.tool then cb("", r.tool, nil)
    else cb(r.answer or "a", nil, nil) end
  end
  local fired = 0
  local api = {
    sent = sent, echoed = echoed,
    line = function(t) TT.collect_line(t) end,       -- a lookup reply line (library list/read output)
    area = function(t) TT.on_area_line(t) end,        -- an `area` command row
    fire = function()                                 -- close the next lookup window (skip zero-delay timers)
      while fired < #timers do
        fired = fired + 1
        local t = timers[fired]
        if t and (t.delay or 0) > 0 then t.cb(); return end
      end
    end,
  }
  local ok, err = pcall(function()
    TT.on_question(question)
    TT.on_choices(choices)
    if drive then drive(api) end
  end)
  send, echo, after, cancel = s_send, s_echo, s_after, s_cancel
  ai_local_tools_request, ai_retrieve, ai_rag_count = s_tools, s_retr, s_rc
  if not ok then error(err, 2) end
  return sent, echoed
end

-- The library flow now reads the LOCAL book mirror (no in-game commands), so these inject the catalog +
-- book text through the TT.Lib seam and assert: NO `library …` send ever goes out, the right entry is
-- resolved (title match ignores the model's fabricated number), and it always answers.
test("library flow: match the local catalog by title → read that entry → answer (no in-game command)", function()
  local q  = 'What is the topic of a book entitled "A Magic Primer: Constructs" in the Great Library?'
  local ch = 'A: philosophy.  B: history.  C: geography.  D: runes.'
  -- The model calls library_entry with a MADE-UP number (99999); the title match must win, not that number.
  TT.Lib.catalog = function() return parse_library_list("48043 - a magic primer: constructs     Topic: philosophy") end
  TT.Lib.read = function(n) return n == 48043 and "48043 - a magic primer: constructs     Topic: philosophy" or nil end
  local sent, echoed = flow(q, ch, { { tool = string.format(LIBRARY_TOOL, 99999) }, { answer = "A" } })
  expect(has_send(sent, "library")):eq(false)                          -- NO in-game library command at all
  expect(has_send(sent, "event answer a")):eq(true)                    -- locked in choice A
  expect(table.concat(echoed, "\n")):contains("found it locally: entry 48043")
end)

test("library flow: no local catalog match → NARRATED guess, never a fake 'library' answer", function()
  local q  = 'What is the topic of a book entitled "A Nonexistent Tome" in the Great Library?'
  local ch = 'A: one.  B: two.  C: three.  D: four.'
  TT.Lib.catalog = function() return parse_library_list("48043 - some unrelated book     Topic: philosophy") end
  TT.Lib.read = function() return nil end
  local sent, echoed = flow(q, ch, { { tool = string.format(LIBRARY_TOOL, 12345) }, { answer = "B" } })
  expect(has_send(sent, "library")):eq(false)                          -- no book was EVER read via the game
  expect(has_send(sent, "event answer")):eq(true)                      -- still answers (it always answers)…
  local text = table.concat(echoed, "\n")
  expect(text):contains("no matching entry")                           -- narrated the give-up…
  expect(text):contains("guessing")                                    -- …and that it's now a guess
  expect(text:find("— library", 1, true)):eq(nil)                      -- NOT labeled as a library answer
end)

test("library flow: a question-stated number reads that entry directly from the mirror (no title search)", function()
  local q  = 'What is entry 16105 in the Great Library?'
  local ch = 'A: a letter.  B: a map.  C: a rune.  D: a key.'
  TT.Lib.read = function(n) return n == 16105 and "16105 - a lightly scorched letter" or nil end
  TT.Lib.catalog = function() error("must not search the catalog when the question states a valid number") end
  local sent, echoed = flow(q, ch, { { tool = string.format(LIBRARY_TOOL, 16105) }, { answer = "A" } })
  expect(has_send(sent, "library")):eq(false)
  expect(has_send(sent, "event answer a")):eq(true)
  expect(table.concat(echoed, "\n")):contains("reading local entry 16105")
end)

test("library flow: a question number NOT in the local mirror falls back to a title match", function()
  local q  = 'What is entry 55555 in the book entitled "The Book of the Sea"?'
  local ch = 'A: geography.  B: history.  C: cooking.  D: war.'
  TT.Lib.read = function(n) return n == 2110 and "2110 - the book of the sea     Topic: geography" or nil end   -- we lack 55555
  TT.Lib.catalog = function() return parse_library_list("2110 - the book of the sea     Topic: geography") end
  local sent, echoed = flow(q, ch, { { tool = string.format(LIBRARY_TOOL, 55555) }, { answer = "A" } })
  expect(has_send(sent, "library")):eq(false)
  expect(has_send(sent, "event answer a")):eq(true)
  local text = table.concat(echoed, "\n")
  expect(text):contains("entry 55555 not in the local library")       -- narrated the local miss…
  expect(text):contains("found it locally: entry 2110")               -- …then resolved by title
end)

test("area flow: `area <kw>` rows are collected and mapped to the choice — no model call", function()
  local q  = 'What level is the area Darring Road?'
  local ch = 'A: level 11.  B: level 12.  C: level 9.  D: level 8.'
  local sent, echoed = flow(q, ch, {}, function(api)
    expect(has_send(api.sent, "area Darring")):eq(true)                -- asks the game directly
    api.area("Lvl  11    Darring Road                          someone")
    api.fire()                                                         -- area window → map level 11 → 'A'
  end)
  expect(has_send(sent, "event answer a")):eq(true)
  expect(table.concat(echoed, "\n")):contains("— area")               -- labeled as an area answer
end)

test("area flow: an unmatched area falls back to the model", function()
  local q  = 'What level is the area Nowhere Land?'
  local ch = 'A: level 3.  B: level 4.  C: level 5.  D: level 6.'
  local sent = flow(q, ch, { { answer = "C" } }, function(api)
    expect(has_send(api.sent, "area Nowhere")):eq(true)
    api.fire()                                                         -- window closes with no matching row → model
  end)
  expect(has_send(sent, "event answer c")):eq(true)                    -- the model's letter
end)
