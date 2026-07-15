




























local function boot(name) pcall(require, name) end
boot("_persist"); if not __persist then dofile("Scripts/_persist.lua") end
local persist = __persist























local cfg = {
   enabled = false,
   rate = nil,
   connect_mute = 4,



   backend = "kokoro",




   dedupe_window = 180,
   dedupe_max = 200,








   emote_style = "narrate",
   home = os.getenv("HOME") or "",


   speak_names = {
      gossip = true, chat = true, auction = true, newbie = true, yell = true, shout = true,
      gtell = true, say = false, tell = false,
   },



   classify = {
      enabled = true,
      max_tokens = 4,
      think_prefill = "<think>\n\n</think>\n\n",
      model = os.getenv("SPEECH_MODEL") or os.getenv("EQ_MODEL") or "qwen3.6-27b-mlx@8bit",
   },
}
cfg.dir = cfg.home .. "/Documents/MudClient"
cfg.save_file = cfg.dir .. "/speech_voices.lua"




















_SPEECH = _SPEECH or {
   enabled = cfg.enabled,
   backend = cfg.backend,
   speakers = {},
   spoken = {},
   classified = {},
   connect_at = nil,
   mute_until = nil,
   loaded = false,
}
_SPEECH.epoch = (_SPEECH.epoch or 0) + 1
local EPOCH = _SPEECH.epoch
local S = _SPEECH


S.recent, S.recent_q = {}, {}


if S.emote_style == nil then S.emote_style = (S.emotes == false) and "off" or cfg.emote_style end
S.emotes = nil

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function norm(s) return (trim(s):lower():gsub("%s+", " ")) end




local save_timer
local function save_now()
   (persist).save(cfg.save_file, { speakers = S.speakers, backend = S.backend })
end

local function schedule_save()
   if cancel and save_timer then cancel(save_timer) end
   if after then save_timer = after(2, save_now) else save_now() end
end
local function load_saved()
   if S.loaded then return end
   S.loaded = true
   local t = persist.load(cfg.save_file)
   if type(t) == "table" then
      local speakers = t.speakers
      if type(speakers) == "table" then
         for k, v in pairs(speakers) do
            if S.speakers[k] == nil then


               if type(v) == "string" then S.speakers[k] = { say = v }
               elseif type(v) == "table" then S.speakers[k] = v end
            end
         end
      end
      local backend = t.backend
      if backend == "say" or backend == "kokoro" then
         S.backend = backend
      end
   end
end











local SELF_VERBS = { say = "say", gossip = "gossip", chat = "chat", auction = "auction",
yell = "yell", shout = "shout", newbie = "newbie", }


local CHAN_VERBS = { gossips = "gossip", chats = "chat", auctions = "auction", yells = "yell",
shouts = "shout", newbies = "newbie", says = "say", }



local INTERSTITIAL = { " looks you over and", " looks at you and", " glances at you and",
" turns to you and", " smiles at you and", " grins at you and", " peers at you and",
" nods at you and", " gazes at you and", " looks up at you and", }
local function clean_speaker(s)
   local out = trim(s)
   for _, phrase in ipairs(INTERSTITIAL) do
      local i = out:find(phrase, 1, true)
      if i then out = trim(out:sub(1, i - 1)); break end
   end
   return out
end











local function parse_chat(raw)
   local line = trim(raw)
   if line == "" then return nil end

   local tgt, msg = line:match("^You tell (.-), '(.*)'$")
   if tgt then
      if tgt == "the group" then return { speaker = "you", channel = "gtell", message = msg, is_self = true } end
      return { speaker = "you", channel = "tell", message = msg, is_self = true, target = tgt }
   end
   local verb, m2 = line:match("^You (%a+), '(.*)'$")
   if verb and SELF_VERBS[verb] then
      return { speaker = "you", channel = SELF_VERBS[verb], message = m2, is_self = true }
   end

   local who, tmsg = line:match("^(.-) tells you, '(.*)'$")
   if who then return { speaker = clean_speaker(who), channel = "tell", message = tmsg } end
   who, tmsg = line:match("^(.-) tells the group, '(.*)'$")
   if who then return { speaker = clean_speaker(who), channel = "gtell", message = tmsg } end

   local who2, cverb, cmsg = line:match("^(.-) (%a+), '(.*)'$")
   if who2 and CHAN_VERBS[cverb] and trim(who2) ~= "" then
      return { speaker = clean_speaker(who2), channel = CHAN_VERBS[cverb], message = cmsg }
   end
   return nil
end






local function active_backend()
   local pref = S.backend or cfg.backend or "say"
   if pref == "say" then return "say" end
   if speech_backend then
      local ok, b = pcall(speech_backend)
      if ok and (b == "say" or b == "kokoro") then return b end
   end
   return "kokoro"
end






local GENDER_WORDS = {

   woman = "f", women = "f", girl = "f", lady = "f", lass = "f", wench = "f", maid = "f",
   maiden = "f", barmaid = "f", milkmaid = "f", witch = "f", hag = "f", crone = "f", matron = "f",
   mother = "f", grandmother = "f", grandma = "f", granny = "f", sister = "f", daughter = "f",
   wife = "f", widow = "f", mistress = "f", dame = "f", madam = "f", madame = "f", nun = "f",
   abbess = "f", priestess = "f", sorceress = "f", enchantress = "f", seamstress = "f",
   huntress = "f", queen = "f", princess = "f", duchess = "f", countess = "f", baroness = "f",
   empress = "f", goddess = "f", she = "f",

   man = "m", men = "m", boy = "m", lad = "m", guy = "m", lord = "m", sir = "m", mister = "m",
   gentleman = "m", monk = "m", friar = "m", father = "m", grandfather = "m", grandpa = "m",
   brother = "m", son = "m", husband = "m", widower = "m", priest = "m", wizard = "m",
   sorcerer = "m", king = "m", prince = "m", duke = "m", count = "m", baron = "m", emperor = "m",
   he = "m",
}


local function gender_from_name(name)
   for w in tostring(name or ""):lower():gmatch("%a+") do
      local g = GENDER_WORDS[w]
      if g then return g end
   end
   return nil
end




local VOICE_GENDER = {
   Alex = "m", Fred = "m", Daniel = "m", Tom = "m", Aaron = "m", Albert = "m", Bruce = "m",
   Junior = "m", Ralph = "m", Rishi = "m", Gordon = "m", Lee = "m", Oliver = "m", Reed = "m",
   Samantha = "f", Victoria = "f", Karen = "f", Moira = "f", Tessa = "f", Fiona = "f", Kate = "f",
   Serena = "f", Allison = "f", Ava = "f", Susan = "f", Vicki = "f", Zoe = "f", Nicky = "f",
   Kathy = "f", Sandy = "f", Shelley = "f", Tara = "f", Stephanie = "f", Matilda = "f", Isha = "f",
   Nora = "f", Amira = "f",
}



local SAY_NOVELTY = {
   Albert = true, ["Bad News"] = true, Bahh = true, Bells = true, Boing = true, Bubbles = true,
   Cellos = true, Wobble = true, ["Good News"] = true, Jester = true, Organ = true, Superstar = true,
   Trinoids = true, Whisper = true, Zarvox = true, Deranged = true, Hysterical = true,
   ["Pipe Organ"] = true, Junior = true, Grandma = true, Grandpa = true, Eddy = true, Flo = true,
   Reed = true, Rocko = true, Sandy = true, Shelley = true,
}



local SAY_PREFERRED = {
   Samantha = true, Alex = true, Ava = true, Allison = true, Susan = true, Zoe = true, Nicky = true,
   Vicki = true, Victoria = true, Kate = true, Serena = true, Fiona = true, Tessa = true, Karen = true,
   Moira = true, Tom = true, Aaron = true, Daniel = true, Rishi = true, Tara = true, Kathy = true,
   Oliver = true, Stephanie = true, Matilda = true, Isha = true, Nora = true, Fred = true,
}



local KOKORO_FALLBACK = {
   "af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky", "af_nova", "af_aoede", "af_kore",
   "af_alloy", "af_jessica", "af_river",
   "am_adam", "am_michael", "am_liam", "am_echo", "am_eric", "am_onyx", "am_puck", "am_fenrir",
   "bf_emma", "bf_alice", "bf_isabella", "bf_lily",
   "bm_george", "bm_daniel", "bm_lewis", "bm_fable",
}









local KOKORO_EXCLUDE = { am_santa = true }
local KOKORO_TIER = {

   am_onyx = 1, bm_george = 1, am_michael = 1, am_fenrir = 1, bm_fable = 1,
   af_heart = 1, af_bella = 1, bf_emma = 1, af_kore = 1, af_aoede = 1,

   bm_lewis = 2, bm_daniel = 2, am_puck = 2,
   bf_isabella = 2, bf_alice = 2, af_nova = 2, af_nicole = 2, af_sarah = 2,


}




local SAY_TIER = {
   Daniel = 1, Moira = 1, Tessa = 1, Serena = 1, Oliver = 1, Fiona = 1,
   Samantha = 2, Karen = 2, Alex = 2, Ava = 2, Tom = 2, Rishi = 2, Tara = 2, Victoria = 2,
   Kate = 2, Allison = 2, Susan = 2, Aaron = 2, Matilda = 2, Isha = 2, Nora = 2, Stephanie = 2,

}





local YOU_POOL = {
   kokoro = { "am_onyx", "bm_george", "am_michael", "am_fenrir" },
   say = { "Daniel", "Oliver", "Tom", "Alex", "Rishi" },
}


local function say_base(name) return (tostring(name):gsub("%s*%b()", ""):gsub("%s+$", "")) end

local function say_rank(name)
   if name:find("Premium") then return 3 elseif name:find("Enhanced") then return 2 else return 1 end
end

local say_pool
local kokoro_pool



local function build_say_pool()
   local names = {}
   if speech_voices then
      local ok, list = pcall(speech_voices)
      if ok and type(list) == "table" then
         for _, v in ipairs(list) do
            local nm = (type(v) == "table") and v.name or v
            if type(nm) == "string" and nm ~= "" then names[#names + 1] = nm end
         end
      end
   end

   local best = {}
   for _, nm in ipairs(names) do
      local b = say_base(nm)
      if not SAY_NOVELTY[b] then
         if not best[b] or say_rank(nm) > say_rank(best[b]) then best[b] = nm end
      end
   end
   local preferred = {}
   local other = {}
   for b, full in pairs(best) do
      if SAY_PREFERRED[b] then preferred[#preferred + 1] = full else other[#other + 1] = full end
   end
   table.sort(preferred); table.sort(other)
   local pool = preferred
   if #pool < 2 then for _, n in ipairs(other) do pool[#pool + 1] = n end end
   if #pool == 0 then pool = { "Samantha", "Daniel", "Karen", "Rishi", "Moira", "Tessa" } end
   return pool
end



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



local function voice_gender(backend, voicename)
   if not voicename then return nil end
   if backend == "kokoro" then
      local g = tostring(voicename):sub(2, 2)
      if g == "f" then return "f" elseif g == "m" then return "m" end
      return nil
   end
   return VOICE_GENDER[say_base(voicename)]
end


local function used_count(voicename, backend)
   local n = 0
   for _, rec in pairs(S.speakers) do
      if type(rec) == "table" and rec[backend] == voicename then n = n + 1 end
   end
   return n
end


local function voice_tier(backend, voicename)
   if backend == "kokoro" then return KOKORO_TIER[voicename] or 3 end
   return SAY_TIER[say_base(voicename)] or 3
end








local function pick_candidates(gender, backend)
   local be = backend or active_backend()
   local all = pool_for(be)
   local pool = {}
   if gender then
      for _, name in ipairs(all) do if voice_gender(be, name) == gender then pool[#pool + 1] = name end end
   end
   if #pool == 0 then pool = all end
   local best = {}
   local bests = nil
   for _, name in ipairs(pool) do
      local s = used_count(name, be) * 100 + voice_tier(be, name)
      if not bests or s < bests then best, bests = { name }, s
      elseif s == bests then best[#best + 1] = name end
   end
   return best
end




local function pick_voice(gender, backend)
   local c = pick_candidates(gender, backend)
   if #c == 0 then return nil end
   return c[math.random(#c)]
end






local function classify_gender(name, context, cb)
   if not (cfg.classify.enabled and ai_local_request) then return cb(nil) end
   local sys = "You classify characters from a fantasy MUD by apparent gender. You are given a " ..
   "character or mob's full display name (it may include a title or epithet, e.g. 'Gisco the " ..
   "Necromancer', 'a fruit vendor') and possibly a line they said. Reply with EXACTLY ONE letter: " ..
   "M for male, F for female, or U if genuinely unknowable. Output nothing else."
   local user = "Name: " .. tostring(name)
   if type(context) == "string" and context ~= "" then
      user = user .. "\nThey said: \"" .. context:sub(1, 120) .. "\""
   end
   local epoch = EPOCH
   ai_local_request(sys, user, cfg.classify.max_tokens, cfg.classify.think_prefill,
   function(reply, err)
      if EPOCH ~= _SPEECH.epoch or epoch ~= _SPEECH.epoch then return end
      if err then return cb(nil) end
      local g = tostring(reply or ""):upper():match("[MFU]")
      if g == "M" then cb("m") elseif g == "F" then cb("f") else cb(nil) end
   end, cfg.classify.model)
end




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








local function assign_voice(key, display, backend, context)
   local be = backend or active_backend()
   local rec = S.speakers[key]
   if rec and rec[be] then return rec[be] end
   local v
   if key == "you" then
      v = pick_you_voice(be)
   else
      local heur = gender_from_name(display)
      if heur then
         v = pick_voice(heur, be)
         S.classified[key] = true
      else
         v = pick_voice(nil, be)
      end
   end
   rec = rec or {}; rec[be] = v; S.speakers[key] = rec
   schedule_save()
   if key ~= "you" and display and display ~= "" and not S.classified[key] then
      S.classified[key] = true
      classify_gender(display, context, function(gender)
         if not gender then return end
         if S.spoken[key] then return end
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

      local rearmed = false
      for i = 1, #q do if q[i] == old then rearmed = true; break end end
      if not rearmed then S.recent[old] = nil end
   end
end

local function clear_dedupe() S.recent, S.recent_q = {}, {} end




local SOCIAL_BASES = { "chuckle", "laugh", "giggle", "snicker", "cackle", "sigh", "groan", "gasp",
"cry", "scream", "snort", }




local SOCIAL_SOUNDS = {
   chuckle = "ha ha", laugh = "ha ha ha!", giggle = "hee hee", sigh = "ohh...",
   groan = "ugh", gasp = "ah!", cry = "oh no", scream = "aah!",
}

local SOCIAL_VERBS = {}
local SOCIAL_THIRD = {}
for _, base in ipairs(SOCIAL_BASES) do
   local third = (base == "cry") and "cries" or (base .. "s")
   SOCIAL_VERBS[third] = base
   SOCIAL_THIRD[base] = third
end




local function social_tail_ok(rest)
   if rest == "" then return true end
   local tail = rest:match("^ ([%a' ]+)$")
   if not tail then return false end
   local n = 0
   for _ in tail:gmatch("%S+") do n = n + 1 end
   return n <= 3
end













local function parse_social(raw)
   local line = trim(raw)
   if line == "" or line:find("'", 1, true) then return nil end
   local body = line:match("^(.-)[.!]$")
   if not body or body:find("[.!,]") then return nil end

   local verb, rest = body:match("^You (%a+)(.*)$")
   if verb and SOCIAL_THIRD[verb] and social_tail_ok(rest) then
      return { speaker = "you", verb = verb, tail = trim(rest), is_self = true }
   end

   for third, base in pairs(SOCIAL_VERBS) do
      local who, rest2 = body:match("^(.-) " .. third .. "(.*)$")
      if who and trim(who) ~= "" and social_tail_ok(rest2 or "") then
         return { speaker = trim(who), verb = base, tail = trim(rest2 or "") }
      end
   end
   return nil
end





local function is_emoticon_token(t)
   if t:match("^[:;=8Xx][%-'^o]*[%)%(DdPpOo03/\\|%*%]%[<>]+$") then return true end
   if t:match("^</?3+$") then return true end
   if t:match("^[Xx][Dd]+$") then return true end
   if t == "^^" or t == "^_^" or t == "-_-" or t == "-.-" or t == "T_T" or
      t == "o.O" or t == "O.o" or t == "\\o/" then       return true end
   return false
end

local function clean_spoken_text(msg)
   local m = tostring(msg or "")
   m = m:gsub("\240\159[\128-\191][\128-\191]", "")
   m = m:gsub("\226[\152-\158][\128-\191]", "")
   m = m:gsub("\239\184\143", "")
   m = m:gsub("\226\128\141", "")
   local parts = {}
   for tok in m:gmatch("%S+") do
      if not is_emoticon_token(tok) then parts[#parts + 1] = tok end
   end
   return table.concat(parts, " ")
end


local function is_muted()
   local now = os.time()
   if S.mute_until and now < S.mute_until then return true end
   if S.connect_at and (now - S.connect_at) < cfg.connect_mute then return true end
   return false
end


local function speak_line(line)
   if not S.enabled then return end


   if is_live and not is_live() then return end
   if is_muted() then return end
   local c = parse_chat(line)
   if not c or not c.message or trim(c.message) == "" then return end
   local key = c.is_self and "you" or norm(c.speaker)
   if key == "" then return end
   local display = c.is_self and nil or c.speaker

   local msg = clean_spoken_text(trim(c.message))
   if msg == "" then return end


   if recently_spoken(key, msg) then return end
   local backend = active_backend()



   local voicename = assign_voice(key, display, backend, msg)
   local say_fallback = (backend == "kokoro") and assign_voice(key, display, "say", msg) or nil
   S.spoken[key] = true
   record_spoken(key, msg)
   local text = msg
   if cfg.speak_names[c.channel] then
      local nm = c.is_self and ((state and state.name) or "You") or c.speaker
      text = nm .. ": " .. text
   end
   if speak then speak(text, voicename, cfg.rate, backend, say_fallback) end
end






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
   if not text then
      text = SOCIAL_THIRD[e.verb]
      if e.tail and e.tail ~= "" then text = text .. " " .. e.tail end
      text = text:lower()
   end
   local display = e.is_self and nil or e.speaker
   local backend = active_backend()
   local voicename = assign_voice(key, display, backend, nil)
   local say_fallback = (backend == "kokoro") and assign_voice(key, display, "say", nil) or nil
   S.spoken[key] = true
   record_spoken(key, "emote:" .. e.verb)
   if speak then speak(text, voicename, cfg.rate, backend, say_fallback) end
end





trigger("^You (say|gossip|chat|auction|yell|shout|newbie|tell)\\b" ..
"|(?:tells you|tells the group|gossips|chats|auctions|yells|shouts|newbies|says), '",
function(line) speak_line(line) end)



trigger("\\b(?:chuckles?|laughs?|giggles?|snickers?|cackles?|sighs?|groans?|gasps?|cry|cries|screams?|snorts?)\\b",
function(line) speak_emote(line) end)




local prev_on_connect = on_connect
function on_connect()
   S.connect_at = os.time()
   if type(prev_on_connect) == "function" then prev_on_connect() end
end





















voice = {}

function voice.on() S.enabled = true; echo("[voice] ON — speaking live chat") end
function voice.off() S.enabled = false; echo("[voice] OFF") end



function voice.backend(b)
   if b == nil or b == "" then
      local eff = active_backend()
      local detail = ""
      if speech_backend then local ok, _, d = pcall(speech_backend); if ok and d then detail = " (" .. d .. ")" end end
      return echo(string.format("[voice] backend pref=%s · active=%s%s", S.backend or cfg.backend, eff, detail))
   end
   local bl = tostring(b):lower()
   if bl ~= "kokoro" and bl ~= "say" then
      return echo("[voice] usage: voice.backend(\"kokoro\" | \"say\")", "yellow")
   end
   S.backend = bl
   schedule_save()
   echo(string.format("[voice] backend -> %s (active=%s)", bl, active_backend()))
end

function voice.list()
   local rows = {}
   local n = 0
   for k, rec in pairs(S.speakers) do rows[#rows + 1] = { k = k, rec = rec }; n = n + 1 end
   table.sort(rows, function(a, b) return a.k < b.k end)
   local eff = active_backend()
   echo(string.format("[voice] %s · backend=%s · %d speaker(s)", S.enabled and "ON" or "OFF", eff, n))
   for _, r in ipairs(rows) do
      local rec = r.rec or {}
      echo(string.format("  %-20s say=%-16s kokoro=%s", r.k, tostring(rec.say or "-"), tostring(rec.kokoro or "-")))
   end
end



function voice.set(name, v)
   if not (type(name) == "string") or not (type(v) == "string") or name == "" or v == "" then
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
   local vv = (type(v) == "string" and v ~= "") and v or pick_voice(nil, backend)
   local fallback = (backend == "kokoro") and pick_voice(nil, "say") or nil
   if speak then speak("The quick brown fox jumps over the lazy dog.", vv, cfg.rate, backend, fallback) end
   echo(string.format("[voice] testing %s (%s)", tostring(vv), backend))
end

function voice.forget(name)
   if not (type(name) == "string") or name == "" then return echo("[voice] usage: voice.forget(\"name\")", "yellow") end
   local key = norm(name)
   S.speakers[key] = nil; S.spoken[key] = nil; S.classified[key] = nil
   schedule_save()
   echo("[voice] forgot " .. key)
end




function voice.reset()
   local n = 0
   for _ in pairs(S.speakers) do n = n + 1 end
   S.speakers = {}; S.spoken = {}; S.classified = {}
   clear_dedupe()
   save_now()
   echo(string.format("[voice] reset — dropped %d speaker assignment(s) (say + kokoro); fresh voices on next sighting", n))
end



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
   local secs = tonumber(seconds) or 10
   S.mute_until = os.time() + secs
   if speech_stop then speech_stop() end
   echo(string.format("[voice] muted for %d s", secs))
end




doc("speak", { sig = "speak(text[, voice[, rate[, backend[, say_fallback]]]])", group = "speech",
text = "Speak text aloud (SpeechService). backend is \"kokoro\" (local mlx-audio server) or \"say\" (macOS, default); voice is the voice for that backend (a Kokoro id like af_heart, or a say voice name); rate is words/min (say only). say_fallback names the say voice used if a kokoro synth fails (the host falls back transparently and arms a cooldown). Queued FIFO; a chat flood drops the oldest unspoken line. The text is passed as one argument / a JSON field (no shell), so game input is never injected.",
example = "speak(\"hello there\", \"af_heart\", nil, \"kokoro\", \"Samantha\")", })
doc("speech_stop", { sig = "speech_stop()", group = "speech",
text = "Cancel the current utterance and flush the speech queue (kills afplay and abandons any in-flight kokoro request).", })
doc("speech_voices", { sig = "speech_voices([all]) -> array", group = "speech",
text = "The available macOS `say` voices as { name=, locale= } entries (English-only unless all is truthy).", })
doc("speech_kokoro_voices", { sig = "speech_kokoro_voices() -> array", group = "speech",
text = "The local Kokoro server's voice ids (e.g. af_heart, am_adam) as an array of strings; empty if the server is unreachable.", })
doc("speech_backend", { sig = "speech_backend() -> (backend, detail)", group = "speech",
text = "The effective TTS backend (\"kokoro\" or \"say\") and a human status string. A kokoro preference reports \"say\" while a fallback cooldown is active (server unreachable).", })
doc("is_live", { sig = "is_live() -> bool", group = "speech",
text = "True only while the host is processing lines from the LIVE connection right now; false during replay() and outside a live batch. Guard live-only reactions (like speech) with this so replayed history is never re-acted-on.", })

doc(voice.on, { name = "voice.on", sig = "voice.on()", group = "speech",
text = "Enable text-to-speech for live in-game chat (tells, says, and channels).", })
doc(voice.off, { name = "voice.off", sig = "voice.off()", group = "speech",
text = "Disable text-to-speech.", })
doc(voice.list, { name = "voice.list", sig = "voice.list()", group = "speech",
text = "List every known speaker and its per-backend voice (say + kokoro; your own character is keyed \"you\").", })
doc(voice.set, { name = "voice.set", sig = "voice.set(name, voice)", group = "speech",
text = "Pin a speaker to a specific voice for the ACTIVE backend (a Kokoro id like af_heart, or a say voice name). The other backend's assignment is untouched. Persisted.",
example = "voice.set(\"Mouserat\", \"am_adam\")", })
doc(voice.test, { name = "voice.test", sig = "voice.test([voice])", group = "speech",
text = "Speak a sample sentence in the given voice (or an auto-picked one) through the active backend to audition it.",
example = "voice.test(\"af_heart\")", })
doc(voice.backend, { name = "voice.backend", sig = "voice.backend([\"kokoro\"|\"say\"])", group = "speech",
text = "Report (no arg) or switch the preferred TTS backend. \"kokoro\" uses the local server with an automatic say fallback; \"say\" forces macOS say. Persisted.",
example = "voice.backend(\"kokoro\")", })
doc(voice.forget, { name = "voice.forget", sig = "voice.forget(name)", group = "speech",
text = "Drop a speaker's saved voices (both backends) so they are reassigned on next sighting.", })
doc(voice.reset, { name = "voice.reset", sig = "voice.reset()", group = "speech",
text = "Wipe ALL speaker voice assignments (say + kokoro), in memory and on disk, plus the recently-spoken dedupe memory. Every speaker gets a fresh pick from the current voice pools the next time they speak.",
example = "voice.reset()", })
doc(voice.emotes, { name = "voice.emotes", sig = "voice.emotes([\"narrate\"|\"sound\"|\"off\"])", group = "speech",
text = "How curated socials (chuckle/laugh/giggle/snicker/cackle/sigh/groan/gasp/cry/scream/snort) are spoken, in the emoter's voice. \"narrate\" (default): the short verb phrase — \"chuckles\", \"sighs somberly\". \"sound\": vetted onomatopoeia (\"ha ha ha!\", \"ugh\"); verbs with no natural sound narrate instead. \"off\": silent. Legacy \"on\" maps to narrate. No arg reports the current mode. Non-vocal socials and free-form emotes are never spoken.",
example = "voice.emotes(\"sound\")", })
doc(voice.mute, { name = "voice.mute", sig = "voice.mute([seconds])", group = "speech",
text = "Silence speech for N seconds (default 10) and flush anything queued. Handy during a flood.",
example = "voice.mute(30)", })


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
end, })



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

   ensure_pools = function() say_pool = nil; kokoro_pool = nil; ensure_pools() end,
   set_pool = function(p) say_pool = p end,
   set_pools = function(s, k) say_pool = s; kokoro_pool = k end,
   ser = function(v) return ((persist).serialize(v):gsub("^return ", "")) end,
   norm = norm,
   is_muted = is_muted,
   state = S,
   cfg = cfg,
}

load_saved()
