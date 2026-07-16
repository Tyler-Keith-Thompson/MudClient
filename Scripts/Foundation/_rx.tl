-- _rx.tl — typed source for the reactive core (compiles to Scripts/Foundation/_rx.lua via tl gen). Home-
-- grown (rxlua is Lua-5.1-era and 2300 lines); this is Lua 5.4, ~1 file, and carries only the operators
-- the MUD logic actually uses. It pairs with Promise.lua: PROMISES sequence a one-shot flow (opener ->
-- probe -> nuke), OBSERVABLES model the never-ending streams of game events (health ticks, spell-landed
-- lines, combat start/end) that the reactive logic composes and subscribes to.
--
--   local rx = __rx
--   local spellLanded = rx.fromTrigger([[^You .* at (.+)!$]])          -- a hot stream of matches
--   spellLanded:map(function(c) return c[1] end)                        -- capture 1 = the target
--             :filter(function(t) return t ~= "" end)
--             :subscribe(function(target) --[[ react ]] end)
--   rx.fromTrigger([[^kxw[tq]_fighting (\d+)]]):first():toPromise()        -- await the next event, to chain
--
-- Everything is pure Lua over the host primitives already present: `trigger`/`rule_remove` (the event
-- source), `after`/`cancel` (time), `__promise` (the promise bridge). Hot-reloadable; `_`-prefixed so
-- `load("Scripts")` never auto-runs it — consumers pull it with `require("_rx")` (dofile fallback in the
-- bare test harness). Tested in Scripts/tests/rx_spec.lua.
--
-- OBJECT MODEL: foundation.d.tl's Observable<T>/Subject<T> are LOCAL (unexported) record types, so this
-- file — like every other consumer (Corpse.tl, DCast.tl, AutoFight.tl) — declares its OWN structural
-- stand-ins below and casts to the global `Rx` type at the one export boundary (`__rx = { ... } as Rx`).
--
-- THE KEY MECHANIC: the original _rx.lua built Observable/Subject as metatable objects sharing one
-- `__index` table of methods. Teal generic METHODS do not survive `__index` dispatch across differing
-- `T` — a chain like `obs:map(f):filter(g):subscribe(h)` loses its type the moment `map`'s return has to
-- be looked up through a shared metatable. So every operator here is instead a CLOSURE assigned onto the
-- instance table AT CONSTRUCTION TIME, threaded through one recursive constructor (`mk` for Observable);
-- Subject gets its own constructor (`mk_subject`) but delegates every inherited operator through
-- `self:asObservable()`, which itself funnels back through `mk` — so there is still exactly one place
-- (`mk`) that builds an operator chain link.
--
-- ONE RUNTIME WRINKLE THIS PRESERVES: AutoFight.tl monkey-patches a SPECIFIC subject instance's `onNext`
-- (a re-entrancy-safe override) by reading `self.observers`/`self.closed` directly as tstack fields, not
-- through any Subject method. So Subject<T> instances keep `observers`/`closed` as real, mutable TABLE
-- FIELDS (exactly like the original `setmetatable({observers=..., closed=...}, Subject)`), not hidden
-- upvalues — every closure below reads them off the `self` parameter, never a captured local, so an
-- external per-instance field override keeps working exactly as before.

global _RX_TEST: {string:any}

-- Type alias for the scan() accumulator. NEEDED as a named alias, not inline `function(U, T): U` at a
-- generic method's parameter position: tl 0.24.8 mis-parses `function<U>(X, function(A,B):C, D): R` —
-- the trailing `, D` after a nested function-type parameter gets swallowed into that inner function's
-- return-type list (`function(A,B):(C,D)`), miscounting the outer arg list by one. Naming the inner
-- function type breaks the ambiguity for the parser. (Verified in isolation; reported nowhere upstream
-- yet, so documenting here.)
local type Reducer<U, T> = function(U, T): U

-- ---- Subscription ---------------------------------------------------------------------------------
-- global record Subscription (foundation.d.tl) only declares `unsubscribe`; the extra `_teardown`/
-- `closed` bookkeeping lives on this local, more specific stand-in and is cast to `Subscription` at the
-- few boundaries that need the narrower public type.
local record SubscriptionImpl
   _teardown: function()
   closed: boolean
   unsubscribe: function(SubscriptionImpl)
end

local function new_subscription(teardown: function()): SubscriptionImpl
   local s: SubscriptionImpl = { _teardown = teardown, closed = false }
   s.unsubscribe = function(self: SubscriptionImpl)
      if self.closed then return end
      self.closed = true
      if self._teardown then pcall(self._teardown) end
   end
   return s
end

local CLOSED: SubscriptionImpl = new_subscription(nil)   -- shared no-op for terminal observers
CLOSED.closed = true

-- ---- Observer -------------------------------------------------------------------------------------
-- Normalize (onNext[, onError, onCompleted]) OR an observer table into a safe observer whose callbacks
-- never fire after it terminates (onError/onCompleted are final).
local record Observer<T>
   onNext: function(T)
   onError: function(string)
   onCompleted: function()
   done: boolean
end

local record RawObserver<T>
   onNext: function(T)
   onError: function(string)
   onCompleted: function()
   done: boolean
end

local function looks_like_observer(a: any): boolean
   if a is {string:any} then
      local t = a as {string:any}
      return t.onNext ~= nil or t.onError ~= nil or t.onCompleted ~= nil
   end
   return false
end

local function to_observer<T>(a: any, b: function(string), c: function()): Observer<T>
   local raw: RawObserver<T> = { done = false }
   if looks_like_observer(a) then
      local t = a as RawObserver<T>
      raw.onNext = t.onNext
      raw.onError = t.onError
      raw.onCompleted = t.onCompleted
   else
      raw.onNext = a as function(T)
      raw.onError = b
      raw.onCompleted = c
   end
   return {
      onNext = function(v: T) if not raw.done and raw.onNext then raw.onNext(v) end end,
      onError = function(e: string) if not raw.done then raw.done = true; if raw.onError then raw.onError(e) end end end,
      onCompleted = function() if not raw.done then raw.done = true; if raw.onCompleted then raw.onCompleted() end end end,
      done = false,
   }
end

-- ---- Observable -----------------------------------------------------------------------------------
-- Structural stand-in for foundation.d.tl's (local, unexported) Observable<T>. `subscribe`'s first arg is
-- `any` because it accepts either an onNext function OR an already-normalized observer table (the latter
-- is how operators/fromTrigger/asObservable re-subscribe without re-wrapping) — exactly the original's
-- `to_observer` dual path.
local record Observable<T>
   subscribe: function(Observable<T>, any, ?function(string), ?function()): Subscription
   map: function<U>(Observable<T>, function(T): U): Observable<U>
   filter: function(Observable<T>, function(T): boolean): Observable<T>
   first: function(Observable<T>, ?function(T): boolean): Observable<T>
   tap: function(Observable<T>, function(T)): Observable<T>
   take: function(Observable<T>, integer): Observable<T>
   skip: function(Observable<T>, integer): Observable<T>
   distinctUntilChanged: function(Observable<T>, ?function(T, T): boolean): Observable<T>
   scan: function<U>(Observable<T>, Reducer<U, T>, U): Observable<U>
   startWith: function(Observable<T>, T...): Observable<T>
   takeUntil: function(Observable<T>, Observable<any>): Observable<T>
   switchMap: function<U>(Observable<T>, function(T): Observable<U>): Observable<U>
   merge: function(Observable<T>, Observable<T>...): Observable<T>
   delay: function(Observable<T>, number): Observable<T>
   toPromise: function(Observable<T>, ?string): Promise<T>
end

-- merge/mk are mutually referenced (mk's instance :merge delegates to merge_all; merge_all builds new
-- links via mk), so merge_all is forward-declared here (mirrors Corpse.tl's `local process: function...`
-- forward-decl for its own recursive flow) and defined after `mk` below.
local merge_all: function<T>(Observable<T>...): Observable<T>

-- mk(onSubscribe): onSubscribe(observer) does the work and returns a teardown function (or nil). Builds
-- ONE Observable<T> instance with every operator wired as a closure over `self`/`onSubscribe` at
-- construction time — the mechanic this whole file exists to demonstrate (see file header).
local function mk<T>(onSubscribe: function(Observer<T>): function()): Observable<T>
   local self: Observable<T> = {}

   -- subscribe() wraps onSubscribe so terminal signals (onError/onCompleted) auto-unsubscribe, exactly
   -- like the original `Observable:subscribe`.
   self.subscribe = function(_: Observable<T>, a: any, b: function(string), c: function()): Subscription
      local observer: Observer<T> = to_observer(a, b, c)
      local sub: SubscriptionImpl = nil
      local base_next, base_err, base_comp = observer.onNext, observer.onError, observer.onCompleted
      observer.onError = function(e: string) base_err(e); if sub then sub:unsubscribe() end end
      observer.onCompleted = function() base_comp(); if sub then sub:unsubscribe() end end
      observer.onNext = base_next
      local teardown = onSubscribe(observer)
      sub = new_subscription(teardown)
      return sub as Subscription
   end

   self.map = function<U>(_: Observable<T>, f: function(T): U): Observable<U>
      return mk(function(observer: Observer<U>): function()
         local sub = self:subscribe(function(v: T) observer.onNext(f(v)) end, observer.onError, observer.onCompleted)
         return function() sub:unsubscribe() end
      end)
   end

   self.filter = function(_: Observable<T>, pred: function(T): boolean): Observable<T>
      return mk(function(observer: Observer<T>): function()
         local sub = self:subscribe(function(v: T) if pred(v) then observer.onNext(v) end end,
                                     observer.onError, observer.onCompleted)
         return function() sub:unsubscribe() end
      end)
   end

   self.tap = function(_: Observable<T>, f: function(T)): Observable<T>
      return mk(function(observer: Observer<T>): function()
         local sub = self:subscribe(function(v: T) f(v); observer.onNext(v) end, observer.onError, observer.onCompleted)
         return function() sub:unsubscribe() end
      end)
   end

   self.take = function(_: Observable<T>, n: integer): Observable<T>
      return mk(function(observer: Observer<T>): function()
         if n <= 0 then observer.onCompleted(); return nil end
         local left = n
         local sub = self:subscribe(function(v: T)
            if left <= 0 then return end
            left = left - 1
            observer.onNext(v)
            if left == 0 then observer.onCompleted() end
         end, observer.onError, observer.onCompleted)
         return function() sub:unsubscribe() end
      end)
   end

   self.skip = function(_: Observable<T>, n: integer): Observable<T>
      return mk(function(observer: Observer<T>): function()
         local left = n
         local sub = self:subscribe(function(v: T)
            if left > 0 then left = left - 1 else observer.onNext(v) end
         end, observer.onError, observer.onCompleted)
         return function() sub:unsubscribe() end
      end)
   end

   -- first([pred]): emit the first (matching) value then complete. Completes with an error if the source
   -- ends without one — so :toPromise() rejects on "stream closed, never saw it".
   self.first = function(_: Observable<T>, pred: function(T): boolean): Observable<T>
      return mk(function(observer: Observer<T>): function()
         local sub = self:subscribe(function(v: T)
            if pred == nil or pred(v) then observer.onNext(v); observer.onCompleted() end
         end, observer.onError, function() observer.onError("no first value") end)
         return function() sub:unsubscribe() end
      end)
   end

   self.distinctUntilChanged = function(_: Observable<T>, eqp: function(T, T): boolean): Observable<T>
      local eqf: function(T, T): boolean = eqp or function(a: T, b: T): boolean return a == b end
      return mk(function(observer: Observer<T>): function()
         local have = false
         local last: T = nil
         local sub = self:subscribe(function(v: T)
            if not have or not eqf(last, v) then have, last = true, v; observer.onNext(v) end
         end, observer.onError, observer.onCompleted)
         return function() sub:unsubscribe() end
      end)
   end

   self.scan = function<U>(_: Observable<T>, accumulator: Reducer<U, T>, seed: U): Observable<U>
      return mk(function(observer: Observer<U>): function()
         local acc: U = seed
         local sub = self:subscribe(function(v: T) acc = accumulator(acc, v); observer.onNext(acc) end,
                                     observer.onError, observer.onCompleted)
         return function() sub:unsubscribe() end
      end)
   end

   self.startWith = function(_: Observable<T>, ...: T): Observable<T>
      local seeds: {T} = { ... }
      return mk(function(observer: Observer<T>): function()
         for _, v in ipairs(seeds) do observer.onNext(v) end
         local sub = self:subscribe(observer.onNext, observer.onError, observer.onCompleted)
         return function() sub:unsubscribe() end
      end)
   end

   -- takeUntil(notifier): mirror source until `notifier` emits once, then complete.
   self.takeUntil = function(_: Observable<T>, notifier: Observable<any>): Observable<T>
      return mk(function(observer: Observer<T>): function()
         local stop: Subscription = nil
         local src = self:subscribe(observer.onNext, observer.onError, observer.onCompleted)
         stop = notifier:subscribe(function(_: any) observer.onCompleted(); if stop then stop:unsubscribe() end end)
         return function() src:unsubscribe(); if stop then stop:unsubscribe() end end
      end)
   end

   -- switchMap(project): for each source value, subscribe to project(v); a new value UNSUBSCRIBES the
   -- previous inner (the "switch"). The workhorse for "on each combat start, run this inner flow".
   self.switchMap = function<U>(_: Observable<T>, project: function(T): Observable<U>): Observable<U>
      return mk(function(observer: Observer<U>): function()
         local inner: Subscription = nil
         local outer = self:subscribe(function(v: T)
            if inner then inner:unsubscribe() end
            inner = project(v):subscribe(observer.onNext, observer.onError)   -- inner completion doesn't end outer
         end, observer.onError, function() if not inner then observer.onCompleted() end end)
         return function() outer:unsubscribe(); if inner then inner:unsubscribe() end end
      end)
   end

   -- merge(...): interleave observables; completes when ALL have completed. Delegates to `merge_all` (the
   -- static Observable.merge / rx.merge implementation) so both forms share one code path.
   self.merge = function(_: Observable<T>, ...: Observable<T>): Observable<T>
      return merge_all(self, ...)
   end

   -- delay(seconds): shift each emission later via after(); teardown cancels pending timers.
   self.delay = function(_: Observable<T>, seconds: number): Observable<T>
      return mk(function(observer: Observer<T>): function()
         local timers: {integer:boolean} = {}
         local src = self:subscribe(function(v: T)
            local id: integer = nil
            id = after and after(seconds, function() timers[id] = nil; observer.onNext(v) end) or nil
            if id then timers[id] = true end
         end, observer.onError, observer.onCompleted)
         return function() src:unsubscribe(); for id in pairs(timers) do if cancel then cancel(id) end end end
      end)
   end

   -- toPromise([why]): a Promise that resolves with this observable's FIRST value and rejects on error /
   -- empty completion. Cancelling the promise unsubscribes (stops listening).
   self.toPromise = function(_: Observable<T>, why: string): Promise<T>
      if not __promise then error("_rx:toPromise needs Promise.lua (__promise) loaded") end
      local source = self
      return __promise(function(resolve: function(any), reject: function(string), onCancel: function(function()))
         local sub = source:subscribe(
            function(v: T) resolve(v) end,
            function(e: string) reject(e) end,
            function() reject(why or "completed with no value") end)
         onCancel(function() sub:unsubscribe() end)
      end, "rx") as Promise<T>
   end

   return self
end

merge_all = function<T>(...: Observable<T>): Observable<T>
   local sources: {Observable<T>} = { ... }
   return mk(function(observer: Observer<T>): function()
      local remaining = #sources
      local subs: {Subscription} = {}
      for _, s in ipairs(sources) do
         subs[#subs + 1] = s:subscribe(observer.onNext, observer.onError, function()
            remaining = remaining - 1
            if remaining == 0 then observer.onCompleted() end
         end)
      end
      return function() for _, sub in ipairs(subs) do sub:unsubscribe() end end
   end)
end

-- ---- Constructors -----------------------------------------------------------------------------------
local function observable_of<T>(...: T): Observable<T>
   local values: {T} = { ... }
   return mk(function(observer: Observer<T>): function()
      for _, v in ipairs(values) do observer.onNext(v) end
      observer.onCompleted()
      return nil
   end)
end

local function observable_empty(): Observable<any>
   return mk(function(o: Observer<any>): function() o.onCompleted(); return nil end)
end
local function observable_never(): Observable<any>
   return mk(function(_: Observer<any>): function() return nil end)
end
local function observable_throw(e: any): Observable<any>
   return mk(function(o: Observer<any>): function() o.onError(e as string); return nil end)
end

-- ---- Subject: a hot, multicast Observable you push into ----------------------------------------------
-- Structural stand-in for foundation.d.tl's (local, unexported) Subject<T>, WITH the extra `observers`/
-- `closed` fields the original runtime instance shape had (see file header — AutoFight.tl's per-instance
-- onNext monkey-patch reads them directly).
local record Subject<T>
   observers: {Observer<T>:boolean}
   closed: boolean
   subscribe: function(Subject<T>, any, ?function(string), ?function()): Subscription
   onNext: function(Subject<T>, T)
   onError: function(Subject<T>, string)
   onCompleted: function(Subject<T>)
   count: function(Subject<T>): integer
   asObservable: function(Subject<T>): Observable<T>
   -- Subject inherits every Observable operator at runtime (the original's setmetatable __index =
   -- Observable); repeated here (Teal records can't extend a non-interface record) so a subject can be
   -- chained directly. Each delegates through asObservable() -> mk, so there's still one operator impl.
   map: function<U>(Subject<T>, function(T): U): Observable<U>
   filter: function(Subject<T>, function(T): boolean): Observable<T>
   first: function(Subject<T>, ?function(T): boolean): Observable<T>
   tap: function(Subject<T>, function(T)): Observable<T>
   take: function(Subject<T>, integer): Observable<T>
   skip: function(Subject<T>, integer): Observable<T>
   distinctUntilChanged: function(Subject<T>, ?function(T, T): boolean): Observable<T>
   scan: function<U>(Subject<T>, Reducer<U, T>, U): Observable<U>
   startWith: function(Subject<T>, T...): Observable<T>
   takeUntil: function(Subject<T>, Observable<any>): Observable<T>
   switchMap: function<U>(Subject<T>, function(T): Observable<U>): Observable<U>
   merge: function(Subject<T>, Observable<T>...): Observable<T>
   delay: function(Subject<T>, number): Observable<T>
   toPromise: function(Subject<T>, ?string): Promise<T>
end

local function mk_subject<T>(): Subject<T>
   local self: Subject<T> = { observers = {}, closed = false }

   self.subscribe = function(self: Subject<T>, a: any, b: function(string), c: function()): Subscription
      if self.closed then return CLOSED as Subscription end
      local observer: Observer<T> = to_observer(a, b, c)
      self.observers[observer] = true
      return new_subscription(function() self.observers[observer] = nil end) as Subscription
   end

   self.onNext = function(self: Subject<T>, v: T)
      if self.closed then return end
      -- Snapshot before dispatch: a synchronous subscriber may subscribe/unsubscribe mid-emit, and
      -- iterating a table with `pairs()` while it's mutated errors ("invalid key to 'next'"). Iterate a
      -- copy and re-check membership so an observer unsubscribed mid-dispatch doesn't still receive this.
      local snapshot: {Observer<T>} = {}
      for o in pairs(self.observers) do snapshot[#snapshot + 1] = o end
      for _, o in ipairs(snapshot) do
         if self.observers[o] then o.onNext(v) end
      end
   end
   self.onError = function(self: Subject<T>, e: string)
      if self.closed then return end
      self.closed = true
      local os_ = self.observers; self.observers = {}
      for o in pairs(os_) do o.onError(e) end
   end
   self.onCompleted = function(self: Subject<T>)
      if self.closed then return end
      self.closed = true
      local os_ = self.observers; self.observers = {}
      for o in pairs(os_) do o.onCompleted() end
   end
   self.count = function(self: Subject<T>): integer
      local n = 0
      for _ in pairs(self.observers) do n = n + 1 end
      return n
   end
   -- Expose as a plain Observable so callers can't push into a stream they only mean to read.
   self.asObservable = function(_: Subject<T>): Observable<T>
      return mk(function(observer: Observer<T>): function()
         local sub = self:subscribe(observer)
         return function() sub:unsubscribe() end
      end)
   end

   self.map = function<U>(_: Subject<T>, f: function(T): U): Observable<U> return self:asObservable():map(f) end
   self.filter = function(_: Subject<T>, pred: function(T): boolean): Observable<T> return self:asObservable():filter(pred) end
   self.first = function(_: Subject<T>, pred: function(T): boolean): Observable<T> return self:asObservable():first(pred) end
   self.tap = function(_: Subject<T>, f: function(T)): Observable<T> return self:asObservable():tap(f) end
   self.take = function(_: Subject<T>, n: integer): Observable<T> return self:asObservable():take(n) end
   self.skip = function(_: Subject<T>, n: integer): Observable<T> return self:asObservable():skip(n) end
   self.distinctUntilChanged = function(_: Subject<T>, eqp: function(T, T): boolean): Observable<T>
      return self:asObservable():distinctUntilChanged(eqp)
   end
   self.scan = function<U>(_: Subject<T>, acc: Reducer<U, T>, seed: U): Observable<U> return self:asObservable():scan(acc, seed) end
   self.startWith = function(_: Subject<T>, ...: T): Observable<T> return self:asObservable():startWith(...) end
   self.takeUntil = function(_: Subject<T>, notifier: Observable<any>): Observable<T> return self:asObservable():takeUntil(notifier) end
   self.switchMap = function<U>(_: Subject<T>, project: function(T): Observable<U>): Observable<U>
      return self:asObservable():switchMap(project)
   end
   self.merge = function(_: Subject<T>, ...: Observable<T>): Observable<T> return self:asObservable():merge(...) end
   self.delay = function(_: Subject<T>, seconds: number): Observable<T> return self:asObservable():delay(seconds) end
   self.toPromise = function(_: Subject<T>, why: string): Promise<T> return self:asObservable():toPromise(why) end

   return self
end

-- ---- Bridge: game trigger -> Observable -----------------------------------------------------------
-- A REFCOUNTED hot stream of a trigger's matches. The `trigger()` is registered on the FIRST subscribe
-- and `rule_remove`d on the LAST unsubscribe, so an unused stream costs nothing. Each match emits a
-- `caps` table: caps[1..N] = the regex capture groups, caps.line = the full matched line. By default the
-- line still displays (handler returns nil); pass `{gag=true}` to hide it, or `{opts=…}` to forward
-- trigger options (class/priority).
local function from_trigger(pattern: string, opts: {string:any}): Observable<{string}>
   opts = opts or {}
   local subject: Subject<{string}> = mk_subject()
   local id: integer = nil
   local function ensure()
      if id or not trigger then return end
      id = trigger(pattern, function(line: string, ...: string): any
         local varargs: {string} = { ... }
         local caps: {any:any} = { line = line }
         for i, v in ipairs(varargs) do caps[i] = v end
         subject:onNext(caps as {string})
         if opts.gag then return false end
         return nil
      end, opts.opts as {string:any})
   end
   local function release()
      if subject:count() == 0 and id and rule_remove then rule_remove(id); id = nil end
   end
   return mk(function(observer: Observer<{string}>): function()
      ensure()
      local sub = subject:subscribe(observer)
      return function() sub:unsubscribe(); release() end
   end)
end

-- ---- Bridge: Observable <-> Promise ------------------------------------------------------------------
-- fromPromise(p): a one-value Observable that emits the promise's resolution then completes (or errors).
-- Promise<T>'s declared surface only exposes andThen/catch/finally/timeout/cancel as SEPARATE typed
-- methods (foundation.d.tl), but the runtime `andThen` field (Promise.lua) is actually a raw 2-callback
-- (onFulfilled, onRejected) closure bound to that promise — not a `self`-taking method — so it's called
-- dot-style on a dynamic view of `p`, exactly like the original untyped _rx.lua did.
local record RawPromise<T>
   andThen: function(function(T), function(string))
   cancel: function(RawPromise<T>)
end
local function from_promise<T>(p: Promise<T>): Observable<T>
   return mk(function(observer: Observer<T>): function()
      local praw = p as RawPromise<T>
      praw.andThen(function(v: T) observer.onNext(v); observer.onCompleted() end,
                   function(e: string) observer.onError(e) end)
      return function() if p.cancel then p:cancel() end end
   end)
end

-- ---- Export ---------------------------------------------------------------------------------------
local record ObservableCtor
   create: function<T>(function(Observer<T>): function()): Observable<T>
   of: function<T>(T...): Observable<T>
   empty: function(): Observable<any>
   never: function(): Observable<any>
   throw: function(any): Observable<any>
   merge: function<T>(Observable<T>...): Observable<T>
   fromTrigger: function(string, ? {string:any}): Observable<{string}>
   fromPromise: function<T>(Promise<T>): Observable<T>
end
local record SubjectCtor
   new: function<T>(): Subject<T>
end

local ObservableM: ObservableCtor = {
   create = mk,
   of = observable_of,
   empty = observable_empty,
   never = observable_never,
   throw = observable_throw,
   merge = merge_all,
   fromTrigger = from_trigger,
   fromPromise = from_promise,
}
local SubjectM: SubjectCtor = { new = mk_subject }

local record RxModule
   Observable: ObservableCtor
   Subject: SubjectCtor
   of: function<T>(T...): Observable<T>
   empty: function(): Observable<any>
   never: function(): Observable<any>
   throw: function(any): Observable<any>
   merge: function<T>(Observable<T>...): Observable<T>
   fromTrigger: function(string, ? {string:any}): Observable<{string}>
   fromPromise: function<T>(Promise<T>): Observable<T>
   subject: function<T>(): Subject<T>
end

local M: RxModule = {
   Observable = ObservableM,
   Subject = SubjectM,
   of = observable_of,
   empty = observable_empty,
   never = observable_never,
   throw = observable_throw,
   merge = merge_all,
   fromTrigger = from_trigger,
   fromPromise = from_promise,
   subject = mk_subject,
}
__rx = M as Rx

_RX_TEST = { Observable = mk, Subject = mk_subject, to_observer = to_observer,
             new_subscription = new_subscription }

return __rx
