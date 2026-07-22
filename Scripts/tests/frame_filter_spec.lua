-- frame_filter is the on_stream streaming filter (DClientProbe) that removes the blank lines the server
-- wraps its gagged kxwt/kxwq telemetry in — the ~2-per-idle-tick blanks that leaked once the telemetry
-- itself was hidden — WITHOUT disturbing genuine spacing or ever merging real lines. It is stateful
-- across chunks; reset_frame_filter pins the streaming state so each case is deterministic.

local ff    = _AA_TEST.frame_filter
local reset = _AA_TEST.reset_frame_filter

local GA = "\238\128\128"   -- U+E000, the host's IAC GO-AHEAD marker

-- Model the downstream line assembler + ^kxw[tq]_ gag: a GA marker appends its segment to the output
-- WITHOUT a line break (only \n breaks lines), so it just drops out; then any line beginning kxwq_/kxwt_
-- is hidden. Returns the VISIBLE lines the player would actually see, joined by "|" for :eq comparison.
local function visible(s)
  local flat = (s:gsub(GA, ""))         -- GA appends its segment inline; the marker itself never displays
  local vis = {}
  for line in (flat .. "\n"):gmatch("([^\n]*)\n") do
    if not line:match("^kxw[tq]_") then vis[#vis + 1] = line end
  end
  -- drop a single trailing empty produced by the sentinel \n so equal content compares equal
  if #vis > 0 and vis[#vis] == "" then vis[#vis] = nil end
  return table.concat(vis, "|")
end

test("idle-tick framing (telemetry wrapped in blanks) collapses to nothing", function()
  reset()
  -- \n-terminated kxwq_prompt, a framing blank, the GA-flushed kxwq_hud prompt, another framing blank —
  -- a whole idle tick with no real text. Nothing visible survives.
  local out = ff("kxwq_prompt 1 1 1 1 1 1\n\nkxwq_hud|1|1|1|1|1|1|standing" .. GA .. "\n")
  expect(visible(out)):eq("")
end)

test("a paragraph break wrapping gagged telemetry survives as exactly one blank", function()
  reset()
  local out = ff("...and simple altar.\n")
  out = out .. ff("\nkxwq_sky 0 0 0\nkxwq_area 6110 The Monastery\n\nAn amorphous mound is here.\n")
  expect(visible(out)):eq("...and simple altar.||An amorphous mound is here.")
end)

test("a run of genuine blank lines (no telemetry) is preserved verbatim", function()
  reset()
  local out = ff("Welcome back!\n\n\n    vaelith - level 28\n")
  expect(out):eq("Welcome back!\n\n\n    vaelith - level 28\n")
end)

test("a visible GA segment keeps its own line — telemetry never glues onto it", function()
  reset()
  -- 'You scan...' is a GA segment (RPC synthesised the GO-AHEAD; no trailing \n), immediately followed by
  -- the next message's leading \n and the kxwq_hud tick. It must stay on its own line, nothing merged.
  local out = ff("You scan the surrounding area..." .. GA)
  out = out .. ff("\nkxwq_hud|1|1|1|1|1|1|standing" .. GA .. "\n")
  expect(visible(out)):eq("You scan the surrounding area...")
end)

test("gagged telemetry between two real lines with no blank invents no spacing", function()
  reset()
  local out = ff("You head west.\nkxwq_walkdir 3\nWithin the temple\n")
  expect(visible(out)):eq("You head west.|Within the temple")
end)

test("state carries across chunk boundaries (framing split mid-run)", function()
  reset()
  -- The framing run straddles a chunk: real text + blank + gagged tick at the end of one feed, resolved
  -- by real text at the start of the next. The break is emitted exactly once, no merge.
  local a = ff("You currently gain 59 hitpoints while sitting.\n\nkxwq_hud|1|1|1|1|1|1|sitting" .. GA .. "\n")
  local b = ff("You make a shallow cut and begin tapping your life.\n")
  expect(visible(a .. b)):eq(
    "You currently gain 59 hitpoints while sitting.||You make a shallow cut and begin tapping your life.")
end)

test("leading framing before any real text is dropped", function()
  reset()
  local out = ff("\nkxwq_hud|1|1|1|1|1|1|standing" .. GA .. "\n\nYou return to your keyboard.\n")
  expect(visible(out)):eq("You return to your keyboard.")
end)
