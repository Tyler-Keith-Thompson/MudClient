







































































local function mk(run,
   print_)
   local p = { run = run }
   p.print = function(_self, v)
      return print_(v)
   end
   p.map = function(self, conv)
      return mk(
      function(s, pos)
         local r = self.run(s, pos)
         if not r.ok then
            return { ok = false, pos = r.pos, label = r.label }
         end
         return { ok = true, value = conv.apply(r.value), pos = r.pos }
      end,
      function(u)
         return self:print(conv.unapply(u))
      end)

   end
   p.mapf = function(self, f)
      return mk(
      function(s, pos)
         local r = self.run(s, pos)
         if not r.ok then
            return { ok = false, pos = r.pos, label = r.label }
         end
         return { ok = true, value = f(r.value), pos = r.pos }
      end,
      function(_u)
         return { ok = false, err = "not printable: built with mapf (a one-way transform) — use map(Conversion) for a printable pipeline" }
      end)

   end
   p.flatMap = function(self, f)
      return mk(
      function(s, pos)
         local r = self.run(s, pos)
         if not r.ok then
            return { ok = false, pos = r.pos, label = r.label }
         end
         return f(r.value).run(s, r.pos)
      end,
      function(_u)
         return { ok = false, err = "not printable: built with flatMap (a one-way transform)" }
      end)

   end
   p.skip = function(self, other)
      return mk(
      function(s, pos)
         local r = self.run(s, pos)
         if not r.ok then return r end
         local r2 = other.run(s, r.pos)
         if not r2.ok then
            return { ok = false, pos = r2.pos, label = r2.label }
         end
         return { ok = true, value = r.value, pos = r2.pos }
      end,
      function(t)
         local pr1 = self:print(t)
         if not pr1.ok then return pr1 end



         local pr2 = other:print(nil)
         if not pr2.ok then return pr2 end
         return { ok = true, text = pr1.text .. pr2.text }
      end)

   end
   p.take = function(self, other)
      return mk(
      function(s, pos)
         local r = self.run(s, pos)
         if not r.ok then
            return { ok = false, pos = r.pos, label = r.label }
         end
         return other.run(s, r.pos)
      end,
      function(u)
         local pr2 = other:print(u)
         if not pr2.ok then return pr2 end

         local pr1 = self:print(nil)
         if not pr1.ok then return pr1 end
         return { ok = true, text = pr1.text .. pr2.text }
      end)

   end
   p.opt = function(self, default)
      return mk(
      function(s, pos)
         local r = self.run(s, pos)
         if r.ok then return r end
         return { ok = true, value = default, pos = pos }
      end,
      function(t)
         local pr = self:print(t)
         if pr.ok then return pr end
         return { ok = true, text = "" }
      end)

   end
   return p
end



local UNIT = {}



local function succeed(v)
   return mk(
   function(_s, pos)
      return { ok = true, value = v, pos = pos }
   end,
   function(_t)
      return { ok = true, text = "" }
   end)

end



local function fail(label)
   return mk(
   function(_s, pos)
      return { ok = false, pos = pos, label = label }
   end,
   function(_t)
      return { ok = false, err = "not printable: unconditional fail(\"" .. label .. "\")" }
   end)

end





local function lit(match)
   return mk(
   function(s, pos)
      if s:sub(pos, pos + #match - 1) == match then
         return { ok = true, value = UNIT, pos = pos + #match }
      end
      return { ok = false, pos = pos, label = "\"" .. match .. "\"" }
   end,
   function(_u)
      return { ok = true, text = match }
   end)

end





local function pat(pattern, label)
   return mk(
   function(s, pos)
      local m = s:match("^(" .. pattern .. ")", pos)
      if m then
         return { ok = true, value = m, pos = pos + #m }
      end
      return { ok = false, pos = pos, label = label }
   end,
   function(v)
      if v:match("^" .. pattern .. "$") then
         return { ok = true, text = v }
      end
      return { ok = false, err = "value " .. v .. " does not match pattern for " .. label }
   end)

end

local number_conv = {
   apply = function(s) return tonumber(s) or 0.0 end,
   unapply = function(n) return tostring(n) end,
}

local flag_conv = {
   apply = function(s) return tonumber(s) == 1 end,
   unapply = function(b) if b then return "1" else return "0" end end,
}

local int_conv = {
   apply = function(s) return math.tointeger(tonumber(s)) or 0 end,
   unapply = function(n) return tostring(n) end,
}



local digits = pat("%d+", "digits"):map(int_conv)


local int_parser = pat("%-?%d+", "integer"):map(int_conv)


local number_parser = pat("%-?%d+%.?%d*", "number"):map(number_conv)




local function prefix_up_to(sep)
   return mk(
   function(s, pos)
      local found = s:find(sep, pos, true)
      local stop = found and (found - 1) or #s
      return { ok = true, value = s:sub(pos, stop), pos = stop + 1 }
   end,
   function(v)
      if v:find(sep, 1, true) then
         return { ok = false, err = "value contains delimiter \"" .. sep .. "\"" }
      end
      return { ok = true, text = v }
   end)

end


local rest_of_input = mk(
function(s, pos)
   return { ok = true, value = s:sub(pos), pos = #s + 1 }
end,
function(v)
   return { ok = true, text = v }
end)




local end_of_input = mk(
function(s, pos)
   if pos > #s then
      return { ok = true, value = UNIT, pos = pos }
   end
   return { ok = false, pos = pos, label = "end of input" }
end,
function(_u)
   return { ok = true, text = "" }
end)









local function oneOf(...)
   local alts = { ... }
   return mk(
   function(s, pos)
      local lastLabel = "no alternatives"
      for i = 1, #alts do
         local r = alts[i].run(s, pos)
         if r.ok then return r end
         lastLabel = r.label
      end
      return { ok = false, pos = pos, label = lastLabel }
   end,
   function(t)
      local lastErr = "no alternatives"
      for i = 1, #alts do
         local pr = alts[i]:print(t)
         if pr.ok then return pr end
         lastErr = pr.err
      end
      return { ok = false, err = lastErr }
   end)

end




local function many(element, sep)
   return mk(
   function(s, pos)
      local out = {}
      local cur = pos
      while true do
         local r = element.run(s, cur)
         if not r.ok then break end
         out[#out + 1] = r.value
         cur = r.pos
         if sep then
            local rs = sep.run(s, cur)
            if not rs.ok then break end
            cur = rs.pos
         end
      end
      return { ok = true, value = out, pos = cur }
   end,
   function(xs)
      local text = ""
      for i = 1, #xs do
         if i > 1 and sep then
            local sepr = sep:print(UNIT)
            if not sepr.ok then return sepr end
            text = text .. sepr.text
         end
         local er = element:print(xs[i])
         if not er.ok then return er end
         text = text .. er.text
      end
      return { ok = true, text = text }
   end)

end



local function many1(element, sep)
   return mk(
   function(s, pos)
      local r1 = element.run(s, pos)
      if not r1.ok then
         return { ok = false, pos = r1.pos, label = r1.label }
      end
      local out = { r1.value }
      local cur = r1.pos
      while true do
         local rs = sep.run(s, cur)
         if not rs.ok then break end
         local re = element.run(s, rs.pos)
         if not re.ok then break end
         out[#out + 1] = re.value
         cur = re.pos
      end
      return { ok = true, value = out, pos = cur }
   end,
   function(xs)
      if #xs == 0 then
         return { ok = false, err = "at least one element required" }
      end
      local text = ""
      for i = 1, #xs do
         if i > 1 then
            local sepr = sep:print(UNIT)
            if not sepr.ok then return sepr end
            text = text .. sepr.text
         end
         local er = element:print(xs[i])
         if not er.ok then return er end
         text = text .. er.text
      end
      return { ok = true, text = text }
   end)

end





local function seq2(pa, pb,
   combine,
   uncombine)
   return mk(
   function(s, pos)
      local ra = pa.run(s, pos)
      if not ra.ok then return { ok = false, pos = ra.pos, label = ra.label } end
      local rb = pb.run(s, ra.pos)
      if not rb.ok then return { ok = false, pos = rb.pos, label = rb.label } end
      return { ok = true, value = combine(ra.value, rb.value), pos = rb.pos }
   end,
   function(r)
      local a, b = uncombine(r)
      local pra = pa:print(a)
      if not pra.ok then return pra end
      local prb = pb:print(b)
      if not prb.ok then return prb end
      return { ok = true, text = pra.text .. prb.text }
   end)

end

local function seq3(pa, pb, pc,
   combine,
   uncombine)
   return mk(
   function(s, pos)
      local ra = pa.run(s, pos)
      if not ra.ok then return { ok = false, pos = ra.pos, label = ra.label } end
      local rb = pb.run(s, ra.pos)
      if not rb.ok then return { ok = false, pos = rb.pos, label = rb.label } end
      local rc = pc.run(s, rb.pos)
      if not rc.ok then return { ok = false, pos = rc.pos, label = rc.label } end
      return { ok = true, value = combine(ra.value, rb.value, rc.value), pos = rc.pos }
   end,
   function(r)
      local a, b, c = uncombine(r)
      local pra = pa:print(a)
      if not pra.ok then return pra end
      local prb = pb:print(b)
      if not prb.ok then return prb end
      local prc = pc:print(c)
      if not prc.ok then return prc end
      return { ok = true, text = pra.text .. prb.text .. prc.text }
   end)

end

local function seq4(pa, pb, pc, pd,
   combine,
   uncombine)
   return mk(
   function(s, pos)
      local ra = pa.run(s, pos)
      if not ra.ok then return { ok = false, pos = ra.pos, label = ra.label } end
      local rb = pb.run(s, ra.pos)
      if not rb.ok then return { ok = false, pos = rb.pos, label = rb.label } end
      local rc = pc.run(s, rb.pos)
      if not rc.ok then return { ok = false, pos = rc.pos, label = rc.label } end
      local rd = pd.run(s, rc.pos)
      if not rd.ok then return { ok = false, pos = rd.pos, label = rd.label } end
      return { ok = true, value = combine(ra.value, rb.value, rc.value, rd.value), pos = rd.pos }
   end,
   function(r)
      local a, b, c, d = uncombine(r)
      local pra = pa:print(a)
      if not pra.ok then return pra end
      local prb = pb:print(b)
      if not prb.ok then return prb end
      local prc = pc:print(c)
      if not prc.ok then return prc end
      local prd = pd:print(d)
      if not prd.ok then return prd end
      return { ok = true, text = pra.text .. prb.text .. prc.text .. prd.text }
   end)

end




local parse_all
local print_all





local function parser_as_conversion(p)
   return {
      apply = function(s)
         local v = parse_all(p, s)
         return v
      end,
      unapply = function(v)
         local s = print_all(p, v)
         return s
      end,
   }
end




parse_all = function(p, s)
   local r = p:skip(end_of_input).run(s, 1)
   if r.ok then return r.value, nil end
   return nil, ("expected " .. r.label .. " at byte " .. tostring(r.pos))
end


print_all = function(p, v)
   local pr = p:print(v)
   if pr.ok then return pr.text, nil end
   return nil, pr.err
end


local M = {
   UNIT = UNIT,
   succeed = succeed,
   fail = fail,
   lit = lit,
   pat = pat,
   digits = digits,
   int_parser = int_parser,
   number_parser = number_parser,
   prefix_up_to = prefix_up_to,
   rest_of_input = rest_of_input,
   end_of_input = end_of_input,
   number_conv = number_conv,
   flag_conv = flag_conv,
   parser_as_conversion = parser_as_conversion,
   oneOf = oneOf,
   many = many,
   many1 = many1,
   seq2 = seq2,
   seq3 = seq3,
   seq4 = seq4,
   parse_all = parse_all,
   print_all = print_all,
}
__parse = M

_PARSE_TEST = { mk = mk }

return M
