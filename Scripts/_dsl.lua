-- Shared declarative DSL for the AlterAeon game scripts — small fluent registrars that let the parsing
-- and reply-routing code read like a SPECIFICATION instead of a wall of hand-rolled trigger closures.
--
-- This is NOT a game script: the `_` prefix keeps the directory loader (load("Scripts")) from
-- auto-running it, and it publishes itself on the `__dsl` global (a `__` name, so doc-coverage exempt).
-- Consumers pull it in with:  pcall(require, "_dsl"); if not __dsl then dofile("Scripts/_dsl.lua") end
-- — require() in the live client (hot-reloadable; reload() busts its cache), a dofile fallback in the
-- pure-Lua test harness (where the require searcher's host primitives are stubbed out).
--
-- EVERY helper here is a pure REGISTRAR over the host trigger() builtin: it changes how the game code
-- READS, never what it does. Each registers the SAME trigger patterns the old imperative loops did, in
-- the same order, so Swift-engine pattern specificity (which decides same-line firing order) is unchanged.

local M = {}

-- Converter sugar for `field(...):as(number)` — reads as a type annotation at the call site.
M.number = tonumber
-- A 0/1 kxwt flag as a boolean, for `:as(flag)` (sky/outdoors/overcast).
function M.flag(s) return tonumber(s) == 1 end

-- field(pattern) — declare a kxwt/text line as a spec of "these captures go into these state fields".
-- Replaces  trigger(pat, function(_, a) state.x = tonumber(a) end)  with a chain:
--     field [[^kxwt_gold (-?\d+)]] : into "gold" : as (number)
--     field [[^kxwt_prompt (\d+) (\d+) …]] : into("hp","maxhp",…) : as(number) : then_(on_vitals)
-- One trigger is registered IMMEDIATELY (so its pattern keeps its place in specificity/registration
-- order); the returned builder just mutates a config table the trigger closure reads at fire time, so the
-- :into/:as/:then_ that follow all take effect before any line ever arrives. `:as` transforming to nil
-- clears the field (e.g. an unknown walkdir code), matching the old `state[key] = conv(v)`.
function M.field(pattern)
  local cfg = { keys = {}, conv = nil, after = nil }
  trigger(pattern, function(_, ...)
    if #cfg.keys == 0 then return end
    local caps = { ... }                       -- cap1..capN, then the raw ANSI line last (ignored)
    for i, key in ipairs(cfg.keys) do
      local v = caps[i]
      if cfg.conv then v = cfg.conv(v) end
      state[key] = v
    end
    if cfg.after then cfg.after() end
  end)
  local b = {}
  function b:into(...) for _, k in ipairs({ ... }) do cfg.keys[#cfg.keys + 1] = k end; return self end
  function b:as(conv)   cfg.conv  = conv; return self end   -- transform every capture (number/flag/…)
  function b:via(conv)  cfg.conv  = conv; return self end   -- alias of :as, reads better for a lookup fn
  function b:then_(fn)  cfg.after = fn;   return self end   -- side effect to run after the assignment
  return b
end

-- replies(handler) — a fluent reply ROUTER. Each :on(pattern, outcome) registers a trigger that calls
-- handler(outcome) when that game line appears, so a table of "line -> outcome" reads as data:
--     replies(minion_cast_settled)
--       : on([[^You repair the damage to .+'s body\.$]], "ok")
--       : on([[^.+ doesn't need that much healing right now\.$]], "full")
-- Chainable; registration order is preserved (same as the old  for _,r in ipairs(CAST_REPLIES)  loop).
function M.replies(handler)
  local r = {}
  function r:on(pattern, outcome)
    trigger(pattern, function() handler(outcome) end)
    return self
  end
  return r
end

-- on_all(patterns, fn) — bind ONE zero-arg action to a whole LIST of lines that all mean the same thing
-- (e.g. every "this harvest step is finished" terminal). Reads as "any of these -> do fn".
function M.on_all(patterns, fn)
  for _, p in ipairs(patterns) do trigger(p, fn) end
end

__dsl = M
return M
