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

local cfg = {
  enabled = true,          -- auto-answer by default (that's the whole point); `#trivia off` to disable
  rag_k = 4,               -- help passages retrieved to ground an unseen question
  area_wait = 1.2,         -- seconds to let the `area` command's rows arrive before deciding
  max_tokens = 12,         -- we only want a letter back
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
  local chunk = loadfile(cfg.cache_file)
  if chunk then local ok, t = pcall(chunk); if ok and type(t) == "table" then cache = t end end
  local n = 0; for _ in pairs(cache) do n = n + 1 end
  S.stats.learned = n
end

local function save_cache()
  local f = io.open(cfg.cache_file, "w")
  if not f then return end
  f:write("return {\n")
  for q, a in pairs(cache) do
    f:write(string.format("  [%q] = %q,\n", q, a))
  end
  f:write("}\n")
  f:close()
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

local function ask_model()
  local q, choices = T.q, T.choices
  local prompt_choices = {}
  for _, L in ipairs({ "a", "b", "c", "d" }) do
    if choices[L] then prompt_choices[#prompt_choices + 1] = L:upper() .. ": " .. choices[L] end
  end
  local sys = "You answer multiple-choice trivia about the MUD 'Alter Aeon'. Use the REFERENCE if it "
    .. "helps. Reply with EXACTLY ONE character: the letter (A, B, C, or D) of the best answer. Output "
    .. "nothing else."

  local function on_reply(reply, err)
    if EPOCH ~= _TRIVIA.epoch or T.answered then return end
    if err then guess("model error: " .. err); return end
    local letter = extract_letter(reply)
    if letter and T.choices[letter] then submit(letter, "model")
    else guess("couldn't parse a letter from '" .. tostring(reply) .. "'") end
  end

  local function decide(manual)
    if EPOCH ~= _TRIVIA.epoch or T.answered then return end
    local user = (manual and manual ~= "" and ("REFERENCE:\n" .. manual .. "\n\n") or "")
      .. "QUESTION: " .. q .. "\n" .. table.concat(prompt_choices, "\n") .. "\n\nAnswer with one letter:"
    -- Answer with the LOCAL model so we don't depend on (or pay for) the pilot's hosted brain — which
    -- may be down or unconfigured, in which case the shared ai_request just errors and we'd guess every
    -- time. Fall back to the shared brain only if the local builtin is missing (un-relaunched binary),
    -- and to a guess if there's no model at all.
    if ai_local_request then
      ai_local_request(sys, user, cfg.max_tokens, cfg.think_prefill, on_reply)
    elseif ai_request then
      ai_request(sys, user, cfg.max_tokens, "", cfg.think_prefill, function(reply, _, err) on_reply(reply, err) end)
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
local function try_area(area_name)
  T.area_rows = {}
  send("area " .. pick_keyword(area_name))
  local target = norm_area(area_name)
  after(cfg.area_wait, function()
    if EPOCH ~= _TRIVIA.epoch or T.answered then T.area_rows = nil; return end
    local rows = T.area_rows or {}; T.area_rows = nil
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
-- Lines reach triggers ANSI-stripped. `[event]` is AlterAeon's literal channel tag.
trigger("\\[event\\] trivia question:\\s*(.+)", function(_, q)
  T = { q = norm(q), q_raw = trim(q), choices = nil, answered = false, our_letter = nil, source = nil }
end)

-- Collect `area` command rows, but only while a trivia area-lookup is in flight (T.area_rows set by
-- try_area). The prefilter matches "Lvl <n>" / "Grp <n>" rows; parse_area_row rejects anything else.
trigger("^\\s*(?:Lvl|Grp)\\s+\\d", function(line)
  if not T.area_rows then return end
  local r = parse_area_row(line)
  if r then T.area_rows[#T.area_rows + 1] = r end
end)

trigger("\\[event\\] trivia choices:\\s*(.+)", function(_, c)
  if not T.q then return end   -- choices without a question we captured; ignore
  T.choices = parse_choices(c)
  attempt_answer()
end)

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
}

-- Pin the local client to a real chat model (see cfg.model) so ai_local_request doesn't fall through to
-- LM Studio's embedding model. Guarded for an un-relaunched binary that lacks the builtin.
if ai_set_local_model then ai_set_local_model(cfg.model) end

load_cache()
echo(status_line())
