-- Specs for AlterAeon.lua's recovery/prompt-handling helpers — pinned ahead of the host-hooks refactor
-- that will move prompt parsing + the connection/recovery state machine onto new APIs. These lock the
-- CURRENT observable behavior: which position command `recover` picks, and the exact state snapshot the
-- pilot/`state` alias reads. The kxwt_prompt/kxwt_position triggers themselves run in Swift; here we test
-- the pure helpers those handlers call (choose_recovery_position) and the snapshot builder (describe_state).

local choose = _AA_TEST.choose_recovery_position

-- Run `fn` against a fabricated `state`, capturing the single command choose_recovery_position sends.
-- Vitals are given as percentages of a 100 max, so 90 == 90%. Always restores the live state + send.
local function capture_choice(hp, mp, sp)
  local saved_state, saved_send = state, send
  local sent
  state = { hp = hp, maxhp = 100, mana = mp, maxmana = 100, stam = sp, maxstam = 100 }
  send = function(c) sent = c end
  local ok, err = pcall(choose)
  state, send = saved_state, saved_send
  if not ok then error(err, 2) end
  return sent
end

test("choose_recovery_position rests only when hp>85% AND mana<100% AND stamina>75%", function()
  -- The one combination that rests: healthy hp/stam, but mana still to recover (rest heals faster + you
  -- stay half-alert). Every other case sleeps.
  expect(capture_choice(100, 50, 100)):eq("rest")
  expect(capture_choice(90, 50, 90)):eq("rest")
end)

test("choose_recovery_position does NOT deepen posture for a fully-recovered player", function()
  -- Once you're at/above the recovery target there's nothing to rest or sleep for — staying down when
  -- you're full makes no sense. (When you're full but still waiting on minions, the posture logic stands
  -- you up / wakes you from sleep — covered in minion_heal_spec.) Position defaults to standing here, so
  -- there's nothing to change → no command.
  expect(capture_choice(100, 100, 100)):eq(nil)
end)

test("choose_recovery_position sleeps when hp or stamina is low (deeper heal needed)", function()
  expect(capture_choice(80, 50, 100)):eq("sleep")     -- hp <=85% -> sleep
  expect(capture_choice(100, 50, 70)):eq("sleep")     -- stamina <=75% -> sleep
end)

test("choose_recovery_position boundaries are strict > (85% hp and 75% stam both sleep)", function()
  expect(capture_choice(85, 50, 100)):eq("sleep")     -- hp exactly 85% -> not > 0.85 -> sleep
  expect(capture_choice(100, 50, 75)):eq("sleep")     -- stam exactly 75% -> not > 0.75 -> sleep
end)

-- ---- describe_state snapshot (fed to the AI + printed by the `state` alias) ----------------------

local function with_state(st, fn)
  local saved = state
  state = st
  local ok, err = pcall(fn)
  state = saved
  if not ok then error(err, 2) end
end

test("describe_state renders vitals, the (ready) label, and recovery mode", function()
  with_state({ name = "Bob", hp = 95, maxhp = 100, mana = 95, maxmana = 100, stam = 95, maxstam = 100,
               fighting = false, spells = {}, recover = true }, function()
    local s = describe_state()
    expect(s):contains("name: Bob")
    expect(s):contains("hp: 95/100, mana: 95/100, stamina: 95/100 (ready)")  -- all >=90% -> (ready)
    expect(s):contains("combat: not fighting")
    expect(s):contains("recovery mode: on")
  end)
end)

test("describe_state omits (ready) when a vital is low, and shows the combat line", function()
  with_state({ name = "Bob", hp = 10, maxhp = 100, mana = 95, maxmana = 100, stam = 95, maxstam = 100,
               fighting = true, fight_name = "a goblin", fight_pct = 40, spells = {}, recover = false },
    function()
      local s = describe_state()
      expect(s:find(" (ready)", 1, true)):falsy()                 -- hp low -> not ready
      expect(s):contains("combat: fighting a goblin (40%)")
      expect(s):contains("recovery mode: off")
    end)
end)

test("describe_state lists active spells and falls back to 'unknown' with no name", function()
  with_state({ hp = 50, maxhp = 100, mana = 50, maxmana = 100, stam = 50, maxstam = 100,
               fighting = false, spells = { ["mana shield"] = true } }, function()
    local s = describe_state()
    expect(s):contains("name: unknown")
    expect(s):contains("active spells: mana shield")
  end)
end)
