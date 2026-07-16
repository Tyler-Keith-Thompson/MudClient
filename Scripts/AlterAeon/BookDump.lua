














state = state or {}





local function boot(name) pcall(require, name) end
boot("Machine")
if not __machine then dofile("Scripts/Foundation/Machine.lua") end
local machine = __machine
local goto_phase = __machine.goto_phase

local HOME = os.getenv("HOME") or ""
local BOOKS_DIR = HOME .. "/Documents/MudClient/books"
local CATALOG = HOME .. "/Documents/MudClient/books_catalog.jsonl"
local PAGER = "Press <return> or 'cont' to continue"
local PAGE_QUIET = 3
local MIN_BOOK = 40
local JITTER_MIN, JITTER_MAX = 3, 10
local BOOK_MAX = 30




































local B = { active = false, queue = {}, i = 0, vnum = nil, buf = nil,
quiet = nil, jitter = nil, watchdog = nil, cap = nil, prev_prompt = nil, }



local have
local load_queue
local save_current
local teardown
local arm_quiet
local arm_watchdog
local capture_line
local read_phase
local settle_phase










local bd_fsm = (machine("read")):
phase("read", function(advance) read_phase(advance) end):
phase("settle", function(advance) settle_phase(advance) end, goto_phase("read"))


local function book_path(v) return BOOKS_DIR .. "/" .. tostring(v) .. ".txt" end
have = function(v)
   local f = io.open(book_path(v), "r"); if not f then return false end
   local sz = f:seek("end"); f:close(); return (sz or 0) > 0
end


load_queue = function()
   local q = {}
   local f = io.open(CATALOG, "r")
   if f then
      for line in f:lines() do local v = line:match('"vnum":%s*(%d+)'); if v then q[#q + 1] = tonumber(v) end end
      f:close()
   end
   return q
end

save_current = function()
   if not (B.vnum and B.buf) then return end



   local first = 1
   for k, ln in ipairs(B.buf) do
      if ln:match("^%s*" .. tostring(B.vnum) .. "%s+%-%s") then first = k; break end
   end
   local kept = {}
   for k = first, #B.buf do kept[#kept + 1] = B.buf[k] end
   local text = table.concat(kept, "\n"):gsub("%s+$", "")
   if #text >= MIN_BOOK then
      local f = io.open(book_path(B.vnum), "w")
      if f then f:write(text .. "\n"); f:close()
echo(string.format("\27[32m[book]\27[0m saved %d (%d chars)", B.vnum, #text)) end
   else
      echo(string.format("\27[33m[book]\27[0m %d: only %dB captured — not saved, will retry next run", B.vnum, #text))
   end
   B.vnum, B.buf = nil, nil
end

teardown = function()
   if B.cap and rule_remove then rule_remove(B.cap); B.cap = nil end
   if B.quiet and cancel then cancel(B.quiet); B.quiet = nil end
   if B.jitter and cancel then cancel(B.jitter); B.jitter = nil end
   if B.watchdog and cancel then cancel(B.watchdog); B.watchdog = nil end
   if B.prev_prompt ~= nil then on_prompt = B.prev_prompt; B.prev_prompt = nil end
end




arm_quiet = function()
   if B.quiet and cancel then cancel(B.quiet) end
   B.quiet = after and after(PAGE_QUIET, function() if B.active then B.advance() end end) or nil
end




arm_watchdog = function()
   if B.watchdog and cancel then cancel(B.watchdog) end
   B.watchdog = after and after(BOOK_MAX, function()
      if B.active then echo("\27[33m[book]\27[0m watchdog: book " .. tostring(B.vnum) .. " stalled — advancing"); B.advance() end
   end) or nil
end






read_phase = function(advance)
   B.advance = advance
   if not B.active then return end
   while B.i < #B.queue do
      B.i = B.i + 1
      local v = B.queue[B.i]
      if not have(v) then
         B.vnum, B.buf = v, {}
         echo(string.format("\27[36m[book]\27[0m %d/%d — reading vnum %d", B.i, #B.queue, v))
         send("library read " .. tostring(v))
         arm_watchdog()
         return
      end
   end
   B.advance(machine.DONE)
end






settle_phase = function(advance)
   B.advance = advance
   if B.quiet and cancel then cancel(B.quiet); B.quiet = nil end
   if B.watchdog and cancel then cancel(B.watchdog); B.watchdog = nil end
   local ok, err = pcall(save_current)
   if not ok then echo("\27[31m[book] save error: " .. tostring(err) .. "\27[0m") end


   local delay = (math.random and math.random(JITTER_MIN, JITTER_MAX)) or JITTER_MIN
   echo(string.format("\27[36m[book]\27[0m saved — next read in %ds (%d/%d)", delay, B.i, #B.queue))
   B.jitter = after and after(delay, function() B.jitter = nil; if B.active then B.advance() end end) or nil
end











local function is_telemetry(line)
   return line:match("^kxw[tq]_") ~= nil or
   line:match("^;s%a") ~= nil
end
capture_line = function(line)
   if B.active and B.vnum and B.buf and not is_telemetry(line) then
      B.buf[#B.buf + 1] = line





      if line:find("%S") then arm_quiet() end
   end
   return nil
end


local function finish_run()
   B.active = false; teardown()
   echo("\27[1;32m[book]\27[0m dump complete — every catalogued book is saved under " .. BOOKS_DIR)
   if B.settle then local s = B.settle; B.settle = nil; s.resolve(nil) end
end



local function begin_run()
   if B.active then echo("[book] already running (" .. B.i .. "/" .. #B.queue .. ")"); return B.promise end
   if os.execute then os.execute('mkdir -p "' .. BOOKS_DIR .. '"') end
   B.queue = load_queue()
   if #B.queue == 0 then echo("[book] no books in " .. CATALOG .. " — run the catalog step first"); return end
   local todo = 0; for _, v in ipairs(B.queue) do if not have(v) then todo = todo + 1 end end
   echo(string.format("[book] starting: %d catalogued, %d still to read (once each, 3–10s apart — cancel any time)", #B.queue, todo))
   if math and math.randomseed then math.randomseed(os.time()) end
   B.active, B.i = true, 0
   B.cap = trigger([[.*]], capture_line)



   B.prev_prompt = on_prompt
   function on_prompt(text)
      if B.active and text and text:find(PAGER, 1, true) then
         send("cont"); arm_quiet(); arm_watchdog(); return
      end
      if B.prev_prompt then return B.prev_prompt(text) end
   end



   B.promise = __promise and __promise(function(resolve, reject, onCancel)
      B.settle = { resolve = resolve, reject = reject }
      onCancel(function()
         B.active = false; save_current(); teardown(); bd_fsm:cancel()
         echo(string.format("\27[33m[book]\27[0m cancelled at %d/%d", B.i, #B.queue))
      end)
      bd_fsm:start(finish_run)
   end, "bookdump") or nil
   if not B.promise then bd_fsm:start(finish_run) end
   return B.promise
end










local BD
BD = setmetatable({}, { __call = function(_, args)
   local cmd = ((args or ""):match("^%s*(%S*)") or ""):lower()
   if cmd == "" or cmd == "start" then return BD.start()
   elseif cmd == "stop" then return BD.stop()
   elseif cmd == "status" then return BD.status()
   else echo("[book] usage: bookdump start|stop|status") end
end, })
bookdump = BD

if alias then
   alias([[^bookdump (.+)$]], function(_, rest) return BD(rest) end)
   alias([[^bookdump$]], function() return BD("") end)
end

function BD.start() return begin_run() end

function BD.stop()
   if not B.active then echo("[book] not running"); return end
   if B.promise and B.promise.cancel then B.promise:cancel()
   else B.active = false; save_current(); teardown(); bd_fsm:cancel()
echo(string.format("[book] stopped at %d/%d", B.i, #B.queue)) end
end

function BD.status()
   local done = 0; for _, v in ipairs(B.queue) do if have(v) then done = done + 1 end end
   echo(string.format("[book] %s  progress %d/%d saved  reading=%s",
   B.active and "RUNNING" or "idle", done, #B.queue, tostring(B.vnum)))
end

doc(bookdump, { name = "bookdump", sig = "bookdump('start'|'stop'|'status')", group = "ai",
text = "Read every book in books_catalog.jsonl once via `library read <vnum>`, auto-paging the " ..
"\"Press <return> or 'cont'…\" pager, and save each to ~/Documents/MudClient/books/<vnum>.txt for the " ..
"RAG. Idempotent — already-saved books are skipped, so the server is hit once per book ever. kxwt/RPC " ..
"telemetry is filtered out of the capture; run it somewhere quiet only to keep OTHER players' visible " ..
"text from leaking into a book. `bookdump status` shows progress; `bookdump stop` halts.", })
