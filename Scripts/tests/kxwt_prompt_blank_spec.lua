-- The server frames its gagged kxwt/kxwq machine lines with a leading blank line (e.g. `You scan...\n\n
-- kxwq_hud|…`). strip_kxwt_prompt_blanks drops the blank(s) directly before a kxw[tq]_ line — the gagged
-- prompt's leading newline — while leaving blanks before real text (paragraph breaks) alone.
--
-- The strip is STATEFUL across messages (the RPC delivers each telemetry line as a separate feed): whether
-- a leading `\n` before a tag is a redundant blank or the line-break the seam needs depends on whether the
-- PREVIOUS message ended at line-start. set_prev_ended_nl pins that seam state so each case is deterministic.

local strip = _AA_TEST.strip_kxwt_prompt_blanks
local at_line_start = _AA_TEST.set_prev_ended_nl

test("drops the blank line before a kxwq_ machine line, whatever precedes it", function()
  -- after REAL content (the case that kept leaking): You scan...\n\nkxwq_hud
  at_line_start(true)
  expect(strip("You scan the surrounding area...\n\nkxwq_hud|354|354|457|457|198|198|standing"))
    :eq("You scan the surrounding area...\nkxwq_hud|354|354|457|457|198|198|standing")
  -- between two machine lines
  at_line_start(true)
  expect(strip("kxwq_fighting -1\n\nkxwq_hud|1|1|1|1|1|1|standing"))
    :eq("kxwq_fighting -1\nkxwq_hud|1|1|1|1|1|1|standing")
  -- multiple blank lines before the prompt collapse to none
  at_line_start(true)
  expect(strip("done\n\n\n\nkxwq_prompt 1 1 1 1 1 1"))
    :eq("done\nkxwq_prompt 1 1 1 1 1 1")
  -- matches kxwt_ as well as kxwq_
  at_line_start(true)
  expect(strip("x\n\nkxwt_music foo")):eq("x\nkxwt_music foo")
end)

test("leaves blank lines before REAL content untouched (paragraph breaks)", function()
  at_line_start(true)
  expect(strip("The sun shines brightly overhead.\n\nA skeletal lich paces here."))
    :eq("The sun shines brightly overhead.\n\nA skeletal lich paces here.")
  -- a single newline before a kxwq_ line (no blank) is unchanged
  at_line_start(true)
  expect(strip("content\nkxwq_hud|1|1|1|1|1|1|standing"))
    :eq("content\nkxwq_hud|1|1|1|1|1|1|standing")
  -- a GA marker before the blank doesn't interfere (it sits on the previous line)
  at_line_start(true)
  expect(strip("You scan...\238\128\128\n\nkxwq_hud|1|1|1|1|1|1|standing"))
    :eq("You scan...\238\128\128\nkxwq_hud|1|1|1|1|1|1|standing")
end)

test("strips the LEADING blank before a kxwq_ line when the prev message ended at line-start", function()
  -- each RPC telemetry message starts with a newline; when the previous message ended in \n, that leading
  -- \n forms a blank line at the seam — drop it (the prev message's own \n is the separator).
  at_line_start(true)
  expect(strip("\nkxwq_prompt 354 354 455 457 198 198")):eq("kxwq_prompt 354 354 455 457 198 198")
  at_line_start(true)
  expect(strip("\n\nkxwq_hud|1|1|1|1|1|1|standing")):eq("kxwq_hud|1|1|1|1|1|1|standing")
  -- a message NOT starting with a telemetry tag keeps its leading newline (could be real spacing)
  at_line_start(true)
  expect(strip("\nYou bow.")):eq("\nYou bow.")
end)

test("keeps the leading newline when the prev message ended MID-LINE (no merge regression)", function()
  -- REGRESSION GUARD: a chat/quest line or GA-flushed prompt ends without a trailing \n. The next telemetry
  -- message's leading \n is then the ONLY separator — stripping it glued the gagged tag onto the real line
  -- (`…in this area.kxwq_prompt 354…`). When prev ended mid-line, keep the leading \n.
  at_line_start(false)
  expect(strip("\nkxwq_prompt 354 354 455 457 198 198")):eq("\nkxwq_prompt 354 354 455 457 198 198")
  at_line_start(false)
  expect(strip("\nkxwq_hud|1|1|1|1|1|1|standing")):eq("\nkxwq_hud|1|1|1|1|1|1|standing")
  -- an extra blank still collapses to the single needed separator even when prev ended mid-line
  at_line_start(false)
  expect(strip("\n\nkxwq_hud|1|1|1|1|1|1|standing")):eq("\nkxwq_hud|1|1|1|1|1|1|standing")
end)

test("tracks the seam state from what it emits (chained messages)", function()
  -- Message ending in real content (no trailing \n) leaves the seam MID-LINE, so the following telemetry
  -- message keeps its separator — this is the exact two-message sequence that used to merge.
  at_line_start(true)
  expect(strip("[questinfo] Aredhel: in this area.")):eq("[questinfo] Aredhel: in this area.")
  expect(strip("\nkxwq_prompt 354 354 455 457 198 198")):eq("\nkxwq_prompt 354 354 455 457 198 198")
  -- After a message ending in \n, the next telemetry seam-blank drops.
  at_line_start(true)
  expect(strip("You put a green soulstone in an icy vortex.\n"))
    :eq("You put a green soulstone in an icy vortex.\n")
  expect(strip("\nkxwq_hud|1|1|1|1|1|1|standing")):eq("kxwq_hud|1|1|1|1|1|1|standing")
end)
