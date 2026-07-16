

























































local function new_subscription(teardown)
   local s = { _teardown = teardown, closed = false }
   s.unsubscribe = function(self)
      if self.closed then return end
      self.closed = true
      if self._teardown then pcall(self._teardown) end
   end
   return s
end

local CLOSED = new_subscription(nil)
CLOSED.closed = true


















local function looks_like_observer(a)
   if type(a) == "table" then
      local t = a
      return t.onNext ~= nil or t.onError ~= nil or t.onCompleted ~= nil
   end
   return false
end

local function to_observer(a, b, c)
   local raw = { done = false }
   if looks_like_observer(a) then
      local t = a
      raw.onNext = t.onNext
      raw.onError = t.onError
      raw.onCompleted = t.onCompleted
   else
      raw.onNext = a
      raw.onError = b
      raw.onCompleted = c
   end
   return {
      onNext = function(v) if not raw.done and raw.onNext then raw.onNext(v) end end,
      onError = function(e) if not raw.done then raw.done = true; if raw.onError then raw.onError(e) end end end,
      onCompleted = function() if not raw.done then raw.done = true; if raw.onCompleted then raw.onCompleted() end end end,
      done = false,
   }
end



























local merge_all




local function mk(onSubscribe)
   local self = {}



   self.subscribe = function(_, a, b, c)
      local observer = to_observer(a, b, c)
      local sub = nil
      local base_next, base_err, base_comp = observer.onNext, observer.onError, observer.onCompleted
      observer.onError = function(e) base_err(e); if sub then sub:unsubscribe() end end
      observer.onCompleted = function() base_comp(); if sub then sub:unsubscribe() end end
      observer.onNext = base_next
      local teardown = onSubscribe(observer)
      sub = new_subscription(teardown)
      return sub
   end

   self.map = function(_, f)
      return mk(function(observer)
         local sub = self:subscribe(function(v) observer.onNext(f(v)) end, observer.onError, observer.onCompleted)
         return function() sub:unsubscribe() end
      end)
   end

   self.filter = function(_, pred)
      return mk(function(observer)
         local sub = self:subscribe(function(v) if pred(v) then observer.onNext(v) end end,
         observer.onError, observer.onCompleted)
         return function() sub:unsubscribe() end
      end)
   end

   self.tap = function(_, f)
      return mk(function(observer)
         local sub = self:subscribe(function(v) f(v); observer.onNext(v) end, observer.onError, observer.onCompleted)
         return function() sub:unsubscribe() end
      end)
   end

   self.take = function(_, n)
      return mk(function(observer)
         if n <= 0 then observer.onCompleted(); return nil end
         local left = n
         local sub = self:subscribe(function(v)
            if left <= 0 then return end
            left = left - 1
            observer.onNext(v)
            if left == 0 then observer.onCompleted() end
         end, observer.onError, observer.onCompleted)
         return function() sub:unsubscribe() end
      end)
   end

   self.skip = function(_, n)
      return mk(function(observer)
         local left = n
         local sub = self:subscribe(function(v)
            if left > 0 then left = left - 1 else observer.onNext(v) end
         end, observer.onError, observer.onCompleted)
         return function() sub:unsubscribe() end
      end)
   end



   self.first = function(_, pred)
      return mk(function(observer)
         local sub = self:subscribe(function(v)
            if pred == nil or pred(v) then observer.onNext(v); observer.onCompleted() end
         end, observer.onError, function() observer.onError("no first value") end)
         return function() sub:unsubscribe() end
      end)
   end

   self.distinctUntilChanged = function(_, eqp)
      local eqf = eqp or function(a, b) return a == b end
      return mk(function(observer)
         local have = false
         local last = nil
         local sub = self:subscribe(function(v)
            if not have or not eqf(last, v) then have, last = true, v; observer.onNext(v) end
         end, observer.onError, observer.onCompleted)
         return function() sub:unsubscribe() end
      end)
   end

   self.scan = function(_, accumulator, seed)
      return mk(function(observer)
         local acc = seed
         local sub = self:subscribe(function(v) acc = accumulator(acc, v); observer.onNext(acc) end,
         observer.onError, observer.onCompleted)
         return function() sub:unsubscribe() end
      end)
   end

   self.startWith = function(_, ...)
      local seeds = { ... }
      return mk(function(observer)
         for _, v in ipairs(seeds) do observer.onNext(v) end
         local sub = self:subscribe(observer.onNext, observer.onError, observer.onCompleted)
         return function() sub:unsubscribe() end
      end)
   end


   self.takeUntil = function(_, notifier)
      return mk(function(observer)
         local stop = nil
         local src = self:subscribe(observer.onNext, observer.onError, observer.onCompleted)
         stop = notifier:subscribe(function(_) observer.onCompleted(); if stop then stop:unsubscribe() end end)
         return function() src:unsubscribe(); if stop then stop:unsubscribe() end end
      end)
   end



   self.switchMap = function(_, project)
      return mk(function(observer)
         local inner = nil
         local outer = self:subscribe(function(v)
            if inner then inner:unsubscribe() end
            inner = project(v):subscribe(observer.onNext, observer.onError)
         end, observer.onError, function() if not inner then observer.onCompleted() end end)
         return function() outer:unsubscribe(); if inner then inner:unsubscribe() end end
      end)
   end



   self.merge = function(_, ...)
      return merge_all(self, ...)
   end


   self.delay = function(_, seconds)
      return mk(function(observer)
         local timers = {}
         local src = self:subscribe(function(v)
            local id = nil
            id = after and after(seconds, function() timers[id] = nil; observer.onNext(v) end) or nil
            if id then timers[id] = true end
         end, observer.onError, observer.onCompleted)
         return function() src:unsubscribe(); for id in pairs(timers) do if cancel then cancel(id) end end end
      end)
   end



   self.toPromise = function(_, why)
      if not __promise then error("_rx:toPromise needs Promise.lua (__promise) loaded") end
      local source = self
      return __promise(function(resolve, reject, onCancel)
         local sub = source:subscribe(
         function(v) resolve(v) end,
         function(e) reject(e) end,
         function() reject(why or "completed with no value") end)
         onCancel(function() sub:unsubscribe() end)
      end, "rx")
   end

   return self
end

merge_all = function(...)
   local sources = { ... }
   return mk(function(observer)
      local remaining = #sources
      local subs = {}
      for _, s in ipairs(sources) do
         subs[#subs + 1] = s:subscribe(observer.onNext, observer.onError, function()
            remaining = remaining - 1
            if remaining == 0 then observer.onCompleted() end
         end)
      end
      return function() for _, sub in ipairs(subs) do sub:unsubscribe() end end
   end)
end


local function observable_of(...)
   local values = { ... }
   return mk(function(observer)
      for _, v in ipairs(values) do observer.onNext(v) end
      observer.onCompleted()
      return nil
   end)
end

local function observable_empty()
   return mk(function(o) o.onCompleted(); return nil end)
end
local function observable_never()
   return mk(function(_) return nil end)
end
local function observable_throw(e)
   return mk(function(o) o.onError(e); return nil end)
end

































local function mk_subject()
   local self = { observers = {}, closed = false }

   self.subscribe = function(self, a, b, c)
      if self.closed then return CLOSED end
      local observer = to_observer(a, b, c)
      self.observers[observer] = true
      return new_subscription(function() self.observers[observer] = nil end)
   end

   self.onNext = function(self, v)
      if self.closed then return end



      local snapshot = {}
      for o in pairs(self.observers) do snapshot[#snapshot + 1] = o end
      for _, o in ipairs(snapshot) do
         if self.observers[o] then o.onNext(v) end
      end
   end
   self.onError = function(self, e)
      if self.closed then return end
      self.closed = true
      local os_ = self.observers; self.observers = {}
      for o in pairs(os_) do o.onError(e) end
   end
   self.onCompleted = function(self)
      if self.closed then return end
      self.closed = true
      local os_ = self.observers; self.observers = {}
      for o in pairs(os_) do o.onCompleted() end
   end
   self.count = function(self)
      local n = 0
      for _ in pairs(self.observers) do n = n + 1 end
      return n
   end

   self.asObservable = function(_)
      return mk(function(observer)
         local sub = self:subscribe(observer)
         return function() sub:unsubscribe() end
      end)
   end

   self.map = function(_, f) return self:asObservable():map(f) end
   self.filter = function(_, pred) return self:asObservable():filter(pred) end
   self.first = function(_, pred) return self:asObservable():first(pred) end
   self.tap = function(_, f) return self:asObservable():tap(f) end
   self.take = function(_, n) return self:asObservable():take(n) end
   self.skip = function(_, n) return self:asObservable():skip(n) end
   self.distinctUntilChanged = function(_, eqp)
      return self:asObservable():distinctUntilChanged(eqp)
   end
   self.scan = function(_, acc, seed) return self:asObservable():scan(acc, seed) end
   self.startWith = function(_, ...) return self:asObservable():startWith(...) end
   self.takeUntil = function(_, notifier) return self:asObservable():takeUntil(notifier) end
   self.switchMap = function(_, project)
      return self:asObservable():switchMap(project)
   end
   self.merge = function(_, ...) return self:asObservable():merge(...) end
   self.delay = function(_, seconds) return self:asObservable():delay(seconds) end
   self.toPromise = function(_, why) return self:asObservable():toPromise(why) end

   return self
end







local function from_trigger(pattern, opts)
   opts = opts or {}
   local subject = mk_subject()
   local id = nil
   local function ensure()
      if id or not trigger then return end
      id = trigger(pattern, function(line, ...)
         local varargs = { ... }
         local caps = { line = line }
         for i, v in ipairs(varargs) do caps[i] = v end
         subject:onNext(caps)
         if opts.gag then return false end
         return nil
      end, opts.opts)
   end
   local function release()
      if subject:count() == 0 and id and rule_remove then rule_remove(id); id = nil end
   end
   return mk(function(observer)
      ensure()
      local sub = subject:subscribe(observer)
      return function() sub:unsubscribe(); release() end
   end)
end











local function from_promise(p)
   return mk(function(observer)
      local praw = p
      praw.andThen(function(v) observer.onNext(v); observer.onCompleted() end,
      function(e) observer.onError(e) end)
      return function() if p.cancel then p:cancel() end end
   end)
end
















local ObservableM = {
   create = mk,
   of = observable_of,
   empty = observable_empty,
   never = observable_never,
   throw = observable_throw,
   merge = merge_all,
   fromTrigger = from_trigger,
   fromPromise = from_promise,
}
local SubjectM = { new = mk_subject }














local M = {
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
__rx = M

_RX_TEST = { Observable = mk, Subject = mk_subject, to_observer = to_observer,
new_subscription = new_subscription, }

return __rx
