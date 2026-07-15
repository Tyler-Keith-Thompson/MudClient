-- DCast.lua — "definite cast". Sends `c <args>` and keeps re-casting until the spell actually LANDS,
-- confirmed by that spell's own landed line (not a guess). A fizzle ("You fail to cast the spell '…'.")
-- re-casts; out-of-mana halts (no spam); a safety cap stops a spell that keeps missing. Returns a chainable
-- promise, so it works standalone (`#dcast fireball orc`), in a pipe, or as a block AutoFight/Recovery can call.
--
-- WHY a landed-line registry (per the request "dcast needs to know the landed line"): success can't be
-- inferred generically — spells have no common "it worked" line, and "no fizzle" isn't proof (a resist/
-- no-target also prints no fizzle). So dcast keeps a spell → landed-pattern table. If it DOESN'T know a
-- spell it says so and stops, rather than pretend the cast landed — and you teach it with dcast.learn().

state = state or {}
_AA_TEST = _AA_TEST or {}

pcall(require, "_rx")
if not __rx then dofile("Scripts/_rx.lua") end
pcall(require, "Promise")
pcall(require, "_persist")
if not __persist then dofile("Scripts/_persist.lua") end
local rx, persist = __rx, __persist

local CAST_WAIT     = 4     -- seconds to wait for a spell's landed line before counting the attempt a miss
local DEFAULT_TRIES = 25    -- safety cap: stop after this many misses (fizzle/resist) so nothing loops forever
local MANA_WAIT     = 6     -- seconds to let mana regen before re-trying a cast that failed on mana
local MANA_CAP      = 40    -- max mana-waits before giving up (≈4 min) — you probably can't cast it at all

-- SEED registry: spell name → its landed-line pattern (Swift trigger regex, self-anchored so it's OUR cast).
-- Only spells whose landed line is the SAME regardless of target (the damage line names the target after a
-- fixed prefix; refresh is self-only). Wire strings VERIFIED live (lifted from AutoFight/Recovery). Heals
-- (bolster/soothe) are deliberately NOT seeded: their landed line differs self ("You feel a little better.")
-- vs minion ("You repair the damage to X's body."), so one pattern can't cover both — teach the form you use.
local SEED = {
  ["lightning"]   = [[^A .* bolt of lightning leaps from you to ]],
  ["icebolt"]     = [[^You create and magically throw bolts of ice at ]],
  ["fireball"]    = [[^You (?:conjure and )?throw a .* fireball at ]],
  ["prism"]       = [[^You use a small crystal to focus your powers and throw a confusing wash of color and force at ]],
  ["frostflower"] = [[^Spiked flowers of ice quickly form on everything in a ring around you!$]],
  ["refresh"]     = [[^You feel less tired\.$]],
}

-- Learned spells persist so teaching sticks across restarts; they layer OVER the seed.
local SPELLS_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/dcast_spells.lua"
local registry = {}
for k, v in pairs(SEED) do registry[k] = v end
do
  local t = persist and persist.load(SPELLS_FILE)
  if type(t) == "table" then for k, v in pairs(t) do if type(k) == "string" and type(v) == "string" then registry[k] = v end end end
end
local function save_learned()
  if not persist then return end
  local learned, parts = {}, {}
  for k, v in pairs(registry) do if SEED[k] ~= v then learned[k] = v end end   -- only the deltas from the seed
  for k, v in pairs(learned) do parts[#parts + 1] = string.format("[%q]=%q", k, v) end
  persist.write(SPELLS_FILE, "return {" .. table.concat(parts, ",") .. "}")
end

-- Resolve the SPELL a `c <args>` line casts: the longest registered spell name that is a whole-word prefix
-- of args (so "fireball orc" → "fireball", "soothe wounds me" → "soothe wounds"). nil = we don't know it.
local function resolve_spell(args)
  local low, best = args:lower(), nil
  for key in pairs(registry) do
    if low == key or low:sub(1, #key + 1) == key .. " " then
      if not best or #key > #best then best = key end
    end
  end
  return best
end
_AA_TEST.dcast_resolve = resolve_spell

-- Pure next-move decision (exposed for the spec): one attempt's outcome + tries-so-far + cap → what to do.
-- "wait" = out of mana; the loop pauses and re-tries once mana has had time to regen (dcast MANAGES the
-- shortage instead of giving up), and a mana-wait does NOT count toward the fizzle cap.
local function decide(outcome, tries, cap)
  if outcome == "ok"   then return "resolve" end
  if outcome == "mana" then return "wait" end
  if outcome == "cant" then return "reject", "can't concentrate enough" end   -- HARD stop: retrying is futile
  -- "fail" (fizzle) or "miss" (no landed line seen) → try again until the cap.
  if tries >= cap then return "reject", "gave up — couldn't land it in " .. tries .. " tries" end
  return "retry"
end
_AA_TEST.dcast_decide = decide

-- One-shot outcome streams shared by every attempt, fed by triggers registered ONCE (reload re-registers).
-- Declared BEFORE attempt() so its closure captures these upvalues (a local is only visible after its decl).
local fizzleS  = rx and rx.subject() or nil
local manaS    = rx and rx.subject() or nil
local concentS = rx and rx.subject() or nil   -- "You can't concentrate enough!" — a HARD stop, never retryable
if trigger then
  trigger([[^You fail to cast the spell ']], function() if fizzleS then fizzleS:onNext() end end)
  trigger([[^You don't have enough mana\.$]], function() if manaS then manaS:onNext() end end)
  trigger([[^You can't concentrate enough]], function() if concentS then concentS:onNext() end end)
end

-- One cast attempt → a promise resolving "ok" | "fail" | "mana" | "miss". `landed_pat` is the spell's landed
-- line; fromTrigger registers it on subscribe and removes it on unsubscribe (so no trigger leaks). Kept OUT
-- of the HUD promise widget — only the top-level dcast row shows.
local function attempt(args, landed_pat)
  local p = __promise(function(resolve, _, onCancel)
    local subs, timer, done = {}, nil, false
    local function cleanup()
      for _, s in ipairs(subs) do s:unsubscribe() end
      subs = {}
      if timer and cancel then cancel(timer); timer = nil end
    end
    local function fin(v) if done then return end; done = true; cleanup(); resolve(v) end
    if rx then subs[#subs + 1] = rx.fromTrigger(landed_pat):subscribe(function() fin("ok") end) end
    if fizzleS  then subs[#subs + 1] = fizzleS:subscribe(function() fin("fail") end) end
    if manaS    then subs[#subs + 1] = manaS:subscribe(function() fin("mana") end) end
    if concentS then subs[#subs + 1] = concentS:subscribe(function() fin("cant") end) end
    timer = after and after(CAST_WAIT, function() fin("miss") end) or nil   -- no landed line in time → a miss
    onCancel(function() done = true; cleanup() end)
    send("c " .. args)
  end, "dcast-try")
  if __untrack_promise then __untrack_promise(p) end
  return p
end

-- dcast(args[, opts]) — the retry loop as ONE tracked promise. Resolves with the number of tries it took;
-- rejects (with a reason) on out-of-mana, the cap, or an unknown spell. opts.tries overrides the cap.
local function do_dcast(args, opts)
  args = (args or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if args == "" then echo("[dcast] usage: dcast <spell> [target]  — re-casts until it lands"); return end
  local spell = resolve_spell(args)
  if not spell then
    echo("\27[33m[dcast]\27[0m I don't know the landed line for '" .. (args:match("^%S+") or args)
      .. "', so I can't tell when it lands. Teach me: dcast.learn('<spell>', '<landed-line pattern>').")
    return
  end
  local landed_pat = registry[spell]
  local cap = (opts and tonumber(opts.tries)) or DEFAULT_TRIES
  return __promise(function(resolve, reject, onCancel)
    local n, cur, mana_waits, waiting_mana, stopped = 0, nil, 0, false, false
    local wait_timer
    local function try()
      if stopped then return end
      n = n + 1
      cur = attempt(args, landed_pat)
      cur.andThen(function(r)
        local act, why = decide(r, n, cap)
        if act == "resolve" then
          echo(string.format("\27[32m[dcast]\27[0m '%s' landed%s.", args, n > 1 and (" (" .. n .. " tries)") or ""))
          resolve(n)
        elseif act == "reject" then
          echo("\27[33m[dcast]\27[0m '" .. args .. "' — " .. why .. ".")
          reject(why)
        elseif act == "wait" then
          -- Out of mana: don't spam and don't give up — pause, let it regen, then cast again. n is NOT
          -- bumped for the mana-wait (it isn't a miss), but a separate cap stops an unwinnable wait.
          n = n - 1
          mana_waits = mana_waits + 1
          if mana_waits > MANA_CAP then
            echo("\27[33m[dcast]\27[0m '" .. args .. "' — still out of mana after a long wait; stopping.")
            reject("out of mana")
          else
            if not waiting_mana then   -- announce the wait once, not every poll
              waiting_mana = true
              echo("\27[36m[dcast]\27[0m out of mana — waiting for it to regen, then I'll keep casting.")
            end
            wait_timer = after and after(MANA_WAIT, try) or nil
          end
        else
          waiting_mana = false   -- mana came back (this attempt didn't fail on mana) — re-arm the announce
          try()
        end
      end)
    end
    onCancel(function() stopped = true
      if wait_timer and cancel then cancel(wait_timer) end
      if cur and cur.cancel then cur.cancel() end
    end)
    try()
  end, "dcast " .. args)
end

-- Public callable table: `#dcast fireball orc` → `dcast("fireball orc")`; chainable from Lua/pipes.
dcast = setmetatable(dcast or {}, { __call = function(_, args, opts) return do_dcast(args, opts) end })

-- ALIAS on straight typed input (no `#`), exactly like goto/explore/autofight — this is how you actually
-- use it in play: type `dcast fireball orc`. Returns the promise so it still pipes (`dcast heal |+ stand`).
-- (The `#dcast …` / `dcast(...)` forms above stay for the REPL and Lua callers.)
if alias then
  alias([[^dcast (.+)$]], function(_, rest) return do_dcast(rest) end)
  alias([[^dcast$]],      function() return do_dcast("") end)
end

-- Teach dcast a spell's landed line (persists). `pattern` is the Swift trigger regex that prints when YOUR
-- cast of `spell` lands (e.g. dcast.learn("magic missile", "^Your magic missile")).
function dcast.learn(spell, pattern)
  spell = (spell or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if spell == "" or not pattern or pattern == "" then echo("[dcast] usage: dcast.learn('<spell>', '<landed-line pattern>')"); return end
  registry[spell] = pattern
  save_learned()
  echo("[dcast] learned '" .. spell .. "' → " .. pattern)
end
function dcast.forget(spell)
  spell = (spell or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  registry[spell] = SEED[spell]   -- back to the seed (nil if it wasn't seeded)
  save_learned()
  echo("[dcast] forgot '" .. spell .. "'" .. (registry[spell] and " (restored the built-in)" or ""))
end
function dcast.known()
  local names = {}
  for k in pairs(registry) do names[#names + 1] = k end
  table.sort(names)
  echo("[dcast] knows: " .. (next(names) and table.concat(names, ", ") or "(nothing)"))
end
_AA_TEST.dcast_registry = registry

doc(dcast, { name = "dcast", sig = "dcast('<spell> [target]')", group = "combat",
  text = "\"Definite cast\": send `c <spell> [target]` and keep re-casting on a fizzle until the spell's own "
      .. "landed line prints. Halts on out-of-mana or after ~25 misses; returns a promise so it chains/pipes. "
      .. "It only casts spells whose landed line it knows — otherwise it tells you and stops. `dcast.learn("
      .. "'<spell>','<landed-pattern>')` teaches one (persists), `dcast.forget('<spell>')` / `dcast.known()`." })
