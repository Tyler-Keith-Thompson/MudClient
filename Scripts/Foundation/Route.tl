-- Route.tl — tiny declarative first-match dispatcher (the `__route` analog of __dsl/__rx/__di), for
-- priority-router scripts (see Scripts/CLAUDE.md's "Priority-router / message-dispatcher" shape) that
-- want to read as a table of `{ predicate, handler }` cases instead of an if/elseif chain.
--
--   on_prompt = route({
--     { is_fighting_bar, handle_fighting },   -- first match wins
--     { is_hud_prompt,   apply_prompt },
--     { any,             reinject },
--   })
--
-- route(cases) returns a dispatcher: calling it runs the FIRST case whose predicate(value) is truthy,
-- passing value to that case's handler, and returns the handler's result unchanged — so a case can
-- behave exactly like a trigger handler (return a rewrite / false-to-gag / nil). Cases are plain
-- `{predicate, handler}` pairs (a named record would force `{pred=, run=}` at every call site instead
-- of this flatter, table-literal-shaped syntax), untyped past that since a predicate/handler pair is
-- heterogeneous by nature.
local type Case = {any}

local function route(cases: {Case}): function(any): any...
   return function(value: any): any...
      for _, c in ipairs(cases) do
         local pred = c[1] as function(any): boolean
         if pred(value) then return (c[2] as function(any): any...)(value) end
      end
   end
end

-- Always-true sentinel predicate for a catch-all fallthrough case.
local function any(_: any): boolean return true end

local M = { route = route, any = any }
__route = M
return M
