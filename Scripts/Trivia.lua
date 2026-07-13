-- Trivia auto-answerer.
--
-- AlterAeon periodically runs a TRIVIA GAME on the `[event]` channel: a game-knowledge question, four
-- lettered choices, then a reveal a minute later. You answer with `event answer <letter>`. This script
-- watches that channel and answers automatically, two ways:
--
--   1. MEMORY (free, instant): every reveal teaches us the correct ANSWER TEXT for that question, cached
--      to disk. When the same question comes back we just pick the choice whose text matches — no model
--      call, and it's robust to AlterAeon shuffling the A/B/C/D order between askings.
--   2. MODEL + RAG (fallback): for an unseen question we retrieve the most relevant help passages via the
--      shared RAG index and ask the active decision brain (ai_request) for a single letter.
--
-- It answers with the LOCAL model (ai_local_request — a dedicated client pinned to LM Studio /
-- localhost:1234), NOT the pilot's decision brain. So it works and stays free even when pilot.brain(…) is a
-- hosted API that's down or unconfigured (which otherwise just errors, making us guess every time). It
-- grounds with the shared RAG index (ai_retrieve) but never touches or reconfigures the pilot's clients.
-- (If the local builtin is missing on an un-relaunched binary, it falls back to the shared brain.)
--
-- INDEPENDENT of the AI pilot: this answers whether or not the pilot is armed — it has its own trivia.on()
-- toggle and only the memory/RAG/model plumbing is shared. And it ALWAYS answers: on a memory miss with
-- no usable model reply (model errored, unparseable, or no brain configured) it GUESSES a random choice
-- rather than sitting out — a 1-in-4 shot plus a chance to learn the real answer from the reveal.
--
-- Controls: trivia.status() · trivia.on() / trivia.off() · trivia.stats() · trivia.forget() (clear learned cache); help(trivia).
-- Hot-reloadable: edit + pilot.reload().
--
-- ARCHITECTURE (promise + reactive, mirrors Corpse/AutoFight): the async LOOKUP flow — searching the
-- Great Library (list → pick → read), the `area` query, and the model tool round-trip — is a PROMISE
-- CHAIN over game-reply STREAMS, not a nest of send/after callbacks. Every game line fans into a hot
-- Subject (lineS / areaRowS); run_lookup() awaits a command's windowed output as a promise; the
-- discovery→pick→read sequence is `.andThen` with the VALIDATED entry NUMBER flowing as the resolve
-- value; the game's invalid-book rejection is a `:catch` that retries by title and then GRACEFULLY
-- DEGRADES to a narrated, labeled guess (never a fabricated `library`-sourced answer). The pure
-- parse/pick/classify helpers stay plain functions the flow calls.

-- Reactive core (__rx): the lookup flow reacts to game-reply STREAMS (see lineS/areaRowS below); the
-- promise layer (__promise, loaded by the directory loader before this file — P < T alphabetically)
-- chains the steps. `_`-prefixed files aren't auto-loaded, so pull _rx the documented way (dofile
-- fallback for the bare Lua test harness).
pcall(require, "_rx")
if not __rx then dofile("Scripts/_rx.lua") end
pcall(require, "_persist")
if not __persist then dofile("Scripts/_persist.lua") end
local persist = __persist

local cfg = {
  enabled = true,          -- auto-answer by default (that's the whole point); `#trivia off` to disable
  rag_k = 4,               -- help passages retrieved to ground an unseen question
  area_wait = 1.2,         -- seconds to let the `area` command's rows arrive before deciding
  lookup_wait = 1.5,       -- seconds to capture a tool lookup's in-game command output before answering
  max_tokens = 12,         -- we only want a letter back (the direct/answer turns)
  tool_max_tokens = 128,   -- the tools turn needs room to emit a tool call (name + arguments)
  home = os.getenv("HOME") or "",
  -- Same trailing prefill the pilot uses: a CLOSED, empty <think> block suppresses Qwen3.x's habit of
  -- spending the whole budget "thinking" and returning nothing. Harmless to hosted Claude.
  think_prefill = "<think>\n\n</think>\n\n",
  -- Pin the local model EXPLICITLY. The local client otherwise auto-discovers by taking the first id
  -- from LM Studio's /v1/models — which is the RAG EMBEDDING model (text-embedding-nomic-…). Sending a
  -- chat completion there 400s ("Invalid model identifier"), so trivia would guess every time. Hardcode
  -- a real chat model; override with TRIVIA_MODEL (or LMSTUDIO_MODEL) if yours is named differently.
  model = os.getenv("TRIVIA_MODEL") or os.getenv("LMSTUDIO_MODEL") or "qwen3.6-35b-a3b-mlx",
}
cfg.dir = cfg.home .. "/Documents/MudClient"
cfg.cache_file = cfg.dir .. "/trivia_answers.lua"

-- Survive pilot.reload(): keep the toggle, stats, and in-flight question in a global, and bump an epoch so
-- a model reply that lands after a reload can't fire a stale `event answer`.
_TRIVIA = _TRIVIA or { enabled = cfg.enabled, stats = { attempts = 0, correct = 0, learned = 0 } }
_TRIVIA.epoch = (_TRIVIA.epoch or 0) + 1
local EPOCH = _TRIVIA.epoch
local S = _TRIVIA

-- The current, unanswered question in flight (reset each new question).
local T = { q = nil, choices = nil, answered = false, our_letter = nil, source = nil }

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
-- Canonical form used both as the cache KEY (for questions) and to compare choice TEXT to a cached
-- answer: lowercased, whitespace collapsed, trailing period dropped.
local function norm(s) return (trim(s or ""):lower():gsub("%s+", " "):gsub("%.%s*$", "")) end

-- ---- learned-answer cache (persisted) ------------------------------------------------------------
local cache = {}   -- norm(question) -> norm(correct answer text)

local function load_cache()
  local t = persist.load(cfg.cache_file)
  if type(t) == "table" then cache = t end
  local n = 0; for _ in pairs(cache) do n = n + 1 end
  S.stats.learned = n
end

local function save_cache()
  persist.save(cfg.cache_file, cache)
end

-- ---- parsing -------------------------------------------------------------------------------------
-- "A: 3.   B: 2.   C: 18.   D: 8."  ->  { a = "3", b = "2", c = "18", d = "8" }
-- Locate each "<Letter>:" marker, then slice the body between consecutive markers. (A gmatch with a
-- lookahead-style terminator would consume the next marker and drop every other choice.)
local function parse_choices(s)
  s = trim(s)
  local marks = {}
  for _, L in ipairs({ "A", "B", "C", "D" }) do
    local i = s:find(L .. ":", 1, true)
    if i then marks[#marks + 1] = { L = L:lower(), i = i } end
  end
  table.sort(marks, function(a, b) return a.i < b.i end)   -- position order = shuffle-tolerant
  local out = {}
  for idx, m in ipairs(marks) do
    local body_start = m.i + 2                              -- past "X:"
    local body_end = marks[idx + 1] and (marks[idx + 1].i - 1) or #s
    out[m.L] = norm(s:sub(body_start, body_end))
  end
  return out
end

-- Pull the intended choice letter out of a model reply. Prefer an isolated single letter, else the
-- first A-D that appears anywhere. Returns lowercase "a".."d" or nil.
local function extract_letter(reply)
  reply = reply or ""
  -- 1) An isolated single letter: "C", "b", "the answer is C.", "D)" — bounded by non-letters.
  for ch in reply:gmatch("%f[%a](%a)%f[%A]") do
    local u = ch:upper()
    if u:find("^[ABCD]$") then return u:lower() end
  end
  -- 2) A labeled form "C)", "C.", "C:" — a choice letter followed by a delimiter. Deliberately NOT a
  --    bare A-D anywhere, which would wrongly fire on letters buried in words ("iDea" -> D).
  local u = reply:upper():match("([ABCD])[%)%.:]")
  return u and u:lower() or nil
end

-- Given the parsed choices and a cached correct answer text, return the matching letter (order-agnostic).
local function letter_for_text(choices, answer_text)
  if not choices or not answer_text then return nil end
  for L, body in pairs(choices) do if body == answer_text then return L end end
  return nil
end

-- ---- area-level questions via the in-game `area` command -----------------------------------------
-- "What level is the area <NAME>?" is authoritatively answerable by asking the game: `area <keyword>`
-- lists matching areas as rows like "Lvl  34    Ruined Temple    <creators>" (normal) or
-- "Grp 195 10 The nightmare plane...    <creators>" (group). Normal areas answer "level N"; group areas
-- answer "N total levels" (the group figure). This is a live lookup the scraped RAG corpus can't provide.

-- Canonicalize an area name for matching: lowercased, leading "the " dropped, spaces collapsed, trailing
-- punctuation stripped. So the question's "The Ryuu Graveyard" matches the row's "The Ryuu Graveyard".
local function norm_area(s)
  return (trim(s or ""):lower():gsub("^the%s+", ""):gsub("%s+", " "):gsub("[%.,;:!?]+$", ""))
end

-- Pick the most distinctive word to hand `area` as its search keyword (longest non-stopword). The full
-- name is matched against results afterward, so a keyword that over-matches is harmless.
local AREA_STOP = { the = true, of = true, ["and"] = true, a = true, an = true, in_ = true }
local function pick_keyword(name)
  local best = ""
  for w in (name or ""):gmatch("%a+") do
    if not AREA_STOP[w:lower()] and #w > #best then best = w end
  end
  return best ~= "" and best or trim(name or "")
end

-- Parse one `area` output row into { kind="Lvl"|"Grp", n1, n2, desc }. Returns nil for non-rows
-- (headers, dashes, sector titles). Description ends at the first run of 2+ spaces before the creators.
local function parse_area_row(line)
  line = (line or ""):gsub("\27%[[%d;]*%a", "")
  local rest = line:match("^%s*Lvl%s+(%d.*)$")
  if rest then
    local n1, tail = rest:match("^(%d+)%s+(.*)$")
    if not n1 then return nil end
    return { kind = "Lvl", n1 = tonumber(n1), desc = norm_area((tail:match("^(.-)%s%s+") or tail)) }
  end
  rest = line:match("^%s*Grp%s+(%d.*)$")
  if rest then
    local n1, n2, tail = rest:match("^(%d+)%s+(%d+)%s+(.*)$")
    if not n1 then return nil end
    return { kind = "Grp", n1 = tonumber(n1), n2 = tonumber(n2), desc = norm_area((tail:match("^(.-)%s%s+") or tail)) }
  end
  return nil
end

-- Match an area's level (num, and whether it's a group area) to the choice letter. Prefers an exact
-- number+phrasing match ("N total levels" for group, "level N" otherwise); falls back to number alone.
local function choice_for_level(choices, num, is_group)
  local fallback
  for _, L in ipairs({ "a", "b", "c", "d" }) do
    local body = choices[L]
    if body then
      local cnum = tonumber(body:match("(%d+)"))
      local total = body:find("total level") ~= nil
      if cnum == num then
        if (is_group and total) or (not is_group and not total) then return L end
        fallback = fallback or L
      end
    end
  end
  return fallback
end

-- ---- answering -----------------------------------------------------------------------------------
local CHOICE_LETTERS = { "a", "b", "c", "d" }
math.randomseed(os.time())

local function submit(letter, source)
  T.answered, T.our_letter, T.source = true, letter, source
  send("event answer " .. letter)
  local choice = (T.choices and T.choices[letter]) or "?"
  echo(string.format("\27[1;36m[trivia] answered %s (%s) — %s\27[0m", letter:upper(), choice, source))
end

-- Letters that actually have a choice this asking (usually a-d, but be defensive).
local function available_letters()
  local ls = {}
  for _, L in ipairs(CHOICE_LETTERS) do if T.choices and T.choices[L] then ls[#ls + 1] = L end end
  return ls
end

-- Last resort: never leave a question unanswered. Pick a random available letter and send it. Better a
-- 1-in-4 shot (and a chance to LEARN the real answer from the reveal) than sitting it out.
local function guess(reason)
  if T.answered then return end
  local ls = available_letters()
  if #ls == 0 then return end
  if reason then echo("\27[33m[trivia] " .. reason .. " — guessing\27[0m") end
  submit(ls[math.random(#ls)], "guess")
end

-- ---- model tool-calling: look answers up with in-game commands ------------------------------------
-- Some questions aren't in the RAG corpus but ARE answerable live (an area's sector/level; a Great Library
-- entry). We give the model two TOOLS; when it can't answer from the reference it calls one, we run the
-- matching in-game command, capture its output (tolerating combat noise), feed it back, and it answers.
-- Needs the ai_local_tools_request builtin (a relaunch after adding it); without it we fall back to the
-- old tool-less single call, so trivia keeps working (guessing on lookup questions) until then.
local TOOLS_JSON = [==[[
{"type":"function","function":{"name":"area_info","description":"Look up an Alter Aeon AREA by name to find its sector/continent and its level. Call this for any question about which sector or continent an area is in, or an area's level.","parameters":{"type":"object","properties":{"area_name":{"type":"string","description":"the area name, e.g. Cliffside Island"}},"required":["area_name"]}}},
{"type":"function","function":{"name":"library_entry","description":"Look up a Great Library ENTRY by its number to get its title and topic. Call this for any question asking what a numbered Great Library entry is.","parameters":{"type":"object","properties":{"entry_number":{"type":"integer","description":"the entry number, e.g. 48043"}},"required":["entry_number"]}}}
]]==]

-- Parse the first tool call out of ai_local_tools_request's tool_calls_json ("[{name, arguments}]", where
-- arguments is an ESCAPED json string). No JSON decoder in this runtime, so we pull the fields we need with
-- patterns: the name, then the one argument value each tool takes (tolerant of the \"…\" escaping).
local function parse_tool_call(tool_calls_json)
  local j = tool_calls_json or ""
  local name = j:match('"name"%s*:%s*"([%w_]+)"')
  if name == "area_info" then
    local a = j:match('area_name["\\:%s]+([^"\\]+)')
    return name, { area_name = a and trim(a) or nil }
  elseif name == "library_entry" then
    local n = j:match('entry_number["\\:%s]+(%d+)')
    return name, { entry_number = n and tonumber(n) or nil }
  end
  return name, {}
end

-- The in-game command that answers a given tool call, or nil for an unusable one.
local function tool_command(name, args)
  args = args or {}
  if name == "area_info" and args.area_name and args.area_name ~= "" then
    return "area " .. pick_keyword(args.area_name)     -- pick_keyword: a distinctive search word
  elseif name == "library_entry" and args.entry_number then
    return "library read " .. args.entry_number
  end
  return nil
end

-- A tool NAME -> the short source tag shown when we answer from its lookup.
local TOOL_SOURCE = { area_info = "area", library_entry = "library" }

-- ---- Great Library: discover book numbers, never fabricate them ----------------------------------
-- The model's `library_entry` tool hands us an entry_number, but for a "what's the topic of the book
-- entitled X?" question it has no way to KNOW the number and just makes one up — the game then rejects
-- `library read <made-up>` with "Sorry, that's not a valid book number." So we never trust a model
-- number: we read a number only if it (a) appears verbatim in the QUESTION ("What is entry 16105…"),
-- or (b) came back from a real `library list`/`library search`. Everything below is pure + unit-tested;
-- the async discovery chain that uses them lives in decide().

-- The game's rejection of a bad `library read`. Recognizing it is what turns a dead lookup into a retry
-- (via list/search) instead of a blind answer sourced as "library".
local function library_read_failed(out)
  local o = out or ""
  return o:find("not a valid book number", 1, true) ~= nil
      or o:find("'library list' for a list", 1, true) ~= nil
end

-- Parse `library list` / `library search` (and `library read`) catalog lines into entries. A line looks
-- like "48043 - a scriber's book of runes     Topic: philosophy" (Topic optional). Returns an array of
-- { num, title, topic } with title/topic normalized. Non-catalog lines (headers, combat) are skipped.
local function parse_library_list(out)
  local entries = {}
  for line in (out or ""):gmatch("[^\n]+") do
    local l = line:gsub("\27%[[%d;]*%a", "")            -- strip ANSI
    local num, rest = l:match("^%s*(%d+)%s*%-%s+(.+)$")
    if num then
      local title, topic = rest:match("^(.-)%s%s+Topic:%s*(.+)$")
      if not title then title = rest end
      entries[#entries + 1] = { num = tonumber(num), title = norm(title), topic = norm(topic or "") }
    end
  end
  return entries
end

-- Pull the quoted book title out of a "…book entitled "X"…" / "…titled, 'X'…" / "…called "X"…" question.
local function library_title(question)
  local q = question or ""
  return q:match('entitled%s*,?%s*["\'](.-)["\']')
      or q:match('titled%s*,?%s*["\'](.-)["\']')
      or q:match('called%s*,?%s*["\'](.-)["\']')
end

-- The `library list` search keyword for a title question: the most distinctive word of the quoted title.
local function library_keyword(question)
  local title = library_title(question)
  if not title then return nil end
  return pick_keyword(title)
end

-- An entry number stated IN the question itself ("What is entry 16105 in the Great Library?"). Trusted
-- (it's the game's own number, not a model guess) so it may be read directly.
local function question_book_number(question)
  local q = question or ""
  local n = q:match("[Ee]ntry%s+#?(%d+)") or q:match("[Bb]ook%s+#?(%d+)") or q:match("[Nn]umber%s+#?(%d+)")
  return n and tonumber(n) or nil
end

-- From parsed catalog entries, pick the number whose title matches the question's book title. Returns a
-- number that DEFINITELY appeared in the list (so it's safe to `library read`), or nil to give up. This
-- is the only source of a book number when the question doesn't state one — a model guess never reaches
-- `library read`.
local function library_pick_entry(entries, question)
  if not entries or #entries == 0 then return nil end
  local title = library_title(question)
  local tnorm = title and norm(title) or nil
  if tnorm and tnorm ~= "" then
    for _, e in ipairs(entries) do
      if e.title == tnorm or e.title:find(tnorm, 1, true) or tnorm:find(e.title, 1, true) then
        return e.num
      end
    end
    return nil                                          -- had a title but nothing matched → don't guess
  end
  if #entries == 1 then return entries[1].num end       -- no title, but the search pinned a single entry
  return nil
end

-- ---- in-game command output capture (noise-tolerant), STREAM + PROMISE driven --------------------
-- A lookup command's output has no single terminal line — the answer is spread across several lines amid
-- combat noise — so we COLLECT over a short window. The window is inherent to the behaviour (it's not a
-- stall watchdog), so it stays an `after`; but the machinery is now reactive. Every game line is pushed
-- onto `lineS` (a hot Subject) by the broad `.+` collector trigger; run_lookup() returns a PROMISE that
-- subscribes for the window, keeps the lines capture_keep() lets through (capped), and RESOLVES with the
-- concatenated text. The single in-flight subscription IS the gate: a line arriving with no lookup
-- awaiting has no subscriber and is dropped — no `capture.active` flag to juggle. capture_keep + the
-- collectors stay pure/thin; the async progress lives in the promise chain, not module state.
local CAPTURE_MAX = 40
local rx = __rx
local lineS    = rx and rx.subject() or nil   -- every game line (fed by the broad `.+` collector trigger)
local areaRowS = rx and rx.subject() or nil   -- parsed `area` rows (fed by the Lvl|Grp trigger)
local GIVEUP   = {}                            -- rejection sentinel: "couldn't resolve honestly → degrade"

-- Should this line be kept in a lookup capture? (Pure — unit-tested.)
local function capture_keep(line, cmd)
  local l = trim(line or "")
  if l == "" then return false end
  if l:find("^kxw[tq]_") then return false end                 -- protocol machinery
  if l:find("^%[event%]") then return false end             -- the trivia channel itself
  if cmd and l == trim(cmd) then return false end           -- our own echoed command
  return true
end

-- The broad line collector fans every line into lineS; the active lookup (if any) filters + keeps it.
local function collect_line(line) if lineS then lineS:onNext(line) end end

-- A flow promise: __promise STARTED synchronously at construction (a lookup's send must go out the moment
-- run_lookup is reached inside a chain, not a tick later) and kept OUT of the HUD promise widget (this is
-- background plumbing, not a user action). Guarded so the file still loads without the promise layer.
local function P(executor)
  local p = __promise and __promise(executor, "trivia-lookup") or nil
  if p and __untrack_promise then __untrack_promise(p) end
  if p and p.__start then p.__start() end
  return p
end
local function rejected(reason) return P(function(_, reject) reject(reason) end) end
local function dead_p()         return P(function() end) end   -- never settles: a stale flow halts silently
-- A model reply / lookup that lands after a reload (epoch bump) or after we've already answered must not
-- fire a stale `event answer`; the chain checks this at each async boundary and halts (dead_p) if so.
local function stale() return EPOCH ~= _TRIVIA.epoch or T.answered end

-- Run a lookup command; RESOLVES with its captured output after the collection window. Pure-Lua promise
-- over the line stream, replacing the old capture.active/callback machine.
local function run_lookup(cmd)
  return P(function(resolve)
    local lines = {}
    local sub = lineS and lineS:subscribe(function(line)
      if #lines >= CAPTURE_MAX then return end
      if capture_keep(line, cmd) then lines[#lines + 1] = trim(line) end
    end) or nil
    send(cmd)
    after(cfg.lookup_wait, function()
      if sub then sub:unsubscribe() end
      resolve(table.concat(lines, "\n"))
    end)
  end)
end

local function ask_model()
  local q, choices = T.q_raw or T.q, T.choices
  local prompt_choices = {}
  for _, L in ipairs({ "a", "b", "c", "d" }) do
    if choices[L] then prompt_choices[#prompt_choices + 1] = L:upper() .. ": " .. choices[L] end
  end
  local sys = "You answer multiple-choice trivia about the MUD 'Alter Aeon'. Use the REFERENCE if it helps. "
    .. "If you can't answer for certain from the reference (e.g. which sector/continent an area is in, an "
    .. "area's level, or what a numbered Great Library entry is), CALL a tool to look it up, then answer. "
    .. "Otherwise reply with EXACTLY ONE character: the letter A, B, C, or D. Output nothing else."

  -- Parse a model reply into a letter and submit (or guess). `source` labels how we got it.
  local function answer_from(reply, source)
    if EPOCH ~= _TRIVIA.epoch or T.answered then return end
    local letter = extract_letter(reply)
    if letter and T.choices[letter] then submit(letter, source)
    else guess("couldn't parse a letter from '" .. tostring(reply) .. "'") end
  end

  local function decide(reference)
    if EPOCH ~= _TRIVIA.epoch or T.answered then return end
    local user = (reference and reference ~= "" and ("REFERENCE:\n" .. reference .. "\n\n") or "")
      .. "QUESTION: " .. q .. "\n" .. table.concat(prompt_choices, "\n")
    -- Preferred: the LOCAL model WITH tools, so we don't depend on (or pay for) the pilot's brain and can
    -- look answers up in-game. Fall back to a plain local (then shared) call when the tools builtin is
    -- missing (binary not relaunched yet), and to a guess if there's no model at all.
    -- Feed a successful lookup's output back to the model and answer, labeling the source.
    local function feed_lookup(name, out)
      if stale() then return end
      local user2 = user .. "\n\nLOOKUP RESULT (" .. name .. "):\n" .. out .. "\n\nNow answer with one letter:"
      ai_local_tools_request(sys, user2, cfg.max_tokens, cfg.think_prefill, "", function(r2, _, e2)
        if e2 then guess("model error: " .. e2) else answer_from(r2, TOOL_SOURCE[name] or "tool") end
      end)
    end

    -- Resolve a Great Library lookup WITHOUT ever reading a fabricated number, as a PROMISE CHAIN over the
    -- reply streams. RESOLVES with the successful `library read` text, or REJECTS with GIVEUP when it can't
    -- resolve one honestly — the caller then degrades to a NARRATED labeled guess (never a letter sourced
    -- as though the library confirmed it). The only numbers ever read are (a) one the QUESTION itself states
    -- (question_book_number, trusted) or (b) one that came back from a real `library list` (library_pick_
    -- entry — flowed on as the resolve value). A model's fabricated number never reaches `library read`.
    local function resolve_library()
      local qnum = question_book_number(q)                 -- a number the QUESTION itself states (trusted)
      local function give_up(msg) echo("\27[33m[trivia] " .. msg .. "\27[0m"); return rejected(GIVEUP) end
      -- Search the catalog by the question's book title; the matching entry NUMBER flows on as the resolve
      -- value into the `library read` step (validated — it definitely appeared in the list).
      local function discover()
        if stale() then return dead_p() end
        local kw = library_keyword(q)
        if not kw then return give_up("library: no book title to search — skipping lookup") end
        local list_cmd = "library list " .. kw
        echo("\27[36m[trivia] searching the library: " .. list_cmd .. "\27[0m")
        return run_lookup(list_cmd):andThen(function(list_out)
          if stale() then return dead_p() end
          local pick = library_pick_entry(parse_library_list(list_out), q)
          if not pick then return give_up("library: no matching entry in the catalog — giving up on this lookup") end
          return pick                                      -- ← the validated entry number flows on
        end):andThen(function(pick)
          local read_cmd = "library read " .. pick
          echo("\27[36m[trivia] looking it up: " .. read_cmd .. "\27[0m")
          return run_lookup(read_cmd):andThen(function(read_out)
            if stale() then return dead_p() end
            if library_read_failed(read_out) then
              return give_up("library read " .. pick .. " still rejected — giving up on this lookup")
            end
            return read_out
          end)
        end)
      end
      if qnum then
        local read_cmd = "library read " .. qnum
        echo("\27[36m[trivia] looking it up: " .. read_cmd .. "\27[0m")
        return run_lookup(read_cmd):andThen(function(read_out)
          if stale() then return dead_p() end
          if library_read_failed(read_out) then           -- the game rejected the question-stated number →
            echo("\27[33m[trivia] library read " .. qnum .. " not a valid book number — searching by title\27[0m")
            return discover()                              -- retry by title (still never a fabricated number)
          end
          return read_out
        end)
      end
      return discover()                                    -- no trusted number → never read the model's guess
    end

    if ai_local_tools_request then
      ai_local_tools_request(sys, user .. "\n\nAnswer with one letter, or call a tool.", cfg.tool_max_tokens,
        cfg.think_prefill, TOOLS_JSON, function(reply, tool_calls, err)
          if stale() then return end
          if err then guess("model error: " .. err); return end
          if not tool_calls then answer_from(reply, "model"); return end   -- answered directly
          local name, args = parse_tool_call(tool_calls)
          if name == "library_entry" then                                  -- validated, discovery-first path
            resolve_library()
              :andThen(function(out) if not stale() then feed_lookup("library", out) end end)
              :catch(function(reason)                                      -- the invalid-book rejection lands here
                if not stale() and reason == GIVEUP then
                  guess("library lookup unresolved")                       -- labeled guess, NOT a fake "library" answer
                end
              end)
            return
          end
          local cmd = tool_command(name, args)
          if not cmd then answer_from(reply, "model"); return end          -- unusable tool call → try the text
          echo("\27[36m[trivia] looking it up: " .. cmd .. "\27[0m")
          run_lookup(cmd):andThen(function(out) if not stale() then feed_lookup(name, out) end end)
        end)
    elseif ai_local_request then
      ai_local_request(sys, user .. "\n\nAnswer with one letter:", cfg.max_tokens, cfg.think_prefill,
        function(reply, err) if err then guess("model error: " .. err) else answer_from(reply, "model") end end)
    elseif ai_request then
      ai_request(sys, user .. "\n\nAnswer with one letter:", cfg.max_tokens, "", cfg.think_prefill,
        function(reply, _, err) if err then guess("model error: " .. err) else answer_from(reply, "model") end end)
    else
      guess("no model available")
    end
  end

  -- Ground with RAG when the index is loaded; otherwise go in cold. `chunks_json` is a JSON array of
  -- passage strings — models read that fine, so we hand it over verbatim rather than pulling in a decoder.
  if ai_retrieve and ai_rag_count and ai_rag_count() > 0 then
    ai_retrieve(q, cfg.rag_k, function(chunks_json, rerr)
      if EPOCH ~= _TRIVIA.epoch or T.answered then return end
      decide((not rerr and chunks_json) or "")
    end)
  else
    decide("")
  end
end

-- Answer "What level is the area <NAME>?" by asking the game. Send `area <keyword>`, let the area-row
-- trigger collect the results, then (after a beat) find the row matching <NAME> and map its level to a
-- choice. Falls back to the model if the area isn't found (e.g. undiscovered, or the list was paged).
-- Collect the `area` rows off areaRowS for the window, then match + map. The single window subscription
-- IS the gate (a stray `area` row outside a lookup has no subscriber and is dropped), so the T.area_rows
-- flag has dissolved into this closure — same as run_lookup's line capture.
local function try_area(area_name)
  local target = norm_area(area_name)
  local rows = {}
  local sub = areaRowS and areaRowS:subscribe(function(r) rows[#rows + 1] = r end) or nil
  send("area " .. pick_keyword(area_name))
  after(cfg.area_wait, function()
    if sub then sub:unsubscribe() end
    if stale() then return end
    local match
    for _, r in ipairs(rows) do
      if r.desc == target or r.desc:find(target, 1, true) or target:find(r.desc, 1, true) then
        match = r; break
      end
    end
    if not match then ask_model(); return end   -- couldn't identify the area — let the model try
    local letter = choice_for_level(T.choices, match.n1, match.kind == "Grp")
    if letter then submit(letter, "area") else ask_model() end
  end)
end

local function attempt_answer()
  if not S.enabled then return end
  if not T.q or not T.choices or T.answered then return end
  -- 1) Memory: have we been told the right answer to this exact question before?
  local known = cache[T.q]
  if known then
    local letter = letter_for_text(T.choices, known)
    if letter then submit(letter, "memory"); return end
    -- Cached answer text isn't among this asking's choices (rare) — fall through below.
  end
  -- 2) Area-level questions: ask the game directly (`area`), which is authoritative and not in the corpus.
  -- Guard against the "area heal SPELL" trap: "What level is the area heal spell?" is a spell question,
  -- not an area, so skip anything ending in spell/skill.
  local area_name = T.q_raw and T.q_raw:match("^[Ww]hat level is the area%s+(.+)")
  if area_name then area_name = trim((area_name:gsub("%s*%?%s*$", ""))) end
  local low = area_name and area_name:lower()
  if area_name and not (low:match("spell$") or low:match("skill$")) then try_area(area_name); return end
  -- 3) Model + RAG.
  ask_model()
end

-- ---- channel triggers ----------------------------------------------------------------------------
-- Lines reach triggers ANSI-stripped. `[event]` is AlterAeon's literal channel tag. The trigger bodies
-- are thin wrappers over named SEAMS (on_trivia_question / on_trivia_choices / on_area_line /
-- collect_line) that BOTH the live triggers AND the specs call — one path, no second matcher to drift
-- (mirrors AutoFight's hit_* / Corpse's reply seams). The specs drive a whole lookup flow through these.
local function on_trivia_question(q)
  T = { q = norm(q), q_raw = trim(q), choices = nil, answered = false, our_letter = nil, source = nil }
end
local function on_trivia_choices(c)
  if not T.q then return end   -- choices without a question we captured; ignore
  T.choices = parse_choices(c)
  attempt_answer()
end
-- Fan `area` command rows into areaRowS; only try_area's in-flight window subscribes, so a stray row is
-- dropped. The prefilter matches "Lvl <n>" / "Grp <n>" rows; parse_area_row rejects anything else.
local function on_area_line(line)
  local r = parse_area_row(line)
  if r and areaRowS then areaRowS:onNext(r) end
end

trigger("\\[event\\] trivia question:\\s*(.+)", function(_, q) on_trivia_question(q) end)
trigger("^\\s*(?:Lvl|Grp)\\s+\\d", function(line) on_area_line(line) end)
-- Broad line collector for a tool lookup's command output. Matches every line but no-ops unless a lookup
-- capture is active (run_lookup), so it's cheap the rest of the time; collect_line does the filtering.
trigger(".+", function(line) collect_line(line) end)
trigger("\\[event\\] trivia choices:\\s*(.+)", function(_, c) on_trivia_choices(c) end)

-- Reveal: "...the answer is 'c', 7 players answered." — learn it (order-agnostic, by text) and score.
trigger("\\[event\\] trivia answer:.*answer is '?(\\w)'?", function(_, rletter)
  rletter = rletter:lower()
  if T.choices and T.choices[rletter] then
    local was_new = cache[T.q] == nil
    cache[T.q] = T.choices[rletter]
    if was_new then S.stats.learned = S.stats.learned + 1 end
    save_cache()
  end
  if T.answered and T.our_letter then
    S.stats.attempts = S.stats.attempts + 1
    if T.our_letter == rletter then
      S.stats.correct = S.stats.correct + 1
      echo("\27[1;32m[trivia] ✓ correct (" .. rletter:upper() .. ")\27[0m")
    else
      echo(string.format("\27[1;31m[trivia] ✗ we said %s, answer was %s (learned)\27[0m",
        T.our_letter:upper(), rletter:upper()))
    end
  end
  T = { q = nil, choices = nil, answered = false }   -- clear until the next question
end)

-- Heads-up when a game is announced (purely informational).
trigger("\\[event\\] announcement: (.*TRIVIA[^\\n]*)", function(_, msg)
  if S.enabled then echo("\27[1;33m[trivia] " .. trim(msg) .. " (auto-answer armed)\27[0m") end
end)

-- ---- #trivia control -----------------------------------------------------------------------------
local function status_line()
  local s = S.stats
  local acc = s.attempts > 0 and string.format(" · %.0f%% (%d/%d)",
    100 * s.correct / s.attempts, s.correct, s.attempts) or ""
  return string.format("[trivia] %s · %d learned%s", S.enabled and "ON" or "OFF", s.learned, acc)
end

-- The `trivia` control surface: a documented, first-class table (Phase-2 migration off the old
-- command("trivia", …) string parser). Members are individually doc()'d so help(trivia) lists them;
-- the table is *callable* so the legacy typed `#trivia on` (rewritten to `trivia("on")`) still works.
trivia = {}
function trivia.on() S.enabled = true; echo(status_line()) end
function trivia.off() S.enabled = false; echo("[trivia] OFF (auto-answer disabled)") end
function trivia.status() echo(status_line()) end
function trivia.stats() echo(status_line()) end
function trivia.forget()
  cache = {}; S.stats.learned = 0; save_cache(); echo("[trivia] cleared learned-answer cache")
end

doc(trivia.on, { name = "trivia.on", sig = "trivia.on()", group = "trivia",
  text = "Enable auto-answering of the game's trivia questions." })
doc(trivia.off, { name = "trivia.off", sig = "trivia.off()", group = "trivia",
  text = "Disable auto-answering." })
doc(trivia.status, { name = "trivia.status", sig = "trivia.status()", group = "trivia",
  text = "Show whether auto-answer is on, how many answers are learned, and the running accuracy." })
doc(trivia.stats, { name = "trivia.stats", sig = "trivia.stats()", group = "trivia",
  text = "Same readout as trivia.status(): on/off, learned count, accuracy." })
doc(trivia.forget, { name = "trivia.forget", sig = "trivia.forget()", group = "trivia",
  text = "Clear the learned-answer cache." })

setmetatable(trivia, { __call = function(_, rest)
  local verb = trim((rest or "")):lower()
  if verb == "on" then trivia.on()
  elseif verb == "off" then trivia.off()
  elseif verb == "stats" then trivia.stats()
  elseif verb == "forget" then trivia.forget()
  elseif verb == "" or verb == "status" then trivia.status()
  else echo("[trivia] usage: trivia.on() | trivia.off() | trivia.stats() | trivia.forget()  (help(trivia))") end
end })

-- Pure helpers exposed for the test harness (Scripts/tests/trivia_spec.lua).
_TRIVIA_TEST = {
  parse_choices = parse_choices,
  extract_letter = extract_letter,
  norm = norm,
  letter_for_text = letter_for_text,
  parse_area_row = parse_area_row,
  pick_keyword = pick_keyword,
  norm_area = norm_area,
  choice_for_level = choice_for_level,
  parse_tool_call = parse_tool_call,
  tool_command = tool_command,
  capture_keep = capture_keep,
  library_read_failed = library_read_failed,
  parse_library_list = parse_library_list,
  library_title = library_title,
  library_keyword = library_keyword,
  question_book_number = question_book_number,
  library_pick_entry = library_pick_entry,
  -- Flow seams: drive the async lookup machine the way the live triggers do (question → choices kicks
  -- attempt_answer; collect_line / on_area_line feed a lookup's reply lines). Behaviour-level flow specs
  -- use these + stubbed send/echo/after/ai_local_tools_request to assert the SEND SEQUENCE and narration.
  on_question  = on_trivia_question,
  on_choices   = on_trivia_choices,
  on_area_line = on_area_line,
  collect_line = collect_line,
}

-- Pin the local client to a real chat model (see cfg.model) so ai_local_request doesn't fall through to
-- LM Studio's embedding model. Guarded for an un-relaunched binary that lacks the builtin.
if ai_set_local_model then ai_set_local_model(cfg.model) end

load_cache()
echo(status_line())
