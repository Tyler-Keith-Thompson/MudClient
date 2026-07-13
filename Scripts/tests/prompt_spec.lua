-- Specs for Prompt.lua's pure kxwq_hud PROMPT parser — the supplementary state source that keeps the
-- HUD's vitals/position/combat block working under `nomelee` (kxwt_fighting never arrives in that mode;
-- see Combat.lua's engaged() note). The sentinel is `kxwq_` (not `kxwt_`) so it doesn't collide with the
-- real kxwt_ protocol namespace; the parser also tolerates the `kxwt_hud` spelling. The trigger that sets
-- the prompt formats runs in Swift (not Lua-testable); on_prompt itself is exercised through the pure
-- parse_prompt/apply_prompt seam.

local parse_prompt = _PROMPT_TEST.parse_prompt
local apply_prompt = _PROMPT_TEST.apply_prompt

local function with_state(st, fn)
  local saved_state, saved_recover_v, saved_recover_p, saved_update = state, __recovery_on_vitals, __recovery_on_position, on_update
  state = st
  __recovery_on_vitals = nil
  __recovery_on_position = nil
  on_update = nil
  local ok, err = pcall(fn)
  state, __recovery_on_vitals, __recovery_on_position, on_update = saved_state, saved_recover_v, saved_recover_p, saved_update
  if not ok then error(err, 2) end
end

test("parse_prompt reads a fighting prompt: vitals, position, and the target (name with spaces)", function()
  local p = parse_prompt("kxwq_hud|80|100|40|50|90|100|standing|65|m|Drax the kender")
  expect(p.hp):eq(80)
  expect(p.maxhp):eq(100)
  expect(p.mana):eq(40)
  expect(p.maxmana):eq(50)
  expect(p.stam):eq(90)
  expect(p.maxstam):eq(100)
  expect(p.position):eq("standing")
  expect(p.fight_pct):eq(65)
  expect(p.fight_gender):eq("m")
  expect(p.fight_name):eq("Drax the kender")
end)

test("parse_prompt reads a default (non-fighting) prompt: vitals + position, no target fields", function()
  local p = parse_prompt("kxwq_hud|100|100|50|50|100|100|sleeping")
  expect(p.hp):eq(100)
  expect(p.maxhp):eq(100)
  expect(p.position):eq("sleeping")
  expect(p.fight_name):eq(nil)
  expect(p.fight_pct):eq(nil)
end)

test("parse_prompt accepts both sentinel letters (kxwq_hud primary, kxwt_hud tolerated)", function()
  local p = parse_prompt("kxwt_hud|80|100|40|50|90|100|standing|65|m|an orc")
  expect(p.hp):eq(80)
  expect(p.position):eq("standing")
  expect(p.fight_name):eq("an orc")
end)

test("parse_prompt ignores a non-kxw[qt]_hud prompt", function()
  expect(parse_prompt("> ")):eq(nil)
  expect(parse_prompt("")):eq(nil)
  expect(parse_prompt(nil)):eq(nil)
end)

test("parse_prompt is defensive against a garbled/short kxwq_hud prompt", function()
  expect(parse_prompt("kxwq_hud|80|100|standing")):eq(nil)          -- too few fields
  expect(parse_prompt("kxwq_hud|x|100|40|50|90|100|standing")):eq(nil)  -- non-numeric hp
  expect(parse_prompt("kxwq_hud||100|40|50|90|100|standing")):eq(nil)   -- blank hp
end)

test("apply_prompt writes vitals/position and sets fighting state from a fighting prompt", function()
  with_state({}, function()
    apply_prompt(parse_prompt("kxwq_hud|80|100|40|50|90|100|standing|65|m|Drax the kender"))
    expect(state.hp):eq(80)
    expect(state.maxhp):eq(100)
    expect(state.mana):eq(40)
    expect(state.maxmana):eq(50)
    expect(state.stam):eq(90)
    expect(state.maxstam):eq(100)
    expect(state.position):eq("standing")
    expect(state.fighting):eq(true)
    expect(state.fight_name):eq("Drax the kender")
    expect(state.fight_pct):eq(65)
  end)
end)

test("apply_prompt clears fighting state from a default (non-fighting) prompt", function()
  with_state({ fighting = true, fight_name = "an orc", fight_pct = 40 }, function()
    apply_prompt(parse_prompt("kxwq_hud|100|100|50|50|100|100|standing"))
    expect(state.hp):eq(100)
    expect(state.position):eq("standing")
    expect(state.fighting):eq(false)
    expect(state.fight_name):eq(nil)
    expect(state.fight_pct):eq(nil)
  end)
end)

test("apply_prompt(nil) (a non-matching prompt) does not touch state", function()
  local st = { hp = 5, maxhp = 10, fighting = true, fight_name = "x", position = "sitting" }
  with_state(st, function()
    apply_prompt(nil)
    expect(state.hp):eq(5)
    expect(state.fighting):eq(true)
    expect(state.fight_name):eq("x")
    expect(state.position):eq("sitting")
  end)
end)

-- apply_prompt is AutoFight's nomelee combat signal (AutoFight.lua defines __autofight_prompt); this just
-- asserts apply_prompt CALLS the bridge with the right args, via a fake recorder global — not AutoFight's
-- own freshness-guard behaviour (that's autofight_spec.lua's job).
test("apply_prompt calls __autofight_prompt with the fight pct/name from a fighting prompt", function()
  local saved = __autofight_prompt
  local calls = {}
  __autofight_prompt = function(pct, name) calls[#calls + 1] = { pct, name } end
  local ok, err = pcall(function()
    with_state({}, function()
      apply_prompt(parse_prompt("kxwq_hud|80|100|40|50|90|100|standing|65|m|Drax the kender"))
    end)
  end)
  __autofight_prompt = saved
  if not ok then error(err, 2) end
  expect(#calls):eq(1)
  expect(calls[1][1]):eq(65)
  expect(calls[1][2]):eq("Drax the kender")
end)

test("apply_prompt calls __autofight_prompt with (nil, nil) from a default (non-fighting) prompt", function()
  local saved = __autofight_prompt
  local calls = {}
  __autofight_prompt = function(pct, name) calls[#calls + 1] = { pct, name } end
  local ok, err = pcall(function()
    with_state({ fighting = true, fight_name = "an orc", fight_pct = 40 }, function()
      apply_prompt(parse_prompt("kxwq_hud|100|100|50|50|100|100|standing"))
    end)
  end)
  __autofight_prompt = saved
  if not ok then error(err, 2) end
  expect(#calls):eq(1)
  expect(calls[1][1]):eq(nil)
  expect(calls[1][2]):eq(nil)
end)
