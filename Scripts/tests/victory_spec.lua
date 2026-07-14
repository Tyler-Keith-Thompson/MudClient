-- Specs for cry of victory (Combat.lua). The `victory` warcry is cried automatically the instant a
-- non-ally mob dies while we're engaged. The "<name> is DEAD!" TRIGGER that feeds it runs in Swift;
-- here we test the pure maybe_victory decision: the on/off flag, the ally + engaged gates, and the
-- multi-kill dedup. engaged() is driven off state.fighting / state.engaged_until, so we set those.

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

test("cries victory when a non-ally dies and we're engaged", function()
  with_state({ auto_victory = true, fighting = true }, function(sent)
    AA.maybe_victory("A goblin", 1000)
    expect(sent[1]):eq("victory")
  end)
end)

test("does NOT cry when auto_victory is off", function()
  with_state({ auto_victory = false, fighting = true }, function(sent)
    AA.maybe_victory("A goblin", 1000)
    expect(#sent):eq(0)
  end)
end)

test("does NOT cry for an ally/minion death (is_ally)", function()
  with_state({ auto_victory = true, fighting = true, name = "Vaelith",
               group = { { name = "a skeletal spider" } } }, function(sent)
    AA.maybe_victory("a skeletal spider", 1000)   -- our own minion
    expect(#sent):eq(0)
    AA.maybe_victory("Vaelith", 1000)             -- ourselves
    expect(#sent):eq(0)
  end)
end)

test("does NOT cry when not engaged (no fight to be victorious over)", function()
  with_state({ auto_victory = true, fighting = false, engaged_until = 0 }, function(sent)
    AA.maybe_victory("A goblin", 5000)   -- engaged_until 0 < now -> not engaged
    expect(#sent):eq(0)
  end)
end)

test("cries when engaged via the text window (engaged_until), not just kxwt fighting", function()
  with_state({ auto_victory = true, fighting = false, engaged_until = 2000 }, function(sent)
    AA.maybe_victory("A goblin", 1500)   -- now 1500 < engaged_until 2000 -> engaged
    expect(sent[1]):eq("victory")
  end)
end)

test("dedups a multi-kill round into one cry, then allows another after the window", function()
  with_state({ auto_victory = true, fighting = true }, function(sent)
    AA.maybe_victory("A goblin", 1000)
    AA.maybe_victory("An orc", 1001)     -- same round, within VICTORY_DEDUP -> suppressed
    expect(#sent):eq(1)
    AA.maybe_victory("A troll", 1003)    -- 3s later -> allowed again
    expect(#sent):eq(2)
  end)
end)
