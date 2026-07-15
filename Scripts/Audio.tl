-- AlterAeon audio layer — music channels + master/category volume.
--
-- Split out of AlterAeon.lua. The generic Swift host just plays files / sets service levels; the
-- game-specific soundpack path and the master x category volume model live here.

global volume: function(any): any...
global volume_command: function(any): any...

state = state or {}
_AA_TEST = _AA_TEST or {}

-- Music channels (kxwt_music). We only receive track NAMES per channel (e.g. the "music" and
-- "terrain" channels), not audio. We know where the AlterAeon dclient soundpack lives, so we build the
-- full path and hand it to the generic Swift player (which stays game-agnostic — it just plays a file).
-- The track names already carry their subdir (soundtrack/…, weather/…), so SOUNDPACK is the ogg_v1 root.
-- We also remember each channel's track so the HUD can show a "♪" mood indicator. `if music then`
-- guards an un-relaunched binary that lacks the new builtin.
local SOUNDPACK: string = (os.getenv("HOME") or "") .. "/Library/AlterAeon/soundpack/ogg_v1/"
state.music = state.music or {}
-- state.music is read fresh through this cast on every call (never cached in a local) — anything that
-- reassigns state.music wholesale (a spec's reset(), a future migration) must be observed, exactly like
-- the pre-Teal Lua which always indexed through `state.music` directly.
-- Plain router helpers (the trigger bodies call these; unit-tested via _AA_TEST/music_spec). A single
-- consumer, no fan-out/compose/dedupe: `distinctUntilChanged` would SUPPRESS a repeat channel_play that
-- currently re-issues music.play, so this deliberately stays a plain trigger->function router (like
-- AlterAeon/ChatDecode), NOT an rx stream — parity requires the re-issue on every line.
local function music_channel_play(ch: string, tr: string)
  (state.music as {string:string})[ch] = tr
  if music then music.play(ch, SOUNDPACK .. tr .. ".ogg") end
end
local function music_channel_stop(ch: string)
  (state.music as {string:string})[ch] = nil
  if music then music.stop(ch) end
end
trigger([[^kxw[tq]_music channel_play (\S+) (\S+)]], function(_: any, ch: string, tr: string) music_channel_play(ch, tr) end)
trigger([[^kxw[tq]_music channel_stop (\S+)]], function(_: any, ch: string) music_channel_stop(ch) end)

-- Live MIDI performances (kxwt_midi) — a bard/flute playing in REAL TIME, streamed as raw MIDI events
-- (unlike kxwt_music, which just names a pre-authored soundtrack file to loop). Each line is ONE MIDI
-- channel-voice message as space-separated hex bytes ("90 4d 32" = Note On). We strip the kxwt framing
-- and hand the raw MIDI payload to the live synth (music.midi), which plays it as it arrives — there are
-- no timing bytes, events sound the moment they land. `set midi on` server-side turns the stream on.
-- See docs/protocol/kxwt-midi.md. The `if music` guard tolerates an un-relaunched binary lacking it.
local function midi_event(payload: string)
  if music and music.midi then music.midi(payload) end
end
trigger([[^kxw[tq]_midi (.+)]], function(_: any, payload: string) midi_event(payload) end)

-- Flush any held notes when the connection drops so a performance can't hang a note past the socket.
if on_disconnect == nil then
  function on_disconnect(): any if music and music.midi_reset then music.midi_reset() end end
end

-- Audio volume: a MASTER plus three categories — music (layered player), sfx (MSP sound effects), and
-- voice (TTS). The effective level pushed to each host service = round(master% × category%), so
-- `volume('0')` zeroes the master → all three effective 0 → full silence, while `volume('voice 0')`
-- mutes only TTS. Levels persist across reload/reconnect in state.volumes (migrated from the old
-- single state.music_volume). The `if …` guards tolerate an un-relaunched binary lacking a new builtin.
-- music defaults to 35% (deliberately quiet, matching Swift's own default); everything else to 100%.
local VOLUME_DEFAULTS: {string:integer} = { master = 100, music = 35, sfx = 100, voice = 100 }
state.volumes = state.volumes or {}
-- state.volumes is read fresh through this cast on every access (never cached in a local) — a spec's
-- `state.volumes = {...}` reassignment (or a future reset) must be observed, exactly like the pre-Teal
-- Lua which always indexed through `state.volumes` directly.
local function vols(): {string:integer} return state.volumes as {string:integer} end
for k, v in pairs(VOLUME_DEFAULTS) do
  if vols()[k] == nil then vols()[k] = v end
end
-- Migrate the legacy single music level into the new table (once).
if state.music_volume ~= nil then
  vols().music = state.music_volume as integer
  state.music_volume = nil
end

-- Always start a session at 20% master — the level the player sets by hand every game start, so bake it
-- in. Applied on every load/reload (overriding the default/persisted master); the categories keep their
-- own levels. Adjust live any time with volume('N'); a fresh load resets it back to 20.
vols().master = 20

-- Accepted category words (aliases fold onto the three canonical keys). `master` is accepted too so
-- `volume('master 80')` works alongside the bare-number shorthand.
local VOLUME_ALIASES: {string:string} = {
  master = "master", music = "music",
  sfx = "sfx", effects = "sfx", effect = "sfx", msp = "sfx",
  voice = "voice", speech = "voice", tts = "voice", say = "voice",
}

-- Effective 0-100 level for a category = master% × category%, rounded.
local function volume_effective(cat: string): integer
  return math.floor((vols().master / 100) * (vols()[cat] / 100) * 100 + 0.5)
end

-- Recompute all three effective levels and push them to the host services. Returns them for callers/tests.
local function volume_apply(): integer, integer, integer
  local em, es, ev = volume_effective("music"), volume_effective("sfx"), volume_effective("voice")
  if music and music.volume then music.volume(em) end
  if msp_volume then msp_volume(es) end
  if speech_volume then speech_volume(ev) end
  return em, es, ev
end

local function volume_readout()
  echo(string.format("[volume] master %d%%  |  music %d%%->%d%%  sfx %d%%->%d%%  voice %d%%->%d%%",
    vols().master,
    vols().music, volume_effective("music"),
    vols().sfx, volume_effective("sfx"),
    vols().voice, volume_effective("voice")))
  echo("[volume] volume('0-100')=master; volume('music|sfx|voice <0-100>')=category; volume()=this readout")
end

-- First-class documented function (migrated off command("volume", …)); the legacy typed
-- `#volume music 40` still rewrites to volume("music 40") and lands here unchanged.
function volume(args: any): any return volume_command(args) end
doc(volume, { name = "volume", sig = "volume(['<0-100>' | '<music|sfx|voice> <0-100>'])", group = "audio",
  text = "Master + per-category audio volume (0-100). volume('0') mutes EVERYTHING (master); volume('50') sets master; volume('music 40'), volume('sfx 0'), volume('voice 0') set a category (aliases: effects/msp=sfx, speech/tts=voice); volume() prints a readout. Effective = master% x category%.",
  example = "volume('0')  -- silence all; volume('voice 0')  -- mute only TTS" })

function volume_command(args: any): any
  -- Coerce to string first: the typed bridge (`#volume music 40`) always passes a string, but a direct
  -- Lua call can pass a NUMBER — volume(0) — and 0 is truthy, so `(args or "")` kept the number and the
  -- `:match` below indexed a number value. tostring() makes volume(0) and volume('0') behave alike.
  local a: string = tostring(args or ""):match("^%s*(.-)%s*$")
  if a == "" then volume_readout(); return end
  -- bare number => MASTER
  if a:match("^%d+$") then
    vols().master = math.max(0, math.min(100, tonumber(a) as integer))
    volume_apply()
    echo(string.format("[volume] master set to %d%%", vols().master))
    return
  end
  local word = (a:match("^(%S+)") or ""):lower()
  local rest = a:match("^%S+%s+(.*)$") or ""
  local cat = VOLUME_ALIASES[word]
  if not cat then
    echo("[volume] usage: volume('0-100') sets master; volume('music|sfx|voice <0-100>') sets a category")
    return
  end
  local num = rest:match("^(%d+)")
  if not num then volume_readout(); return end
  vols()[cat] = math.max(0, math.min(100, tonumber(num) as integer))
  volume_apply()
  if cat == "master" then
    echo(string.format("[volume] master set to %d%%", vols().master))
  else
    echo(string.format("[volume] %s set to %d%% (effective %d%%)", cat, vols()[cat], volume_effective(cat)))
  end
end

-- Push the persisted levels to the services once at load (so a reload re-applies them).
volume_apply()

_AA_TEST.volume_effective = volume_effective
_AA_TEST.volume_apply = volume_apply
_AA_TEST.volume_command = volume_command
_AA_TEST.VOLUME_DEFAULTS = VOLUME_DEFAULTS
_AA_TEST.music_channel_play = music_channel_play
_AA_TEST.music_channel_stop = music_channel_stop
_AA_TEST.midi_event = midi_event
_AA_TEST.SOUNDPACK = SOUNDPACK
