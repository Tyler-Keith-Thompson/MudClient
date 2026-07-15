


























state = state or {}
_PROMPT_TEST = _PROMPT_TEST or {}








local function set_prompt_formats()
   send("prompt fighting kxwq_hud\\|%hp\\|%hpx\\|%ma\\|%mnx\\|%mv\\|%mvx\\|%pos\\|%fp\\|%fg\\|%fi")
   send("prompt default kxwq_hud\\|%hp\\|%hpx\\|%ma\\|%mnx\\|%mv\\|%mvx\\|%pos")
   send("prompt sleeping kxwq_hud\\|%hp\\|%hpx\\|%ma\\|%mnx\\|%mv\\|%mvx\\|%pos")
end



trigger([[^kxw[tq]_supported$]], set_prompt_formats)




if is_connected and is_connected() then set_prompt_formats() end









trigger([[^kxw[qt]_hud]], function() return "\27[0m" end)

















local function parse_prompt(text)
   local t = (text or ""):match("^%s*(.-)%s*$")
   if not t:match("^kxw[qt]_hud|") then return nil end
   local fields = {}
   for f in (t .. "|"):gmatch("(.-)|") do fields[#fields + 1] = f end

   if #fields < 8 then return nil end
   local hp, maxhp = tonumber(fields[2]), tonumber(fields[3])
   local mana, maxmana = tonumber(fields[4]), tonumber(fields[5])
   local stam, maxstam = tonumber(fields[6]), tonumber(fields[7])
   local pos = fields[8]
   if not (hp and maxhp and mana and maxmana and stam and maxstam) or not pos or pos == "" then return nil end
   local out = { hp = hp, maxhp = maxhp, mana = mana, maxmana = maxmana,
stam = stam, maxstam = maxstam, position = pos, }
   if #fields >= 11 then
      local fpct = tonumber(fields[9])
      local fname = fields[11]
      if fpct and fname and fname ~= "" then
         out.fight_pct, out.fight_gender, out.fight_name = fpct, fields[10], fname
      end
   end
   return out
end



local function apply_prompt(p)
   if not p then return end
   state.hp, state.maxhp = p.hp, p.maxhp
   state.mana, state.maxmana = p.mana, p.maxmana
   state.stam, state.maxstam = p.stam, p.maxstam
   if __recovery_on_vitals then __recovery_on_vitals() end

   local changed = (state.position ~= p.position)
   state.position = p.position
   if __recovery_on_position then __recovery_on_position(p.position, changed) end

   apply_fight(p.fight_pct, p.fight_name)

   if on_update then on_update() end
end





function apply_fight(fight_pct, fight_name)
   if fight_name then
      state.fighting, state.fight_pct, state.fight_name = true, fight_pct, fight_name
   else
      state.fighting, state.fight_name, state.fight_pct = false, nil, nil
   end
   if __autofight_prompt then
      if fight_name then __autofight_prompt(fight_pct, fight_name) else __autofight_prompt(nil, nil) end
   end
end








local function fighting_from_prompt(text)
   local pct, name = text:match("^kxw[tq]_fighting (%d+) %S+ (.+)$")
   if pct then apply_fight(tonumber(pct), name); if on_update then on_update() end; return true end
   if text:match("^kxw[tq]_fighting %-1%f[%D]") then apply_fight(nil, nil); if on_update then on_update() end; return true end
   return false
end










local function reinject_kxwt_tag(text)
   if feed_server and text:match("^kxw[tq]_") then feed_server(text .. "\n"); return true end
   return false
end

function on_prompt(text)
   if fighting_from_prompt(text) then return end
   local p = parse_prompt(text)
   if p then apply_prompt(p); return end
   reinject_kxwt_tag(text)
end

_PROMPT_TEST.parse_prompt = parse_prompt
_PROMPT_TEST.apply_prompt = apply_prompt
_PROMPT_TEST.fighting_from_prompt = fighting_from_prompt
_PROMPT_TEST.reinject_kxwt_tag = reinject_kxwt_tag
