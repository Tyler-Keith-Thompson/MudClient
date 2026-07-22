
























local dclient = { on = true, buf = "", debug = false, handlers = {} }




local handle_login
local handle_uuid
local handle_hp
local handle_group
local handle_areaname
local handle_map
local handle_skystate
local handle_sound



dclient.handlers = {
   login = function(data, tag) return handle_login(data, tag) end,
   uuid = function(data, tag) return handle_uuid(data, tag) end,
   hp = function(data, tag) return handle_hp(data, tag) end,
   group = function(data, tag) return handle_group(data, tag) end,
   areaname = function(data, tag) return handle_areaname(data, tag) end,
   map = function(data, tag) return handle_map(data, tag) end,
   skystate = function(data, tag) return handle_skystate(data, tag) end,
   sound = function(data, tag) return handle_sound(data, tag) end,
}


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
























local GA_MARK <const> = "\238\128\128"


local fb_buf = ""
local fb_held = 0
local fb_run_gag = false
local fb_prior = false
local fb_swallow = false

local function fb_resolve()
   local s
   if fb_run_gag then
      s = (fb_held > 0 and fb_prior) and "\n" or ""
   else
      s = ("\n"):rep(fb_held)
   end
   fb_held = 0; fb_run_gag = false
   return s
end



local function frame_filter(text)
   fb_buf = fb_buf .. text
   local out = {}
   while true do
      local nl = fb_buf:find("\n", 1, true)
      local ga = fb_buf:find(GA_MARK, 1, true)
      if not nl and not ga then break end
      local idx; local is_ga
      if nl and (not ga or nl < ga) then idx = nl; is_ga = false else idx = ga; is_ga = true end
      local unit = fb_buf:sub(1, idx - 1)
      if is_ga then
         fb_buf = fb_buf:sub(idx + #GA_MARK)
         if unit == "" then


            out[#out + 1] = GA_MARK
            fb_run_gag = true; fb_swallow = true
         elseif unit:match("^kxw[tq]_") then



            out[#out + 1] = unit .. GA_MARK .. "\n"
            fb_run_gag = true; fb_swallow = true
         else


            out[#out + 1] = fb_resolve() .. unit .. GA_MARK .. "\n"
            fb_prior = true; fb_swallow = true
         end
      else
         fb_buf = fb_buf:sub(idx + 1)
         if unit == "" then
            if fb_swallow then fb_swallow = false
            else fb_held = fb_held + 1 end
         elseif unit:match("^kxw[tq]_") then
            out[#out + 1] = unit .. "\n"
            fb_run_gag = true; fb_swallow = false
         else
            out[#out + 1] = fb_resolve() .. unit .. "\n"
            fb_prior = true; fb_swallow = false
         end
      end
   end
   return table.concat(out)
end

if _AA_TEST then
   _AA_TEST.frame_filter = frame_filter
   _AA_TEST.reset_frame_filter = function()
      fb_buf = ""; fb_held = 0; fb_run_gag = false; fb_prior = false; fb_swallow = false
   end
end



local function dclient_feed(chunk)
   if not dclient.on then return frame_filter(chunk) end
   dclient.buf = dclient.buf .. chunk
   return frame_filter(dclient_parse())
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






handle_login = function(data, _)
   if data and data ~= "" then state.name = data end
end




handle_uuid = function(data, _)
   if data and data ~= "" and persist and persist.write then
      persist.write(UUID_FILE, string.format("return %q", data))
   end
end




handle_hp = function(data, _)
   local a, b, c, d, e, f = data:match("^(%d+) (%d+) (%d+) (%d+) (%d+) (%d+)")
   if a then
      state.hp, state.maxhp = tonumber(a), tonumber(b)
      state.mana, state.maxmana = tonumber(c), tonumber(d)
      state.stam, state.maxstam = tonumber(e), tonumber(f)
   end
end












handle_group = function(data, _)
   local flags_for = (state.group_flags) or {}
   local g = {}
   local myname = state.name
   if type(myname) == "string" and myname ~= "" then
      g[1] = { hp = state.hp, maxhp = state.maxhp, mana = state.mana, maxmana = state.maxmana,
stam = state.stam, maxstam = state.maxstam, name = myname,
flags = flags_for[myname] or "X", is_self = true, }
   end
   for line in (data .. "\n"):gmatch("(.-)\n") do
      local hp, mhp, m, mm, s, ms, rest =
      line:match("^(%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (.-)%s*$")
      if hp then




         local name = rest
         local kind = "P"
         local dn = rest:match("^%-(.-)%-$")
         local on = rest:match("^%.(.-)%.$")
         if dn then name, kind = dn, "M"
         elseif on then name, kind = on, "O" end
         if name ~= "" and name ~= myname then
            g[#g + 1] = { hp = tonumber(hp), maxhp = tonumber(mhp), mana = tonumber(m), maxmana = tonumber(mm),
stam = tonumber(s), maxstam = tonumber(ms), name = name, flags = flags_for[name] or kind, }
         end
      end
   end
   state.group = g
   if on_update then on_update() end






   if state.recover and __recovery_on_group then __recovery_on_group() end
end

handle_areaname = function(data, _) state.area = data end











dclient.capture_map = false
local SMAP_CAPTURE_FILE = (os.getenv("HOME") or "") .. "/Documents/MudClient/smap_capture.log"
local function smap_escape(s)
   return (s:gsub("[^\32-\126]", function(c)
      local b = c:byte()
      if b == 13 then return "\\r" elseif b == 10 then return "\\n" end
      return string.format("\\x%02x", b)
   end))
end
handle_map = function(data, _)
   state.dclient_map = data
   if dclient.capture_map then
      local f = io.open(SMAP_CAPTURE_FILE, "a")
      if f then f:write(string.format("=== map %d bytes ===\n%s\n", #data, smap_escape(data))); f:close() end
   end



   if smap_on_map_update then smap_on_map_update() end
   if on_update then on_update() end
end

handle_skystate = function(data, _)
   local clock = data:match("(%d+:%d+ %a%a)%s*$")
   if clock then state.clock = clock end
end









local DC_SOUNDPACK = (os.getenv("HOME") or "") .. "/Library/AlterAeon/soundpack/"
handle_sound = function(data, _)
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
