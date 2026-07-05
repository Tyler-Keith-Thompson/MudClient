-- Specs for the walk-vs-bridge route planner behind `goto <mark>` (AIPilot.lua). `goto` no longer walks
-- just because a walk path exists — plan_goto_route costs the overland walk against bridging via the
-- waypoint network and takes the cheaper one. These lock that decision, the network-entry choice
-- (recall vs a short walk-to-waypoint), and the BRIDGE_MIN_SAVINGS hysteresis. Costs are asserted
-- against the exposed tunable constants so the numbers stay correct if those are re-tuned.

local plan          = _AIP_TEST.plan_goto_route
local network_entry = _AIP_TEST.network_entry
local P             = _AIP_TEST.P
local HOP_COST      = _AIP_TEST.HOP_COST
local RECALL_COST   = _AIP_TEST.RECALL_COST
local MIN_SAVINGS   = _AIP_TEST.BRIDGE_MIN_SAVINGS

-- Save/restore all planner-relevant state around each test.
local function with_state(fn)
  local saved = { rooms = P.rooms, cur = P.current_room, wps = P.waypoints,
                  wr = P.wp_room, rw = P.room_wp }
  P.waypoints, P.wp_room, P.room_wp = nil, nil, nil
  local ok, err = pcall(fn)
  P.rooms, P.current_room, P.waypoints = saved.rooms, saved.cur, saved.wps
  P.wp_room, P.room_wp = saved.wr, saved.rw
  if not ok then error(err) end
end

-- HERE=C0 -e-> C1 -e-> ... -e-> M : `n` east-edges, the mark "trainer" on the last room M.
local function chain(n)
  local rooms, ids = {}, { "HERE" }
  for i = 1, n - 1 do ids[#ids + 1] = "C" .. i end
  ids[#ids + 1] = "M"
  for _, id in ipairs(ids) do rooms[id] = { moves = {}, exits = {} } end
  for i = 1, #ids - 1 do
    rooms[ids[i]].moves.east = ids[i + 1]
    rooms[ids[i + 1]].moves.west = ids[i]
  end
  rooms["M"].marks = { trainer = true }
  return rooms
end

-- A waypoint room WP whose learned number is known, `leg` east-steps from the mark M.
local function add_waypoint(rooms, leg)
  local ids = { "WP" }
  for i = 1, leg - 1 do ids[#ids + 1] = "W" .. i end
  ids[#ids + 1] = "M"                                  -- WP's chain lands on the shared mark room
  for i = 1, #ids - 1 do
    rooms[ids[i]] = rooms[ids[i]] or { moves = {}, exits = {} }
    rooms[ids[i + 1]] = rooms[ids[i + 1]] or { moves = {}, exits = {} }
    rooms[ids[i]].moves.east = ids[i + 1]
  end
  rooms["WP"].waypoint = true
  rooms["M"].marks = rooms["M"].marks or { trainer = true }   -- ensure the mark exists even off a raw graph
  P.room_wp = { WP = 7 }                               -- learned: waypoint number 7 travels to WP
  return rooms
end

test("(a) a short walk with no waypoint option just walks", function()
  with_state(function()
    P.rooms = chain(2)                                  -- mark 2 steps away, no waypoints anywhere
    P.current_room = "HERE"
    local r = plan("trainer")
    expect(r.mode):eq("walk")
    expect(#r.path):eq(2)
    expect(r.walk_cost):eq(2)
  end)
end)

test("(b) a long walk with a known near waypoint bridges; entry is free when standing on a waypoint", function()
  with_state(function()
    P.rooms = add_waypoint(chain(12), 1)                -- 12 steps on foot; WP is 1 step from the mark
    P.rooms["HERE"].waypoint = true                     -- already on the network -> entry costs nothing
    P.current_room = "HERE"
    local r = plan("trainer")
    expect(r.mode):eq("bridge")
    expect(r.target_wp):eq("WP")
    expect(r.walk_cost):eq(12)
    expect(r.entry_cost):eq(0)                          -- standing on a waypoint
    expect(r.bridge_cost):eq(HOP_COST + 1)              -- 0 entry + one hop + a 1-step final leg
  end)
end)

test("(c) a long walk whose waypoint number is UNKNOWN walks (never picks an uncompletable bridge)", function()
  with_state(function()
    P.rooms = add_waypoint(chain(12), 1)
    P.room_wp = {}                                      -- forget WP's number: the hop would stall
    P.current_room = "HERE"
    local r = plan("trainer")
    expect(r.mode):eq("walk")
    expect(#r.path):eq(12)
  end)
end)

test("(d) an unwalkable mark with a known waypoint bridges (the original fallback)", function()
  with_state(function()
    P.rooms = add_waypoint({ HERE = { moves = {}, exits = {} } }, 1)  -- HERE is isolated: no overland route
    P.current_room = "HERE"
    local r = plan("trainer")
    expect(r.mode):eq("bridge")
    expect(r.target_wp):eq("WP")
    expect(r.walk_cost):eq(math.huge)                   -- not walkable at all
    expect(r.entry_cost):eq(RECALL_COST)                -- no waypoint walkable from HERE -> recall
    expect(r.entry_path):eq(nil)
    expect(r.bridge_cost):eq(RECALL_COST + HOP_COST + 1)
  end)
end)

test("(e) BRIDGE_MIN_SAVINGS is the hysteresis boundary — walk at the edge, bridge one step past it", function()
  with_state(function()
    local bridge_cost = HOP_COST + 1                    -- entry 0 (on a waypoint) + hop + 1-step final leg
    local boundary = bridge_cost + MIN_SAVINGS          -- bridge iff walk_cost STRICTLY exceeds this

    P.rooms = add_waypoint(chain(boundary), 1)
    P.rooms["HERE"].waypoint = true
    P.current_room = "HERE"
    expect(plan("trainer").mode):eq("walk")             -- exactly at the boundary -> still walk

    P.rooms = add_waypoint(chain(boundary + 1), 1)
    P.rooms["HERE"].waypoint = true
    P.current_room = "HERE"
    expect(plan("trainer").mode):eq("bridge")           -- one step past -> bridge
  end)
end)

test("(f) network entry: 0 on a waypoint, walk when nearer than a recall, recall at/over the constant", function()
  with_state(function()
    -- Standing on a waypoint is free.
    P.rooms = { HERE = { moves = {}, exits = {}, waypoint = true } }
    local c0, p0 = network_entry("HERE")
    expect(c0):eq(0)
    expect(p0):eq(nil)

    -- A waypoint strictly nearer than a recall -> walk to it (RECALL_COST-1 steps away).
    local near = RECALL_COST - 1
    local rooms, prev = { HERE = { moves = {}, exits = {} } }, "HERE"
    for i = 1, near do
      local id = (i == near) and "WP" or ("E" .. i)
      rooms[id] = { moves = {}, exits = {} }
      rooms[prev].moves.east = id; prev = id
    end
    rooms["WP"].waypoint = true
    P.rooms = rooms
    local c1, p1 = network_entry("HERE")
    expect(c1):eq(near)
    expect(p1 and #p1):eq(near)

    -- The SAME waypoint exactly RECALL_COST steps away -> recall wins (choice flips at the constant).
    rooms, prev = { HERE = { moves = {}, exits = {} } }, "HERE"
    for i = 1, RECALL_COST do
      local id = (i == RECALL_COST) and "WP" or ("E" .. i)
      rooms[id] = { moves = {}, exits = {} }
      rooms[prev].moves.east = id; prev = id
    end
    rooms["WP"].waypoint = true
    P.rooms = rooms
    local c2, p2 = network_entry("HERE")
    expect(c2):eq(RECALL_COST)
    expect(p2):eq(nil)

    -- No walkable waypoint at all -> recall.
    P.rooms = { HERE = { moves = {}, exits = {} } }
    local c3, p3 = network_entry("HERE")
    expect(c3):eq(RECALL_COST)
    expect(p3):eq(nil)
  end)
end)
