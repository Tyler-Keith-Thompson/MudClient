-- Specs for cry of victory (Combat.lua). The `victory` warcry is cried automatically off the game's OWN
-- "You feel victorious!" line — a positive signal the server prints only when YOU land a killing blow
-- worth crowing over (verified in human-traces.jsonl: it never appears for a summon/minion's death, only
-- your own kills). The "You feel victorious!" TRIGGER that feeds it runs in Swift; here we test the pure
-- maybe_victory decision: the on/off flag and the multi-kill dedup.

local AA = _AA_TEST

local function with_state(st, fn)
  local saved_state, saved_send = state, send
  local sent = {}
  state = st
  send = function(c) sent[#sent + 1] = c end
  AA.reset_victory()
  local ok, err = pcall(function() fn(sent) end)
  state, send = saved_state, saved_send
  if not ok then error(err, 2) end
end

test("cries victory when auto_victory is on", function()
  with_state({ auto_victory = true }, function(sent)
    AA.maybe_victory(1000)
    expect(sent[1]):eq("victory")
  end)
end)

test("does NOT cry when auto_victory is off", function()
  with_state({ auto_victory = false }, function(sent)
    AA.maybe_victory(1000)
    expect(#sent):eq(0)
  end)
end)

test("a summon/minion death alone never reaches maybe_victory (only 'You feel victorious!' does)", function()
  -- No ally/engaged gating anymore: the game's own signal already guarantees it's YOUR kill, so a
  -- summon's "is DEAD!" line is never even routed here (see AutoFight/Combat: the trigger is on the
  -- literal "You feel victorious!" text, not on "is DEAD!"). Nothing to assert on maybe_victory itself
  -- beyond: it fires whenever it's called and auto_victory is on.
  with_state({ auto_victory = true }, function(sent)
    AA.maybe_victory(1000)
    expect(sent[1]):eq("victory")
  end)
end)

test("dedups a multi-kill round into one cry, then allows another after the window", function()
  with_state({ auto_victory = true }, function(sent)
    AA.maybe_victory(1000)
    AA.maybe_victory(1001)     -- same round, within VICTORY_DEDUP -> suppressed
    expect(#sent):eq(1)
    AA.maybe_victory(1003)     -- 3s later -> allowed again
    expect(#sent):eq(2)
  end)
end)
