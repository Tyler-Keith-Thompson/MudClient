-- Specs for auto-assist (AlterAeon.lua). When your minions are fighting an enemy but you're not in the
-- melee round yourself (engaged() true from combat text, but state.fighting false — the "dimmed target"
-- state), we `assist` to jump in. The melee-round TRIGGER that detects the enemy and calls maybe_assist
-- runs in Swift; here we test the pure maybe_assist decision + debounce.

local AA = _AA_TEST

local function with_combat(fighting, auto, fn)
  local saved_state, saved_send = state, send
  local sent = {}
  state = { fighting = fighting, auto_assist = auto }
  send = function(c) sent[#sent + 1] = c end
  AA.reset_assist()
  local ok, err = pcall(function() fn(sent) end)
  state, send = saved_state, saved_send
  if not ok then error(err, 2) end
end

test("assists when your side is fighting but you're NOT in the melee round", function()
  with_combat(false, true, function(sent)
    AA.maybe_assist(1000)
    expect(sent[1]):eq("assist")
  end)
end)

test("does NOT assist when you're already in the melee round (state.fighting)", function()
  with_combat(true, true, function(sent)
    AA.maybe_assist(1000)
    expect(#sent):eq(0)
  end)
end)

test("does NOT assist when auto-assist is off", function()
  with_combat(false, false, function(sent)
    AA.maybe_assist(1000)
    expect(#sent):eq(0)
  end)
end)

test("latches: fires ONCE per fight (the burst of melee lines can't re-assist); re-arms after the fight ends", function()
  with_combat(false, true, function(sent)
    AA.maybe_assist()            -- jump into the fight → assist
    AA.maybe_assist()            -- same fight, latched → nothing (rounds fire many times/sec)
    AA.maybe_assist()            -- still latched → nothing (this was the "assist fired again at the tail" bug)
    expect(#sent):eq(1)
    AA.reset_assist()            -- the fight ended (over RPC, ncombat clears state.assisted)
    AA.maybe_assist()            -- next fight → assists again
    expect(#sent):eq(2)
  end)
end)
