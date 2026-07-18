-- CLI entry point for the script test suite (run via tools/luatest/run.sh, from the repo root).
--
-- The game scripts call host builtins that only exist when the Swift client registers them
-- (trigger/alias/echo/panel/ai_*/…). Here we stub those so the scripts load in a bare interpreter,
-- then invoke the SAME `run_test_suite()` the in-app `#test` command uses. Keeping this out of
-- Scripts/ means it never gets auto-loaded or picked up by the Scripts/tests/*.lua glob.
--
-- Every stub is recorded in `__host_builtins`, mirroring what the real host's Lua.register does, so
-- the doc-coverage spec (Scripts/tests/doc_coverage_spec.lua) enforces documentation for the whole
-- builtin surface in THIS harness too, not just in-app. Adding a builtin in Swift means adding its
-- stub here (or scripts won't load) — and the moment it's here, it must be doc()'d in bootstrap.lua.
__host_builtins = {}
local function stub(name, fn)
  _G[name] = fn or function() end           -- a DISTINCT closure per name (by-value doc lookups must
  __host_builtins[name] = true              -- not smear across builtins through one shared noop)
end
for _, n in ipairs({
  "trigger", "alias", "gag", "send",
  "rule_remove", "rule_enable", "class_enable", "class_remove",
  "untrigger", "unalias", "ungag",
  "music_play", "music_stop", "music_volume", "music_midi", "music_midi_reset", "msp_volume", "speech_volume",
  "sound_once",
  "panel_render", "panel_top", "panel_height", "panel_top_height",
  "ai_request", "ai_local_request", "ai_local_tools_request", "ai_set_local_endpoint", "ai_set_local_model",
  "ai_memory_request", "ai_retrieve", "ai_rag_load",
  "ai_set_auth", "ai_set_endpoint", "ai_set_model", "ai_set_memory_endpoint",
  "ai_set_memory_key", "ai_set_memory_model", "ai_usage_reset",
  "unbind", "input_set", "bell", "copy", "disconnect", "is_connected", "connect", "telnet_send", "on_stream",
  "net_connect", "net_send", "net_disconnect", "net_is_connected", "feed_server",
  "log_start", "log_stop", "log_active", "replay",
  "grep", "sent", "received", "claude", "chat",
  "speak", "speech_stop",
}) do stub(n) end
-- Speech / live-vs-history stubs (SpeechService + SpeechBuiltins). is_live defaults to true so specs
-- run "as if live"; speech_voices returns a small canned voice list so Speech.lua's assignment logic
-- has voices to work with. Specs override these locally to exercise the gating/assignment paths.
stub("is_live", function() return true end)
stub("speech_voices", function()
  return { { name = "Alex", locale = "en_US" }, { name = "Samantha", locale = "en_US" },
           { name = "Daniel", locale = "en_GB" }, { name = "Karen", locale = "en_AU" } }
end)
-- Script-loader primitives the pure-Lua `load`/`reload` (bootstrap.lua) stand on. `__`-prefixed, so
-- doc-exempt; scripts don't call them at load time, so these defaults just keep load()/reload()
-- callable in the harness (load_spec overrides them to drive the loader against a fake filesystem).
stub("__path_kind", function() return "missing" end)
stub("__list_dir", function() return {} end)
stub("__run_file", function() return true end)
stub("__clear_rules")
stub("__term_cols", function() return 80 end)   -- internal (__-prefixed): help() packs to this width
stub("lag_status", function() return { ui_ms = 0, ui_age_ms = -1, net_ms = 0, net_age_ms = -1 } end)
stub("ai_rag_count", function() return 0 end)
stub("ai_usage", function() return 0, 0, 0, 0 end)
stub("ai_mem_usage", function() return 0, 0 end)
stub("echo", function(s) print((tostring(s):gsub("\27%[[%d;]*m", ""))) end)  -- strip colour for clean CI output
-- Terminal/input bridge stubs (bind returns an id; the reads return empty).
local _bindid = 0
stub("bind", function() _bindid = _bindid + 1; return _bindid end)
stub("input_get", function() return "" end)
stub("scrollback", function() return {} end)
stub("scrollback_find", function() return {} end)
-- spellcheck defaults to "everything is spelled fine" (nil) so the typo pass is inert in CI; the
-- chatdecode spec overrides the global to drive the correction path.
stub("spellcheck", function() return nil end)

-- Timer bridge stubs. There's no event loop in the CLI harness, so callbacks never auto-fire (just as
-- the old `after` no-op never did); these keep the SAME contract the host now exposes so scripts that
-- store timer ids and cancel() them load and run cleanly: after/every return a unique cancellable id,
-- every marks itself repeating, and cancel removes the entry. Specs that need to observe scheduling
-- override these locally (see pilot_timer_spec).
local _timers, _timer_id = {}, 0
stub("after", function(_delay, cb) _timer_id = _timer_id + 1; _timers[_timer_id] = { cb = cb }; return _timer_id end)
stub("every", function(_delay, cb) _timer_id = _timer_id + 1; _timers[_timer_id] = { cb = cb, repeating = true }; return _timer_id end)
stub("cancel", function(id) if id ~= nil then _timers[id] = nil end end)

-- Tables the Swift side normally assembles from the registered functions.
panel = { render = panel_render, top = panel_top,
          height = panel_height, top_height = panel_top_height }
music = { play = music_play, stop = music_stop, volume = music_volume,
          midi = music_midi, midi_reset = music_midi_reset }

-- Load the SAME host bootstrap the engine loads (doc/help registry, the __repl_* pretty-printer, and
-- the legacy command() bridge), so the doc/help and command-bridge specs exercise the real code. Must
-- run after the builtin stubs and the panel/music tables above, and before the game scripts (so their
-- command(...) calls hit the bridge).
do
  local ok, err = pcall(dofile, "Scripts/bootstrap.lua")
  if not ok then io.stderr:write("BOOTSTRAP LOAD ERROR: " .. tostring(err) .. "\n"); os.exit(1) end
end

-- Load the real scripts in the same (case-insensitive alphabetical) order the client's directory
-- loader now uses — AIPilot BEFORE AlterAeon — so their globals (state, on_update, run_test_suite,
-- _HUD_TEST, _AIP_TEST, …) are all present AND the defensive `state = state or {}` decoupling is
-- exercised under the real order (there is no manifest pinning AlterAeon first anymore).
for _, f in ipairs({ "Scripts/AlterAeon/AIPilot.lua", "Scripts/AlterAeon/AlterAeon.lua", "Scripts/AlterAeon/Audio.lua",
                     "Scripts/AlterAeon/AutoFight.lua", "Scripts/AlterAeon/BookDump.lua", "Scripts/AlterAeon/ChatDecode.lua",
                     "Scripts/AlterAeon/Combat.lua", "Scripts/AlterAeon/Corpse.lua", "Scripts/AlterAeon/DCast.lua",
                     "Scripts/AlterAeon/Equipment.lua", "Scripts/AlterAeon/HUD.lua", "Scripts/Foundation/Promise.lua",
                     "Scripts/AlterAeon/Prompt.lua", "Scripts/AlterAeon/Recovery.lua", "Scripts/AlterAeon/RPC.lua",
                     "Scripts/AlterAeon/Soulforge.lua", "Scripts/AlterAeon/Speech.lua", "Scripts/AlterAeon/Trivia.lua" }) do
  local ok, err = pcall(dofile, f)
  if not ok then io.stderr:write("LOAD ERROR in " .. f .. ": " .. tostring(err) .. "\n"); os.exit(1) end
end

local pass, fail = run_test_suite()
os.exit((fail or 1) == 0 and 0 or 1)                               -- non-zero exit on any failure (CI-friendly)
