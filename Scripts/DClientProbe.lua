
























local dclient = { on = true, buf = "", debug = false, handlers = {} }

local function dclient_dispatch(tag, data)


   if dclient.debug then
      echo("\27[1;33m[dclient] " .. tag .. " ► " .. (tostring(data):gsub("[\r\n]", "\\n")):sub(1, 240) .. "\27[0m")
   end
   local h = dclient.handlers[tag]
   if h then
      local ok, err = pcall(h, data, tag)
      if not ok then echo("[dclient] handler '" .. tag .. "' error: " .. tostring(err)) end
   end
end



local function dclient_parse()
   local b = dclient.buf
   local out = {}
   local i = 1
   local n = #b
   while i <= n do
      local semi = b:find(";", i, true)
      if not semi then out[#out + 1] = b:sub(i); i = n + 1; break end
      if semi > i then out[#out + 1] = b:sub(i, semi - 1) end
      if semi + 1 > n then i = semi; break end
      local nx = b:sub(semi + 1, semi + 1)
      if nx == ";" then
         out[#out + 1] = ";"; i = semi + 2
      elseif nx == "t" then
         local tagEnd = b:find(";", semi + 2, true)
         if not tagEnd then i = semi; break end
         dclient_dispatch(b:sub(semi + 2, tagEnd - 1), ""); i = tagEnd + 1
      elseif nx == "s" then
         local tagEnd = b:find(";", semi + 2, true)
         if not tagEnd then i = semi; break end
         local dataEnd = b:find(";", tagEnd + 1, true)
         if not dataEnd then i = semi; break end
         if b:sub(dataEnd + 1, dataEnd + 1) ~= "e" then
            dclient_dispatch(b:sub(semi + 2, tagEnd - 1), b:sub(tagEnd + 1, dataEnd - 1)); i = dataEnd + 1
         else
            local endSemi = b:find(";", dataEnd + 2, true)
            if not endSemi then i = semi; break end
            dclient_dispatch(b:sub(semi + 2, tagEnd - 1), b:sub(tagEnd + 1, dataEnd - 1)); i = endSemi + 1
         end
      else
         out[#out + 1] = ";" .. nx; i = semi + 2
      end
   end
   dclient.buf = b:sub(i)
   return table.concat(out)
end


local function dclient_feed(chunk)
   if not dclient.on then return chunk end
   dclient.buf = dclient.buf .. chunk
   return dclient_parse()
end
if on_stream then on_stream(dclient_feed) end






function on_telnet_negotiate(_, option)
   if option == 70 then return "accept" end
   return nil
end


function on_telnet(option, payload)
   if not dclient.debug then return end
   local p = tostring(payload or ""):gsub("[^\32-\126]", "."):sub(1, 160)
   echo("\27[1;35m[dclient] SB opt=" .. tostring(option) .. " len=" .. #(payload or "") .. " -> " .. p .. "\27[0m")
end


















local DCLIENT_VER = "1.096-g64-rc5"
local UUID_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/dclient_uuid.txt"





local persist






local function dclient_uuid()
   local saved = (persist and persist.load) and persist.load(UUID_FILE) or nil
   if type(saved) == "string" and saved ~= "" then return saved end
   local hex = { "D", "F", "L", "T" }
   local chars = "0123456789abcdef"
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






dclient.handlers["login"] = function(data, _)
   if data and data ~= "" then state.name = data end
end




dclient.handlers["uuid"] = function(data, _)
   if data and data ~= "" and persist and persist.write then
      persist.write(UUID_FILE, string.format("return %q", data))
   end
end




dclient.handlers["hp"] = function(data, _)
   local a, b, c, d, e, f = data:match("^(%d+) (%d+) (%d+) (%d+) (%d+) (%d+)")
   if a then
      state.hp, state.maxhp = tonumber(a), tonumber(b)
      state.mana, state.maxmana = tonumber(c), tonumber(d)
      state.stam, state.maxstam = tonumber(e), tonumber(f)
   end
end












dclient.handlers["group"] = function(data, _)
   local flags_for = (state.group_flags) or {}
   local g = {}
   local myname = state.name
   if type(myname) == "string" and myname ~= "" then
      g[1] = { hp = state.hp, maxhp = state.maxhp, mana = state.mana, maxmana = state.maxmana,
stam = state.stam, maxstam = state.maxstam, name = myname,
flags = flags_for[myname] or "X", is_self = true, }
   end
   for line in (data .. "\n"):gmatch("(.-)\n") do
      local hp, mhp, m, mm, s, ms, name =
      line:match("^(%d+) (%d+) (%d+) (%d+) (%d+) (%d+) %-(.-)%-%s*$")
      if hp then
         g[#g + 1] = { hp = tonumber(hp), maxhp = tonumber(mhp), mana = tonumber(m), maxmana = tonumber(mm),
stam = tonumber(s), maxstam = tonumber(ms), name = name, flags = flags_for[name] or "M", }
      end
   end
   state.group = g
   if on_update then on_update() end






   if state.recover and __recovery_on_group then __recovery_on_group() end
end

dclient.handlers["areaname"] = function(data, _) state.area = data end











dclient.capture_map = false
local SMAP_CAPTURE_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/smap_capture.log"
local function smap_escape(s)
   return (s:gsub("[^\32-\126]", function(c)
      local b = c:byte()
      if b == 13 then return "\\r" elseif b == 10 then return "\\n" end
      return string.format("\\x%02x", b)
   end))
end
dclient.handlers["map"] = function(data, _)
   state.dclient_map = data
   if dclient.capture_map then
      local f = io.open(SMAP_CAPTURE_FILE, "a")
      if f then f:write(string.format("=== map %d bytes ===\n%s\n", #data, smap_escape(data))); f:close() end
   end



   if smap_on_map_update then smap_on_map_update() end
   if on_update then on_update() end
end

dclient.handlers["skystate"] = function(data, _)
   local clock = data:match("(%d+:%d+ %a%a)%s*$")
   if clock then state.clock = clock end
end









local DC_SOUNDPACK = (os.getenv("HOME") or "") .. "/Library/AlterAeon/soundpack/"
dclient.handlers["sound"] = function(data, _)
   local path = DC_SOUNDPACK .. data .. ".ogg"
   if data:find("soundtrack", 1, true) then
      if music and music.play then music.play("music", path) end
   elseif sound_once then
      sound_once(path)
   end
end


_AA_TEST = _AA_TEST or {}
_AA_TEST.dclient = dclient
_AA_TEST.dclient_parse = dclient_parse
_AA_TEST.dclient_feed = dclient_feed
