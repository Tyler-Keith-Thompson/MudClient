-- DCast.tl — typed source for "definite cast" (compiles to Scripts/DCast.lua via the loader / build.sh).
-- The point of this migration: DCast is promise + rx heavy, exactly the shape I claimed would "collapse to
-- any". Typed against the Promise<T>/Rx declarations in mud.d.tl, the LOGIC stays fully typed — Outcome and
-- Action are closed enums, attempt() is Promise<Outcome>, the retry chain carries its element type. The only
-- `any` is at the deliberate dynamic boundaries (the global callable table, the _AA_TEST seam, doc()).

state = state or {}
_AA_TEST = _AA_TEST or {}

-- Self-bootstrap the reactive deps (DCast may load before them; load order is require-driven, not pinned).
-- require in the live client, a dofile fallback in the test harness where the searcher's host primitives
-- are stubbed. MUST run before the `local rx/persist` captures below, or they'd bind nil. The require goes
-- through a dynamic name so Teal doesn't try to type these Lua-only modules (they publish globals __rx/
-- __persist, already declared in mud.d.tl) — they're loaded for effect, not for a return value.
local function boot(name: string) pcall(require, name) end
boot("_rx");      if not __rx then dofile("Scripts/_rx.lua") end
boot("Promise")
boot("_persist"); if not __persist then dofile("Scripts/_persist.lua") end

local rx = __rx
local persist = __persist

local CAST_WAIT     = 4      -- seconds to wait for a spell's landed line before counting the attempt a miss
local DEFAULT_TRIES = 25     -- safety cap: stop after this many misses so nothing loops forever
local MANA_WAIT     = 6      -- seconds to let mana regen before re-trying a cast that failed on mana
local MANA_CAP      = 40     -- max mana-waits before giving up (≈4 min)

-- One attempt's outcome, and what the loop decides next — both CLOSED sets (a typo won't compile).
local enum Outcome
   "ok" "fail" "mana" "miss" "cant"
end
local enum Action
   "resolve" "reject" "wait" "retry"
end

-- SEED registry: spell name → its landed-line pattern (Swift trigger regex, self-anchored to OUR cast).
local SEED: {string:string} = {
   ["lightning"]   = [[^A .* bolt of lightning leaps from you to ]],
   ["icebolt"]     = [[^You create and magically throw bolts of ice at ]],
   ["fireball"]    = [[^You (?:conjure and )?throw a .* fireball at ]],
   ["prism"]       = [[^You use a small crystal to focus your powers and throw a confusing wash of color and force at ]],
   ["frostflower"] = [[^Spiked flowers of ice quickly form on everything in a ring around you!$]],
   ["refresh"]     = [[^You feel less tired\.$]],
}

local SPELLS_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/dcast_spells.lua"
local registry: {string:string} = {}
for k, v in pairs(SEED) do registry[k] = v end
do
   local t = persist and persist.load(SPELLS_FILE)
   if t is {string:string} then                       -- persist.load is `any`; Teal forces the narrowing
      for k, v in pairs(t) do registry[k] = v end
   end
end

local function save_learned()
   if not persist then return end
   local parts: {string} = {}
   for k, v in pairs(registry) do
      if SEED[k] ~= v then parts[#parts + 1] = string.format("[%q]=%q", k, v) end   -- only deltas from the seed
   end
   persist.write(SPELLS_FILE, "return {" .. table.concat(parts, ",") .. "}")
end

-- Resolve the SPELL a `c <args>` line casts: the longest registered name that whole-word-prefixes args.
local function resolve_spell(args: string): string
   local low = args:lower()
   local best: string = nil
   for key in pairs(registry) do
      if low == key or low:sub(1, #key + 1) == key .. " " then
         if not best or #key > #best then best = key end
      end
   end
   return best
end
_AA_TEST.dcast_resolve = resolve_spell

-- Pure next-move decision (exposed for the spec): outcome + tries-so-far + cap → an Action (+ reason).
local function decide(outcome: Outcome, tries: integer, cap: integer): Action, string
   if outcome == "ok"   then return "resolve" end
   if outcome == "mana" then return "wait" end
   if outcome == "cant" then return "reject", "can't concentrate enough" end   -- HARD stop
   if tries >= cap then return "reject", "gave up — couldn't land it in " .. tostring(tries) .. " tries" end
   return "retry"
end
_AA_TEST.dcast_decide = decide

-- One-shot outcome streams shared by every attempt, fed by triggers registered ONCE.
local fizzleS  = rx and rx.subject() or nil
local manaS    = rx and rx.subject() or nil
local concentS = rx and rx.subject() or nil       -- "You can't concentrate enough!" — a HARD stop
if trigger then
   trigger([[^You fail to cast the spell ']],  function() if fizzleS then fizzleS:onNext(nil) end end)
   trigger([[^You don't have enough mana\.$]], function() if manaS then manaS:onNext(nil) end end)
   trigger([[^You can't concentrate enough]],  function() if concentS then concentS:onNext(nil) end end)
end

-- One cast attempt → Promise<Outcome>. fromTrigger registers the landed pattern on subscribe, removes it
-- on unsubscribe (no trigger leak). Kept OUT of the HUD promise widget — only the top-level dcast row shows.
local function attempt(args: string, landed_pat: string): Promise<Outcome>
   local p = __promise(function(resolve: function(any), _: function(string), onCancel: function(function()))
      local subs: {Subscription} = {}
      local timer: integer = nil
      local done = false
      local function cleanup()
         for _, s in ipairs(subs) do s:unsubscribe() end
         subs = {}
         if timer and cancel then cancel(timer); timer = nil end
      end
      local function fin(v: Outcome)
         if done then return end
         done = true; cleanup(); resolve(v)
      end
      if rx then subs[#subs + 1] = rx.fromTrigger(landed_pat):subscribe(function() fin("ok") end) end
      if fizzleS  then subs[#subs + 1] = fizzleS:subscribe(function() fin("fail") end) end
      if manaS    then subs[#subs + 1] = manaS:subscribe(function() fin("mana") end) end
      if concentS then subs[#subs + 1] = concentS:subscribe(function() fin("cant") end) end
      timer = after and after(CAST_WAIT, function() fin("miss") end) or nil    -- no landed line in time → miss
      onCancel(function() done = true; cleanup() end)
      send("c " .. args)
   end, "dcast-try")
   if __untrack_promise then __untrack_promise(p) end
   return p as Promise<Outcome>          -- cast the element type at the boundary (see mud.d.tl Promise note)
end

local record DcastOpts
   tries: integer
end

-- dcast(args[, opts]) — the retry loop as ONE tracked promise. Resolves with the number of tries it took;
-- rejects (with a reason) on out-of-mana, the cap, or an unknown spell. opts.tries overrides the cap.
local function do_dcast(args: string, opts: DcastOpts): Promise<integer>
   args = (args or ""):gsub("^%s+", ""):gsub("%s+$", "")
   if args == "" then echo("[dcast] usage: dcast <spell> [target]  — re-casts until it lands") return nil end
   local spell = resolve_spell(args)
   if not spell then
      echo("\27[33m[dcast]\27[0m I don't know the landed line for '" .. (args:match("^%S+") or args)
         .. "', so I can't tell when it lands. Teach me: dcast.learn('<spell>', '<landed-line pattern>').")
      return nil
   end
   local landed_pat = registry[spell]
   local cap = (opts and opts.tries) or DEFAULT_TRIES
   return __promise(function(resolve: function(any), reject: function(string), onCancel: function(function()))
      local n, mana_waits = 0, 0
      local waiting_mana, stopped = false, false
      local cur: Promise<Outcome> = nil
      local wait_timer: integer = nil
      local try: function()
      try = function()
         if stopped then return end
         n = n + 1
         cur = attempt(args, landed_pat)
         cur:andThen(function(r: Outcome)
            local act, why = decide(r, n, cap)
            if act == "resolve" then
               echo(string.format("\27[32m[dcast]\27[0m '%s' landed%s.", args, n > 1 and (" (" .. tostring(n) .. " tries)") or ""))
               resolve(n)
            elseif act == "reject" then
               echo("\27[33m[dcast]\27[0m '" .. args .. "' — " .. (why or "") .. ".")
               reject(why or "failed")
            elseif act == "wait" then
               -- Out of mana: don't spam, don't give up — pause, let it regen, cast again. n is NOT bumped.
               n = n - 1
               mana_waits = mana_waits + 1
               if mana_waits > MANA_CAP then
                  echo("\27[33m[dcast]\27[0m '" .. args .. "' — still out of mana after a long wait; stopping.")
                  reject("out of mana")
               else
                  if not waiting_mana then
                     waiting_mana = true
                     echo("\27[36m[dcast]\27[0m out of mana — waiting for it to regen, then I'll keep casting.")
                  end
                  wait_timer = after and after(MANA_WAIT, try) or nil
               end
            else
               waiting_mana = false    -- mana came back — re-arm the announce
               try()
            end
         end)
      end
      onCancel(function()
         stopped = true
         if wait_timer and cancel then cancel(wait_timer) end
         if cur then cur:cancel() end
      end)
      try()
   end, "dcast " .. args) as Promise<integer>
end

-- Public callable table. `metamethod __call` types the `dcast('fireball orc')` / alias forms.
local record Dcast
   metamethod __call: function(Dcast, string, DcastOpts): Promise<integer>
   learn:  function(string, string)
   forget: function(string)
   known:  function()
end

local D: Dcast = setmetatable({} as Dcast, { __call = function(_: Dcast, args: string, opts: DcastOpts): Promise<integer>
   return do_dcast(args, opts)
end } as metatable<Dcast>)

function D.learn(spell: string, pattern: string)
   spell = (spell or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
   if spell == "" or not pattern or pattern == "" then echo("[dcast] usage: dcast.learn('<spell>', '<landed-line pattern>')") return end
   registry[spell] = pattern
   save_learned()
   echo("[dcast] learned '" .. spell .. "' → " .. pattern)
end
function D.forget(spell: string)
   spell = (spell or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
   registry[spell] = SEED[spell]      -- back to the seed (nil if it wasn't seeded)
   save_learned()
   echo("[dcast] forgot '" .. spell .. "'" .. (registry[spell] and " (restored the built-in)" or ""))
end
function D.known()
   local names: {string} = {}
   for k in pairs(registry) do names[#names + 1] = k end
   table.sort(names)
   echo("[dcast] knows: " .. (next(names) and table.concat(names, ", ") or "(nothing)"))
end

dcast = D                              -- publish to the (any-typed) global for the REPL + Lua callers

-- ALIAS on straight typed input (no `#`): `dcast fireball orc`. Returns the promise so it still pipes.
if alias then
   alias([[^dcast (.+)$]], function(_: any, rest: string): any return do_dcast(rest, nil) end)
   alias([[^dcast$]],      function(): any return do_dcast("", nil) end)
end

_AA_TEST.dcast_registry = registry

doc(D, { name = "dcast", sig = "dcast('<spell> [target]')", group = "combat",
   text = "\"Definite cast\": send `c <spell> [target]` and keep re-casting on a fizzle until the spell's own "
       .. "landed line prints. Halts on out-of-mana or after ~25 misses; returns a promise so it chains/pipes. "
       .. "It only casts spells whose landed line it knows — otherwise it tells you and stops. `dcast.learn("
       .. "'<spell>','<landed-pattern>')` teaches one (persists), `dcast.forget('<spell>')` / `dcast.known()`." })
