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
   first: function(Observable<T>): Observable<T>
end
local record Subject<T>
   subscribe: function(Subject<T>, function(T)): Subscription
   onNext: function(Subject<T>, T)
end
global record Rx
   subject: function(): Subject<any>
   fromTrigger: function(string): Observable<{string}>
end
global __rx: Rx

-- Promise (Promise.lua). The callback RECEIVES the typed element T (the win); its return is optional
-- (side-effect, or a value/promise our runtime adopts dynamically), modelled as `: any...`, and the
-- resulting promise is Promise<any> because that adoption isn't statically trackable through the metatable
-- layer — the deliberate dynamic edge. resolve/reject take `any` so a caller can cast the promise's T.
global record Promise<T>
   andThen: function(Promise<T>, function(T): any...): Promise<any>
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

-- Test seam + a couple of callable-table globals that other (still-Lua) scripts read. `any` on purpose:
-- these are the deliberate dynamic boundaries — the typing win is in each script's internal logic.
global _AA_TEST: {string:any}
global dcast: any
