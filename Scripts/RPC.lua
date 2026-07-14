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
do
  local f = io.open("Scripts/rpc_descriptor.pb", "rb")
  if not f then
    echo("[rpc] ERROR: Scripts/rpc_descriptor.pb not found — protobuf decode will fail")
  else
    local data = f:read("*a"); f:close()
    local ok, err = pcall(pb.load, data)
    if not ok then echo("[rpc] ERROR: pb.load failed: " .. tostring(err)) end
  end
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
        if _RPC_DEBUG then
          local hex = payload:sub(1, 48):gsub(".", function(c) return string.format("%02x ", c:byte()) end)
          echo(string.format("[rpc dbg] frameinfo %dB ok=%s proto=%s svc=%s | %s",
            #payload, tostring(ok), tostring(ok and fi and fi.proto_name), tostring(ok and fi and fi.rpc_service_name), hex))
        end
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
  if not r then
    if _RPC_DEBUG then echo(string.format("[rpc] unknown proto=%s service=%s bytes=%d", proto_name, service_name, #payload)) end
    return
  end
  if r.full == "xirr_client_rpc.text_block" then
    local m = pb.decode(r.full, payload)
    feed_server(m.text or "")
    return
  end
  if r.full == "xirr_server_rpc.keepalive_info" then
    local m = pb.decode(r.full, payload)
    send_pong(frameinfo, m)
    return
  end
  -- Not-yet-handled telemetry (hpbar/enemy/sky/icons/buttons/kv/...): SILENT by default. Echoing every
  -- one floods the terminal and locks the UI (the server streams these continuously). Flip _RPC_DEBUG on
  -- and #reload to inspect; as we wire a type into a widget, add an explicit case above.
  if _RPC_DEBUG then
    local m = pb.decode(r.full, payload)
    local summarize = SUMMARIZERS[r.full]
    echo(summarize and summarize(m) or string.format("[rpc] %s: %s", r.full, tostring(m)))
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

local phase = PHASE_AWAITING_ACK
local ack_buf = ""
local block_reader = nil

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
  phase = PHASE_AWAITING_ACK
  ack_buf = ""
  block_reader = new_block_reader()
  net_send("REQUEST " .. REQUEST_PROTOCOL .. "\n")
end

function on_net_disconnect(reason)
  phase = PHASE_AWAITING_ACK
  ack_buf = ""
  echo("[rpc] disconnected: " .. tostring(reason))
end

function on_net(data)
  local payload = data
  if phase == PHASE_AWAITING_ACK then
    ack_buf = ack_buf .. data
    local nl = ack_buf:find("\n", 1, true)
    if not nl then return end
    local line = ack_buf:sub(1, nl - 1):gsub("%s+$", "")
    local remainder = ack_buf:sub(nl + 1)
    ack_buf = ""
    if line:upper():match("^ACK") then
      phase = PHASE_BINARY
      send_version_info()
      payload = remainder
      if #payload == 0 then return end
    else
      echo("[rpc] handshake rejected: '" .. line .. "'")
      if net_disconnect then net_disconnect() end
      return
    end
  end
  for _, block in ipairs(block_reader(payload)) do
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
  if phase == PHASE_BINARY and net_is_connected and net_is_connected() then
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
  return phase == PHASE_BINARY and (net_is_connected and net_is_connected() or false)
end
doc(dclient_rpc.connected, { name = "dclient_rpc.connected", sig = "dclient_rpc.connected() -> bool", group = "connection",
  text = "Whether the RPC handshake completed (past the REQUEST/ACK text preamble, into the binary protobuf phase)." })

-- Auto-connect on load, guarded so #reload (which re-runs this file in the LIVE state) never redials
-- an already-open session.
if net_connect and not (net_is_connected and net_is_connected()) then dclient_rpc.start() end

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
