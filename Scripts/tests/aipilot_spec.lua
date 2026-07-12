-- Specs for AIPilot.lua map/landmark logic — guards the `mark` / `goto` / navigate('<label>') feature.

local has_mark = _AIP_TEST.has_mark
local find_path = _AIP_TEST.find_path
local P = _AIP_TEST.P

test("has_mark matches exact and substring labels, tolerates nils", function()
  local room = { marks = { trainer = true } }
  expect(has_mark(room, "trainer")):truthy()
  expect(has_mark(room, "train")):truthy()     -- substring, so `goto train` reaches a "trainer"
  expect(has_mark(room, "shop")):falsy()
  expect(has_mark({}, "trainer")):falsy()       -- no marks table
  expect(has_mark(nil, "trainer")):falsy()      -- no room
end)

test("find_path routes over the move graph to the nearest matching room", function()
  -- Build a throwaway 3-room line A -e-> B -e-> C and point the map at A. Restore afterward so a live
  -- session's real map is never clobbered by the test.
  local saved_rooms, saved_cur = P.rooms, P.current_room
  P.rooms = {
    A = { exits = { east = true }, moves = { east = "B" } },
    B = { exits = { east = true, west = true }, moves = { east = "C", west = "A" } },
    C = { exits = { west = true }, moves = { west = "B" }, marks = { trainer = true } },
  }
  P.current_room = "A"
  local path, dest = find_path(function(id) return has_mark(P.rooms[id], "trainer") end)
  expect(path):truthy()
  expect(#path):eq(2)            -- A -> B -> C
  expect(path[1]):eq("east")
  expect(path[2]):eq("east")
  expect(dest):eq("C")

  -- Unreachable label -> nil route (this is the case `goto` reports / the recall bridge will handle).
  local none = find_path(function(id) return has_mark(P.rooms[id], "nowhere") end)
  expect(none):falsy()

  P.rooms, P.current_room = saved_rooms, saved_cur
end)

test("minimap shows a stub for every exit, even walked ones whose neighbor is off-map", function()
  local P = _AIP_TEST.P
  local saved = { rooms = P.rooms, cur = P.current_room }
  -- One room at the origin: east/west advertised but unexplored; north "walked" to a room we haven't
  -- stored (off-map). The bug was that walked-to-off-map exits drew nothing.
  P.rooms = { R = { coord = { 0, 0, 0, 0 }, exits = { east = true, west = true, north = true },
                    moves = { north = 999 } } }
  P.current_room = "R"
  local m = minimap(3, 2)
  local ccol, crow = 4 * 3 + 1, 2 * 2 + 1        -- center cell (13, 5)
  expect(m.cells[crow][ccol + 1].ch):eq("─")     -- east tick
  expect(m.cells[crow][ccol + 1].fg):eq("brightgreen")   -- unexplored
  expect(m.cells[crow][ccol - 1].ch):eq("─")     -- west tick
  expect(m.cells[crow - 1][ccol].ch):eq("│")     -- north tick...
  expect(m.cells[crow - 1][ccol].fg):eq("brightblack")   -- ...walked but off-map -> dim
  P.rooms, P.current_room = saved.rooms, saved.cur
end)

test("minimap gathers spatial neighbours by coordinate, not move-graph reachability", function()
  -- Repro of the teleport-onto-isolated-waypoint / zone-renumber bug: the current room has a valid
  -- coord but its `moves` reach NOTHING on this floor (or only a far, off-window node). Several rooms
  -- sit at adjacent coords on the SAME plane+height but are NOT in its move-component. The old
  -- graph-based gather drew only the current room; the coord-based gather must include the neighbours.
  local P = _AIP_TEST.P
  local saved = { rooms = P.rooms, cur = P.current_room }
  P.rooms = {
    -- current room: graph-isolated (moves point off-floor / to an unstored far node)
    HERE = { coord = { 100, 100, 0, 0 }, exits = {}, moves = { down = "FAR" } },
    FAR  = { coord = { 100, 100, 9, 0 }, exits = {}, moves = {} },   -- different height -> another floor
    -- spatial neighbours on the SAME plane+height, unreachable via HERE's moves:
    N    = { coord = { 100, 101, 0, 0 }, exits = {}, moves = {} },   -- one coord-unit north
    E    = { coord = { 101, 100, 0, 0 }, exits = {}, moves = {} },   -- one coord-unit east
    S    = { coord = { 100,  99, 0, 0 }, exits = {}, moves = {} },   -- one coord-unit south
    NE   = { coord = { 101, 101, 0, 0 }, exits = {}, moves = {} },
    -- a same-column room a couple units north, still inside the window:
    N2   = { coord = { 100, 102, 0, 0 }, exits = {}, moves = {} },
    -- off-floor room that must NOT appear (different plane):
    OTHER = { coord = { 101, 101, 0, 1 }, exits = {}, moves = {} },
  }
  P.current_room = "HERE"
  local m = minimap(3, 2)
  local ccol, crow = 4 * 3 + 1, 2 * 2 + 1                  -- centre cell (13, 5)
  expect(m.cells[crow][ccol].ch):eq("◉")                  -- you, anchored at 0,0
  -- neighbours placed by coordinate delta (north = +y -> up = row-1); glyph is a node marker, not blank.
  local nodes = { ["□"]=true, ["▣"]=true, ["★"]=true, ["ᴡ"]=true, ["◉"]=true }
  local function is_node(cell) return cell and nodes[cell.ch] end
  expect(is_node(m.cells[crow - 2] and m.cells[crow - 2][ccol])):truthy()      -- N (one unit up)
  expect(is_node(m.cells[crow] and m.cells[crow][ccol + 4])):truthy()          -- E (one unit right)
  expect(is_node(m.cells[crow + 2] and m.cells[crow + 2][ccol])):truthy()      -- S (one unit down)
  -- count all node glyphs: should be many (HERE + N + E + S + NE + N2 = 6), proving coord-gather —
  -- the old move-graph gather would have drawn only HERE.
  local count = 0
  for _, cols in pairs(m.cells) do for _, cell in pairs(cols) do if is_node(cell) then count = count + 1 end end end
  expect(count):eq(6)                                     -- OTHER (other plane) and FAR (other floor) excluded
  P.rooms, P.current_room = saved.rooms, saved.cur
end)

test("find_path won't route through a known dead-end exit", function()
  local saved_rooms, saved_cur = P.rooms, P.current_room
  P.rooms = {
    A = { exits = { east = true }, moves = { east = "B" }, blocked = { east = true } },
    B = { exits = { west = true }, moves = { west = "A" }, marks = { shop = true } },
  }
  P.current_room = "A"
  local path = find_path(function(id) return has_mark(P.rooms[id], "shop") end)
  expect(path):falsy()          -- the only route is through a blocked exit
  P.rooms, P.current_room = saved_rooms, saved_cur
end)

-- ---- death mark + goto-death nearest-point fallback ----------------------------------------------
local nearest_reachable_to_coord = _AIP_TEST.nearest_reachable_to_coord
local mark_death = _AIP_TEST.mark_death

test("nearest_reachable_to_coord picks the closest MOVE-REACHABLE room, preferring same plane", function()
  local saved_rooms, saved_cur = P.rooms, P.current_room
  -- A -n-> B -n-> C -e-> D. X sits closest to the target but has NO inbound edge (unreachable, like a
  -- den you can only `enter hole` into). D is the exact xy but on another plane, so the plane penalty
  -- must keep C (same plane) as the pick.
  P.rooms = {
    A = { coord = { 0, 0, 0, 0 },  moves = { north = "B" } },              -- start
    B = { coord = { 0, 10, 0, 0 }, moves = { north = "C", south = "A" } },
    C = { coord = { 0, 20, 0, 0 }, moves = { south = "B", east = "D" } },  -- reachable, closest same-plane
    D = { coord = { 0, 22, 0, 5 }, moves = { west = "C" } },               -- exact xy but plane 5
    X = { coord = { 0, 21, 0, 0 }, moves = {} },                           -- closest, but UNREACHABLE
  }
  P.current_room = "A"
  local best = nearest_reachable_to_coord({ 0, 22, 0, 0 })
  expect(best):eq("C")                       -- not X (unreachable), not D (wrong plane)
  expect(nearest_reachable_to_coord(nil)):falsy()
  P.rooms, P.current_room = saved_rooms, saved_cur
end)

test("mark_death tags the current room 'death', replacing any earlier one but keeping other labels", function()
  local saved_rooms, saved_cur = P.rooms, P.current_room
  P.rooms = {
    here = { coord = { 1, 2, 3, 0 }, name = "the den" },
    old  = { coord = { 4, 5, 6, 0 }, marks = { death = true, trainer = true } },  -- a prior death + a keeper
  }
  P.current_room = "here"
  mark_death()
  expect(has_mark(P.rooms.here, "death")):truthy()               -- new corpse marked
  expect(P.rooms.old.marks and P.rooms.old.marks.death):falsy()  -- old death cleared
  expect(has_mark(P.rooms.old, "trainer")):truthy()              -- unrelated label preserved
  P.rooms, P.current_room = saved_rooms, saved_cur
end)

test("mark('return') is a singleton — re-marking MOVES it, wiping the old one, keeping other labels", function()
  local mark_command = _AIP_TEST.mark_command
  local saved_rooms, saved_cur = P.rooms, P.current_room
  P.rooms = {
    here = { coord = { 1, 2, 3, 0 }, name = "the shrine" },
    old  = { coord = { 4, 5, 6, 0 }, marks = { ["return"] = true, trainer = true } },  -- prior return + keeper
  }
  P.current_room = "here"
  mark_command("return")
  expect(has_mark(P.rooms.here, "return")):truthy()               -- return now points here
  expect(P.rooms.old.marks and P.rooms.old.marks["return"]):falsy()  -- old return cleared
  expect(has_mark(P.rooms.old, "trainer")):truthy()               -- unrelated label preserved
  -- Re-marking the SAME room is idempotent (no "already marked" bail — it just re-places).
  mark_command("return")
  expect(has_mark(P.rooms.here, "return")):truthy()
  P.rooms, P.current_room = saved_rooms, saved_cur
end)

test("a NON-singleton mark still refuses to re-mark the same room", function()
  local mark_command = _AIP_TEST.mark_command
  local saved_rooms, saved_cur = P.rooms, P.current_room
  P.rooms = { here = { coord = { 1, 2, 3, 0 }, name = "the den", marks = { trainer = true } } }
  P.current_room = "here"
  mark_command("trainer")                                         -- already marked → no-op, no crash
  expect(has_mark(P.rooms.here, "trainer")):truthy()
  P.rooms, P.current_room = saved_rooms, saved_cur
end)

test("mark_death keeps a previous mark when the death room isn't on the map (no coord)", function()
  local saved_rooms, saved_cur = P.rooms, P.current_room
  P.rooms = {
    unmapped = {},                                              -- current room, no coord
    old      = { coord = { 4, 5, 6, 0 }, marks = { death = true } },
  }
  P.current_room = "unmapped"
  mark_death()
  expect(P.rooms.unmapped.marks and P.rooms.unmapped.marks.death):falsy()  -- nothing to mark
  expect(has_mark(P.rooms.old, "death")):truthy()                          -- earlier mark NOT wiped
  P.rooms, P.current_room = saved_rooms, saved_cur
end)
