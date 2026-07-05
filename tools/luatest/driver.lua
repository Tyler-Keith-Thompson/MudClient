-- CLI entry point for the script test suite (run via tools/luatest/run.sh, from the repo root).
--
-- The game scripts call host builtins that only exist when the Swift client registers them
-- (trigger/alias/echo/panel/ai_*/…). Here we stub those so the scripts load in a bare interpreter,
-- then invoke the SAME `run_test_suite()` the in-app `#test` command uses. Keeping this out of
-- Scripts/ means it never gets auto-loaded or picked up by the Scripts/tests/*.lua glob.

local noop = function() end
for _, n in ipairs({
  "trigger", "alias", "gag", "send",
  "rule_remove", "rule_enable", "class_enable", "class_remove",
  "music_play", "music_stop", "music_volume",
  "panel_render", "panel_top", "panel_height", "panel_top_height",
  "ai_request", "ai_local_request", "ai_set_local_endpoint", "ai_set_local_model",
  "ai_memory_request", "ai_retrieve", "ai_rag_load",
  "ai_set_auth", "ai_set_endpoint", "ai_set_model", "ai_set_memory_endpoint",
  "ai_set_memory_key", "ai_set_memory_model", "ai_usage_reset",
  "unbind", "input_set", "bell",
}) do _G[n] = noop end
function ai_rag_count() return 0 end
function ai_usage() return 0, 0, 0, 0 end
function ai_mem_usage() return 0, 0 end
function echo(s) print((tostring(s):gsub("\27%[[%d;]*m", ""))) end  -- strip colour for clean CI output
-- Terminal/input bridge stubs (bind returns an id; the reads return empty).
local _bindid = 0
function bind() _bindid = _bindid + 1; return _bindid end
function input_get() return "" end
function scrollback() return {} end
function scrollback_find() return {} end

-- Timer bridge stubs. There's no event loop in the CLI harness, so callbacks never auto-fire (just as
-- the old `after` no-op never did); these keep the SAME contract the host now exposes so scripts that
-- store timer ids and cancel() them load and run cleanly: after/every return a unique cancellable id,
-- every marks itself repeating, and cancel removes the entry. Specs that need to observe scheduling
-- override these locally (see pilot_timer_spec).
local _timers, _timer_id = {}, 0
function after(_delay, cb) _timer_id = _timer_id + 1; _timers[_timer_id] = { cb = cb }; return _timer_id end
function every(_delay, cb) _timer_id = _timer_id + 1; _timers[_timer_id] = { cb = cb, repeating = true }; return _timer_id end
function cancel(id) if id ~= nil then _timers[id] = nil end end

-- Tables the Swift side normally assembles from the registered functions.
panel = { render = panel_render, top = panel_top,
          height = function() return 0 end, top_height = function() return 0 end }
music = { play = noop, stop = noop, volume = noop }

-- Load the SAME host bootstrap the engine loads (doc/help registry, the __repl_* pretty-printer, and
-- the legacy command() bridge), so the doc/help and command-bridge specs exercise the real code. Must
-- run after the builtin stubs and the panel/music tables above, and before the game scripts (so their
-- command(...) calls hit the bridge).
do
  local ok, err = pcall(dofile, "Scripts/bootstrap.lua")
  if not ok then io.stderr:write("BOOTSTRAP LOAD ERROR: " .. tostring(err) .. "\n"); os.exit(1) end
end

-- Load the real scripts in the same order the client does, so their globals (state, on_update,
-- run_test_suite, _HUD_TEST, _AIP_TEST, …) are all present.
for _, f in ipairs({ "Scripts/AlterAeon.lua", "Scripts/AIPilot.lua", "Scripts/HUD.lua", "Scripts/Trivia.lua", "Scripts/Equipment.lua" }) do
  local ok, err = pcall(dofile, f)
  if not ok then io.stderr:write("LOAD ERROR in " .. f .. ": " .. tostring(err) .. "\n"); os.exit(1) end
end

local pass, fail = run_test_suite()
os.exit((fail or 1) == 0 and 0 or 1)                               -- non-zero exit on any failure (CI-friendly)
