







state = state or {}
_AA_TEST = _AA_TEST or {}



local music_channel_play
local music_channel_stop
local midi_event




trigger([[^kxw[tq]_music channel_play (\S+) (\S+)]], function(_, ch, tr) music_channel_play(ch, tr) end)
trigger([[^kxw[tq]_music channel_stop (\S+)]], function(_, ch) music_channel_stop(ch) end)
trigger([[^kxw[tq]_midi (.+)]], function(_, payload) midi_event(payload) end)
if on_disconnect == nil then
   function on_disconnect() if music and music.midi_reset then music.midi_reset() end end
end








local SOUNDPACK = (os.getenv("HOME") or "") .. "/Library/AlterAeon/soundpack/ogg_v1/"
state.music = state.music or {}







music_channel_play = function(ch, tr)
   (state.music)[ch] = tr
   if music then music.play(ch, SOUNDPACK .. tr .. ".ogg") end
end
music_channel_stop = function(ch)
   (state.music)[ch] = nil
   if music then music.stop(ch) end
end







midi_event = function(payload)
   if music and music.midi then music.midi(payload) end
end







local VOLUME_DEFAULTS = { master = 100, music = 35, sfx = 100, voice = 100 }
state.volumes = state.volumes or {}



local function vols() return state.volumes end
for k, v in pairs(VOLUME_DEFAULTS) do
   if vols()[k] == nil then vols()[k] = v end
end

if state.music_volume ~= nil then
   vols().music = state.music_volume
   state.music_volume = nil
end




vols().master = 20



local VOLUME_ALIASES = {
   master = "master", music = "music",
   sfx = "sfx", effects = "sfx", effect = "sfx", msp = "sfx",
   voice = "voice", speech = "voice", tts = "voice", say = "voice",
}


local function volume_effective(cat)
   return math.floor((vols().master / 100) * (vols()[cat] / 100) * 100 + 0.5)
end


local function volume_apply()
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



function volume(args) return volume_command(args) end
doc(volume, { name = "volume", sig = "volume(['<0-100>' | '<music|sfx|voice> <0-100>'])", group = "audio",
text = "Master + per-category audio volume (0-100). volume('0') mutes EVERYTHING (master); volume('50') sets master; volume('music 40'), volume('sfx 0'), volume('voice 0') set a category (aliases: effects/msp=sfx, speech/tts=voice); volume() prints a readout. Effective = master% x category%.",
example = "volume('0')  -- silence all; volume('voice 0')  -- mute only TTS", })

function volume_command(args)



   local a = tostring(args or ""):match("^%s*(.-)%s*$")
   if a == "" then volume_readout(); return end

   if a:match("^%d+$") then
      vols().master = math.max(0, math.min(100, tonumber(a)))
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
   vols()[cat] = math.max(0, math.min(100, tonumber(num)))
   volume_apply()
   if cat == "master" then
      echo(string.format("[volume] master set to %d%%", vols().master))
   else
      echo(string.format("[volume] %s set to %d%% (effective %d%%)", cat, vols()[cat], volume_effective(cat)))
   end
end


volume_apply()

_AA_TEST.volume_effective = volume_effective
_AA_TEST.volume_apply = volume_apply
_AA_TEST.volume_command = volume_command
_AA_TEST.VOLUME_DEFAULTS = VOLUME_DEFAULTS
_AA_TEST.music_channel_play = music_channel_play
_AA_TEST.music_channel_stop = music_channel_stop
_AA_TEST.midi_event = midi_event
_AA_TEST.SOUNDPACK = SOUNDPACK
