-- AlterAeon combat layer — fighting state, inferred opponents, engagement, targeting.
--
-- Split out of AlterAeon.lua. Owns kxwt_fighting, the inferred multi-opponent tracker, the
-- text-derived engaged() state, explicit targeting, and the in_combat() predicate every consumer
-- reads. Interrupts a recovery via the __recovery_cancel hook (Recovery.lua).
--
-- ARCHITECTURE (reactive): the combat wire — kxwt_fighting (the health bar + its -1 combat-end),
-- the melee-round lines, the condition ladder, the targeting confirmations, room change and mob death
-- — are hot Observables (rx.fromTrigger; see the "wire -> streams" block at the bottom). Each stream's
-- subscriber does one job: call the PURE helpers (opponent bookkeeping math, name normalization,
-- is_ally, the parsers) that compute the new tracker/engaged state. So the control flow reads as
-- "every game line that can change combat state is a stream, and here's what each drives" — the same
-- shape as AutoFight's and Recovery's wire blocks — instead of imperative trigger bodies mutating the
-- tracker tables by hand. The pure helpers stay plain functions (unit-tested directly, exposed via
-- _AA_TEST); the streams compose and call them.

state = state or {}
_AA_TEST = _AA_TEST or {}

-- Reactive core (__rx: Observables/Subjects built on the host trigger/after primitives). The combat
-- state REACTS to the wire streams below. `_`-prefixed files aren't auto-loaded, so pull _rx here the
-- documented way (dofile fallback for the bare Lua test harness); __promise loads via the loader.
pcall(require, "_rx")
if not __rx then dofile("Scripts/_rx.lua") end

-- ===== Inferred multi-opponent tracking (pure helpers) ==========================================
-- The kxwt protocol reports exactly ONE health bar — kxwt_fighting, the CURRENT target (or -1 when
-- combat ends); the raw logs show one line per update, no multi-mob enumeration. To show bars for the
-- OTHER mobs you're engaged with, we INFER their health from the textual condition ladder AlterAeon
-- prints after hits ("X is near death!", "X has quite a few wounds.") — see 'help injury injuries damage
-- descriptions'. These are ESTIMATES (flagged as such in the HUD). state.opponents: name ->
-- { pct = 0..100, exact = <bool>, t = <os.time last seen> }. The current target also lands here (exact),
-- so switching targets leaves its last bar behind as an "other".
state.opponents = state.opponents or {}

-- Condition phrase -> representative % (band midpoint of the 8-rung injury ladder, plus the even-lower
-- combat "near death"). Substring match, case-insensitive; ordered lowest-first, and longer phrases that
-- contain a shorter one resolve to their own rung because we return the FIRST hit and the specific
-- phrases are listed ahead of any bare word that could shadow them.
local CONDITION_LADDER = {
  { "near death",                 3 },
  { "mortally wounded",           8 },
  { "big nasty wounds",          42 },   -- before any bare "wounds"; distinct band
  { "quite a few wounds",        55 },
  { "small wounds and bruises",  68 },
  { "a few scratches",           82 },
  { "pretty hurt",               28 },
  { "awful",                     15 },
  { "excellent",                 95 },
}
-- Estimated health % for a line of game text carrying a condition phrase, or nil if it carries none.
local function condition_pct(text)
  local low = (text or ""):lower()
  for _, e in ipairs(CONDITION_LADDER) do
    if low:find(e[1], 1, true) then return e[2] end
  end
  return nil
end

-- Parse a condition-report line into (mob-name, estimated-%), or nil. The subject is the noun phrase
-- before the "is/has/looks" clause; we reject yourself and your own minions ("You…"/"Your…") and reject
-- over-long or multi-sentence subjects (a stray phrase match inside a longer combat line).
local function parse_opponent(line)
  local pct = condition_pct(line)
  if not pct then return nil end
  local subj = line:match("^(.-)%s+[Ii]s%s") or line:match("^(.-)%s+[Hh]as%s")
             or line:match("^(.-)%s+[Ll]ooks?%s")
  if not subj then return nil end
  subj = subj:gsub("^%s+", ""):gsub("%s+$", "")
  if subj == "" or #subj > 40 or subj:find("[%.!%?]") then return nil end
  local lw = subj:lower()
  if lw:find("^your?%f[%A]") then return nil end   -- "you"/"your <minion>"
  return subj, pct
end

-- Record (or refresh) an opponent's reading. Keyed by LOWERCASED name (the wire mixes "An orc bachelor"
-- and "an orc bachelor" for the same mob); the display name is the first-seen original. `exact` is true
-- only for the kxwt_fighting target. A nil pct (a melee sighting with no condition phrase) refreshes the
-- timestamp but never clobbers a known health estimate.
local function opponent_note(tbl, name, pct, now, exact)
  if not name then return end
  local key = name:lower()
  local e = tbl[key]
  if e then
    e.t = now
    if pct ~= nil then e.pct, e.exact = pct, exact == true end
  else
    tbl[key] = { display = name, pct = pct, exact = exact == true, t = now }
  end
end

-- Live opponents as an array, sorted most-recently-seen first (name breaks ties deterministically),
-- excluding `exclude` (the current target, shown by its own exact bar; compared case-insensitively) and
-- dropping entries not seen within `ttl` seconds. Prunes the expired entries from `tbl` in place.
local function opponents_active(tbl, now, ttl, exclude)
  local exl = exclude and exclude:lower() or nil
  local out = {}
  for key, o in pairs(tbl or {}) do
    if now - (o.t or 0) > ttl then
      tbl[key] = nil
    elseif key ~= exl then
      out[#out + 1] = { name = o.display or key, pct = o.pct, est = not o.exact, t = o.t }
    end
  end
  table.sort(out, function(a, b)
    if a.t ~= b.t then return a.t > b.t end
    return a.name < b.name
  end)
  return out
end

local OPP_TTL = 30
-- Public: the HUD's inferred-opponent bars read this. Returns the pruned, sorted "other opponents" list
-- (excludes the current kxwt_fighting target) as { {name, pct, est}, ... }, newest-first.
function active_opponents(now)
  return opponents_active(state.opponents, now or os.time(), OPP_TTL, state.fight_name)
end
doc(active_opponents, { name = "active_opponents", sig = "active_opponents([now])", group = "combat",
  text = "Inferred list of the OTHER mobs you're fighting (not the current kxwt_fighting target), health estimated from the condition ladder. Returns an array of {name, pct, est} newest-first; prunes entries older than 30s." })

-- Is `name` you or one of your groupmates/minions (so a combat line about them is NOT an enemy)?
-- "you"/"You" (the melee lines' pronoun for yourself) counts, as does your kxwt_myname. Global (like
-- engaged/active_opponents) so other scripts — e.g. AutoFight's crowd detection — can classify names.
function is_ally(name)
  if not name then return false end
  local low = name:lower()
  if low == "you" then return true end
  if state.name and low == state.name:lower() then return true end   -- kxwt_myname
  for _, m in ipairs(state.group or {}) do if m.name:lower() == low then return true end end
  return false
end
doc(is_ally, { name = "is_ally", sig = "is_ally(name) -> bool", group = "combat",
  text = "True when `name` is you (incl. the \"you\" pronoun / your kxwt_myname) or a current group "
      .. "member/minion — i.e. a combat line about them is friendly, not an enemy sighting." })

-- ---- "engaged" (fighting without kxwt_fighting) ------------------------------------------------
-- PROVEN BY THE RAW LOGS: with `nocombat` (nomelee) toggled on, the server does NOT send kxwt_fighting
-- AT ALL during a fight — not per round, not even -1 — because you're not in the melee round. The fight
-- exists only as text: melee-round lines between your minions and the mob, the mob's attacks on you,
-- and the condition ladder. So we derive an ENGAGED state from those lines: any melee-round line
-- involving you or an ally refreshes `state.engaged_until`; it expires ENGAGE_TTL seconds after the
-- last one (rounds are ~2s apart), and is cleared eagerly on room change, kxwt_fighting -1, and when
-- the last known opponent dies (kxwt_mdeath) so post-kill looting isn't held up.
local ENGAGE_TTL = 10

-- The canonical melee damage-verb ladder, from 'help default damage strings' (both the flat and the
-- percentage-based combatmode sets), lowercased for matching.
local MELEE_VERBS = {
  annoys = true, scratches = true, hits = true, injures = true, wounds = true, mauls = true,
  decimates = true, devastates = true, maims = true, mutilates = true, dismembers = true,
  disembowels = true, massacres = true, obliterates = true, demolishes = true, destroys = true,
  annihilates = true, misses = true,
  -- percentage-mode edged/pointed + blunt variants
  nicks = true, cuts = true, gouges = true, gashes = true, lacerates = true, shreds = true,
  mangles = true, rends = true, thumps = true, mars = true, batters = true, thrashes = true,
  clobbers = true, smashes = true, pulverizes = true,
}

-- Parse a melee-round line into (attacker, target), or nil. Forms:
--   "<attacker>'s <skill> <verb> <target>."   (greedy attacker match so a name containing 's survives)
--   "Your <skill> <verb> <target>."           (your own melee swings)
-- The *** BIG DAMAGE *** decorations are stripped first. Lua patterns can't alternate on the verb set,
-- so after splitting off the attacker we SCAN the remaining words for the first damage verb; everything
-- before it is the skill (1..4 words) and everything after is the target.
local function parse_melee(line)
  local t = (line or ""):gsub("%*", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  local attacker, rest = t:match("^(.+)'s (.+)$")
  if not attacker then
    rest = t:match("^[Yy]our (.+)$")
    if rest then attacker = "you" end
  end
  if not rest then return nil end
  local body = rest:match("^(.-)[%.!]+$")          -- combat sends always end in . or !
  if not body then return nil end
  local before = 0
  for s, word in body:gmatch("()(%S+)") do
    if MELEE_VERBS[word:lower()] and before >= 1 and before <= 4 then
      local target = body:sub(s + #word + 1)
      if target ~= "" then return attacker, target end
    end
    before = before + 1
  end
  return nil
end

-- The enemy in an (attacker, target) melee pair: whichever side is NOT you/an ally. nil when the pair
-- doesn't involve your side at all (bystander mob-vs-mob), or when both sides are yours.
local function melee_enemy(attacker, target)
  local a_ally, t_ally = is_ally(attacker), is_ally(target)
  if a_ally and not t_ally then return target end
  if t_ally and not a_ally then return attacker end
  return nil
end

-- Are we engaged in a fight, kxwt-confirmed or text-inferred? THE combat predicate — HUD gating,
-- in_combat() and every pilot/equipment consumer sit on this.
function engaged(now)
  if state.fighting then return true end
  return (state.engaged_until or 0) > (now or os.time())
end
doc(engaged, { name = "engaged", sig = "engaged([now])", group = "combat",
  text = "True when you're in a fight: the kxwt_fighting target is live OR combat text (melee-round lines) was seen within the last ~10s. Covers nomelee fights, where the server sends NO kxwt_fighting at all." })

-- ---- auto-assist (pure decision + debounce) -----------------------------------------------------
-- When your minions (or you) are getting hit by an enemy but you're NOT in the melee round yourself —
-- engaged() is true from the combat text, yet state.fighting is false (no kxwt_fighting), the "dimmed
-- target" state — jump into the fight with `assist` so you (and AutoFight) actually engage. Called off
-- the melee-round stream (which has already identified the enemy and confirmed your side is in it),
-- debounced so the many rounds-per-second lines don't spam `assist`. Off via `autoassist off`.
local ASSIST_COOLDOWN = 3   -- seconds between assist attempts (retries if the first didn't pull you in)
local assist_at = 0
local function maybe_assist(now)
  if not state.auto_assist then return end
  if state.fighting then return end          -- already in the melee round → nothing to assist into
  now = now or os.time()
  if now < assist_at + ASSIST_COOLDOWN then return end
  assist_at = now
  send("assist")
end
-- kxwt_fighting -1 (combat ended) resets the debounce so the NEXT fight assists immediately.
local function reset_assist() assist_at = 0 end

-- Just YOU (not your minions): the melee lines' pronoun "you", or your kxwt_myname. Lets us tell "I'm in
-- this fight" from "my MINIONS are" — a mob brawling only with your pets shouldn't pin YOU in combat.
local function is_self(name)
  if not name then return false end
  local low = name:lower()
  return low == "you" or (state.name ~= nil and low == state.name:lower())
end

-- ---- explicit targeting (the `target` command) --------------------------------------------------
-- There is NO kxwt target tag (the full documented tag vocabulary has nothing target-shaped;
-- kxwt_fighting is the only enemy tag and it's melee-gated) — but the game confirms targeting in TEXT.
-- Researched wordings, VERBATIM from human-traces:
--   "You keep a steady eye on a druidess."      <- `target <name>` acquisition (carries the NAME)
--   "You are already targeting him."            <- re-target, pronoun only (no name)
--   "You are targeting Fraxis Hammerhand."      <- passive report inside `score` output
-- Target-CLEARED wordings ('target noone') appear NOWHERE in the traces or help corpus — the forms
-- below ("You stop targeting …" / "You are no longer targeting …" / "You no longer have a target") are
-- best guesses, UNCONFIRMED LIVE; adjust here if the real send differs.
-- Classify a targeting line -> kind ("acquire"|"already"|"report"|"clear"), name-or-nil.
local function parse_target_line(line)
  local t = line or ""
  local name = t:match("^You keep a steady eye on (.+)%.$")
  if name then return "acquire", name end
  if t:match("^You are already targeting %a+%.$") then return "already", nil end
  name = t:match("^You are targeting (.+)%.$")
  if name then return "report", name end
  name = t:match("^You stop targeting (.+)%.$") or t:match("^You are no longer targeting (.+)%.$")
  if name then return "clear", name end
  if t:match("^You no longer have a target") then return "clear", nil end
  return nil
end

-- ===== live wire -> streams -> tracker / engaged / assist ========================================
-- rx.fromTrigger(pattern) is a hot stream of a Swift trigger's matches (registered on first subscribe;
-- the line still displays). Each subscriber calls the pure helpers above to update the shared `state`
-- the HUD/Recovery/Corpse read. Trigger REGEXES run in Swift (not unit-tested); the patterns/anchors
-- below are byte-identical to the old trigger() block, so live matching is unchanged. Subscribed at
-- LOAD (synchronously), so the triggers register in load order — Combat loads before Corpse, which is
-- what the kxwt_fighting -1 ordering below relies on. Guarded on __rx (the dofile fallback at the top
-- guarantees it here and in the harness); fromTrigger no-ops when the host `trigger` builtin is absent.
local rx = __rx
if rx then
  local T = rx.fromTrigger

  -- kxwt_fighting <pct> <gender> <name> — the CURRENT target's EXACT health bar; also the combat-start
  -- signal. Sets the fighting flag/name/pct, lands the exact reading in the tracker, and cancels any
  -- recovery (a fight rejects it). (Folds together the old two same-line triggers: fighting-state and
  -- the exact opponent_note.)
  T([[^kxwt_fighting (\d+) \S+ (.+)$]])
    :map(function(c) return { pct = tonumber(c[1]), name = c[2] } end)
    :subscribe(function(f)
      state.fighting, state.fight_pct, state.fight_name = true, f.pct, f.name
      opponent_note(state.opponents, f.name, f.pct, os.time(), true)   -- current target: exact reading
      if __recovery_cancel then __recovery_cancel("combat started") end   -- a fight cancels (and rejects) recovery
    end)

  -- kxwt_fighting -1 — combat ENDED. ORDER-CRITICAL: this single subscriber clears the fighting state
  -- AND the inferred opponents AND the engaged window (so in_combat() reads false) BEFORE Corpse's own
  -- kxwt_fighting -1 handler runs — Corpse gates its post-kill looting on in_combat(), and Combat loads
  -- (and so subscribes/registers this trigger) before Corpse. Also resets the assist debounce so the
  -- NEXT fight can assist immediately. (Folds the old two same-line triggers into one.)
  T([[^kxwt_fighting -1$]]):subscribe(function()
    state.fighting, state.fight_name, state.fight_pct = false, nil, nil
    state.opponents = {}
    state.engaged_until = nil
    reset_assist()
  end)

  -- Melee-round lines ("<attacker>'s <skill> <verb> <target>." / "Your <verb> <target>."). Each names
  -- the enemy and proves engagement: record a name sighting (keeps any known pct), assist if your side
  -- is fighting and you aren't, and — only when YOU (not just a minion) are in it — open the engaged
  -- window (which gates goto/explore/rest) and cancel recovery. A mob brawling only with your MINIONS
  -- keeps them busy but doesn't pin YOU in combat (else `goto` refuses while your pets mop up adds).
  -- CASE-INSENSITIVE verb match (?i:…) + tolerate the crit decoration `*** VERB ***`: AlterAeon UPPERCASES
  -- the verb on a critical hit ("… MASSACRES …", sometimes "… *** MASSACRES ***"). The old lowercase-only,
  -- case-sensitive pattern silently skipped every crit line — so a fight whose first rounds were all crits
  -- never registered the opponent, never opened the engaged window, and (the reported bug) never fired
  -- auto-assist, forcing a manual `ass`. parse_melee already lower()s + strips `*`, so only this gate moved.
  T([[\S+'s [a-z *]*(?i:annoys|scratches|hits|injures|wounds|mauls|decimates|devastates|maims|mutilates|dismembers|disembowels|massacres|obliterates|demolishes|destroys|annihilates|misses|nicks|cuts|gouges|gashes|lacerates|shreds|mangles|rends|thumps|mars|batters|thrashes|clobbers|smashes|pulverizes) ]])
    :subscribe(function(c)
      local attacker, target = parse_melee(c.line)
      if not attacker then return end
      local enemy = melee_enemy(attacker, target)
      if not enemy then return end                       -- bystander fight; not ours
      local now = os.time()
      opponent_note(state.opponents, enemy, nil, now, false)   -- name sighting; keeps any known pct
      maybe_assist(now)                                  -- your side is fighting; jump in if you aren't
      if is_self(attacker) or is_self(target) then
        state.engaged_until = now + ENGAGE_TTL
        if __recovery_cancel then __recovery_cancel("combat started") end  -- fights (kxwt-visible or not) cancel recovery
      end
    end)

  -- EARLIEST assist signal: a pet/minion "jumps to your side in battle!" (or a tank rescues you) the instant
  -- combat starts — BEFORE any melee-round line, and immune to the crit-verb gap above. Your side is now in
  -- a fight; if you aren't yet, jump in. Names no enemy, so it drives assist only (maybe_assist self-guards
  -- on not-already-fighting + the debounce, so a second minion joining mid-fight is a harmless no-op).
  T([[jumps to your side in battle!]]):subscribe(function() maybe_assist(os.time()) end)
  T([[rescues you and takes over the battle!]]):subscribe(function() maybe_assist(os.time()) end)

  -- Condition-ladder lines while engaged: infer the OTHER mobs' health. Gated on engaged() so an
  -- out-of-combat 'look' condition line can't spawn phantom opponents; skips you/your minions.
  T([[(near death|mortally wounded|awful|pretty hurt|nasty wounds|a few wounds|small wounds|few scratches|excellent)]])
    :subscribe(function(c)
      if not engaged() then return end
      local name, pct = parse_opponent(c.line)
      if name and not is_ally(name) then
        state.engaged_until = os.time() + ENGAGE_TTL
        opponent_note(state.opponents, name, pct, os.time(), false)
      end
    end)

  -- Targeting confirmations. Acquisition ("steady eye") SEEDS the enemy name immediately — before any
  -- melee round or condition line — and opens the engaged window, so a caster who targets and opens
  -- with a spell has a named combat block up from the first cast. The pronoun form refreshes the window
  -- but carries no name (never creates a nameless entry). The passive `score` report seeds the name only
  -- while already engaged (score is routinely run at rest; a persistent target must not flash the HUD).
  T([[^You keep a steady eye on .+\.$]]):subscribe(function(c)
    local _, name = parse_target_line(c.line)
    if not name or is_ally(name) then return end
    local now = os.time()
    state.engaged_until = now + ENGAGE_TTL
    opponent_note(state.opponents, name, nil, now, false)
  end)
  T([[^You are already targeting \w+\.$]]):subscribe(function(c)
    if parse_target_line(c.line) == "already" then state.engaged_until = os.time() + ENGAGE_TTL end
  end)
  T([[^You are targeting .+\.$]]):subscribe(function(c)
    local kind, name = parse_target_line(c.line)
    if kind == "report" and name and engaged() and not is_ally(name) then
      opponent_note(state.opponents, name, nil, os.time(), false)
    end
  end)
  -- Target cleared (UNCONFIRMED wordings — see note above): withdraw the seeded entry only when it has
  -- no combat evidence yet (pct == nil, i.e. it exists purely because we targeted it); a mob with a
  -- health reading is still fighting us regardless of our targeting choice. Never touches the window.
  T([[^You (stop targeting .+|are no longer targeting .+|no longer have a target.*)$]]):subscribe(function(c)
    local kind, name = parse_target_line(c.line)
    if kind ~= "clear" or not name then return end
    local e = state.opponents[name:lower()]
    if e and e.pct == nil then state.opponents[name:lower()] = nil end
  end)

  -- Room change abandons the engagement; a mob's death drops its bar immediately (and, if it was the
  -- last opponent with no kxwt melee target left, ends the engaged window NOW so corpse looting — gated
  -- on in_combat() — isn't stalled for the TTL tail).
  T([[^kxwt_rvnum ]]):subscribe(function()
    state.opponents = {}; state.engaged_until = nil
  end)
  T([[^kxwt_mdeath (.+)$]]):subscribe(function(c)
    local name = c[1]
    state.opponents[name:lower()] = nil
    if not state.fighting and not next(state.opponents) then state.engaged_until = nil end
  end)
end

-- ===== test seams (the specs drive these pure helpers directly; opponents_spec / assist_spec) =====
_AA_TEST.condition_pct     = condition_pct
_AA_TEST.parse_opponent    = parse_opponent
_AA_TEST.opponent_note     = opponent_note
_AA_TEST.opponents_active  = opponents_active
_AA_TEST.parse_melee       = parse_melee
_AA_TEST.melee_enemy       = melee_enemy
_AA_TEST.is_ally           = is_ally
_AA_TEST.ENGAGE_TTL        = ENGAGE_TTL
_AA_TEST.parse_target_line = parse_target_line
_AA_TEST.maybe_assist      = maybe_assist
_AA_TEST.reset_assist      = reset_assist
_AA_TEST.is_self           = is_self

-- THE combat predicate for every consumer (pilot navigation/prompt gating, equipment swaps, corpse
-- automation, recovery). Broadened to the engaged() state: in a nomelee fight kxwt_fighting is never
-- sent, but you're still very much in combat — navigation must not walk off, eq swaps must not start,
-- recovery must not begin, and the pilot must be told it's fighting. Consumers that specifically need
-- "am I in the melee round with an exact target" should read state.fighting directly.
function in_combat() return engaged() end
