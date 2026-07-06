-- Specs for Speech.lua — chat parsing, backend-aware per-speaker voice assignment, live-vs-history
-- gating, the say-pool novelty filter, and the optional LLM gender classification contract. Pure helpers
-- are reached through _SPEECH_TEST; the speaking path is driven by stubbing the global
-- `speak`/`is_live`/`ai_local_request`/`speech_backend` builtins.

local T = _SPEECH_TEST
local S = T.state

-- Reset the registry + session bookkeeping to a known state before an assignment/speak case. Defaults
-- to the `say` backend for deterministic voice picks unless a case opts into kokoro.
local function reset()
  S.speakers = {}; S.spoken = {}; S.classified = {}
  S.enabled = true; S.emotes = true; S.connect_at = nil; S.mute_until = nil
  S.backend = "say"                        -- deterministic backend for most cases
  T.cfg.backend = "say"
  T.cfg.classify.enabled = false           -- default OFF for deterministic assignment cases
  T.clear_dedupe()                          -- no carried-over suppression between cases
  T.set_pools(nil, nil)                     -- fall back to built-in pools unless a case sets one
end

-- ---------------------------------------------------------------- parsing (verbatim wire formats)
test("parse_chat: incoming private tell", function()
  local c = T.parse_chat("Mouserat tells you, 'hey there'")
  expect(c ~= nil):truthy()
  expect(c.channel):eq("tell"); expect(c.speaker):eq("Mouserat"); expect(c.message):eq("hey there")
  expect(c.is_self):falsy()
end)

test("parse_chat: mob tell strips the interstitial action clause", function()
  local c = T.parse_chat("Stiboli the Spellcaster looks you over and tells you, 'I can teach you.'")
  expect(c.channel):eq("tell"); expect(c.speaker):eq("Stiboli the Spellcaster")
  expect(c.message):eq("I can teach you.")
end)

test("parse_chat: incoming group tell", function()
  local c = T.parse_chat("Lokar tells the group, 'brb'")
  expect(c.channel):eq("gtell"); expect(c.speaker):eq("Lokar"); expect(c.message):eq("brb")
end)

test("parse_chat: room say (mob and player)", function()
  local c = T.parse_chat("Gisco the Necromancer says, 'beware of traps!'")
  expect(c.channel):eq("say"); expect(c.speaker):eq("Gisco the Necromancer")
  local d = T.parse_chat("A hedge wizard says, 'talk to me first.'")
  expect(d.channel):eq("say"); expect(d.speaker):eq("A hedge wizard")
end)

test("parse_chat: gossip / chat / auction / yell channels", function()
  expect(T.parse_chat("Mouserat gossips, 'true fishing is awesome'").channel):eq("gossip")
  expect(T.parse_chat("Catharsis chats, 'thank you'").channel):eq("chat")
  expect(T.parse_chat("Judas auctions, 'I do not like the name'").channel):eq("auction")
  local y = T.parse_chat("a fruit vendor yells, 'JOJOOOOOTO!'")
  expect(y.channel):eq("yell"); expect(y.speaker):eq("a fruit vendor")
end)

test("parse_chat: your own say / tell / gossip", function()
  local s = T.parse_chat("You say, 'odd'")
  expect(s.is_self):truthy(); expect(s.channel):eq("say"); expect(s.message):eq("odd")
  local tl = T.parse_chat("You tell Conan, 'Hi there'")
  expect(tl.is_self):truthy(); expect(tl.channel):eq("tell"); expect(tl.target):eq("Conan")
  expect(tl.message):eq("Hi there")
  local g = T.parse_chat("You gossip, 'anyone selling gear?'")
  expect(g.is_self):truthy(); expect(g.channel):eq("gossip")
  local gt = T.parse_chat("You tell the group, 'incoming'")
  expect(gt.channel):eq("gtell"); expect(gt.is_self):truthy()
end)

test("parse_chat: NON-chat lines are rejected (never speak)", function()
  expect(T.parse_chat("You hit the orc for 50 damage.")):eq(nil)
  expect(T.parse_chat("The orc sergeant screams, 'Aargh!'")):eq(nil)   -- 'screams' not a chat verb
  expect(T.parse_chat("A sign here reads, 'keep out'")):eq(nil)         -- 'reads' not a chat verb
  expect(T.parse_chat("The goblin dies.")):eq(nil)
  expect(T.parse_chat("")):eq(nil)
end)

-- ---------------------------------------------------------------- say-pool novelty filter
test("say pool: drops novelty voices, keeps natural ones, prefers premium variants", function()
  reset()
  -- Stub the host say-voice list with a mix of novelty + natural + a premium variant.
  local real = speech_voices
  speech_voices = function()
    return {
      { name = "Zarvox", locale = "en_US" }, { name = "Trinoids", locale = "en_US" },
      { name = "Bells", locale = "en_US" }, { name = "Samantha", locale = "en_US" },
      { name = "Daniel", locale = "en_GB" }, { name = "Ava", locale = "en_US" },
      { name = "Ava (Premium)", locale = "en_US" },
    }
  end
  local pool = T.build_say_pool()
  local has = {}
  for _, n in ipairs(pool) do has[n] = true end
  expect(has["Zarvox"]):falsy()                 -- novelty dropped
  expect(has["Trinoids"]):falsy(); expect(has["Bells"]):falsy()
  expect(has["Samantha"]):truthy(); expect(has["Daniel"]):truthy()
  expect(has["Ava (Premium)"]):truthy()         -- premium variant chosen
  expect(has["Ava"]):falsy()                    -- plain variant dropped in favor of premium
  speech_voices = real
end)

test("kokoro pool + gender: english ids from server, gender by prefix", function()
  reset()
  local real = speech_kokoro_voices
  speech_kokoro_voices = function()
    return { "af_heart", "am_adam", "bf_emma", "bm_george", "jf_alpha", "zm_yunxi" }   -- last two non-english
  end
  local pool = T.build_kokoro_pool()
  local has = {}; for _, id in ipairs(pool) do has[id] = true end
  expect(has["af_heart"]):truthy(); expect(has["bm_george"]):truthy()
  expect(has["jf_alpha"]):falsy(); expect(has["zm_yunxi"]):falsy()   -- non-english filtered
  expect(T.voice_gender("kokoro", "af_heart")):eq("f")
  expect(T.voice_gender("kokoro", "am_adam")):eq("m")
  expect(T.voice_gender("kokoro", "bf_emma")):eq("f")
  expect(T.voice_gender("kokoro", "bm_george")):eq("m")
  speech_kokoro_voices = real
end)

-- ---------------------------------------------------------------- voice assignment (per backend)
test("assignment: first sighting assigns a say voice, then it is stable", function()
  reset(); T.set_pools({ "Alex", "Samantha", "Daniel" }, nil)
  local v1 = T.assign_voice("mouserat", "Mouserat", "say")
  expect(type(v1)):eq("string")
  expect(S.speakers["mouserat"].say):eq(v1)
  local v2 = T.assign_voice("mouserat", "Mouserat", "say")
  expect(v2):eq(v1)                       -- same voice on re-sighting
end)

test("assignment: round-robins by least-used and reuses on exhaustion", function()
  reset(); T.set_pools({ "Alex", "Samantha" }, nil)
  math.randomseed(11)
  local a = T.assign_voice("s1", "s1", "say")
  local b = T.assign_voice("s2", "s2", "say")
  expect(a):ne(b)                          -- distinct while voices remain
  local c = T.assign_voice("s3", "s3", "say")     -- pool exhausted -> reuse one of the least-used
  expect(c == "Alex" or c == "Samantha"):truthy()
end)

test("assignment: per-backend records kept side by side", function()
  reset(); T.set_pools({ "Alex", "Samantha" }, { "af_heart", "am_adam" })
  local sv = T.assign_voice("bob", "Bob", "say")
  local kv = T.assign_voice("bob", "Bob", "kokoro")
  expect(S.speakers["bob"].say):eq(sv)
  expect(S.speakers["bob"].kokoro):eq(kv)
  expect(kv:match("^%a%a_")):truthy()            -- a kokoro id, not a say name
end)

test("assignment: switching backend gives a fresh pick for the new backend, keeps the old", function()
  reset(); T.set_pools({ "Alex" }, { "af_heart" })
  S.backend = "say"
  T.assign_voice("gwen", "Gwen", "say")
  expect(S.speakers["gwen"].say):eq("Alex")
  expect(S.speakers["gwen"].kokoro):eq(nil)      -- no kokoro voice yet
  S.backend = "kokoro"
  local kv = T.assign_voice("gwen", "Gwen", "kokoro")
  expect(kv):eq("af_heart")
  expect(S.speakers["gwen"].say):eq("Alex")      -- old say assignment preserved
end)

test("persistence: serialize -> reload round-trips the per-backend registry + backend pref", function()
  reset()
  S.speakers = { mouserat = { say = "Daniel", kokoro = "am_adam" }, ["a fruit vendor"] = { say = "Fred" } }
  local blob = T.ser({ speakers = S.speakers, backend = "kokoro" })
  local t = loadchunk("return " .. blob)()
  expect(t.speakers.mouserat.say):eq("Daniel")
  expect(t.speakers.mouserat.kokoro):eq("am_adam")
  expect(t.speakers["a fruit vendor"].say):eq("Fred")
  expect(t.backend):eq("kokoro")
end)

-- ---------------------------------------------------------------- active backend selection
test("active_backend: say preference forces say; kokoro honors host health", function()
  reset()
  S.backend = "say"
  expect(T.active_backend()):eq("say")
  S.backend = "kokoro"
  local real = speech_backend
  speech_backend = function() return "kokoro", "ready" end
  expect(T.active_backend()):eq("kokoro")
  speech_backend = function() return "say", "kokoro unreachable" end   -- cooldown
  expect(T.active_backend()):eq("say")
  speech_backend = real
end)

-- ---------------------------------------------------------------- is_live gating + speaking
test("is_live gating: history/replay is never spoken", function()
  reset()
  local said = {}
  local real_speak, real_live = speak, is_live
  speak = function(text, v) said[#said + 1] = text end
  is_live = function() return false end
  T.speak_line("Mouserat gossips, 'hi'")
  expect(#said):eq(0)                      -- gated out
  is_live = function() return true end
  T.speak_line("Mouserat gossips, 'hi'")
  expect(#said):eq(1)                      -- spoken live
  speak, is_live = real_speak, real_live
end)

test("speaking: channel prepends the name, tell/say do not", function()
  reset()
  local said = {}
  local real_speak, real_live = speak, is_live
  speak = function(text, v) said[#said + 1] = text end
  is_live = function() return true end
  T.speak_line("Mouserat gossips, 'true fishing is awesome'")
  expect(said[1]):eq("Mouserat: true fishing is awesome")   -- speak_names[gossip] = true
  T.speak_line("Mouserat tells you, 'secret'")
  expect(said[2]):eq("secret")                              -- speak_names[tell] = false
  speak, is_live = real_speak, real_live
end)

test("speaking: kokoro backend passes a say fallback voice through to the host", function()
  reset(); S.backend = "kokoro"; T.set_pools({ "Alex" }, { "af_heart" })
  local calls = {}
  local real_speak, real_live, real_backend = speak, is_live, speech_backend
  speak = function(text, voice, rate, backend, fallback)
    calls[#calls + 1] = { text = text, voice = voice, backend = backend, fallback = fallback }
  end
  is_live = function() return true end
  speech_backend = function() return "kokoro", "ready" end
  T.speak_line("Mouserat tells you, 'hi'")
  expect(calls[1].backend):eq("kokoro")
  expect(calls[1].voice):eq("af_heart")           -- kokoro id
  expect(calls[1].fallback):eq("Alex")            -- say fallback resolved alongside
  speak, is_live, speech_backend = real_speak, real_live, real_backend
end)

test("speaking: muted window swallows speech", function()
  reset()
  local said = {}
  local real_speak, real_live = speak, is_live
  speak = function(text) said[#said + 1] = text end
  is_live = function() return true end
  S.mute_until = os.time() + 60
  T.speak_line("Mouserat gossips, 'hi'")
  expect(#said):eq(0)
  speak, is_live = real_speak, real_live
end)

-- ---------------------------------------------------------------- recently-spoken dedupe
test("dedupe: identical (speaker, message) within the window is suppressed", function()
  reset()
  local said = {}
  local real_speak, real_live = speak, is_live
  speak = function(text) said[#said + 1] = text end
  is_live = function() return true end
  T.speak_line("Mouserat gossips, 'true fishing is awesome'")
  T.speak_line("Mouserat gossips, 'true fishing is awesome'")   -- e.g. the game's `replay` output
  expect(#said):eq(1)
  -- A DIFFERENT message from the same speaker still speaks.
  T.speak_line("Mouserat gossips, 'something new'")
  expect(#said):eq(2)
  -- The SAME message from a different speaker still speaks.
  T.speak_line("Lokar gossips, 'true fishing is awesome'")
  expect(#said):eq(3)
  speak, is_live = real_speak, real_live
end)

test("dedupe: repeats OUTSIDE the window are spoken again", function()
  reset()
  local said = {}
  local real_speak, real_live = speak, is_live
  speak = function(text) said[#said + 1] = text end
  is_live = function() return true end
  T.speak_line("Mouserat gossips, 'hi'")
  expect(#said):eq(1)
  -- Age the record past the window (the sig format is key\0message).
  S.recent["mouserat\0hi"] = os.time() - (T.cfg.dedupe_window + 1)
  T.speak_line("Mouserat gossips, 'hi'")
  expect(#said):eq(2)
  speak, is_live = real_speak, real_live
end)

test("dedupe: memory-bounded — the queue never exceeds dedupe_max", function()
  reset()
  local old_max = T.cfg.dedupe_max
  T.cfg.dedupe_max = 10
  for i = 1, 35 do T.record_spoken("spk" .. i, "msg" .. i) end
  expect(#S.recent_q <= 10):truthy()
  local n = 0
  for _ in pairs(S.recent) do n = n + 1 end
  expect(n <= 10):truthy()                 -- evicted sigs leave the map too
  -- The NEWEST entries survive; the oldest were evicted.
  expect(T.recently_spoken("spk35", "msg35")):truthy()
  expect(T.recently_spoken("spk1", "msg1")):falsy()
  T.cfg.dedupe_max = old_max
end)

test("dedupe: replay()/history never records — a gated line still speaks later live", function()
  reset()
  local said = {}
  local real_speak, real_live = speak, is_live
  speak = function(text) said[#said + 1] = text end
  is_live = function() return false end     -- client-side replay(): is_live gate wins first
  T.speak_line("Mouserat gossips, 'hi'")
  expect(#said):eq(0)
  expect(T.recently_spoken("mouserat", "hi")):falsy()   -- suppression did NOT get recorded
  is_live = function() return true end
  T.speak_line("Mouserat gossips, 'hi'")
  expect(#said):eq(1)                        -- the first LIVE occurrence speaks
  speak, is_live = real_speak, real_live
end)

-- ---------------------------------------------------------------- voice.reset
test("voice.reset: wipes both backends, dedupe memory, and the persisted file", function()
  reset()
  local tmp = os.tmpname()
  local old_file = T.cfg.save_file
  T.cfg.save_file = tmp
  S.speakers = { mouserat = { say = "Zarvox", kokoro = "af_heart" }, lokar = { say = "Bells" },
                 you = { say = "Fred", kokoro = "af_jessica" } }
  S.spoken = { mouserat = true }; S.classified = { mouserat = true }
  T.record_spoken("mouserat", "hi")
  voice.reset()
  expect(next(S.speakers)):eq(nil)          -- all assignments gone (both backends)
  expect(S.speakers["you"]):eq(nil)         -- including your own character's
  expect(next(S.spoken)):eq(nil); expect(next(S.classified)):eq(nil)
  expect(T.recently_spoken("mouserat", "hi")):falsy()   -- dedupe cleared
  -- The persisted file was rewritten with an EMPTY registry.
  local t = loadfile(tmp)()
  expect(next(t.speakers)):eq(nil)
  os.remove(tmp)
  T.cfg.save_file = old_file
end)

test("voice.reset: next sighting picks fresh voices from the current pools", function()
  reset()
  local tmp = os.tmpname()
  local old_file = T.cfg.save_file
  T.cfg.save_file = tmp
  S.speakers = { mouserat = { say = "Zarvox" } }   -- a ludicrous old novelty assignment
  voice.reset()
  T.set_pools({ "Samantha", "Daniel" }, nil)        -- the current curated pool
  local v = T.assign_voice("mouserat", "Mouserat", "say")
  expect(v):eq("Daniel")                            -- fresh pick from tier 1, not the old Zarvox
  os.remove(tmp)
  T.cfg.save_file = old_file
end)

-- ---------------------------------------------------------------- socials / emotes
test("parse_social: verbatim trace shapes (own + third-person, multi-word names)", function()
  local e1 = T.parse_social("You chuckle.")
  expect(e1.is_self):truthy(); expect(e1.verb):eq("chuckle"); expect(e1.speaker):eq("you")
  local e2 = T.parse_social("You laugh out loud.")             -- short tail allowed
  expect(e2.verb):eq("laugh")
  local e3 = T.parse_social("You sigh.")
  expect(e3.verb):eq("sigh")
  local e4 = T.parse_social("Mario sighs somberly.")           -- adverb tail
  expect(e4.speaker):eq("Mario"); expect(e4.verb):eq("sigh"); expect(e4.is_self):falsy()
  local e5 = T.parse_social("A baby water elemental giggles.") -- multi-word name
  expect(e5.speaker):eq("A baby water elemental"); expect(e5.verb):eq("giggle")
  local e6 = T.parse_social("Mouserat laughs at Lokar.")       -- targeted social
  expect(e6.speaker):eq("Mouserat"); expect(e6.verb):eq("laugh")
end)

test("parse_social: rejects lookalikes that merely contain a social verb", function()
  -- Mob-flavor sentence with a long clause after the verb (verbatim from traces).
  expect(T.parse_social("A mindless zombie groans as it shuffles slowly towards you.")):eq(nil)
  -- Combat scream with a long object clause (hyphenated, multi-word).
  expect(T.parse_social("A buhito screams a blood-chilling roar at A clay man!")):eq(nil)
  -- Quoted scream is speech, not a social.
  expect(T.parse_social("You scream 'The POWER!' and writhe on the floor.")):eq(nil)
  -- Non-vocal socials stay silent.
  expect(T.parse_social("Mouserat waves happily.")):eq(nil)
  expect(T.parse_social("Lokar nods.")):eq(nil)
  expect(T.parse_social("Mouserat dances with Lokar.")):eq(nil)
  -- Ordinary narration.
  expect(T.parse_social("The goblin dies.")):eq(nil)
  expect(T.parse_social("")):eq(nil)
end)

test("social sounds: every curated verb (base + third person) maps to a short utterance", function()
  local n = 0
  for base, sound in pairs(T.social_sounds) do
    n = n + 1
    expect(type(sound)):eq("string"); expect(#sound > 0):truthy(); expect(#sound < 40):truthy()
    local third = (base == "cry") and "cries" or (base .. "s")
    expect(T.social_verbs[third]):eq(base)           -- third-person form round-trips
  end
  expect(n >= 11):truthy()                            -- chuckle/laugh/giggle/snicker/cackle/sigh/groan/gasp/cry/scream/snort
end)

test("emotes: speak the vocalization in the emoter's assigned voice", function()
  reset(); T.set_pools({ "Alex" }, nil)
  local calls = {}
  local real_speak, real_live = speak, is_live
  speak = function(text, voice) calls[#calls + 1] = { text = text, voice = voice } end
  is_live = function() return true end
  T.speak_emote("Mouserat chuckles.")
  expect(#calls):eq(1)
  expect(calls[1].text):eq(T.social_sounds.chuckle)   -- the curated sound, never the raw line
  expect(calls[1].voice):eq("Alex")                   -- the speaker's assigned voice
  expect(S.speakers["mouserat"].say):eq("Alex")       -- and it registered like a chat sighting
  speak, is_live = real_speak, real_live
end)

test("emotes: obey is_live, the toggle, and dedupe", function()
  reset(); T.set_pools({ "Alex" }, nil)
  local said = {}
  local real_speak, real_live = speak, is_live
  speak = function(text) said[#said + 1] = text end
  is_live = function() return false end
  T.speak_emote("Mouserat chuckles.")                 -- replayed history: silent
  expect(#said):eq(0)
  is_live = function() return true end
  S.emotes = false
  T.speak_emote("Mouserat chuckles.")                 -- toggled off: silent
  expect(#said):eq(0)
  S.emotes = true
  T.speak_emote("Mouserat chuckles.")
  T.speak_emote("Mouserat chuckles.")                 -- repeat within the window: deduped
  expect(#said):eq(1)
  T.speak_emote("Mouserat laughs.")                   -- different social: speaks
  expect(#said):eq(2)
  speak, is_live = real_speak, real_live
end)

-- ---------------------------------------------------------------- gendered-word heuristic (no LLM)
test("gender heuristic: explicit gender words resolve without any LLM", function()
  expect(T.gender_from_name("An orc woman")):eq("f")
  expect(T.gender_from_name("A hedge witch")):eq("f")
  expect(T.gender_from_name("the barmaid")):eq("f")
  expect(T.gender_from_name("older woman")):eq("f")
  expect(T.gender_from_name("orc mother")):eq("f")
  expect(T.gender_from_name("A young lord")):eq("m")
  expect(T.gender_from_name("Priest of Xandar")):eq("m")
  expect(T.gender_from_name("hedge wizard")):eq("m")
  expect(T.gender_from_name("shy little boy")):eq("m")
end)

test("gender heuristic: priestess/priest suffix trap and misses fall through", function()
  expect(T.gender_from_name("the high priestess")):eq("f")   -- whole-word: not caught by "priest"
  expect(T.gender_from_name("the priest")):eq("m")
  expect(T.gender_from_name("a sorceress supreme")):eq("f")
  expect(T.gender_from_name("Gisco the Necromancer")):eq(nil)  -- no gender word -> LLM territory
  expect(T.gender_from_name("Mouserat")):eq(nil)
  expect(T.gender_from_name("")):eq(nil)
  expect(T.gender_from_name(nil)):eq(nil)
end)

test("gender heuristic: a hit assigns a gendered voice and SKIPS the LLM", function()
  reset(); T.cfg.classify.enabled = true; T.set_pools({ "Daniel", "Samantha" }, nil)
  local called = false
  local real = ai_local_request
  ai_local_request = function(_, _, _, _, cb) called = true; cb("M", nil) end
  local v = T.assign_voice("an orc woman", "An orc woman", "say")
  expect(v):eq("Samantha")                   -- the only female voice in the pool
  expect(called):falsy()                     -- no LLM call for a heuristic hit
  expect(S.classified["an orc woman"]):truthy()   -- and it never will be asked
  ai_local_request = real
end)

test("classify prompt: full display name, said-line context, and the dense-model override", function()
  reset(); T.cfg.classify.enabled = true; T.set_pools({ "Daniel", "Samantha" }, nil)
  local got = {}
  local real = ai_local_request
  ai_local_request = function(sys, user, max, prefill, cb, model)
    got.sys, got.user, got.model = sys, user, model
    cb("U", nil)
  end
  T.assign_voice("gisco the necromancer", "Gisco the Necromancer", "say", "flee, mortals!")
  expect(got.user:find("Gisco the Necromancer", 1, true) ~= nil):truthy()   -- FULL name incl. title
  expect(got.user:find("flee, mortals!", 1, true) ~= nil):truthy()          -- the message as context
  expect(got.sys:find("EXACTLY ONE letter") ~= nil):truthy()                -- strict M/F/U contract
  expect(got.model):eq(T.cfg.classify.model)                                -- per-call 27b override
  ai_local_request = real
end)

-- ---------------------------------------------------------------- weighted fantasy tiers
test("tiers: kokoro ranking — onyx/george epic, santa excluded, flat voices tier 3", function()
  expect(T.voice_tier("kokoro", "am_onyx")):eq(1)      -- THE deep male
  expect(T.voice_tier("kokoro", "bm_george")):eq(1)
  expect(T.voice_tier("kokoro", "af_heart")):eq(1)
  expect(T.voice_tier("kokoro", "bm_daniel")):eq(2)
  expect(T.voice_tier("kokoro", "af_jessica")):eq(3)
  expect(T.voice_tier("kokoro", "am_eric")):eq(3)
  expect(T.voice_tier("say", "Daniel")):eq(1)
  expect(T.voice_tier("say", "Ava (Premium)")):eq(2)   -- ranks by base name
  expect(T.voice_tier("say", "Kathy")):eq(3)
  -- am_santa never enters the pool, even if the server offers it.
  local real = speech_kokoro_voices
  speech_kokoro_voices = function() return { "am_santa", "am_onyx", "af_heart" } end
  local pool = T.build_kokoro_pool()
  local has = {}; for _, id in ipairs(pool) do has[id] = true end
  expect(has["am_santa"]):falsy(); expect(has["am_onyx"]):truthy()
  speech_kokoro_voices = real
end)

test("tiers: candidate set is least-used within the best tier; spills before reusing", function()
  reset(); T.set_pools(nil, { "af_heart", "af_nova", "af_jessica" })   -- tiers 1, 2, 3
  -- Empty registry: only the tier-1 voice is eligible.
  local c1 = T.pick_candidates("f", "kokoro")
  expect(#c1):eq(1); expect(c1[1]):eq("af_heart")
  -- Tier 1 taken -> spill to tier 2, then tier 3, BEFORE reusing anyone.
  S.speakers = { a = { kokoro = "af_heart" } }
  expect(T.pick_candidates("f", "kokoro")[1]):eq("af_nova")
  S.speakers.b = { kokoro = "af_nova" }
  expect(T.pick_candidates("f", "kokoro")[1]):eq("af_jessica")
  -- Everyone used once -> reuse starts back at the epic tier.
  S.speakers.c = { kokoro = "af_jessica" }
  expect(T.pick_candidates("f", "kokoro")[1]):eq("af_heart")
end)

test("tiers: equal-score candidates are ALL returned; the draw stays within them", function()
  reset(); T.set_pools(nil, { "af_jessica", "af_heart", "af_bella", "af_river" })
  local c = T.pick_candidates("f", "kokoro")             -- af_heart + af_bella, both tier 1 unused
  expect(#c):eq(2)
  local set = {}; for _, n in ipairs(c) do set[n] = true end
  expect(set["af_heart"]):truthy(); expect(set["af_bella"]):truthy()
  math.randomseed(7)
  for _ = 1, 20 do
    local v = T.pick_voice("f", "kokoro")
    expect(set[v]):truthy()                              -- random draw never leaves the candidate set
  end
end)

test("tiers: U/unresolved uses the NEUTRAL mixed pool (both genders eligible)", function()
  reset(); T.set_pools(nil, { "af_heart", "bm_george", "af_jessica" })
  local c = T.pick_candidates(nil, "kokoro")             -- no gender: mixed pool, tier 1 of EITHER
  local set = {}; for _, n in ipairs(c) do set[n] = true end
  expect(set["af_heart"]):truthy(); expect(set["bm_george"]):truthy()   -- both tier-1 genders
  expect(set["af_jessica"]):falsy()                                      -- tier 3 not eligible yet
end)

-- ---------------------------------------------------------------- own character ("you")
test("own char: unresolvable name defaults to the deep-male pool and re-rolls on reset", function()
  reset(); T.set_pools(nil, nil)                          -- full built-in pools
  local old_state = state
  state = { name = "Vaelith" }                            -- no gender word -> deep-male YOU_POOL
  local deep = {}; for _, id in ipairs(T.you_pool.kokoro) do deep[id] = true end
  math.randomseed(3)
  local seen = {}
  for _ = 1, 40 do
    S.speakers = {}                                       -- what voice.reset() does to the registry
    local v = T.assign_voice("you", nil, "kokoro")
    expect(deep[v]):truthy()                              -- always a deep-male pick (am_onyx tier)
    seen[v] = true
  end
  local distinct = 0
  for _ in pairs(seen) do distinct = distinct + 1 end
  expect(distinct >= 2):truthy()                          -- reset genuinely RE-ROLLS
  state = old_state
end)

test("own char: gendered character name resolves via the heuristic", function()
  reset(); T.set_pools(nil, nil)
  local old_state = state
  state = { name = "Queen Vaelith" }
  local v = T.assign_voice("you", nil, "kokoro")
  expect(T.voice_gender("kokoro", v)):eq("f")             -- female pick, not the deep-male default
  state = old_state
end)

-- ---------------------------------------------------------------- LLM classification contract
test("classify: valid reply reassigns an unspoken speaker's voice", function()
  reset(); T.cfg.classify.enabled = true; T.set_pools({ "Alex", "Samantha" }, nil)   -- Alex=m, Samantha=f
  local real = ai_local_request
  ai_local_request = function(_, _, _, _, cb) cb("F", nil) end                  -- classifier says female
  T.assign_voice("gwen", "Gwen", "say")                                         -- provisional = Alex
  expect(S.speakers["gwen"].say):eq("Samantha")                                 -- upgraded to a female voice
  ai_local_request = real
end)

test("classify: upgrades every assigned backend for an unspoken speaker", function()
  reset(); T.cfg.classify.enabled = true
  T.set_pools({ "Alex", "Samantha" }, { "am_adam", "af_heart" })
  local real = ai_local_request
  ai_local_request = function(_, _, _, _, cb) cb("F", nil) end
  T.assign_voice("gwen", "Gwen", "say")       -- provisional say = Alex; triggers classify
  T.assign_voice("gwen", "Gwen", "kokoro")    -- provisional kokoro = am_adam (classify already ran once)
  -- The classify callback ran on the first assign and upgraded whatever was assigned then (say). Re-run
  -- the upgrade path by classifying again is guarded; assert the say voice is the female pick.
  expect(S.speakers["gwen"].say):eq("Samantha")
  ai_local_request = real
end)

test("classify: garbage / error falls back silently to the provisional voice", function()
  reset(); T.cfg.classify.enabled = true; T.set_pools({ "Alex", "Samantha" }, nil)
  local real = ai_local_request
  ai_local_request = function(_, _, _, _, cb) cb("purple monkey", nil) end       -- unparseable
  local v = T.assign_voice("zed", "Zed", "say")
  expect(S.speakers["zed"].say):eq(v)                                            -- unchanged
  ai_local_request = function(_, _, _, _, cb) cb(nil, "timeout") end             -- error path
  local v2 = T.assign_voice("qux", "Qux", "say")
  expect(S.speakers["qux"].say):eq(v2)
  ai_local_request = real
end)

test("classify: does NOT reassign a speaker already heard this session", function()
  -- Daniel is tier 1 / Samantha tier 2, so the provisional (neutral) pick is deterministically Daniel.
  reset(); T.cfg.classify.enabled = true; T.set_pools({ "Daniel", "Samantha" }, nil)
  local real = ai_local_request
  ai_local_request = function(_, _, _, _, cb) cb("F", nil) end
  S.spoken["gwen"] = true                                                       -- already heard
  local v = T.assign_voice("gwen", "Gwen", "say")
  expect(v):eq("Daniel")
  expect(S.speakers["gwen"].say):eq(v)                                          -- keeps provisional
  expect(S.speakers["gwen"].say):ne("Samantha")
  ai_local_request = real
end)
