-- Specs for Soulforge.lua — the auto-merge-soulstones-upward routine.
--
-- CHARACTERIZATION suite, mirroring autofight_spec / recover_spec. The PURE helpers (soulstone_color,
-- parse_soulstones, tier, is_raw, plan_next_forge, target-selection) are asserted directly on their
-- return values; the FLOW is asserted on the OBSERVABLE send sequence (SF.sent) it emits — never on
-- internal fields. A reimplementation that stored state differently must still turn these green because
-- it reproduces the same plans and the same casts.
--
-- The flow is driven by calling the SAME hit_* handlers the live triggers dispatch to (SF.forge_result /
-- SF.fail / SF.bad_selection / …) plus SF.on_inv (the read-inventory-then-cast step). The harness has no
-- event loop, so a spec sets state.inventory then calls SF.on_inv directly rather than waiting on a timer.

local SF = _SF_TEST

-- Build an inventory of soulstone display names from short colour tokens. "pale"/"deep" expand to the
-- real two-word phrases; anything else is "a <color> soulstone".
local NAME = { red = "a red soulstone", yellow = "a yellow soulstone", green = "a green soulstone",
               pale = "a pale blue soulstone", deep = "a deep blue soulstone", purple = "a purple soulstone" }
local function inv(...)
  local out = {}
  for _, c in ipairs({ ... }) do out[#out + 1] = NAME[c] or c end
  return out
end

local function seq() local t = {}; for i, v in ipairs(SF.sent) do t[i] = v end; return t end

-- Capture echo lines (colour stripped) for the cases where a user-visible message is the only observable.
local function capture_echo(fn)
  local saved, out = echo, {}
  echo = function(s) out[#out + 1] = (tostring(s):gsub("\27%[[%d;]*m", "")) end
  local ok, err = pcall(fn)
  echo = saved
  if not ok then error(err, 2) end
  return table.concat(out, "\n")
end

-- Start an op with a given carried inventory and run it to its first decision: SF.begin sends `inv`, then
-- SF.on_inv reads state.inventory and either casts or finishes.
local function begin_with(inventory)
  SF.reset()
  state.inventory = inventory
  SF.begin()          -- sends "inv"
  SF.on_inv()         -- reads inventory -> casts or finishes
end

-- ---- (a) colour parsing --------------------------------------------------------------------------
test("soulstone_color maps display names (incl. the two-word blues) to tier keys; nil for non-stones", function()
  expect(SF.soulstone_color("a red soulstone")):eq("red")
  expect(SF.soulstone_color("a green soulstone")):eq("green")
  expect(SF.soulstone_color("a pale blue soulstone")):eq("pale")
  expect(SF.soulstone_color("a deep blue soulstone")):eq("deep")
  expect(SF.soulstone_color("a purple soulstone")):eq("purple")
  expect(SF.soulstone_color("a red dragonscale")):eq(nil)   -- gear that shares a colour word is NOT a stone
  expect(SF.soulstone_color("a green cloak")):eq(nil)
end)

test("tier orders the colours red<yellow<green<pale<deep<purple", function()
  expect(SF.tier("red")):eq(1);  expect(SF.tier("yellow")):eq(2); expect(SF.tier("green")):eq(3)
  expect(SF.tier("pale")):eq(4); expect(SF.tier("deep")):eq(5);   expect(SF.tier("purple")):eq(6)
end)

test("parse_soulstones assigns 1-based ordinals in inventory order (keyword-scoped)", function()
  local s = SF.parse_soulstones(inv("red", "green", "green"))
  expect(#s):eq(3)
  expect(s[1].ord):eq(1); expect(s[1].color):eq("red")
  expect(s[2].ord):eq(2); expect(s[2].color):eq("green")
  expect(s[3].ord):eq(3); expect(s[3].color):eq("green")
end)

test("a non-stone soulstone-keyword item still consumes an ordinal slot but is unplannable (color nil)", function()
  -- Ground truth: `N.soulstone` counts every keyword match, so an odd keyworded item shifts the numbering
  -- even though we'd never merge it.
  local s = SF.parse_soulstones({ "a green soulstone", "a soulstone shard", "a red soulstone" })
  expect(#s):eq(3)
  expect(s[2].color):eq(nil)      -- unrecognised colour → not plannable…
  expect(s[3].ord):eq(3)          -- …but it still pushed the red to ordinal 3
end)

-- ---- (a1) carried-container detection ------------------------------------------------------------
test("looks_like_container / container_kw recognise the common soulstone carriers", function()
  expect(SF.looks_like_container("a pocket dimension")):eq(true)
  expect(SF.looks_like_container("a small sack")):eq(true)
  expect(SF.looks_like_container("an icy vortex")):eq(true)
  expect(SF.looks_like_container("a green soulstone")):eq(false)   -- a stone is never a container
  expect(SF.looks_like_container("the horn of a minotaur")):eq(false)
  expect(SF.container_kw("a small sack")):eq("sack")               -- the LAST noun is the get-keyword
  expect(SF.container_kw("a pocket dimension")):eq("dimension")
  expect(SF.container_kw("an icy vortex")):eq("vortex")
end)

test("carried_containers lists DISTINCT container keywords in order, skipping stones and gear", function()
  local c = SF.carried_containers({ "a red soulstone", "a small sack", "a pocket dimension",
                                    "the horn of a minotaur", "an icy vortex", "a small sack" })
  expect(#c):eq(3)                                                 -- the duplicate sack is deduped
  expect(c[1]):eq("sack"); expect(c[2]):eq("dimension"); expect(c[3]):eq("vortex")
end)

-- ---- (a2) in-memory model update: apply_forge ----------------------------------------------------
test("apply_forge collapses the cast pair to the result colour, base upgraded IN PLACE, renumbered", function()
  local m = SF.parse_soulstones(inv("red", "yellow", "green"))
  local ok = SF.apply_forge(m, 1, 2, "green", "yellow")   -- merged red(1)+yellow(2); yellow base → green
  expect(ok):eq(true)
  expect(#m):eq(2)
  expect(m[1].color):eq("green"); expect(m[1].ord):eq(1)  -- the upgraded base (former yellow), lower slot
  expect(m[2].color):eq("green"); expect(m[2].ord):eq(2)  -- the untouched green, ordinal shifted 3 → 2
end)

test("apply_forge returns false on a desync (base colour matches neither cast stone) → caller re-reads", function()
  local m = SF.parse_soulstones(inv("red", "green"))
  expect(SF.apply_forge(m, 1, 2, "green", "purple")):eq(false)   -- 'purple' base is impossible here
  expect(SF.apply_forge(m, 1, 9, "yellow", "red")):eq(false)     -- ord 9 not present
end)

-- ---- (b) merge policy: plan_next_forge -----------------------------------------------------------
test("two same-colour stones plan the 1st and 2nd ordinals → c soulforge 1.soulstone 2.soulstone", function()
  local pair = SF.plan_next_forge(SF.parse_soulstones(inv("green", "green")))
  expect(pair.a):eq(1); expect(pair.b):eq(2)
  expect(SF.forge_cmd(pair)):eq("c soulforge 1.soulstone 2.soulstone")
end)

test("a lone LOW stone is consumed (mixed up), not stranded while others pair", function()
  -- Only ONE red, plus a green pair. The red has no same-colour partner, so it's MIXED with a green
  -- (ords 1,2) — we don't leave the red sitting there and forge the greens instead.
  local pair = SF.plan_next_forge(SF.parse_soulstones(inv("red", "green", "green")))
  expect(pair.a):eq(1); expect(pair.b):eq(2)
end)

test("a same-colour partner for the lowest stone is preferred over mixing", function()
  -- Two reds AND two greens: the lowest stone (red) has a same-colour partner → merge the red pair (1,2),
  -- not a red+green mix.
  local pair = SF.plan_next_forge(SF.parse_soulstones(inv("red", "red", "green", "green")))
  expect(pair.a):eq(1); expect(pair.b):eq(2)
end)

test("among colours that BOTH have a pair, the lowest tier goes first", function()
  local pair = SF.plan_next_forge(SF.parse_soulstones(inv("red", "red", "green", "green")))
  expect(pair.a):eq(1); expect(pair.b):eq(2)   -- the red pair, not the green
end)

test("mixes the two lowest-tier stones only when NO colour has a pair", function()
  local pair = SF.plan_next_forge(SF.parse_soulstones(inv("red", "green")))
  expect(pair.a):eq(1); expect(pair.b):eq(2)   -- distinct colours, lowest tiers
  -- yellow+green mix (no pair anywhere) picks the two lowest tiers present.
  local p2 = SF.plan_next_forge(SF.parse_soulstones(inv("green", "yellow")))
  expect(p2.a):eq(1); expect(p2.b):eq(2)
end)

test("done (nil plan) when fewer than two raw stones remain", function()
  expect(SF.plan_next_forge(SF.parse_soulstones(inv("red")))):eq(nil)          -- one stone
  expect(SF.plan_next_forge(SF.parse_soulstones({}))):eq(nil)                   -- none
end)

-- ---- (c) pale/deep policy ------------------------------------------------------------------------
test("a FEW pale stones are kept, not merged (below pale_lots) → done", function()
  -- 3 pale, pale_lots is 4 → pale isn't surplus yet → nothing raw → done.
  expect(SF.plan_next_forge(SF.parse_soulstones(inv("pale", "pale", "pale")))):eq(nil)
  expect(SF.target_tier(SF.parse_soulstones(inv("pale", "pale", "pale")))):eq(SF.tier("pale"))
end)

test("LOTS of pale (>= pale_lots) merges the surplus pale→deep, keeping keep_pale on hand", function()
  local stones = SF.parse_soulstones(inv("pale", "pale", "pale", "pale", "pale"))   -- 5 pale
  expect(SF.is_raw("pale", stones)):eq(true)          -- surplus → mergeable
  local pair = SF.plan_next_forge(stones)
  expect(pair.a):eq(1); expect(pair.b):eq(2)          -- first two pale ordinals
  expect(SF.target_tier(stones)):eq(SF.tier("deep"))  -- climbing toward deep now
  -- Down to keep_pale (2) pale would NOT be raw — so the loop stops before spending the stash.
  expect(SF.is_raw("pale", SF.parse_soulstones(inv("pale", "pale")))):eq(false)
end)

test("never merges deep or purple (the goal, not fuel)", function()
  expect(SF.is_raw("deep", SF.parse_soulstones(inv("deep", "deep")))):eq(false)
  expect(SF.is_raw("purple", SF.parse_soulstones(inv("purple", "purple")))):eq(false)
  expect(SF.plan_next_forge(SF.parse_soulstones(inv("deep", "deep", "purple")))):eq(nil)
  -- A pile of surplus pale alongside deep stones still targets ONLY the pale — the deep is never touched.
  local pair = SF.plan_next_forge(SF.parse_soulstones(inv("pale", "pale", "pale", "pale", "deep", "deep")))
  expect(pair.a):eq(1); expect(pair.b):eq(2)          -- pale ords 1,2; deep (ords 5,6) never selected
end)

test("BUG 1 fix: plan_next_forge's pale-surplus test honors an explicit CONTEXT, not just the carried subset", function()
  -- 3 pale on hand alone: not surplus (pale_lots is 4) → no context arg means "judge stones on their own".
  local carried = SF.parse_soulstones(inv("pale", "pale", "pale"))
  expect(SF.plan_next_forge(carried)):eq(nil)
  -- The SAME 3 carried stones, but a wider context (e.g. carried + what's still sitting in a container)
  -- shows 4 pale total → surplus → the carried pair IS planned (ordinals still come from `carried`).
  local context = SF.parse_soulstones(inv("pale", "pale", "pale", "pale"))
  local pair = SF.plan_next_forge(carried, context)
  expect(pair.a):eq(1); expect(pair.b):eq(2)
end)

-- ---- (d) flow: observable send sequences ---------------------------------------------------------
test("begin reads inventory then casts the merge: inv → c soulforge 1.soulstone 2.soulstone", function()
  begin_with(inv("green", "green"))
  expect(SF.sent[1]):eq("inv")               -- first thing an op does: re-read what you carry
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")
end)

test("inventory read is RESPONSE-DRIVEN: a laggy `inv` reply is used when it lands, not a stale snapshot", function()
  -- Reproduces the bug: on a laggy server the `inv`/`look in` reply can arrive well after any fixed short
  -- wait, so a timer-based read builds its plan from an empty/stale state.inventory. SF.begin() now only
  -- SENDS `inv` and starts waiting (SF.awaiting_inv() true) — it must NOT plan yet, because the reply
  -- hasn't landed. Only once state.inventory is actually populated AND the completion hook fires
  -- (SF.inventory_ready(), the test-seam mirror of the on_inventory global AlterAeon.lua calls when the
  -- "You are carrying:" block closes) does soulforge read and plan.
  SF.reset()
  state.inventory = {}                       -- stale/empty — as if a previous read, or nothing yet
  SF.begin()
  expect(#SF.sent):eq(1)                     -- only the send so far — no premature read/cast
  expect(SF.sent[1]):eq("inv")
  expect(SF.awaiting_inv()):eq(true)

  -- The laggy reply finally lands: state.inventory gets populated, THEN the block-close hook fires.
  state.inventory = inv("yellow", "green")
  SF.inventory_ready()

  expect(SF.awaiting_inv()):eq(false)
  expect(#SF.sent):eq(2)
  expect(SF.sent[2]):eq("c soulforge 1.soulstone 2.soulstone")   -- planned from the LATE reply, not the stale empty one
end)

test("inventory_ready is a no-op when nothing is awaiting it (an unrelated/late fire can't double-plan)", function()
  SF.reset()
  expect(SF.active()):eq(false)
  SF.inventory_ready()               -- no op running at all
  expect(SF.active()):eq(false)

  begin_with(inv("green", "green"))  -- begin_with already resolves via SF.on_inv, so awaiting_inv is clear
  expect(SF.awaiting_inv()):eq(false)
  local n = #SF.sent
  SF.inventory_ready()               -- stray fire — must not trigger another read/cast
  expect(#SF.sent):eq(n)
end)

test("a forge result updates the model IN MEMORY and casts the next merge with NO re-inventory", function()
  begin_with(inv("green", "green", "green", "green"))
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")   -- first green pair
  local n = #SF.sent
  SF.forge_result("green", "green")          -- green+green → green (no upgrade); model 4→3, all in memory
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")   -- next merge cast immediately
  for i = n + 1, #SF.sent do expect(SF.sent[i]):ne("inv") end           -- and NOT a single re-inventory
end)

test("the model climbs colours from forge FEEDBACK alone — exactly ONE inv for the whole run", function()
  begin_with(inv("red", "red", "green", "green"))
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")   -- lowest pair: the two reds
  SF.forge_result("yellow", "red")           -- red+red → yellow; model = [yellow, green, green]
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")   -- lone yellow MIXED with a green
  SF.forge_result("green", "green")          -- yellow+green → green (base green); model = [green, green]
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")   -- now the green pair
  SF.forge_result("pale", "green")           -- green+green → pale; model = [pale] → done
  expect(SF.active()):eq(false)
  local invs = 0; for _, c in ipairs(seq()) do if c == "inv" then invs = invs + 1 end end
  expect(invs):eq(1)                         -- the initial read only; every step after was in-memory
end)

test("finishes when fewer than two mergeable stones remain (no further cast)", function()
  begin_with(inv("green", "green"))
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")
  local n = #SF.sent
  SF.forge_result("pale", "green")           -- green+green → pale; one stone left in the model
  expect(#SF.sent):eq(n)                     -- no new cast, and no re-inventory
  expect(SF.active()):eq(false)              -- op settled (done)
end)

test("finishing AFTER a forge reports 'done', not the container hint", function()
  SF.reset()
  state.inventory = inv("red", "red")
  SF.begin(); SF.on_inv()                    -- casts the red pair
  local out = capture_echo(function()
    SF.forge_result("yellow", "red")         -- reds merged → we DID forge; model = [yellow] (one left)
  end)
  expect(out):contains("done")
  expect(out:find("container", 1, true) == nil):eq(true)   -- NOT the "started too thin" hint
  expect(SF.active()):eq(false)
end)

test("a 'fail to cast' RECASTS the SAME command — no re-inventory", function()
  begin_with(inv("green", "green"))
  local cmd = SF.sent[#SF.sent]
  expect(cmd):eq("c soulforge 1.soulstone 2.soulstone")
  local n = #SF.sent
  SF.fail()                                  -- skill fizzled → schedule a recast (no immediate send)
  expect(#SF.sent):eq(n)                     -- nothing sent yet (paced), and crucially NO `inv`
  SF.recast()                                -- the pending recast fires
  expect(SF.sent[#SF.sent]):eq(cmd)          -- the SAME command, re-cast
  expect(SF.sent[#SF.sent]):ne("inv")        -- not a re-inventory
end)

test("a 'two different soulstones' rejection re-inventories and re-plans", function()
  begin_with(inv("red", "green"))
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")
  SF.bad_selection()                         -- ordinals collided / matched gear → re-read + re-plan
  expect(SF.sent[#SF.sent]):eq("inv")
  state.inventory = inv("green", "green")    -- fresh read
  SF.on_inv()
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")
end)

test("out of mana stops the op (rejects) and casts nothing more", function()
  begin_with(inv("green", "green"))
  local n = #SF.sent
  SF.mana()                                  -- "You don't have enough mana." → stop
  expect(#SF.sent):eq(n)                     -- no further sends
  expect(SF.active()):eq(false)
end)

test("fewer than two carried stones resolves with a container hint (no forge cast)", function()
  local out = capture_echo(function()
    begin_with(inv("green"))                 -- only one on hand
  end)
  expect(out):contains("container")          -- hint to pull stones out of a container
  for _, c in ipairs(seq()) do expect(c:find("soulforge", 1, true) == nil):eq(true) end   -- never cast
  expect(SF.active()):eq(false)
end)

-- ---- (f) gather phase: LOOK IN containers, understand, then pull only the raw colours --------------
test("container_soulstone parses look-in lines (with/without count prefix); nil for non-stones", function()
  local c, n = SF.container_soulstone("a red soulstone");        expect(c):eq("red");  expect(n):eq(1)
  c, n = SF.container_soulstone("(    3) a red soulstone");      expect(c):eq("red");  expect(n):eq(3)
  c, n = SF.container_soulstone("a pale blue soulstone");        expect(c):eq("pale"); expect(n):eq(1)
  expect(SF.container_soulstone("a small sack")):eq(nil)                         -- not a soulstone
  expect(SF.container_soulstone("You get a red soulstone from a small sack.")):eq(nil)  -- not the bare form
end)

test("gather: with no carried containers it goes straight to forging (no look/get)", function()
  begin_with(inv("green", "green"))
  for _, c in ipairs(seq()) do
    expect(c:find("look in", 1, true) == nil):eq(true)
    expect(c:find("get ", 1, true) == nil):eq(true)
  end
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")
end)

test("gather: LOOKS IN the container, understands contents, then pulls ONLY the raw colours", function()
  SF.reset()
  state.inventory = { "a small sack" }        -- one container, nothing loose yet
  SF.begin()                                  -- "inv"
  SF.on_inv()                                 -- gather/look → `look in sack`
  expect(SF.sent[#SF.sent]):eq("look in sack")
  SF.look_soulstone("a red soulstone")        -- the sack's contents, as the look-in block streams them
  SF.look_soulstone("a green soulstone")
  SF.look_soulstone("a deep blue soulstone")  -- deep blue is the GOAL, not fuel — must be left alone
  SF.look_done()                              -- block quiet → decide + start pulling
  expect(SF.sent[#SF.sent]):eq("get red soulstone sack")     -- raw red first (never `get deep …`)
  SF.get_ok("red")            -- one red out (appended to the model); known count (1) exhausted → next queued colour
  expect(SF.sent[#SF.sent]):eq("get green soulstone sack")   -- advanced WITHOUT a trailing miss-probe for red
  SF.get_ok("green")          -- green out; known count (1) exhausted → queue done → forge STRAIGHT from memory
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")   -- the pulled red + green
  local invs, gets = 0, 0
  for _, c in ipairs(seq()) do
    expect(c:find("get deep", 1, true) == nil):eq(true)      -- deep blue left in the sack
    if c == "inv" then invs = invs + 1 end
    if c:find("^get ") then gets = gets + 1 end
  end
  expect(invs):eq(1)                          -- only the initial read; the pull → forge was all in memory
  expect(gets):eq(2)                          -- exactly one `get` per known-count colour, no trailing miss-probe
end)

test("gather: an EMPTY container is looked in, reported, and not pulled — loose stones forge, no extra inv", function()
  SF.reset()
  state.inventory = { "a small sack", "a green soulstone", "a green soulstone" }
  SF.begin(); SF.on_inv()
  expect(SF.sent[#SF.sent]):eq("look in sack")
  local n = #SF.sent
  SF.look_done()                              -- no soulstone lines fed → sack empty → nothing to pull
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")   -- the two loose greens
  for i = n + 1, #SF.sent do
    expect(SF.sent[i]):ne("inv")                                        -- pulled 0 → no re-read
    expect(SF.sent[i]:find("get ", 1, true) == nil):eq(true)           -- and never a get
  end
end)

test("gather: a container of ONLY deep blue is looked in but nothing is pulled (all non-raw)", function()
  SF.reset()
  state.inventory = { "a pocket dimension", "a red soulstone", "a red soulstone" }
  SF.begin(); SF.on_inv()
  expect(SF.sent[#SF.sent]):eq("look in dimension")
  SF.look_soulstone("a deep blue soulstone")
  SF.look_soulstone("a deep blue soulstone")
  SF.look_done()                              -- only deep blue inside → nothing raw → no pull
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")   -- forge the two loose reds
  for _, c in ipairs(seq()) do expect(c:find("get ", 1, true) == nil):eq(true) end
end)

test("gather: a full pack during pulling stops the sweep and forges what we have (no inv)", function()
  SF.reset()
  state.inventory = { "a pocket dimension" }
  SF.begin(); SF.on_inv()
  expect(SF.sent[#SF.sent]):eq("look in dimension")
  SF.look_soulstone("(  3) a red soulstone")  -- count-prefixed grouping
  SF.look_done()
  expect(SF.sent[#SF.sent]):eq("get red soulstone dimension")
  SF.get_ok("red"); SF.get_ok("red")          -- pulled two (both appended to the model)…
  SF.carry_full()                             -- "You can't carry that many items." → stop, forge from memory
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")
end)

test("BUG 2 fix: pull is COUNT-BOUNDED to the known look-in count — no trailing miss-probe get", function()
  SF.reset()
  state.inventory = { "a small sack" }
  SF.begin(); SF.on_inv()
  expect(SF.sent[#SF.sent]):eq("look in sack")
  SF.look_soulstone("(  3) a red soulstone")   -- the sack holds EXACTLY 3
  SF.look_done()
  expect(SF.sent[#SF.sent]):eq("get red soulstone sack")
  SF.get_ok("red"); SF.get_ok("red"); SF.get_ok("red")   -- pull all 3 known — no fourth `get` fired
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")   -- advances straight to forging
  local gets = 0
  for _, c in ipairs(seq()) do if c:find("^get ") then gets = gets + 1 end end
  expect(gets):eq(3)   -- exactly the known count — never the extra miss-probe get
end)

test("BUG 1 fix: pale surplus is judged on carried+container combined, so a pull cut short still forges", function()
  -- 3 pale carried + 1 more sitting in the sack (4 total, pale_lots=4) → the LOOK phase sees it as surplus
  -- and queues a pull. But the pack fills before that pull lands (carry_full), so the container's pale is
  -- NEVER actually moved into the carried model. Before the fix, plan_and_cast would judge surplus off the
  -- carried model alone (3 < pale_lots) and forge nothing; the fix judges it off the combined picture (4),
  -- same as the pull decision, so the carried pale pair still forges.
  SF.reset()
  state.inventory = { "a small sack", "a pale blue soulstone", "a pale blue soulstone", "a pale blue soulstone" }
  SF.begin(); SF.on_inv()
  expect(SF.sent[#SF.sent]):eq("look in sack")
  SF.look_soulstone("a pale blue soulstone")   -- 1 more pale sitting in the sack
  SF.look_done()                               -- combined (3 carried + 1 sack = 4) is surplus → queues a pull
  expect(SF.sent[#SF.sent]):eq("get pale soulstone sack")
  SF.carry_full()                              -- pack fills before the pull lands — the sack's pale stays put
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")   -- forges the carried pale surplus anyway
end)

-- ---- (g) stow: put the forged stones back, and batch through a big stash -------------------------
test("stow: after a forge pass, PUTS the results back into the source container", function()
  SF.reset()
  state.inventory = { "a small sack" }
  SF.begin(); SF.on_inv()                       -- look in sack
  SF.look_soulstone("a red soulstone"); SF.look_soulstone("a red soulstone")
  SF.look_done()                                -- red is raw → pull
  expect(SF.sent[#SF.sent]):eq("get red soulstone sack")
  SF.get_ok("red"); SF.get_ok("red"); SF.get_empty()   -- pulled 2 reds → forge from memory (no inv)
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")
  SF.forge_result("yellow", "red")              -- red+red→yellow; pass done → STOW the leftover back
  expect(SF.sent[#SF.sent]):eq("put soulstone sack")
end)

test("cycle: LOOKS ONCE and never re-inventories between passes — memory-driven, two batches, converges", function()
  -- 4 greens in the sack, but the pack only holds 2 at a time → it takes TWO pull/forge/stow batches. The
  -- whole thing runs off the in-memory model: exactly ONE `look in` and ONE `inv` (the initial) all run.
  SF.reset()
  state.inventory = { "a small sack" }
  SF.begin(); SF.on_inv()
  expect(SF.sent[#SF.sent]):eq("look in sack")            -- the ONE look
  SF.look_soulstone("(  4) a green soulstone"); SF.look_done()
  -- BATCH 1: pull two greens (pack fills), forge the pair, stow the result — all from memory.
  expect(SF.sent[#SF.sent]):eq("get green soulstone sack")
  SF.get_ok("green"); SF.get_ok("green"); SF.carry_full()
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")
  SF.forge_result("pale", "green")                        -- green+green→pale (lone pale can't re-forge)
  expect(SF.sent[#SF.sent]):eq("put soulstone sack")
  SF.put_ok("pale"); SF.put_empty()                       -- pale stowed; 2 greens still in the sack → BATCH 2
  expect(SF.sent[#SF.sent]):eq("get green soulstone sack")   -- straight to pulling — NO inv, NO second look
  SF.get_ok("green"); SF.get_ok("green"); SF.get_empty()
  expect(SF.sent[#SF.sent]):eq("c soulforge 1.soulstone 2.soulstone")
  SF.forge_result("pale", "green")
  expect(SF.sent[#SF.sent]):eq("put soulstone sack")
  SF.put_ok("pale"); SF.put_empty()                       -- now sack = 2 pale (not surplus) → nothing raw → done
  expect(SF.active()):eq(false)
  local looks, invs = 0, 0
  for _, c in ipairs(seq()) do
    if c == "look in sack" then looks = looks + 1 end
    if c == "inv" then invs = invs + 1 end
  end
  expect(looks):eq(1)                                     -- looked EXACTLY once
  expect(invs):eq(1)                                      -- inventoried EXACTLY once (the initial read)
end)

-- ---- (e) safety: bounded no-progress -------------------------------------------------------------
test("bails after max_no_progress consecutive rejected selections (no forge in between)", function()
  SF.reset()
  state.inventory = inv("red", "green")      -- a mix the game keeps rejecting
  SF.begin(); SF.on_inv()                    -- first cast
  -- The game keeps rejecting the selection with no forge landing between them → give up after the cap.
  for _ = 1, SF.cfg.max_no_progress do
    SF.bad_selection()                       -- re-inventory & re-plan
    SF.on_inv()
  end
  expect(SF.active()):eq(false)              -- stopped instead of spinning forever
end)
