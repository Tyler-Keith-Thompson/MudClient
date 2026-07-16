-- alteraeon.d.tl — type declarations for AlterAeon-specific globals (game state, game-semantic hooks,
-- cross-script game logic, the callable game-surface tables). Loaded after foundation.d.tl (see
-- env.d.tl), so it may reference foundation's global types (e.g. Promise<any>).

-- The shared game state table. Genuinely heterogeneous (vitals, position, flags, roster, …), so its
-- value type is `any` on purpose — the typing win is in the pure logic that reads/writes it, not here.
global state: {string:any}

-- ---- Game-semantic lifecycle hooks — optional globals a script may define; the host calls whichever
-- exist (see LuaScriptEngine.swift callGlobal* call sites).
global on_prompt:    function(string)
global on_update:    function()
global on_inventory: function()

-- ---- Cross-script game globals other (still-Lua) scripts define/read, that a migrated script may need to
-- call. Genuinely dynamic at these edges (state-machine callbacks, HUD data feeds); `any`/permissive
-- where the shape isn't pinned down by a single owner.
global apply_fight:            function(? number, ? string)
global active_opponents:       function(? number): {any}
global is_ally:                function(string): boolean
global engaged:                function(? number): boolean   -- Combat.lua: text-derived in-combat predicate
global in_combat:              function(): boolean           -- Combat.lua: engaged(); every pilot/eq/corpse consumer sits on it
global smap_on_map_update:     function()                    -- AIPilot.lua: called after a ;smap; grid update
global minimap:                function(? integer, ? integer): any   -- AIPilot.lua: room-graph minimap renderer (HUD consumes)
global describe_state:         function(): string           -- AlterAeon.lua: human-readable state dump (Recovery/AIPilot consume)
global game_command_reference: function(): string           -- AlterAeon.lua: AI command reference (AIPilot consumes)
global __autofight_prompt:     function(? number, ? string)
global __recovery_on_vitals:   function()
global __recovery_on_position: function(any, boolean)
global __recovery_on_group:    function()
global __recovery_on_spellup:   function(any)
global __recovery_on_spelldown: function(any)
global __recovery_cancel:       function(? string)
global __ready:                 function(any): any

-- ---- Callable game-surface tables — the deliberate dynamic boundary. Each is a `__call` metatable
-- (so `eq("scan")` and `#eq scan` both work); typing them precisely isn't the point, the pure logic
-- behind each member is.
global eq: any
global pilot: any
global kxwt: any
global trivia: any
global dcast: any

-- ---- Domain events (Events.tl) — the named, typed Observable surface every script subscribes to at its
-- top (CLAUDE.md's "reactive chain at the top" rule). Observable<T> is LOCAL to foundation.d.tl (see
-- _rx.tl's header note on why every rx consumer re-declares its own view); EventObservable<T> mirrors just
-- the operators a subscriber composes with (map/filter/distinctUntilChanged/tap/…), but — UNLIKE
-- Observable<T> — is declared GLOBAL here on purpose: it's the one shared cross-file type name Events.tl
-- (the single producer) and every consumer script (AutoFight.tl, …) both need to spell — Events.tl builds
-- the real thing with __rx and casts into this shape at its export boundary, exactly like _rx.tl's own
-- `__rx = M as Rx`.
-- Named alias for scan()'s accumulator, NEEDED as a named type (not inline `function(U, T): U` at a generic
-- method's parameter position) — tl 0.24.8 mis-parses `function<U>(X, function(A,B):C, D): R`: the trailing
-- `, D` after a nested function-type parameter gets swallowed into that inner function's return-type list,
-- miscounting the outer arg list by one (see _rx.tl's own `Reducer<U, T>` for the same workaround).
global type EventReducer<U, T> = function(U, T): U

global record EventObservable<T>
   subscribe:            function(EventObservable<T>, function(T)): Subscription
   map:                  function<U>(EventObservable<T>, function(T): U): EventObservable<U>
   filter:               function(EventObservable<T>, function(T): boolean): EventObservable<T>
   tap:                  function(EventObservable<T>, function(T)): EventObservable<T>
   first:                function(EventObservable<T>, ? function(T): boolean): EventObservable<T>
   take:                 function(EventObservable<T>, integer): EventObservable<T>
   skip:                 function(EventObservable<T>, integer): EventObservable<T>
   distinctUntilChanged: function(EventObservable<T>, ? function(T, T): boolean): EventObservable<T>
   scan:                 function<U>(EventObservable<T>, EventReducer<U, T>, U): EventObservable<U>
   takeUntil:            function(EventObservable<T>, EventObservable<any>): EventObservable<T>
   switchMap:            function<U>(EventObservable<T>, function(T): EventObservable<U>): EventObservable<U>
end

-- Line-sourced: a hot per-line stream (rx.fromTrigger under the hood).
global onSpellUp:       EventObservable<string>   -- kxwt_spellup <name> — a buff/spell came UP
global onSpellDown:     EventObservable<string>   -- kxwt_spelldown <name> — a buff/spell dropped
global onMinionDied:    EventObservable<string>   -- kxwt_ydeath <name> — one of YOUR OWN minions died
global onEnemyDied:     EventObservable<string>   -- kxwt_mdeath <name> — an enemy died
global onCryOfVictory:  EventObservable<boolean>  -- "You feel victorious!" — the game's own positive signal that YOU landed a killing blow (never fires for a summon/minion's death)
global onSpellLanded:   EventObservable<string>   -- a damage/opener spell's own success line landed; emits the spell name

-- State-derived: transition events, sampled off the existing kxwt_prompt/kxwt_fighting/kxwt_position push
-- sources (never polled with `every` — see Events.tl).
global onCombatStart:   EventObservable<boolean>  -- engaged() flipped false -> true
global onCombatEnd:     EventObservable<boolean>  -- engaged() flipped true -> false
global onPostureChange: EventObservable<string>   -- kxwt_position text changed
global onManaLow:       EventObservable<number>   -- mana/maxmana crossed below the low-mana threshold; emits the ratio
global onHPLow:         EventObservable<number>   -- hp/maxhp crossed below the low-hp threshold; emits the ratio
global onNewOpponent:   EventObservable<string>   -- the kxwt_fighting target name changed to a new one
global onTankDown:      EventObservable<string>   -- your grouped, tanking (M+T flagged) minion was confirmed dead

-- Test seam.
global _AA_TEST: {string:any}
global _EVENTS_TEST: {string:any}
