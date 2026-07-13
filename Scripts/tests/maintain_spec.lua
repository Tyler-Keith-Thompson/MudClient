-- Specs for AlterAeon.lua's auto-maintain: when a maintainable spell lands (kxwt_spellup), issue
-- `maintain <spell>` exactly once. The trigger regex runs in Swift; here we drive the pure helper
-- `maybe_maintain` it calls and assert on the OBSERVABLE `send` sequence.

local maybe_maintain = _AA_TEST.maybe_maintain
local MAINTAINABLE   = _AA_TEST.MAINTAINABLE

-- Run `body` with a captured `send` and a fresh `state`, restoring both afterwards. Returns the list
-- of commands sent.
local function with_capture(body)
  local saved_send, saved_state = send, state
  local sent = {}
  send = function(c) sent[#sent + 1] = c end
  state = { maintained = {} }
  local ok, err = pcall(body)
  send, state = saved_send, saved_state
  if not ok then error(err) end
  return sent
end

test("maybe_maintain sends `maintain <spell>` for a maintainable spell", function()
  local sent = with_capture(function()
    maybe_maintain("dread portent")
  end)
  expect(#sent):eq(1)
  expect(sent[1]):eq("maintain dread portent")
end)

test("maybe_maintain ignores a spell the maintaining skill can't hold", function()
  local sent = with_capture(function()
    maybe_maintain("fire shield")   -- a real buff, but NOT maintainable
    maybe_maintain("mana shield")
  end)
  expect(#sent):eq(0)
end)

test("maybe_maintain fires only ONCE per spell — a re-up doesn't re-send", function()
  local sent = with_capture(function()
    maybe_maintain("fly")
    maybe_maintain("fly")   -- same spell up again (recast / score reconcile) → no second maintain
  end)
  expect(#sent):eq(1)
  expect(sent[1]):eq("maintain fly")
end)

test("clearing the maintained flag (spelldown) lets a returning spell be re-maintained", function()
  local sent = with_capture(function()
    maybe_maintain("infravision")
    state.maintained["infravision"] = nil   -- what the kxwt_spelldown handler does
    maybe_maintain("infravision")
  end)
  expect(#sent):eq(2)
  expect(sent[1]):eq("maintain infravision")
  expect(sent[2]):eq("maintain infravision")
end)

test("maybe_maintain matches case-insensitively on the spell name", function()
  local sent = with_capture(function()
    maybe_maintain("Walk On Water")
  end)
  expect(#sent):eq(1)
  expect(sent[1]):eq("maintain Walk On Water")   -- sent verbatim as reported by kxwt
end)

test("the maintainable set is exactly the 13 spells from `help maintaining spells`", function()
  local expected = {
    "armor aegis", "detect invisibility", "detect evil", "infravision", "sense life", "fly",
    "water breathing", "darken", "detect undead", "dread portent", "unburden", "walk on water",
    "feather fall",
  }
  local n = 0
  for _ in pairs(MAINTAINABLE) do n = n + 1 end
  expect(n):eq(#expected)
  for _, name in ipairs(expected) do expect(MAINTAINABLE[name]):eq(true) end
end)
