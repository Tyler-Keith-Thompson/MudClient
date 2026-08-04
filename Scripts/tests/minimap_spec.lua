-- Minimap.tl renderer: it turns placement cells into a `canvas` draw-command list. We stub the global
-- `canvas` builtin to capture what it emits (no real painting needed) and assert the command structure.

local function capture()
  local seen = {}
  canvas = function(cmds, opts) seen.cmds = cmds; seen.opts = opts end
  return seen
end

local function count_ops(cmds)
  local n = { poly = 0, path = 0, tile = 0 }
  for _, c in ipairs(cmds) do n[c.op] = (n[c.op] or 0) + 1 end
  return n
end

test("minimap_render emits a sized canvas of poly/path/tile commands for a scene", function()
  local seen = capture()
  minimap_render({
    { gx = 0, gy = 0, z = 0, terrain = 2, exits = { "n", "e", "s", "w" }, cur = true },
    { gx = 0, gy = 1, z = 0, terrain = 4, exits = { "s" } },
    { gx = 1, gy = 0, z = 1, terrain = 10, exits = { "w" } },   -- one level up (east)
  }, 26, 9)
  expect(seen.opts.w > 0):truthy()
  expect(seen.opts.h > 0):truthy()
  expect(seen.opts.location):eq("top")
  local n = count_ops(seen.cmds)
  expect(n.tile):eq(3)                 -- one terrain top face per placed room
  expect(n.poly > 0):truthy()          -- walls / outlines / current ring / compass arrowhead
  expect(n.path > 0):truthy()          -- connectors / chevrons / compass shaft+glyph
end)

test("minimap_render draws the current room's gold ring and an elevation is encoded in z", function()
  local seen = capture()
  minimap_render({
    { gx = 0, gy = 0, z = 0, terrain = 3, exits = {}, cur = true },
    { gx = 1, gy = 0, z = 2, terrain = 10, exits = {} },        -- two levels up → drawn higher
  }, 26, 9)
  -- the gold ring is a poly stroked with ~{1,0.86,0.2}; find it
  local gold = false
  for _, c in ipairs(seen.cmds) do
    if c.op == "poly" and c.line and math.abs(c.line[1]-1.0) < 0.01
       and math.abs(c.line[2]-0.86) < 0.01 and math.abs(c.line[3]-0.2) < 0.01 then gold = true end
  end
  expect(gold):truthy()
end)

test("minimap_render clears the panel (empty commands) when there are no cells", function()
  local seen = capture()
  minimap_render({}, 26, 9)
  expect(#seen.cmds):eq(0)             -- empty command list → canvas clears back to text
end)

test("minimap_render draws a floor-ABOVE room as an outline-only wireframe (no filled tile veiling below)", function()
  local seen = capture()
  minimap_render({
    { gx = 0, gy = 0, z = 0, terrain = 2, exits = { "u" }, cur = true },
    { gx = 0, gy = 0, z = 1, terrain = 1, exits = { "d" }, dim = true },   -- a floor above (ghost)
  }, 26, 9)
  -- only the current room gets a filled terrain tile; the floor-above room must NOT (else it veils below)
  local tiles = 0
  for _, c in ipairs(seen.cmds) do if c.op == "tile" then tiles = tiles + 1 end end
  expect(tiles):eq(1)
  -- the ghost is an outline: a poly with a cool line colour and NO fill
  local wire = false
  for _, c in ipairs(seen.cmds) do
    if c.op == "poly" and not c.fill and c.line and c.line[3] > c.line[1] and c.line[3] > 0.9 then wire = true end
  end
  expect(wire):truthy()
end)
