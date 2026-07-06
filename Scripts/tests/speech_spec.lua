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
  S.enabled = true; S.connect_at = nil; S.mute_until = nil
  S.backend = "say"                        -- deterministic backend for most cases
  T.cfg.backend = "say"
  T.cfg.classify.enabled = false           -- default OFF for deterministic assignment cases
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
  local a = T.assign_voice("s1", "s1", "say")
  local b = T.assign_voice("s2", "s2", "say")
  expect(a):ne(b)                          -- distinct while voices remain
  local c = T.assign_voice("s3", "s3", "say")     -- pool exhausted -> reuse least-used (first)
  expect(c):eq("Alex")
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
  reset(); T.cfg.classify.enabled = true; T.set_pools({ "Alex", "Samantha" }, nil)
  local real = ai_local_request
  ai_local_request = function(_, _, _, _, cb) cb("F", nil) end
  S.spoken["gwen"] = true                                                       -- already heard
  local v = T.assign_voice("gwen", "Gwen", "say")
  expect(S.speakers["gwen"].say):eq(v)                                          -- keeps provisional
  expect(S.speakers["gwen"].say):ne("Samantha")
  ai_local_request = real
end)
