-- Specs for ChatDecode.lua — the chat annotator's PURE decoder.
--
-- The trigger regexes live in the Swift engine and aren't unit-testable; these drive the same helpers
-- the trigger handlers call (decode_message / format_notes via _CD_TEST) plus the decode.* controls.

local CD = _CD_TEST
local function terms(notes) local t = {}; for i, n in ipairs(notes) do t[i] = n.term .. ":" .. n.exp end; return t end
local function find(notes, term)
  for _, n in ipairs(notes) do if n.term == term then return n end end
  return nil
end

-- ---- acronyms / jargon -------------------------------------------------------------------------
test("expands general net-speak", function()
  local n = CD.decode("brb gtg ttyl")
  expect(#n):eq(3)
  expect(find(n, "brb").exp):eq("be right back")
  expect(find(n, "gtg").exp):eq("got to go")
  expect(find(n, "ttyl").exp):eq("talk to you later")
end)

test("expands MUD jargon", function()
  local n = CD.decode("oom, need to regen mana")
  expect(find(n, "oom").exp):eq("out of mana")
  expect(find(n, "regen").exp):eq("regenerate")
end)

test("is case-insensitive and strips surrounding punctuation", function()
  local n = CD.decode("BRB! (oom)")
  expect(find(n, "BRB").exp):eq("be right back")   -- term preserves the user's original casing
  expect(find(n, "oom").exp):eq("out of mana")
end)

test("de-dupes a repeated term within a line", function()
  local n = CD.decode("lol lol lol that was lol")
  expect(#n):eq(1)
  expect(n[1].term):eq("lol")
end)

test("a message with nothing to explain yields no notes", function()
  expect(#CD.decode("heading to the market now")):eq(0)
  expect(CD.format(CD.decode("heading to the market now"))):eq(nil)
end)

-- ---- emoticons ---------------------------------------------------------------------------------
test("explains emoticons on the raw token (punctuation intact)", function()
  local n = CD.decode("nice :) <3 gg")
  expect(find(n, ":)").exp):eq("smiling")
  expect(find(n, "<3").exp):eq("love")
  expect(find(n, "gg").exp):eq("good game")
end)

-- ---- formatting --------------------------------------------------------------------------------
test("format joins notes with the separator and prefix, '=' for terms", function()
  local line = CD.format(CD.decode("brb oom"))
  expect(line:find("be right back", 1, true) ~= nil):eq(true)
  expect(line:find(" = ", 1, true) ~= nil):eq(true)
  expect(line:find(CD.cfg.prefix, 1, true)):eq(1)   -- starts with the dim prefix
end)

test("caps notes at cfg.max_notes", function()
  local old = CD.cfg.max_notes
  CD.cfg.max_notes = 2
  local n = CD.decode("brb gtg ttyl omw")
  expect(#n):eq(2)
  CD.cfg.max_notes = old
end)

-- ---- typo pass (opt-in, driven by a stubbed spellcheck) ----------------------------------------
test("typo pass is OFF by default: unknown words are left alone", function()
  local prev = CD.S.typos
  CD.S.typos = false
  expect(#CD.decode("teh wrold is mine")):eq(0)
  CD.S.typos = prev
end)

test("typo pass ON: spellcheck suggestions become '→' corrections, game vocab skipped", function()
  local prev_typos, prev_spell = CD.S.typos, spellcheck
  CD.S.typos = true
  spellcheck = function(w)                       -- luacheck: ignore
    local fixes = { teh = "the", wrold = "world" }
    return fixes[w:lower()]
  end
  -- "recall" is game vocab (skipped); "teh"/"wrold" correct; "the" (already right) returns nil.
  local n = CD.decode("teh wrold recall the")
  expect(#n):eq(2)
  expect(find(n, "teh").exp):eq("the")
  expect(find(n, "teh").kind):eq("typo")
  expect(find(n, "wrold").exp):eq("world")
  expect(find(n, "recall")):eq(nil)
  local line = CD.format(n)
  expect(line:find(" \u{2192} ", 1, true) ~= nil):eq(true)   -- uses the arrow, not '='
  CD.S.typos, spellcheck = prev_typos, prev_spell   -- luacheck: ignore
end)

test("typo pass ignores short words and non-alphabetic tokens", function()
  local prev_typos, prev_spell = CD.S.typos, spellcheck
  CD.S.typos = true
  spellcheck = function() return "SHOULD_NOT_BE_USED" end   -- luacheck: ignore
  local n = CD.decode("hi 4ever w00t")   -- "hi" too short; "4ever"/"w00t" non-alphabetic
  expect(#n):eq(0)
  CD.S.typos, spellcheck = prev_typos, prev_spell   -- luacheck: ignore
end)

-- ---- runtime additions & gate ------------------------------------------------------------------
test("decode.add teaches a new term used by the decoder", function()
  CD.S.extra["bof"] = nil
  decode.add("bof", "back of fight")
  local n = CD.decode("go bof now")
  expect(find(n, "bof").exp):eq("back of fight")
  CD.S.extra["bof"] = nil
end)

test("annotate no-ops when disabled", function()
  local prev = CD.S.enabled
  CD.S.enabled = false
  local echoed = false
  local real_echo = echo
  echo = function() echoed = true end            -- luacheck: ignore
  CD.annotate("brb oom", false)
  expect(echoed):eq(false)
  echo = real_echo                               -- luacheck: ignore
  CD.S.enabled = prev
end)

test("annotate respects cfg.self for own outgoing lines", function()
  local prev_en, prev_self = CD.S.enabled, CD.cfg.self
  CD.S.enabled, CD.cfg.self = true, false
  local echoed = false
  local real_echo = echo
  echo = function() echoed = true end            -- luacheck: ignore
  CD.annotate("brb oom", true)                   -- is_self=true, self annotation off
  expect(echoed):eq(false)
  echo = real_echo                               -- luacheck: ignore
  CD.S.enabled, CD.cfg.self = prev_en, prev_self
end)
