-- Specs for dcast (DCast.lua) — the "definite cast" retry loop. The reactive send/await runs in the live
-- engine; here we test the two pure pieces: resolving which spell a `c <args>` line casts (longest known
-- prefix), and the next-move decision (resolve / reject / retry) from an attempt's outcome + the cap.

local AA = _AA_TEST
local resolve = AA.dcast_resolve
local decide  = AA.dcast_decide

test("resolve_spell matches a seeded spell as a whole-word prefix, longest-first", function()
  expect(resolve("fireball orc")):eq("fireball")
  expect(resolve("frostflower")):eq("frostflower")           -- no target
  expect(resolve("ICEBOLT a goblin")):eq("icebolt")          -- case-insensitive
end)

test("resolve_spell returns nil for a spell it doesn't know (→ dcast tells the user)", function()
  expect(resolve("supernova orc")):eq(nil)
  expect(resolve("fire orc")):eq(nil)                        -- "fire" is not "fireball": prefix must be whole-word
end)

test("resolve_spell honours a learned spell, and forget restores the seed default", function()
  dcast.learn("magic missile", "^Your magic missile")
  expect(resolve("magic missile goblin")):eq("magic missile")
  dcast.forget("magic missile")
  expect(resolve("magic missile goblin")):eq(nil)           -- not seeded → gone after forget
end)

test("decide: a landed cast resolves", function()
  expect(({ decide("ok", 1, 25) })[1]):eq("resolve")
end)

test("decide: out-of-mana WAITS (managed — regen then resume, not a give-up)", function()
  expect(({ decide("mana", 1, 25) })[1]):eq("wait")
  expect(({ decide("mana", 99, 25) })[1]):eq("wait")   -- never counts as a miss, so the cap can't reject it
end)

test("decide: \"can't concentrate enough\" is a HARD stop — reject immediately, never retry", function()
  local act, why = decide("cant", 1, 25)
  expect(act):eq("reject"); expect(why):eq("can't concentrate enough")
end)

test("decide: an invalid target is a HARD stop — reject immediately (retrying can never land it)", function()
  local act, why = decide("notarget", 1, 25)
  expect(act):eq("reject"); expect(why):eq("not a valid target for that spell")
end)

test("decide: a fizzle/miss retries until the cap, then rejects", function()
  expect(({ decide("fail", 1, 3) })[1]):eq("retry")
  expect(({ decide("miss", 2, 3) })[1]):eq("retry")
  expect(({ decide("fail", 3, 3) })[1]):eq("reject")        -- hit the cap
end)
