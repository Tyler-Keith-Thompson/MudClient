







































state = state or {}











local cfg = {
   pale_lots = 4,
   keep_pale = 2,
   inv_backstop = 4.5,

   recast_wait = 0.4,
   gather_wait = 2.5,







   max_no_progress = 3,
   stow = true,
}



local SF_IDLE = 30


local TIER = { red = 1, yellow = 2, green = 3, pale = 4, deep = 5, purple = 6 }

local COLOR_ALIAS = { ["pale blue"] = "pale", ["deep blue"] = "deep" }
local TIER_LABEL = { red = "red", yellow = "yellow", green = "green",
pale = "pale blue", deep = "deep blue", purple = "purple", }

local function say(s) if echo then echo("\27[1;35m[soulforge]\27[0m " .. s) end end














local function tier_key(phrase)
   if type(phrase) == "string" then
      local c = phrase:lower():gsub("^%s+", ""):gsub("%s+$", "")
      c = COLOR_ALIAS[c] or c
      return TIER[c] and c or nil
   end
   return nil
end

local function soulstone_color(name)
   if type(name) == "string" then
      local c = name:match("^%s*[Aa]n?%s+(.-)%s+soulstone%s*%.?%s*$")
      return c and tier_key(c) or nil
   end
   return nil
end

local function tier(color) return TIER[color] end





local function parse_soulstones(inventory)
   local out = {}
   local n = 0
   for _, name in ipairs(inventory or {}) do
      if type(name) == "string" and name:lower():find("soulstone", 1, true) then
         n = n + 1
         out[#out + 1] = { ord = n, name = name, color = soulstone_color(name) }
      end
   end
   return out
end

local function count_color(stones, color)
   local n = 0
   for _, s in ipairs(stones) do if s.color == color then n = n + 1 end end
   return n
end




local function target_tier(stones)
   return (count_color(stones, "pale") >= cfg.pale_lots) and TIER.deep or TIER.pale
end





local function is_raw(color, stones)
   local t = TIER[color]
   if not t then return false end
   if t < TIER.pale then return true end
   if color == "pale" then
      local n = count_color(stones, "pale")
      return n >= cfg.pale_lots and n > cfg.keep_pale
   end
   return false
end

















local function plan_next_forge(stones, context)
   context = context or stones
   local raw = {}
   for _, s in ipairs(stones) do
      if s.color and is_raw(s.color, context) then raw[#raw + 1] = s end
   end
   if #raw < 2 then return nil end


   table.sort(raw, function(x, y)
      if TIER[x.color] ~= TIER[y.color] then return TIER[x.color] < TIER[y.color] end
      return x.ord < y.ord
   end)
   local lowest = raw[1]



   local partner = nil
   for i = 2, #raw do
      if raw[i].color == lowest.color then partner = raw[i]; break end
   end


   partner = partner or raw[2]

   local a, b = lowest.ord, partner.ord
   if a > b then a, b = b, a end
   return { a = a, b = b }
end



local function forge_cmd(pair)
   return string.format("c soulforge %d.soulstone %d.soulstone", pair.a, pair.b)
end







local function renumber(model) for i, s in ipairs(model) do s.ord = i end end






local function apply_forge(model, a, b, result_color, base_color)
   if not result_color then return false end
   local ia
   local ib
   for i, s in ipairs(model) do
      if s.ord == a then ia = i elseif s.ord == b then ib = i end
   end
   if not ia or not ib then return false end
   local ca, cb = model[ia].color, model[ib].color
   if base_color and base_color ~= ca and base_color ~= cb then return false end
   local survive, remove = ia, ib
   if base_color and cb == base_color and ca ~= base_color then survive, remove = ib, ia end
   model[survive].color = result_color
   table.remove(model, remove)
   renumber(model)
   return true
end






local CONTAINER_KW = { "sack", "bag", "backpack", "pack", "pouch", "chest", "box", "quiver", "basket",
"container", "purse", "case", "satchel", "crate", "barrel", "trunk", "dimension",
"vortex", "distortion", "pocket", }
local function looks_like_container(name)
   if not (type(name) == "string") then return false end
   local n = name:lower()
   if n:find("soulstone", 1, true) then return false end
   for _, kw in ipairs(CONTAINER_KW) do if n:find(kw, 1, true) then return true end end
   return false
end



local function container_kw(name)
   return (type(name) == "string") and name:match("(%a+)%s*%.?%s*$") or nil
end



local function carried_containers(inventory)
   local out = {}
   local seen = {}
   for _, name in ipairs(inventory or {}) do
      if looks_like_container(name) then
         local kw = container_kw(name)
         if kw and not seen[kw] then seen[kw] = true; out[#out + 1] = kw end
      end
   end
   return out
end




local function container_soulstone(line)
   if not (type(line) == "string") then return nil end
   local count, phrase = line:match("^%s*%(%s*(%d+)%s*%)%s*[Aa]n?%s+(.-)%s+soulstone%s*%.?%s*$")
   if not phrase then phrase = line:match("^%s*[Aa]n?%s+(.-)%s+soulstone%s*%.?%s*$") end
   local color = phrase and tier_key(phrase) or nil
   if not color then return nil end
   return color, (math.tointeger(tonumber(count)) or 1)
end




local sent = {}
local function clear_sent() for i = #sent, 1, -1 do sent[i] = nil end end
local function sf_send(cmd)
   sent[#sent + 1] = cmd
   if send then send(cmd) end
end









































local sf_op









local function sf_settle(ok, reason)
   local op = sf_op; sf_op = nil
   if not op then return end
   if cancel then
      if op.timer then cancel(op.timer) end
      if op.inv_timer then cancel(op.inv_timer) end
      if op.recast_timer then cancel(op.recast_timer) end
      if op.gather_timer then cancel(op.gather_timer) end
   end
   if ok == false then op.reject(reason or "soulforge interrupted") else (op.resolve)() end
end


local function sf_touch()
   local op = sf_op; if not op then return end
   if op.timer and cancel then cancel(op.timer) end
   if after then    op.timer = after(SF_IDLE, function()
      say("stalled — wrapping up.")
      sf_settle(false, "stalled")
   end) end
end

local plan_and_cast
local start_gather
local forge_done
local done_looking






local function combined_colors(op)
   local combined = {}
   for _, s in ipairs(op.model or {}) do if s.color then combined[#combined + 1] = { color = s.color } end end
   for _, counts in pairs(op.container_stones or {}) do
      for color, n in pairs(counts) do for _ = 1, n do combined[#combined + 1] = { color = color } end end
   end
   return combined
end



local function resync_and_plan()
   local op = sf_op; if not op then return end
   op.inv_timer, op.awaiting_inv = nil, false
   op.model = parse_soulstones(state.inventory)



   if not op.gathered then return start_gather() end
   plan_and_cast()
end







local function kick_inventory()
   local op = sf_op; if not op then return end
   sf_touch()
   op.awaiting_inv = true
   if op.inv_timer and cancel then cancel(op.inv_timer) end
   sf_send("inv")
   op.inv_timer = after and after(cfg.inv_backstop, resync_and_plan) or nil
end






function on_inventory()
   local op = sf_op
   if not op or not op.awaiting_inv then return end
   op.awaiting_inv = false
   if op.inv_timer and cancel then cancel(op.inv_timer) end
   resync_and_plan()
end



plan_and_cast = function()
   local op = sf_op; if not op then return end
   local model = op.model or {}




   if #model < 2 then return forge_done() end



   local pair = plan_next_forge(model, combined_colors(op))
   if not pair then return forge_done() end

   op.pair = pair
   op.cmd = forge_cmd(pair)
   sf_touch()
   sf_send(op.cmd)
end














local gather_look
local gather_look_done
local gather_pull
local gather_pull_advance
local finish_gather




local function arm_gather_backstop(cb)
   local op = sf_op; if not op then return end
   if op.gather_timer and cancel then cancel(op.gather_timer) end
   op.gather_timer = after and after(cfg.gather_wait, function()
      op.gather_timer = nil
      if sf_op == op then cb() end
   end) or nil
end


local function describe_counts(counts)
   local parts = {}
   for _, color in ipairs({ "red", "yellow", "green", "pale", "deep", "purple" }) do
      local n = counts[color]
      if n and n > 0 then parts[#parts + 1] = n .. " " .. TIER_LABEL[color] end
   end
   return (#parts > 0) and table.concat(parts, ", ") or nil
end



gather_look = function()
   local op = sf_op; if not op then return end
   local kw = op.containers[op.cont_idx]
   if not kw then return done_looking() end
   op.capturing, op.look_found = true, {}
   sf_touch()
   sf_send("look in " .. kw)
   arm_gather_backstop(gather_look_done)
end


gather_look_done = function()
   local op = sf_op; if not op or not op.capturing then return end
   op.capturing = false
   if op.gather_timer and cancel then cancel(op.gather_timer); op.gather_timer = nil end
   local kw = op.containers[op.cont_idx]
   op.container_stones[kw] = op.look_found or {}
   local desc = describe_counts(op.container_stones[kw])
   say(kw .. " holds: " .. (desc or "no soulstones"))
   op.cont_idx = op.cont_idx + 1
   if op.cont_idx <= #op.containers then gather_look() else done_looking() end
end




done_looking = function()
   local op = sf_op; if not op then return end
   op.phase = "gather"

   local combined = combined_colors(op)

   op.pull_queue = {}
   for _, kw in ipairs(op.containers) do
      for _, color in ipairs({ "red", "yellow", "green", "pale", "deep", "purple" }) do
         local n = (op.container_stones[kw] or {})[color]
         if n and n > 0 and is_raw(color, combined) then


            op.pull_queue[#op.pull_queue + 1] = { kw = kw, color = color, remaining = n }
         end
      end
   end
   if #op.pull_queue == 0 then
      say("nothing in your containers is worth forging — leaving them; forging what you carry.")
      return finish_gather()
   end
   op.gphase, op.pull_idx, op.pulled = "pull", 1, 0
   gather_pull()
end







gather_pull = function()
   local op = sf_op; if not op then return end
   local item = op.pull_queue[op.pull_idx]
   if not item then return finish_gather() end
   if (item.remaining or 1) <= 0 then
      op.pull_idx = op.pull_idx + 1
      return gather_pull()
   end
   sf_touch()
   sf_send(string.format("get %s soulstone %s", item.color, item.kw))
   arm_gather_backstop(gather_pull_advance)
end


gather_pull_advance = function()
   local op = sf_op; if not op then return end
   if op.gather_timer and cancel then cancel(op.gather_timer); op.gather_timer = nil end
   op.pull_idx = op.pull_idx + 1
   if op.pull_idx > #op.pull_queue then finish_gather() else gather_pull() end
end

finish_gather = function()
   local op = sf_op; if not op then return end
   if op.gather_timer and cancel then cancel(op.gather_timer); op.gather_timer = nil end
   op.capturing = false
   op.gathered, op.phase = true, "forge"
   if (op.pulled or 0) > 0 then say(string.format("pulled %d soulstone(s) out — forging.", op.pulled)) end

   plan_and_cast()
end



start_gather = function()
   local op = sf_op; if not op then return end
   op.phase, op.containers = "gather", carried_containers(state.inventory)
   op.cont_idx, op.pulled, op.container_stones, op.gphase = 1, 0, {}, "look"
   op.forged_this_cycle = 0
   op.stow_kw = op.containers[1]
   if #op.containers == 0 then op.gathered, op.phase = true, "forge"; return plan_and_cast() end
   say(string.format("looking in %d carried container(s) for soulstones…", #op.containers))
   gather_look()
end







local next_cycle
local stow_next


local function report_done()
   local op = sf_op; if not op then return end
   local back = (op.stowed_total and op.stowed_total > 0 and op.stow_kw) and
   string.format(" — put %d back in %s", op.stowed_total, op.stow_kw) or ""
   if (op.forged_total or 0) > 0 then
      say(string.format("done — forged %d time(s)%s.", op.forged_total, back))
   elseif back ~= "" then
      say("done" .. back .. " (nothing needed forging).")
   else
      say("nothing to forge (checked your inventory and carried containers).")
   end
end

local function stow_done()
   local op = sf_op; if not op then return end
   if op.gather_timer and cancel then cancel(op.gather_timer); op.gather_timer = nil end
   next_cycle()
end

stow_next = function()
   local op = sf_op; if not op or not op.stow_kw then return stow_done() end




   if #(op.model or {}) == 0 then return stow_done() end
   sf_touch()
   sf_send("put soulstone " .. op.stow_kw)
   arm_gather_backstop(stow_done)
end

local function begin_stow()
   local op = sf_op; if not op then return end
   op.phase = "stow"
   stow_next()
end



forge_done = function()
   local op = sf_op; if not op then return end
   if cfg.stow and op.stow_kw and #(op.model or {}) > 0 then return begin_stow() end
   report_done(); sf_settle(true)
end



local function container_has_raw(op)
   local combined = combined_colors(op)
   local raw = 0
   for _, s in ipairs(combined) do if is_raw(s.color, combined) then raw = raw + 1 end end
   return raw >= 2
end





next_cycle = function()
   local op = sf_op; if not op then return end
   if (op.forged_this_cycle or 0) > 0 and container_has_raw(op) then
      op.forged_this_cycle = 0
      done_looking()
   else
      report_done(); sf_settle(true)
   end
end



local function begin_op()
   sf_settle(false, "superseded")
   if not __promise then say("promise layer unavailable — cannot run soulforge."); return nil end
   local p = __promise(function(resolve, reject, onCancel)
      sf_op = { resolve = resolve, reject = reject, cmd = nil, no_progress = 0,
phase = "gather", gathered = false, }
      onCancel(function()
         if sf_op and cancel then
            if sf_op.timer then cancel(sf_op.timer) end
            if sf_op.inv_timer then cancel(sf_op.inv_timer) end
            if sf_op.recast_timer then cancel(sf_op.recast_timer) end
            if sf_op.gather_timer then cancel(sf_op.gather_timer) end
         end
         sf_op = nil
      end)
   end, "soulforge")
   if p and p.__start then p.__start() end
   if sf_op then sf_op.promise = p end
   say("merging soulstones up toward pale blue — reading what you're carrying…")
   kick_inventory()
   return p
end







local function hit_forge_result(result_phrase, base_phrase)
   local op = sf_op; if not op then return end
   op.forged = true
   op.forged_total = (op.forged_total or 0) + 1
   op.forged_this_cycle = (op.forged_this_cycle or 0) + 1
   op.no_progress = 0
   sf_touch()
   local ok = op.pair and apply_forge(op.model or {}, op.pair.a, op.pair.b,
   tier_key(result_phrase), tier_key(base_phrase))
   if ok then plan_and_cast()
   else kick_inventory() end
end




local function resend_cmd()
   local op = sf_op; if not op or not op.cmd then return end
   op.recast_timer = nil
   sf_touch()
   sf_send(op.cmd)
end
local function hit_fail()
   local op = sf_op; if not op then return end
   sf_touch()
   if op.recast_timer and cancel then cancel(op.recast_timer) end
   op.recast_timer = after and after(cfg.recast_wait, resend_cmd) or nil
end






local function hit_bad_selection()
   local op = sf_op; if not op then return end
   op.no_progress = (op.no_progress or 0) + 1
   if op.no_progress >= cfg.max_no_progress then
      say(string.format("no progress after %d rejected selections — stopping.", op.no_progress))
      sf_settle(true); return
   end
   kick_inventory()
end



local function hit_mana()
   if not sf_op then return end
   say("out of mana — stopping (recover mana, then run soulforge again).")
   sf_settle(false, "out of mana")
end




local function hit_progress() sf_touch() end





local function hit_look_soulstone(line)
   local op = sf_op; if not op or not op.capturing then return end
   local color, count = container_soulstone(line)
   if not color then return end
   op.look_found = op.look_found or {}
   op.look_found[color] = (op.look_found[color] or 0) + count
   sf_touch()
   arm_gather_backstop(gather_look_done)
end




local function hit_get_ok(color_phrase)
   local op = sf_op; if not op or op.phase ~= "gather" or op.gphase ~= "pull" then return end
   op.pulled = (op.pulled or 0) + 1
   local item = op.pull_queue[op.pull_idx]



   if item and op.container_stones[item.kw] and op.container_stones[item.kw][item.color] then
      op.container_stones[item.kw][item.color] = op.container_stones[item.kw][item.color] - 1
   end
   if item then item.remaining = (item.remaining or 1) - 1 end


   local color = tier_key(color_phrase) or (item and item.color)
   if color then
      op.model = op.model or {}
      op.model[#op.model + 1] = { color = color }
      renumber(op.model)
   end
   sf_touch()
   gather_pull()
end

local function hit_get_empty()
   local op = sf_op; if not op or op.phase ~= "gather" or op.gphase ~= "pull" then return end
   sf_touch()
   gather_pull_advance()
end


local function hit_carry_full()
   local op = sf_op; if not op or op.phase ~= "gather" then return end
   say("inventory full — forging what I have to free space.")
   finish_gather()
end




local function hit_put_ok(color_phrase)
   local op = sf_op; if not op or op.phase ~= "stow" then return end
   op.stowed_total = (op.stowed_total or 0) + 1
   local color = tier_key(color_phrase)
   if color and op.stow_kw then
      op.container_stones[op.stow_kw] = op.container_stones[op.stow_kw] or {}
      op.container_stones[op.stow_kw][color] = (op.container_stones[op.stow_kw][color] or 0) + 1
   end


   if color and op.model then
      for i, s in ipairs(op.model) do
         if s.color == color then table.remove(op.model, i); renumber(op.model); break end
      end
   end
   sf_touch()
   stow_next()
end

local function hit_put_empty()
   local op = sf_op; if not op or op.phase ~= "stow" then return end
   sf_touch()
   stow_done()
end





if trigger then


   trigger([[^You forge a (.+) soulstone using a (.+) soulstone as a base!]],
   function(_, result, base) hit_forge_result(result, base) end)

   trigger([[^You cast the spell to merge a (.+) soulstone and a (.+) soulstone]], function() hit_progress() end)
   trigger([[^You can't carry any more and drop a (.+) soulstone]], function() hit_progress() end)

   trigger([[^You fail to cast the spell 'soulforge'\.]], function() hit_fail() end)

   trigger([[^You must specify two different soulstones]], function() hit_bad_selection() end)
   trigger([[^You do not seem to have a soulstone by that name\.]], function() hit_bad_selection() end)

   trigger([[^You don't have enough mana]], function() hit_mana() end)




   trigger([[^\s*(?:\(\s*\d+\s*\)\s*)?an? .+ soulstone\.?\s*$]], function(line) hit_look_soulstone(line) end)


   trigger([[^You get a (.+) soulstone from ]], function(_, color) hit_get_ok(color) end)
   trigger([[^You don't see anything named '.-' in ]], function() hit_get_empty() end)
   trigger([[^You can't carry that many items]], function() hit_carry_full() end)


   trigger([[^You put a (.+) soulstone in ]], function(_, color) hit_put_ok(color) end)


   trigger([[^You aren't carrying ]], function() hit_put_empty() end)
   trigger([[^You do not seem to have that item\.]], function() hit_put_empty() end)
end




local function soulforge_start()
   if sf_op then
      say("already forging — 'soulforge off' to stop.")
      return sf_op.promise
   end
   return begin_op()
end

local function soulforge_off()
   if sf_op then say("stopping."); sf_settle(false, "cancelled")
   else say("not running.") end
end

local function soulforge_status()
   if sf_op then
      say("running" .. (sf_op.cmd and (" — last cast: " .. sf_op.cmd) or " — reading inventory…") .. ".")
   else
      say("idle. Type `soulforge` to merge low-level soulstones up toward pale/deep blue.")
   end
end




function soulforge(verb)
   verb = (verb or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
   if verb == "off" or verb == "stop" then return soulforge_off() end
   if verb == "status" then return soulforge_status() end
   return soulforge_start()
end
doc("soulforge", { sig = "soulforge(['off'|'status']) -> promise", group = "combat",
text = "Auto-merge low-level soulstones (the drops from soulsteal) upward toward pale blue — or deep " ..
"blue once pale is plentiful. First pulls soulstones out of your carried containers (pocket " ..
"dimension / sack / vortex …), then casts `soulforge` on the two best candidates and repeats " ..
"until nothing's worth merging. Prefers same-colour pairs; never merges deep/purple; keeps a " ..
"working stash of pale on hand. No arg starts it and returns a chainable promise (recover mana " ..
"| soulforge); 'off' stops; 'status' reports.",
example = "#soulforge   (or:  recover mana | soulforge)", })



if alias then
   alias([[^soulforge$]], function() soulforge() end)
   alias([[^soulforge (.+)$]], function(_, rest) soulforge(rest) end)
end











































_SF_TEST = {
   cfg = cfg,
   sent = sent,
   soulstone_color = soulstone_color,
   parse_soulstones = parse_soulstones,
   tier = tier,
   tier_key = tier_key,
   is_raw = is_raw,
   target_tier = target_tier,
   plan_next_forge = plan_next_forge,
   forge_cmd = forge_cmd,
   apply_forge = apply_forge,
   looks_like_container = looks_like_container,
   container_kw = container_kw,
   carried_containers = carried_containers,
   container_soulstone = container_soulstone,
   begin = soulforge_start,
   on_inv = function() resync_and_plan() end,
   inventory_ready = function() on_inventory() end,
   awaiting_inv = function() return sf_op ~= nil and sf_op.awaiting_inv == true end,
   forge_result = hit_forge_result,
   fail = hit_fail,
   recast = resend_cmd,
   bad_selection = hit_bad_selection,
   mana = hit_mana,
   look_soulstone = hit_look_soulstone,
   look_done = function() gather_look_done() end,
   get_ok = hit_get_ok,
   get_empty = hit_get_empty,
   carry_full = hit_carry_full,
   put_ok = hit_put_ok,
   put_empty = hit_put_empty,
   active = function() return sf_op ~= nil end,
   reset = function()
      if sf_op and sf_op.promise then sf_op.promise:cancel() end
      sf_op = nil
      clear_sent()
   end,
}
