-- Speech.lua — text-to-speech for in-game chat, one persistent voice per speaker.
--
-- Watches the chat surface (tells, group tells, says, and the gossip/chat/auction/newbie/yell/shout
-- channels — plus your OWN "You say/tell/…" lines) and speaks the message aloud through macOS `say`
-- (the host `speak`/`speech_voices`/`speech_stop` builtins in SpeechService.swift). Each distinct
-- speaker keeps a stable voice, assigned on first sighting and PERSISTED to disk, so "Mouserat" always
-- sounds like Mouserat across sessions. Your character is keyed canonically as "you" (not the character
-- name, so it survives a rename) and gets its own voice.
--
-- CRITICAL — never speaks history. Every utterance is guarded by the host `is_live()` discriminator,
-- which is false while `replay()` feeds saved logs (and outside any live batch), so replayed/scrollback
-- text is silent. A short post-connect mute window (cfg.connect_mute) also swallows the login/MOTD
-- burst.
--
-- Voice assignment: a provisional voice is picked IMMEDIATELY (least-used within a gender pool, else
-- round-robin over all voices) — speech NEVER blocks on the model. Optionally the local model classifies
-- the speaker's name male/female (ai_local_request, strict one-letter contract, silent fallback) and, if
-- it lands before that speaker has been heard, upgrades the pick.
--
-- Controls: voice.on()/off() · voice.list() · voice.set("name","Samantha") · voice.test("Samantha") ·
-- voice.forget("name") · voice.mute(seconds); `help(voice)`. Hot-reloadable: edit + pilot.reload().

local cfg = {
  enabled = true,            -- speak by default; voice.off() to silence
  rate = nil,                -- words/min for `say` (nil = system default)
  connect_mute = 4,          -- seconds after a connect to stay silent (login/MOTD burst)
  home = os.getenv("HOME") or "",
  -- Say the speaker's name before the message on these channels (public chatter reads better with an
  -- attribution; private tells/says are quieter without one). Keyed by canonical channel.
  speak_names = {
    gossip = true, chat = true, auction = true, newbie = true, yell = true, shout = true,
    gtell = true, say = false, tell = false,
  },
  -- Optional LLM gender classification for a better first voice. NEVER blocks speech.
  classify = {
    enabled = true,
    max_tokens = 4,
    think_prefill = "<think>\n\n</think>\n\n",   -- same Qwen3.x empty-think guard trivia/pilot use
    model = os.getenv("SPEECH_MODEL") or os.getenv("TRIVIA_MODEL") or os.getenv("LMSTUDIO_MODEL")
            or "qwen3.6-35b-a3b-mlx",
  },
}
cfg.dir = cfg.home .. "/Documents/MudClient"
cfg.save_file = cfg.dir .. "/speech_voices.lua"

-- Survive pilot.reload(): the voice registry, session bookkeeping, and toggles live in a global; an
-- epoch neutralizes a model reply that lands after a reload. Defensive `or` init so this needs NO load
-- ordering — a bare Speech.lua works even if it somehow loads first.
_SPEECH = _SPEECH or {
  enabled = cfg.enabled,
  speakers = {},      -- canonical key -> voice name (persisted)
  spoken = {},        -- key -> true once heard this session (freezes their voice)
  classified = {},    -- key -> true once the LLM classifier has run (don't re-ask)
  connect_at = nil,   -- os.time() of the last connect (mute window anchor)
  mute_until = nil,   -- os.time() before which all speech is muted (voice.mute)
  loaded = false,
}
_SPEECH.epoch = (_SPEECH.epoch or 0) + 1
local EPOCH = _SPEECH.epoch
local S = _SPEECH

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
-- Canonical speaker key: lowercased, whitespace collapsed. So "Mouserat" and "mouserat " map together.
local function norm(s) return (trim(s):lower():gsub("%s+", " ")) end

-- ============================ persistence ============================
local function ser(v)
  local t = type(v)
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "string" then return string.format("%q", v) end
  if t == "table" then
    local parts = {}
    for k, val in pairs(v) do
      local key = (type(k) == "number") and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
      parts[#parts + 1] = key .. "=" .. ser(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end

local save_timer
local function save_now()
  local f = io.open(cfg.save_file, "w")
  if not f then return end
  f:write("return " .. ser({ speakers = S.speakers }))
  f:close()
end
-- Debounce writes (a chat flood assigns many voices at once): each edit re-arms a single 2s timer.
local function schedule_save()
  if cancel and save_timer then cancel(save_timer) end
  if after then save_timer = after(2, save_now) else save_now() end
end
local function load_saved()
  if S.loaded then return end
  S.loaded = true
  local chunk = loadfile(cfg.save_file)
  if not chunk then return end
  local ok, t = pcall(chunk)
  if ok and type(t) == "table" and type(t.speakers) == "table" then
    for k, v in pairs(t.speakers) do if S.speakers[k] == nil then S.speakers[k] = v end end
  end
end

-- ============================ chat-line parsing ============================
-- Verbatim AlterAeon wire formats (confirmed against ~/Documents/MudClient/human-traces.jsonl):
--   incoming tell:   "Mouserat tells you, 'hi'"      (also mob "X looks you over and tells you, '…'")
--   group tell:      "Mouserat tells the group, 'brb'"
--   room say:        "Gisco the Necromancer says, 'beware!'"   "A hedge wizard says, '…'"
--   channels:        "Mouserat gossips, '…'"  "Lokar chats, '…'"  "Judas auctions, '…'"
--                    "a fruit vendor yells, '…'"  (yells/shouts/newbies same shape)
--   your own:        "You say, 'odd'"   "You tell Conan, 'hi'"   "You gossip, '…'"

-- Your own outgoing verbs -> canonical channel.
local SELF_VERBS = { say = "say", gossip = "gossip", chat = "chat", auction = "auction",
                     yell = "yell", shout = "shout", newbie = "newbie" }
-- Third-person channel/say verbs -> canonical channel. A CLOSED set: a quoted combat/emote line whose
-- verb isn't here ("The orc screams, '…'") is rejected, so it never speaks.
local CHAN_VERBS = { gossips = "gossip", chats = "chat", auctions = "auction", yells = "yell",
                     shouts = "shout", newbies = "newbie", says = "say" }

-- Trim a mob's interstitial action clause so the voice key is the bare name: "Stiboli the Spellcaster
-- looks you over and tells you" -> "Stiboli the Spellcaster".
local INTERSTITIAL = { " looks you over and", " looks at you and", " glances at you and",
  " turns to you and", " smiles at you and", " grins at you and", " peers at you and",
  " nods at you and", " gazes at you and", " looks up at you and" }
local function clean_speaker(s)
  s = trim(s)
  for _, phrase in ipairs(INTERSTITIAL) do
    local i = s:find(phrase, 1, true)
    if i then s = trim(s:sub(1, i - 1)); break end
  end
  return s
end

-- parse_chat(line) -> { speaker, channel, message, is_self[, target] } or nil for a non-chat line.
-- `line` is the ANSI-stripped text triggers receive. Pure (unit-tested).
local function parse_chat(line)
  line = trim(line)
  if line == "" then return nil end
  -- ---- your own outgoing lines ----
  local tgt, msg = line:match("^You tell (.-), '(.*)'$")
  if tgt then
    if tgt == "the group" then return { speaker = "you", channel = "gtell", message = msg, is_self = true } end
    return { speaker = "you", channel = "tell", message = msg, is_self = true, target = tgt }
  end
  local verb, m2 = line:match("^You (%a+), '(.*)'$")
  if verb and SELF_VERBS[verb] then
    return { speaker = "you", channel = SELF_VERBS[verb], message = m2, is_self = true }
  end
  -- ---- incoming private / group tells ----
  local who, tmsg = line:match("^(.-) tells you, '(.*)'$")
  if who then return { speaker = clean_speaker(who), channel = "tell", message = tmsg } end
  who, tmsg = line:match("^(.-) tells the group, '(.*)'$")
  if who then return { speaker = clean_speaker(who), channel = "gtell", message = tmsg } end
  -- ---- incoming channels + room say:  "Name <verb>, 'msg'" ----
  local who2, cverb, cmsg = line:match("^(.-) (%a+), '(.*)'$")
  if who2 and CHAN_VERBS[cverb] and trim(who2) ~= "" then
    return { speaker = clean_speaker(who2), channel = CHAN_VERBS[cverb], message = cmsg }
  end
  return nil
end

-- ============================ voice pool & assignment ============================
-- Curated gender hints for common macOS voices (say -v ? carries no gender). Only used to bias the
-- pick; any name not here is treated as gender-neutral and stays eligible for either classification.
local VOICE_GENDER = {
  Alex = "m", Fred = "m", Daniel = "m", Tom = "m", Aaron = "m", Albert = "m", Bruce = "m",
  Junior = "m", Ralph = "m", Rishi = "m", Gordon = "m", Lee = "m", Oliver = "m", Reed = "m",
  Samantha = "f", Victoria = "f", Karen = "f", Moira = "f", Tessa = "f", Fiona = "f", Kate = "f",
  Serena = "f", Allison = "f", Ava = "f", Susan = "f", Vicki = "f", Zoe = "f", Nicky = "f",
  Kathy = "f", Sandy = "f", Shelley = "f",
}

local voice_pool   -- array of available voice names (cached from speech_voices)
local function ensure_pool()
  if voice_pool then return end
  voice_pool = {}
  if speech_voices then
    local ok, list = pcall(speech_voices)
    if ok and type(list) == "table" then
      for _, v in ipairs(list) do
        local nm = type(v) == "table" and v.name or v
        if type(nm) == "string" and nm ~= "" then voice_pool[#voice_pool + 1] = nm end
      end
    end
  end
  if #voice_pool == 0 then
    voice_pool = { "Alex", "Samantha", "Daniel", "Karen", "Fred", "Victoria", "Tom", "Moira" }
  end
end

local function used_count(name)
  local n = 0
  for _, v in pairs(S.speakers) do if v == name then n = n + 1 end end
  return n
end

-- Pick a voice: least-used within the gender pool (or all voices when gender is nil / no gendered
-- voices are available), then first in pool order — deterministic, and round-robins as speakers grow.
local function pick_voice(gender)
  ensure_pool()
  local pool = {}
  if gender then
    for _, name in ipairs(voice_pool) do if VOICE_GENDER[name] == gender then pool[#pool + 1] = name end end
  end
  if #pool == 0 then pool = voice_pool end
  local best, bestn
  for _, name in ipairs(pool) do
    local c = used_count(name)
    if not bestn or c < bestn then best, bestn = name, c end
  end
  return best
end

-- Ask the LOCAL model to classify a name male/female. Strict one-letter contract; any error, timeout,
-- or garbage falls back silently to cb(nil). Never blocks — the caller has already assigned a voice.
local function classify_gender(name, cb)
  if not (cfg.classify.enabled and ai_local_request) then return cb(nil) end
  local sys = "Classify the given fantasy character or player name as male or female. Reply with "
    .. "EXACTLY ONE letter: M for male, F for female, or U if unknown/unclear. Output nothing else."
  local epoch = EPOCH
  ai_local_request(sys, "Name: " .. name, cfg.classify.max_tokens, cfg.classify.think_prefill,
    function(reply, err)
      if EPOCH ~= _SPEECH.epoch or epoch ~= _SPEECH.epoch then return end   -- reloaded: drop stale
      if err then return cb(nil) end
      local g = tostring(reply or ""):upper():match("[MFU]")
      if g == "M" then cb("m") elseif g == "F" then cb("f") else cb(nil) end
    end, cfg.classify.model)
end

-- assign_voice(key, display) -> voice. Returns the speaker's existing voice, or picks (and persists) a
-- new one on first sighting. Provisional pick is IMMEDIATE; an optional async classify upgrades it iff
-- the speaker hasn't been heard yet.
local function assign_voice(key, display)
  local existing = S.speakers[key]
  if existing then return existing end
  local v = pick_voice(nil)
  S.speakers[key] = v
  schedule_save()
  if key ~= "you" and display and display ~= "" and not S.classified[key] then
    S.classified[key] = true
    classify_gender(display, function(gender)
      if not gender then return end
      if S.spoken[key] then return end             -- already heard with the provisional voice — keep it
      local gv = pick_voice(gender)
      if gv and gv ~= S.speakers[key] then S.speakers[key] = gv; schedule_save() end
    end)
  end
  return v
end

-- ============================ speaking ============================
local function is_muted()
  local now = os.time()
  if S.mute_until and now < S.mute_until then return true end
  if S.connect_at and (now - S.connect_at) < cfg.connect_mute then return true end
  return false
end

-- The gate every chat line passes through. Exposed for tests; the triggers just forward the line here.
local function speak_line(line)
  if not S.enabled then return end
  -- Live-only: is_live() is false during replay()/history. Guard for an un-relaunched binary lacking
  -- the builtin (then assume live).
  if is_live and not is_live() then return end
  if is_muted() then return end
  local c = parse_chat(line)
  if not c or not c.message or trim(c.message) == "" then return end
  local key = c.is_self and "you" or norm(c.speaker)
  if key == "" then return end
  local voice = assign_voice(key, c.is_self and nil or c.speaker)
  S.spoken[key] = true
  local text = trim(c.message)
  if cfg.speak_names[c.channel] then
    local nm = c.is_self and ((state and state.name) or "You") or c.speaker
    text = nm .. ": " .. text
  end
  if speak then speak(text, voice, cfg.rate) end
end

-- ============================ triggers ============================
-- One broad trigger fires for any chat-shaped line; parse_chat is the real, exact gate (a non-chat
-- quoted line — combat, emotes, signs — parses to nil and never speaks). Regexes run in the Swift
-- engine and aren't unit-testable; speak_line/parse_chat (the pure helpers) are.
trigger("^You (say|gossip|chat|auction|yell|shout|newbie|tell)\\b"
  .. "|(?:tells you|tells the group|gossips|chats|auctions|yells|shouts|newbies|says), '",
  function(line) speak_line(line) end)

-- Post-connect mute window: chain the existing on_connect (AlterAeon defines it) so we don't clobber
-- it, and stamp the connect time. Re-runs cleanly on reload (AlterAeon reloads first, resetting the
-- global to its own function, which we then re-wrap — no stacking).
local prev_on_connect = on_connect
function on_connect(...)
  S.connect_at = os.time()
  if type(prev_on_connect) == "function" then return prev_on_connect(...) end
end

-- ============================ public control surface ============================
voice = {}

function voice.on() S.enabled = true; echo("[voice] ON — speaking live chat") end
function voice.off() S.enabled = false; echo("[voice] OFF") end

function voice.list()
  local rows, n = {}, 0
  for k, v in pairs(S.speakers) do rows[#rows + 1] = { k = k, v = v }; n = n + 1 end
  table.sort(rows, function(a, b) return a.k < b.k end)
  echo(string.format("[voice] %s · %d speaker(s)", S.enabled and "ON" or "OFF", n))
  for _, r in ipairs(rows) do echo(string.format("  %-20s %s", r.k, r.v)) end
end

function voice.set(name, v)
  if type(name) ~= "string" or type(v) ~= "string" or name == "" or v == "" then
    return echo("[voice] usage: voice.set(\"name\", \"Samantha\")", "yellow")
  end
  S.speakers[norm(name)] = v
  schedule_save()
  echo(string.format("[voice] %s -> %s", norm(name), v))
end

function voice.test(v)
  v = (type(v) == "string" and v ~= "") and v or pick_voice(nil)
  if speak then speak("The quick brown fox jumps over the lazy dog.", v) end
  echo("[voice] testing " .. tostring(v))
end

function voice.forget(name)
  if type(name) ~= "string" or name == "" then return echo("[voice] usage: voice.forget(\"name\")", "yellow") end
  local key = norm(name)
  S.speakers[key] = nil; S.spoken[key] = nil; S.classified[key] = nil
  schedule_save()
  echo("[voice] forgot " .. key)
end

function voice.mute(seconds)
  seconds = tonumber(seconds) or 10
  S.mute_until = os.time() + seconds
  if speech_stop then speech_stop() end
  echo(string.format("[voice] muted for %d s", seconds))
end

-- Docs for the host builtins this script drives. Registered here (not bootstrap.lua) — the doc-coverage
-- spec checks the live registry, so it accepts a doc() from any loaded file. `__`-exempt names aside,
-- every builtin recorded in __host_builtins needs one of these.
doc("speak", { sig = "speak(text[, voice[, rate]])", group = "speech",
  text = "Speak text aloud via macOS `say` (SpeechService). voice is a system voice name (see speech_voices()); rate is words/min. Queued FIFO; a chat flood drops the oldest unspoken line. The text is passed as one argument (no shell), so game input is never injected.",
  example = "speak(\"hello there\", \"Samantha\")" })
doc("speech_stop", { sig = "speech_stop()", group = "speech",
  text = "Cancel the current utterance and flush the speech queue." })
doc("speech_voices", { sig = "speech_voices([all]) -> array", group = "speech",
  text = "The available system voices as { name=, locale= } entries (English-only unless all is truthy)." })
doc("is_live", { sig = "is_live() -> bool", group = "speech",
  text = "True only while the host is processing lines from the LIVE connection right now; false during replay() and outside a live batch. Guard live-only reactions (like speech) with this so replayed history is never re-acted-on." })

doc(voice.on, { name = "voice.on", sig = "voice.on()", group = "speech",
  text = "Enable text-to-speech for live in-game chat (tells, says, and channels)." })
doc(voice.off, { name = "voice.off", sig = "voice.off()", group = "speech",
  text = "Disable text-to-speech." })
doc(voice.list, { name = "voice.list", sig = "voice.list()", group = "speech",
  text = "List every known speaker and the voice assigned to it (your own character is keyed \"you\")." })
doc(voice.set, { name = "voice.set", sig = "voice.set(name, voice)", group = "speech",
  text = "Pin a speaker to a specific system voice (see speech_voices()). Persisted.",
  example = "voice.set(\"Mouserat\", \"Daniel\")" })
doc(voice.test, { name = "voice.test", sig = "voice.test([voice])", group = "speech",
  text = "Speak a sample sentence in the given voice (or an auto-picked one) to audition it.",
  example = "voice.test(\"Samantha\")" })
doc(voice.forget, { name = "voice.forget", sig = "voice.forget(name)", group = "speech",
  text = "Drop a speaker's saved voice so it is reassigned on next sighting." })
doc(voice.mute, { name = "voice.mute", sig = "voice.mute([seconds])", group = "speech",
  text = "Silence speech for N seconds (default 10) and flush anything queued. Handy during a flood.",
  example = "voice.mute(30)" })

-- Callable table so the legacy typed `#voice on` (rewritten to voice("on")) still works.
setmetatable(voice, { __call = function(_, rest)
  local args = trim(rest or "")
  local verb, arg = args:match("^(%S+)%s*(.-)$")
  verb = (verb or ""):lower()
  if verb == "on" then voice.on()
  elseif verb == "off" then voice.off()
  elseif verb == "list" or verb == "" then voice.list()
  elseif verb == "set" then local n, v = arg:match("^(%S+)%s+(%S+)$"); voice.set(n, v)
  elseif verb == "test" then voice.test(arg ~= "" and arg or nil)
  elseif verb == "forget" then voice.forget(arg)
  elseif verb == "mute" then voice.mute(tonumber(arg))
  else echo("[voice] usage: voice.on() | off() | list() | set(name,voice) | test(voice) | forget(name) | mute(s)  (help(voice))") end
end })

-- ============================ test seam ============================
_SPEECH_TEST = {
  parse_chat = parse_chat,
  clean_speaker = clean_speaker,
  pick_voice = pick_voice,
  used_count = used_count,
  assign_voice = assign_voice,
  classify_gender = classify_gender,
  speak_line = speak_line,
  ensure_pool = function() voice_pool = nil; ensure_pool() end,
  set_pool = function(p) voice_pool = p end,
  ser = ser,
  norm = norm,
  is_muted = is_muted,
  state = S,
  cfg = cfg,
}

load_saved()
