













local PITCH_DEG = 34.0
local LEAN_DEG = 25.0
local CELL_MAG = 34.0
local TILE_SCALE = 0.82
local CUBE_H = 12.0
local LEVEL_H = 22.0
local Z_HEADROOM = 1
local SCALE = 3





local TERR = {}
local function set(rgb, ...)
   for _, code in ipairs({ ... }) do TERR[code] = rgb end
end
set({ 0.45, 0.72, 0.35 }, 3, 15); set({ 0.20, 0.52, 0.28 }, 4, 5, 17, 34)
set({ 0.16, 0.20, 0.24 }, 6, 36); set({ 0.40, 0.46, 0.28 }, 7, 29, 38)
set({ 0.62, 0.60, 0.55 }, 2, 28); set({ 0.78, 0.66, 0.48 }, 1)
set({ 0.60, 0.62, 0.66 }, 33); set({ 0.55, 0.52, 0.50 }, 8, 10, 11)
set({ 0.85, 0.75, 0.45 }, 9, 12, 16); set({ 0.80, 0.86, 0.92 }, 13, 24)
set({ 0.82, 0.78, 0.55 }, 14); set({ 0.30, 0.52, 0.82 }, 18, 19, 20, 32)
set({ 0.25, 0.55, 0.60 }, 21); set({ 0.42, 0.36, 0.32 }, 22, 27, 37)
set({ 0.78, 0.85, 0.92 }, 23, 31); set({ 0.85, 0.35, 0.15 }, 25)
set({ 0.55, 0.50, 0.45 }, 26, 30); set({ 0.38, 0.44, 0.34 }, 35)
set({ 0.60, 0.45, 0.85 }, 39)
local DEFAULT_RGB = { 0.60, 0.64, 0.70 }
local NAMED = { yellow = { 0.95, 0.85, 0.35 }, gray = { 0.55, 0.58, 0.60 } }


local DELTA = {
   n = { 0, 1 }, s = { 0, -1 }, e = { 1, 0 }, w = { -1, 0 }, ne = { 1, 1 }, nw = { -1, 1 }, se = { 1, -1 }, sw = { -1, -1 },
}

local function base_rgb(cell)
   local cn = cell.color
   if cn and NAMED[cn] then return NAMED[cn] end
   return TERR[cell.terrain] or DEFAULT_RGB
end

local function shade(rgb, mul, a)
   return { rgb[1] * mul, rgb[2] * mul, rgb[3] * mul, a }
end


function minimap_render(cells, cols, rows, depth)
   if not cells or #cells == 0 then
      canvas({}, { location = "top", cols = cols, rows = rows }); return
   end
   local half = depth or 5

   local s = SCALE
   local ch, lvl = CUBE_H * s, LEVEL_H * s
   local phi = PITCH_DEG * math.pi / 180.0
   local sinp = math.sin(phi)
   local psi = math.atan(math.tan(LEAN_DEG * math.pi / 180.0) * sinp)
   local m = CELL_MAG * s
   local exx, exy = math.cos(psi) * m, math.sin(psi) * sinp * m
   local nyx, nyy = -math.sin(psi) * m, math.cos(psi) * sinp * m
   local hexx, hexy = exx * TILE_SCALE / 2, exy * TILE_SCALE / 2
   local hnyx, hnyy = nyx * TILE_SCALE / 2, nyy * TILE_SCALE / 2
   local halfSpanX = math.abs(hexx) + math.abs(hnyx)
   local halfSpanY = math.abs(hexy) + math.abs(hnyy)
   local zPad = lvl * Z_HEADROOM + ch


   local minSx, maxSx, minSy, maxSy = 0.0, 0.0, 0.0, 0.0
   for _, gx in ipairs({ -half, half }) do
      for _, gy in ipairs({ -half, half }) do
         local sx = gx * exx + gy * nyx
         local sy = gx * exy + gy * nyy
         minSx = math.min(minSx, sx); maxSx = math.max(maxSx, sx)
         minSy = math.min(minSy, sy); maxSy = math.max(maxSy, sy)
      end
   end
   local margin = 6.0 * s
   local originX = -minSx + halfSpanX + margin
   local originY = -minSy + halfSpanY + ch + margin
   local W = math.floor((maxSx - minSx) + 2 * halfSpanX + 2 * margin + 0.5)
   local H = math.floor((maxSy - minSy) + 2 * halfSpanY + 2 * zPad + 2 * margin + 0.5)

   local function cx(cell)
      return originX + (cell.gx) * exx + (cell.gy) * nyx
   end
   local function cy(cell)
      return originY + (cell.gx) * exy + (cell.gy) * nyy + (cell.z) * lvl
   end

   local cmds = {}
   local function push(c) cmds[#cmds + 1] = c end

   local WALL_STROKE = { 0.07, 0.08, 0.09, 0.85 }
   local TOP_STROKE = { 0.10, 0.12, 0.13, 0.85 }


   local function draw_room(cell, a)
      local x, y = cx(cell), cy(cell)
      local swx, swy = x - hexx - hnyx, y - hexy - hnyy
      local sex, sey = x + hexx - hnyx, y + hexy - hnyy
      local nex, ney = x + hexx + hnyx, y + hexy + hnyy
      local nwx, nwy = x - hexx + hnyx, y - hexy + hnyy
      local rgb = base_rgb(cell)
      local dn = ch

      push({ op = "poly", pts = { sex, sey, nex, ney, nex, ney - dn, sex, sey - dn }, fill = shade(rgb, 0.62, a) })
      push({ op = "poly", pts = { swx, swy, sex, sey, sex, sey - dn, swx, swy - dn }, fill = shade(rgb, 0.44, a),
line = { WALL_STROKE[1], WALL_STROKE[2], WALL_STROKE[3], WALL_STROKE[4] * a }, w = math.max(1, 1 * s), })
      push({ op = "poly", pts = { sex, sey, nex, ney, nex, ney - dn, sex, sey - dn },
line = { WALL_STROKE[1], WALL_STROKE[2], WALL_STROKE[3], WALL_STROKE[4] * a }, w = math.max(1, 1 * s), })

      push({ op = "tile", code = cell.terrain, pts = { swx, swy, sex, sey, nex, ney, nwx, nwy },
fill = shade(rgb, 1.0, a), a = a, })
      push({ op = "poly", pts = { swx, swy, sex, sey, nex, ney, nwx, nwy },
line = { TOP_STROKE[1], TOP_STROKE[2], TOP_STROKE[3], TOP_STROKE[4] * a }, w = math.max(1, 1.2 * s), })

      local exits = cell.exits
      local has_u, has_d = false, false
      if exits then       for _, e in ipairs(exits) do
         if e == "u" then has_u = true elseif e == "d" then has_d = true end
      end end
      local vr = math.abs(hnyy) + math.abs(hexy)
      local cw, cha = 5 * s, 5 * s
      if has_u then
         local px, py = x, y + vr * 0.32
         push({ op = "path", pts = { px - cw, py, px, py + cha, px + cw, py }, line = { 0.55, 1.0, 0.6, a }, w = math.max(1.5, 2 * s) })
      end
      if has_d then
         local px = (swx + sex) / 2
         local py = (swy + sey) / 2 - dn - 2 * s
         push({ op = "path", pts = { px - cw, py, px, py - cha, px + cw, py }, line = { 0.95, 0.65, 0.35, a }, w = math.max(1.5, 2 * s) })
      end
      if cell.cur then
         local top = { swx, swy, sex, sey, nex, ney, nwx, nwy }
         push({ op = "poly", pts = top, line = { 0.05, 0.06, 0.07, 1 }, w = math.max(3, 5 * s) })
         push({ op = "poly", pts = top, line = { 1.0, 0.86, 0.2, 1 }, w = math.max(1.5, 2.4 * s) })
      end
   end



   local function draw_ghost(cell)
      local x, y = cx(cell), cy(cell)
      local swx, swy = x - hexx - hnyx, y - hexy - hnyy
      local sex, sey = x + hexx - hnyx, y + hexy - hnyy
      local nex, ney = x + hexx + hnyx, y + hexy + hnyy
      local nwx, nwy = x - hexx + hnyx, y - hexy + hnyy
      local dn = ch
      local wire = { 0.62, 0.80, 1.0, 0.7 }
      push({ op = "poly", pts = { swx, swy, sex, sey, nex, ney, nwx, nwy }, line = wire, w = math.max(1, 1.2 * s) })

      push({ op = "path", pts = { swx, swy - dn, swx, swy }, line = wire, w = math.max(1, 1.2 * s) })
      push({ op = "path", pts = { sex, sey - dn, sex, sey }, line = wire, w = math.max(1, 1.2 * s) })
      push({ op = "path", pts = { nex, ney - dn, nex, ney }, line = wire, w = math.max(1, 1.2 * s) })
      push({ op = "path", pts = { swx, swy - dn, sex, sey - dn, nex, ney - dn }, line = { wire[1], wire[2], wire[3], 0.45 }, w = math.max(1, 1 * s) })
   end


   local function ordered(list)
      table.sort(list, function(a, b)
         local ca, cb = a, b
         local sa = (ca.gx) + (ca.gy)
         local sb = (cb.gx) + (cb.gy)
         if sa ~= sb then return sa > sb end
         return (ca.z) < (cb.z)
      end)
      return list
   end


   local below, ground, current, above = {}, {}, {}, {}
   local by_cell = {}
   local function inwin(c)
      local gx, gy = c.gx, c.gy
      return gx >= -half and gx <= half and gy >= -half and gy <= half
   end
   for _, cc in ipairs(cells) do
      local c = cc
      if inwin(c) then
         if c.dim then
            if (c.z) > 0 then above[#above + 1] = cc else below[#below + 1] = cc end
         elseif c.cur then
            current[#current + 1] = cc
            by_cell[(c.gx) .. "," .. (c.gy)] = cc
         else
            ground[#ground + 1] = cc
            by_cell[(c.gx) .. "," .. (c.gy)] = cc
         end
      end
   end

   for _, c in ipairs(ordered(below)) do draw_room(c, 0.30) end
   for _, c in ipairs(ordered(ground)) do draw_room(c, 1.0) end
   for _, c in ipairs(current) do draw_room(c, 1.0) end


   for _, cc in ipairs(cells) do
      local c = cc
      if not c.dim and inwin(c) then
         local exits = c.exits
         if exits then          for _, d in ipairs(exits) do
            local dl = DELTA[d]
            if dl then
               local nb = by_cell[((c.gx) + dl[1]) .. "," .. ((c.gy) + dl[2])]
               if nb then
                  local nbc = nb
                  local fx, fy = cx(c), cy(c)
                  local tx, ty = cx(nbc), cy(nbc)
                  local mx, my = (fx + tx) / 2, (fy + ty) / 2
                  local vx, vy = tx - fx, ty - fy
                  local len = math.max(1, math.sqrt(vx * vx + vy * vy))
                  local ux, uy = vx / len, vy / len
                  local half = math.max(3 * s, len * 0.30)
                  local p1x, p1y = mx - ux * half, my - uy * half
                  local p2x, p2y = mx + ux * half, my + uy * half
                  push({ op = "path", pts = { p1x, p1y, p2x, p2y }, line = { 0.13, 0.14, 0.15, 0.9 }, w = math.max(2.5, 4 * s) })
                  push({ op = "path", pts = { p1x, p1y, p2x, p2y }, line = { 0.95, 0.88, 0.55, 1 }, w = math.max(1.5, 2 * s) })
               end
            end
         end end
      end
   end

   for _, c in ipairs(ordered(above)) do draw_ghost(c) end


   do
      local cxp, cyp = 20 * s, (H) - 20 * s
      local mag = math.sqrt(nyx * nyx + nyy * nyy)
      local nx, ny = nyx / mag, nyy / mag
      local len = 13 * s
      local tipx, tipy = cxp + nx * len, cyp + ny * len
      local tailx, taily = cxp - nx * len * 0.5, cyp - ny * len * 0.5
      push({ op = "path", pts = { tailx, taily, tipx, tipy }, line = { 0.95, 0.9, 0.55, 1 }, w = math.max(1.5, 2 * s) })
      local perpx, perpy = -ny, nx
      local ah = 5 * s
      local a1x, a1y = tipx - nx * ah + perpx * ah * 0.6, tipy - ny * ah + perpy * ah * 0.6
      local a2x, a2y = tipx - nx * ah - perpx * ah * 0.6, tipy - ny * ah - perpy * ah * 0.6
      push({ op = "poly", pts = { tipx, tipy, a1x, a1y, a2x, a2y }, fill = { 0.95, 0.9, 0.55, 1 } })
      local nlx, nly = tipx + nx * 8 * s, tipy + ny * 8 * s
      local g = 3.5 * s
      push({ op = "path", pts = { nlx - g, nly - g, nlx - g, nly + g, nlx + g, nly - g, nlx + g, nly + g },
line = { 1.0, 0.95, 0.7, 1 }, w = math.max(1.2, 1.6 * s), })
   end

   canvas(cmds, { w = W, h = H, location = "top", cols = cols, rows = rows })
end


_MINIMAP_TEST = { base_rgb = base_rgb, TERR = TERR }
