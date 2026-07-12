-- Specs for the AlterAeon waypoint/recall parsing (AIPilot.lua). The formats here are copied verbatim
-- from real game output captured in the human traces, so these lock the parser to reality.

local parse = _AIP_TEST.parse_waypoint_list
local recall_failed = _AIP_TEST.recall_failed

test("parse_waypoint_list reads in-range, bridged, and no-bridge rows", function()
  local text = table.concat({
    "You can travel to the following waypoints:",
    "1 - A heavily warded waypoint",
    "3 - A large waypoint in a stony field",
    "4 - The Pellam Cemetery Waypoint",
    "6 (bridge  4) - The Temple of Zin",
    "15 (no bridge) - The Dragon Tooth Waypoint",
    "",
  }, "\n")
  local wp = parse(text)
  expect(#wp):eq(5)

  expect(wp[1].num):eq(1)
  expect(wp[1].name):eq("A heavily warded waypoint")
  expect(wp[1].reachable):truthy()
  expect(wp[1].bridge):falsy()

  expect(wp[4].num):eq(6)
  expect(wp[4].name):eq("The Temple of Zin")
  expect(wp[4].reachable):falsy()
  expect(wp[4].bridge):eq(4)              -- must hop to waypoint 4 first

  expect(wp[5].num):eq(15)
  expect(wp[5].reachable):falsy()
  expect(wp[5].bridge):falsy()            -- out of range, no bridge
end)

test("parse_waypoint_list ignores non-row lines (headers, quest log, prose)", function()
  local text = table.concat({
    "Waypoints are a quick way to get from place to place.",
    " 20 Completed a few tasks given by the ranger in Naphtali.",  -- quest line: number but no ' - '
    "2 - A large waypoint in a stony field",
    "[Exits: east south ]",
  }, "\n")
  local wp = parse(text)
  expect(#wp):eq(1)
  expect(wp[1].num):eq(2)
end)

test("recall_failed detects the fizzle line and nothing else", function()
  expect(recall_failed("No god responds to your call.")):truthy()
  expect(recall_failed("You pray to the gods for transportation...")):falsy()
  expect(recall_failed("The Pellam Cemetery Waypoint")):falsy()
end)

test("learn_waypoint records number<->room both ways and re-points on reorder", function()
  local P = _AIP_TEST.P
  local num_for = _AIP_TEST.waypoint_num_for_room
  local nearest = _AIP_TEST.nearest_waypoint_for
  local saved = { rooms = P.rooms, cur = P.current_room, wp = P.waypoints, wr = P.wp_room, rw = P.room_wp }
  P.rooms = { RX = { moves = {}, marks = { forge = true } }, RY = { moves = {} } }
  P.waypoints, P.wp_room, P.room_wp = nil, nil, nil
  P.current_room = "RY"
  _AIP_TEST.learn_waypoint(4, "RX")
  expect(num_for("RX")):eq(4)                       -- number now resolvable for that room
  expect(nearest("forge")):eq("RX")                -- travelling there proved it's a waypoint (routable as one)
  _AIP_TEST.learn_waypoint(4, "RY")                 -- reorder: number 4 now reaches RY
  expect(num_for("RY")):eq(4)                       -- RY resolves to 4...
  expect(num_for("RX")):falsy()                    -- ...and RX's stale number is dropped
  P.rooms, P.current_room, P.waypoints, P.wp_room, P.room_wp =
    saved.rooms, saved.cur, saved.wp, saved.wr, saved.rw
end)

test("nearest_waypoint_for picks the waypoint fewest walk-steps from the mark", function()
  local P = _AIP_TEST.P
  local saved = { rooms = P.rooms, cur = P.current_room }
  P.rooms = {
    WP_A = { moves = { east = "M" }, waypoint = true },            -- 1 step to the mark
    WP_B = { moves = { east = "X" }, waypoint = true },            -- 2 steps to the mark
    X    = { moves = { west = "WP_B", east = "M" } },
    M    = { moves = { west = "X" }, marks = { trainer = true } },
  }
  P.current_room = "elsewhere"
  expect(_AIP_TEST.nearest_waypoint_for("trainer")):eq("WP_A")
  P.rooms, P.current_room = saved.rooms, saved.cur
end)

test("goto bridge auto-hops using a LEARNED number (no description matching)", function()
  local P = _AIP_TEST.P
  local saved = { rooms = P.rooms, cur = P.current_room, wr = P.wp_room, rw = P.room_wp, br = P.goto_bridge }
  local real_send, sent = send, nil
  send = function(c) sent = c end
  P.rooms = {
    HERE = { moves = {}, waypoint = true },                       -- on a waypoint, mark not walkable
    DEST = { moves = { east = "M" }, waypoint = true },
    M    = { moves = { west = "DEST" }, marks = { trainer = true } },
  }
  P.current_room = "HERE"
  P.wp_room, P.room_wp = { [7] = "DEST" }, { DEST = 7 }             -- learned: waypoint 7 -> DEST
  P.goto_bridge = { label = "trainer", target_wp = "DEST", tries = 0, hops = 0 }
  goto_bridge_advance()
  expect(sent):eq("waypoint 7")
  send = real_send
  P.rooms, P.current_room = saved.rooms, saved.cur
  P.wp_room, P.room_wp, P.goto_bridge = saved.wr, saved.rw, saved.br
end)

test("goto bridge hands off (no blind hop) when the target number is unknown", function()
  local P = _AIP_TEST.P
  local saved = { rooms = P.rooms, cur = P.current_room, wr = P.wp_room, rw = P.room_wp, br = P.goto_bridge }
  local real_send, sent = send, nil
  send = function(c) sent = c end
  P.rooms = {
    HERE = { moves = {}, waypoint = true },
    DEST = { moves = { east = "M" }, waypoint = true },
    M    = { moves = { west = "DEST" }, marks = { trainer = true } },
  }
  P.current_room = "HERE"
  P.wp_room, P.room_wp = {}, {}                                    -- we've NOT learned DEST's number
  P.goto_bridge = { label = "trainer", target_wp = "DEST", tries = 0, hops = 0 }
  local real_echo, msgs = echo, {}
  echo = function(s) msgs[#msgs + 1] = tostring(s) end
  goto_bridge_advance()
  echo = real_echo
  expect(sent):falsy()                                            -- never guesses a waypoint number
  expect(table.concat(msgs, "\n"):find("don't know which waypoint number", 1, true) ~= nil):truthy()  -- handed off
  send = real_send
  P.rooms, P.current_room = saved.rooms, saved.cur
  P.wp_room, P.room_wp, P.goto_bridge = saved.wr, saved.rw, saved.br
end)

test("waypoint_cmd_num matches waypoint travel commands AND their abbreviations", function()
  local f = _AIP_TEST.waypoint_cmd_num
  expect(f("waypoint 8")):eq(8)
  expect(f("way 1")):eq(1)             -- the abbreviation that silently taught nothing before
  expect(f("wayp 12")):eq(12)
  expect(f("waypoint  3 ")):eq(3)      -- extra spaces tolerated
  expect(f("waypoint")):falsy()        -- the bare list command, no number
  expect(f("wave 8")):falsy()          -- not a waypoint command
  expect(f("west 8")):falsy()
end)

test("nearest_waypoint_for picks a waypoint room that IS the mark (mark set at a waypoint)", function()
  local P = _AIP_TEST.P
  local saved = { rooms = P.rooms, cur = P.current_room }
  -- "return" is marked AT a waypoint room (WP). Previously nearest_waypoint_for excluded the room
  -- itself and would route to a neighbor waypoint whose number it didn't know.
  P.rooms = {
    WP  = { moves = {}, waypoint = true, marks = { ["return"] = true }, name = "The Indira Shrine" },
    FAR = { moves = {}, waypoint = true, name = "Somewhere else" },
  }
  P.current_room = "FAR"
  expect(_AIP_TEST.nearest_waypoint_for("return")):eq("WP")   -- the mark's own waypoint, 0 steps
  P.rooms, P.current_room = saved.rooms, saved.cur
end)

test("waypoint_num_for_room resolves by live-list name match, then learned", function()
  local P = _AIP_TEST.P
  local saved = { rooms = P.rooms, wp = P.waypoints, rw = P.room_wp }
  P.rooms = { R8 = { name = "The Indira Shrine" }, RG = { name = "The far north rim of the pit" } }
  P.waypoints = {
    [8] = { num = 8, name = "The Indira Shrine", reachable = true },
    [3] = { num = 3, name = "A large waypoint in a stony field", reachable = true },
  }
  P.room_wp = { RG = 3 }                                       -- generic waypoint learned by travel
  -- Named waypoint: resolved from the live list even with NO learned entry (survives a relaunch).
  expect(_AIP_TEST.waypoint_num_for_room("R8")):eq(8)
  -- Generic waypoint whose room name isn't in the list text: falls back to the learned number.
  expect(_AIP_TEST.waypoint_num_for_room("RG")):eq(3)
  P.rooms, P.waypoints, P.room_wp = saved.rooms, saved.wp, saved.rw
end)

test("goto recall bridge retries recall then gives up at the cap", function()
  local P = _AIP_TEST.P
  local real_send = send
  local sent = 0
  send = function(c) if c == "recall" then sent = sent + 1 end end   -- count recall attempts
  local real_echo, msgs = echo, {}
  echo = function(s) msgs[#msgs + 1] = tostring(s) end
  P.goto_bridge = { label = "trainer", tries = 0 }
  -- Drive the retry loop the way pilot_observe would on repeated fizzles.
  for _ = 1, 12 do goto_recall_attempt() end
  send, echo = real_send, real_echo
  expect(sent):eq(6)                                -- exactly RECALL_MAX_TRIES recalls, no more
  expect(table.concat(msgs, "\n"):find("recall kept failing", 1, true) ~= nil):truthy()  -- gave up, told you
end)
