-- ChatDecode.lua — annotate player chat with plain-English decodings.
--
-- A lot of what players type is an acronym ("brb"), a bit of net-speak ("iirc"), MUD jargon ("oom"),
-- an emoticon (":P"), or a typo ("teh"). This watches the SOCIAL channels — gossip, chat, newbie,
-- auction, tells, and your own outgoing on those — and, when a line contains anything worth
-- explaining, echoes a dim annotation line right below it:
--
--     Copper gossips, 'brb oom, gg tho ill be back rn'
--       ↳ brb = be right back · oom = out of mana · gg = good game · tho = though · rn = right now
--
-- It is deliberately NOT an LLM: every decoding is an O(1) table hit, and the optional typo pass is a
-- single native `spellcheck()` call (macOS NSSpellChecker, local dictionary) per unknown word — so a
-- whole chat line resolves in well under a millisecond. Nothing here ever blocks or hits the network.
--
-- Scope guards:
--   * Triggers are ANCHORED (^…$) to the exact channel wire formats, so another player can't make the
--     annotator fire by quoting a channel string inside their own say/tell.
--   * Room `says`/`yells` are intentionally NOT watched — those are mostly clean NPC dialogue, not
--     typo-prone player chatter.
--   * The typo pass (decode.typos) is OFF by default: acronym/jargon expansion has zero false
--     positives, whereas spell-correction needs the game-vocab allowlist dialed in first.
--
-- Controls:  decode.on()/off() · decode.typos("on"|"off") · decode.add("word","meaning") ·
--            decode.explain("brb ...")  (dry-run: prints what a line would annotate); help(decode).
-- Hot-reloadable: edit + pilot.reload().

local cfg = {
  enabled   = true,           -- annotate by default (passive, one dim line, easy to ignore)
  typos     = false,          -- typo correction via spellcheck() — OFF for v1 (acronyms first)
  self      = true,           -- also annotate YOUR OWN outgoing channel lines
  color     = "bright black", -- dim annotation color (a color spec echo() understands)
  prefix    = "  \u{21b3} ",  -- "  ↳ "
  sep       = " \u{00b7} ",   -- " · " between notes
  arrow_typo = " \u{2192} ",  -- " → " for a correction
  eq        = " = ",          -- " = " for an expansion
  max_notes = 8,              -- cap notes per line (a wall of jargon shouldn't spam a huge line)
  min_word  = 3,              -- only spell-check words at least this long
}

-- Survive pilot.reload(): runtime toggles + any user-added terms live in a global.
_CHATDECODE = _CHATDECODE or { enabled = cfg.enabled, typos = cfg.typos, extra = {} }
local S = _CHATDECODE

-- ============================ dictionaries ============================
-- Acronyms / net-speak / MUD jargon → expansion. Keys are lowercase; lookups are case-insensitive.
-- Expansions are short and literal. Where a term is genuinely ambiguous the MUD-chat reading is used.
local ACRONYMS = {
  -- general net-speak
  brb = "be right back", bbl = "be back later", bbiab = "be back in a bit", afk = "away from keyboard",
  gtg = "got to go", g2g = "got to go", ttyl = "talk to you later", omw = "on my way", omg = "oh my god",
  imo = "in my opinion", imho = "in my humble opinion", tbh = "to be honest", ngl = "not gonna lie",
  iirc = "if I recall correctly", afaik = "as far as I know", idk = "I don't know", idc = "I don't care",
  irl = "in real life", fyi = "for your information", btw = "by the way", ftw = "for the win",
  ty = "thank you", tyvm = "thank you very much", thx = "thanks", thnx = "thanks", np = "no problem",
  nvm = "never mind", wb = "welcome back", gg = "good game", wp = "well played", gj = "good job",
  gl = "good luck", hf = "have fun", glhf = "good luck have fun", ez = "easy", ikr = "I know right",
  lol = "laughing out loud", lmao = "laughing hard", rofl = "rolling on the floor laughing",
  smh = "shaking my head", tmi = "too much information", ftfy = "fixed that for you",
  tldr = "too long, didn't read", jk = "just kidding", rn = "right now", ppl = "people",
  pls = "please", plz = "please", u = "you", ur = "your", cya = "see you", cu = "see you",
  wtf = "what the heck", wth = "what the heck", tho = "though", dunno = "don't know", gimme = "give me",
  -- MUD / AlterAeon jargon
  oom = "out of mana", eq = "equipment", exp = "experience", xp = "experience", hp = "hit points",
  mp = "mana points", sp = "spell points", mob = "monster", mobs = "monsters",
  aggro = "aggressive (draws attention)", tank = "damage absorber", dps = "damage per second",
  aoe = "area of effect", buff = "beneficial spell", debuff = "harmful effect", proc = "triggered effect",
  cd = "cooldown", tnl = "to next level", lfg = "looking for group", lf = "looking for",
  wtb = "want to buy", wts = "want to sell", wtt = "want to trade", ooc = "out of character",
  brt = "be right there", sec = "one second", pst = "please send tell", res = "resurrect",
  rez = "resurrect", regen = "regenerate", sac = "sacrifice", invis = "invisible",
  grats = "congratulations", gratz = "congratulations", congrats = "congratulations",
  woot = "woohoo", wewt = "woohoo", pwned = "defeated", ded = "dead",
}

-- Emoticons → meaning. Matched against the RAW token (punctuation intact), before any stripping.
local EMOTICONS = {
  [":)"] = "smiling", [":-)"] = "smiling", [":D"] = "grinning", [":-D"] = "grinning",
  [":("] = "frowning", [":-("] = "frowning", [";)"] = "winking", [";-)"] = "winking",
  [":P"] = "playful", [":-P"] = "playful", [":p"] = "playful", ["xD"] = "laughing", ["XD"] = "laughing",
  [":o"] = "surprised", [":O"] = "surprised", [":'("] = "crying", ["</3"] = "heartbroken",
  ["<3"] = "love", [":/"] = "unsure", [":\\"] = "unsure", ["^^"] = "happy", ["o/"] = "waving",
}

-- Game vocabulary the English spell-checker would wrongly flag. Only consulted by the (opt-in) typo
-- pass. Seeded with common AlterAeon terms; extend at runtime with decode.add(word) or edit here.
local GAME_VOCAB = {}
for _, w in ipairs({
  "alteraeon", "vnum", "eq", "spellcomp", "waypoint", "recall", "mana", "mob", "mobs", "ooc", "quaff",
  "tarrants", "soulsteal", "frostflower", "kai", "necro", "necromancer", "vise", "naginata",
  "gossip", "newbie", "auction", "dex", "str", "int", "wis", "con", "cha", "hp", "mp", "sp", "xp",
}) do GAME_VOCAB[w] = true end

-- ============================ decoding (pure — unit-tested) ============================
local function lc(s) return (tostring(s or ""):lower()) end

-- Look a token up. Tries the emoticon map on the RAW token first (keeps its punctuation), then the
-- acronym/jargon map + any user additions on the punctuation-stripped core. Returns exp, term, kind.
local function lookup(tok)
  local emo = EMOTICONS[tok]
  if emo then return emo, tok, "emote" end
  local core = tok:gsub("^[%p]+", ""):gsub("[%p]+$", "")   -- strip surrounding punctuation only
  local key = lc(core)
  if key == "" then return nil end
  local exp = S.extra[key] or ACRONYMS[key]
  if exp then return exp, core, "term" end
  return nil, core, nil
end

-- Decode a chat message into an ordered, de-duplicated list of notes: { term=, exp=, kind= }.
-- kind is "emote" | "term" | "typo". The typo branch only runs when decode.typos is on, the word is
-- alphabetic, long enough, not game vocab, and spellcheck() offers a different word.
local function decode_message(msg)
  msg = tostring(msg or "")
  local notes, seen = {}, {}
  for tok in msg:gmatch("%S+") do
    if #notes >= cfg.max_notes then break end
    local exp, term, kind = lookup(tok)
    local dedupe = lc(term ~= "" and term or tok)
    if exp and not seen[dedupe] then
      seen[dedupe] = true
      notes[#notes + 1] = { term = term ~= "" and term or tok, exp = exp, kind = kind }
    elseif not exp and S.typos and term and #term >= cfg.min_word and not seen[dedupe]
        and term:match("^%a+$") and not GAME_VOCAB[lc(term)] then
      if spellcheck then
        local sug = spellcheck(term)
        if type(sug) == "string" and sug ~= "" and lc(sug) ~= lc(term) then
          seen[dedupe] = true
          notes[#notes + 1] = { term = term, exp = sug, kind = "typo" }
        end
      end
    end
  end
  return notes
end

-- Render notes into the single dim annotation line (nil if there's nothing to say).
local function format_notes(notes)
  if not notes or #notes == 0 then return nil end
  local parts = {}
  for _, n in ipairs(notes) do
    local joiner = (n.kind == "typo") and cfg.arrow_typo or cfg.eq
    parts[#parts + 1] = n.term .. joiner .. n.exp
  end
  return cfg.prefix .. table.concat(parts, cfg.sep)
end

-- ============================ live path ============================
-- The gate every matched chat line passes through. is_self is true for our own outgoing lines.
local function annotate(msg, is_self)
  if not S.enabled then return end
  if is_self and not cfg.self then return end
  local line = format_notes(decode_message(msg))
  if line and echo then echo(line, cfg.color) end
end

-- ============================ triggers ============================
-- One anchored trigger for incoming social channels (gossip/chat/auction/newbie + tells), and one for
-- our own outgoing on those channels. Anchored ^…$ so a quoted channel string inside someone's message
-- can't spoof it; the message body is capture group 1.  Regexes run in the Swift engine (not unit-
-- testable); decode_message/format_notes (the pure helpers) are what the spec drives.
trigger([[^\S+ (?:gossips|chats|auctions|newbies|tells you|tells the group), '(.+)'$]],
  function(_, msg) annotate(msg, false) end)

trigger([[^You (?:gossip|chat|auction|newbie) '?(.+?)'?$|^You tell \S+, '(.+)'$]],
  function(_, a, b) annotate(a or b, true) end)

-- ============================ public control surface ============================
decode = {}

function decode.on()  S.enabled = true;  echo("[decode] ON — annotating chat") end
function decode.off() S.enabled = false; echo("[decode] OFF") end

-- Turn the typo pass on/off (or report it). Off by default; needs spellcheck() + the game-vocab list.
function decode.typos(v)
  if v == nil then return echo("[decode] typos " .. (S.typos and "ON" or "OFF")) end
  v = lc(v)
  S.typos = (v == "on" or v == "true" or v == "1" or v == "yes")
  echo("[decode] typos " .. (S.typos and "ON" or "OFF"))
end

-- Teach it a new term (or override one): decode.add("bof", "back of fight"). Persists across reloads
-- (kept in the global). A game word can also be added here as its own expansion to explain it.
function decode.add(word, meaning)
  if type(word) ~= "string" or word == "" or type(meaning) ~= "string" or meaning == "" then
    return echo("[decode] usage: decode.add(\"word\", \"meaning\")", "yellow")
  end
  S.extra[lc(word)] = meaning
  echo(string.format("[decode] added %s = %s", lc(word), meaning))
end

-- Dry-run: show what a given message WOULD annotate to, without needing a live line. Handy for tuning.
function decode.explain(msg)
  local line = format_notes(decode_message(msg or ""))
  echo(line or "[decode] (nothing to explain)", line and cfg.color or nil)
end

-- ============================ docs ============================
doc("decode", { sig = "decode.on() · decode.off() · decode.typos(on|off) · decode.add(w, m) · decode.explain(s)",
  group = "chat",
  text = "Chat decoder: watches the social channels (gossip/chat/newbie/auction/tells + your own) and echoes a dim line beneath any message that contains an acronym, net-speak, MUD jargon, or emoticon — expanded to plain English. Anchored triggers, so other players can't spoof it. The optional typo pass (decode.typos) adds native spell-correction for unknown words (off by default). All O(1) table hits + one local spellcheck call — no LLM, never blocks.",
  example = 'decode.explain("brb oom gg :P")' })
doc("decode.on",      { sig = "decode.on()",  group = "chat", text = "Enable chat annotation." })
doc("decode.off",     { sig = "decode.off()", group = "chat", text = "Disable chat annotation (triggers stay registered; the gate just no-ops)." })
doc("decode.typos",   { sig = "decode.typos([on|off])", group = "chat",
  text = "Turn the spell-correction pass on/off, or report it with no argument. Off by default: it spell-checks unknown, alphabetic, non-game words via spellcheck() and annotates a suggested correction." })
doc("decode.add",     { sig = "decode.add(word, meaning)", group = "chat",
  text = "Teach the decoder a term (or override a built-in one). Lowercased; persists across pilot.reload(). Use it for guild slang or to explain a game word." })
doc("decode.explain", { sig = "decode.explain(message)", group = "chat",
  text = "Dry-run: print the annotation a message would produce, without a live chat line. For tuning the dictionaries." })

-- Test seam: expose the pure helpers + tables so the spec drives the real decoder.
_CD_TEST = {
  decode = decode_message, format = format_notes, annotate = annotate,
  cfg = cfg, S = S, ACRONYMS = ACRONYMS, EMOTICONS = EMOTICONS, GAME_VOCAB = GAME_VOCAB,
}
