







































local function boot(name) pcall(require, name) end
boot("_rx"); if not __rx then dofile("Scripts/Foundation/_rx.lua") end
boot("_persist"); if not __persist then dofile("Scripts/Foundation/_persist.lua") end
local persist = __persist



local on_trivia_question
local on_trivia_choices
local on_area_line
local collect_line
local on_trivia_reveal
local on_trivia_announce







trigger([[\[event\] trivia question:\s*(.+)]], function(_, q) on_trivia_question(q) end)
trigger([[^\s*(?:Lvl|Grp)\s+\d]], function(line) on_area_line(line) end)


trigger(".+", function(line) collect_line(line) end)
trigger([[\[event\] trivia choices:\s*(.+)]], function(_, c) on_trivia_choices(c) end)

trigger([[\[event\] trivia answer:.*answer is '?(\w)'?]], function(_, rletter) on_trivia_reveal(rletter) end)

trigger([[\[event\] announcement: (.*TRIVIA[^\n]*)]], function(_, msg) on_trivia_announce(msg) end)
















local cfg = {
   enabled = true,
   rag_k = 4,
   area_wait = 1.2,
   lookup_wait = 1.5,
   max_tokens = 12,
   tool_max_tokens = 128,
   home = os.getenv("HOME") or "",


   think_prefill = "<think>\n\n</think>\n\n",




   model = os.getenv("TRIVIA_MODEL") or os.getenv("LMSTUDIO_MODEL") or "qwen3.6-35b-a3b-mlx",
}
cfg.dir = cfg.home .. "/Documents/MudClient"
cfg.cache_file = cfg.dir .. "/trivia_answers.lua"















_TRIVIA = _TRIVIA or { enabled = cfg.enabled, stats = { attempts = 0, correct = 0, learned = 0 } }
_TRIVIA.epoch = (_TRIVIA.epoch or 0) + 1
local EPOCH = _TRIVIA.epoch
local S = _TRIVIA










local T = { q = nil, choices = nil, answered = false, our_letter = nil, source = nil }

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end


local function norm(s) return (trim(s or ""):lower():gsub("%s+", " "):gsub("%.%s*$", "")) end


local cache = {}

local function load_cache()
   local t = persist.load(cfg.cache_file)
   if type(t) == "table" then cache = t end
   local n = 0; for _ in pairs(cache) do n = n + 1 end
   S.stats.learned = n
end



local function save_cache()
   (persist).save(cfg.cache_file, cache)
end









local function parse_choices(s)
   s = trim(s)
   local marks = {}
   for _, L in ipairs({ "A", "B", "C", "D" }) do
      local i = s:find(L .. ":", 1, true)
      if i then marks[#marks + 1] = { L = L:lower(), i = i } end
   end
   table.sort(marks, function(a, b) return a.i < b.i end)
   local out = {}
   for idx, m in ipairs(marks) do
      local body_start = m.i + 2
      local body_end = marks[idx + 1] and (marks[idx + 1].i - 1) or #s
      out[m.L] = norm(s:sub(body_start, body_end))
   end
   return out
end



local function extract_letter(reply)
   reply = reply or ""

   for ch in reply:gmatch("%f[%a](%a)%f[%A]") do
      local u = ch:upper()
      if u:find("^[ABCD]$") then return u:lower() end
   end


   local u = reply:upper():match("([ABCD])[%)%.:]")
   return u and u:lower() or nil
end


local function letter_for_text(choices, answer_text)
   if not choices or not answer_text then return nil end
   for L, body in pairs(choices) do if body == answer_text then return L end end
   return nil
end









local function norm_area(s)
   return (trim(s or ""):lower():gsub("^the%s+", ""):gsub("%s+", " "):gsub("[%.,;:!?]+$", ""))
end



local AREA_STOP = { the = true, of = true, ["and"] = true, a = true, an = true, in_ = true }
local function pick_keyword(name)
   local best = ""
   for w in (name or ""):gmatch("%a+") do
      if not AREA_STOP[w:lower()] and #w > #best then best = w end
   end
   return best ~= "" and best or trim(name or "")
end










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



local function choice_for_level(choices, num, is_group)
   local fallback = nil
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


local CHOICE_LETTERS = { "a", "b", "c", "d" }
math.randomseed(os.time())

local function submit(letter, source)
   T.answered, T.our_letter, T.source = true, letter, source
   send("event answer " .. letter)
   local choice = (T.choices and T.choices[letter]) or "?"
   echo(string.format("\27[1;36m[trivia] answered %s (%s) — %s\27[0m", letter:upper(), choice, source))
end


local function available_letters()
   local ls = {}
   for _, L in ipairs(CHOICE_LETTERS) do if T.choices and T.choices[L] then ls[#ls + 1] = L end end
   return ls
end



local function guess(reason)
   if T.answered then return end
   local ls = available_letters()
   if #ls == 0 then return end
   if reason then echo("\27[33m[trivia] " .. reason .. " — guessing\27[0m") end
   submit(ls[math.random(#ls)], "guess")
end







local TOOLS_JSON = [==[[
{"type":"function","function":{"name":"area_info","description":"Look up an Alter Aeon AREA by name to find its sector/continent and its level. Call this for any question about which sector or continent an area is in, or an area's level.","parameters":{"type":"object","properties":{"area_name":{"type":"string","description":"the area name, e.g. Cliffside Island"}},"required":["area_name"]}}},
{"type":"function","function":{"name":"library_entry","description":"Look up a Great Library ENTRY by its number to get its title and topic. Call this for any question asking what a numbered Great Library entry is.","parameters":{"type":"object","properties":{"entry_number":{"type":"integer","description":"the entry number, e.g. 48043"}},"required":["entry_number"]}}}
]]==]









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




local function tool_command(name, args)
   args = args or {}
   if name == "area_info" and args.area_name and args.area_name ~= "" then
      return "area " .. pick_keyword(args.area_name)
   end
   return nil
end


local TOOL_SOURCE = { area_info = "area", library_entry = "library" }


















local function parse_library_list(out)
   local entries = {}
   for line in (out or ""):gmatch("[^\n]+") do
      local l = line:gsub("\27%[[%d;]*%a", "")
      local num, rest = l:match("^%s*(%d+)%s*%-%s+(.+)$")
      if num then
         local title, topic = rest:match("^(.-)%s%s+Topic:%s*(.+)$")
         if not title then title = rest end
         entries[#entries + 1] = { num = tonumber(num), title = norm(title), topic = norm(topic or "") }
      end
   end
   return entries
end


local function library_title(question)
   local q = question or ""
   return q:match('entitled%s*,?%s*["\'](.-)["\']') or
   q:match('titled%s*,?%s*["\'](.-)["\']') or
   q:match('called%s*,?%s*["\'](.-)["\']')
end


local function library_keyword(question)
   local title = library_title(question)
   if not title then return nil end
   return pick_keyword(title)
end



local function question_book_number(question)
   local q = question or ""
   local n = q:match("[Ee]ntry%s+#?(%d+)") or q:match("[Bb]ook%s+#?(%d+)") or q:match("[Nn]umber%s+#?(%d+)")
   return n and tonumber(n) or nil
end





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
      return nil
   end
   if #entries == 1 then return entries[1].num end
   return nil
end





local function read_book(num)
   if not num then return nil end
   local f = io.open(cfg.dir .. "/books/" .. tostring(num) .. ".txt", "r")
   if not f then return nil end
   local d = f:read("a"); f:close()
   return d
end



local catalog_cache = nil
local function load_catalog()
   if catalog_cache then return catalog_cache end
   local f = io.open(cfg.dir .. "/books_catalog.txt", "r")
   if not f then catalog_cache = {}; return catalog_cache end
   local d = f:read("a"); f:close()
   catalog_cache = parse_library_list(d)
   return catalog_cache
end







local Lib = { read = read_book, catalog = load_catalog }










local CAPTURE_MAX = 40
local rx = __rx








local lineS = rx and rx.subject() or nil
local areaRowS = rx and rx.subject() or nil
local GIVEUP = {}


local function capture_keep(line, cmd)
   local l = trim(line or "")
   if l == "" then return false end
   if l:find("^kxw[tq]_") then return false end
   if l:find("^%[event%]") then return false end
   if cmd and l == trim(cmd) then return false end
   return true
end


collect_line = function(line) if lineS then lineS:onNext(line) end end














local function P(executor)
   local p = __promise and __promise(executor, "trivia-lookup") or nil
   if p and __untrack_promise then __untrack_promise(p) end
   if p and p.__start then p.__start() end
   return p
end
local function rejected(reason) return P(function(_, reject) reject(reason) end) end


local function stale() return EPOCH ~= _TRIVIA.epoch or T.answered end



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
   local sys = "You answer multiple-choice trivia about the MUD 'Alter Aeon'. Use the REFERENCE if it helps. " ..
   "If you can't answer for certain from the reference (e.g. which sector/continent an area is in, an " ..
   "area's level, or what a numbered Great Library entry is), CALL a tool to look it up, then answer. " ..
   "Otherwise reply with EXACTLY ONE character: the letter A, B, C, or D. Output nothing else."


   local function answer_from(reply, source)
      if EPOCH ~= _TRIVIA.epoch or T.answered then return end
      local letter = extract_letter(reply)
      if letter and T.choices[letter] then submit(letter, source)
      else guess("couldn't parse a letter from '" .. tostring(reply) .. "'") end
   end

   local function decide(reference)
      if EPOCH ~= _TRIVIA.epoch or T.answered then return end
      local user = (reference and reference ~= "" and ("REFERENCE:\n" .. reference .. "\n\n") or "") ..
      "QUESTION: " .. q .. "\n" .. table.concat(prompt_choices, "\n")




      local function feed_lookup(name, out)
         if stale() then return end
         local user2 = user .. "\n\nLOOKUP RESULT (" .. name .. "):\n" .. out .. "\n\nNow answer with one letter:"
         ai_local_tools_request(sys, user2, cfg.max_tokens, cfg.think_prefill, "", function(r2, _, e2)
            if e2 then guess("model error: " .. (e2)) else answer_from(r2, TOOL_SOURCE[name] or "tool") end
         end)
      end






      local function resolve_library()
         local function give_up(msg)
            echo("\27[33m[trivia] " .. msg .. "\27[0m"); return rejected(GIVEUP)
         end
         local function resolved(text)
            return P(function(resolve) resolve(text) end)
         end

         local function by_title()
            local pick = library_pick_entry(Lib.catalog(), q)
            if not pick then return give_up("library: no matching entry in the local catalog") end
            local text = Lib.read(pick)
            if not text then return give_up("library: catalog entry " .. (pick) .. " isn't in the local mirror") end
            echo("\27[36m[trivia] found it locally: entry " .. (pick) .. "\27[0m")
            return resolved(text)
         end
         local qnum = question_book_number(q)
         if qnum then
            local text = Lib.read(qnum)
            if text then
               echo("\27[36m[trivia] reading local entry " .. qnum .. "\27[0m")
               return resolved(text)
            end
            echo("\27[33m[trivia] entry " .. qnum .. " not in the local library — searching by title\27[0m")
         end
         return by_title()
      end

      if ai_local_tools_request then
         ai_local_tools_request(sys, user .. "\n\nAnswer with one letter, or call a tool.", cfg.tool_max_tokens,
         cfg.think_prefill, TOOLS_JSON, function(reply, tool_calls, err)
            if stale() then return end
            if err then guess("model error: " .. (err)); return end
            if not tool_calls then answer_from(reply, "model"); return end
            local name, args = parse_tool_call(tool_calls)
            if name == "library_entry" then
               resolve_library():
               andThen(function(out) if not stale() then feed_lookup("library", out) end end):
               catch(function(reason)
                  if not stale() and (reason) == GIVEUP then
                     guess("library lookup unresolved")
                  end
               end)
               return
            end
            local cmd = tool_command(name, args)
            if not cmd then answer_from(reply, "model"); return end
            echo("\27[36m[trivia] looking it up: " .. cmd .. "\27[0m")
            run_lookup(cmd):andThen(function(out) if not stale() then feed_lookup(name, out) end end)
         end)
      elseif ai_local_request then
         ai_local_request(sys, user .. "\n\nAnswer with one letter:", cfg.max_tokens, cfg.think_prefill,
         function(reply, err) if err then guess("model error: " .. (err)) else answer_from(reply, "model") end end)
      elseif ai_request then
         ai_request(sys, user .. "\n\nAnswer with one letter:", cfg.max_tokens, "", cfg.think_prefill,
         function(reply, _, err) if err then guess("model error: " .. (err)) else answer_from(reply, "model") end end)
      else
         guess("no model available")
      end
   end



   if ai_retrieve and ai_rag_count and ai_rag_count() > 0 then
      ai_retrieve(q, cfg.rag_k, function(chunks_json, rerr)
         if EPOCH ~= _TRIVIA.epoch or T.answered then return end
         decide(((not rerr and chunks_json) or ""))
      end)
   else
      decide("")
   end
end







local function try_area(area_name)
   local target = norm_area(area_name)
   local rows = {}
   local sub = areaRowS and areaRowS:subscribe(function(r) rows[#rows + 1] = r end) or nil
   send("area " .. pick_keyword(area_name))
   after(cfg.area_wait, function()
      if sub then sub:unsubscribe() end
      if stale() then return end
      local match = nil
      for _, r in ipairs(rows) do
         if r.desc == target or r.desc:find(target, 1, true) or target:find(r.desc, 1, true) then
            match = r; break
         end
      end
      if not match then ask_model(); return end
      local letter = choice_for_level(T.choices, match.n1, match.kind == "Grp")
      if letter then submit(letter, "area") else ask_model() end
   end)
end

local function attempt_answer()
   if not S.enabled then return end
   if not T.q or not T.choices or T.answered then return end

   local known = cache[T.q]
   if known then
      local letter = letter_for_text(T.choices, known)
      if letter then submit(letter, "memory"); return end

   end



   local area_name = T.q_raw and T.q_raw:match("^[Ww]hat level is the area%s+(.+)")
   if area_name then area_name = trim((area_name:gsub("%s*%?%s*$", ""))) end
   local low = area_name and area_name:lower()
   if area_name and not (low:match("spell$") or low:match("skill$")) then try_area(area_name); return end

   ask_model()
end



on_trivia_question = function(q)
   T = { q = norm(q), q_raw = trim(q), choices = nil, answered = false, our_letter = nil, source = nil }
end
on_trivia_choices = function(c)
   if not T.q then return end
   T.choices = parse_choices(c)
   attempt_answer()
end


on_area_line = function(line)
   local r = parse_area_row(line)
   if r and areaRowS then areaRowS:onNext(r) end
end


on_trivia_reveal = function(rletter)
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
   T = { q = nil, choices = nil, answered = false }
end

on_trivia_announce = function(msg)
   if S.enabled then echo("\27[1;33m[trivia] " .. trim(msg) .. " (auto-answer armed)\27[0m") end
end


local function status_line()
   local s = S.stats
   local acc = s.attempts > 0 and string.format(" · %.0f%% (%d/%d)",
   100 * s.correct / s.attempts, s.correct, s.attempts) or ""
   return string.format("[trivia] %s · %d learned%s", S.enabled and "ON" or "OFF", s.learned, acc)
end












local Triv = {}
function Triv.on() S.enabled = true; echo(status_line()) end
function Triv.off() S.enabled = false; echo("[trivia] OFF (auto-answer disabled)") end
function Triv.status() echo(status_line()) end
function Triv.stats() echo(status_line()) end
function Triv.forget()
   cache = {}; S.stats.learned = 0; save_cache(); echo("[trivia] cleared learned-answer cache")
end

doc(Triv.on, { name = "trivia.on", sig = "trivia.on()", group = "trivia",
text = "Enable auto-answering of the game's trivia questions.", })
doc(Triv.off, { name = "trivia.off", sig = "trivia.off()", group = "trivia",
text = "Disable auto-answering.", })
doc(Triv.status, { name = "trivia.status", sig = "trivia.status()", group = "trivia",
text = "Show whether auto-answer is on, how many answers are learned, and the running accuracy.", })
doc(Triv.stats, { name = "trivia.stats", sig = "trivia.stats()", group = "trivia",
text = "Same readout as trivia.status(): on/off, learned count, accuracy.", })
doc(Triv.forget, { name = "trivia.forget", sig = "trivia.forget()", group = "trivia",
text = "Clear the learned-answer cache.", })

setmetatable(Triv, { __call = function(_, rest)
   local verb = trim((rest or "")):lower()
   if verb == "on" then Triv.on()
   elseif verb == "off" then Triv.off()
   elseif verb == "stats" then Triv.stats()
   elseif verb == "forget" then Triv.forget()
   elseif verb == "" or verb == "status" then Triv.status()
   else echo("[trivia] usage: trivia.on() | trivia.off() | trivia.stats() | trivia.forget()  (help(trivia))") end
end, })

trivia = Triv




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
   parse_library_list = parse_library_list,
   library_title = library_title,
   library_keyword = library_keyword,
   question_book_number = question_book_number,
   library_pick_entry = library_pick_entry,
   read_book = read_book,
   load_catalog = load_catalog,
   Lib = Lib,



   on_question = on_trivia_question,
   on_choices = on_trivia_choices,
   on_area_line = on_area_line,
   collect_line = collect_line,
}



if ai_set_local_model then ai_set_local_model(cfg.model) end

load_cache()
echo(status_line())
