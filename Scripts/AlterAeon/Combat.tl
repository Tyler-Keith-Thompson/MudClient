-- AlterAeon combat layer — fighting state, inferred opponents, engagement, targeting.
--
-- Split out of AlterAeon.lua. Owns kxwt_fighting, the inferred multi-opponent tracker, the
-- text-derived engaged() state, explicit targeting, and the in_combat() predicate every consumer
-- reads. Interrupts a recovery via the __recovery_cancel hook (Recovery.lua).
--
-- ARCHITECTURE (reactive): the combat wire — kxwt_fighting (the health bar + its -1 combat-end),
-- the melee-round lines, the condition ladder, the targeting confirmations, room change and mob death
-- — are hot Observables (rx.fromTrigger; see the "wire -> streams" block right below, at the TOP of
-- the file). Each stream's subscriber does one job: call the PURE helpers (opponent bookkeeping math,
-- name normalization, is_ally, the parsers — forward-declared above the block, defined further down)
-- that compute the new tracker/engaged state. So the control flow reads as "every game line that can
-- change combat state is a stream, and here's what each drives" — the same shape as AutoFight's and
-- Recovery's wire blocks — instead of imperative trigger bodies mutating the tracker tables by hand.
-- The pure helpers stay plain functions (unit-tested directly, exposed via _AA_TEST); the streams
-- compose and call them.

-- engaged/in_combat are cross-script predicates now declared centrally in mud.d.tl (consumed by
-- AlterAeon/AIPilot/AutoFight/Corpse/Recovery/Equipment/HUD/RPC/Prompt); Combat just ASSIGNS them below.
-- autoVictory (REPL/HUD-facing control table) stays declared locally — Combat owns it.

state = state or {}
_AA_TEST = _AA_TEST or {}

-- Reactive core (__rx: Observables/Subjects built on the host trigger/after primitives). The combat
-- state REACTS to the wire streams below. `_`-prefixed files aren't auto-loaded, so pull _rx here the
-- documented way (dofile fallback for the bare Lua test harness); __promise loads via the loader.
local function boot(n: string) pcall(require, n) end
boot("_rx")
if not __rx then dofile("Scripts/Foundation/_rx.lua") end

-- state.opponents: name -> { pct = 0..100, exact = <bool>, t = <os.time last seen> } (see "Inferred
-- multi-opponent tracking" below for the full rationale). Seeded here since the top block's stream
-- subscribers read/write it via the opps()/opponent_note() helpers forward-declared next.
state.opponents = state.opponents or {}

local record OpponentEntry
  display: string
  pct: integer
  exact: boolean
  t: integer
end

-- The capture table carries both the numbered regex groups AND the full matched line (.line); mud.d.tl's
-- Observable<{string}> only models the array part, so `.line` reads go through this local cast type.
local record Cap
  {string}
  line: string
end

-- Pure helpers the wire streams below call (implementations further down this file — hoisting the
-- reactive block to the top means forward-declaring the "how" it dispatches into).
local opps: function(): {string:OpponentEntry}
local opponent_note: function({string:OpponentEntry}, string, integer, integer, boolean)
local parse_opponent: function(string): (string, integer)
local parse_melee: function(string): (string, string)
local melee_enemy: function(string, string): string
local is_self: function(string): boolean
local maybe_assist: function(number)
local reset_assist: function()
local parse_target_line: function(string): (string, string)

-- ---- "engaged" (fighting without kxwt_fighting) ------------------------------------------------
-- PROVEN BY THE RAW LOGS: with `nocombat` (nomelee) toggled on, the server does NOT send kxwt_fighting
-- AT ALL during a fight — not per round, not even -1 — because you're not in the melee round. The fight
-- exists only as text: melee-round lines between your minions and the mob, the mob's attacks on you,
-- and the condition ladder. So we derive an ENGAGED state from those lines: any melee-round line
-- involving you or an ally refreshes `state.engaged_until`; it expires ENGAGE_TTL seconds after the
-- last one (rounds are ~2s apart), and is cleared eagerly on room change, kxwt_fighting -1, and when
-- the last known opponent dies (kxwt_mdeath) so post-kill looting isn't held up.
local ENGAGE_TTL = 10

-- ══ THE WIRE — every game line that can change combat state, as a stream, and what it drives ══
-- rx.fromTrigger(pattern) is a hot stream of a Swift trigger's matches (registered on first subscribe;
-- the line still displays). Trigger REGEXES run in Swift (not unit-tested); the patterns/anchors below
-- are byte-identical to the old trigger() block, so live matching is unchanged. Subscribed at LOAD
-- (synchronously), so the triggers register in load order — Combat loads before Corpse, which is what
-- the kxwt_fighting -1 ordering below relies on. Guarded on __rx (the dofile fallback above guarantees
-- it here and in the harness); fromTrigger no-ops when the host `trigger` builtin is absent.
local rx = __rx
if rx then
  local T = rx.fromTrigger

  -- kxwt_fighting <pct> <gender> <name> — the CURRENT target's EXACT health bar; also the combat-start
  -- signal. Sets the fighting flag/name/pct, lands the exact reading in the tracker, and cancels any
  -- recovery (a fight rejects it). (Folds together the old two same-line triggers: fighting-state and
  -- the exact opponent_note.)
  local record FightReading
    pct: integer
    name: string
  end
  T([[^kxw[tq]_fighting (\d+) \S+ (.+)$]])
    :map(function(c: {string}): FightReading return { pct = tonumber(c[1]) as integer, name = c[2] } end)
    :subscribe(function(f: FightReading)
      state.fighting, state.fight_pct, state.fight_name = true, f.pct, f.name
      opponent_note(opps(), f.name, f.pct, os.time(), true)   -- current target: exact reading
      if __recovery_cancel then __recovery_cancel("combat started") end   -- a fight cancels (and rejects) recovery
    end)

  -- kxwt_fighting -1 — combat ENDED. ORDER-CRITICAL: this single subscriber clears the fighting state
  -- AND the inferred opponents AND the engaged window (so in_combat() reads false) BEFORE Corpse's own
  -- kxwt_fighting -1 handler runs — Corpse gates its post-kill looting on in_combat(), and Combat loads
  -- (and so subscribes/registers this trigger) before Corpse. Also resets the assist debounce so the
  -- NEXT fight can assist immediately. (Folds the old two same-line triggers into one.)
  T([[^kxw[tq]_fighting -1$]]):subscribe(function(_: {string})
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
    :subscribe(function(c: {string})
      local cap = c as Cap
      local attacker, target = parse_melee(cap.line)
      if not attacker then return end
      local enemy = melee_enemy(attacker, target)
      if not enemy then return end                       -- bystander fight; not ours
      local now = os.time()
      opponent_note(opps(), enemy, nil, now, false)   -- name sighting; keeps any known pct
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
  T([[jumps to your side in battle!]]):subscribe(function(_: {string}) maybe_assist(os.time()) end)
  T([[rescues you and takes over the battle!]]):subscribe(function(_: {string}) maybe_assist(os.time()) end)

  -- Condition-ladder lines while engaged: infer the OTHER mobs' health. Gated on engaged() so an
  -- out-of-combat 'look' condition line can't spawn phantom opponents; skips you/your minions.
  T([[(near death|mortally wounded|awful|pretty hurt|nasty wounds|a few wounds|small wounds|few scratches|excellent)]])
    :subscribe(function(c: {string})
      if not engaged() then return end
      local cap = c as Cap
      local name, pct = parse_opponent(cap.line)
      if name and not is_ally(name) then
        state.engaged_until = os.time() + ENGAGE_TTL
        opponent_note(opps(), name, pct, os.time(), false)
      end
    end)

  -- Targeting confirmations. Acquisition ("steady eye") SEEDS the enemy name immediately — before any
  -- melee round or condition line — and opens the engaged window, so a caster who targets and opens
  -- with a spell has a named combat block up from the first cast. The pronoun form refreshes the window
  -- but carries no name (never creates a nameless entry). The passive `score` report seeds the name only
  -- while already engaged (score is routinely run at rest; a persistent target must not flash the HUD).
  T([[^You keep a steady eye on .+\.$]]):subscribe(function(c: {string})
    local cap = c as Cap
    local _, name = parse_target_line(cap.line)
    if not name or is_ally(name) then return end
    local now = os.time()
    state.engaged_until = now + ENGAGE_TTL
    opponent_note(opps(), name, nil, now, false)
  end)
  T([[^You are already targeting \w+\.$]]):subscribe(function(c: {string})
    local cap = c as Cap
    if parse_target_line(cap.line) == "already" then state.engaged_until = os.time() + ENGAGE_TTL end
  end)
  T([[^You are targeting .+\.$]]):subscribe(function(c: {string})
    local cap = c as Cap
    local kind, name = parse_target_line(cap.line)
    if kind == "report" and name and engaged() and not is_ally(name) then
      opponent_note(opps(), name, nil, os.time(), false)
    end
  end)
  -- Target cleared (UNCONFIRMED wordings — see note above): withdraw the seeded entry only when it has
  -- no combat evidence yet (pct == nil, i.e. it exists purely because we targeted it); a mob with a
  -- health reading is still fighting us regardless of our targeting choice. Never touches the window.
  T([[^You (stop targeting .+|are no longer targeting .+|no longer have a target.*)$]]):subscribe(function(c: {string})
    local cap = c as Cap
    local kind, name = parse_target_line(cap.line)
    if kind ~= "clear" or not name then return end
    local e = opps()[name:lower()]
    if e and e.pct == nil then opps()[name:lower()] = nil end
  end)

  -- Room change abandons the engagement; a mob's death drops its bar immediately (and, if it was the
  -- last opponent with no kxwt melee target left, ends the engaged window NOW so corpse looting — gated
  -- on in_combat() — isn't stalled for the TTL tail).
  T([[^kxw[tq]_rvnum ]]):subscribe(function(_: {string})
    state.opponents = {}; state.engaged_until = nil
  end)
  T([[^kxw[tq]_mdeath (.+)$]]):subscribe(function(c: {string})
    local name = c[1]
    opps()[name:lower()] = nil
    if not state.fighting and not next(opps()) then state.engaged_until = nil end
  end)
end
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ===== Inferred multi-opponent tracking (pure helpers) ==========================================
-- The kxwt protocol reports exactly ONE health bar — kxwt_fighting, the CURRENT target (or -1 when
-- combat ends); the raw logs show one line per update, no multi-mob enumeration. To show bars for the
-- OTHER mobs you're engaged with, we INFER their health from the textual condition ladder AlterAeon
-- prints after hits ("X is near death!", "X has quite a few wounds.") — see 'help injury injuries damage
-- descriptions'. These are ESTIMATES (flagged as such in the HUD). The current target also lands here
-- (exact), so switching targets leaves its last bar behind as an "other".

-- One tracked opponent's reading. `pct` is unknown (nil) for a purely-seeded/melee-only sighting until
-- a condition line supplies an estimate.
opps = function(): {string:OpponentEntry} return state.opponents as {string:OpponentEntry} end

-- Condition phrase -> representative % (band midpoint of the 8-rung injury ladder, plus the even-lower
-- combat "near death"). Substring match, case-insensitive; ordered lowest-first, and longer phrases that
-- contain a shorter one resolve to their own rung because we return the FIRST hit and the specific
-- phrases are listed ahead of any bare word that could shadow them.
local record LadderEntry
  phrase: string
  pct: integer
end
local CONDITION_LADDER: {LadderEntry} = {
  { phrase = "near death",                 pct = 3 },
  { phrase = "mortally wounded",           pct = 8 },
  { phrase = "big nasty wounds",          pct = 42 },   -- before any bare "wounds"; distinct band
  { phrase = "quite a few wounds",        pct = 55 },
  { phrase = "small wounds and bruises",  pct = 68 },
  { phrase = "a few scratches",           pct = 82 },
  { phrase = "pretty hurt",               pct = 28 },
  { phrase = "awful",                     pct = 15 },
  { phrase = "excellent",                 pct = 95 },
}
-- Estimated health % for a line of game text carrying a condition phrase, or nil if it carries none.
local function condition_pct(text: string): integer
  local low = (text or ""):lower()
  for _, e in ipairs(CONDITION_LADDER) do
    if low:find(e.phrase, 1, true) then return e.pct end
  end
  return nil
end

-- Parse a condition-report line into (mob-name, estimated-%), or nil. The subject is the noun phrase
-- before the "is/has/looks" clause; we reject yourself and your own minions ("You…"/"Your…") and reject
-- over-long or multi-sentence subjects (a stray phrase match inside a longer combat line).
parse_opponent = function(line: string): (string, integer)
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
opponent_note = function(tbl: {string:OpponentEntry}, name: string, pct: integer, now: integer, exact: boolean)
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
local record ActiveOpp
  name: string
  pct: integer
  est: boolean
  t: integer
end
local function opponents_active(tbl: {string:OpponentEntry}, now: integer, ttl: integer, exclude: string): {ActiveOpp}
  local exl = exclude and exclude:lower() or nil
  local out: {ActiveOpp} = {}
  for key, o in pairs(tbl or {}) do
    if now - (o.t or 0) > ttl then
      tbl[key] = nil
    elseif key ~= exl then
      out[#out + 1] = { name = o.display or key, pct = o.pct, est = not o.exact, t = o.t }
    end
  end
  table.sort(out, function(a: ActiveOpp, b: ActiveOpp): boolean
    if a.t ~= b.t then return a.t > b.t end
    return a.name < b.name
  end)
  return out
end

local OPP_TTL = 30
-- Public: the HUD's inferred-opponent bars read this. Returns the pruned, sorted "other opponents" list
-- (excludes the current kxwt_fighting target) as { {name, pct, est}, ... }, newest-first.
function active_opponents(now: integer): {ActiveOpp}
  return opponents_active(opps(), now or os.time(), OPP_TTL, state.fight_name as string)
end
doc(active_opponents, { name = "active_opponents", sig = "active_opponents([now])", group = "combat",
  text = "Inferred list of the OTHER mobs you're fighting (not the current kxwt_fighting target), health estimated from the condition ladder. Returns an array of {name, pct, est} newest-first; prunes entries older than 30s." })

-- Is `name` you or one of your groupmates/minions (so a combat line about them is NOT an enemy)?
-- "you"/"You" (the melee lines' pronoun for yourself) counts, as does your kxwt_myname. Global (like
-- engaged/active_opponents) so other scripts — e.g. AutoFight's crowd detection — can classify names.
local record GroupMember
  name: string
end
function is_ally(name: string): boolean
  if not name then return false end
  local low = name:lower()
  if low == "you" then return true end
  if state.name and low == (state.name as string):lower() then return true end   -- kxwt_myname
  for _, m in ipairs((state.group as {GroupMember}) or {}) do if m.name:lower() == low then return true end end
  return false
end
doc(is_ally, { name = "is_ally", sig = "is_ally(name) -> bool", group = "combat",
  text = "True when `name` is you (incl. the \"you\" pronoun / your kxwt_myname) or a current group "
      .. "member/minion — i.e. a combat line about them is friendly, not an enemy sighting." })

-- Are we engaged in a fight, kxwt-confirmed or text-inferred? THE combat predicate — HUD gating,
-- in_combat() and every pilot/equipment consumer sit on this.
function engaged(now: number): boolean
  if state.fighting then return true end
  return ((state.engaged_until as number) or 0) > (now or os.time())
end
doc(engaged, { name = "engaged", sig = "engaged([now])", group = "combat",
  text = "True when you're in a fight: the kxwt_fighting target is live OR combat text (melee-round lines) was seen within the last ~10s. Covers nomelee fights, where the server sends NO kxwt_fighting at all." })

-- ---- auto-assist (a ONE-SHOT fight-starter) -----------------------------------------------------
-- Auto-assist is for when you're NOT yet in a fight your minions started — the "dimmed target" state where
-- the combat text shows your side fighting but you aren't in it. It fires `assist` to jump you in, and that
-- is ITS WHOLE JOB: once a fight has started it LATCHES (state.assisted) and does nothing more for the rest
-- of that fight. Without the latch the many melee-round lines each re-evaluated it, so it fired again at the
-- TAIL of a fight — even one `assist` landing just AFTER the mob died ("No-one in your group is fighting…").
-- The latch clears when the fight ENDS (reset_assist below, and RPC's ncombat clears state.assisted), so the
-- NEXT fight assists again. Off via `autoassist off`.
maybe_assist = function(now: number)
  if not state.auto_assist then return end
  if state.assisted then return end          -- already jumped into THIS fight → auto-assist is done until it ends
  state.assisted = true                        -- latch immediately so the burst of melee lines can't re-assist
  if state.fighting then return end            -- you're already in the melee round → nothing to assist into
  send("assist")
end
-- Combat ended → drop the latch so the NEXT fight can auto-assist. (kxwt_fighting -1 calls this; over the
-- 1.105 RPC the authoritative end is ncombat, which clears state.assisted directly — RPC.lua.)
reset_assist = function() state.assisted = nil end

-- Just YOU (not your minions): the melee lines' pronoun "you", or your kxwt_myname. Lets us tell "I'm in
-- this fight" from "my MINIONS are" — a mob brawling only with your pets shouldn't pin YOU in combat.
is_self = function(name: string): boolean
  if not name then return false end
  local low = name:lower()
  return low == "you" or (state.name ~= nil and low == (state.name as string):lower())
end

-- The canonical melee damage-verb ladder, from 'help default damage strings' (both the flat and the
-- percentage-based combatmode sets), lowercased for matching.
local MELEE_VERBS: {string:boolean} = {
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
parse_melee = function(line: string): (string, string)
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
melee_enemy = function(attacker: string, target: string): string
  local a_ally, t_ally = is_ally(attacker), is_ally(target)
  if a_ally and not t_ally then return target end
  if t_ally and not a_ally then return attacker end
  return nil
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
parse_target_line = function(line: string): (string, string)
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

-- ---- cry of victory (warrior warcry) ------------------------------------------------------------
-- `victory` is a warrior skill (help 'warrior skill cry of victory'): used right AFTER you land the
-- killing blow, it refunds some hp/movement (and morale) and helps stave off stuns — cheap recovery
-- between fights. MUSH-Z ships this as `config autovictory`; we mirror it. Fire `victory` the instant a
-- non-ally mob dies while we're engaged (the killing-blow window). Deduped so a multi-mob round that
-- prints several "is DEAD!" lines only cries once; the game itself no-ops the skill if the last blow
-- wasn't ours (or we lack the skill), so an occasional wasted cry is harmless. Over the 1.105 RPC the
-- death arrives as the plain "<name> is DEAD!" text line (kxwt_mdeath is gone unless kxwt is on), so we
-- key off that line — the same signal Corpse.lua's harvester uses.
state.auto_victory = (state.auto_victory == nil) and true or state.auto_victory
local VICTORY_DEDUP = 2   -- seconds; collapse a multi-kill round into one cry
local last_victory_at: number = 0
local function maybe_victory(name: string, now: number)
  if not state.auto_victory then return end
  if is_ally(name) then return end          -- our own minion / a groupmate died — not our kill to crow over
  if not engaged(now) then return end       -- only right after a fight we were actually in
  now = now or os.time()
  if now - last_victory_at < VICTORY_DEDUP then return end
  last_victory_at = now
  send("victory")
end
if _AA_TEST then
  _AA_TEST.maybe_victory  = maybe_victory
  _AA_TEST.reset_victory  = function() last_victory_at = 0 end
end
trigger([[^(.+) is DEAD!$]], function(_: any, name: string): any maybe_victory(name, nil) end)

-- Control surface: `autoVictory on|off|status` (callable table, so `#autoVictory off` works). Mirrors
-- autoFight / autoHarvest.
local record AutoVictory
  metamethod __call: function(AutoVictory, string)
  on:     function()
  off:    function()
  status: function(): boolean
end
global autoVictory: AutoVictory
autoVictory = setmetatable(autoVictory or {} as AutoVictory, { __call = function(_: AutoVictory, args: string)
  local verb = ((args or ""):match("^%s*(%S*)") or ""):lower()
  if verb == "on"  then state.auto_victory = true;  echo("[victory] cry of victory ON")
  elseif verb == "off" then state.auto_victory = false; echo("[victory] cry of victory OFF")
  else echo("[victory] cry of victory is " .. (state.auto_victory and "ON" or "OFF")) end
end } as metatable<AutoVictory>)
function autoVictory.on()     state.auto_victory = true end
function autoVictory.off()    state.auto_victory = false end
function autoVictory.status(): boolean return state.auto_victory as boolean end
doc(autoVictory, { name = "autoVictory", sig = "autoVictory('on'|'off'|'status')", group = "combat",
  text = "Auto-`victory` (warrior 'cry of victory' warcry): after you land a killing blow it's cried "
      .. "automatically for the hp/move/anti-stun refund. `#autoVictory off` disables; on by default." })

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
function in_combat(): boolean return engaged() end
