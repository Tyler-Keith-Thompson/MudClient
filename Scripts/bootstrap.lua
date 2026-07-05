-- bootstrap.lua — the host's Lua bootstrap, loaded once at engine start AFTER every host builtin is
-- registered (so its doc() calls, and the `panel`/`music` tables it documents, already exist).
--
-- It is NOT a game script: it isn't hot-reloaded and lives outside the `#load`ed set. It provides the
-- pieces that turn `#…` input into a real Lua REPL:
--   * __repl_render / __repl_print — the pretty-printer the REPL uses to auto-print expression results.
--   * doc(target, info) + help(x)  — the documentation registry and its lookup UI.
--   * doc() entries for the entire host builtin surface (and the optional hook globals).
--   * command(name, handler)       — the legacy `command` bridge (defines a global fn + a doc stub).
--   * ai(args)                     — the `#ai …` router (`ai reload` re-runs scripts; else -> ai_command).
--
-- The standalone Lua test harness (tools/luatest/driver.lua) dofile()s this same file, so the doc/help
-- and command-bridge specs run against the real implementation.

--------------------------------------------------------------------------------
-- Documentation registry
--------------------------------------------------------------------------------

-- by_name: name string -> entry.  by_fn: function value -> entry (so help(alias), passing the function,
-- works).  list: insertion-ordered entries (unused by help(), which lists via by_name, but handy for
-- introspection). An entry = { name, sig, text, group, fn }.
__docs = __docs or { by_name = {}, by_fn = {}, list = {} }

-- doc(target, info): document `target` (a global-name string OR a function value). info fields:
--   sig   — a one-line signature, e.g. "alias(pattern, handler[, opts]) -> id"
--   text  — 1-3 sentence description
--   group — grouping key for help()'s listing (default "misc")
--   name  — display name when target is a bare function value
-- When target is a string naming a global function, the function value is indexed too, so help() can be
-- called with either the name or the function.
function doc(target, info)
  if target == nil then return end
  info = info or {}
  local name, fn
  local tt = type(target)
  if tt == "string" then
    name = target
    if type(_G[target]) == "function" then fn = _G[target] end
  elseif tt == "function" then
    fn = target
    name = info.name
  else
    return
  end
  local entry = { name = name, sig = info.sig, text = info.text, group = info.group or "misc", fn = fn }
  if entry.name then __docs.by_name[entry.name] = entry end
  if fn then __docs.by_fn[fn] = entry end
  __docs.list[#__docs.list + 1] = entry
  return entry
end

--------------------------------------------------------------------------------
-- REPL pretty-printer
--------------------------------------------------------------------------------

local MAX_ITEMS = 6        -- how many table entries to show before "N more…"
local MAX_STR   = 48       -- truncate long strings inside a table

local render_table          -- forward declaration (render_val recurses through it)

-- Render a value as it appears INSIDE a table: strings are quoted/truncated, nested tables are bounded
-- by `depth`, functions show their doc name if known.
local function render_val(v, depth)
  local t = type(v)
  if t == "string" then
    local s = v
    if #s > MAX_STR then s = s:sub(1, MAX_STR - 1) .. "…" end
    return '"' .. s .. '"'
  elseif t == "table" then
    if depth <= 0 then return "{…}" end
    return render_table(v, depth)
  elseif t == "function" then
    local d = __docs.by_fn[v]
    return d and ("function: " .. d.name) or "function"
  else
    return tostring(v)
  end
end

-- Shallow, bounded table render: "{1, 2, a=3, b=\"x\", 4 more…}". Array part first (in order), then
-- other keys (unordered). Never renders more than MAX_ITEMS entries; nested depth is capped.
render_table = function(t, depth)
  local parts, shown, total = {}, 0, 0
  local n = #t
  for i = 1, n do
    total = total + 1
    if shown < MAX_ITEMS then parts[#parts + 1] = render_val(t[i], depth - 1); shown = shown + 1 end
  end
  for k, v in pairs(t) do
    local is_seq = (type(k) == "number" and k >= 1 and k <= n and k == math.floor(k))
    if not is_seq then
      total = total + 1
      if shown < MAX_ITEMS then
        local key = (type(k) == "string") and k or ("[" .. tostring(k) .. "]")
        parts[#parts + 1] = key .. "=" .. render_val(v, depth - 1)
        shown = shown + 1
      end
    end
  end
  if total > shown then parts[#parts + 1] = (total - shown) .. " more…" end
  return "{" .. table.concat(parts, ", ") .. "}"
end

-- Top-level render: strings plain (unquoted), numbers/bools plain, tables shallow, functions by name.
local function render_top(v)
  local t = type(v)
  if t == "string" then return v end
  if t == "function" then
    local d = __docs.by_fn[v]
    return d and ("function: " .. d.name) or tostring(v)
  end
  if t == "table" then return render_table(v, 2) end
  return tostring(v)
end

-- Called by the host REPL with an expression's result(s). Zero args (a statement or a void call) prints
-- nothing; otherwise each result is rendered and the line echoed (tab-separated for multiple results).
function __repl_print(...)
  local n = select("#", ...)
  if n == 0 then return end
  local parts = {}
  for i = 1, n do parts[i] = render_top((select(i, ...))) end
  echo(table.concat(parts, "\t"))
end

--------------------------------------------------------------------------------
-- help()
--------------------------------------------------------------------------------

-- Group display order; groups not listed here sort alphabetically after these.
local GROUP_RANK = {
  help = 1, io = 2, triggers = 3, timers = 4, connection = 5, terminal = 6,
  panel = 7, music = 8, logging = 9, ai = 10, scripts = 11, hooks = 12, legacy = 13, misc = 99,
}
local function group_less(a, b)
  local ra, rb = GROUP_RANK[a] or 50, GROUP_RANK[b] or 50
  if ra ~= rb then return ra < rb end
  return a < b
end

-- First line of a doc's text, trimmed/truncated — the one-line summary for a listing.
local function summary(e)
  local s = e.text or e.sig or ""
  s = s:gsub("\n.*$", "")
  if #s > 66 then s = s:sub(1, 65) .. "…" end
  return s
end

-- List every documented target, grouped; or only the given group.
local function help_list(only_group)
  local groups = {}
  for _, e in pairs(__docs.by_name) do
    local g = e.group or "misc"
    if only_group == nil or g == only_group then
      groups[g] = groups[g] or {}
      groups[g][#groups[g] + 1] = e
    end
  end
  local gnames = {}
  for g in pairs(groups) do gnames[#gnames + 1] = g end
  table.sort(gnames, group_less)
  if #gnames == 0 then
    echo(only_group and ("no documented entries in group '" .. only_group .. "'") or "nothing documented", "yellow")
    return
  end
  for _, g in ipairs(gnames) do
    echo(g, "cyan")
    local es = groups[g]
    table.sort(es, function(a, b) return (a.name or "") < (b.name or "") end)
    for _, e in ipairs(es) do
      echo(string.format("  %-22s %s", e.name or "?", summary(e)))
    end
  end
end

-- Full doc for one entry (its function value passed for the undocumented fallback message).
local function help_entry(e, val)
  if not e then
    if val ~= nil then echo(tostring(val) .. " — undocumented " .. type(val), "yellow")
    else echo("no documentation", "yellow") end
    return
  end
  echo(e.sig or e.name or "?", "cyan")
  if e.group then echo("  group: " .. e.group, "dim") end
  if e.text then echo("  " .. e.text) end
end

-- Document a table by listing its documented function members (e.g. help(panel)).
local function help_table(tb)
  local items = {}
  for k, v in pairs(tb) do
    if type(v) == "function" and __docs.by_fn[v] then
      items[#items + 1] = { k = tostring(k), e = __docs.by_fn[v] }
    end
  end
  if #items == 0 then echo("no documented members", "yellow"); return end
  table.sort(items, function(a, b) return a.k < b.k end)
  for _, it in ipairs(items) do
    echo(string.format("  %-16s %s", it.k, it.e.sig or summary(it.e)))
  end
end

local function has_group(name)
  for _, e in pairs(__docs.by_name) do if (e.group or "misc") == name then return true end end
  return false
end

-- help()            — grouped listing of everything documented.
-- help(fn)          — full doc for a function value.
-- help("name")      — full doc for a documented name; else, if it's a group, list that group; else, if
--                     it's an existing global, report its type; else "no documentation".
-- help(table)       — list the table's documented members (e.g. help(panel)).
function help(x)
  if x == nil then return help_list(nil) end
  local t = type(x)
  if t == "function" then return help_entry(__docs.by_fn[x], x) end
  if t == "table" then return help_table(x) end
  if t == "string" then
    if __docs.by_name[x] then return help_entry(__docs.by_name[x], _G[x]) end
    if has_group(x) then return help_list(x) end
    if _G[x] ~= nil then return echo(x .. " — undocumented " .. type(_G[x]), "yellow") end
    return echo("no documentation for '" .. x .. "'", "yellow")
  end
  echo("help: cannot document a " .. t, "yellow")
end

--------------------------------------------------------------------------------
-- Legacy command() bridge
--------------------------------------------------------------------------------

-- command(name, handler): the migration bridge. Instead of a host command registry, it defines a global
-- function <name> (name sanitized to a valid Lua identifier) that forwards its single optional string
-- argument to `handler`, and registers a stub doc. So `command("kxwt", fn)` makes `kxwt("dump 5")`
-- callable, and the REPL's legacy rewrite keeps `#kxwt dump 5` working.
function command(name, handler)
  if type(name) ~= "string" or type(handler) ~= "function" then return end
  local g = name:gsub("[^%w]", "_")
  _G[g] = function(arg) return handler(arg) end
  doc(g, { sig = g .. "([arg])",
           text = "migrated legacy command; takes a single string argument",
           group = "legacy" })
  return g
end

-- ai(args): the `#ai …` control surface. `ai reload` re-runs the loaded scripts; anything else is
-- forwarded to the pilot's `ai_command` global (defined later by the game scripts).
function ai(args)
  args = args or ""
  local trimmed = args:match("^%s*(.-)%s*$")
  if trimmed:lower() == "reload" then return reload() end
  if ai_command then return ai_command(trimmed) end
end

--------------------------------------------------------------------------------
-- Docs for the host builtin surface
--------------------------------------------------------------------------------

-- io / core
doc("send",  { sig = "send(text)", group = "io",
  text = "Send a command to the MUD (goes through the on_send hook and alias handling upstream)." })
doc("echo",  { sig = "echo(text[, color])", group = "io",
  text = "Print a line to the local display. Optional color: red/green/yellow/blue/magenta/cyan/white/dim." })
doc("bell",  { sig = "bell()", group = "io", text = "Ring the terminal bell." })

-- triggers / aliases / gags / rule lifecycle
doc("trigger", { sig = "trigger(pattern, handler[, opts]) -> id", group = "triggers",
  text = "Register a line trigger. handler(line, cap1, …, raw) may return a string (replace the line), false/\"\" (gag), or nil (unchanged). opts = { oneshot=true, class=\"name\" }." })
doc("alias", { sig = "alias(pattern, handler[, opts]) -> id", group = "triggers",
  text = "Register an input alias. Matching typed input is swallowed and handler(input, cap1, …) runs. Same opts as trigger()." })
doc("gag", { sig = "gag(pattern) -> id", group = "triggers",
  text = "Drop every server line matching the pattern. Removable/toggleable by id like any rule." })
doc("rule_remove", { sig = "rule_remove(id)", group = "triggers",
  text = "Remove the trigger, alias, or gag with this id." })
doc("rule_enable", { sig = "rule_enable(id, on)", group = "triggers",
  text = "Enable or disable a single rule; disabled rules don't match." })
doc("class_enable", { sig = "class_enable(name, on)", group = "triggers",
  text = "Enable or disable every trigger/alias tagged with class `name`." })
doc("class_remove", { sig = "class_remove(name)", group = "triggers",
  text = "Remove every trigger/alias tagged with class `name`." })

-- timers
doc("after", { sig = "after(seconds, callback) -> id", group = "timers",
  text = "Call callback() once after `seconds`. Returns a cancellable id." })
doc("every", { sig = "every(seconds, callback) -> id", group = "timers",
  text = "Call callback() repeatedly every `seconds`. Returns a cancellable id." })
doc("cancel", { sig = "cancel(id)", group = "timers",
  text = "Cancel a pending or repeating timer started by after()/every()." })

-- connection
doc("connect", { sig = "connect(host[, port])", group = "connection",
  text = "Open (or re-open) the connection. port defaults to 23." })
doc("disconnect", { sig = "disconnect()", group = "connection", text = "Close the current connection." })
doc("is_connected", { sig = "is_connected() -> bool", group = "connection",
  text = "Whether the socket is currently connected." })
doc("telnet_send", { sig = "telnet_send(option, payload)", group = "connection",
  text = "Send IAC SB <option> <payload> IAC SE, escaping IAC bytes. option is numeric; payload is a byte string." })

-- terminal / input
doc("bind", { sig = "bind(keyname, handler) -> id", group = "terminal",
  text = "Register a key macro; handler(keyname) runs when the key is pressed and the key is consumed. Later binds for a key win." })
doc("unbind", { sig = "unbind(id)", group = "terminal", text = "Remove a binding returned by bind()." })
doc("input_get", { sig = "input_get() -> string", group = "terminal", text = "Get the current input-line text." })
doc("input_set", { sig = "input_set(text)", group = "terminal", text = "Replace the input line and redraw it." })
doc("scrollback", { sig = "scrollback(n) -> array", group = "terminal",
  text = "The last n displayed lines (ANSI stripped), oldest-first." })
doc("scrollback_find", { sig = "scrollback_find(pattern[, max]) -> array", group = "terminal",
  text = "Up to `max` (default 100) most-recent scrollback lines matching the pattern (ANSI stripped), oldest-first." })

-- logging / replay
doc("log_start", { sig = "log_start(path[, opts]) -> bool", group = "logging",
  text = "Log displayed server lines to a file (appends). opts = { timestamps=bool, ansi=bool, commands=bool }, all default false." })
doc("log_stop", { sig = "log_stop()", group = "logging", text = "Stop the active session log." })
doc("log_active", { sig = "log_active() -> (bool, path|nil)", group = "logging",
  text = "Whether a log is active, and its path." })
doc("replay", { sig = "replay(path[, opts]) -> bool", group = "logging",
  text = "Feed a plain-text file through the normal server-line pipeline (triggers/gags fire), no network, no logging. opts = { speed=lines/sec, quiet=bool }." })

-- panel (bottom status HUD) / top panel
if panel then
  doc(panel.render, { name = "panel.render", sig = "panel.render(spec)", group = "panel",
    text = "Replace the bottom status panel with a declarative spec (a list of styled rows/columns)." })
  doc(panel.height, { name = "panel.height", sig = "panel.height(n)", group = "panel",
    text = "Pin the bottom panel's height to n rows." })
  doc(panel.top, { name = "panel.top", sig = "panel.top(spec)", group = "panel",
    text = "Replace the top panel (e.g. group roster) with a declarative spec." })
  doc(panel.top_height, { name = "panel.top_height", sig = "panel.top_height(n)", group = "panel",
    text = "Pin the top panel's height to n rows." })
end

-- music (layered named audio)
if music then
  doc(music.play, { name = "music.play", sig = "music.play(channel, track)", group = "music",
    text = "Play a named track on a named channel (a file from the configured sound dir)." })
  doc(music.stop, { name = "music.stop", sig = "music.stop(channel)", group = "music",
    text = "Stop playback on a channel." })
  doc(music.volume, { name = "music.volume", sig = "music.volume(pct)", group = "music",
    text = "Set master volume from a 0-100 percentage." })
end

-- AI / LLM bridge
doc("ai", { sig = "ai(args)", group = "ai",
  text = "AI pilot control surface. `ai reload` re-runs the loaded scripts; any other text is forwarded to the pilot's ai_command handler." })
doc("ai_request", { sig = "ai_request(system, user, max_tokens, tools_json, assistant_prefix, cb)", group = "ai",
  text = "Async decision-model completion. cb(reply, tool_calls_json, err). tools_json/assistant_prefix may be nil/\"\"." })
doc("ai_local_request", { sig = "ai_local_request(system, user, max_tokens, prefix, cb[, model])", group = "ai",
  text = "Async completion against the LOCAL model (never a paid API), for cheap always-on features. cb(reply, err). Optional model overrides the pinned local model for this call." })
doc("ai_memory_request", { sig = "ai_memory_request(system, user, max_tokens, cb)", group = "ai",
  text = "Async completion against the separately-configured memory-head client. cb(reply, err). No tools or prefill." })
doc("ai_retrieve", { sig = "ai_retrieve(query, k, cb)", group = "ai",
  text = "Retrieve the top-k doc passages from the RAG index. cb(chunks_json, err)." })
doc("ai_rag_load", { sig = "ai_rag_load(path)", group = "ai", text = "Load the prebuilt RAG doc index from `path`." })
doc("ai_rag_count", { sig = "ai_rag_count() -> int", group = "ai", text = "Number of chunks in the loaded RAG index." })
doc("ai_set_endpoint", { sig = "ai_set_endpoint(url)", group = "ai", text = "Set the decision client's API endpoint." })
doc("ai_set_model", { sig = "ai_set_model(id)", group = "ai", text = "Set the decision client's model id." })
doc("ai_set_auth", { sig = "ai_set_auth(on)", group = "ai",
  text = "Point the decision client at Anthropic (keychain key + native /v1/messages for caching) when on, or back to the local model." })
doc("ai_set_local_endpoint", { sig = "ai_set_local_endpoint(url)", group = "ai",
  text = "Override the local client's endpoint (default LM Studio at http://localhost:1234/v1)." })
doc("ai_set_local_model", { sig = "ai_set_local_model(id)", group = "ai", text = "Set the local client's model id." })
doc("ai_set_memory_endpoint", { sig = "ai_set_memory_endpoint(url)", group = "ai", text = "Set the memory-head client's endpoint." })
doc("ai_set_memory_model", { sig = "ai_set_memory_model(id)", group = "ai", text = "Set the memory-head client's model id." })
doc("ai_set_memory_key", { sig = "ai_set_memory_key(key)", group = "ai", text = "Set the memory-head client's auth key." })
doc("ai_usage", { sig = "ai_usage() -> (in, out, cache_read, cache_write)", group = "ai",
  text = "Decision-brain token counts, for cost reporting." })
doc("ai_mem_usage", { sig = "ai_mem_usage() -> (in, out, cache_read, cache_write)", group = "ai",
  text = "Memory-head token counts, for cost reporting." })
doc("ai_usage_reset", { sig = "ai_usage_reset()", group = "ai", text = "Reset the decision-brain and memory-head token counters." })

-- scripts / documentation
doc("load_script", { sig = "load_script(name)", group = "scripts",
  text = "Load (or hot-reload) Scripts/<name>.lua and remember it so reload() re-runs it. Also handles the braced `{Name}` form. `#load {Name}` rewrites to this." })
doc("reload", { sig = "reload()", group = "scripts",
  text = "Re-run every loaded script live (clears triggers/aliases/timers first). `#reload` rewrites to this." })
doc("command", { sig = "command(name, handler)", group = "scripts",
  text = "Legacy bridge: define a global function <name> (sanitized) that forwards one string argument to handler. Prefer defining and doc()ing a real function." })
doc("help", { sig = "help([target])", group = "help",
  text = "Documentation. help() lists everything; help(fn|\"name\") shows one entry; help(\"group\") lists a group; help(table) lists documented members." })
doc("doc", { sig = "doc(target, info)", group = "help",
  text = "Register documentation for a global name or function value. info = { sig, text, group }." })

-- Optional hook globals — define a global with the given name to receive the event.
doc("on_connect", { sig = "on_connect()", group = "hooks", text = "hooks: define a global with this name. Fired when the socket connects." })
doc("on_disconnect", { sig = "on_disconnect(reason)", group = "hooks", text = "hooks: define a global with this name. Fired when the socket goes down." })
doc("on_prompt", { sig = "on_prompt(text)", group = "hooks", text = "hooks: define a global with this name. Fired at a GO-AHEAD prompt boundary with the flushed text." })
doc("on_telnet", { sig = "on_telnet(option, payload)", group = "hooks", text = "hooks: define a global with this name. Fired for a telnet subnegotiation (numeric option, raw byte payload)." })
doc("on_send", { sig = "on_send(cmd)", group = "hooks", text = "hooks: define a global with this name. Filter an outbound command: return nil (unchanged), false (suppress), or a string (replace). send() inside is transmitted directly." })
doc("on_resize", { sig = "on_resize(cols, rows)", group = "hooks", text = "hooks: define a global with this name. Fired after the terminal is resized." })
doc("on_mouse", { sig = "on_mouse(event, x, y, button)", group = "hooks", text = "hooks: define a global with this name. Return truthy to consume a mouse event." })
doc("on_user_input", { sig = "on_user_input(cmd)", group = "hooks", text = "hooks: define a global with this name. Observe a typed command (non-swallowing)." })
doc("on_update", { sig = "on_update()", group = "hooks", text = "hooks: define a global with this name. Fired after a batch of server output so the script can refresh panels." })
