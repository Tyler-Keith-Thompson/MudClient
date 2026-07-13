-- Specs for AIPilot.lua's exploration/navigation helpers — pure map + command classifiers pinned ahead
-- of the host-hooks refactor that reworks the combat-vs-exploration mode switching. These lock the
-- CURRENT behavior of: the exits parser the observer feeds the map, the "does this command end my turn"
-- classifier (the ad-hoc combat/settle/move flag), and the frontier routing (untaken_exit /
-- path_to_unexplored / resolve_nav / best_explore_dir).

local parse_exits      = _AIP_TEST.parse_exits
local cmd_ends_turn    = _AIP_TEST.cmd_ends_turn
local untaken_exit     = _AIP_TEST.untaken_exit
local path_to_unexplored = _AIP_TEST.path_to_unexplored
local resolve_nav      = _AIP_TEST.resolve_nav
local best_explore_dir = _AIP_TEST.best_explore_dir
local P                = _AIP_TEST.P

test("parse_exits reads both the [Exits: ...] and 'Obvious exits:' forms, canonicalizing abbreviations", function()
  local a = parse_exits("[Exits: north e up ]")
  expect(a.north):truthy()
  expect(a.east):truthy()         -- "e" canonicalized to east
  expect(a.up):truthy()
  expect(a.south):falsy()
  local b = parse_exits("Obvious exits: south, west.")
  expect(b.south):truthy()
  expect(b.west):truthy()
end)

test("parse_exits returns nil when there are no real exit words", function()
  expect(parse_exits("[Exits: none ]")):eq(nil)   -- "none" isn't a direction
  expect(parse_exits("just some prose about a room")):eq(nil)
  expect(parse_exits("")):eq(nil)
end)

test("cmd_ends_turn is true for a move or a settle command, false for actions", function()
  expect(cmd_ends_turn("north")):truthy()
  expect(cmd_ends_turn("n")):truthy()             -- abbreviation
  expect(cmd_ends_turn("rest")):truthy()          -- settle: first word
  expect(cmd_ends_turn("sleep now")):truthy()     -- settle keyed on the first word
  expect(cmd_ends_turn("kill goblin")):falsy()    -- an attack keeps your turn
  expect(cmd_ends_turn("look")):falsy()
  expect(cmd_ends_turn("cast 'heal'")):falsy()
end)

test("untaken_exit returns the first (sorted) advertised exit we've neither walked nor blocked", function()
  local saved_rooms, saved_cur = P.rooms, P.current_room
  P.rooms = { A = { exits = { east = true, west = true, north = true },
                    moves = { east = "B" }, blocked = { north = true } } }
  expect(untaken_exit("A")):eq("west")   -- east walked, north blocked -> only west, and it sorts first anyway
  P.rooms = { A = { exits = { east = true }, moves = { east = "B" } } }
  expect(untaken_exit("A")):eq(nil)      -- everything explored
  expect(untaken_exit("nope")):eq(nil)   -- unknown room
  P.rooms, P.current_room = saved_rooms, saved_cur
end)

test("path_to_unexplored steps out here if it can, else routes to a frontier and crosses INTO it", function()
  local saved_rooms, saved_cur = P.rooms, P.current_room
  -- Current room A itself has an untaken exit -> a one-step route.
  P.rooms = { A = { exits = { east = true, west = true }, moves = { east = "B" },
                    coord = { 0, 0, 0, 0 } },
              B = { exits = { west = true }, moves = { west = "A" } } }
  P.current_room = "A"
  local p1 = path_to_unexplored()
  expect(#p1):eq(1)
  expect(p1[1]):eq("west")           -- untaken exit of A

  -- Now A is fully explored; the frontier is B (its east is untaken). Route walks A->B then steps east.
  P.rooms = { A = { exits = { east = true }, moves = { east = "B" } },
              B = { exits = { east = true, west = true }, moves = { west = "A" } } }
  P.current_room = "A"
  local p2 = path_to_unexplored()
  expect(#p2):eq(2)
  expect(p2[1]):eq("east")           -- A -> B
  expect(p2[2]):eq("east")           -- final step crosses into B's unexplored east
  P.rooms, P.current_room = saved_rooms, saved_cur
end)

test("resolve_nav returns a frontier predicate for 'unexplored', a fuzzy matcher for a name", function()
  local saved_rooms, saved_cur = P.rooms, P.current_room
  P.rooms = {
    HERE = { exits = {}, moves = {} },
    SHOP = { exits = {}, moves = {}, name = "The General Store", area = "Naphtali" },
    FR   = { exits = { east = true }, moves = {} },          -- a frontier (untaken east)
  }
  P.current_room = "HERE"

  local frontier_pred, fdesc = resolve_nav("unexplored")
  expect(fdesc):eq("unexplored ground")
  expect(frontier_pred("FR")):truthy()
  expect(frontier_pred("SHOP")):falsy()
  expect(frontier_pred("HERE")):falsy()                      -- never the current room

  local name_pred, ndesc = resolve_nav("store")
  expect(ndesc):eq("store")
  expect(name_pred("SHOP")):truthy()                         -- matches the room NAME substring
  local area_pred = resolve_nav("naphtali")
  expect(area_pred("SHOP")):truthy()                         -- matches the AREA substring
  expect(name_pred("FR")):falsy()
  P.rooms, P.current_room = saved_rooms, saved_cur
end)

test("best_explore_dir prefers an untaken exit here, else the first BFS step toward a frontier, else nil", function()
  local saved_rooms, saved_cur = P.rooms, P.current_room
  -- Untaken exit at the current room -> take it directly.
  P.rooms = { A = { exits = { south = true, east = true }, moves = { east = "B" } },
              B = { exits = { west = true }, moves = { west = "A" } } }
  P.current_room = "A"
  expect(best_explore_dir()):eq("south")   -- east walked; south is the untaken exit

  -- No untaken exit here; the frontier is one room east. First step is east (a real, unblocked exit).
  P.rooms = { A = { exits = { east = true }, moves = { east = "B" } },
              B = { exits = { east = true, west = true }, moves = { west = "A" } } }
  P.current_room = "A"
  expect(best_explore_dir()):eq("east")

  -- Everything reachable is explored -> nil.
  P.rooms = { A = { exits = { east = true }, moves = { east = "B" } },
              B = { exits = { west = true }, moves = { west = "A" } } }
  P.current_room = "A"
  expect(best_explore_dir()):eq(nil)
  P.rooms, P.current_room = saved_rooms, saved_cur
end)

-- ---- noexit: manual per-room direction blocking (locked doors / guards explore should skip) --------

local noexit       = _AIP_TEST.noexit_command
local addexit      = _AIP_TEST.addexit_command
local has_frontier = _AIP_TEST.has_frontier

-- Capture noexit's echo confirmations (its observable acknowledgement) alongside the routing effect.
local function with_echo(fn)
  local real_echo, msgs = echo, {}
  echo = function(s) msgs[#msgs + 1] = tostring(s) end
  local ok, err = pcall(function() fn(msgs) end)
  echo = real_echo
  if not ok then error(err, 2) end
end

test("noexit <dir> blocks a direction out of the current room, and explore skips it", function()
  local saved_rooms, saved_cur = P.rooms, P.current_room
  P.rooms = { A = { exits = { north = true, south = true }, moves = {} } }
  P.current_room = "A"
  with_echo(function(msgs)
    noexit("north")
    expect(table.concat(msgs, "\n"):find("blocked north", 1, true) ~= nil):truthy()  -- acknowledged
  end)
  expect(best_explore_dir()):eq("south")   -- north blocked → routing takes the south exit instead
  expect(untaken_exit("A")):eq("south")
  P.rooms, P.current_room = saved_rooms, saved_cur
end)

test("noexit accepts direction abbreviations and ignores non-directions", function()
  local saved_rooms, saved_cur = P.rooms, P.current_room
  P.rooms = { A = { exits = { northeast = true }, moves = {} } }
  P.current_room = "A"
  noexit("ne")
  expect(best_explore_dir()):eq(nil)        -- the only exit (ne) is now blocked → nothing to explore
  with_echo(function(msgs)
    noexit("banana")                        -- not a direction → refused, nothing blocked
    expect(table.concat(msgs, "\n"):find("isn't a direction", 1, true) ~= nil):truthy()
  end)
  P.rooms, P.current_room = saved_rooms, saved_cur
end)

test("noexit clear <dir> unblocks one; noexit clear wipes every block here", function()
  local saved_rooms, saved_cur = P.rooms, P.current_room
  P.rooms = { A = { exits = { north = true, east = true }, moves = {},
                    blocked = { north = true, east = true } } }
  P.current_room = "A"
  noexit("clear north")
  expect(untaken_exit("A")):eq("north")     -- north explorable again; east still blocked (sorts first if open)
  noexit("clear")
  expect(untaken_exit("A")):eq("east")      -- everything unblocked → first sorted untaken exit
  P.rooms, P.current_room = saved_rooms, saved_cur
end)

test("a room whose only untaken exit is blocked is no longer a frontier", function()
  local saved_rooms, saved_cur = P.rooms, P.current_room
  P.rooms = { A = { exits = { north = true }, moves = {}, blocked = { north = true } } }
  expect(has_frontier("A")):eq(false)
  P.rooms.A.blocked = nil
  expect(has_frontier("A")):eq(true)
  P.rooms, P.current_room = saved_rooms, saved_cur
end)

-- ---- addexit: manual per-room HIDDEN exits (secret doors the game never advertises) ----------------
test("addexit <dir> adds a hidden exit the room never advertised, and explore will route through it", function()
  local saved_rooms, saved_cur = P.rooms, P.current_room
  P.rooms = { A = { exits = {}, moves = {} } }   -- the room advertises NO exits
  P.current_room = "A"
  expect(best_explore_dir()):eq(nil)             -- nothing to explore yet
  with_echo(function(msgs)
    addexit("down")                              -- there's an unlisted trapdoor down
    expect(table.concat(msgs, "\n"):find("added down", 1, true) ~= nil):truthy()
  end)
  expect(P.rooms.A.exits.down):eq(true)          -- now a real exit for routing
  expect(best_explore_dir()):eq("down")          -- ...and explore takes it
  expect(untaken_exit("A")):eq("down")
  P.rooms, P.current_room = saved_rooms, saved_cur
end)

test("addexit un-blocks a direction you'd previously noexit'd", function()
  local saved_rooms, saved_cur = P.rooms, P.current_room
  P.rooms = { A = { exits = { north = true }, moves = {}, blocked = { north = true } } }
  P.current_room = "A"
  expect(best_explore_dir()):eq(nil)             -- north advertised but blocked → nothing to explore
  addexit("north")                               -- adding the exit clears the block
  expect(P.rooms.A.blocked):eq(nil)
  expect(best_explore_dir()):eq("north")
  P.rooms, P.current_room = saved_rooms, saved_cur
end)

test("addexit clear <dir> removes one added exit; addexit clear removes them all", function()
  local saved_rooms, saved_cur = P.rooms, P.current_room
  P.rooms = { A = { exits = {}, moves = {} } }
  P.current_room = "A"
  addexit("north"); addexit("east")
  addexit("clear north")
  expect(P.rooms.A.exits.north):eq(nil); expect(P.rooms.A.exits.east):eq(true)
  addexit("clear")
  expect(P.rooms.A.exits.east):eq(nil); expect(P.rooms.A.added):eq(nil)
  with_echo(function(msgs)
    addexit("banana")                            -- not a direction → refused
    expect(table.concat(msgs, "\n"):find("isn't a direction", 1, true) ~= nil):truthy()
  end)
  P.rooms, P.current_room = saved_rooms, saved_cur
end)
