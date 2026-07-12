-- Specs for the reactive core (Scripts/_rx.lua): Observables/Subjects, the operators the game uses, the
-- refcounted trigger->Observable bridge, and the Observable<->Promise bridge. Pure Lua; the trigger and
-- timer host primitives are overridden locally to drive the streams deterministically.

if not __rx then dofile("Scripts/_rx.lua") end
local rx = __rx

-- ---- Subject: hot multicast + unsubscribe --------------------------------------------------------
test("Subject multicasts to all subscribers and stops on unsubscribe", function()
  local s = rx.subject()
  local a, b = {}, {}
  local subA = s:subscribe(function(v) a[#a + 1] = v end)
  s:subscribe(function(v) b[#b + 1] = v end)
  s:onNext(1); s:onNext(2)
  subA:unsubscribe()
  s:onNext(3)
  expect(table.concat(a, ",")):eq("1,2")     -- A stopped after unsubscribe
  expect(table.concat(b, ",")):eq("1,2,3")   -- B kept receiving
end)

-- ---- operators -----------------------------------------------------------------------------------
test("map + filter transform the stream", function()
  local s = rx.subject()
  local got = {}
  s:map(function(v) return v * 2 end):filter(function(v) return v > 4 end)
   :subscribe(function(v) got[#got + 1] = v end)
  for _, v in ipairs({ 1, 2, 3, 4 }) do s:onNext(v) end   -- *2 -> 2,4,6,8 ; >4 -> 6,8
  expect(table.concat(got, ",")):eq("6,8")
end)

test("take completes after N and first([pred]) grabs one then completes", function()
  local s = rx.subject()
  local taken, done = {}, false
  s:take(2):subscribe(function(v) taken[#taken + 1] = v end, nil, function() done = true end)
  s:onNext("a"); s:onNext("b"); s:onNext("c")
  expect(table.concat(taken, ",")):eq("a,b")
  expect(done):truthy()

  local s2, first = rx.subject(), nil
  s2:first(function(v) return v >= 3 end):subscribe(function(v) first = v end)
  s2:onNext(1); s2:onNext(2); s2:onNext(5); s2:onNext(9)
  expect(first):eq(5)
end)

test("scan accumulates and distinctUntilChanged suppresses repeats", function()
  local s = rx.subject()
  local sums = {}
  s:scan(function(acc, v) return acc + v end, 0):subscribe(function(v) sums[#sums + 1] = v end)
  for _, v in ipairs({ 1, 2, 3 }) do s:onNext(v) end
  expect(table.concat(sums, ",")):eq("1,3,6")

  local d = rx.subject()
  local seen = {}
  d:distinctUntilChanged():subscribe(function(v) seen[#seen + 1] = v end)
  for _, v in ipairs({ 1, 1, 2, 2, 2, 3, 1 }) do d:onNext(v) end
  expect(table.concat(seen, ",")):eq("1,2,3,1")
end)

test("merge interleaves and takeUntil stops the source when the notifier fires", function()
  local a, b = rx.subject(), rx.subject()
  local merged = {}
  rx.merge(a, b):subscribe(function(v) merged[#merged + 1] = v end)
  a:onNext("a1"); b:onNext("b1"); a:onNext("a2")
  expect(table.concat(merged, ",")):eq("a1,b1,a2")

  local src, stop = rx.subject(), rx.subject()
  local got, done = {}, false
  src:takeUntil(stop):subscribe(function(v) got[#got + 1] = v end, nil, function() done = true end)
  src:onNext(1); src:onNext(2); stop:onNext(true); src:onNext(3)
  expect(table.concat(got, ",")):eq("1,2")
  expect(done):truthy()
end)

test("switchMap cancels the previous inner when the source emits again", function()
  local outer = rx.subject()
  local inners = { rx.subject(), rx.subject() }
  local idx, got = 0, {}
  outer:switchMap(function() idx = idx + 1; return inners[idx] end)
       :subscribe(function(v) got[#got + 1] = v end)
  outer:onNext("first");  inners[1]:onNext("A")     -- inner 1 active
  outer:onNext("second"); inners[1]:onNext("Xdropped"); inners[2]:onNext("B")   -- switched: inner 1 ignored
  expect(table.concat(got, ",")):eq("A,B")
end)

-- ---- trigger -> Observable bridge (refcounted) ---------------------------------------------------
test("fromTrigger registers on first subscribe, emits captures, rule_removes on last unsubscribe", function()
  local saved_trigger, saved_remove = trigger, rule_remove
  local handler, made_id, removed = nil, nil, nil
  _G.trigger = function(_pat, fn) handler = fn; made_id = 42; return made_id end
  _G.rule_remove = function(id) removed = id end

  local stream = rx.fromTrigger([[^You hit (%S+) for (%d+)$]])
  expect(handler):falsy()                              -- cold: no trigger registered yet

  local caps = {}
  local sub1 = stream:subscribe(function(c) caps[#caps + 1] = c end)
  local sub2 = stream:subscribe(function() end)
  expect(handler):truthy()                             -- registered on first subscribe
  expect(made_id):eq(42)

  handler("You hit orc for 37", "orc", "37")           -- (line, cap1, cap2) per host convention
  expect(caps[1][1]):eq("orc")
  expect(caps[1][2]):eq("37")
  expect(caps[1].line):eq("You hit orc for 37")

  sub1:unsubscribe(); expect(removed):falsy()          -- still one subscriber -> keep the trigger
  sub2:unsubscribe(); expect(removed):eq(42)           -- last one gone -> rule_remove

  _G.trigger, _G.rule_remove = saved_trigger, saved_remove
end)

-- ---- re-entrancy: a subscriber that subscribes/unsubscribes mid-dispatch must not crash ----------
test("Subject:onNext is re-entrancy safe (subscribe/unsubscribe during emit)", function()
  local s = rx.subject()
  local got = {}
  -- First subscriber subscribes a SECOND observer the first time it sees a value (mutates during emit).
  local added = false
  s:subscribe(function(v)
    got[#got + 1] = "a" .. v
    if not added then added = true; s:subscribe(function(w) got[#got + 1] = "b" .. w end) end
  end)
  s:onNext(1)   -- must not error; the late subscriber joins for subsequent emits
  s:onNext(2)
  expect(table.concat(got, ",")):eq("a1,a2,b2")

  -- An observer that unsubscribes itself mid-dispatch must not still receive the value, and must not crash.
  local s2, seen = rx.subject(), {}
  local sub
  sub = s2:subscribe(function(v) seen[#seen + 1] = v; sub:unsubscribe() end)
  s2:subscribe(function(v) seen[#seen + 1] = "keep" .. v end)
  s2:onNext(1); s2:onNext(2)
  expect(table.concat(seen, ",")):eq("1,keep1,keep2")
end)

-- ---- Observable <-> Promise bridge ---------------------------------------------------------------
test("first():toPromise() resolves with the awaited event (sequencing bridge)", function()
  -- Promise builders auto-start via after(0); fire timers synchronously so the chain runs in-line.
  local saved_after = after
  _G.after = function(_delay, cb) cb(); return 0 end

  local ev = rx.subject()
  local resolved
  ev:first(function(v) return v == "go" end):toPromise()
    .andThen(function(v) resolved = v end)
  ev:onNext("wait"); ev:onNext("go"); ev:onNext("late")
  expect(resolved):eq("go")

  _G.after = saved_after
end)
