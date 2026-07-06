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
  rate = nil,                -- words/min for `say` (nil = system default; ignored by kokoro)
  connect_mute = 4,          -- seconds after a connect to stay silent (login/MOTD burst)
  -- Preferred TTS backend. "kokoro" = the local mlx-audio server (tools/tts/), with an automatic `say`
  -- fallback whenever it's unreachable (the Swift host arms a cooldown and re-probes); "say" forces
  -- macOS `say`. Runtime-switchable + persisted via voice.backend("kokoro"|"say").
  backend = "kokoro",
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
  backend = cfg.backend,  -- runtime backend preference (persisted); active_backend() adds health
  speakers = {},      -- canonical key -> { say = voiceName, kokoro = voiceId } (per-backend, persisted)
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
  f:write("return " .. ser({ speakers = S.speakers, backend = S.backend }))
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
    for k, v in pairs(t.speakers) do
      if S.speakers[k] == nil then
        -- Migrate the old flat format (key -> "Samantha") to the per-backend record. Old voices were
        -- always `say` voices, so seed the say slot; kokoro voices get assigned lazily on next sighting.
        if type(v) == "string" then S.speakers[k] = { say = v }
        elseif type(v) == "table" then S.speakers[k] = v end
      end
    end
  end
  if ok and type(t) == "table" and (t.backend == "say" or t.backend == "kokoro") then
    S.backend = t.backend
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

-- ============================ backend selection ============================
-- The EFFECTIVE backend for this line: cfg/S preference, but a kokoro preference is downgraded to say
-- while the host reports a kokoro cooldown (server unreachable). speech_backend() is the host's health
-- view; if the builtin is missing (un-relaunched binary) we optimistically honor the preference and let
-- the host's per-utterance fallback cover a dead server.
local function active_backend()
  local pref = S.backend or cfg.backend or "say"
  if pref == "say" then return "say" end
  if speech_backend then
    local ok, b = pcall(speech_backend)
    if ok and (b == "say" or b == "kokoro") then return b end
  end
  return "kokoro"
end

-- ============================ voice pools (per backend) ============================
-- SAY voices carry no gender in `say -v ?`, so we curate hints; any name not here is gender-neutral and
-- stays eligible for either classification.
local VOICE_GENDER = {
  Alex = "m", Fred = "m", Daniel = "m", Tom = "m", Aaron = "m", Albert = "m", Bruce = "m",
  Junior = "m", Ralph = "m", Rishi = "m", Gordon = "m", Lee = "m", Oliver = "m", Reed = "m",
  Samantha = "f", Victoria = "f", Karen = "f", Moira = "f", Tessa = "f", Fiona = "f", Kate = "f",
  Serena = "f", Allison = "f", Ava = "f", Susan = "f", Vicki = "f", Zoe = "f", Nicky = "f",
  Kathy = "f", Sandy = "f", Shelley = "f", Tara = "f", Stephanie = "f", Matilda = "f", Isha = "f",
  Nora = "f", Amira = "f",
}

-- macOS ships many NOVELTY/robotic "voices" under en_* (Zarvox, Trinoids, Bells, …). They read terribly
-- for chat, so drop them from the say pool. (Kokoro has no such junk.)
local SAY_NOVELTY = {
  Albert = true, ["Bad News"] = true, Bahh = true, Bells = true, Boing = true, Bubbles = true,
  Cellos = true, Wobble = true, ["Good News"] = true, Jester = true, Organ = true, Superstar = true,
  Trinoids = true, Whisper = true, Zarvox = true, Deranged = true, Hysterical = true,
  ["Pipe Organ"] = true, Junior = true, Grandma = true, Grandpa = true, Eddy = true, Flo = true,
  Reed = true, Rocko = true, Sandy = true, Shelley = true,
}
-- Preferred natural human voices (base names). The say pool intersects available voices with this list,
-- so quality stays high across macOS versions; if the machine has almost none of these we fall back to
-- (available minus novelty).
local SAY_PREFERRED = {
  Samantha = true, Alex = true, Ava = true, Allison = true, Susan = true, Zoe = true, Nicky = true,
  Vicki = true, Victoria = true, Kate = true, Serena = true, Fiona = true, Tessa = true, Karen = true,
  Moira = true, Tom = true, Aaron = true, Daniel = true, Rishi = true, Tara = true, Kathy = true,
  Oliver = true, Stephanie = true, Matilda = true, Isha = true, Nora = true, Fred = true,
}

-- Curated Kokoro v1.0 English voices (a_ = American, b_ = British; second letter f/m = gender). Used as
-- a fallback if the server's /v1/voices list can't be fetched.
local KOKORO_FALLBACK = {
  "af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky", "af_nova", "af_aoede", "af_kore",
  "af_alloy", "af_jessica", "af_river",
  "am_adam", "am_michael", "am_liam", "am_echo", "am_eric", "am_onyx", "am_puck", "am_fenrir",
  "bf_emma", "bf_alice", "bf_isabella", "bf_lily",
  "bm_george", "bm_daniel", "bm_lewis", "bm_fable",
}

-- A say voice's base name: "Ava (Premium)" -> "Ava" (for gender/preference/novelty lookup).
local function say_base(name) return (tostring(name):gsub("%s*%b()", ""):gsub("%s+$", "")) end
-- Rank a say voice variant: prefer Premium > Enhanced > plain, so a name with a hi-fi variant wins.
local function say_rank(name)
  if name:find("Premium") then return 3 elseif name:find("Enhanced") then return 2 else return 1 end
end

local say_pool, kokoro_pool   -- cached voice-name/id arrays

-- Build the SAY pool: dedupe by base name (best variant wins), keep preferred natural voices, drop
-- novelty. Falls back to (all-minus-novelty), then a tiny hard-coded list, so it's never empty.
local function build_say_pool()
  local names = {}
  if speech_voices then
    local ok, list = pcall(speech_voices)
    if ok and type(list) == "table" then
      for _, v in ipairs(list) do
        local nm = type(v) == "table" and v.name or v
        if type(nm) == "string" and nm ~= "" then names[#names + 1] = nm end
      end
    end
  end
  -- Pick the best variant per base name.
  local best = {}   -- base -> full name
  for _, nm in ipairs(names) do
    local b = say_base(nm)
    if not SAY_NOVELTY[b] then
      if not best[b] or say_rank(nm) > say_rank(best[b]) then best[b] = nm end
    end
  end
  local preferred, other = {}, {}
  for b, full in pairs(best) do
    if SAY_PREFERRED[b] then preferred[#preferred + 1] = full else other[#other + 1] = full end
  end
  table.sort(preferred); table.sort(other)
  local pool = preferred
  if #pool < 2 then for _, n in ipairs(other) do pool[#pool + 1] = n end end
  if #pool == 0 then pool = { "Samantha", "Daniel", "Karen", "Rishi", "Moira", "Tessa" } end
  return pool
end

-- Build the KOKORO pool: the server's English (a_/b_) voice ids, else the curated fallback.
local function build_kokoro_pool()
  local pool = {}
  if speech_kokoro_voices then
    local ok, list = pcall(speech_kokoro_voices)
    if ok and type(list) == "table" then
      for _, id in ipairs(list) do
        if type(id) == "string" and id:match("^[ab][fm]_") then pool[#pool + 1] = id end
      end
    end
  end
  if #pool == 0 then for _, id in ipairs(KOKORO_FALLBACK) do pool[#pool + 1] = id end end
  table.sort(pool)
  return pool
end

local function ensure_pools()
  if not say_pool then say_pool = build_say_pool() end
  if not kokoro_pool then kokoro_pool = build_kokoro_pool() end
end

local function pool_for(backend) ensure_pools(); return backend == "kokoro" and kokoro_pool or say_pool end

-- Gender of a voice within a backend: say via the curated map (by base name); kokoro via the id's
-- second letter (af_/bf_ = female, am_/bm_ = male).
local function voice_gender(backend, voice)
  if not voice then return nil end
  if backend == "kokoro" then
    local g = tostring(voice):sub(2, 2)
    if g == "f" then return "f" elseif g == "m" then return "m" end
    return nil
  end
  return VOICE_GENDER[say_base(voice)]
end

-- How many speakers already use `voice` for `backend` (round-robin least-used).
local function used_count(voice, backend)
  local n = 0
  for _, rec in pairs(S.speakers) do
    if type(rec) == "table" and rec[backend] == voice then n = n + 1 end
  end
  return n
end

-- Pick a voice for `backend`: least-used within the gender pool (or the whole pool when gender is nil /
-- no gendered voices exist), then pool order — deterministic, round-robins as speakers grow.
local function pick_voice(gender, backend)
  backend = backend or active_backend()
  local all = pool_for(backend)
  local pool = {}
  if gender then
    for _, name in ipairs(all) do if voice_gender(backend, name) == gender then pool[#pool + 1] = name end end
  end
  if #pool == 0 then pool = all end
  local best, bestn
  for _, name in ipairs(pool) do
    local c = used_count(name, backend)
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

-- assign_voice(key, display, backend) -> voice for that backend. Returns the speaker's existing
-- per-backend voice, or picks (and persists) one on first sighting for that backend. Provisional pick is
-- IMMEDIATE; an optional async classify (once per speaker) upgrades EVERY assigned backend's voice iff
-- the speaker hasn't been heard yet. Assignments for both backends are kept side by side, so switching
-- backends never loses the other's voice and only fills the gap for the newly-active backend.
local function assign_voice(key, display, backend)
  backend = backend or active_backend()
  local rec = S.speakers[key]
  if rec and rec[backend] then return rec[backend] end
  local v = pick_voice(nil, backend)
  rec = rec or {}; rec[backend] = v; S.speakers[key] = rec
  schedule_save()
  if key ~= "you" and display and display ~= "" and not S.classified[key] then
    S.classified[key] = true
    classify_gender(display, function(gender)
      if not gender then return end
      if S.spoken[key] then return end             -- already heard with the provisional voice — keep it
      local r = S.speakers[key]; if not r then return end
      local changed = false
      for _, b in ipairs({ "say", "kokoro" }) do
        if r[b] then
          local gv = pick_voice(gender, b)
          if gv and gv ~= r[b] then r[b] = gv; changed = true end
        end
      end
      if changed then schedule_save() end
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
  local display = c.is_self and nil or c.speaker
  local backend = active_backend()
  -- Primary voice for the active backend; when kokoro, also resolve a `say` voice so the host's
  -- transparent fallback (server unreachable) keeps this speaker sounding consistent.
  local voice = assign_voice(key, display, backend)
  local say_fallback = (backend == "kokoro") and assign_voice(key, display, "say") or nil
  S.spoken[key] = true
  local text = trim(c.message)
  if cfg.speak_names[c.channel] then
    local nm = c.is_self and ((state and state.name) or "You") or c.speaker
    text = nm .. ": " .. text
  end
  if speak then speak(text, voice, cfg.rate, backend, say_fallback) end
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

-- Switch or report the backend preference. voice.backend() reports current + effective; voice.backend
-- ("kokoro"|"say") sets and persists the preference.
function voice.backend(b)
  if b == nil or b == "" then
    local eff = active_backend()
    local detail = ""
    if speech_backend then local ok, _, d = pcall(speech_backend); if ok and d then detail = " (" .. d .. ")" end end
    return echo(string.format("[voice] backend pref=%s · active=%s%s", S.backend or cfg.backend, eff, detail))
  end
  b = tostring(b):lower()
  if b ~= "kokoro" and b ~= "say" then
    return echo("[voice] usage: voice.backend(\"kokoro\" | \"say\")", "yellow")
  end
  S.backend = b
  schedule_save()
  echo(string.format("[voice] backend -> %s (active=%s)", b, active_backend()))
end

function voice.list()
  local rows, n = {}, 0
  for k, rec in pairs(S.speakers) do rows[#rows + 1] = { k = k, rec = rec }; n = n + 1 end
  table.sort(rows, function(a, b) return a.k < b.k end)
  local eff = active_backend()
  echo(string.format("[voice] %s · backend=%s · %d speaker(s)", S.enabled and "ON" or "OFF", eff, n))
  for _, r in ipairs(rows) do
    local rec = type(r.rec) == "table" and r.rec or {}
    echo(string.format("  %-20s say=%-16s kokoro=%s", r.k, tostring(rec.say or "-"), tostring(rec.kokoro or "-")))
  end
end

-- Pin a speaker to a specific voice for the ACTIVE backend (a kokoro id like af_heart when kokoro is
-- active, else a say voice name). The other backend's assignment is left untouched.
function voice.set(name, v)
  if type(name) ~= "string" or type(v) ~= "string" or name == "" or v == "" then
    return echo("[voice] usage: voice.set(\"name\", \"af_heart\")", "yellow")
  end
  local key = norm(name)
  local backend = active_backend()
  local rec = S.speakers[key] or {}
  rec[backend] = v; S.speakers[key] = rec
  schedule_save()
  echo(string.format("[voice] %s -> %s (%s)", key, v, backend))
end

function voice.test(v)
  local backend = active_backend()
  v = (type(v) == "string" and v ~= "") and v or pick_voice(nil, backend)
  local fallback = (backend == "kokoro") and pick_voice(nil, "say") or nil
  if speak then speak("The quick brown fox jumps over the lazy dog.", v, cfg.rate, backend, fallback) end
  echo(string.format("[voice] testing %s (%s)", tostring(v), backend))
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
doc("speak", { sig = "speak(text[, voice[, rate[, backend[, say_fallback]]]])", group = "speech",
  text = "Speak text aloud (SpeechService). backend is \"kokoro\" (local mlx-audio server) or \"say\" (macOS, default); voice is the voice for that backend (a Kokoro id like af_heart, or a say voice name); rate is words/min (say only). say_fallback names the say voice used if a kokoro synth fails (the host falls back transparently and arms a cooldown). Queued FIFO; a chat flood drops the oldest unspoken line. The text is passed as one argument / a JSON field (no shell), so game input is never injected.",
  example = "speak(\"hello there\", \"af_heart\", nil, \"kokoro\", \"Samantha\")" })
doc("speech_stop", { sig = "speech_stop()", group = "speech",
  text = "Cancel the current utterance and flush the speech queue (kills afplay and abandons any in-flight kokoro request)." })
doc("speech_voices", { sig = "speech_voices([all]) -> array", group = "speech",
  text = "The available macOS `say` voices as { name=, locale= } entries (English-only unless all is truthy)." })
doc("speech_kokoro_voices", { sig = "speech_kokoro_voices() -> array", group = "speech",
  text = "The local Kokoro server's voice ids (e.g. af_heart, am_adam) as an array of strings; empty if the server is unreachable." })
doc("speech_backend", { sig = "speech_backend() -> (backend, detail)", group = "speech",
  text = "The effective TTS backend (\"kokoro\" or \"say\") and a human status string. A kokoro preference reports \"say\" while a fallback cooldown is active (server unreachable)." })
doc("is_live", { sig = "is_live() -> bool", group = "speech",
  text = "True only while the host is processing lines from the LIVE connection right now; false during replay() and outside a live batch. Guard live-only reactions (like speech) with this so replayed history is never re-acted-on." })

doc(voice.on, { name = "voice.on", sig = "voice.on()", group = "speech",
  text = "Enable text-to-speech for live in-game chat (tells, says, and channels)." })
doc(voice.off, { name = "voice.off", sig = "voice.off()", group = "speech",
  text = "Disable text-to-speech." })
doc(voice.list, { name = "voice.list", sig = "voice.list()", group = "speech",
  text = "List every known speaker and its per-backend voice (say + kokoro; your own character is keyed \"you\")." })
doc(voice.set, { name = "voice.set", sig = "voice.set(name, voice)", group = "speech",
  text = "Pin a speaker to a specific voice for the ACTIVE backend (a Kokoro id like af_heart, or a say voice name). The other backend's assignment is untouched. Persisted.",
  example = "voice.set(\"Mouserat\", \"am_adam\")" })
doc(voice.test, { name = "voice.test", sig = "voice.test([voice])", group = "speech",
  text = "Speak a sample sentence in the given voice (or an auto-picked one) through the active backend to audition it.",
  example = "voice.test(\"af_heart\")" })
doc(voice.backend, { name = "voice.backend", sig = "voice.backend([\"kokoro\"|\"say\"])", group = "speech",
  text = "Report (no arg) or switch the preferred TTS backend. \"kokoro\" uses the local server with an automatic say fallback; \"say\" forces macOS say. Persisted.",
  example = "voice.backend(\"kokoro\")" })
doc(voice.forget, { name = "voice.forget", sig = "voice.forget(name)", group = "speech",
  text = "Drop a speaker's saved voices (both backends) so they are reassigned on next sighting." })
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
  elseif verb == "backend" then voice.backend(arg ~= "" and arg or nil)
  elseif verb == "forget" then voice.forget(arg)
  elseif verb == "mute" then voice.mute(tonumber(arg))
  else echo("[voice] usage: voice.on() | off() | list() | set(name,voice) | test(voice) | backend(k/say) | forget(name) | mute(s)  (help(voice))") end
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
  active_backend = active_backend,
  voice_gender = voice_gender,
  build_say_pool = build_say_pool,
  build_kokoro_pool = build_kokoro_pool,
  say_base = say_base,
  -- Force both pools to a known state for deterministic pool/assignment cases.
  ensure_pools = function() say_pool = nil; kokoro_pool = nil; ensure_pools() end,
  set_pool = function(p) say_pool = p end,                       -- back-compat: sets the say pool
  set_pools = function(s, k) say_pool = s; kokoro_pool = k end,   -- nil clears (rebuild on next use)
  ser = ser,
  norm = norm,
  is_muted = is_muted,
  state = S,
  cfg = cfg,
}

load_saved()
