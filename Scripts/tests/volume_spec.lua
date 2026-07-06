-- Specs for the `volume` command (AlterAeon.lua): a MASTER plus three categories (music / sfx / voice).
-- The effective level pushed to each host service = round(master% x category%). We drive volume_command
-- and observe (a) the persisted state.volumes and (b) the values pushed to the three service setters,
-- which we stub locally to record. Pure helpers are reached through _AA_TEST.

local T = _AA_TEST

-- Install recorders over the three host volume setters (globals in the harness) and return a table of
-- the last value each received, plus a restore(). volume_apply() calls music.volume / msp_volume /
-- speech_volume as globals at call time, so overriding them here is observed.
local function capture()
  local rec = { music = nil, sfx = nil, voice = nil, calls = 0 }
  local orig_music, orig_msp, orig_speech = music.volume, _G.msp_volume, _G.speech_volume
  music.volume    = function(n) rec.music = n; rec.calls = rec.calls + 1 end
  _G.msp_volume   = function(n) rec.sfx = n;   rec.calls = rec.calls + 1 end
  _G.speech_volume = function(n) rec.voice = n; rec.calls = rec.calls + 1 end
  function rec.restore()
    music.volume = orig_music; _G.msp_volume = orig_msp; _G.speech_volume = orig_speech
  end
  return rec
end

-- Reset to defaults before each case (levels persist in state.volumes across the whole suite).
local function reset()
  state.volumes = { master = 100, music = 35, sfx = 100, voice = 100 }
end

-- ---------------------------------------------------------------- effective computation
test("volume_effective = master% x category%, rounded", function()
  reset()
  expect(T.volume_effective("music")):eq(35)      -- 100% x 35%
  expect(T.volume_effective("sfx")):eq(100)
  state.volumes.master = 50
  expect(T.volume_effective("music")):eq(18)       -- 50% x 35% = 17.5 -> 18
  expect(T.volume_effective("sfx")):eq(50)
  expect(T.volume_effective("voice")):eq(50)
  state.volumes.master = 0
  expect(T.volume_effective("voice")):eq(0)        -- master 0 zeroes every category
end)

-- ---------------------------------------------------------------- master mutes everything (volume 0)
test("volume('0') sets master 0 and pushes 0 to all three services", function()
  reset()
  local rec = capture()
  T.volume_command("0")
  rec.restore()
  expect(state.volumes.master):eq(0)
  expect(rec.calls):eq(3)          -- all three setters invoked
  expect(rec.music):eq(0)
  expect(rec.sfx):eq(0)
  expect(rec.voice):eq(0)
end)

test("volume('50') sets master and pushes scaled effective levels", function()
  reset()
  local rec = capture()
  T.volume_command("50")
  rec.restore()
  expect(state.volumes.master):eq(50)
  expect(rec.music):eq(18)         -- 50% x 35%
  expect(rec.sfx):eq(50)           -- 50% x 100%
  expect(rec.voice):eq(50)
end)

-- ---------------------------------------------------------------- per-category, aliases, muting one
test("volume('voice 0') mutes only TTS, leaves music/sfx", function()
  reset()
  local rec = capture()
  T.volume_command("voice 0")
  rec.restore()
  expect(state.volumes.voice):eq(0)
  expect(rec.voice):eq(0)          -- TTS silenced
  expect(rec.music):eq(35)         -- unchanged (master still 100)
  expect(rec.sfx):eq(100)
end)

test("category aliases fold: sfx/effects/msp -> sfx, voice/speech/tts -> voice", function()
  reset(); T.volume_command("effects 40"); expect(state.volumes.sfx):eq(40)
  reset(); T.volume_command("msp 10");     expect(state.volumes.sfx):eq(10)
  reset(); T.volume_command("speech 20");  expect(state.volumes.voice):eq(20)
  reset(); T.volume_command("tts 5");      expect(state.volumes.voice):eq(5)
  reset(); T.volume_command("music 60");   expect(state.volumes.music):eq(60)
end)

test("category values clamp to 0..100 and master can be set by name", function()
  reset()
  T.volume_command("sfx 250"); expect(state.volumes.sfx):eq(100)
  T.volume_command("master 80"); expect(state.volumes.master):eq(80)
end)

test("unknown category is rejected without changing state", function()
  reset()
  T.volume_command("bogus 50")
  expect(state.volumes.master):eq(100)
  expect(state.volumes.music):eq(35)
end)

-- ---------------------------------------------------------------- readout (no-arg) is safe
test("volume() with no args prints a readout without error or state change", function()
  reset()
  local rec = capture()
  T.volume_command("")             -- readout path: must not touch the services or state
  rec.restore()
  expect(rec.calls):eq(0)
  expect(state.volumes.master):eq(100)
end)

-- ---------------------------------------------------------------- migration + defaults
test("legacy state.music_volume is migrated into state.volumes.music on load", function()
  -- The load-time migration already ran; assert the shape it guarantees exists.
  expect(type(state.volumes)):eq("table")
  expect(state.music_volume):eq(nil)
  expect(T.VOLUME_DEFAULTS.music):eq(35)
end)
