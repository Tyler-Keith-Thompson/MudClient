-- BookDump.lua — read every catalogued book ONCE and save its text for the RAG.
--
-- Drives `library read <vnum>` down the whole books_catalog.jsonl list, auto-paging through the
-- "Press <return> or 'cont' to continue, anything else to quit..." pager (which arrives GA-terminated, so
-- it comes through on_prompt — NOT a trigger — see the raw-log analysis), and writes each book's text to
-- ~/Documents/MudClient/books/<vnum>.txt. IDEMPOTENT: a book that already has a non-empty file is skipped,
-- so re-running only fetches what's missing — every book hits the server exactly ONCE, ever.
--
-- Usage (after #reload):  bookdump start    ·    bookdump status    ·    bookdump stop
-- The saved .txt files + the titles in books_catalog.jsonl are the RAG corpus; build the index separately.

-- `bookdump` isn't in mud.d.tl (this is the only script that publishes it) — declared here, `any` like the
-- other callable game-surface tables (eq/pilot/kxwt/trivia), since the typing win is in the logic below.
global bookdump: any

state = state or {}

local HOME      = os.getenv("HOME") or ""
local BOOKS_DIR = HOME .. "/Documents/MudClient/books"
local CATALOG   = HOME .. "/Documents/MudClient/books_catalog.jsonl"
local PAGER     = "Press <return> or 'cont' to continue"   -- the pager prompt (plain-substring match)
local PAGE_QUIET = 3        -- seconds of silence after the last page before a book is considered done
local MIN_BOOK   = 40       -- chars; a shorter capture is an error/empty ("no such book") → NOT saved, retried
local JITTER_MIN, JITTER_MAX = 3, 10   -- random seconds BETWEEN books so we don't fire 474 reads in a burst
local BOOK_MAX   = 30       -- hard watchdog: if a book neither completes nor turns a page in this long, advance

-- All mutable state in one record so it survives a #reload cleanly (the machinery — triggers/on_prompt wrap —
-- does NOT survive reload, so don't #reload mid-run; stop, reload, start again).
local record Settle
   resolve: function(any)
   reject:  function(string)
end
local record BState
   active:      boolean
   queue:       {integer}
   i:           integer
   vnum:        integer
   buf:         {string}
   quiet:       integer
   jitter:      integer
   watchdog:    integer
   cap:         integer
   prev_prompt: function(string)
   promise:     Promise<any>
   settle:      Settle
   arm_quiet:    function()
   arm_watchdog: function()
end
local B: BState = { active = false, queue = {}, i = 0, vnum = nil, buf = nil,
            quiet = nil, jitter = nil, watchdog = nil, cap = nil, prev_prompt = nil }

local function book_path(v: integer): string return BOOKS_DIR .. "/" .. tostring(v) .. ".txt" end
local function have(v: integer): boolean
  local f = io.open(book_path(v), "r"); if not f then return false end
  local sz = f:seek("end"); f:close(); return (sz or 0) > 0
end

-- Read the vnum list from the catalog JSONL (one {"vnum":N,...} per line).
local function load_queue(): {integer}
  local q: {integer} = {}
  local f = io.open(CATALOG, "r")
  if f then
    for line in f:lines() do local v = line:match('"vnum":%s*(%d+)'); if v then q[#q + 1] = tonumber(v) as integer end end
    f:close()
  end
  return q
end

local function save_current()
  if not (B.vnum and B.buf) then return end
  -- `library read` prints a header "<vnum> - <title>    Topic: <topic>" then a "----" rule then the text.
  -- Trim any leading noise captured before that header so the saved file starts cleanly AT the book (the
  -- header line — with its Topic — is kept, it's useful RAG metadata). If the header never appeared, keep all.
  local first = 1
  for k, ln in ipairs(B.buf) do
    if ln:match("^%s*" .. tostring(B.vnum) .. "%s+%-%s") then first = k; break end
  end
  local kept: {string} = {}
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

local function teardown()
  if B.cap and rule_remove then rule_remove(B.cap); B.cap = nil end
  if B.quiet    and cancel then cancel(B.quiet);    B.quiet    = nil end
  if B.jitter   and cancel then cancel(B.jitter);   B.jitter   = nil end
  if B.watchdog and cancel then cancel(B.watchdog); B.watchdog = nil end
  if B.prev_prompt ~= nil then on_prompt = B.prev_prompt; B.prev_prompt = nil end   -- restore the real on_prompt
end

local read_next: function()   -- fwd (recursive with the quiet timer)

-- Book done → save it, then schedule the NEXT read after a random jitter. WRAPPED so a hidden error (a bad
-- save, a stripped stdlib fn, …) surfaces LOUDLY and STILL schedules the next read, instead of silently
-- killing the whole run — which is what stalled it after book 1 (201 saved fine, then nothing).
local function advance()
  if B.quiet    and cancel then cancel(B.quiet);    B.quiet    = nil end
  if B.watchdog and cancel then cancel(B.watchdog); B.watchdog = nil end
  local ok, err = pcall(save_current as function(): any)
  if not ok then echo("\27[31m[book] save error: " .. tostring(err) .. "\27[0m") end
  -- Integer jitter via math.random(min,max) — the ARG'd form every other script uses successfully (the
  -- no-arg math.random() float form is untested in this embed and was the prime suspect for the stall).
  local delay = (math.random and math.random(JITTER_MIN, JITTER_MAX)) or JITTER_MIN
  echo(string.format("\27[36m[book]\27[0m saved — next read in %ds (%d/%d)", delay, B.i, #B.queue))
  B.jitter = after and after(delay, function() B.jitter = nil; if B.active then read_next() end end) or nil
end

-- The "book done" detector: fires PAGE_QUIET seconds after the last captured line (no more pages coming).
local function arm_quiet()
  if B.quiet and cancel then cancel(B.quiet) end
  B.quiet = after and after(PAGE_QUIET, function() if B.active then advance() end end) or nil
end
B.arm_quiet = arm_quiet

-- Hard backstop: if a book neither turns a page (cont) nor completes within BOOK_MAX, force an advance so a
-- stuck pager / missed signal can never permanently halt the run. Re-armed on each page turn (long books are
-- fine); cancelled the moment a book advances.
local function arm_watchdog()
  if B.watchdog and cancel then cancel(B.watchdog) end
  B.watchdog = after and after(BOOK_MAX, function()
    if B.active then echo("\27[33m[book]\27[0m watchdog: book " .. tostring(B.vnum) .. " stalled — advancing"); advance() end
  end) or nil
end
B.arm_watchdog = arm_watchdog

read_next = function()
  if not B.active then return end
  while B.i < #B.queue do
    B.i = B.i + 1
    local v = B.queue[B.i]
    if not have(v) then                                   -- skip books we already captured (spam ONCE)
      B.vnum, B.buf = v, {}
      echo(string.format("\27[36m[book]\27[0m %d/%d — reading vnum %d", B.i, #B.queue, v))
      send("library read " .. tostring(v))
      arm_watchdog()          -- the quiet timer starts on the FIRST real book line (capture_line), not now
      return
    end
  end
  B.active = false; teardown()
  echo("\27[1;32m[book]\27[0m dump complete — every catalogued book is saved under " .. BOOKS_DIR)
  if B.settle then local s = B.settle; B.settle = nil; s.resolve(nil) end   -- settle the promise as fulfilled
end

-- Capture the current book's text while a read is in flight, resetting the "done" timer on each real line (a
-- slow multi-page book must not time out mid-read). Returns nil → the line still displays.
-- What can and can't reach here:
--   * kxwt/kxwq TELEMETRY tags never should (AlterAeon's catch-all gag ends the handler chain before this
--     low-specificity `.*` observer) — but we FILTER them explicitly anyway, so a change in gag ordering
--     can't leak protocol noise into a book. You can't silence these, so we don't rely on you being "quiet".
--   * RPC's NON-TEXT messages (hpbar/enemy_hp/;sgroup;/sky/music) aren't trigger lines at all → never here.
--   * The GA-flushed pager prompt is an on_prompt (handled in start()), not a trigger line → never here.
-- What CAN interleave (and is the only reason to run somewhere quiet): other players' VISIBLE text —
-- a room say/emote, a tell shown inline, movement — since that's genuine game text like the book itself.
local function is_telemetry(line: string): boolean
  return line:match("^kxw[tq]_") ~= nil        -- a kxwt/kxwq protocol tag
      or line:match("^;s%a") ~= nil            -- a stray dclient ;s<tag> frame, if one ever slips through
end
local function capture_line(line: string): string
  if B.active and B.vnum and B.buf and not is_telemetry(line) then
    B.buf[#B.buf + 1] = line
    -- Reset the "book done" timer ONLY on a line with real content. The line-assembler emits a spurious
    -- EMPTY line after every GA-flushed prompt/tag (the kxwq_hud prompt fires ~every tick), so resetting on
    -- blanks would keep the quiet timer from EVER firing → the 30s watchdog had to advance each book (the
    -- "very long delay before it says saved"). Book blank lines are still captured (formatting); the real
    -- text around them keeps the timer alive, and trailing blanks are trimmed on save.
    if line:find("%S") then arm_quiet() end
  end
  return nil
end

-- Public callable table, typed like Dcast (see DCast.tl): `metamethod __call` handles `bookdump('start')` /
-- the alias form, start/stop/status are the named entry points.
local record BookDumpT
   metamethod __call: function(BookDumpT, string): any
   start:  function(): any
   stop:   function()
   status: function()
end

local BD: BookDumpT
BD = setmetatable({} as BookDumpT, { __call = function(_: BookDumpT, args: string): any
  local cmd = ((args or ""):match("^%s*(%S*)") or ""):lower()
  if cmd == "" or cmd == "start" then return BD.start()
  elseif cmd == "stop"   then return BD.stop()
  elseif cmd == "status" then return BD.status()
  else echo("[book] usage: bookdump start|stop|status") end
end } as metatable<BookDumpT>)
bookdump = BD                          -- publish to the (any-typed) global for the REPL + Lua callers
-- Straight-input alias (no `#`), like goto/dcast: `bookdump start`. Returns the promise so it chains/pipes.
if alias then
  alias([[^bookdump (.+)$]], function(_: any, rest: string): any return BD(rest) end)
  alias([[^bookdump$]],      function(): any return BD("") end)
end

function BD.start(): any
  if B.active then echo("[book] already running (" .. B.i .. "/" .. #B.queue .. ")"); return B.promise end
  if os.execute then os.execute('mkdir -p "' .. BOOKS_DIR .. '"') end
  B.queue = load_queue()
  if #B.queue == 0 then echo("[book] no books in " .. CATALOG .. " — run the catalog step first"); return end
  local todo = 0; for _, v in ipairs(B.queue) do if not have(v) then todo = todo + 1 end end
  echo(string.format("[book] starting: %d catalogued, %d still to read (once each, 3–10s apart — cancel any time)", #B.queue, todo))
  if math and math.randomseed then math.randomseed(os.time()) end
  B.active, B.i = true, 0
  B.cap = trigger([[.*]], capture_line)                  -- observe every line (low specificity → runs last)
  -- The pager is GA-flushed → on_prompt. Chain the current handler so the vitals/fighting/re-inject logic
  -- still runs for everything that ISN'T the pager. Captured at start() (runtime), so Prompt.lua's on_prompt
  -- is already in place — wrapping at load time would be clobbered by Prompt.lua loading after us.
  B.prev_prompt = on_prompt
  function on_prompt(text: string)
    if B.active and text and text:find(PAGER, 1, true) then
      send("cont"); arm_quiet(); arm_watchdog(); return   -- page turn → keep the watchdog fresh for long books
    end
    if B.prev_prompt then return B.prev_prompt(text) end
  end
  -- Wrap the whole run in a cancellable promise (Promise.lua): it RESOLVES when every book is saved, shows as
  -- a "bookdump" row in the promise widget, and its cancel hook tears everything down — so `bookdump stop`,
  -- cancelling the widget row, or `-|` all halt it cleanly mid-run.
  B.promise = __promise and __promise(function(resolve: function(any), reject: function(string), onCancel: function(function()))
    B.settle = { resolve = resolve, reject = reject }
    onCancel(function()
      B.active = false; save_current(); teardown()
      echo(string.format("\27[33m[book]\27[0m cancelled at %d/%d", B.i, #B.queue))
    end)
    read_next()
  end, "bookdump") or nil
  if not B.promise then read_next() end                  -- Promise.lua absent (bare harness) → run unwrapped
  return B.promise
end

function BD.stop()
  if not B.active then echo("[book] not running"); return end
  if B.promise and B.promise.cancel then B.promise:cancel()   -- fires the onCancel hook (save + teardown)
  else B.active = false; save_current(); teardown()
    echo(string.format("[book] stopped at %d/%d", B.i, #B.queue)) end
end

function BD.status()
  local done = 0; for _, v in ipairs(B.queue) do if have(v) then done = done + 1 end end
  echo(string.format("[book] %s  progress %d/%d saved  reading=%s",
    B.active and "RUNNING" or "idle", done, #B.queue, tostring(B.vnum)))
end

doc(bookdump, { name = "bookdump", sig = "bookdump('start'|'stop'|'status')", group = "ai",
  text = "Read every book in books_catalog.jsonl once via `library read <vnum>`, auto-paging the "
      .. "\"Press <return> or 'cont'…\" pager, and save each to ~/Documents/MudClient/books/<vnum>.txt for the "
      .. "RAG. Idempotent — already-saved books are skipped, so the server is hit once per book ever. kxwt/RPC "
      .. "telemetry is filtered out of the capture; run it somewhere quiet only to keep OTHER players' visible "
      .. "text from leaking into a book. `bookdump status` shows progress; `bookdump stop` halts." })
