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
--
-- ============================== THE RULE ==============================
-- EVERY new capability MUST be doc()'d, or the test suite fails:
--   * a new host builtin (Swift `lua.register`) needs a doc() entry here — Lua.register records every
--     registration into `__host_builtins`, and Scripts/tests/doc_coverage_spec.lua fails, BY NAME, on
--     any recorded builtin without documentation;
--   * a new `on_*` hook consulted from Swift (callGlobal and friends) needs a doc() entry in the
--     "hooks" group here — the Swift test `hookDocsCoverSwiftCallSites` scans the Swift sources and
--     fails on any hook call site this file doesn't document;
--   * a new public script API (a member of eq/pilot/kxwt/trivia/panel/music/...) needs a doc() in its
--     own script — the same coverage spec walks those tables.
-- Genuinely-internal helpers use a `__` name prefix, which exempts them from coverage.
-- ======================================================================

--------------------------------------------------------------------------------
-- Documentation registry
--------------------------------------------------------------------------------

-- by_name: name string -> entry.  by_fn: function value -> entry (so help(alias), passing the function,
-- works).  list: insertion-ordered entries (unused by help(), which lists via by_name, but handy for
-- introspection). An entry = { name, sig, text, group, example, topic, hidden, fn }.
__docs = __docs or { by_name = {}, by_fn = {}, list = {} }
-- table value -> a doc NAME or GROUP to show instead, for tables that carry no documented function
-- members of their own. Lets `help(io)` (the stdlib io TABLE — it shadows the "io" doc group) land on
-- the send/echo/bell group, and `help(colors)` land on the colors topic. Weak keys: an alias must
-- never keep a dead table alive.
__docs.table_alias = __docs.table_alias or setmetatable({}, { __mode = "k" })

-- doc(target, info): document `target` (a global-name string OR a function value). info fields:
--   sig     — a one-line signature, e.g. "alias(pattern, handler[, opts]) -> id"
--   text    — 1-3 sentence description
--   group   — grouping key for help()'s listing (default "misc")
--   name    — display name when target is a bare function value
--   example — optional one-line usage example, rendered by help() as `e.g. …` (optional; the coverage
--             spec does not require it)
--   topic   — optional: a how-to topic entry, surfaced by the help() footer hint
--   hidden  — optional: resolvable via help("name") but omitted from listings (for alias entries)
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
  local entry = { name = name, sig = info.sig, text = info.text, group = info.group or "misc",
                  example = info.example, topic = info.topic, hidden = info.hidden, fn = fn }
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

-- The top-level renderer, exported: the echo() coercion wrapper below uses it, and anything else that
-- wants "show me this value the way the REPL would" can too.
__repl_render = render_top

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
-- echo() coercion wrapper
--------------------------------------------------------------------------------

-- Wrap the host `echo` so a wrong argument type is never a silent no-op (the classic REPL footgun:
-- `#echo(test, red)` passes two GLOBALS — the test function and nil — not strings). Text that isn't a
-- string is coerced through the REPL renderer, exactly like `print`-with-taste (a function shows as
-- "function: test" when documented, numbers/booleans naturally, tables shallowly). A nil text argument
-- gets a usage hint instead of printing "nil". A non-string color is dropped (prints plain); unknown
-- color NAMES are reported by the host side (see LuaScriptEngine's echo builtin).
__host_echo = echo    -- the raw host sink, kept reachable (and swappable — specs capture through it)
function echo(text, color)
  if text == nil then
    return __host_echo('echo: expected text — did you mean quotes? e.g. echo("hello", "bright red")',
                       "yellow")
  end
  if type(text) ~= "string" then text = __repl_render(text) end
  if color ~= nil and type(color) ~= "string" then color = nil end
  return __host_echo(text, color)
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

-- __pack_names(names, width, indent) -> array of lines. Greedily flows the space-separated `names`
-- into as few lines as possible, each (including its `indent` leading spaces) at most `width` visible
-- characters wide. Always returns at least one line (the bare indent for an empty list) so callers can
-- ipairs() the result unconditionally. Pure — unit-tested directly.
function __pack_names(names, width, indent)
  indent = indent or 0
  width = math.max(width or 80, indent + 1)
  local pad = string.rep(" ", indent)
  local lines, cur = {}, nil
  for _, name in ipairs(names) do
    if cur == nil then
      cur = pad .. name
    elseif #cur + 1 + #name <= width then
      cur = cur .. " " .. name
    else
      lines[#lines + 1] = cur
      cur = pad .. name
    end
  end
  lines[#lines + 1] = cur or pad
  return lines
end

-- The current terminal width (host-provided via __term_cols; 80 when unavailable), for packing.
local function term_cols()
  if type(__term_cols) == "function" then
    local ok, n = pcall(__term_cols)
    if ok and type(n) == "number" and n > 0 then return math.floor(n) end
  end
  return 80
end

-- List every documented target, grouped; or only the given group. Hidden entries (alias names like
-- "color" for "colors") resolve via help("name") but don't clutter listings.
--   * The full catalog (no group given) packs each group's function NAMES horizontally into columns
--     across the terminal width, so the whole thing fits in ~one screen instead of one line per fn.
--   * A single-group view keeps the readable one-line-summary style (name + first line of its doc).
local function help_list(only_group)
  local groups = {}
  for _, e in pairs(__docs.by_name) do
    local g = e.group or "misc"
    if (only_group == nil or g == only_group) and not e.hidden then
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
  local cols = term_cols()
  for _, g in ipairs(gnames) do
    echo(g, "cyan")
    local es = groups[g]
    table.sort(es, function(a, b) return (a.name or "") < (b.name or "") end)
    if only_group == nil then
      -- Catalog: flow the names horizontally (indented under the group header).
      local names = {}
      for _, e in ipairs(es) do names[#names + 1] = e.name or "?" end
      for _, line in ipairs(__pack_names(names, cols, 2)) do echo(line) end
    else
      -- Single group: one readable summary line per entry.
      for _, e in ipairs(es) do
        echo(string.format("  %-22s %s", e.name or "?", summary(e)))
      end
    end
  end
end

local function has_group(name)
  for _, e in pairs(__docs.by_name) do if (e.group or "misc") == name then return true end end
  return false
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
  if e.example then echo("  e.g. " .. e.example, "dim") end
end

local help_table   -- forward declaration (the alias fallback re-enters help machinery)

-- Document a table by listing its documented function members (e.g. help(panel)). A table with no
-- documented members of its own may still be a known alias (see __docs.table_alias): `help(io)` — the
-- stdlib io table, passed unquoted — renders the "io" doc group; `help(colors)` renders the colors
-- topic entry.
help_table = function(tb)
  local items = {}
  for k, v in pairs(tb) do
    if type(v) == "function" and __docs.by_fn[v] then
      items[#items + 1] = { k = tostring(k), e = __docs.by_fn[v] }
    end
  end
  if #items == 0 then
    local alias = __docs.table_alias[tb]
    if alias then
      if __docs.by_name[alias] then return help_entry(__docs.by_name[alias], tb) end
      if has_group(alias) then return help_list(alias) end
    end
    echo("no documented members", "yellow")
    return
  end
  table.sort(items, function(a, b) return a.k < b.k end)
  for _, it in ipairs(items) do
    echo(string.format("  %-16s %s", it.k, it.e.sig or summary(it.e)))
  end
end

-- help()            — grouped listing of everything documented, plus a usage footer.
-- help(fn)          — full doc for a function value.
-- help("name")      — full doc for a documented name; else, if it's a group, list that group; else, if
--                     it's an existing global, report its type; else "no documentation".
-- help(table)       — list the table's documented members (e.g. help(panel)); a memberless table known
--                     to the alias registry renders its group/topic (e.g. help(io), help(colors)).
function help(x)
  if x == nil then
    -- Also the landing spot for `help(color)`-style typos: an unquoted, undefined global IS nil, so
    -- after the listing point at quoting and the topic entries (colors, …) the user probably wanted.
    help_list(nil)
    local topics = {}
    for _, e in pairs(__docs.by_name) do
      if e.topic and not e.hidden then topics[#topics + 1] = e.name end
    end
    table.sort(topics)
    local hint = 'help("name") shows one entry, help("group") a group — quote the name (an unquoted name is a global).'
    if #topics > 0 then hint = hint .. " Topics: " .. table.concat(topics, ", ") .. "." end
    echo(hint, "dim")
    return
  end
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
-- colors — the named-color help, as a live demo
--------------------------------------------------------------------------------

-- The canonical spec vocabulary, and the SINGLE SOURCE the `colors` list and `colors()` demo are both
-- generated from — add a name here and it appears in both automatically. The HOST resolves specs
-- (LuaScriptEngine.sgrCodes over PanelHost.palette for colors, LuaScriptEngine.attributeCodes for
-- attributes); these lists mirror those for discovery. A spec is space-separated words: at most one
-- base color, `bright` to brighten it ("bright red" and "brightred" are both fine), any attributes,
-- and the advanced `colorN` (256-color) escape hatch.
local BASE_COLORS = { "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white" }
-- Text attributes, in the order colors() lists them. Each is a valid spec word; the host also accepts
-- the aliases faint/italics/reverse/inverse/strike/strikethru (see LuaScriptEngine.attributeCodes).
local ATTRIBUTES  = { "bold", "dim", "italic", "underline", "blink", "reversed", "strikethrough" }

-- `colors` is both a list (its array part holds every name, so `#colors` auto-prints them) and
-- callable: `colors()` prints each name rendered IN that color/attribute — a live palette demo,
-- grouped base / bright / attributes with a footer note about the colorN escape hatch.
colors = {}
for _, c in ipairs(BASE_COLORS) do colors[#colors + 1] = c end
for _, c in ipairs(BASE_COLORS) do colors[#colors + 1] = "bright " .. c end
for _, m in ipairs(ATTRIBUTES) do colors[#colors + 1] = m end
setmetatable(colors, { __call = function()
  echo("color specs: space-separated words — one base color, 'bright' to brighten it, any attributes.", "dim")
  echo('e.g. echo("hi", "bright red")  echo("x", "bold underline red")  ("brightred" fuses too)', "dim")
  echo("base colors:", "cyan")
  for _, c in ipairs(BASE_COLORS) do echo("  " .. c, c) end
  echo("bright:", "cyan")
  for _, c in ipairs(BASE_COLORS) do echo("  bright " .. c, "bright " .. c) end
  echo("attributes:", "cyan")
  for _, m in ipairs(ATTRIBUTES) do echo("  " .. m, m) end
  echo('note: colorN (0-255) is an advanced 256-color escape hatch — e.g. echo("x", "color214").', "dim")
end })

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
  text = "Send a command to the MUD (goes through the on_send hook and alias handling upstream).",
  example = 'send("look")' })
doc("echo",  { sig = "echo(text[, color])", group = "io",
  text = "Print a line to the local display. Non-string text is rendered like a REPL result. color is a spec: one base color, optionally 'bright', plus attributes bold/dim/italic/underline/blink/reversed/strikethrough (or an advanced colorN) — run colors() for a live palette.",
  example = 'echo("ding!", "bright red")' })
doc("bell",  { sig = "bell()", group = "io",
  text = "Ring the bell: plays the macOS system alert sound (audible even when the terminal's own bell is muted, which it usually is) and writes a BEL to the controlling terminal so emulators that flash/badge on a bell still do.",
  example = "bell()" })
doc("copy",  { sig = "copy([n])", group = "terminal",
  text = "Copy the last n scrollback lines (ANSI stripped) to the macOS clipboard; n defaults to 20. Echoes a confirmation with the number of lines copied.",
  example = "copy(50)" })
doc("spellcheck", { sig = "spellcheck(word) -> suggestion|nil", group = "io",
  text = "Native macOS spell-check (NSSpellChecker) of a single word: returns the top English correction if the word is misspelled, or nil if it's fine (or under 2 chars). Local dictionary, no network — fast enough to run per chat word. It only knows English, so game jargon must be filtered by the caller (ChatDecode keeps its own allowlist) before calling. Powers the optional typo pass in decode.",
  example = 'spellcheck("teh")  --> "the"' })

-- colors: the palette topic. help("colors"), help("color"), and help(colors) all land here; calling
-- colors() prints the live demo. The stdlib `io` TABLE aliases to the "io" doc group so an unquoted
-- help(io) still works.
doc("colors", { sig = "colors()", group = "help", topic = true,
  text = "The named colors and text attributes echo/panels accept. Call colors() to print every name rendered in its own style; #colors lists them plainly. Specs combine one base color, 'bright', and attributes (bold/dim/italic/underline/blink/reversed/strikethrough): \"bright red\", \"bold underline red\", \"brightred\". Advanced: colorN (0-255) is a 256-color escape hatch, e.g. \"color214\".",
  example = "colors()" })
doc("color", { sig = "colors()", group = "help", hidden = true,
  text = "Alias of colors — see help(\"colors\") or run colors()." })
__docs.table_alias[colors] = "colors"
if io then __docs.table_alias[io] = "io" end

-- triggers / aliases / gags / rule lifecycle
doc("trigger", { sig = "trigger(pattern, handler[, opts]) -> id", group = "triggers",
  text = "Register a line trigger. handler(line, cap1, …, raw) may return a string (replace the line), false/\"\" (gag), or nil (unchanged). opts = { oneshot=true, class=\"name\", priority=0 }. ALL matching triggers fire, ordered by priority (desc) then pattern SPECIFICITY (desc) then registration order — so specific parsers/rewriters run before broad `.*` observers, which then read the state they wrote. Specificity favours a `^`/`$` anchor and literal characters and penalises `.*`/`.+`; set opts.priority to override.",
  example = "trigger(\"^You are hungry\", function() send(\"eat bread\") end)  -- opts = { priority = 10 } to force early" })
doc("alias", { sig = "alias(pattern, handler[, opts]) -> id", group = "triggers",
  text = "Register an input alias. Matching typed input is swallowed and handler(input, cap1, …) runs. Same opts as trigger() (oneshot/class/priority). The MOST SPECIFIC matching alias wins (priority desc, then specificity desc, then registration order) — a narrow pattern beats a broad one regardless of load order.",
  example = "alias(\"^gg$\", function() send(\"get all from corpse\") end)" })
doc("gag", { sig = "gag(pattern) -> id", group = "triggers",
  text = "Drop every server line matching the pattern. Removable/toggleable by id like any rule.",
  example = "gag(\"^kxwt_\")" })
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
  text = "Call callback() once after `seconds`. Returns a cancellable id.",
  example = "after(2, function() echo(\"two seconds later\") end)" })
doc("every", { sig = "every(seconds, callback) -> id", group = "timers",
  text = "Call callback() repeatedly every `seconds`. Returns a cancellable id.",
  example = "every(60, function() send(\"save\") end)" })
doc("cancel", { sig = "cancel(id)", group = "timers",
  text = "Cancel a pending or repeating timer started by after()/every().",
  example = "t = after(5, f); cancel(t)" })
doc("lag_status", { sig = "lag_status() -> {ui_ms, ui_age_ms, net_ms, net_age_ms}", group = "terminal",
  text = "Latency snapshot separating a LOCAL UI hitch (the terminal's main loop stalling — measured by "
      .. "a heartbeat on the UI queue) from SERVER round-trip (time from your last command to its next "
      .. "prompt). Durations and an age in ms since each was measured (age -1 = never). Powers the HUD "
      .. "lag widget.",
  example = "local s = lag_status(); if s.ui_age_ms >= 0 then echo(\"UI hitch \"..s.ui_ms..\"ms\") end" })

-- connection
doc("connect", { sig = "connect(host[, port])", group = "connection",
  text = "Open (or re-open) the connection. port defaults to 23.",
  example = "connect(\"alteraeon.com\", 3002)" })
doc("disconnect", { sig = "disconnect()", group = "connection", text = "Close the current connection." })
doc("is_connected", { sig = "is_connected() -> bool", group = "connection",
  text = "Whether the socket is currently connected." })
doc("telnet_send", { sig = "telnet_send(option, payload)", group = "connection",
  text = "Send IAC SB <option> <payload> IAC SE, escaping IAC bytes. option is numeric; payload is a byte string.",
  example = "telnet_send(90, \"!!SOUND(ding)\")" })

-- terminal / input
doc("bind", { sig = "bind(keyname, handler) -> id", group = "terminal",
  text = "Register a key macro; handler(keyname) runs when the key is pressed and the key is consumed. Later binds for a key win.",
  example = "bind(\"f5\", function() send(\"cast 'heal'\") end)" })
doc("unbind", { sig = "unbind(id)", group = "terminal", text = "Remove a binding returned by bind()." })
doc("input_get", { sig = "input_get() -> string", group = "terminal", text = "Get the current input-line text." })
doc("input_set", { sig = "input_set(text)", group = "terminal", text = "Replace the input line and redraw it.",
  example = "input_set(\"say hello\")" })
doc("scrollback", { sig = "scrollback(n) -> array", group = "terminal",
  text = "The last n displayed lines (ANSI stripped), oldest-first.",
  example = "scrollback(20)" })
doc("scrollback_find", { sig = "scrollback_find(pattern[, max]) -> array", group = "terminal",
  text = "Up to `max` (default 100) most-recent scrollback lines matching the pattern (ANSI stripped), oldest-first.",
  example = "scrollback_find(\"tells you\", 10)" })

-- session transcript (sent + received) search
doc("grep", { sig = "grep(text)", group = "history",
  text = "Print every transcript line — SENT and RECEIVED — containing `text` (case-insensitive substring), each labeled by kind and (for sends) origin: you-typed vs a script/the AI pilot.",
  example = "#grep orc" })
doc("sent", { sig = "sent([n])", group = "history",
  text = "Print the last n (default 20) commands sent to the server, each labeled by origin (you vs a script/the AI pilot).",
  example = "#sent 10" })
doc("received", { sig = "received([n])", group = "history",
  text = "Print the last n (default 20) lines received (displayed) from the server.",
  example = "#received 10" })

-- logging / replay
doc("log_start", { sig = "log_start(path[, opts]) -> bool", group = "logging",
  text = "Log displayed server lines to a file (appends). opts = { timestamps=bool, ansi=bool, commands=bool }, all default false.",
  example = "log_start(\"session.log\", { commands = true })" })
doc("log_stop", { sig = "log_stop()", group = "logging", text = "Stop the active session log." })
doc("log_active", { sig = "log_active() -> (bool, path|nil)", group = "logging",
  text = "Whether a log is active, and its path." })
doc("replay", { sig = "replay(path[, opts]) -> bool", group = "logging",
  text = "Feed a plain-text file through the normal server-line pipeline (triggers/gags fire), no network, no logging. opts = { speed=lines/sec, quiet=bool }.",
  example = "replay(\"session.log\", { speed = 20 })" })

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

-- Per-category audio masters (see the `volume` command in AlterAeon.lua, which drives these).
doc("msp_volume", { sig = "msp_volume(pct)", group = "audio",
  text = "Set the master volume for MSP sound effects from a 0-100 percentage. Scales every NEW effect; 0 silences them." })
doc("speech_volume", { sig = "speech_volume(pct)", group = "audio",
  text = "Set the TTS voice volume from a 0-100 percentage. At 0 utterances are dropped entirely — never synthesized or played (true silence)." })

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

--------------------------------------------------------------------------------
-- Script loader — `load(path)` (shadows Lua's stdlib `load`; that stays at `loadchunk`)
--------------------------------------------------------------------------------
-- `load(path)` resolves `path` relative to the CWD the client launched from (the repo root):
--   * a file loads that file; the `.lua` extension is assumed when absent
--     (`load("AlterAeon")` == `load("AlterAeon.lua")`);
--   * a directory loads its top-level `*.lua` scripts (`load("Scripts")`), non-recursively.
-- Because top-level script code runs on load, this is also how the app boots (the host runs
-- `load("Scripts")` at startup) and hot-reloads (`reload()` == clear rules + `load("Scripts")`).
--
-- Under the hood every script runs through `require` (a custom package.searcher, below): a module
-- runs ONCE per session, so load order emerges from declared `require(...)` dependencies at the top of
-- scripts rather than a sidecar manifest. There is no manifest.lua. `load(path)` busts the module's
-- cache first so an interactive re-load re-runs it; `reload()` busts the whole script set.
--
-- NAME COLLISION: this shadows the Lua stdlib `load` (compile a chunk from a string/function). The
-- rule is simple and loud: a STRING argument is always a PATH; a non-string (a function, the classic
-- `load(fn)` chunk-reader form) delegates to the stdlib, still reachable as `loadchunk`. Code that
-- means "compile this Lua source string" must call `loadchunk("...")`, not `load`.
loadchunk = loadchunk or load                 -- preserve the stdlib chunk-compiler before we shadow it

-- Directory-loading policy (kept as pure, testable helpers; see Scripts/tests/load_spec.lua):
-- files the directory loader never runs — host-owned (bootstrap) / harness-only (testing).
local LOAD_EXCLUDE = { ["bootstrap.lua"] = true, ["testing.lua"] = true }

-- From a directory's file list, keep the game scripts to load: only `*.lua`, never an excluded file,
-- never a `_`-prefixed file (private/scratch). Order of the input is preserved.
local function load_filter(names)
  local out = {}
  for _, n in ipairs(names) do
    if n:sub(1, 1) ~= "_" and n:match("%.lua$") and not LOAD_EXCLUDE[n] then out[#out + 1] = n end
  end
  return out
end

-- Deterministic directory order: case-insensitive alphabetical. There is NO manifest anymore — load
-- order no longer needs pinning. Cross-script LOAD-TIME dependencies (if any) are declared IN the
-- scripts with `require(...)` at the top, and require's run-once cache pulls a dependency in before
-- its dependents regardless of alphabetical position. Same-LINE trigger firing order (the other thing
-- the old manifest existed for) is now decided by pattern specificity in the Swift engine, not by
-- registration/load order — so a catch-all `.*` observer always fires AFTER the specific parsers on
-- the same line no matter which script loaded first. Sorts and returns `names` in place.
local function load_order(names)
  table.sort(names, function(a, b) return a:lower() < b:lower() end)
  return names
end

--------------------------------------------------------------------------------
-- require() wiring — a custom package.searcher for the script world
--------------------------------------------------------------------------------
-- Scripts load each other (when they have real load-time deps) and the directory loader loads the set
-- via `require(name)`, so a module runs exactly once per session no matter how many paths reach it.
-- This searcher resolves a module name to a Scripts/*.lua file using the SAME host primitives and
-- CWD-relative semantics as load() (via __path_kind), so resolution matches load() exactly — including
-- the test harness, where the driver stubs __path_kind/__run_file against a fake filesystem.

-- Directories searched for a bare module name (require("AlterAeon") -> Scripts/AlterAeon.lua). The
-- directory loader temporarily prepends the directory it is loading (see load()), so a sibling
-- require during a directory load resolves within that same directory.
local SEARCH_ROOTS = { "Scripts", "." }

-- Modules THIS searcher has loaded (name -> resolved path). reload() drops only these from
-- package.loaded, never stdlib entries. A global so it survives bootstrap re-entry in the harness.
__script_loaded = __script_loaded or {}

-- Resolve a module/require name to an existing .lua file path, or nil. A name ending in `.lua` (or an
-- explicit path) is tried verbatim; otherwise `<name>.lua` under each search root, CWD-relative.
local function resolve_script(name)
  local cands = {}
  if name:match("%.lua$") then
    cands[#cands + 1] = name
  else
    cands[#cands + 1] = name .. ".lua"                          -- CWD-relative / explicit path
    for _, root in ipairs(SEARCH_ROOTS) do
      cands[#cands + 1] = root .. "/" .. name .. ".lua"
    end
  end
  for _, p in ipairs(cands) do
    if __path_kind(p) == "file" then return p end
  end
  return nil
end

-- The searcher: return a loader that runs the file in the LIVE global state (scripts communicate via
-- globals, so require's return value is just `true` — the point is run-once + ordering, not modules).
local function script_searcher(name)
  local path = resolve_script(name)
  if not path then return "\n\tno script '" .. name .. "'" end
  return function()
    __script_loaded[name] = path
    __run_file(path)
    return true
  end
end

-- Install once, ahead of the stdlib path searcher, so our CWD-relative resolution wins for script
-- names (matching load()'s semantics). Guarded so a harness re-dofile doesn't stack duplicates.
if not __script_searcher_installed then
  table.insert(package.searchers, 2, script_searcher)
  __script_searcher_installed = true
end

-- The basename module name for a path ("Scripts/HUD.lua" -> "HUD"), so a file loaded by explicit path
-- and the same file loaded by the directory loader share ONE package.loaded identity (load it twice in
-- a session and it re-registers once, not twice).
local function module_of(path)
  return (path:gsub("%.lua$", ""):gsub(".*/", ""))
end

-- Bust a module's cache entry so the next require re-runs it. `load(path)`'s interactive intent is
-- "run it (again) now", so it always busts before requiring; the directory loader does the same per
-- file so a re-load of Scripts/ re-runs everything.
local function bust(mod)
  package.loaded[mod] = nil
  __script_loaded[mod] = nil
end

function load(arg)
  if type(arg) ~= "string" then return loadchunk(arg) end   -- non-string → stdlib chunk-reader
  local kind = __path_kind(arg)
  if kind == "dir" then
    table.insert(SEARCH_ROOTS, 1, arg)                       -- resolve siblings within this dir
    local ok, err = pcall(function()
      for _, n in ipairs(load_order(load_filter(__list_dir(arg)))) do
        local mod = module_of(n)
        bust(mod)                                            -- fresh directory load re-runs each file
        require(mod)
      end
    end)
    table.remove(SEARCH_ROOTS, 1)
    if not ok then error(err, 2) end
  else
    -- A single file OR a bare module name. Route through require (run-once), but bust first so the
    -- interactive `load("HUD")` / `load("Scripts/HUD")` always re-runs. Normalise to the basename so
    -- it shares identity with the directory loader's entry.
    local mod = module_of(arg)
    bust(mod)
    local ok = pcall(require, mod)
    if not ok then error("load: no such script or directory: " .. tostring(arg), 2) end
  end
end

-- reload() — hot-reload: drop OUR modules from the require cache (never stdlib), clear all
-- rules/timers, then re-run the Scripts/ directory. `#reload` / `#ai reload` route here.
function reload()
  for name in pairs(__script_loaded) do package.loaded[name] = nil end
  __script_loaded = {}
  __clear_rules()
  load("Scripts")
end

-- Test seam for the pure loader logic (extension/exclusion/ordering + name resolution); see
-- Scripts/tests/load_spec.lua.
_LOAD_TEST = { filter = load_filter, order = load_order, resolve = resolve_script,
               module_of = module_of }

--------------------------------------------------------------------------------
-- `|` pipe: sequence typed commands on promises
--------------------------------------------------------------------------------
--
-- A `|` on the command line chains commands so each WAITS for the previous to finish:
--
--     recover 95 | attack rat | goto town
--
-- is `recover(95)` then — once vitals reach 95% — `attack("rat")`, then — once the rat dies —
-- `goto("town")`. `|` is a sibling of `;`: `;` fires commands independently (no waiting), `|` waits.
--
-- The host tokenizes the line (InputService.pipeSegments — same swift-parsing escaping as `;`, so `\|`
-- is a literal pipe) and hands us the ordered segment strings; we only build the promise chain, because
-- promises are a Lua concept. Each segment becomes a promise: a segment whose FIRST WORD names a
-- callable global — a function like recover/attack/goto or a callable table like eq/pilot — is CALLED
-- as word("rest"); if that returns a promise (recover/attack do) the chain waits on it, otherwise it
-- just resolves (nothing to await). Any other segment is an ordinary command: it's sent (through the
-- normal alias pipeline, exactly as if you typed it) and resolves at once — so `l`, `kill rat`, and your
-- aliases all work as pass-through steps. This is the same first-word-callable rule the REPL uses for
-- `#word rest` (see legacyRewrite in Swift).
--
-- Chaining is deferred correctly: the head runs now, every later segment is only invoked when its
-- predecessor's promise resolves — so a non-promise action (e.g. `volume 50`) still runs at its turn in
-- the sequence, not eagerly.

local function pipe_is_callable(v)
  if type(v) == "function" then return true end
  if type(v) == "table" then local mt = getmetatable(v); return mt ~= nil and mt.__call ~= nil end
  return false
end

local function pipe_is_promise(x) return type(x) == "table" and x.__is_promise == true end

-- Run ONE segment now and return a promise for its completion (always a promise, so the chain composes).
local function pipe_run_segment(seg)
  seg = (seg or ""):match("^%s*(.-)%s*$")
  if seg == "" then return __promise(function(res) res() end, "pipe") end
  local word, rest = seg:match("^(%S+)%s*(.-)$")
  local fn = word and _G[word]
  if pipe_is_callable(fn) then
    local ok, r = pcall(fn, (rest ~= "" and rest or nil))
    if not ok then return __promise(function(_, rej) rej(r) end, "pipe:" .. word) end
    if pipe_is_promise(r) then return r end
    return __promise(function(res) res() end, "pipe:" .. word)   -- non-promise action: done immediately
  end
  return __promise(function(res) send(seg); res() end, "pipe:" .. seg)  -- ordinary command
end

-- Host entry point (ScriptInterpreter → engine.runPipe). `segments` is the pre-split, pre-unescaped
-- array from InputService.pipeSegments. Builds the promise chain and lets the head auto-start.
-- `__`-prefixed => internal, doc-exempt.
function __pipe(segments)
  if type(segments) ~= "table" or #segments == 0 then return end
  local head = pipe_run_segment(segments[1])
  local chain = head
  for i = 2, #segments do
    local seg = segments[i]
    chain = chain.andThen(function() return pipe_run_segment(seg) end)
  end
  -- Promise widget: show the WHOLE pipe as ONE row (the typed line) for the chain's entire life. The
  -- head auto-registered under its own label (e.g. "recover"); supersede it with the full line on the
  -- final chain promise, which stays pending until the last step resolves.
  if __untrack_promise then __untrack_promise(head) end
  if __track_promise then
    local parts = {}
    for _, s in ipairs(segments) do parts[#parts + 1] = (s or ""):match("^%s*(.-)%s*$") end
    __track_promise(chain, table.concat(parts, " | "))
  end
end

-- `+| <cmd…>` — APPEND to the current in-flight promise instead of starting a new chain. So `recover`
-- then `+| explore` becomes `recover | explore`: the new segments are grafted onto the promise that's
-- already running (via andThen), and the widget row is retitled to the whole line. If nothing's pending
-- ("if possible" fails), we just run the segments as a fresh pipe. Returns true if it appended.
function __pipe_append(segments)
  if type(segments) ~= "table" or #segments == 0 then return false end
  local head = __current_promise and __current_promise()
  if not head then __pipe(segments); return false end   -- nothing to append to → just run it
  local desc = head._track_desc or head.label or "?"
  if __untrack_promise then __untrack_promise(head) end  -- the retitled tail supersedes this row
  local chain, parts = head, {}
  for i = 1, #segments do
    local seg = segments[i]
    chain = chain.andThen(function() return pipe_run_segment(seg) end)
    parts[#parts + 1] = (seg or ""):match("^%s*(.-)%s*$")
  end
  if __track_promise then __track_promise(chain, desc .. " | " .. table.concat(parts, " | ")) end
  return true
end

-- `-|` — the inverse of `+|`: an operator on its own that removes the END (last segment) of the current
-- in-flight promise chain. So after `recover | explore` you can `-|` to drop `explore` and just keep
-- recovering; another `-|` drops `recover` too (a one-segment chain is simply cancelled). If the dropped
-- segment had already STARTED, its cancel hook runs (e.g. `attack` disarms auto-fight). The earlier
-- segments keep running untouched. Returns true if anything was trimmed.
function __pipe_pop()
  local tail = __current_promise and __current_promise()
  if not tail then
    if echo then echo("\27[90m[pipe] nothing in flight to trim\27[0m") end
    return false
  end
  local desc = tail._track_desc or tail.label or "?"
  local dropped = (desc:match("([^|]*)$") or desc):match("^%s*(.-)%s*$")   -- text after the last '|'
  local parent = __pop_tail and __pop_tail(tail)
  if parent then
    -- Retitle the widget row to the chain minus its last segment (cosmetic; falls back if the desc has
    -- no '|' to split on, e.g. a segment that itself contained an escaped pipe).
    local trimmed = desc:match("^(.-)%s*|[^|]*$")
    trimmed = (trimmed and trimmed ~= "" and trimmed) or parent._track_desc or parent.label or dropped
    if __track_promise then __track_promise(parent, trimmed) end
    if echo then echo("\27[90m[pipe] dropped \27[0m" .. dropped .. "\27[90m — now: \27[0m" .. tostring(trimmed)) end
  else
    if echo then echo("\27[90m[pipe] cancelled \27[0m" .. dropped) end
  end
  return true
end

-- Test seam (Scripts/tests/pipe_spec.lua): the per-segment runner + the chain builder + append/pop. (Split
-- + escaping is Swift's job now — InputService.pipeSegments — tested on that side.)
_PIPE_TEST = { run = pipe_run_segment, pipe = __pipe, append = __pipe_append, pop = __pipe_pop,
               callable = pipe_is_callable }

-- scripts / documentation
doc("load", { sig = "load(path)", group = "scripts",
  text = "Load a Lua script or directory, resolved relative to the launch CWD. A directory loads its top-level *.lua scripts (case-insensitive alphabetical) via require(); a single file (the `.lua` extension is assumed if absent) also routes through require but busts its cache first, so an interactive re-load re-runs it. Cross-script load-time deps are declared in-file with require(); the run-once cache means order emerges from dependencies, not a manifest. Shadows stdlib load — a non-string arg delegates to `loadchunk`. `#load {Name}` rewrites to `load(\"Scripts/Name\")`.",
  example = "load(\"Scripts\")   load(\"AlterAeon\")" })
doc("loadchunk", { sig = "loadchunk(chunk[, ...])", group = "scripts",
  text = "Lua's stdlib `load` (compile a chunk from a string or reader function), preserved here because `load` is shadowed by the script loader." })
doc("reload", { sig = "reload()", group = "scripts",
  text = "Hot-reload: drop the script modules from require's cache (never stdlib), clear all triggers/aliases/timers, then re-run `load(\"Scripts\")`. `#reload` and `#ai reload` route here." })
doc("command", { sig = "command(name, handler)", group = "scripts",
  text = "Legacy bridge: define a global function <name> (sanitized) that forwards one string argument to handler. Prefer defining and doc()ing a real function." })
doc("help", { sig = "help([target])", group = "help",
  text = "Documentation. help() lists everything; help(fn|\"name\") shows one entry; help(\"group\") lists a group; help(table) lists documented members.",
  example = "help(\"triggers\")  help(alias)  help(panel)" })
doc("doc", { sig = "doc(target, info)", group = "help",
  text = "Register documentation for a global name or function value. info = { sig, text, group }.",
  example = "doc(\"f\", { sig = \"f(x)\", text = \"Does f.\", group = \"misc\", example = \"f(1)\" })" })

-- Optional hook globals — define a global with the given name to receive the event.
doc("on_connect", { sig = "on_connect()", group = "hooks", text = "hooks: define a global with this name. Fired when the socket connects." })
doc("on_disconnect", { sig = "on_disconnect(reason)", group = "hooks", text = "hooks: define a global with this name. Fired when the socket goes down." })
doc("on_prompt", { sig = "on_prompt(text)", group = "hooks", text = "hooks: define a global with this name. Fired at a GO-AHEAD prompt boundary with the flushed text." })
doc("on_telnet", { sig = "on_telnet(option, payload)", group = "hooks", text = "hooks: define a global with this name. Fired for a telnet subnegotiation (numeric option, raw byte payload)." })
doc("on_telnet_negotiate", { sig = "on_telnet_negotiate(verb, option)", group = "hooks", text = "hooks: define a global with this name. Consulted for a WILL/WONT/DO/DONT option; return \"accept\" or \"reject\" to decide the reply." })
doc("on_send", { sig = "on_send(cmd)", group = "hooks", text = "hooks: define a global with this name. Filter an outbound command: return nil (unchanged), false (suppress), or a string (replace). send() inside is transmitted directly." })
doc("on_resize", { sig = "on_resize(cols, rows)", group = "hooks", text = "hooks: define a global with this name. Fired after the terminal is resized." })
doc("on_mouse", { sig = "on_mouse(event, x, y, button)", group = "hooks", text = "hooks: define a global with this name. Return truthy to consume a mouse event." })
doc("on_user_input", { sig = "on_user_input(cmd)", group = "hooks", text = "hooks: define a global with this name. Observe a typed command (non-swallowing)." })
doc("on_update", { sig = "on_update()", group = "hooks", text = "hooks: define a global with this name. Fired after a batch of server output so the script can refresh panels." })
