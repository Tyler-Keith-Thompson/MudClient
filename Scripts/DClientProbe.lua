-- DClientProbe.lua — spoof the official Linux dclient (v1.096) to unlock AlterAeon's dclient channel.
--
-- The handshake is purely IN-BAND (no telnet-option negotiation needed):
--   1. IDENTITY: send `_dClient <version>` as the FIRST thing on connect (before the name; later it reads
--      as a bad character name). Linux 1096 version = `1.096-g64-rc5`.
--   2. AFTERWORD: the server replies with a `login` tag; we answer `set kxwt` (the login handler below) to
--      turn on telemetry.
--
-- CONFIRMED WORKING on the PLAIN port (3002): the server returns tagged blocks (`;s<TAG>;<DATA>;e<TAG>;`)
-- and one-shots (`;t<TAG>;`) mixed IN-BAND into the normal text stream (not newline-delimited, not
-- telnet). We register an `on_stream` filter (dclient_feed) that peels complete frames out of the raw
-- chunk stream, before line assembly, and dispatches each to a handler below; whatever's left over is
-- what gets displayed.
--
-- Enabled by default (dclient.on = true) with debug on (dclient.debug = true) so every tag is visible
-- while we finish mapping out the protocol; `#dcprobe` re-sends the identity if the server needs a kick.

local dclient = { on = true, buf = "", debug = false, handlers = {} }

local function dclient_dispatch(tag, data)
  -- Debug: echo EVERY tag, handled or not (so nothing is invisible while we map the protocol). Newlines in
  -- multi-line payloads (group/map/window_create) are shown as \n so one event = one line.
  if dclient.debug then
    echo("\27[1;33m[dclient] " .. tag .. " ► " .. (tostring(data):gsub("[\r\n]", "\\n")):sub(1, 240) .. "\27[0m")
  end
  local h = dclient.handlers[tag]
  if h then
    local ok, err = pcall(h, data, tag)
    if not ok then echo("[dclient] handler '" .. tag .. "' error: " .. tostring(err)) end
  end
end

-- Streaming framing parser over dclient.buf. Dispatches every COMPLETE block/one-shot and returns the
-- text to display; anything only partially arrived stays buffered (whole) for the next chunk.
local function dclient_parse()
  local b, out, i = dclient.buf, {}, 1
  local n = #b
  while i <= n do
    local semi = b:find(";", i, true)
    if not semi then out[#out + 1] = b:sub(i); i = n + 1; break end
    if semi > i then out[#out + 1] = b:sub(i, semi - 1) end     -- text before the ';'
    if semi + 1 > n then i = semi; break end                    -- ';' at buffer end -> wait for next char
    local nx = b:sub(semi + 1, semi + 1)
    if nx == ";" then
      out[#out + 1] = ";"; i = semi + 2                          -- ";;" -> literal ';'
    elseif nx == "t" then
      local tagEnd = b:find(";", semi + 2, true)
      if not tagEnd then i = semi; break end
      dclient_dispatch(b:sub(semi + 2, tagEnd - 1), ""); i = tagEnd + 1
    elseif nx == "s" then
      local tagEnd = b:find(";", semi + 2, true)
      if not tagEnd then i = semi; break end
      local dataEnd = b:find(";", tagEnd + 1, true)
      if not dataEnd then i = semi; break end
      if b:sub(dataEnd + 1, dataEnd + 1) ~= "e" then             -- malformed: no end tag -> take data, resync
        dclient_dispatch(b:sub(semi + 2, tagEnd - 1), b:sub(tagEnd + 1, dataEnd - 1)); i = dataEnd + 1
      else
        local endSemi = b:find(";", dataEnd + 2, true)
        if not endSemi then i = semi; break end                 -- end tag not fully here -> wait
        dclient_dispatch(b:sub(semi + 2, tagEnd - 1), b:sub(tagEnd + 1, dataEnd - 1)); i = endSemi + 1
      end
    else
      out[#out + 1] = ";" .. nx; i = semi + 2                    -- ";X" (not special) -> literal two chars
    end
  end
  dclient.buf = b:sub(i)
  return table.concat(out)
end

-- The on_stream filter: buffer + parse when enabled, else pass the chunk straight through.
local function dclient_feed(chunk)
  if not dclient.on then return chunk end
  dclient.buf = dclient.buf .. chunk
  return dclient_parse()
end
if on_stream then on_stream(dclient_feed) end

-- Accept MSSP (telnet option 70 = MUD Server Status Protocol). The server offers `IAC WILL 70` and, once
-- we DO it, pushes a metadata block via `IAC SB 70 …` — NAME / PLAYERS / UPTIME / HOSTNAME / PORT /
-- CODEBASE / CONTACT (fields delimited by 0x01/0x02). This is SERVER INFO, separate from the dclient
-- tagged channel (that's the in-band `;s<tag>;` framing above, opened by the `_dClient` identity). Host
-- default is DONT (reject); the real client accepts it, so we do too.
function on_telnet_negotiate(verb, option)
  if option == 70 then return "accept" end          -- MSSP
  return nil                                          -- defer everything else to the host
end

-- Debugger: surface any telnet subnegotiation (IAC SB <opt> <payload> IAC SE) — e.g. the MSSP block on 70.
function on_telnet(option, payload)
  if not dclient.debug then return end
  local p = tostring(payload or ""):gsub("[^\32-\126]", "."):sub(1, 160)
  echo("\27[1;35m[dclient] SB opt=" .. tostring(option) .. " len=" .. #(payload or "") .. " -> " .. p .. "\27[0m")
end

-- Identity handshake, sent FIRST on connect (before anything else, or it reads as a bad character name).
-- This file loads after AlterAeon.lua (alphabetically), which already defines on_connect (it opens the
-- connection) -- wrap it so both fire: identity first, then whatever AlterAeon.lua's on_connect does.
--
-- BYTE-EXACT FORMAT (reverse-engineered from `xirr_mw::socket_connect` in both the Mac and Linux 1.096
-- binaries): `_dClient <uuid> <version>\n`. THREE space-separated fields, terminated by a single \n (no
-- \r, no telnet framing). Field 2 is NOT a client name — it's the client's 32-char UUID. Sending only
-- `_dClient <version>` (two fields) gets a DEGRADED channel; the placeholder name we tried earlier worked
-- only because the server just wants three tokens.
--   * version: DELIBERATELY the OLD `1.096-g64-rc5` (Mac was `1.096.03-mac-rc6`), NOT the latest. The real
--     latest Linux build is `1.105-g64-rc2` (binary AlterAeon_220331_1105_linux64_rc2.exe from
--     alteraeon.com/downloads/dclient_v3/) — but 1.105 ABANDONED the in-band kxwt/kxwq protocol ENTIRELY
--     (its binary has zero kxwt/kxwq/dclstatus strings) and moved ALL telemetry + audio to a protobuf RPC
--     sub-protocol on a SEPARATE TLS connection (port 3103). If we advertised 1.105 on the game socket the
--     server would likely switch us to that RPC transport and STOP sending the `kxwq_*`/`;s<tag>;` tags our
--     HUD/combat/map depend on — a hard regression. So we stay on 1.096 for the game socket, and (if we
--     pursue music) add the RPC connection strictly IN PARALLEL. See memory dclient-1105-protobuf-rpc.
local DCLIENT_VER  = "1.096-g64-rc5"
local UUID_FILE    = (os.getenv("HOME") or "") .. "/Documents/MudClient/dclient_uuid.txt"

-- FIRST connect (nothing saved) → send a throwaway DFLT+28-hex default (create_default_uuid's format). The
-- server then ASSIGNS a durable per-install token via the `;suuid;` tag, which the uuid handler below
-- PERSISTS; we reuse it forever after. This mirrors the official client (set_uuid → save_system_config), so
-- the server recognizes us as a returning install instead of minting a new token each session. We do NOT
-- persist the DFLT default — only the server's assigned value gets saved.
local function dclient_uuid()
  local saved = (persist and persist.load) and persist.load(UUID_FILE) or nil
  if type(saved) == "string" and saved ~= "" then return saved end
  local hex, chars = { "D", "F", "L", "T" }, "0123456789abcdef"
  math.randomseed(os.time() + math.floor((os.clock() or 0) * 1e6))
  for _ = 5, 32 do local i = math.random(1, 16); hex[#hex + 1] = chars:sub(i, i) end
  return table.concat(hex)
end

local IDENTITY = "_dClient " .. dclient_uuid() .. " " .. DCLIENT_VER
local function handshake() if send then send(IDENTITY) end end
local _prev_on_connect = on_connect
function on_connect()
  handshake()
  if _prev_on_connect then _prev_on_connect() end
end


-- Auto-enable client-trigger telemetry (kxwt/kxwq) the moment we log in. The server fires the dclient
-- `login` tag (payload = character name) at that point, so we reply with `set kxwt` -- the same command
-- that works by hand. We can't lean on the `^kxw[tq]_supported` handshake in a dclient session: the
-- server doesn't send that line here, which is why the pilot's map/coords used to stay dark until you
-- enabled it manually.
dclient.handlers["login"] = function(data)
  if data and data ~= "" then state.name = data end
  send("set kxwt")
end

-- The server assigns our durable per-install identity via `;suuid;<token>;euuid;`. Persist it so we echo it
-- back as handshake field 2 next connect (the official client does exactly this: set_uuid → save config),
-- making the server recognize us as a returning install instead of a brand-new one each session.
dclient.handlers["uuid"] = function(data)
  if data and data ~= "" and persist and persist.write then
    persist.write(UUID_FILE, string.format("return %q", data))
  end
end

-- Telemetry handlers: translate dclient tags into the SAME `state` fields the kxwt triggers fill, so the
-- HUD widgets render off whichever protocol is live (field layouts confirmed from live captures). Both
-- can run at once -- they write the same fields, so last-writer-wins with identical data.
dclient.handlers["hp"] = function(data)      -- "hp maxhp mana maxmana mov maxmov" (your vitals)
  local a, b, c, d, e, f = data:match("^(%d+) (%d+) (%d+) (%d+) (%d+) (%d+)")
  if a then
    state.hp, state.maxhp = tonumber(a), tonumber(b)
    state.mana, state.maxmana = tonumber(c), tonumber(d)
    state.stam, state.maxstam = tonumber(e), tonumber(f)
  end
end

-- GROUP is the one place kxwq beats dclient, so we deliberately DON'T write the roster from the framed
-- `;sgroup;` event — we let AlterAeon.lua's `kxw[tq]_group` parser own `state.group` instead.
-- Why: the framed `;sgroup;` payload is strictly POORER. Its lines are "hp maxhp mana maxmana mov maxmov
-- -name-" with NO flags and it OMITS you, whereas the paired `kxwq_group` block carries the class/role
-- flags ("… M A mummy", "… MT A flesh beast", "XLN Vaelith") AND includes you. Those flags are what
-- HUD.lua's group_member_row colors by (M=cyan minion, O=grey, ?=yellow mob; L/T/N badges) — the framed
-- data literally cannot reproduce the colors because the flags aren't in it. Both events fire every tick,
-- so writing state.group from BOTH made the roster flicker (flagged kxwq rows vs flagless framed rows,
-- and you popping in/out). Deferring to kxwq_group kills the flicker and restores the colors. We leave the
-- handler registered as a no-op purely so the tag still surfaces in the dclient debug echo (dispatch echoes
-- every tag before the handler lookup) while we map the protocol.
dclient.handlers["group"] = function(_) end

dclient.handlers["areaname"] = function(data) state.area = data end

dclient.handlers["skystate"] = function(data)   -- e.g. "110 3 870 2:30 pm" -- trailing token is the clock
  local clock = data:match("(%d+:%d+ %a%a)%s*$")
  if clock then state.clock = clock end
end

-- `sound` carries a soundpack-relative path (e.g. "ogg_v1/move/gravel1"), already rooted at the ogg_v1
-- pack, so unlike Audio.lua's kxwt SOUNDPACK (which is the ogg_v1 dir itself) we go one level up here.
-- These are the ONLY per-event sounds a dclient session gets: `!!SOUND`/`!-SOUND` MSP directives never
-- arrive here for individual events (only the base-URL-setting `!-SOUND(Off U=...)` does, at login, with
-- nothing following it -- see MSP.swift), so this framed channel is the sole source and there's no
-- double-play risk. Soundtracks loop (crossfade on the "music" channel, the looping layered player);
-- everything else is a one-shot, played via `sound_once` -- the SAME player MSP `!!SOUND` effects use,
-- not the looping `music` channel player (which would leak per-path channels for one-shots).
local DC_SOUNDPACK = (os.getenv("HOME") or "") .. "/Library/AlterAeon/soundpack/"
dclient.handlers["sound"] = function(data)
  local path = DC_SOUNDPACK .. data .. ".ogg"
  if data:find("soundtrack", 1, true) then
    if music and music.play then music.play("music", path) end        -- looping background score
  elseif sound_once then
    sound_once(path)                                                   -- one-shot effect
  end
end


_AA_TEST = _AA_TEST or {}
_AA_TEST.dclient = dclient
_AA_TEST.dclient_parse = dclient_parse
_AA_TEST.dclient_feed = dclient_feed
