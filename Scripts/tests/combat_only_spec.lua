-- Specs for combat-only mode (cfg.combat_only): the pilot takes turns ONLY while in a fight and stays
-- dormant between fights, auto-resuming when the next fight starts — WITHOUT re-arming per fight. We
-- drive the real fire_if_ready gate, stub `after`/`take_turn` (as pilot_timer_spec does) to see whether
-- a turn fired, and toggle the authoritative combat predicate via state.engaged_until (in_combat()).

local P   = _AIP_TEST.P
local cfg = _AIP_TEST.cfg

-- Run fire_if_ready with after()/take_turn captured; returns whether a turn fired. fire_if_ready sets
-- P.busy=true when it acts (normally reset in the async callback, which we stub away), so we clear it
-- afterward — otherwise the NEXT call would see a stale busy flag. Restores the globals after.
local function fired_by(fn)
  local real_after, real_take = after, take_turn
  local fired = false
  after = function() end
  take_turn = function() fired = true end
  local ok, err = pcall(fn)
  after, take_turn = real_after, real_take
  P.busy = false
  if not ok then error(err, 2) end
  return fired
end

-- The engaged() window (in_combat()) reads state.engaged_until; set it live for the duration of fn.
local function set_combat(on) state.engaged_until = on and (os.time() + 100) or nil end

test("combat-only: dormant out of combat, fires in combat, and auto-resumes the next fight", function()
  local saved = { co = cfg.combat_only, en = P.enabled, busy = P.busy, nav = P.nav,
                  gen = P.gen, lt = P.last_turn, lh = P.last_human, eu = state.engaged_until }
  -- Ready to act on every guard EXCEPT the combat gate: enabled, idle, cooldowns elapsed.
  cfg.combat_only = true
  P.enabled, P.busy, P.nav, P.gen, P.last_turn, P.last_human = true, false, nil, 7, 0, 0

  -- Between fights: no turn (and, per fire_if_ready, no re-arm — pilot_observe re-arms on the next line).
  set_combat(false)
  expect(fired_by(function() fire_if_ready(7) end)):falsy()

  -- Fight starts: the SAME gen/config now fires — no per-fight re-arming needed.
  set_combat(true)
  expect(fired_by(function() fire_if_ready(7) end)):truthy()

  -- Fight ends: dormant again (this is where the user explores/moves manually, untouched).
  set_combat(false)
  expect(fired_by(function() fire_if_ready(7) end)):falsy()

  -- Next fight: auto-resumes with no reconfiguration.
  set_combat(true)
  expect(fired_by(function() fire_if_ready(7) end)):truthy()

  cfg.combat_only, P.enabled, P.busy, P.nav, P.gen, P.last_turn, P.last_human, state.engaged_until =
    saved.co, saved.en, saved.busy, saved.nav, saved.gen, saved.lt, saved.lh, saved.eu
end)

test("combat-only OFF: the pilot fires regardless of combat (master switch unchanged)", function()
  local saved = { co = cfg.combat_only, en = P.enabled, busy = P.busy, nav = P.nav,
                  gen = P.gen, lt = P.last_turn, lh = P.last_human, eu = state.engaged_until }
  cfg.combat_only = false
  P.enabled, P.busy, P.nav, P.gen, P.last_turn, P.last_human = true, false, nil, 3, 0, 0

  set_combat(false)
  expect(fired_by(function() fire_if_ready(3) end)):truthy()   -- acts between fights when combat_only is off
  set_combat(true)
  expect(fired_by(function() fire_if_ready(3) end)):truthy()

  cfg.combat_only, P.enabled, P.busy, P.nav, P.gen, P.last_turn, P.last_human, state.engaged_until =
    saved.co, saved.en, saved.busy, saved.nav, saved.gen, saved.lt, saved.lh, saved.eu
end)

test("combat-only respects the master switch: disabled never fires even in combat", function()
  local saved = { co = cfg.combat_only, en = P.enabled, eu = state.engaged_until,
                  gen = P.gen, lt = P.last_turn, lh = P.last_human }
  cfg.combat_only = true
  P.enabled, P.gen, P.last_turn, P.last_human = false, 4, 0, 0
  set_combat(true)
  expect(fired_by(function() fire_if_ready(4) end)):falsy()   -- pilot.off() wins over combat_only
  cfg.combat_only, P.enabled, state.engaged_until, P.gen, P.last_turn, P.last_human =
    saved.co, saved.en, saved.eu, saved.gen, saved.lt, saved.lh
end)
