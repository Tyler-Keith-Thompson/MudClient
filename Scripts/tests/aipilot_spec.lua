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
