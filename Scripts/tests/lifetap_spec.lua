-- Specs for the recovery lifetap booster (AlterAeon.lua): bleed surplus HP into mana while resting, never
-- past the 55% floor, always via a direct `lifetap <n>` amount. Gated to necromancers with the skill.

local wanted   = _AA_TEST.lifetap_wanted
local amount   = _AA_TEST.lifetap_amount
local floor_hp = _AA_TEST.lifetap_floor_hp
local has      = _AA_TEST.has_lifetap
local maybe    = _AA_TEST.maybe_lifetap
local recovery = _AA_TEST.recovery
local FLOOR    = _AA_TEST.LIFETAP_FLOOR
local MIN      = _AA_TEST.LIFETAP_MIN

-- Drive lifetap decisions against a fabricated state + recovery, capturing sent commands. Defaults model
-- the happy path: mid-recovery, resting, out of combat, a level-21 necromancer, HP full, mana low.
local function with(opts, fn)
  local saved_state, saved_send = state, send
  local saved_rec = { pct = recovery.pct, stat = recovery.stat, minions_only = recovery.minions_only }
  opts = opts or {}
  state = {
    hp = opts.hp or 100, maxhp = opts.maxhp or 100,
    mana = opts.mana or 20, maxmana = opts.maxmana or 100,
    position = opts.position or "resting",
    recover = (opts.recover ~= false),
    fighting = opts.fighting or false,
    lifetapping = opts.lifetapping or false,
    lifetap_manafull = opts.manafull or false,
    classes = opts.classes or { Necromancer = { level = 21 } },
  }
  recovery.pct = opts.pct or 0.90
  recovery.stat = opts.stat            -- nil = every-vital recovery
  recovery.minions_only = opts.minions_only
  local sent = {}
  _G.send = function(c) sent[#sent + 1] = c end
  local ok, err = pcall(function() fn(sent) end)
  state, _G.send = saved_state, saved_send
  recovery.pct, recovery.stat, recovery.minions_only = saved_rec.pct, saved_rec.stat, saved_rec.minions_only
  if not ok then error(err, 2) end
end

test("floor is 55% of max hp, rounded to the nearest hp", function()
  with({ maxhp = 200 }, function() expect(floor_hp()):eq(110) end)   -- 200 * 0.55
  with({ maxhp = 205 }, function() expect(floor_hp()):eq(113) end)   -- 205 * 0.55 = 112.75 -> 113
end)

test("has_lifetap requires a necromancer at level 21+", function()
  with({ classes = { Necromancer = { level = 21 } } }, function() expect(has()):truthy() end)
  with({ classes = { Necromancer = { level = 30 } } }, function() expect(has()):truthy() end)
  with({ classes = { Necromancer = { level = 20 } } }, function() expect(has()):falsy() end)
  with({ classes = { Mage = { level = 40 } } },        function() expect(has()):falsy() end)
  with({ classes = {} },                                function() expect(has()):falsy() end)
end)

test("wanted on the happy path: recovering, resting, mana low, hp full, is a necromancer", function()
  with({}, function() expect(wanted()):truthy() end)
end)

test("not wanted when not recovering, in combat, or a fight-cancelled recovery", function()
  with({ recover = false }, function() expect(wanted()):falsy() end)
  with({ fighting = true },  function() expect(wanted()):falsy() end)
end)

test("not wanted for a non-necromancer (self-disables)", function()
  with({ classes = { Cleric = { level = 30 } } }, function() expect(wanted()):falsy() end)
end)

test("not wanted while asleep — sleeping cancels the bleed", function()
  with({ position = "sleeping" }, function() expect(wanted()):falsy() end)
  with({ position = "resting" },  function() expect(wanted()):truthy() end)
  with({ position = "sitting" },  function() expect(wanted()):truthy() end)
end)

test("not wanted once mana reaches the recovery target", function()
  with({ mana = 90, pct = 0.90 }, function() expect(wanted()):falsy() end)  -- exactly at target
  with({ mana = 91, pct = 0.90 }, function() expect(wanted()):falsy() end)
  with({ mana = 89, pct = 0.90 }, function() expect(wanted()):truthy() end)
end)

test("not wanted when hp is already at/below the floor", function()
  with({ hp = 55, maxhp = 100 }, function() expect(wanted()):falsy() end)  -- floor is 55
  with({ hp = 56, maxhp = 100 }, function() expect(wanted()):truthy() end)
end)

test("never bleeds HP for a `recover hp`/`recover stamina` single-stat recovery", function()
  with({ stat = "hp" },   function() expect(wanted()):falsy() end)
  with({ stat = "stam" }, function() expect(wanted()):falsy() end)
  with({ stat = "mana" }, function() expect(wanted()):truthy() end)  -- `recover mana` is exactly the case for it
end)

test("never touches you during a minion-only recovery", function()
  with({ minions_only = true }, function() expect(wanted()):falsy() end)
end)

test("suppressed after the game says mana is already almost full", function()
  with({ manafull = true }, function() expect(wanted()):falsy() end)
end)

test("amount is the whole surplus down to the floor (max safe chunk)", function()
  with({ hp = 100, maxhp = 100 }, function() expect(amount()):eq(45) end)   -- 100 - 55
  with({ hp = 205, maxhp = 205 }, function() expect(amount()):eq(205 - math.ceil(205 * FLOOR)) end)
end)

test("no tap when the surplus is smaller than the minimum chunk", function()
  with({ hp = 55 + MIN - 1, maxhp = 100 }, function() expect(amount()):eq(nil) end)
  with({ hp = 55 + MIN,     maxhp = 100 }, function() expect(amount()):eq(55 + MIN - floor_hp()) end)
end)

-- ---- maybe_lifetap: transitions ----------------------------------------------------------------

test("maybe_lifetap starts a bleed with a direct hp amount when idle and there's safe surplus", function()
  with({ hp = 100, maxhp = 100, lifetapping = false }, function(sent)
    maybe()
    expect(sent[1]):eq("lifetap 45")
  end)
end)

test("maybe_lifetap does not start a second bleed while one is already running", function()
  with({ hp = 100, lifetapping = true }, function(sent)
    maybe()
    expect(#sent):eq(0)
  end)
end)

test("maybe_lifetap stops an in-flight bleed the moment it's no longer wanted", function()
  with({ mana = 95, pct = 0.90, lifetapping = true }, function(sent)  -- mana passed target mid-bleed
    maybe()
    expect(sent[1]):eq("lifetap stop")
  end)
  with({ hp = 55, maxhp = 100, lifetapping = true }, function(sent)   -- bled to the floor
    maybe()
    expect(sent[1]):eq("lifetap stop")
  end)
end)

test("maybe_lifetap is a no-op when idle and there's no safe surplus to tap", function()
  with({ hp = 55, maxhp = 100, lifetapping = false }, function(sent)
    maybe()
    expect(#sent):eq(0)
  end)
end)
