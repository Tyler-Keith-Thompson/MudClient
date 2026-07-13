-- Specs for the music-channel router (Audio.lua): the kxwt_music channel_play/channel_stop lines route
-- to music.play/music.stop and record each channel's current track in state.music (the HUD "♪" mood).
-- The trigger REGEXES run in Swift (untestable from Lua), so we drive the plain handler helpers the
-- trigger bodies call (byte-identical logic) and assert the OBSERVABLE output: the music.play/stop calls
-- (channel + full soundpack path) and the persisted state.music. Helpers are reached through _AA_TEST.

local T = _AA_TEST

-- Record the music.play/music.stop calls for the duration of fn, then restore. music_channel_play/stop
-- call the `music` table's methods as globals at call time, so overriding them here is observed.
local function capture(fn)
  local rec = { plays = {}, stops = {} }
  local orig_play, orig_stop = music.play, music.stop
  music.play = function(ch, path) rec.plays[#rec.plays + 1] = { ch = ch, path = path } end
  music.stop = function(ch) rec.stops[#rec.stops + 1] = ch end
  local ok, err = pcall(fn, rec)
  music.play, music.stop = orig_play, orig_stop
  if not ok then error(err, 2) end
  return rec
end

-- Fresh channel table per case (state.music persists across the suite).
local function reset() state.music = {} end

test("channel_play routes to music.play with the full soundpack path and remembers the track", function()
  reset()
  local rec = capture(function() T.music_channel_play("music", "soundtrack/dungeon") end)
  expect(#rec.plays):eq(1)
  expect(rec.plays[1].ch):eq("music")
  expect(rec.plays[1].path):eq(T.SOUNDPACK .. "soundtrack/dungeon.ogg")   -- SOUNDPACK + track + .ogg
  expect(state.music.music):eq("soundtrack/dungeon")                     -- remembered for the HUD mood
end)

test("distinct channels are tracked independently", function()
  reset()
  capture(function()
    T.music_channel_play("music", "soundtrack/town")
    T.music_channel_play("terrain", "weather/rain")
  end)
  expect(state.music.music):eq("soundtrack/town")
  expect(state.music.terrain):eq("weather/rain")
end)

test("channel_stop routes to music.stop and clears that channel's track", function()
  reset()
  local rec = capture(function()
    T.music_channel_play("terrain", "weather/rain")
    T.music_channel_stop("terrain")
  end)
  expect(#rec.stops):eq(1)
  expect(rec.stops[1]):eq("terrain")
  expect(state.music.terrain):eq(nil)
end)

-- Parity guard for the deliberate NON-reactive choice: a repeated channel_play with the SAME track
-- re-issues music.play every time (no distinctUntilChanged dedupe). A stream that suppressed the repeat
-- would break this — it documents why the router stays a plain trigger->function router.
test("a repeated same-track channel_play re-issues music.play (no dedupe)", function()
  reset()
  local rec = capture(function()
    T.music_channel_play("music", "soundtrack/boss")
    T.music_channel_play("music", "soundtrack/boss")
  end)
  expect(#rec.plays):eq(2)                                   -- both fire; the second is NOT suppressed
  expect(rec.plays[2].path):eq(T.SOUNDPACK .. "soundtrack/boss.ogg")
end)

-- ---- kxwt_midi live performances (Audio.lua midi_event router) -----------------------------------
-- The trigger REGEX runs in Swift, so we drive the plain router midi_event() the trigger body calls and
-- assert the OBSERVABLE output: the raw hex-byte payload handed to music.midi (Swift parses + synthesises
-- it). The router forwards the payload verbatim — MIDI byte interpretation is the synth's job, not Lua's.
local function capture_midi(fn)
  local rec, orig = {}, music.midi
  music.midi = function(payload) rec[#rec + 1] = payload end
  local ok, err = pcall(fn, rec)
  music.midi = orig
  if not ok then error(err, 2) end
  return rec
end

test("midi_event forwards the raw MIDI-byte payload verbatim to music.midi", function()
  local rec = capture_midi(function()
    T.midi_event("C0 49")        -- Program Change (Flute)
    T.midi_event("90 4d 32")     -- Note On
    T.midi_event("80 4d 00")     -- Note Off
    T.midi_event("B0 7B 00")     -- All Notes Off
  end)
  expect(#rec):eq(4)
  expect(rec[1]):eq("C0 49")
  expect(rec[2]):eq("90 4d 32")
  expect(rec[3]):eq("80 4d 00")
  expect(rec[4]):eq("B0 7B 00")   -- forwarded byte-for-byte; no parsing/dedupe in the Lua layer
end)
