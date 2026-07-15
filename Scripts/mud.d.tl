-- mud.d.tl — type declarations for the MudClient host surface. Written ONCE; every `.tl` script is
-- checked against these (tlconfig.lua points `global_env_def` here), so a wrong arg type or arity on a
-- host call is a COMPILE error instead of a runtime nil. Grows as we migrate more scripts to Teal.

-- The shared game state table. Genuinely heterogeneous (vitals, position, flags, roster, …), so its
-- value type is `any` on purpose — the typing win is in the pure logic that reads/writes it, not here.
global state: {string:any}

-- Reactive surface (_rx.lua). Streams are single-value in our usage (a capture table, a bare signal,
-- or a scalar), so single-param generics are accurate — see the DCast note.
global record Subscription
   unsubscribe: function(Subscription)
end
local record Observable<T>
   subscribe: function(Observable<T>, function(T)): Subscription
   map: function<U>(Observable<T>, function(T): U): Observable<U>
   filter: function(Observable<T>, function(T): boolean): Observable<T>
   first: function(Observable<T>, ? function(T): boolean): Observable<T>
   tap: function(Observable<T>, function(T)): Observable<T>
   take: function(Observable<T>, integer): Observable<T>
   skip: function(Observable<T>, integer): Observable<T>
   distinctUntilChanged: function(Observable<T>, ? function(T, T): boolean): Observable<T>
   scan: function<U>(Observable<T>, function(U, T): U, U): Observable<U>
   startWith: function(Observable<T>, T...): Observable<T>
   takeUntil: function(Observable<T>, Observable<any>): Observable<T>
   switchMap: function<U>(Observable<T>, function(T): Observable<U>): Observable<U>
   merge: function(Observable<T>, Observable<T>...): Observable<T>
   delay: function(Observable<T>, number): Observable<T>
   toPromise: function(Observable<T>, ? string): Promise<T>
end
local record Subject<T>
   subscribe: function(Subject<T>, function(T)): Subscription
   onNext: function(Subject<T>, T)
   onError: function(Subject<T>, string)
   onCompleted: function(Subject<T>)
   count: function(Subject<T>): integer
   asObservable: function(Subject<T>): Observable<T>
   -- Subject inherits every Observable operator at runtime (setmetatable __index = Observable); repeated
   -- here (Teal records can't extend a non-interface record) so a subject can be chained directly.
   map: function<U>(Subject<T>, function(T): U): Observable<U>
   filter: function(Subject<T>, function(T): boolean): Observable<T>
   first: function(Subject<T>, ? function(T): boolean): Observable<T>
   tap: function(Subject<T>, function(T)): Observable<T>
   take: function(Subject<T>, integer): Observable<T>
   skip: function(Subject<T>, integer): Observable<T>
   distinctUntilChanged: function(Subject<T>, ? function(T, T): boolean): Observable<T>
   scan: function<U>(Subject<T>, function(U, T): U, U): Observable<U>
   startWith: function(Subject<T>, T...): Observable<T>
   takeUntil: function(Subject<T>, Observable<any>): Observable<T>
   switchMap: function<U>(Subject<T>, function(T): Observable<U>): Observable<U>
   merge: function(Subject<T>, Observable<T>...): Observable<T>
   delay: function(Subject<T>, number): Observable<T>
   toPromise: function(Subject<T>, ? string): Promise<T>
end
global record Rx
   subject: function(): Subject<any>
   fromTrigger: function(string, ? {string:any}): Observable<{string}>
   of: function<T>(T...): Observable<T>
   empty: function(): Observable<any>
   never: function(): Observable<any>
   throw: function(any): Observable<any>
   merge: function<T>(Observable<T>...): Observable<T>
   fromPromise: function<T>(Promise<T>): Observable<T>
end
global __rx: Rx

-- Promise (Promise.lua). The callback RECEIVES the typed element T (the win); its return is optional
-- (side-effect, or a value/promise our runtime adopts dynamically), modelled as `: any...`, and the
-- resulting promise is Promise<any> because that adoption isn't statically trackable through the metatable
-- layer — the deliberate dynamic edge. resolve/reject take `any` so a caller can cast the promise's T.
global record Promise<T>
   andThen: function(Promise<T>, function(T): any...): Promise<any>
   catch:   function(Promise<T>, function(string): any...): Promise<any>
   finally: function(Promise<T>, function(): any...): Promise<any>
   timeout: function(Promise<T>, number, ? string): Promise<T>
   cancel:  function(Promise<T>)
end
global __promise: function(
   function(function(any), function(string), function(function())),   -- (resolve, reject, onCancel)
   string): Promise<any>
global __untrack_promise: function(Promise<any>)

-- Persist (_persist.lua).
global record Persist
   load: function(string): any
   write: function(string, string)
   save: function(string, any): boolean   -- serialize+write a table atomically (callers pass heterogeneous tables → any)
   serialize: function(any): string       -- table → a `return {...}` chunk string
end
global __persist: Persist
global __dsl: any

-- Host builtins (the subset the migrated scripts touch; extend as needed). A trigger/alias handler gets
-- the matched line, then capture groups, then the raw ANSI line last — all strings — hence (...: any).
-- A handler's return is OPTIONAL (return a rewritten line / false-to-gag, or nothing): modelled as a
-- vararg return `: any...`, which accepts both a value-returning and a side-effect-only handler.
global trigger: function(string, function(...: any): any...): integer
global alias:   function(string, function(...: any): any...): integer
global send:    function(string)
global echo:    function(string, ? string)     -- color is optional; omit it for the default
global after:   function(number, function()): integer
global cancel:  function(integer)
global doc:     function(...: any)
global __repl_render: function(any): string     -- bootstrap.lua's REPL pretty-printer (render_top)

-- gag/rule lifecycle (siblings of trigger/alias above).
global gag:          function(string): integer
global rule_remove:  function(integer)
global rule_enable:  function(integer, boolean)
global class_enable: function(string, boolean)
global class_remove: function(string)

-- Timers: `every` is after()'s repeating sibling (same handler-return convention).
global every: function(number, function(): any...): integer

-- ---- I/O / terminal ----
global bell:            function()
global copy:            function(? integer)
global spellcheck:      function(string): string
global input_get:       function(): string
global input_set:       function(any)                     -- text-ish: string, or a number coerced like tostring
global scrollback:      function(integer): {string}
global scrollback_find: function(string, ? integer): {string}
global grep:            function(string)
global sent:            function(? integer)
global received:        function(? integer)
global claude:          function(string)
global chat:            function(string)
global __term_cols:     function(): integer

-- ---- Connection lifecycle (telnet) ----
global connect:             function(string, ? integer)
global disconnect:          function()
global is_connected:        function(): boolean
global reconnect:           function()                    -- pure-Lua wrapper (bootstrap.lua) remembering the last connect()
global telnet_send:         function(integer, ? string)
global on_stream:           function(function(string): string)

-- ---- Generic binary socket (net_*, independent of connect/telnet) ----
global net_connect:      function(string, integer, ? {string:any})   -- opts = { tls = bool }
global net_send:         function(string)
global net_disconnect:   function()
global net_is_connected: function(): boolean
global feed_server:      function(string)

-- ---- Session logging & replay ----
global log_start:  function(string, ? {string:any}): boolean   -- opts = { timestamps=, ansi=, commands= }
global log_stop:   function()
global log_active: function(): (boolean, string)
global replay:     function(string, ? {string:any}): boolean   -- opts = { speed=, quiet= }

-- ---- Key bindings ----
global bind:   function(string, function(...: any): any...): integer
global unbind: function(integer)

-- ---- Panel (declarative top-of-screen HUD) — both the raw registered functions and the `panel` table
-- assembled from them (see bootstrap.lua/LuaScriptEngine.installPanel). `spec` is the declarative row/
-- column model; genuinely heterogeneous, so `any` on purpose.
global panel_render:     function(any)
global panel_height:     function(? integer)
global panel_top:        function(any)
global panel_top_height: function(? integer)
global record Panel
   render:     function(any)
   height:     function(? integer)
   top:        function(any)
   top_height: function(? integer)
end
global panel: Panel

-- ---- Music / sound (layered named audio + live MIDI + one-shot effects) ----
global music_play:       function(string, string)
global music_stop:       function(? string)
global music_volume:     function(number)
global music_midi:       function(string)
global music_midi_reset: function()
global record Music
   play:       function(string, string)
   stop:       function(? string)
   volume:     function(number)
   midi:       function(string)
   midi_reset: function()
end
global music: Music
global sound_once:    function(string, ? number)
global msp_volume:    function(number)
global speech_volume: function(number)

-- ---- Text-to-speech (SpeechBuiltins.swift) ----
global speak:                function(string, ? string, ? integer, ? string, ? string)
global speech_stop:          function()
global speech_voices:        function(? boolean): {any}
global speech_kokoro_voices: function(): {string}
global speech_backend:       function(): (string, string)
global is_live:              function(): boolean

-- ---- AI / LLM bridge. Callbacks receive results asynchronously; args can be nil (an error string, a
-- missing tool-calls JSON, …), so — like trigger/alias handlers — they're modelled permissively as
-- `(...: any): any...` rather than pinning positions that are frequently nil.
global ai_request:             function(string, string, integer, ? string, ? string, function(...: any): any...)
global ai_local_request:       function(string, string, integer, ? string, function(...: any): any..., ? string)
global ai_local_tools_request: function(string, string, integer, ? string, ? string, function(...: any): any..., ? string)
global ai_set_local_endpoint:  function(string)
global ai_set_local_model:     function(string)
global ai_set_endpoint:        function(string)
global ai_set_model:           function(string)
global ai_set_auth:            function(boolean)
global ai_memory_request:      function(string, string, integer, function(...: any): any...)
global ai_set_memory_endpoint: function(string)
global ai_set_memory_model:    function(string)
global ai_set_memory_key:      function(string)
global ai_rag_load:            function(string)
global ai_rag_count:           function(): integer
global ai_usage:                function(): (integer, integer, integer, integer)
global ai_mem_usage:            function(): (integer, integer, integer, integer)
global ai_usage_reset:          function()
global ai_retrieve:             function(string, integer, function(...: any): any...)
global lag_status:              function(): {string:number}

-- ---- Script-loader primitives (bootstrap.lua's `load`/`reload`/`require` stand on these). `__`-prefixed
-- => doc-exempt host I/O; `load`/`reload`/`command`/`ai` are the user-facing pure-Lua surface built on top.
global __path_kind:   function(string): string        -- "file" | "dir" | "missing"
global __list_dir:    function(string): {string}
global __run_file:    function(string): boolean
global __clear_rules: function()
-- NOTE: `load` itself is NOT redeclared here — Teal's stdlib already declares it `<const>` (the chunk
-- compiler); bootstrap.lua shadows it at runtime with the path/dir loader (a string arg is a path, a
-- non-string delegates to the preserved original, reachable as `loadchunk`), but that's a value-level
-- shadow the type-checker doesn't need to know about — callers just pass a string path.
global loadchunk:     function(...: any): any...       -- the shadowed stdlib `load` (compile a chunk from string/function)
global reload:        function()
global command:       function(string, function(? string): any...): string
global ai:            function(? string): any...

-- ---- Callable game-surface tables — the deliberate dynamic boundary. Each is a `__call` metatable
-- (so `eq("scan")` and `#eq scan` both work); typing them precisely isn't the point, the pure logic
-- behind each member is.
global eq: any
global pilot: any
global kxwt: any
global trivia: any

-- ---- Lifecycle/telnet/terminal hooks — optional globals a script may define; the host calls whichever
-- exist (see LuaScriptEngine.swift callGlobal* call sites). Hooks that may rewrite/veto/consume return a
-- value: modelled as a vararg return (`: any...`), same convention as trigger/alias handlers.
global on_connect:           function()
global on_disconnect:        function(string)
global on_prompt:            function(string)
global on_telnet:            function(integer, string)
global on_telnet_negotiate:  function(string, integer): any...     -- "accept" | "reject" | nil
global on_send:              function(string): any...              -- nil (unchanged) | false (suppress) | string (replace)
global on_resize:            function(integer, integer)
global on_mouse:             function(string, integer, integer, integer): any...   -- truthy return consumes the event
global on_user_input:        function(string)
global on_update:            function()
global on_inventory:         function()
global on_net:               function(string)
global on_net_connect:       function()
global on_net_disconnect:    function(string)

-- ---- Cross-script globals other (still-Lua) scripts define/read, that a migrated script may need to
-- call. Genuinely dynamic at these edges (state-machine callbacks, HUD data feeds); `any`/permissive
-- where the shape isn't pinned down by a single owner.
global apply_fight:            function(? number, ? string)
global active_opponents:       function(? number): {any}
global active_promises:        function(): {any}
global is_ally:                function(string): boolean
global engaged:                function(? number): boolean   -- Combat.lua: text-derived in-combat predicate
global in_combat:              function(): boolean           -- Combat.lua: engaged(); every pilot/eq/corpse consumer sits on it
global smap_on_map_update:     function()                    -- AIPilot.lua: called after a ;smap; grid update
global minimap:                function(? integer, ? integer): any   -- AIPilot.lua: room-graph minimap renderer (HUD consumes)
global cancelPromises:         function(): integer
global __autofight_prompt:     function(? number, ? string)
global __recovery_on_vitals:   function()
global __recovery_on_position: function(any, boolean)
global __recovery_on_group:    function()
global __recovery_on_spellup:   function(any)
global __recovery_on_spelldown: function(any)
global __recovery_cancel:       function(? string)
global __ready:                 function(any): any
global __track_promise:         function(any)
global __current_promise:       function(): any
global __pop_tail:              function(): any

-- Test seam + a couple of callable-table globals that other (still-Lua) scripts read. `any` on purpose:
-- these are the deliberate dynamic boundaries — the typing win is in each script's internal logic.
global _AA_TEST: {string:any}
global dcast: any
