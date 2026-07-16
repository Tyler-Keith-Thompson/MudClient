


























state = state or {}
_PROMPT_TEST = _PROMPT_TEST or {}






local function boot(name) pcall(require, name) end
boot("Parse")
if not __parse then dofile("Scripts/Foundation/Parse.lua") end
boot("Route")
if not __route then dofile("Scripts/Foundation/Route.lua") end
local route = __route.route








local function set_prompt_formats()
   send("prompt fighting kxwq_hud\\|%hp\\|%hpx\\|%ma\\|%mnx\\|%mv\\|%mvx\\|%pos\\|%fp\\|%fg\\|%fi")
   send("prompt default kxwq_hud\\|%hp\\|%hpx\\|%ma\\|%mnx\\|%mv\\|%mvx\\|%pos")
   send("prompt sleeping kxwq_hud\\|%hp\\|%hpx\\|%ma\\|%mnx\\|%mv\\|%mvx\\|%pos")
end



trigger([[^kxw[tq]_supported$]], set_prompt_formats)




if is_connected and is_connected() then set_prompt_formats() end









trigger([[^kxw[qt]_hud]], function() return "\27[0m" end)























local sentinel = __parse.oneOf(__parse.lit("kxwq_hud"), __parse.lit("kxwt_hud"))
local pipe = __parse.lit("|")
local field = __parse.prefix_up_to("|")
local prompt_fields = sentinel:take(pipe):take(__parse.many1(field, pipe))






local function to_prompt_fields(fields)
   if #fields < 7 then return nil end
   local hp, maxhp = tonumber(fields[1]), tonumber(fields[2])
   local mana, maxmana = tonumber(fields[3]), tonumber(fields[4])
   local stam, maxstam = tonumber(fields[5]), tonumber(fields[6])
   local pos = fields[7]
   if not (hp and maxhp and mana and maxmana and stam and maxstam) or not pos or pos == "" then return nil end
   local out = { hp = hp, maxhp = maxhp, mana = mana, maxmana = maxmana,
stam = stam, maxstam = maxstam, position = pos, }
   if #fields >= 10 then
      local fpct = tonumber(fields[8])
      local fname = fields[10]
      if fpct and fname and fname ~= "" then
         out.fight_pct, out.fight_gender, out.fight_name = fpct, fields[9], fname
      end
   end
   return out
end





local function from_prompt_fields(p)
   local out = {
      tostring(p.hp), tostring(p.maxhp), tostring(p.mana), tostring(p.maxmana),
      tostring(p.stam), tostring(p.maxstam), p.position,
   }
   if p.fight_name then
      out[8], out[9], out[10] = tostring(p.fight_pct), p.fight_gender, p.fight_name
   end
   return out
end

local prompt_fields_conv = {
   apply = to_prompt_fields,
   unapply = from_prompt_fields,
}




local prompt_parser = prompt_fields:map(prompt_fields_conv)

local function parse_prompt(text)
   local t = (text or ""):match("^%s*(.-)%s*$")
   local p = __parse.parse_all(prompt_parser, t)
   return p
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






local function is_fighting_bar(text)
   return text:match("^kxw[tq]_fighting") ~= nil
end

local function is_hud_prompt(text)
   return parse_prompt(text) ~= nil
end

local any_case = __route.any

local function handle_fighting(text)
   fighting_from_prompt(text)
end

local function apply_prompt_line(text)
   apply_prompt(parse_prompt(text))
end

on_prompt = route({
   { is_fighting_bar, handle_fighting },
   { is_hud_prompt, apply_prompt_line },
   { any_case, reinject_kxwt_tag },
})

_PROMPT_TEST.parse_prompt = parse_prompt
_PROMPT_TEST.apply_prompt = apply_prompt
_PROMPT_TEST.fighting_from_prompt = fighting_from_prompt
_PROMPT_TEST.reinject_kxwt_tag = reinject_kxwt_tag
