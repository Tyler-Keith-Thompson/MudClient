-- Specs for the after-kill corpse automation (AlterAeon.lua): the invariant that a corpse still holding
-- loot we couldn't auto-take is NEVER sacrificed. The trigger REGEXES that set `dirty` (binding object /
-- can't-carry / must-get-by-name) run in Swift; here we test the pure decision in corpse_finish given
-- the flag. (This is the "sacrificed a corpse with a binding medallion in it" bug.)

local corpse = _AA_TEST.corpse

-- Run `fn(sent)` with the corpse table set to `fields` and `send` capturing, then restore both.
local function with_corpse(fields, fn)
  local saved_send, sent = send, {}
  send = function(c) sent[#sent + 1] = c end
  local snap = {}; for k, v in pairs(corpse) do snap[k] = v end
  for k, v in pairs(fields) do corpse[k] = v end
  local ok, err = pcall(function() fn(sent) end)
  send = saved_send
  for k in pairs(corpse) do corpse[k] = nil end
  for k, v in pairs(snap) do corpse[k] = v end
  if not ok then error(err, 2) end
end

test("a DIRTY corpse (loot left behind, e.g. a binding object) is NOT sacrificed", function()
  with_corpse({ on = true, active = true, idx = 1, dirty = true }, function(sent)
    corpse_finish()
    for _, c in ipairs(sent) do
      expect(c:find("^bsac") == nil):eq(true)    -- never blood-sacrificed
      expect(c:find("^sac ") == nil):eq(true)    -- never sacrificed
    end
    expect(corpse.idx):eq(2)                      -- stepped PAST the dirty corpse, leaving it intact
  end)
end)

test("a CLEAN corpse is blood-sacrificed", function()
  with_corpse({ on = true, active = true, idx = 1, dirty = false }, function(sent)
    corpse_finish()
    expect(sent[1]):eq("bsac 1.corpse")
  end)
end)
