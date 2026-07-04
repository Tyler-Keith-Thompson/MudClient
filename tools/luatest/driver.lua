-- CLI entry point for the script test suite (run via tools/luatest/run.sh, from the repo root).
--
-- The game scripts call host builtins that only exist when the Swift client registers them
-- (trigger/alias/echo/panel/ai_*/…). Here we stub those so the scripts load in a bare interpreter,
-- then invoke the SAME `run_test_suite()` the in-app `#test` command uses. Keeping this out of
-- Scripts/ means it never gets auto-loaded or picked up by the Scripts/tests/*.lua glob.

local noop = function() end
for _, n in ipairs({
  "trigger", "alias", "gag", "send", "after",
  "music_play", "music_stop", "music_volume",
  "panel_render", "panel_top", "panel_height", "panel_top_height",
  "ai_request", "ai_memory_request", "ai_retrieve", "ai_rag_load",
  "ai_set_auth", "ai_set_endpoint", "ai_set_model", "ai_set_memory_endpoint",
  "ai_set_memory_key", "ai_set_memory_model", "ai_usage_reset",
}) do _G[n] = noop end
function ai_rag_count() return 0 end
function ai_usage() return 0, 0, 0, 0 end
function ai_mem_usage() return 0, 0 end
function echo(s) print((tostring(s):gsub("\27%[[%d;]*m", ""))) end  -- strip colour for clean CI output

local commands = {}
function command(name, fn) commands[name] = fn end                 -- capture (unused; we call directly)

-- Tables the Swift side normally assembles from the registered functions.
panel = { render = panel_render, top = panel_top,
          height = function() return 0 end, top_height = function() return 0 end }
music = { play = noop, stop = noop, volume = noop }

-- Load the real scripts in the same order the client does, so their globals (state, on_update,
-- run_test_suite, _HUD_TEST, _AIP_TEST, …) are all present.
for _, f in ipairs({ "Scripts/AlterAeon.lua", "Scripts/AIPilot.lua", "Scripts/HUD.lua" }) do
  local ok, err = pcall(dofile, f)
  if not ok then io.stderr:write("LOAD ERROR in " .. f .. ": " .. tostring(err) .. "\n"); os.exit(1) end
end

local pass, fail = run_test_suite()
os.exit((fail or 1) == 0 and 0 or 1)                               -- non-zero exit on any failure (CI-friendly)
