-- Specs for the `;smap;` coord bridge (Scripts/AlterAeon/AIPilot.lua smap_coord_grid/smap_apply/smap_on_map_update)
-- that restores the room-graph minimap over the 1.105 RPC transport (kxwt_rvnum/kxwt_rshort are dead
-- there). Fixture frames below are 3 CONSECUTIVE, DISTINCT real `;smap;` payloads captured while
-- walking one direction repeatedly (~/Documents/MudClient/smap_capture.log, frames 0/1/2 after
-- de-duplication) — control bytes already unescaped (this is what state.dclient_map actually holds;
-- the capture log's `\r`/`\n`/`\xNN` escaping is only for safely writing to a text file).

local smap_coord_grid = _AIP_TEST.smap_coord_grid
local smap_apply = _AIP_TEST.smap_apply
local smap_on_map_update = _AIP_TEST.smap_on_map_update
local SM = _AIP_TEST.SM
local P = _AIP_TEST.P

local FRAME = {
  "@@@@@@@@@@@@\n@@@@@@@@@@@\n@@@@@@@@@@@\n@@@DD@@@@@D\n@@@D@D@@@@@\n@@@D@@D@DB@\n@@DD@D@D@DC\n@@@DA@CD@D@\n@@@@D@@@C@@\n@@@@@@@@@DD\n@@@@@@@@@@@\n@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@DA@@@@@@D\n@@@DADD@@@D@\n@@@@@BDDB@@A\n@@@D@@@@@@D@\n@@@@DDD@D@C@\n@@@@@@@@@DD@\n@@@@@@@@@@DD\n@@@@@@@@@@DD\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@DD@@@@@D@\n@@@DDD@@@@DD\n@@DDDDD@@DDD\n@@@DDDDDDDDD\n@@@@DDDDDDD@\n@@@@@DD@@DD@\n@@@@@@@@@@@@\n@@@@@@@@@@DD\n@@@@@@@@@@@D\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@DD@@@@@C\n@@@DDDD@@@DD\n@@@DDDDD@DDD\n@@DDDDDDDDD@\n@@@D@DDDDDD@\n@@@@DD@@DDD@\n@@@@@@@@@@@D\n@@@@@@@@@@DD\n@@@@@@@@@@D@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@@@@@@@@@@@@A@IPBDL@@@@@@@@@@@@@@@@@@@@@BDO@\n@@@@@@@@@@@@A@LABDC@APAH@@@@@@@@@@@@@@@@BFF@\n@@@@@@@@DBV@BBR@BDZ@A@F@B@Q@@@@@BDB@BDT@BD]@\n@@@@@@@@@@@@A@OHBD[@BDD@BEM@BDV@BD_@A@PH@@@@\n@@@@@@@@@@@@@@@@A@GPBDB@@@@@@@@@BDH@BDG@@@@@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@BDY@@@@@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@BDB@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@DD^@\n@",
  "D@@@@@@@@@@@\n@@@@@@@@@@@\n@@@@@@@@@@@\n@@@@DD@@@@@\n@@@@D@D@@@@\n@@@@D@@D@DB\n@@@DD@D@D@D\n@@@@DA@CD@D\n@@@@@D@@@C@\n@@@@@@@@@@D\n@@@@@@@@@@@\n@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@DA@@@@@@\n@@@@DADD@@@@\n@@@@@@BDDB@@\n@@@@D@@@@@@D\n@@@@@DDD@D@C\n@@@@@@@@@@DD\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@DD@@@@@@\n@@@@DDD@@@@@\n@@@DDDDD@@D@\n@@@@DDDDDDDD\n@@@@@DDDDDDD\n@@@@@@DD@@DD\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@DD@@@@@\n@@@@DDDD@@@@\n@@@@DDDDD@DD\n@@@DDDDDDDDD\n@@@@D@DDDDDD\n@@@@@DD@@DDD\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@@@@@@@@@@@@@@@@A@IPBDL@@@@@@@@@@@@@@@@@@@@@\n@@@@@@@@@@@@@@@@A@LABDC@APAH@@@@@@@@@@@@@@@@\n@@@@@@@@@@@@DBV@BBR@BDZ@A@F@B@Q@@@@@BDB@BDT@\n@@@@@@@@@@@@@@@@A@OHBD[@BDD@BEM@BDV@BD_@A@PH\n@@@@@@@@@@@@@@@@@@@@A@GPBDB@@@@@@@@@BDH@BDG@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@BDY@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@",
  "D@@@@@@@@@@@\n@@@@@@@@@@@\n@@@@@@@@@@@\n@@@@@DD@@@@\n@@@@@D@D@@@\n@@@@@D@@D@D\n@@@@DD@D@D@\n@@@@@DA@CD@\n@@@@@@D@@@C\n@@@@@@@@@@@\n@@@@@@@@@@@\n@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@DA@@@@@\n@@@@@DADD@@@\n@@@@@@@BDDB@\n@@@@@D@@@@@@\n@@@@@@DDD@D@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@DD@@@@@\n@@@@@DDD@@@@\n@@@@DDDDD@@@\n@@@@@DDDDDDD\n@@@@@@DDDDDD\n@@@@@@@DD@@D\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@DD@@@@\n@@@@@DDDD@@@\n@@@@@DDDDD@D\n@@@@DDDDDDDD\n@@@@@D@DDDDD\n@@@@@@DD@@D@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@@@@@@@@@@@@@@@@@@@@A@IPBDL@@@@@@@@@@@@@@@@@\n@@@@@@@@@@@@@@@@@@@@A@LABDC@APAH@@@@@@@@@@@@\n@@@@@@@@@@@@@@@@DBV@BBR@BDZ@A@F@B@Q@@@@@BDB@\n@@@@@@@@@@@@@@@@@@@@A@OHBD[@BDD@BEM@BDV@BD_@\n@@@@@@@@@@@@@@@@@@@@@@@@A@GPBDB@@@@@@@@@BDH@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n@",
}

test("smap_coord_grid decodes the widest section into a stable, non-zero center room id", function()
  local grids = {}
  for i, raw in ipairs(FRAME) do
    local g = smap_coord_grid(raw)
    expect(g):truthy()
    expect(g.w >= 8):truthy()           -- decoded cell grid (>= 8 cells wide, per the smap_coord_grid contract)
    grids[i] = g
    local center = g.grid[g.center_r][g.center_c]
    expect(center > 0):truthy()         -- decoded a real room id, not @@@@ (0)
  end
  -- Each frame's center is a DIFFERENT room (we stepped between them) but decodes consistently: the
  -- same grid decoded twice gives the same id (stability, not a hash of noise).
  local again = smap_coord_grid(FRAME[1])
  expect(again.grid[again.center_r][again.center_c]):eq(grids[1].grid[grids[1].center_r][grids[1].center_c])
end)

test("consecutive frames: the new center was exactly one cell away in the previous frame's grid", function()
  local g1, g2, g3 = smap_coord_grid(FRAME[1]), smap_coord_grid(FRAME[2]), smap_coord_grid(FRAME[3])
  local function step(prev, cur)
    local c_id = cur.grid[cur.center_r][cur.center_c]
    local r, c
    for rr, row in ipairs(prev.grid) do
      for cc, v in ipairs(row) do
        if v == c_id then r, c = rr, cc end
      end
    end
    expect(r):truthy()   -- the room we walked into was visible, one step away, in the prior frame
    local dr, dc = r - prev.center_r, c - prev.center_c
    -- unit vector: exactly one of dr/dc is +-1, the other 0 (adjacent cell, not a jump/teleport)
    expect(math.abs(dr) + math.abs(dc)):eq(1)
    return dr, dc
  end
  local dr1, dc1 = step(g1, g2)
  local dr2, dc2 = step(g2, g3)
  -- The fixture was captured walking the SAME direction repeatedly, so both steps agree.
  expect(dr1):eq(dr2)
  expect(dc1):eq(dc2)
end)

test("smap_apply is PREVIEW-ONLY: tracks SM.abs surroundings but NEVER feeds the routing graph", function()
  -- smap's cell values aren't globally-unique room ids and its grid positions aren't real coordinates
  -- (only kxwt has those), so smap_apply must NOT touch P.current_room / P.rooms — it only maintains the
  -- abs[] preview minimap() reads. This guards the fix for smap/kxwt fighting over the same rooms' coords.
  local saved_rooms, saved_cur, saved_dir = P.rooms, P.current_room, P.last_move_dir
  local saved_sm = { abs = SM.abs, cur = SM.cur, cur_xy = SM.cur_xy, prev_grid = SM.prev_grid }
  P.rooms, P.current_room, P.last_move_dir = {}, nil, nil
  SM.abs, SM.cur, SM.cur_xy, SM.prev_grid = {}, nil, nil, nil

  local g1 = smap_coord_grid(FRAME[1])
  local id1 = g1.grid[g1.center_r][g1.center_c]
  smap_apply(g1)
  expect(P.current_room):eq(nil)          -- graph UNTOUCHED — kxwt owns room identity now
  expect(P.rooms[id1]):falsy()            -- no fake room fabricated
  expect(SM.cur):eq(id1)                  -- but the preview tracks the decoded center
  expect(SM.abs[id1]):truthy()
  local xy1 = { SM.abs[id1][1], SM.abs[id1][2] }

  local g2 = smap_coord_grid(FRAME[2])
  local id2 = g2.grid[g2.center_r][g2.center_c]
  smap_apply(g2)
  expect(P.current_room):eq(nil)          -- STILL never fed the graph
  expect(SM.cur):eq(id2)
  expect(id2 ~= id1):truthy()
  local xy2 = { SM.abs[id2][1], SM.abs[id2][2] }
  -- the preview position stepped exactly one unit (matches the unit-vector step asserted above)
  local dx, dy = xy2[1] - xy1[1], xy2[2] - xy1[2]
  expect(math.abs(dx) + math.abs(dy)):eq(1)

  P.rooms, P.current_room, P.last_move_dir = saved_rooms, saved_cur, saved_dir
  SM.abs, SM.cur, SM.cur_xy, SM.prev_grid = saved_sm.abs, saved_sm.cur, saved_sm.cur_xy, saved_sm.prev_grid
end)

test("smap_on_map_update is a no-op without state.dclient_map, and safe to call repeatedly", function()
  local saved = state.dclient_map
  state.dclient_map = nil
  local ok = pcall(smap_on_map_update)
  expect(ok):truthy()
  state.dclient_map = FRAME[1]
  ok = pcall(smap_on_map_update)
  expect(ok):truthy()
  state.dclient_map = saved
end)
