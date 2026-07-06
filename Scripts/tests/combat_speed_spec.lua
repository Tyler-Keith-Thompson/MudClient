-- Specs for the combat speed path: a combat turn must cap generation at cfg.combat_max_tokens (a
-- command is ~5-15 tokens; the full 256 is wasteful) and, on the LOCAL path, must send the LEAN prompt
-- (no MAP / NOTES blocks) rather than the full one. We drive the real take_turn_decide and intercept the
-- ai_request call to read the max_tokens it passes and the user prompt it built.

local P   = _AIP_TEST.P
local cfg = _AIP_TEST.cfg

-- Capture the (sys, user, max_tokens, tools) ai_request receives during one take_turn_decide, without
-- running the model (the stub never invokes the callback). Restores all touched globals/state.
local function capture(fighting, use_tools)
  local real_req = ai_request
  local seen = {}
  ai_request = function(sys, user, max_tokens, tools, prefill, cb)
    seen = { sys = sys, user = user, max_tokens = max_tokens, tools = tools }
  end
  local saved = { eu = state.engaged_until, ut = cfg.use_tools,
                  seq = P.snap_seq, sf = P.snap_fighting, pend = P.pending, nudge = P.nudge }
  cfg.use_tools = use_tools
  state.engaged_until = fighting and (os.time() + 100) or nil
  local ok, err = pcall(take_turn_decide)
  ai_request = real_req
  state.engaged_until, cfg.use_tools, P.snap_seq, P.snap_fighting, P.pending, P.nudge =
    saved.eu, saved.ut, saved.seq, saved.sf, saved.pend, saved.nudge
  if not ok then error(err, 2) end
  return seen
end

test("a combat turn caps generation at cfg.combat_max_tokens, not the full max_tokens", function()
  local seen = capture(true, false)
  expect(seen.max_tokens):eq(cfg.combat_max_tokens)
  expect(cfg.combat_max_tokens < cfg.max_tokens):truthy()   -- it really is a lower cap
end)

test("a non-combat turn uses the full max_tokens", function()
  local seen = capture(false, false)
  expect(seen.max_tokens):eq(cfg.max_tokens)
end)

test("the LOCAL combat prompt is lean — drops the MAP / NOTES blocks the full prompt carries", function()
  local seen = capture(true, false)
  expect(seen.user:find("MAP / WHAT YOU KNOW", 1, true)):falsy()
  expect(seen.user:find("NOTES YOU'VE SAVED", 1, true)):falsy()
  expect(seen.user:find("CHARACTER STATE", 1, true)):truthy()     -- state is still there
  expect(seen.user:find("IN COMBAT", 1, true)):truthy()           -- and the combat closer
end)
