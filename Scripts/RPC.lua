-- AlterAeon 1.105 protobuf RPC client — reimplements the Swift RPCConnection/RPCFramer/LineFramer
-- entirely in hot-reloadable Lua, on top of the generic net_connect/net_send/on_net/on_net_connect/
-- on_net_disconnect hooks and the embedded `pb` (lua-protobuf) module. AlterAeon 1.105 is single-socket:
-- the whole game (text, telemetry, music, commands) rides this ONE TLS connection to
-- www.alteraeon.com:3103 — see AUTH_WIRE.md/FRAMING.md (tools/finetune-adjacent scratch docs) for the
-- reverse-engineered wire spec this ports byte-for-byte.
--
-- Layering (bottom to top), each independently testable via `_RPC_TEST`:
--   1. CRC-32/ISO-HDLC (pure Lua, table-based) — needed to compute OUTBOUND frame checksums.
--   2. Line framer — 10-byte header [size u32 LE][payload_crc32 u32 LE][hdr_checksum u16 LE] + payload.
--      INBOUND skips CRC verification (TLS already guarantees integrity); only frames+parses size.
--   3. Proto (block) framer — one logical RPC block = TWO consecutive line frames: a
--      xirr_proto_framer_frameinfo frame (routing key), then the payload data frame.
--   4. The connect/handshake state machine (REQUEST/ACK text preamble, then version_info, then
--      routed binary blocks) + routing table (parity with the old Swift RPCFramer.decode/handle).
--   5. `dclient_rpc` control table (start/stop/connected) + `on_send` composition (outbound user
--      input rides the RPC as a text_block, suppressing the legacy telnet send).

state = state or {}
_AA_TEST = _AA_TEST or {}
_RPC_TEST = _RPC_TEST or {}

-- Load the protobuf schema so pb.encode/decode know our message types. This is a FileDescriptorSet
-- compiled from Sources/MudClient/RPC/proto/*.proto (regenerate with `just regen-rpc-descriptor`).
-- WITHOUT this, every pb.decode fails and frameinfos come back empty → all blocks route as "unknown".
-- Load ONCE: `pb`'s registered types are C-side state that survives a Lua #reload, so re-reading the
-- file every reload is pointless (guarded by a global flag).
if not __rpc_pb_loaded then
  local f = io.open("Scripts/rpc_descriptor.pb", "rb")
  if not f then
    echo("[rpc] ERROR: Scripts/rpc_descriptor.pb not found — protobuf decode will fail")
  else
    local data = f:read("*a"); f:close()
    local ok, err = pcall(pb.load, data)
    if not ok then echo("[rpc] ERROR: pb.load failed: " .. tostring(err)) else __rpc_pb_loaded = true end
  end
end

-- AlterAeon soundpack root (music/sound filenames from the RPC are relative to this, e.g.
-- "ogg_v1/soundtrack/track_area_dragontooth" → SOUNDPACK .. name .. ".ogg").
local SOUNDPACK = (os.getenv("HOME") or "") .. "/Library/AlterAeon/soundpack/"

-- AlterAeon `~`-tilde color codes → ANSI (game `help colors`). ~R/~Y/~G/~C/~B/~P/~W set a color, ~O
-- resets, ~H = bright/highlight, ~F = faint/dim, ~U reverts to the PREVIOUS color, ~~ = a literal ~.
-- Used to render chat (channel_send_data) which arrives with these codes inline instead of ANSI.
local TILDE = { O = "\27[0m", R = "\27[31m", Y = "\27[33m", G = "\27[32m", C = "\27[36m",
                B = "\27[34m", P = "\27[35m", W = "\27[37m", H = "\27[1m", F = "\27[2m" }
local function tilde_to_ansi(s)
  local out, i, n, prev, cur = {}, 1, #s, "\27[0m", "\27[0m"
  while i <= n do
    local c = s:sub(i, i)
    if c == "~" and i < n then
      local x = s:sub(i + 1, i + 1)
      if x == "~" then out[#out + 1] = "~"
      elseif x == "U" then out[#out + 1] = prev; cur = prev
      elseif TILDE[x] then
        if x:match("[ORYGCBPW]") then prev = cur; cur = TILDE[x] end   -- track color for ~U (not H/F)
        out[#out + 1] = TILDE[x]
      else out[#out + 1] = "~" .. x end                                -- unknown ~X → literal
      i = i + 2
    else out[#out + 1] = c; i = i + 1 end
  end
  return table.concat(out) .. "\27[0m"
end

-- RPC message debugger (`#rpc ...`). Globals so they persist across #reload and the user drives them:
--   _RPC_DEBUG   — master on/off (default OFF — the protocol is mapped now; turn on with `#rpc debug on`
--                  to inspect messages). When on, EVERY decoded message (except text_block, which is the
--                  rendered game text) is echoed as a one-line summary — UNLESS its name is ignored.
--   _RPC_IGNORE  — a set of name substrings the user has muted (`#rpc ignore hpbar`); matched against the
--                  message's proto_name AND rpc_service_name. The user tracks what's noise, not the code.
_RPC_DEBUG = _RPC_DEBUG == nil and false or _RPC_DEBUG
_RPC_IGNORE = _RPC_IGNORE or {}
-- Normalize a name for matching: lowercase + drop underscores, so the user can `#rpc ignore` by whatever
-- they SEE — the pretty camelCase summary label ("audioPlayout", "enemyHP") OR the raw snake proto name
-- ("audio_playout_data", "enemy_hp_data"). Without this, "audioPlayout" never matched "audio_playout_data".
local function rpc_norm(s) return (s or ""):lower():gsub("_", "") end
local function rpc_ignored(proto_name, service_name)
  local pn, sn = rpc_norm(proto_name), rpc_norm(service_name)
  for pat in pairs(_RPC_IGNORE) do
    local p = rpc_norm(pat)
    if p ~= "" and (pn:find(p, 1, true) or sn:find(p, 1, true)) then return true end
  end
  return false
end

--------------------------------------------------------------------------------
-- 1. CRC-32/ISO-HDLC (poly 0xEDB88320 reflected, init/xorout 0xFFFFFFFF)
--------------------------------------------------------------------------------

local CRC32_TABLE = {}
for i = 0, 255 do
  local c = i
  for _ = 1, 8 do
    if c & 1 ~= 0 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
  end
  CRC32_TABLE[i] = c
end

local function crc32(bytes)
  local crc = 0xFFFFFFFF
  for i = 1, #bytes do
    local b = bytes:byte(i)
    crc = CRC32_TABLE[(crc ~ b) & 0xFF] ~ (crc >> 8)
  end
  return (crc ~ 0xFFFFFFFF) & 0xFFFFFFFF
end

--------------------------------------------------------------------------------
-- 2. Line framer
--------------------------------------------------------------------------------

local HEADER_SIZE = 10
local MAX_PAYLOAD_SIZE = 4000000

local function encode_line(payload)
  local header8 = string.pack("<I4I4", #payload, crc32(payload))
  local hdr_checksum = crc32(header8) & 0xFFFF
  return header8 .. string.pack("<I2", hdr_checksum) .. payload
end

-- Returns a stateful `feed(bytes) -> {payload, payload, ...}` closure that buffers partial frames
-- across calls (a frame — or several — may straddle two on_net chunks). INBOUND skips CRC
-- verification (TLS already guarantees integrity): only the size is trusted, to reassemble frames.
local function new_line_reader()
  local buf = ""
  return function(bytes)
    buf = buf .. bytes
    local payloads = {}
    local pos, n = 1, #buf
    -- Walk by index (string.unpack/sub take a start offset) instead of re-slicing `buf` every frame —
    -- a per-frame `buf:sub(total+1)` is O(n) each, so a burst of many frames in one chunk is O(n²) and
    -- can wedge the UI. Slice out only the payloads, then drop the consumed prefix once at the end.
    while n - pos + 1 >= HEADER_SIZE do
      local size = string.unpack("<I4", buf, pos)
      if size > MAX_PAYLOAD_SIZE then pos = n + 1; break end
      local total = HEADER_SIZE + size
      if n - pos + 1 < total then break end
      payloads[#payloads + 1] = buf:sub(pos + HEADER_SIZE, pos + total - 1)
      pos = pos + total
    end
    buf = pos > n and "" or buf:sub(pos)
    return payloads
  end
end

--------------------------------------------------------------------------------
-- 3. Proto (block) framer — two line frames per logical block: frameinfo, then data.
--------------------------------------------------------------------------------

local FRAMEINFO_TYPE = "xirr_rpc.xirr_proto_framer_frameinfo"

local function encode_frameinfo(fi) return pb.encode(FRAMEINFO_TYPE, fi) end

local function encode_block(frameinfo, payload)
  return encode_line(encode_frameinfo(frameinfo)) .. encode_line(payload)
end

-- Returns a stateful `feed(bytes) -> { {frameinfo=..., payload=...}, ... }` closure: reassembles the
-- frameinfo line frame, then pairs it with the following data line frame into one logical block.
local function new_block_reader()
  local line_reader = new_line_reader()
  local pending_fi = nil
  return function(bytes)
    local blocks = {}
    for _, payload in ipairs(line_reader(bytes)) do
      if pending_fi == nil then
        local ok, fi = pcall(pb.decode, FRAMEINFO_TYPE, payload)
        pending_fi = ok and fi or {}
      else
        blocks[#blocks + 1] = { frameinfo = pending_fi, payload = payload }
        pending_fi = nil
      end
    end
    return blocks
  end
end

--------------------------------------------------------------------------------
-- 4. Routing table (parity with the old Swift RPCFramer.decode) + per-type handling
--------------------------------------------------------------------------------

-- Tried in order (matching the Swift routing): exact full proto_name match, then suffix match on
-- the message part of proto_name (after the last "."), then service-key match on proto_name, then
-- service-key match on rpc_service_name.
local ROUTES = {
  { full = "dclient_rpc.hpbar_data",                service = "hpbar" },
  { full = "dclient_rpc.enemy_hp_data",              service = "enemyhp" },
  { full = "dclient_rpc.sky_and_time",               service = "skystate" },
  { full = "dclient_rpc.exp_to_level",               service = "xp2l" },
  { full = "dclient_rpc.icon_bar_data",               service = "iconbar" },
  { full = "dclient_rpc.room_terrain_metadata",       service = "room_terrain_metadata" },
  { full = "xirr_soundpack_rpc.music_playout_data",   service = "music" },
  { full = "dclient_rpc.popup_window",                service = "popup_window_create" },
  { full = "dclient_rpc.button_configuration",        service = "fkey" },
  { full = "xirr_client_rpc.generic_kv_event",        service = "kvp" },
  { full = "xirr_client_rpc.channel_send_data",       service = "channelsend" },
  { full = "xirr_client_rpc.text_block",              service = "text_block" },
  { full = "xirr_client_rpc.audio_playout_data",      service = "audio_playout_data" },
  { full = "xirr_server_rpc.keepalive_info",          service = "keepalive" },
}

local function find_route(proto_name, service_name)
  proto_name = proto_name or ""
  service_name = service_name or ""
  local message_part = proto_name:match("([^.]+)$") or proto_name
  for _, r in ipairs(ROUTES) do if r.full == proto_name then return r end end
  for _, r in ipairs(ROUTES) do
    if (r.full:match("([^.]+)$")) == message_part then return r end
  end
  for _, r in ipairs(ROUTES) do if r.service == proto_name then return r end end
  for _, r in ipairs(ROUTES) do if r.service == service_name then return r end end
  return nil
end

-- One-line "not yet handled" summaries — kept VISIBLE per the design (parity with the Swift `log()`
-- calls); the legacy text-tag telemetry riding inside text_block already drives the widgets, so these
-- structured messages are informational until a widget is migrated onto them directly.
local SUMMARIZERS = {
  ["dclient_rpc.hpbar_data"] = function(m)
    return string.format("[rpc] hpbar f1=%s f2=%s f3=%s f4=%s f5=%s f6=%s", tostring(m.f1), tostring(m.f2), tostring(m.f3), tostring(m.f4), tostring(m.f5), tostring(m.f6))
  end,
  ["dclient_rpc.enemy_hp_data"] = function(m)
    return string.format("[rpc] enemyHP name='%s' hp=%s", tostring(m.enemy_name), tostring(m.f2))
  end,
  ["dclient_rpc.sky_and_time"] = function(m)
    return string.format("[rpc] sky f1=%s f2=%s f3=%s f4=%s f5=%s '%s'", tostring(m.f1), tostring(m.f2), tostring(m.f3), tostring(m.f4), tostring(m.f5), tostring(m.printed_time_of_day_string))
  end,
  ["dclient_rpc.exp_to_level"] = function(m)
    return string.format("[rpc] expToLevel values=%s", table.concat(m.f1 or {}, ","))
  end,
  ["dclient_rpc.icon_bar_data"] = function(m)
    return string.format("[rpc] iconBar f1=%s f2=%s f3=%s f4=%s f5=%s f6=%s", tostring(m.f1), tostring(m.f2), tostring(m.f3), tostring(m.f4), tostring(m.f5), tostring(m.f6))
  end,
  ["dclient_rpc.room_terrain_metadata"] = function(m)
    return string.format("[rpc] roomTerrain f1=%d f2=%d f3=%d f4=%d", #(m.f1 or {}), #(m.f2 or {}), #(m.f3 or {}), #(m.f4 or {}))
  end,
  ["dclient_rpc.popup_window"] = function(m)
    return string.format("[rpc] popupWindow name='%s' display='%s' cmd='%s'", tostring(m.name), tostring(m.display_name), tostring(m.command))
  end,
  ["dclient_rpc.button_configuration"] = function(m)
    return string.format("[rpc] buttonConfig f1=%s display='%s' action='%s'", tostring(m.f1), tostring(m.display_string), tostring(m.action_string))
  end,
  ["xirr_client_rpc.generic_kv_event"] = function(m)
    return string.format("[rpc] genericKV key='%s' value='%s' f3=%s", tostring(m.key), tostring(m.kvalue), tostring(m.f3))
  end,
  ["xirr_client_rpc.channel_send_data"] = function(m)
    return string.format("[rpc] channelSend channel='%s' message='%s'", tostring(m.channel_name), tostring(m.sent_message))
  end,
  ["xirr_client_rpc.audio_playout_data"] = function(m)
    return string.format("[rpc] audioPlayout file='%s'", tostring(m.short_clip_filename))
  end,
  ["xirr_soundpack_rpc.music_playout_data"] = function(m)
    return string.format("[rpc] music op=%s channel='%s' file='%s'", tostring(m.op), tostring(m.channel_name), tostring(m.filename))
  end,
}

-- Answer the server's rpc/ping or it drops the connection (~15s). Reply is a keepalive_info
-- transaction RESPONSE: echo the request's proto_name + f30 (transaction id, the correlation key),
-- set frameinfo.f20 = 3 (RESPONSE).
local function send_pong(req_frameinfo, req_msg)
  local resp_frameinfo = { proto_name = req_frameinfo.proto_name, f20 = 3, f30 = req_frameinfo.f30 }
  local payload = pb.encode("xirr_server_rpc.keepalive_info", { f1 = req_msg.f1 or 0 })
  net_send(encode_block(resp_frameinfo, payload))
end

-- Dispatch one decoded block. `text_block` is the key line that keeps the game working — its bytes
-- are the raw telnet-style game stream (IAC, `;s<tag>;` dclient tags, MSP markers all inline), fed
-- through the SAME inbound pipeline the legacy telnet path used, driving every existing text-tag
-- parser → widgets (incl. kxwq_group).
local function route(frameinfo, payload)
  local proto_name = frameinfo.proto_name or ""
  local service_name = frameinfo.rpc_service_name or ""
  local r = find_route(proto_name, service_name)
  local m = nil
  if r then
    local ok, dec = pcall(pb.decode, r.full, payload)
    if ok then m = dec end
    -- ACTIONS for the types we handle. text_block is the rendered game text: feed it and RETURN (never
    -- echoed as a debug line). Everything else does its action then falls through to the debug echo.
    if r.full == "xirr_client_rpc.text_block" then
      feed_server(m and m.text or "")   -- feed_server flushes the tail per call (each text_block is complete)
      return
    elseif r.full == "xirr_server_rpc.keepalive_info" then
      send_pong(frameinfo, m or {})     -- answer rpc/ping or the server drops us (~15s)
    elseif r.full == "xirr_soundpack_rpc.music_playout_data" and m then
      -- In practice the server just re-sends the current area soundtrack (same filename, op=10) over and
      -- over — there's no distinct START. So: any op that NAMES a track → play it, but DEDUP on filename
      -- (per channel, in a global so it survives #reload) so we don't restart it 83×. Only explicit STOP
      -- (5 HARD_STOP / 9 SOFT_STOP) or DELETE (2) actually stops. Suspend/unsuspend are treated as "play".
      local ch = (m.channel_name and m.channel_name ~= "") and m.channel_name or "music"
      local op = m.op or 0
      __rpc_music = __rpc_music or {}
      if op == 5 or op == 9 or op == 2 then
        if music and music.stop then music.stop(ch) end
        __rpc_music[ch] = nil
      elseif m.filename and m.filename ~= "" and __rpc_music[ch] ~= m.filename then
        __rpc_music[ch] = m.filename
        if music and music.play then music.play(ch, SOUNDPACK .. m.filename .. ".ogg") end
      end
    elseif r.full == "xirr_client_rpc.audio_playout_data" and m then
      if m.short_clip_filename and m.short_clip_filename ~= "" and sound_once then
        sound_once(SOUNDPACK .. m.short_clip_filename .. ".ogg")
      end
    elseif r.full == "dclient_rpc.hpbar_data" and m then
      -- f1..f6 = hp/maxhp, sp/maxsp, mv/maxmv (BEST-GUESS; swap here if crossed — hot-reloadable).
      state.hp, state.maxhp = m.f1, m.f2
      state.mana, state.maxmana = m.f3, m.f4
      state.stam, state.maxstam = m.f5, m.f6
      if __recovery_on_vitals then __recovery_on_vitals() end
      if on_update then on_update() end
    elseif r.full == "dclient_rpc.sky_and_time" and m then
      -- Time/weather → HUD. printed_time_of_day_string ("2:10 pm") is the clock the time widget shows.
      -- (sky_and_time isn't a ;s tag over RPC, so DClientProbe's skystate handler never fires — wire here.)
      if m.printed_time_of_day_string and m.printed_time_of_day_string ~= "" then
        state.clock = m.printed_time_of_day_string
      end
      -- Weather/sky flags → HUD weather block (outdoors/sky_visible/overcast → moon/sun/cloud icons).
      -- BEST-GUESS from the fields (they vary by location at the same time): f2 tracks sky-visible/outdoors,
      -- f1 an overcast-ish flag. f5 = minutes-since-midnight. VERIFY LIVE and swap if the icons are wrong.
      state.outdoors    = (m.f2 == 1)
      state.sky_visible = (m.f2 == 1)
      state.overcast    = (m.f1 == 1)
      if on_update then on_update() end
    elseif r.full == "xirr_client_rpc.channel_send_data" and m then
      -- A chat-channel line (gossip/tell/etc). It arrives with AlterAeon ~-tilde color codes inline; parse
      -- them to ANSI and just echo it as game content. RETURN so it isn't also shown as an [rpc] debug line.
      if m.sent_message and #m.sent_message > 0 then echo(tilde_to_ansi(m.sent_message)) end
      return
    elseif r.full == "dclient_rpc.enemy_hp_data" and m then
      -- f2 = enemy HP as a 0-100 percentage. 0% is NEAR-DEATH, NOT dead — VERIFIED in the raw log the enemy
      -- streams "…5, 4, 0, 0…" and keeps fighting to the real end. And enemy_hp_data CAN'T tell 0% from dead
      -- anyway (proto3 decodes an absent f2 to 0, same as a real 0% bar). So enemy_hp_data only STARTS/REFRESHES
      -- the fight — a NAMED enemy (any HP, 0 included) is active — and it NEVER ends the fight on a low/zero
      -- reading. Ending is left to the AUTHORITATIVE signals that are unambiguous: kxwq_fighting -1 (→
      -- fighting_from_prompt), generic_kv 'ncombat', and the "is DEAD!" line. (Treating 0 as death is what
      -- dropped the fight early and made autofight lose track.) An EMPTY name = no target → clear.
      local name, pct = m.enemy_name, m.f2
      if name and #name > 0 then
        local was_fighting = state.fighting
        state.fighting, state.fight_name, state.fight_pct = true, name, pct or 0
        -- Combat START (transition into fighting): CANCEL any in-progress recovery — resting/sleeping
        -- through a fight is dangerous. kxwt_fighting used to do this (Combat.lua); over RPC enemy_hp_data
        -- is the earliest combat-start signal (fires before/instead of a melee line, incl. ranged/spell
        -- openers). Only on the transition, not every HP tick.
        if not was_fighting and __recovery_cancel then __recovery_cancel("combat started") end
        -- Drive AutoFight: it's normally armed by kxwt_fighting, which is DEAD over RPC. `__autofight_prompt`
        -- is its transport-agnostic combat-signal entry (built for the nomelee prompt fallback) — enemy_hp_data
        -- is our authoritative health bar, so feed every tick (name+pct starts/refreshes the fight; the spell-
        -- landed TEXT triggers still fire through the text_block pipeline, so the rest of the routine works).
        if __autofight_prompt then __autofight_prompt(pct or 0, name) end
      else
        -- EMPTY name = no target → clear the HUD state + AutoFight. (Reached only when there's no enemy
        -- name at all — NOT on a 0% reading, which keeps the fight above.)
        state.fighting, state.fight_name, state.fight_pct = false, nil, nil
        if __autofight_prompt then __autofight_prompt(nil, nil) end
      end
      if on_update then on_update() end
    elseif r.full == "dclient_rpc.exp_to_level" and m then
      -- CONFIRMED against the game's `level` display: f1 is a flat int32 array of PER-CLASS % to next
      -- level, in PER-MILLE (0-1000). Observed 603,944,517,944,724,804 = 60.3/94.4/51.7/94.4/72.4/80.4%,
      -- matching the game's per-class percents. No class names ride this message; HUD.lua's exp widget
      -- shows the class closest to levelling (the max). Stash the raw array as-is.
      state.exp_to_level = m.f1
      if on_update then on_update() end
    elseif r.full == "xirr_client_rpc.generic_kv_event" and m then
      -- A keyed side-channel: `key` names the datum, value rides `kvalue` (string) or `f3` (int), by key.
      --   key='areaname' → kvalue is the current area ("The Town of Dragon Tooth") → area widget.
      --   key='dirs'     → f3 is an EXITS BITMASK (kvalue empty). Bits (CONFIRMED against observed values
      --                    85=N+E+S+W, 69=N+E+W, 640=NW+D): 1=N 2=NE 4=E 8=SE 16=S 32=SW 64=W 128=NW 256=U
      --                    512=D. Decode into the north/east/up/... set the HUD compass + room-name badges
      --                    read (same shape AlterAeon.lua's "[Exits: ]" trigger builds).
      --   other keys (event/colorflash/bclear/…) → fall through to the debug echo, unhandled for now.
      local key = m.key or ""
      if key == "areaname" then
        state.area = m.kvalue or ""
        if on_update then on_update() end
      elseif key == "dirs" and type(m.f3) == "number" then
        -- Two different 'dirs' events share this key: the real EXITS carry the bitmask in f3; a separate
        -- config toggle arrives as kvalue='on'/'off' with NO f3. Only the numeric-f3 form is exits — the
        -- toggle must NOT wipe state.exits to empty (that's what blanked the compass until you `look`ed).
        local bits = m.f3
        local set = {}
        if bits &   1 ~= 0 then set.north     = true end
        if bits &   2 ~= 0 then set.northeast = true end
        if bits &   4 ~= 0 then set.east      = true end
        if bits &   8 ~= 0 then set.southeast = true end
        if bits &  16 ~= 0 then set.south     = true end
        if bits &  32 ~= 0 then set.southwest = true end
        if bits &  64 ~= 0 then set.west      = true end
        if bits & 128 ~= 0 then set.northwest = true end
        if bits & 256 ~= 0 then set.up        = true end
        if bits & 512 ~= 0 then set.down      = true end
        state.exits = set
        if on_update then on_update() end
      elseif key == "ncombat" then
        -- AUTHORITATIVE combat-END signal (fires the instant a fight is fully over — more reliable than
        -- inferring it from a trailing enemy_hp_data hp=nil, which can be dropped/lagged). Clear the fight
        -- so the HUD combat widget stops showing a phantom enemy. (Combat START is enemy_hp_data-driven.)
        state.fighting, state.fight_name, state.fight_pct = false, nil, nil
        -- Also clear the TEXT-inferred engaged state (engaged_until, up to ENGAGE_TTL=10s, + the opponents
        -- table) — exactly what kxwt_fighting -1 used to do. Without this engaged()/in_combat() lingers for
        -- ~10s after the last mob dies (the "engaged target takes 5-8s to clear" lag), which also delayed
        -- corpse harvesting (it waits on in_combat()).
        state.engaged_until = nil
        state.opponents = {}
        state.assisted = nil                                          -- fight over → re-arm auto-assist (Combat.lua)
        if __autofight_prompt then __autofight_prompt(nil, nil) end   -- end AutoFight's routine authoritatively
        if on_update then on_update() end
      elseif key == "login" then
        if m.kvalue and m.kvalue ~= "" then state.name = m.kvalue end
        -- NOTE: we deliberately do NOT touch kxwt here. Enabling it over the 1.105 RPC was a disaster — the
        -- kxwt_* tags (group/hp/…) FIGHT the RPC widgets (group roster flickered as the two sources
        -- overwrote each other). Navigation stays on the ;smap; section-3 local map. If kxwt was left on
        -- server-side, disable it manually once with `set kxwt off`. The kxwt_live() gate still stands the
        -- section-3 bridge down IF you ever choose to enable kxwt by hand.
      end
    end
  end
  -- DEBUGGER: echo every message (except text_block, handled above) unless the user muted its name via
  -- `#rpc ignore <name>`. The user decides what's noise; we don't hide "handled" ones automatically.
  -- DECODED, not raw: a custom summarizer if we have one, else the decoded fields pretty-printed.
  if _RPC_DEBUG and not rpc_ignored(proto_name, service_name) then
    local name = proto_name ~= "" and proto_name or service_name
    local s = r and SUMMARIZERS[r.full]
    if s then
      echo(s(m))
    elseif m then
      echo(string.format("[rpc] %s %s", name, __repl_render and __repl_render(m) or "(decoded)"))
    else
      echo(string.format("[rpc] %s [unrouted] (%dB)", name, #payload))
    end
  end
end

--------------------------------------------------------------------------------
-- 5. Connect + handshake state machine
--------------------------------------------------------------------------------

local HOST = "www.alteraeon.com"
local PORT = 3103
local CLIENT_VERSION = "1.105-g64-rc2"
local REQUEST_PROTOCOL = "xirr_proto_rpc_1.0_noauth"

local PHASE_AWAITING_ACK = "awaiting_ack"
local PHASE_BINARY = "binary"

-- Connection state lives in a GLOBAL table so it SURVIVES #reload. The socket is a Swift object that
-- outlives the Lua reload; if we reset phase back to the handshake here, the still-open binary stream
-- would be misread as an ACK line and disconnect us. Keeping phase/ack_buf/block_reader in `__rpc` means
-- a #reload picks up mid-session exactly where it was (block_reader closure + its byte buffer intact).
__rpc = __rpc or { phase = PHASE_AWAITING_ACK, ack_buf = "", block_reader = nil }

-- The install identity to present as version_info.client_uuid — prefer the real AlterAeon client's
-- uuid from its config (so we look like a known install); fall back to a stable DFLT token.
local function default_uuid()
  local path = (os.getenv("HOME") or "") .. "/Library/AlterAeon/alter_aeon.cfg"
  local f = io.open(path, "r")
  if f then
    local text = f:read("*a")
    f:close()
    local uuid = text and text:match("<uuid>([^<]+)</uuid>")
    if uuid and #uuid > 0 then return uuid end
  end
  return "DFLT000000000000000000000000"
end

local function send_version_info()
  local frameinfo = { proto_name = "xirr_client_rpc.version_info", rpc_service_name = "versioninfo", f20 = 1 }
  local payload = pb.encode("xirr_client_rpc.version_info", {
    client_version = CLIENT_VERSION, client_uuid = default_uuid(), client_protocol = "" })
  net_send(encode_block(frameinfo, payload))
end

function on_net_connect()
  __rpc.phase = PHASE_AWAITING_ACK
  __rpc.ack_buf = ""
  __rpc.block_reader = new_block_reader()
  net_send("REQUEST " .. REQUEST_PROTOCOL .. "\n")
end

function on_net_disconnect(reason)
  __rpc.phase = PHASE_AWAITING_ACK
  __rpc.ack_buf = ""
  echo("[rpc] disconnected: " .. tostring(reason))
end

function on_net(data)
  local payload = data
  if __rpc.phase == PHASE_AWAITING_ACK then
    __rpc.ack_buf = __rpc.ack_buf .. data
    local nl = __rpc.ack_buf:find("\n", 1, true)
    if not nl then return end
    local line = __rpc.ack_buf:sub(1, nl - 1):gsub("%s+$", "")
    local remainder = __rpc.ack_buf:sub(nl + 1)
    __rpc.ack_buf = ""
    if line:upper():match("^ACK") then
      __rpc.phase = PHASE_BINARY
      send_version_info()
      payload = remainder
      if #payload == 0 then return end
    else
      echo("[rpc] handshake rejected: '" .. line .. "'")
      if net_disconnect then net_disconnect() end
      return
    end
  end
  if not __rpc.block_reader then __rpc.block_reader = new_block_reader() end
  for _, block in ipairs(__rpc.block_reader(payload)) do
    route(block.frameinfo, block.payload)
  end
end

--------------------------------------------------------------------------------
-- Outbound: user input rides the RPC as a text_block (suppressing the legacy telnet send). Compose
-- with any pre-existing on_send (none found in Scripts/*.lua at the time of writing — grepped clean —
-- but chain defensively so a later script's on_send still runs).
--------------------------------------------------------------------------------

local prior_on_send = on_send

function on_send(cmd)
  if __rpc.phase == PHASE_BINARY and net_is_connected and net_is_connected() then
    local frameinfo = { proto_name = "xirr_client_rpc.text_block", rpc_service_name = "text_block", f20 = 1 }
    local payload = pb.encode("xirr_client_rpc.text_block", { text = cmd .. "\n" })
    net_send(encode_block(frameinfo, payload))
    return false
  end
  if prior_on_send then return prior_on_send(cmd) end
  return nil
end

--------------------------------------------------------------------------------
-- Control surface
--------------------------------------------------------------------------------

dclient_rpc = dclient_rpc or {}

function dclient_rpc.start()
  if net_is_connected and net_is_connected() then return end
  net_connect(HOST, PORT, { tls = true })
end
doc(dclient_rpc.start, { name = "dclient_rpc.start", sig = "dclient_rpc.start()", group = "connection",
  text = "Open the AlterAeon 1.105 protobuf RPC connection (www.alteraeon.com:3103, TLS) — the whole game rides this one socket. No-op if already connected." })

function dclient_rpc.stop()
  if net_disconnect then net_disconnect() end
end
doc(dclient_rpc.stop, { name = "dclient_rpc.stop", sig = "dclient_rpc.stop()", group = "connection",
  text = "Close the RPC connection opened by dclient_rpc.start()." })

function dclient_rpc.connected()
  return __rpc.phase == PHASE_BINARY and (net_is_connected and net_is_connected() or false)
end
doc(dclient_rpc.connected, { name = "dclient_rpc.connected", sig = "dclient_rpc.connected() -> bool", group = "connection",
  text = "Whether the RPC handshake completed (past the REQUEST/ACK text preamble, into the binary protobuf phase)." })

-- `#rpc ...` message-debugger command. Callable global, so the host's `#word rest` → `word("rest")`
-- rewrite turns `#rpc ignore hpbar` into `rpc("ignore hpbar")`.
rpc = setmetatable(rpc or {}, { __call = function(_, args)
  local cmd, rest = (args or ""):match("^(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()
  if cmd == "debug" then
    if rest ~= "" then _RPC_DEBUG = (rest:lower() ~= "off") end
    echo("[rpc] debug " .. (_RPC_DEBUG and "on" or "off"))
  elseif cmd == "ignore" and rest ~= "" then
    _RPC_IGNORE[rest] = true; echo("[rpc] ignoring '" .. rest .. "'")
  elseif cmd == "show" and rest ~= "" then
    _RPC_IGNORE[rest] = nil; echo("[rpc] showing '" .. rest .. "'")
  elseif cmd == "list" then
    local ign = {}; for k in pairs(_RPC_IGNORE) do ign[#ign + 1] = k end
    table.sort(ign)
    echo("[rpc] debug=" .. (_RPC_DEBUG and "on" or "off") .. "  ignored: " .. (#ign > 0 and table.concat(ign, ", ") or "(none)"))
  else
    echo("[rpc] usage: rpc debug on|off · rpc ignore <name> · rpc show <name> · rpc list")
  end
end })
doc(rpc, { name = "rpc", sig = "rpc('debug on|off' | 'ignore <name>' | 'show <name>' | 'list')", group = "connection",
  text = "RPC message debugger. `#rpc debug on|off` toggles echoing every decoded RPC message (except game text). `#rpc ignore <name>`/`#rpc show <name>` mute/unmute a message by a substring of its protobuf name or service key (e.g. `#rpc ignore hpbar`). `#rpc list` shows the current state." })

-- Auto-connect on load. Guarded so #reload (re-runs this file in the LIVE state) never redials an open
-- session. If the socket IS already up (a #reload mid-session), we're past the handshake — force binary
-- phase so on_net decodes frames instead of misreading them as an ACK line (keep the persisted reader +
-- its byte buffer so we don't desync).
if net_connect and not (net_is_connected and net_is_connected()) then
  dclient_rpc.start()
elseif net_is_connected and net_is_connected() then
  -- #reload while live: force binary phase (so on_net decodes frames, not misreads them as an ACK line)
  -- and RE-CREATE the block reader so any framer/reader CODE changes actually take effect. (Persisting the
  -- old closure would freeze its code at the version that first created it — that's why stale debug/logic
  -- lingered after edits.) A fresh reader starts at a frame boundary; on an idle #reload there's no partial
  -- frame buffered, so nothing desyncs.
  __rpc.phase = PHASE_BINARY
  __rpc.block_reader = new_block_reader()
end

--------------------------------------------------------------------------------
-- Test seam — exposes the pure logic (no live socket needed) for Scripts/tests/rpc_spec.lua.
--------------------------------------------------------------------------------

_RPC_TEST.crc32 = crc32
_RPC_TEST.encode_line = encode_line
_RPC_TEST.new_line_reader = new_line_reader
_RPC_TEST.encode_frameinfo = encode_frameinfo
_RPC_TEST.encode_block = encode_block
_RPC_TEST.new_block_reader = new_block_reader
_RPC_TEST.find_route = find_route
_RPC_TEST.route = route
_RPC_TEST.send_pong = send_pong
_RPC_TEST.default_uuid = default_uuid
_RPC_TEST.FRAMEINFO_TYPE = FRAMEINFO_TYPE
