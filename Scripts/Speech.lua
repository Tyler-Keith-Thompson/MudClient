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
-- Repeats: an identical (speaker, message) pair is never spoken twice within cfg.dedupe_window — this
-- silences the game's `replay` command (whose output is byte-identical to live chat). Curated socials
-- ("Mouserat chuckles.") speak in the emoter's voice — narrated verb phrase by default, vetted
-- onomatopoeia in "sound" mode (voice.emotes). Emoji/emoticons are stripped before anything is spoken.
--
-- Controls: voice.on()/off() · voice.list() · voice.set("name","af_heart") · voice.test("af_heart") ·
-- voice.backend("kokoro"|"say") · voice.forget("name") · voice.reset() · voice.emotes("on"|"off") ·
-- voice.mute(seconds); `help(voice)`. Hot-reloadable: edit + pilot.reload().

local cfg = {
  enabled = true,            -- speak by default; voice.off() to silence
  rate = nil,                -- words/min for `say` (nil = system default; ignored by kokoro)
  connect_mute = 4,          -- seconds after a connect to stay silent (login/MOTD burst)
  -- Preferred TTS backend. "kokoro" = the local mlx-audio server (tools/tts/), with an automatic `say`
  -- fallback whenever it's unreachable (the Swift host arms a cooldown and re-probes); "say" forces
  -- macOS `say`. Runtime-switchable + persisted via voice.backend("kokoro"|"say").
  backend = "kokoro",
  -- Never speak an identical (speaker, message) pair twice within this window. This is what silences
  -- the game's `replay` command: replayed channel lines are BYTE-IDENTICAL to the live ones (verified
  -- against human-traces.jsonl — no prefix/timestamp distinguishes them), so shape-detection is
  -- impossible and recency-dedupe is the correct gate. Bounded LRU (dedupe_max entries).
  dedupe_window = 180,
  dedupe_max = 200,
  -- How curated socials are spoken (voice.emotes to switch):
  --   "narrate" (default) — speak the emote as short narration in the emoter's voice: just the verb
  --                         phrase, lowercase ("chuckles", "sighs somberly"). Plain words, so TTS
  --                         pronunciation can never sound broken.
  --   "sound"             — onomatopoeia mode ("ha ha ha!", "ugh"): only empirically TTS-friendly
  --                         renderings; verbs with no natural-sounding form narrate instead.
  --   "off"               — socials are silent.
  -- Non-vocal socials (waves, nods) and free-form emotes never speak in any mode.
  emote_style = "narrate",
  home = os.getenv("HOME") or "",
  -- Say the speaker's name before the message on these channels (public chatter reads better with an
  -- attribution; private tells/says are quieter without one). Keyed by canonical channel.
  speak_names = {
    gossip = true, chat = true, auction = true, newbie = true, yell = true, shout = true,
    gtell = true, say = false, tell = false,
  },
  -- Optional LLM gender classification for a better first voice. NEVER blocks speech, and only runs
  -- for names the cheap gendered-word heuristic can't resolve. Uses the smarter dense 27b via the
  -- per-REQUEST model override (same pattern as Equipment.lua), so pinned models stay undisturbed.
  classify = {
    enabled = true,
    max_tokens = 4,
    think_prefill = "<think>\n\n</think>\n\n",   -- same Qwen3.x empty-think guard trivia/pilot use
    model = os.getenv("SPEECH_MODEL") or os.getenv("EQ_MODEL") or "qwen3.6-27b-mlx@8bit",
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
-- Recently-spoken dedupe LRU: sig -> os.time(), plus an insertion-order queue for the size cap.
-- Deliberately reset on EVERY (re)load — a reload should never carry over suppression state.
S.recent, S.recent_q = {}, {}
-- Emote style survives reload (kept in S, seeded from cfg the first time). Migrates the old boolean
-- S.emotes from a pre-style session: false -> "off", true/absent -> the cfg default.
if S.emote_style == nil then S.emote_style = (S.emotes == false) and "off" or cfg.emote_style end
S.emotes = nil

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

-- ============================ gender heuristic (no LLM) ============================
-- AlterAeon speaker names constantly carry explicit gender words ("An orc woman", "Priest of Xandar",
-- "the barmaid", "orc mother", "hedge wizard" — all verbatim from human-traces.jsonl). Exact WHOLE-WORD
-- lookup, so suffix traps are safe by construction: "priestess" is its own word (female) and never
-- falls through to "priest" (male). Curated; anything unlisted resolves nil and may go to the LLM.
local GENDER_WORDS = {
  -- female
  woman = "f", women = "f", girl = "f", lady = "f", lass = "f", wench = "f", maid = "f",
  maiden = "f", barmaid = "f", milkmaid = "f", witch = "f", hag = "f", crone = "f", matron = "f",
  mother = "f", grandmother = "f", grandma = "f", granny = "f", sister = "f", daughter = "f",
  wife = "f", widow = "f", mistress = "f", dame = "f", madam = "f", madame = "f", nun = "f",
  abbess = "f", priestess = "f", sorceress = "f", enchantress = "f", seamstress = "f",
  huntress = "f", queen = "f", princess = "f", duchess = "f", countess = "f", baroness = "f",
  empress = "f", goddess = "f", she = "f",
  -- male
  man = "m", men = "m", boy = "m", lad = "m", guy = "m", lord = "m", sir = "m", mister = "m",
  gentleman = "m", monk = "m", friar = "m", father = "m", grandfather = "m", grandpa = "m",
  brother = "m", son = "m", husband = "m", widower = "m", priest = "m", wizard = "m",
  sorcerer = "m", king = "m", prince = "m", duke = "m", count = "m", baron = "m", emperor = "m",
  he = "m",
}

-- gender_from_name(name) -> "m" | "f" | nil. First gendered word wins, scanning left to right.
local function gender_from_name(name)
  for w in tostring(name or ""):lower():gmatch("%a+") do
    local g = GENDER_WORDS[w]
    if g then return g end
  end
  return nil
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

-- ---- fantasy/epic preference tiers ----
-- Tier 1 = dramatic, fantasy-appropriate (assigned first); tier 2 = decent; tier 3 = flat/thin. Kokoro
-- tiers combine the repo VOICES.md quality grades (af_heart=A, af_bella=A-, bf_emma=B-, am_fenrir/
-- am_michael/af_kore/af_aoede=C+…) with TIMBRE: am_onyx is the DEEP male (OpenAI-style naming —
-- onyx = deep — outweighs its D grade for epic flavor), bm_george the deeper British male, am_michael
-- solid mid, am_fenrir dramatic; bm_fable is a lighter, androgynous "storyteller" — kept in tier 1 for
-- variety but NOT the deep-male default. British voices skew epic (bf_emma, bf_isabella).
-- am_santa is EXCLUDED outright (this is fantasy, not Christmas).
local KOKORO_EXCLUDE = { am_santa = true }
local KOKORO_TIER = {
  -- tier 1 — epic
  am_onyx = 1, bm_george = 1, am_michael = 1, am_fenrir = 1, bm_fable = 1,
  af_heart = 1, af_bella = 1, bf_emma = 1, af_kore = 1, af_aoede = 1,
  -- tier 2 — solid
  bm_lewis = 2, bm_daniel = 2, am_puck = 2,
  bf_isabella = 2, bf_alice = 2, af_nova = 2, af_nicole = 2, af_sarah = 2,
  -- everything else (am_adam, am_eric, am_echo, am_liam, af_jessica, af_river, af_sky, af_alloy,
  -- bf_lily, unknown future ids) defaults to tier 3.
}
-- Say voices, same idea lighter-touch (by BASE name, within the existing curated allowlist): the
-- deeper/theatrical accents first. On this machine `say -v ?` offers Daniel (GB), Moira (IE),
-- Tessa (ZA), Rishi, Tara, Samantha, Karen, Kathy, Fred — tiers cover the wider allowlist so richer
-- voice sets (Premium/Enhanced installs) rank sensibly too.
local SAY_TIER = {
  Daniel = 1, Moira = 1, Tessa = 1, Serena = 1, Oliver = 1, Fiona = 1,
  Samantha = 2, Karen = 2, Alex = 2, Ava = 2, Tom = 2, Rishi = 2, Tara = 2, Victoria = 2,
  Kate = 2, Allison = 2, Susan = 2, Aaron = 2, Matilda = 2, Isha = 2, Nora = 2, Stephanie = 2,
  -- unlisted (Kathy, Fred, Vicki, Zoe, Nicky…) -> tier 3
}

-- Your OWN character's default candidates when no gender can be resolved from the character name
-- (e.g. "Vaelith"): the DEEP-male/epic set per backend (the user's evident preference — a necromancer
-- should not sound like af_jessica), drawn RANDOMLY so voice.reset() re-rolls "you" too. am_onyx leads
-- (the deep male); bm_fable deliberately absent (lighter/androgynous). Override with voice.set("you",…).
local YOU_POOL = {
  kokoro = { "am_onyx", "bm_george", "am_michael", "am_fenrir" },
  say = { "Daniel", "Oliver", "Tom", "Alex", "Rishi" },
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

-- Build the KOKORO pool: the server's English (a_/b_) voice ids minus the exclusions (am_santa),
-- else the curated fallback.
local function build_kokoro_pool()
  local pool = {}
  if speech_kokoro_voices then
    local ok, list = pcall(speech_kokoro_voices)
    if ok and type(list) == "table" then
      for _, id in ipairs(list) do
        if type(id) == "string" and id:match("^[ab][fm]_") and not KOKORO_EXCLUDE[id] then
          pool[#pool + 1] = id
        end
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

-- Fantasy-preference tier of a voice (1 epic .. 3 flat). Say voices rank by BASE name.
local function voice_tier(backend, voice)
  if backend == "kokoro" then return KOKORO_TIER[voice] or 3 end
  return SAY_TIER[say_base(voice)] or 3
end

-- The ELIGIBLE candidate set for a new assignment: WEIGHTED least-used with a fantasy/epic tier
-- preference. Candidates come from the gender pool ("m"/"f"); gender nil / "U" uses the NEUTRAL mixed
-- pool (every voice, so an unresolved speaker draws evenly rather than skewing one gender's epic
-- voices). Score is used_count*100 + tier; ALL minimum-score voices are returned — so the first
-- speakers land in tier 1 (least-used within the tier), and as speakers multiply we SPILL to lower
-- tiers before reusing anyone (30 speakers still get variety; the first dozen get the epic voices).
-- Pure and deterministic (unit-tested); the random draw lives in pick_voice.
local function pick_candidates(gender, backend)
  backend = backend or active_backend()
  local all = pool_for(backend)
  local pool = {}
  if gender then
    for _, name in ipairs(all) do if voice_gender(backend, name) == gender then pool[#pool + 1] = name end end
  end
  if #pool == 0 then pool = all end
  local best, bests = {}, nil
  for _, name in ipairs(pool) do
    local s = used_count(name, backend) * 100 + voice_tier(backend, name)
    if not bests or s < bests then best, bests = { name }, s
    elseif s == bests then best[#best + 1] = name end
  end
  return best
end

-- Pick a voice: a RANDOM draw among the equally-eligible candidates. The randomness is at ASSIGNMENT
-- time only (the persisted assignment stays stable afterward) — it exists so voice.reset() genuinely
-- re-rolls instead of deterministically re-deriving the identical voice for every speaker.
local function pick_voice(gender, backend)
  local c = pick_candidates(gender, backend)
  if #c == 0 then return nil end
  return c[math.random(#c)]
end

-- Ask the LOCAL model to classify a name male/female — only reached when gender_from_name() found no
-- explicit gender word. The FULL display name (title included: "Gisco the Necromancer", not "Gisco")
-- and, when available, the line they just said are passed as context; strict one-letter contract; any
-- error, timeout, or garbage falls back silently to cb(nil). Never blocks — the caller has already
-- assigned a voice. Uses the dense 27b via ai_local_request's per-call model override (EQ pattern).
local function classify_gender(name, context, cb)
  if not (cfg.classify.enabled and ai_local_request) then return cb(nil) end
  local sys = "You classify characters from a fantasy MUD by apparent gender. You are given a "
    .. "character or mob's full display name (it may include a title or epithet, e.g. 'Gisco the "
    .. "Necromancer', 'a fruit vendor') and possibly a line they said. Reply with EXACTLY ONE letter: "
    .. "M for male, F for female, or U if genuinely unknowable. Output nothing else."
  local user = "Name: " .. name
  if type(context) == "string" and context ~= "" then
    user = user .. "\nThey said: \"" .. context:sub(1, 120) .. "\""
  end
  local epoch = EPOCH
  ai_local_request(sys, user, cfg.classify.max_tokens, cfg.classify.think_prefill,
    function(reply, err)
      if EPOCH ~= _SPEECH.epoch or epoch ~= _SPEECH.epoch then return end   -- reloaded: drop stale
      if err then return cb(nil) end
      local g = tostring(reply or ""):upper():match("[MFU]")
      if g == "M" then cb("m") elseif g == "F" then cb("f") else cb(nil) end
    end, cfg.classify.model)
end

-- The voice for YOUR OWN character: gendered pick if the character's NAME resolves via the heuristic,
-- else a random draw from the deep-male/epic YOU_POOL (intersected with the live pool; falls back to a
-- male pick if none of the preferred ids are available).
local function pick_you_voice(backend)
  local g = gender_from_name((state and state.name) or "")
  if g then return pick_voice(g, backend) end
  local avail = {}
  for _, n in ipairs(pool_for(backend)) do avail[n] = true end
  local c = {}
  for _, n in ipairs(YOU_POOL[backend] or {}) do if avail[n] then c[#c + 1] = n end end
  if #c > 0 then return c[math.random(#c)] end
  return pick_voice("m", backend)
end

-- assign_voice(key, display, backend[, context]) -> voice for that backend. Returns the speaker's
-- existing per-backend voice, or picks (and persists) one on first sighting for that backend.
-- Gender is resolved in LAYERS: (1) the FREE gendered-word heuristic on the display name ("An orc
-- woman" — no LLM call at all); (2) otherwise a provisional neutral pick IMMEDIATELY plus an async LLM
-- classify (full display name + optionally the line they said as `context`) that upgrades EVERY
-- assigned backend's voice iff the speaker hasn't been heard yet. Assignments for both backends are
-- kept side by side, so switching backends never loses the other's voice.
local function assign_voice(key, display, backend, context)
  backend = backend or active_backend()
  local rec = S.speakers[key]
  if rec and rec[backend] then return rec[backend] end
  local v
  if key == "you" then
    v = pick_you_voice(backend)
  else
    local heur = gender_from_name(display)
    if heur then
      v = pick_voice(heur, backend)
      S.classified[key] = true                     -- decided for free — never ask the LLM
    else
      v = pick_voice(nil, backend)                 -- neutral/mixed provisional
    end
  end
  rec = rec or {}; rec[backend] = v; S.speakers[key] = rec
  schedule_save()
  if key ~= "you" and display and display ~= "" and not S.classified[key] then
    S.classified[key] = true
    classify_gender(display, context, function(gender)
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

-- ============================ recently-spoken dedupe ============================
-- Never speak an identical (speaker, message) pair twice within cfg.dedupe_window seconds. This is the
-- defense against the game's `replay` command (replayed lines are indistinguishable from live ones) and
-- against any other repeat vector. Bounded: at most cfg.dedupe_max remembered pairs (oldest evicted).
local function dedupe_sig(key, text) return key .. "\0" .. text end

local function recently_spoken(key, text)
  local t = S.recent[dedupe_sig(key, text)]
  return t ~= nil and (os.time() - t) < cfg.dedupe_window
end

local function record_spoken(key, text)
  local sig = dedupe_sig(key, text)
  S.recent[sig] = os.time()
  local q = S.recent_q
  q[#q + 1] = sig
  while #q > cfg.dedupe_max do
    local old = table.remove(q, 1)
    -- Only drop the map entry if no NEWER queue slot re-armed the same sig.
    local rearmed = false
    for i = 1, #q do if q[i] == old then rearmed = true; break end end
    if not rearmed then S.recent[old] = nil end
  end
end

local function clear_dedupe() S.recent, S.recent_q = {}, {} end

-- ============================ socials / emotes ============================
-- Curated VOCALIZABLE socials. Anything not listed (waves, nods, dances, free-form emote text) is
-- deliberately silent — an emote line can say literally anything.
local SOCIAL_BASES = { "chuckle", "laugh", "giggle", "snicker", "cackle", "sigh", "groan", "gasp",
                       "cry", "scream", "snort" }
-- "sound"-mode onomatopoeia, EMPIRICALLY vetted against the Kokoro server (real-word-ish forms render
-- naturally; spelled interjections like "heh heh"/"hmph"/"aaaah!" come out as stilted literal
-- pronunciation). Verbs with no natural-sounding form are ABSENT here and fall back to narration even
-- in sound mode (snicker, cackle, snort).
local SOCIAL_SOUNDS = {
  chuckle = "ha ha", laugh = "ha ha ha!", giggle = "hee hee", sigh = "ohh...",
  groan = "ugh", gasp = "ah!", cry = "oh no", scream = "aah!",
}
-- Third-person verb form maps: "chuckles" -> "chuckle" (parse) and "chuckle" -> "chuckles" (narrate).
local SOCIAL_VERBS, SOCIAL_THIRD = {}, {}
for _, base in ipairs(SOCIAL_BASES) do
  local third = (base == "cry") and "cries" or (base .. "s")
  SOCIAL_VERBS[third] = base
  SOCIAL_THIRD[base] = third
end

-- A social line's tail after the verb: empty, or a SHORT unpunctuated clause ("somberly", "out loud",
-- "at you"). Anything longer/with punctuation is a mob-flavor or combat sentence that merely CONTAINS
-- a social verb ("A mindless zombie groans as it shuffles slowly towards you.") — rejected.
local function social_tail_ok(rest)
  if rest == "" then return true end
  local tail = rest:match("^ ([%a' ]+)$")
  if not tail then return false end
  local n = 0
  for _ in tail:gmatch("%S+") do n = n + 1 end
  return n <= 3
end

-- parse_social(line) -> { speaker, verb, tail, is_self } for a curated-social line, else nil. Anchored
-- on the verbatim wire shapes from human-traces.jsonl: "You chuckle." · "You laugh out loud." ·
-- "Mario sighs somberly." · "A baby water elemental giggles." — and rejects quoted lines
-- ("You scream '…'"), long clauses, and non-vocal socials. `tail` is the short trailing clause
-- ("out loud", "somberly", "at Lokar"; possibly ""), used by narrate mode. Pure (unit-tested).
local function parse_social(line)
  line = trim(line)
  if line == "" or line:find("'", 1, true) then return nil end   -- quoted = speech, not a social
  local body = line:match("^(.-)[.!]$")
  if not body or body:find("[.!,]") then return nil end          -- one short sentence only
  -- Your own: "You chuckle[ tail]"
  local verb, rest = body:match("^You (%a+)(.*)$")
  if verb and SOCIAL_THIRD[verb] and social_tail_ok(rest) then
    return { speaker = "you", verb = verb, tail = trim(rest), is_self = true }
  end
  -- Third person: "<Name> <verbs>[ tail]" — the name may be multi-word ("A baby water elemental").
  for third, base in pairs(SOCIAL_VERBS) do
    local who, rest2 = body:match("^(.-) " .. third .. "(.*)$")
    if who and trim(who) ~= "" and social_tail_ok(rest2 or "") then
      return { speaker = trim(who), verb = base, tail = trim(rest2 or "") }
    end
  end
  return nil
end

-- ============================ emoji / emoticon hygiene ============================
-- Chat is full of "gratz! :)" and "nice one 🎉" — TTS pronouncing ":)" or an emoji codepoint sounds
-- broken. Strip unicode emoji (byte-range match on the UTF-8 sequences) and whole ASCII-emoticon
-- tokens, collapsing whitespace. A message that was ONLY emoji/emoticons cleans to "" (caller skips it).
local function is_emoticon_token(t)
  if t:match("^[:;=8Xx][%-'^o]*[%)%(DdPpOo03/\\|%*%]%[<>]+$") then return true end -- :) ;-P =D x) :'( :/ :3
  if t:match("^</?3+$") then return true end                                        -- <3 </3 <33
  if t:match("^[Xx][Dd]+$") then return true end                                    -- xD XD xDD
  if t == "^^" or t == "^_^" or t == "-_-" or t == "-.-" or t == "T_T"
     or t == "o.O" or t == "O.o" or t == "\\o/" then return true end
  return false
end

local function clean_spoken_text(msg)
  msg = tostring(msg or "")
  msg = msg:gsub("\240\159[\128-\191][\128-\191]", "")   -- U+1F000–1FFFF: emoji, incl. skin tones
  msg = msg:gsub("\226[\152-\158][\128-\191]", "")        -- U+2600–27BF: misc symbols, ❤, ✨, ☀ …
  msg = msg:gsub("\239\184\143", "")                       -- U+FE0F variation selector
  msg = msg:gsub("\226\128\141", "")                       -- U+200D zero-width joiner
  local parts = {}
  for tok in msg:gmatch("%S+") do
    if not is_emoticon_token(tok) then parts[#parts + 1] = tok end
  end
  return table.concat(parts, " ")                          -- also collapses doubled spaces
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
  -- Emoji/emoticon hygiene: "gratz! :)" speaks as "gratz!"; an all-emoji message speaks not at all.
  local msg = clean_spoken_text(trim(c.message))
  if msg == "" then return end
  -- Recency dedupe: an identical (speaker, message) pair within the window is a repeat — most notably
  -- the game's `replay` command re-printing recent channel history in the exact live format.
  if recently_spoken(key, msg) then return end
  local backend = active_backend()
  -- Primary voice for the active backend; when kokoro, also resolve a `say` voice so the host's
  -- transparent fallback (server unreachable) keeps this speaker sounding consistent. The message is
  -- passed as classifier context (a line of dialogue often disambiguates an androgynous name).
  local voice = assign_voice(key, display, backend, msg)
  local say_fallback = (backend == "kokoro") and assign_voice(key, display, "say", msg) or nil
  S.spoken[key] = true
  record_spoken(key, msg)
  local text = msg
  if cfg.speak_names[c.channel] then
    local nm = c.is_self and ((state and state.name) or "You") or c.speaker
    text = nm .. ": " .. text
  end
  if speak then speak(text, voice, cfg.rate, backend, say_fallback) end
end

-- The gate every social/emote-shaped line passes through. Depending on S.emote_style, speaks either a
-- short NARRATION in the emoter's voice ("chuckles", "sighs somberly" — the verb phrase, no name: the
-- voice identity already says who) or, in "sound" mode, a vetted onomatopoeia (narrating any verb with
-- no natural sound). Same live/mute/dedupe gates as chat (a chuckle in replayed history or a repeated
-- chuckle within the window stays silent).
local function speak_emote(line)
  local style = S.emote_style or cfg.emote_style
  if not S.enabled or style == "off" then return end
  if is_live and not is_live() then return end
  if is_muted() then return end
  local e = parse_social(line)
  if not e then return end
  local key = e.is_self and "you" or norm(e.speaker)
  if key == "" then return end
  if recently_spoken(key, "emote:" .. e.verb) then return end
  local text = (style == "sound") and SOCIAL_SOUNDS[e.verb] or nil
  if not text then                                        -- narrate mode, or no vetted sound
    text = SOCIAL_THIRD[e.verb]
    if e.tail and e.tail ~= "" then text = text .. " " .. e.tail end
    text = text:lower()
  end
  local display = e.is_self and nil or e.speaker
  local backend = active_backend()
  local voice = assign_voice(key, display, backend)
  local say_fallback = (backend == "kokoro") and assign_voice(key, display, "say") or nil
  S.spoken[key] = true
  record_spoken(key, "emote:" .. e.verb)
  if speak then speak(text, voice, cfg.rate, backend, say_fallback) end
end

-- ============================ triggers ============================
-- One broad trigger fires for any chat-shaped line; parse_chat is the real, exact gate (a non-chat
-- quoted line — combat, emotes, signs — parses to nil and never speaks). Regexes run in the Swift
-- engine and aren't unit-testable; speak_line/parse_chat (the pure helpers) are.
trigger("^You (say|gossip|chat|auction|yell|shout|newbie|tell)\\b"
  .. "|(?:tells you|tells the group|gossips|chats|auctions|yells|shouts|newbies|says), '",
  function(line) speak_line(line) end)

-- Socials: broad verb-match trigger; parse_social is the exact gate (rejects quoted lines, long
-- mob-flavor clauses, and any verb not in the curated vocal set).
trigger("\\b(?:chuckles?|laughs?|giggles?|snickers?|cackles?|sighs?|groans?|gasps?|cry|cries|screams?|snorts?)\\b",
  function(line) speak_emote(line) end)

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

-- Wipe EVERY speaker's voice assignment (both backends), the session bookkeeping, and the dedupe
-- memory, and persist the now-empty registry immediately. Each speaker gets a fresh pick from the
-- CURRENT pools the next time they speak.
function voice.reset()
  local n = 0
  for _ in pairs(S.speakers) do n = n + 1 end
  S.speakers = {}; S.spoken = {}; S.classified = {}
  clear_dedupe()
  save_now()
  echo(string.format("[voice] reset — dropped %d speaker assignment(s) (say + kokoro); fresh voices on next sighting", n))
end

-- Set (or report) how curated socials are spoken: "narrate" (verb phrase, default), "sound"
-- (vetted onomatopoeia), or "off". Legacy on/off still work: on -> narrate, off -> off.
function voice.emotes(v)
  if v == nil or v == "" then
    return echo("[voice] emotes: " .. (S.emote_style or cfg.emote_style))
  end
  local m = tostring(v):lower()
  if m == "on" or m == "true" then m = "narrate" end
  if m == "false" then m = "off" end
  if m ~= "narrate" and m ~= "sound" and m ~= "off" then
    return echo("[voice] usage: voice.emotes(\"narrate\" | \"sound\" | \"off\")", "yellow")
  end
  S.emote_style = m
  echo("[voice] emotes: " .. m)
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
doc(voice.reset, { name = "voice.reset", sig = "voice.reset()", group = "speech",
  text = "Wipe ALL speaker voice assignments (say + kokoro), in memory and on disk, plus the recently-spoken dedupe memory. Every speaker gets a fresh pick from the current voice pools the next time they speak.",
  example = "voice.reset()" })
doc(voice.emotes, { name = "voice.emotes", sig = "voice.emotes([\"narrate\"|\"sound\"|\"off\"])", group = "speech",
  text = "How curated socials (chuckle/laugh/giggle/snicker/cackle/sigh/groan/gasp/cry/scream/snort) are spoken, in the emoter's voice. \"narrate\" (default): the short verb phrase — \"chuckles\", \"sighs somberly\". \"sound\": vetted onomatopoeia (\"ha ha ha!\", \"ugh\"); verbs with no natural sound narrate instead. \"off\": silent. Legacy \"on\" maps to narrate. No arg reports the current mode. Non-vocal socials and free-form emotes are never spoken.",
  example = "voice.emotes(\"sound\")" })
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
  elseif verb == "reset" then voice.reset()
  elseif verb == "emotes" then voice.emotes(arg ~= "" and arg or nil)
  elseif verb == "mute" then voice.mute(tonumber(arg))
  else echo("[voice] usage: voice.on() | off() | list() | set(name,voice) | test(voice) | backend(k/say) | forget(name) | reset() | emotes(on/off) | mute(s)  (help(voice))") end
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
  speak_emote = speak_emote,
  parse_social = parse_social,
  social_third = SOCIAL_THIRD,
  clean_spoken_text = clean_spoken_text,
  gender_from_name = gender_from_name,
  pick_candidates = pick_candidates,
  pick_you_voice = pick_you_voice,
  voice_tier = voice_tier,
  you_pool = YOU_POOL,
  social_sounds = SOCIAL_SOUNDS,
  social_verbs = SOCIAL_VERBS,
  recently_spoken = recently_spoken,
  record_spoken = record_spoken,
  clear_dedupe = clear_dedupe,
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
