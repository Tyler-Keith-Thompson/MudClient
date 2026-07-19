-- Group roster parsing from the framed `;sgroup;` RPC event (DClientProbe.handle_group), the SINGLE writer
-- of state.group / the HUD roster. The name's DELIMITER encodes ownership: `-min-` = YOUR minion (flag M),
-- `.min.` = another player's minion (O), and a BARE name = a grouped PLAYER (P). All three must land in the
-- roster — grouped players (Latoya) and their pets used to be dropped because the parser matched only `-x-`.

local AA = _AA_TEST

-- Feed one complete `;sgroup;...;egroup;` frame through the live streaming parser and return state.group.
local function feed_group(members)
  local saved_on, saved_name, saved_group = AA.dclient.on, state.name, state.group
  AA.dclient.on = true
  AA.dclient.buf = ""
  state.name = "Vaelith"
  AA.dclient_feed(";sgroup;" .. members .. ";egroup;")
  local g = state.group
  AA.dclient.on, state.name, state.group = saved_on, saved_name, saved_group
  return g
end

test("sgroup roster keeps grouped players and others' minions, not just your own", function()
  local g = feed_group(
    "810 810 480 480 320 320 Latoya\r\n" ..                 -- bare name  → a grouped PLAYER
    "221 380 4 4 295 295 .A clay man.\r\n" ..               -- .name.     → another player's minion
    "225 225 4 4 256 256 -A fiery skeletal lich-\r\n" ..    -- -name-     → your minion
    "471 471 4 4 317 317 -A mummy-")                        -- -name-     → your minion

  expect(g[1].name):eq("Vaelith")                           -- self is prepended as row 1
  expect(g[1].is_self):truthy()

  expect(g[2].name):eq("Latoya")                            -- the grouped player is now IN the roster
  expect(g[2].flags):eq("P")
  expect(g[2].hp):eq(810)
  expect(g[2].maxmana):eq(480)

  expect(g[3].name):eq("A clay man")                        -- another player's minion, tagged O
  expect(g[3].flags):eq("O")

  expect(g[4].name):eq("A fiery skeletal lich")             -- your minions stay tagged M (cyan in the HUD)
  expect(g[4].flags):eq("M")
  expect(g[5].name):eq("A mummy")
  expect(g[5].flags):eq("M")

  expect(#g):eq(5)                                          -- self + 4 members, none dropped
end)

test("kxwt-supplied flags still win over the delimiter-derived kind", function()
  local saved = state.group_flags
  state.group_flags = { Latoya = "PL" }                      -- kxwt says Latoya is the group LEADER
  local g = feed_group("810 810 480 480 320 320 Latoya")
  state.group_flags = saved
  expect(g[2].name):eq("Latoya")
  expect(g[2].flags):eq("PL")                                -- flags_for wins; not the bare-name "P" default
end)
