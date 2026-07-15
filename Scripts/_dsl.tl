-- _dsl.tl — typed source for the declarative game DSL (compiles to Scripts/_dsl.lua via `tl gen`).
-- The fluent builders keep their state in a record FIELD (`cfg`) rather than a closure upvalue, so the
-- chain `field(pat):into(...):as(conv):then_(fn)` type-checks end to end — the "rewrite, don't port"
-- version of the pattern I claimed collapses to `any`. It doesn't.

local type Conv = function(string): any     -- capture transformer: number / flag / lookup / nil-to-clear

local record FieldCfg
   keys: {string}
   conv: Conv
   after: function()
end

-- field(pattern) → a builder whose :into/:as/:then_ mutate cfg, which the trigger closure reads at fire time.
local record FieldBuilder
   cfg: FieldCfg
end
function FieldBuilder:into(...: string): FieldBuilder
   for _, k in ipairs({...}) do self.cfg.keys[#self.cfg.keys + 1] = k end
   return self
end
function FieldBuilder:as(conv: Conv): FieldBuilder self.cfg.conv = conv; return self end
function FieldBuilder:via(conv: Conv): FieldBuilder self.cfg.conv = conv; return self end   -- alias, reads better for a lookup fn
function FieldBuilder:then_(fn: function()): FieldBuilder self.cfg.after = fn; return self end

-- replies(handler) → a router whose :on(pattern, outcome) fires handler(outcome) when that line appears.
local record ReplyRouter
   handler: function(any)
end
function ReplyRouter:on(pattern: string, outcome: any): ReplyRouter
   local h = self.handler
   trigger(pattern, function() h(outcome) end)
   return self
end

local record Dsl
   number:  function(string): number
   flag:    function(string): boolean
   field:   function(string): FieldBuilder
   replies: function(function(any)): ReplyRouter
   on_all:  function({string}, function())
end

local M: Dsl = {}

-- Converter sugar for `field(...):as(number)`.
function M.number(s: string): number return tonumber(s) end
-- A 0/1 kxwt flag as a boolean, for `:as(flag)`.
function M.flag(s: string): boolean return tonumber(s) == 1 end

function M.field(pattern: string): FieldBuilder
   local cfg: FieldCfg = { keys = {} }
   trigger(pattern, function(_: any, ...: string)
      if #cfg.keys == 0 then return end
      local caps = {...}                       -- cap1..capN, then the raw ANSI line last (ignored)
      for i, key in ipairs(cfg.keys) do
         local v: any = caps[i]
         if cfg.conv then v = cfg.conv(v) end
         state[key] = v
      end
      if cfg.after then cfg.after() end
   end)
   return setmetatable({ cfg = cfg } as FieldBuilder, { __index = FieldBuilder })
end

function M.replies(handler: function(any)): ReplyRouter
   return setmetatable({ handler = handler } as ReplyRouter, { __index = ReplyRouter })
end

-- on_all(patterns, fn) — bind ONE zero-arg action to a whole LIST of lines that all mean the same thing.
function M.on_all(patterns: {string}, fn: function())
   for _, p in ipairs(patterns) do trigger(p, fn) end
end

__dsl = M
return M
