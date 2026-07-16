

















local function route(cases)
   return function(value)
      for _, c in ipairs(cases) do
         local pred = c[1]
         if pred(value) then return (c[2])(value) end
      end
   end
end


local function any(_) return true end

local M = { route = route, any = any }
__route = M
return M
