

















state = state or {}
_AA_TEST = _AA_TEST or {}



_RPC_TEST = _RPC_TEST or {}





local function boot(name) pcall(require, name) end
boot("pb")













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



local SOUNDPACK = (os.getenv("HOME") or "") .. "/Library/AlterAeon/soundpack/"




local TILDE = { O = "\27[0m", R = "\27[31m", Y = "\27[33m", G = "\27[32m", C = "\27[36m",
B = "\27[34m", P = "\27[35m", W = "\27[37m", H = "\27[1m", F = "\27[2m", }
local function tilde_to_ansi(s)
   local out = {}
   local i = 1
   local n = #s
   local prev = "\27[0m"
   local cur = "\27[0m"
   while i <= n do
      local c = s:sub(i, i)
      if c == "~" and i < n then
         local x = s:sub(i + 1, i + 1)
         if x == "~" then out[#out + 1] = "~"
         elseif x == "U" then out[#out + 1] = prev; cur = prev
         elseif TILDE[x] then
            if x:match("[ORYGCBPW]") then prev = cur; cur = TILDE[x] end
            out[#out + 1] = TILDE[x]
         else out[#out + 1] = "~" .. x end
         i = i + 2
      else out[#out + 1] = c; i = i + 1 end
   end
   return table.concat(out) .. "\27[0m"
end











local handle_text_block
local handle_keepalive
local handle_music
local handle_audio
local handle_hpbar
local handle_sky
local handle_channel_send
local handle_enemy_hp
local handle_exp_to_level
local handle_kv_event

local HANDLERS = {
   ["xirr_client_rpc.text_block"] = function(fi, m) return handle_text_block(fi, m) end,
   ["xirr_server_rpc.keepalive_info"] = function(fi, m) return handle_keepalive(fi, m) end,
   ["xirr_soundpack_rpc.music_playout_data"] = function(fi, m) return handle_music(fi, m) end,
   ["xirr_client_rpc.audio_playout_data"] = function(fi, m) return handle_audio(fi, m) end,
   ["dclient_rpc.hpbar_data"] = function(fi, m) return handle_hpbar(fi, m) end,
   ["dclient_rpc.sky_and_time"] = function(fi, m) return handle_sky(fi, m) end,
   ["xirr_client_rpc.channel_send_data"] = function(fi, m) return handle_channel_send(fi, m) end,
   ["dclient_rpc.enemy_hp_data"] = function(fi, m) return handle_enemy_hp(fi, m) end,
   ["dclient_rpc.exp_to_level"] = function(fi, m) return handle_exp_to_level(fi, m) end,
   ["xirr_client_rpc.generic_kv_event"] = function(fi, m) return handle_kv_event(fi, m) end,
}









_RPC_DEBUG = _RPC_DEBUG == nil and false or _RPC_DEBUG
_RPC_IGNORE = _RPC_IGNORE or {}



local function rpc_norm(s) return ((s or ""):lower():gsub("_", "")) end
local function rpc_ignored(proto_name, service_name)
   local pn, sn = rpc_norm(proto_name), rpc_norm(service_name)
   for pat in pairs(_RPC_IGNORE) do
      local p = rpc_norm(pat)
      if p ~= "" and (pn:find(p, 1, true) or sn:find(p, 1, true)) then return true end
   end
   return false
end





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





local HEADER_SIZE = 10
local MAX_PAYLOAD_SIZE = 4000000

local function encode_line(payload)
   local header8 = string.pack("<I4I4", #payload, crc32(payload))
   local hdr_checksum = crc32(header8) & 0xFFFF
   return header8 .. string.pack("<I2", hdr_checksum) .. payload
end




local function new_line_reader()
   local buf = ""
   return function(bytes)
      buf = buf .. bytes
      local payloads = {}
      local pos, n = 1, #buf



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





local FRAMEINFO_TYPE = "xirr_rpc.xirr_proto_framer_frameinfo"

local function encode_frameinfo(fi) return pb.encode(FRAMEINFO_TYPE, fi) end

local function encode_block(frameinfo, payload)
   return encode_line(encode_frameinfo(frameinfo)) .. encode_line(payload)
end








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













local ROUTES = {
   { full = "dclient_rpc.hpbar_data", service = "hpbar" },
   { full = "dclient_rpc.enemy_hp_data", service = "enemyhp" },
   { full = "dclient_rpc.sky_and_time", service = "skystate" },
   { full = "dclient_rpc.exp_to_level", service = "xp2l" },
   { full = "dclient_rpc.icon_bar_data", service = "iconbar" },
   { full = "dclient_rpc.room_terrain_metadata", service = "room_terrain_metadata" },
   { full = "xirr_soundpack_rpc.music_playout_data", service = "music" },
   { full = "dclient_rpc.popup_window", service = "popup_window_create" },
   { full = "dclient_rpc.button_configuration", service = "fkey" },
   { full = "xirr_client_rpc.generic_kv_event", service = "kvp" },
   { full = "xirr_client_rpc.channel_send_data", service = "channelsend" },
   { full = "xirr_client_rpc.text_block", service = "text_block" },
   { full = "xirr_client_rpc.audio_playout_data", service = "audio_playout_data" },
   { full = "xirr_server_rpc.keepalive_info", service = "keepalive" },
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
      return string.format("[rpc] expToLevel values=%s", table.concat((m.f1 or {}), ","))
   end,
   ["dclient_rpc.icon_bar_data"] = function(m)
      return string.format("[rpc] iconBar f1=%s f2=%s f3=%s f4=%s f5=%s f6=%s", tostring(m.f1), tostring(m.f2), tostring(m.f3), tostring(m.f4), tostring(m.f5), tostring(m.f6))
   end,
   ["dclient_rpc.room_terrain_metadata"] = function(m)
      return string.format("[rpc] roomTerrain f1=%d f2=%d f3=%d f4=%d", #((m.f1 or {})), #((m.f2 or {})), #((m.f3 or {})), #((m.f4 or {})))
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




local function send_pong(req_frameinfo, req_msg)
   local resp_frameinfo = { proto_name = req_frameinfo.proto_name, f20 = 3, f30 = req_frameinfo.f30 }
   local payload = pb.encode("xirr_server_rpc.keepalive_info", { f1 = req_msg.f1 or 0 })
   net_send(encode_block(resp_frameinfo, payload))
end








handle_text_block = function(_fi, m)
   feed_server((m and m.text or ""))
   return true
end


handle_keepalive = function(frameinfo, m)
   send_pong(frameinfo, m or {})
   return false
end





handle_music = function(_fi, m)
   if m then
      local ch = ((m.channel_name and m.channel_name ~= "") and m.channel_name or "music")
      local op = (m.op or 0)
      __rpc_music = __rpc_music or {}
      if op == 5 or op == 9 or op == 2 then
         if music and music.stop then music.stop(ch) end
         __rpc_music[ch] = nil
      elseif m.filename and m.filename ~= "" and __rpc_music[ch] ~= m.filename then
         __rpc_music[ch] = m.filename
         if music and music.play then music.play(ch, SOUNDPACK .. (m.filename) .. ".ogg") end
      end
   end
   return false
end

handle_audio = function(_fi, m)
   if m and m.short_clip_filename and m.short_clip_filename ~= "" and sound_once then
      sound_once(SOUNDPACK .. (m.short_clip_filename) .. ".ogg")
   end
   return false
end


handle_hpbar = function(_fi, m)
   if m then
      state.hp, state.maxhp = m.f1, m.f2
      state.mana, state.maxmana = m.f3, m.f4
      state.stam, state.maxstam = m.f5, m.f6
      if __recovery_on_vitals then __recovery_on_vitals() end
      if on_update then on_update() end
   end
   return false
end






handle_sky = function(_fi, m)
   if m then
      if m.printed_time_of_day_string and m.printed_time_of_day_string ~= "" then
         state.clock = m.printed_time_of_day_string
      end
      state.outdoors = (m.f2 == 1)
      state.sky_visible = (m.f2 == 1)
      state.overcast = (m.f1 == 1)
      if on_update then on_update() end
   end
   return false
end



handle_channel_send = function(_fi, m)
   if m and m.sent_message and #(m.sent_message) > 0 then
      echo(tilde_to_ansi(m.sent_message))
      return true
   end
   return false
end








handle_enemy_hp = function(_fi, m)
   if m then
      local name = m.enemy_name
      local pct = m.f2
      if name and #name > 0 then
         local was_fighting = state.fighting
         state.fighting, state.fight_name, state.fight_pct = true, name, pct or 0




         if not was_fighting and __recovery_cancel then __recovery_cancel("combat started") end




         if __autofight_prompt then __autofight_prompt(pct or 0, name) end
      else


         state.fighting, state.fight_name, state.fight_pct = false, nil, nil
         if __autofight_prompt then __autofight_prompt(nil, nil) end
      end
      if on_update then on_update() end
   end
   return false
end





handle_exp_to_level = function(_fi, m)
   if m then
      state.exp_to_level = m.f1
      if on_update then on_update() end
   end
   return false
end








handle_kv_event = function(_fi, m)
   if m then
      local key = (m.key or "")
      if key == "areaname" then
         state.area = m.kvalue or ""
         if on_update then on_update() end
      elseif key == "dirs" and type(m.f3) == "number" then



         local bits = m.f3
         local set = {}
         if bits & 1 ~= 0 then set.north = true end
         if bits & 2 ~= 0 then set.northeast = true end
         if bits & 4 ~= 0 then set.east = true end
         if bits & 8 ~= 0 then set.southeast = true end
         if bits & 16 ~= 0 then set.south = true end
         if bits & 32 ~= 0 then set.southwest = true end
         if bits & 64 ~= 0 then set.west = true end
         if bits & 128 ~= 0 then set.northwest = true end
         if bits & 256 ~= 0 then set.up = true end
         if bits & 512 ~= 0 then set.down = true end
         state.exits = set
         if on_update then on_update() end
      elseif key == "ncombat" then



         state.fighting, state.fight_name, state.fight_pct = false, nil, nil




         state.engaged_until = nil
         state.opponents = {}
         state.assisted = nil
         if __autofight_prompt then __autofight_prompt(nil, nil) end
         if on_update then on_update() end
      elseif key == "login" then
         if m.kvalue and m.kvalue ~= "" then state.name = m.kvalue end






         send("set kxwt on")
      end
   end
   return false
end



local function route(frameinfo, payload)
   local proto_name = (frameinfo.proto_name or "")
   local service_name = (frameinfo.rpc_service_name or "")
   local r = find_route(proto_name, service_name)
   local m = nil
   local suppress = false
   if r then
      local ok, dec = pcall(pb.decode, r.full, payload)
      if ok then m = dec end
      local h = HANDLERS[r.full]
      if h then suppress = h(frameinfo, m) end
   end
   if suppress then return end




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





local HOST = "www.alteraeon.com"
local PORT = 3103
local CLIENT_VERSION = "1.105-g64-rc2"
local REQUEST_PROTOCOL = "xirr_proto_rpc_1.0_noauth"

local PHASE_AWAITING_ACK = "awaiting_ack"
local PHASE_BINARY = "binary"






__rpc = __rpc or { phase = PHASE_AWAITING_ACK, ack_buf = "", block_reader = nil }



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
      client_version = CLIENT_VERSION, client_uuid = default_uuid(), client_protocol = "", })
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
      __rpc.ack_buf = (__rpc.ack_buf) .. data
      local nl = (__rpc.ack_buf):find("\n", 1, true)
      if not nl then return end
      local line = (__rpc.ack_buf):sub(1, nl - 1):gsub("%s+$", "")
      local remainder = (__rpc.ack_buf):sub(nl + 1)
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
   local block_reader = __rpc.block_reader
   for _, block in ipairs(block_reader(payload)) do
      route(block.frameinfo, block.payload)
   end
end







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











local DR = dclient_rpc or {}

function DR.start()
   if net_is_connected and net_is_connected() then return end
   net_connect(HOST, PORT, { tls = true })
end
doc(DR.start, { name = "dclient_rpc.start", sig = "dclient_rpc.start()", group = "connection",
text = "Open the AlterAeon 1.105 protobuf RPC connection (www.alteraeon.com:3103, TLS) — the whole game rides this one socket. No-op if already connected.", })

function DR.stop()
   if net_disconnect then net_disconnect() end
end
doc(DR.stop, { name = "dclient_rpc.stop", sig = "dclient_rpc.stop()", group = "connection",
text = "Close the RPC connection opened by dclient_rpc.start().", })

function DR.connected()
   return __rpc.phase == PHASE_BINARY and (net_is_connected and net_is_connected() or false)
end
doc(DR.connected, { name = "dclient_rpc.connected", sig = "dclient_rpc.connected() -> bool", group = "connection",
text = "Whether the RPC handshake completed (past the REQUEST/ACK text preamble, into the binary protobuf phase).", })

dclient_rpc = DR







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
end, })
doc(rpc, { name = "rpc", sig = "rpc('debug on|off' | 'ignore <name>' | 'show <name>' | 'list')", group = "connection",
text = "RPC message debugger. `#rpc debug on|off` toggles echoing every decoded RPC message (except game text). `#rpc ignore <name>`/`#rpc show <name>` mute/unmute a message by a substring of its protobuf name or service key (e.g. `#rpc ignore hpbar`). `#rpc list` shows the current state.", })





if net_connect and not (net_is_connected and net_is_connected()) then
   dclient_rpc.start()
elseif net_is_connected and net_is_connected() then





   __rpc.phase = PHASE_BINARY
   __rpc.block_reader = new_block_reader()
end





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
