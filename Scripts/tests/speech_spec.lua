-- Specs for Speech.lua — chat parsing, per-speaker voice assignment, live-vs-history gating, and the
-- optional LLM gender classification contract. Pure helpers are reached through _SPEECH_TEST; the
-- speaking path is driven by stubbing the global `speak`/`is_live`/`ai_local_request` builtins.

local T = _SPEECH_TEST
local S = T.state

-- Reset the registry + session bookkeeping to a known state before an assignment/speak case.
local function reset()
  S.speakers = {}; S.spoken = {}; S.classified = {}
  S.enabled = true; S.connect_at = nil; S.mute_until = nil
  T.cfg.classify.enabled = false          -- default OFF for deterministic assignment cases
  T.set_pool(nil)                          -- fall back to the built-in default pool unless a case sets one
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

-- ---------------------------------------------------------------- voice assignment
test("assignment: first sighting assigns a voice, then it is stable", function()
  reset(); T.set_pool({ "Alex", "Samantha", "Daniel" })
  local v1 = T.assign_voice("mouserat", "Mouserat")
  expect(type(v1)):eq("string")
  local v2 = T.assign_voice("mouserat", "Mouserat")
  expect(v2):eq(v1)                       -- same voice on re-sighting
end)

test("assignment: round-robins by least-used and reuses on exhaustion", function()
  reset(); T.set_pool({ "Alex", "Samantha" })
  local a = T.assign_voice("s1", "s1")
  local b = T.assign_voice("s2", "s2")
  expect(a):ne(b)                          -- distinct while voices remain
  local c = T.assign_voice("s3", "s3")     -- pool exhausted -> reuse least-used (first)
  expect(c):eq("Alex")
end)

test("assignment: set / forget", function()
  reset()
  S.speakers[T.norm("Bob")] = "Alex"
  expect(S.speakers["bob"]):eq("Alex")
  S.speakers["bob"] = nil
  expect(S.speakers["bob"]):eq(nil)
end)

test("persistence: serialize -> reload round-trips the registry", function()
  reset()
  S.speakers = { mouserat = "Daniel", ["a fruit vendor"] = "Fred" }
  local blob = T.ser({ speakers = S.speakers })
  local t = loadchunk("return " .. blob)()
  expect(t.speakers.mouserat):eq("Daniel")
  expect(t.speakers["a fruit vendor"]):eq("Fred")
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
  reset(); T.cfg.classify.enabled = true; T.set_pool({ "Alex", "Samantha" })   -- Alex=m, Samantha=f
  local real = ai_local_request
  ai_local_request = function(_, _, _, _, cb) cb("F", nil) end                  -- classifier says female
  local v = T.assign_voice("gwen", "Gwen")                                      -- provisional = Alex
  expect(S.speakers["gwen"]):eq("Samantha")                                     -- upgraded to a female voice
  ai_local_request = real
end)

test("classify: garbage / error falls back silently to the provisional voice", function()
  reset(); T.cfg.classify.enabled = true; T.set_pool({ "Alex", "Samantha" })
  local real = ai_local_request
  ai_local_request = function(_, _, _, _, cb) cb("purple monkey", nil) end       -- unparseable
  local v = T.assign_voice("zed", "Zed")
  expect(S.speakers["zed"]):eq(v)                                               -- unchanged
  ai_local_request = function(_, _, _, _, cb) cb(nil, "timeout") end             -- error path
  local v2 = T.assign_voice("qux", "Qux")
  expect(S.speakers["qux"]):eq(v2)
  ai_local_request = real
end)

test("classify: does NOT reassign a speaker already heard this session", function()
  reset(); T.cfg.classify.enabled = true; T.set_pool({ "Alex", "Samantha" })
  local real = ai_local_request
  ai_local_request = function(_, _, _, _, cb) cb("F", nil) end
  S.spoken["gwen"] = true                                                       -- already heard
  local v = T.assign_voice("gwen", "Gwen")
  expect(S.speakers["gwen"]):eq(v)                                              -- keeps provisional
  expect(S.speakers["gwen"]):ne("Samantha")
  ai_local_request = real
end)
