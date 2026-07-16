-- Events.tl — the domain-event layer for AlterAeon scripts (CLAUDE.md's "reactive chain at the top"
-- rule): named, typed Observables derived from the kxwt wire and from state transitions, so a consumer
-- script's own top reads as `onX:subscribe(handler)` instead of re-deriving "did combat just start" /
-- "is mana low" bookkeeping itself. Declared as globals in alteraeon.d.tl, typed EventObservable<T> — a
-- GLOBAL structural stand-in there (unlike foundation.d.tl's own LOCAL Observable<T> — see that file's
-- header note) since this one shared type name has to be spellable from both this producer and every
-- consumer script.
--
-- THIS IS A STARTER SET, not exhaustive — adopted so far by AutoFight.lua (onSpellLanded, onEnemyDied);
-- see AutoFight.tl's header note on what ISN'T adopted yet and why (its opener->probe->nuke->finish
-- sequence is a PROMISE flow keyed off precise pct/name payloads these generic events don't carry, and
-- its tank-rescue latch has bespoke sticky-name semantics the autofight_spec.lua tank tests pin exactly —
-- forcing either onto the generic events here would risk changing behavior, so they keep their own wiring).
--
-- SOURCES:
--   Line-sourced (rx.fromTrigger, a hot per-line stream; the line still displays):
--     onSpellUp / onSpellDown  — kxwt_spellup / kxwt_spelldown
--     onMinionDied             — kxwt_ydeath (one of YOUR OWN minions died; enemies are kxwt_mdeath)
--     onEnemyDied              — kxwt_mdeath
--     onCryOfVictory           — "You feel victorious!", the game's own positive signal that YOU landed
--                                 a killing blow (never fires for a summon/minion's death)
--     onSpellLanded            — merge of the game's damage/opener spell-landed lines
--   State-derived (transition events, sampled off pre-existing PUSH sources — the kxwt_prompt vitals line
--   and the kxwt_fighting/kxwt_position lines — never a timer/`every` poll):
--     onCombatStart / onCombatEnd — engaged() edge, sampled on the kxwt_prompt tick
--     onPostureChange             — kxwt_position text change
--     onManaLow / onHPLow         — mana/hp ratio crossing below a low threshold, sampled on the same tick
--     onNewOpponent               — the kxwt_fighting target name changing
--     onTankDown                  — the kxwt-grouped, tanking (M+T flagged) minion confirmed gone within
--                                    TANK_DEATH_WINDOW seconds of a kxwt_ydeath (generalizes the detector
--                                    AutoFight.tl's tank-rescue block pioneered — state.group_flags is
--                                    already game-generic, not AutoFight-specific)
--
-- KNOWN GAP: the state-derived events sample the kxwt_prompt/kxwt_position TRIGGER lines specifically. A
-- nomelee session using the kxwq_hud machine prompt instead (Prompt.tl) bypasses the trigger pipeline for
-- those tags (see Prompt.tl's own header: "does NOT rewire AutoFight ... deliberately out of scope here"),
-- so under kxwq_hud these particular events go quiet — same documented scope line Prompt.tl already draws.
-- A future pass can also tap on_prompt; left as a gap for this starter set.

state = state or {}
_EVENTS_TEST = _EVENTS_TEST or {}

local function boot(n: string) pcall(require, n) end
boot("_rx")
if not __rx then dofile("Scripts/Foundation/_rx.lua") end
local rx = __rx

-- rx.merge/rx.subject() aren't members of the GLOBAL Rx record (only subject/fromTrigger/of/empty/never/
-- throw/merge<Observable<T>>/fromPromise are — foundation.d.tl), so this file's merge/subject calls are
-- cast into local structural stand-ins at the two call sites that need them (mirrors AutoFight.tl's own
-- RxExt convention), then the RESULT is cast to the global EventObservable<T> at the export boundary.
local record RxExt
  merge: function(EventObservable<string>...): EventObservable<string>
end
local record Sub<T>
  onNext:       function(Sub<T>, T)
  asObservable: function(Sub<T>): EventObservable<T>
end

if rx then
  local T = rx.fromTrigger

  -- ===== line-sourced events ========================================================================
  onSpellUp    = T([[^kxw[tq]_spellup (.+)$]]):map(function(c: {string}): string return c[1] end) as EventObservable<string>
  onSpellDown  = T([[^kxw[tq]_spelldown (.+)$]]):map(function(c: {string}): string return c[1] end) as EventObservable<string>
  onMinionDied = T([[^kxw[tq]_ydeath (.+)$]]):map(function(c: {string}): string return c[1] end) as EventObservable<string>
  onEnemyDied  = T([[^kxw[tq]_mdeath (.+)$]]):map(function(c: {string}): string return c[1] end) as EventObservable<string>

  -- The killing-blow moment: the game prints "You feel victorious!" only when YOU land a kill worth
  -- crowing over (mirrors Combat.lua's maybe_victory trigger exactly) — a summon/minion dying never
  -- produces this line, so no ally/engaged filtering is needed here, unlike the old "is DEAD!" scheme.
  onCryOfVictory = T([[^You feel victorious!$]])
    :map(function(_: {string}): boolean return true end)
    as EventObservable<boolean>

  -- Every damage/opener spell-landed line the routine cares about (verbatim wire strings; see AutoFight.tl's
  -- OLD copy of this merge for the same patterns' provenance/verification notes).
  local function tag(pattern: string, spell: string): EventObservable<string>
    return T(pattern):map(function(_: {string}): string return spell end) as EventObservable<string>
  end
  onSpellLanded = (rx as RxExt).merge(
    tag([[^A .* bolt of lightning leaps from you to ]], "lightning"),
    tag([[^You create and magically throw bolts of ice at ]], "icebolt"),
    tag([[^You (?:conjure and )?throw a .* fireball at ]], "fireball"),
    tag([[^You use a small crystal to focus your powers and throw a confusing wash of color and force at ]], "prism"),
    tag([[^Spiked flowers of ice quickly form on everything in a ring around you!$]], "frostflower"),
    tag([[^A shower of .* sparks suddenly engulfs]], "shower"),
    tag([[^An ethereal hand appears and attacks .+ from behind!$]], "tarrants"),
    tag([[^You tap your life, and .* toward ]], "bloodmist"))

  -- ===== state-derived transition events ============================================================
  -- Sampled off the kxwt_prompt vitals line — a push source every vitals update already rides in on (per
  -- CLAUDE.md: prefer a real push source over polling with `every`). AlterAeon.lua's own field()-based
  -- trigger on this same pattern registers first (Events.tl loads after AlterAeon — case-insensitive
  -- alphabetical), so state.hp/mana/etc. are already fresh by the time this subscriber runs (same-pattern
  -- triggers fire in registration order — CLAUDE.md). Bridged through `tickSub` (a plain Subject) rather
  -- than chained directly off `T(...)`'s Observable so _EVENTS_TEST.tick() can drive the derived events
  -- below directly in the bare test harness, where `trigger()` is a no-op stub (see driver.lua) and so
  -- the real wire line never fires.
  local tickSub = rx.subject() as Sub<{string}>
  T([[^kxw[tq]_prompt (\d+) (\d+) (\d+) (\d+) (\d+) (\d+)]]):subscribe(function(c: {string}) tickSub:onNext(c) end)
  local tickS = tickSub:asObservable()
  _EVENTS_TEST.tick = function() tickSub:onNext({}) end

  local MANA_LOW_FRAC = 0.2
  local HP_LOW_FRAC   = 0.3

  local function mana_ratio(): number
    local m, mm = state.mana as number, state.maxmana as number
    if not m or not mm or mm <= 0 then return nil end
    return m / mm
  end
  local function hp_ratio(): number
    local h, mh = state.hp as number, state.maxhp as number
    if not h or not mh or mh <= 0 then return nil end
    return h / mh
  end

  -- {prev, cur}: scan (not distinctUntilChanged) so the very FIRST sample a subscriber ever sees carries a
  -- nil `prev` and can never look like a transition — distinctUntilChanged alone passes its first value
  -- unconditionally, which would spuriously fire onCombatEnd the instant a fresh subscriber's first tick
  -- happens to land on "not engaged" (nothing actually ENDED; there was no prior sample to compare against).
  local record Edge
    prev: boolean
    cur:  boolean
  end
  local function combat_edge(): EventObservable<Edge>
    return tickS
      :map(function(_: {string}): boolean return (engaged and engaged()) or false end)
      :scan(function(acc: Edge, cur: boolean): Edge return { prev = acc.cur, cur = cur } end, { prev = nil, cur = nil } as Edge)
      as EventObservable<Edge>
  end
  onCombatStart = combat_edge()
    :filter(function(e: Edge): boolean return e.prev ~= nil and e.prev ~= e.cur and e.cur end)
    :map(function(e: Edge): boolean return e.cur end)
    as EventObservable<boolean>
  onCombatEnd = combat_edge()
    :filter(function(e: Edge): boolean return e.prev ~= nil and e.prev ~= e.cur and not e.cur end)
    :map(function(e: Edge): boolean return e.cur end)
    as EventObservable<boolean>

  -- A {low, ratio} reading per tick: distinctUntilChanged compares ONLY `.low` (the edge), so repeated
  -- ticks below/above threshold don't re-fire — exactly the "crossed" semantics, not a continuous readout.
  local record LowReading
    low:   boolean
    ratio: number
  end
  onManaLow = tickS
    :map(function(_: {string}): LowReading local r = mana_ratio(); return { low = (r ~= nil and r < MANA_LOW_FRAC), ratio = r } end)
    :distinctUntilChanged(function(a: LowReading, b: LowReading): boolean return a.low == b.low end)
    :filter(function(r: LowReading): boolean return r.low end)
    :map(function(r: LowReading): number return r.ratio end)
    as EventObservable<number>
  onHPLow = tickS
    :map(function(_: {string}): LowReading local r = hp_ratio(); return { low = (r ~= nil and r < HP_LOW_FRAC), ratio = r } end)
    :distinctUntilChanged(function(a: LowReading, b: LowReading): boolean return a.low == b.low end)
    :filter(function(r: LowReading): boolean return r.low end)
    :map(function(r: LowReading): number return r.ratio end)
    as EventObservable<number>

  onPostureChange = T([[^kxw[tq]_position (.+)$]])
    :map(function(c: {string}): string return c[1] end)
    :distinctUntilChanged()
    as EventObservable<string>

  -- The kxwt_fighting target NAME changing (including nil -> first sighting) — a generic "new opponent"
  -- signal. AutoFight.tl's own on_fight() detects target rollover more precisely (name change OR a health
  -- jump past a regen margin, needed for its AOE/probe bookkeeping) — this is the simpler, reusable version.
  onNewOpponent = T([[^kxw[tq]_fighting (\d+) \S+ (.+)$]])
    :map(function(c: {string}): string return c[2] end)
    :distinctUntilChanged()
    as EventObservable<string>

  -- ---- onTankDown: generalized tank-death detection --------------------------------------------------
  -- Your TANK is a minion of yours (kxwt group flag M) that's TANKING (flag T) — state.group_flags is
  -- kxwt's own roster+flags (AlterAeon.lua), game-generic, not AutoFight-specific. kxwt_ydeath latches "a
  -- minion of mine died"; the following kxwt_group_end says whether it was the tank (our remembered tank is
  -- now gone) within a short window — a stale RPC roster (kxwt_group streams every tick) can repeat BEFORE
  -- the tank is finally dropped, so the latch must survive several stale group_ends, not just the first.
  local function current_tank_name(): string
    for name, f in pairs((state.group_flags as {string:string}) or {}) do
      if f:find("M", 1, true) and f:find("T", 1, true) then return name end
    end
    return nil
  end
  local TANK_DEATH_WINDOW = 6   -- seconds a ydeath stays "fresh" while waiting for the roster to drop the tank
  local tank_name: string = nil
  local tank_ydeath_at: number = nil
  local tankDownS = rx.subject() as Sub<string>

  local function on_tank_ydeath(_: {string}) tank_ydeath_at = os.time() end
  local function on_tank_group_end(_: {string})
    local t = current_tank_name()
    if t then tank_name = t; return end              -- someone's tanking → track it (leave the latch alone)
    if tank_name then
      local recent = tank_ydeath_at and (os.time() - tank_ydeath_at) <= TANK_DEATH_WINDOW
      local dead = tank_name
      tank_ydeath_at, tank_name = nil, nil            -- consume the latch now the tank is confirmed gone
      if recent then tankDownS:onNext(dead) end
    end
  end
  T([[^kxw[tq]_ydeath ]]):subscribe(on_tank_ydeath)
  T([[^kxw[tq]_group_end$]]):subscribe(on_tank_group_end)
  onTankDown = tankDownS:asObservable() as EventObservable<string>

  -- Test seam: the pure ratio helpers + the tank-death detector's handlers, driven directly since
  -- `trigger()` is a no-op stub in the bare harness (mirrors Combat.tl/AutoFight.tl's own _AA_TEST/
  -- _AF_TEST convention of exposing the exact functions a real trigger would call).
  _EVENTS_TEST.mana_ratio = mana_ratio
  _EVENTS_TEST.hp_ratio = hp_ratio
  _EVENTS_TEST.current_tank_name = current_tank_name
  _EVENTS_TEST.tank_ydeath = function() on_tank_ydeath({}) end
  _EVENTS_TEST.tank_group_end = function() on_tank_group_end({}) end
  _EVENTS_TEST.tank_death_window = TANK_DEATH_WINDOW
  _EVENTS_TEST.reset_tank = function() tank_name, tank_ydeath_at = nil, nil end
end
