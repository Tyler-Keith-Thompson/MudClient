# `kxwt_midi` — live MIDI performances over the wire

AlterAeon streams **live musical performances** (bard/flute/drum/etc. playing) to the client as
out-of-band `kxwt_midi` protocol lines carrying **raw MIDI events**. This is separate from
`kxwt_music` (which names pre-authored soundtrack/terrain tracks the client loops from local files —
see [[dclient-protocol-decompiled]] and `MusicService.swift`). `kxwt_midi` is the player *performing
in real time*; there is no track name, just a stream of note events you feed to a synth as they arrive.

**Status: captured, not yet implemented.** We currently gag all `^kxwt_` lines. This note + the capture
in `captures/` is the reference for adding a MIDI performance player later.

## How it's turned on

```
set midi [on|off]          # per-character server-side toggle
```

`help midi` (keywords `kxwt midi`) — verbatim:

> This command toggles the ability to hear musical performances via MIDI playback through a client.
> The client will receive out of band "kxwt_MIDI" messages that carry raw MIDI data.
>
> Alter Aeon's custom dclient plays MIDI natively. Linux users may need to install a MIDI player like
> FluidSynth as most kernels don't come MIDI enabled. The Windows and MacOS versions support MIDI as well.
>
> FYI there is a hard limit to the number of instruments that can be heard at once.

Note the help text capitalizes `kxwt_MIDI`, but **the wire tag is lowercase `kxwt_midi`** (confirmed in
the capture). When already on, `set midi on` replies `MIDI kxwt is already enabled.`

## Wire format

Each event is its own line, exactly:

```
kxwt_midi <BYTE> <BYTE> ...\r\n
```

where each `<BYTE>` is a two-hex-digit MIDI byte. One line = one MIDI channel-voice message (status byte
+ its data bytes). Like every kxwt line it's out-of-band: multiple `kxwt_midi` lines are batched into a
single GA-terminated packet, interleaved with the human-readable "Asuka continues blowing on ..." prose
and other kxwt lines (`kxwt_prompt`, etc.) in the same packet. `LineAssembler.swift` already reunites a
kxwt line split across a TCP read, so a handler sees whole lines.

### Events observed

| Bytes (hex) | MIDI message | Meaning |
|---|---|---|
| `C0 49` | Program Change, ch 0 | Select instrument — `0x49` = 73 = **Flute** (GM program 74, 0-indexed 73). Sent at the start of every performance *segment* (re-sent after each `B0 7B 00`). |
| `90 nn vv` | Note On, ch 0 | `nn` = key, `vv` = velocity (always `0x32` = 50 here). |
| `80 nn 00` | Note Off, ch 0 | `nn` = key. (Note-off, not the running-status `90 nn 00` form.) |
| `B0 7B 00` | Control Change, ch 0, CC#123 = **All Notes Off** | Punctuates the performance — server flushes held notes, then re-sends the Program Change to start the next phrase. |

All events in the capture are on **MIDI channel 0**. The "hard limit to the number of instruments"
in the help text implies multiple simultaneous performers map to distinct channels/programs — not yet
observed, so channel handling should be general (don't assume ch 0).

**No timing bytes.** There's no delta-time / tempo in the stream — events are meant to be played *as
they arrive*, in real time, gated by packet arrival. So the client is a live synth fed event-by-event,
NOT a `.mid` file it assembles then plays. (Contrast `MidiChannelPlayer` in `MusicService.swift`, which
plays complete `.mid` files via `AVMIDIPlayer`.) A real implementation wants a low-level synth you can
push events to — e.g. `AVAudioUnitSampler` / a `MusicDeviceMIDIEvent`-style path, or AudioToolbox's
`MusicPlayer` fed a live sequence — using the same soundfont plumbing (`MUD_SOUND_FONT`) as the file player.

### Human-readable pairing

The prose lines that ride alongside are the visible surface of the same performance and can be used to
scope start/stop (they are NOT the sound source):

```
Asuka begins performing, blowing into A Beautifully Carved Wooden Flute.   <- performance start (+ C0 program)
Asuka continues blowing on A Beautifully Carved Wooden Flute.              <- ongoing (note on/off batches)
Asuka pauses her performance.                                             <- brief rest
Asuka finishes her performance.                                          <- end (flush all notes off)
```

## Reference capture (this directory)

- `captures/2026-07-12-asuka-flute-performance.raw.b64log` — byte-exact wire capture (base64 per line,
  same format as the ring-buffered `mud_raw.log`; decode before grepping — see [[raw-log-format]]).
  A rich full-session sample: contains `kxwt_` tags MIDI, action, area, exp, fighting, group, id,
  mdeath, midi, music, position, precipitation, prompt, rshort, rvnum, sky, spelldown, spellup, spst,
  terrain, time, walkdir, waypoint.
- `captures/2026-07-12-asuka-flute-performance.midi-events.txt` — the 48 `kxwt_midi` events from that
  capture, decoded to human-readable MIDI (regenerate with the snippet below).

Decode/regenerate:

```python
import base64, re
with open("captures/2026-07-12-asuka-flute-performance.raw.b64log","rb") as f:
    for line in f:
        try: dec = base64.b64decode(line.strip())
        except Exception: continue
        for m in re.finditer(rb'kxwt_midi ([0-9A-Fa-f ]+?)\r', dec):
            print(m.group(1).decode())
```
