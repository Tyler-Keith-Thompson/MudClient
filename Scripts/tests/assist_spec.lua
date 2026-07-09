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

test("debounces: a repeat within the cooldown is suppressed; allowed again after it", function()
  with_combat(false, true, function(sent)
    AA.maybe_assist(1000)        -- assist
    AA.maybe_assist(1001)        -- within the 3s cooldown → nothing (rounds fire many times/sec)
    AA.maybe_assist(1002)        -- still within → nothing
    AA.maybe_assist(1005)        -- past the cooldown → assist again
    expect(#sent):eq(2)
    expect(sent[1]):eq("assist")
    expect(sent[2]):eq("assist")
  end)
end)
