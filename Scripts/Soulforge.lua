-- Soulforge — auto-merge low-level soulstones upward toward pale blue (or deep blue when pale is
-- plentiful), the same way you'd sit and hand-cast `soulforge` over and over between fights.
--
-- soulsteal (AutoFight.lua) drops a stream of low-tier soulstones — red/yellow/green — that are near
-- worthless on their own. The `soulforge` spell merges TWO stones into one of a (usually) higher tier;
-- doing that repeatedly walks a bag of junk stones up to the pale/deep blue ones that are actually worth
-- carrying. This script automates that grind: read what you're carrying, cast the merge on the two best
-- candidates, wait for the result, re-read, repeat — until nothing's left worth merging.
--
-- WHY ORDINALS, NEVER COLOR WORDS (the load-bearing detail): the cast targets stones by their inventory
-- ORDINAL — `c soulforge 1.soulstone 2.soulstone` (the 1st and 2nd items matching keyword "soulstone",
-- counted top-down). It does NOT say `c soulforge red green`. Color words false-positive on GEAR: a "red
-- dragonscale" or a "green cloak" also matches the color keyword, so a color-worded cast can grab a piece
-- of equipment instead of a stone. Ordinals scoped to the "soulstone" keyword can only ever hit stones.
-- We derive the ordinals here from state.inventory (which AlterAeon.lua parses from the `inventory`
-- output — kxwt never pushes what you carry, so we send `inv` and let it repopulate).
--
-- MERGE POLICY (deterministic, tier order red<yellow<green<pale<deep<purple):
--   * everything below pale blue is "raw" and always gets pushed up;
--   * pale blue is raw ONLY when it's plentiful (>= pale_lots) AND merging still leaves keep_pale on
--     hand — so we bank a stash of pale and only spend the SURPLUS climbing to deep blue;
--   * deep blue and purple are never merged (they're the goal, not fuel).
-- Among raw stones we PREFER a same-color pair (lowest tier first — clear the junk), and only mix two
-- different colors when no color has a pair left. Every successful forge consumes 2 stones and yields 1,
-- so the pile strictly shrinks — the loop is bounded; a safety guard also bails after a few re-inventories
-- that don't reduce the count, and on out-of-mana / cancel / a watchdog idle.
--
-- ARCHITECTURE (promise + watchdog, following Equipment.lua's eq_begin/eq_settle/eq_touch): soulforge()
-- is ONE tracked promise (shows in the HUD promise widget, chainable — recover().andThen(soulforge())).
-- It fans out through paced re-inventories and cast-result triggers with several early-return paths, so a
-- missed terminal would leak a widget row forever (the corpse-widget lesson). A watchdog, RE-ARMED on
-- every real step (sf_touch), force-settles the op if it ever goes quiet. Cast failures RECAST the same
-- command (the skill can just fizzle); a bad-selection reply re-inventories and re-plans.
--
-- Controls:  soulforge · soulforge off · soulforge status;  help(soulforge). Hot-reloadable.

state = state or {}   -- defensive: this file may load before AlterAeon.lua under the directory loader.

local cfg = {
  pale_lots       = 4,    -- once you hold this many pale blue, start spending the SURPLUS climbing to deep
  keep_pale       = 2,    -- ...but never merge pale below this many on hand (a working stash)
  inv_wait        = 0.6,  -- seconds after sending `inv` before we read the repopulated state.inventory
  recast_wait     = 0.4,  -- seconds to wait before re-sending the SAME cast after a fizzle (anti-spam)
  gather_wait     = 1.0,  -- backstop: quiet time after a container `get`/`put` with no reply before moving on
  max_no_progress = 3,    -- bail after this many re-inventories that DON'T reduce the soulstone count
  stow            = true, -- after each forge pass, PUT the soulstones back into the source container
}

-- Idle seconds with no progress before the watchdog force-settles the op (so a widget row can't leak if a
-- result line never arrives). Generous — a between-fights forge grind is slow and manual-pace by design.
local SF_IDLE = 30

-- Tier order. Everything below pale is fuel; deep/purple are the goal.
local TIER = { red = 1, yellow = 2, green = 3, pale = 4, deep = 5, purple = 6 }
-- Display-name colour phrases that collapse to a single tier key ("a pale blue soulstone" -> "pale").
local COLOR_ALIAS = { ["pale blue"] = "pale", ["deep blue"] = "deep" }
local TIER_LABEL = { red = "red", yellow = "yellow", green = "green",
                     pale = "pale blue", deep = "deep blue", purple = "purple" }

local function say(s) if echo then echo("\27[1;35m[soulforge]\27[0m " .. s) end end

-- ---- pure helpers (the merge brain; unit-tested via _SF_TEST) -------------------------------------

-- soulstone_color("a pale blue soulstone") -> "pale" (or nil if it isn't a recognised soulstone). Parses
-- the colour phrase out of the display name and maps it to a tier key. Anything whose colour we don't
-- recognise returns nil so planning skips it (we never merge a stone we can't tier).
-- tier_key("Pale Blue") -> "pale" (normalises a bare colour PHRASE — as captured from a forge-result line
-- — to a tier key; nil if unrecognised). soulstone_color reuses it after stripping the item wrapper.
local function tier_key(phrase)
  if type(phrase) ~= "string" then return nil end
  local c = phrase:lower():gsub("^%s+", ""):gsub("%s+$", "")
  c = COLOR_ALIAS[c] or c
  return TIER[c] and c or nil
end

local function soulstone_color(name)
  if type(name) ~= "string" then return nil end
  local c = name:match("^%s*[Aa]n?%s+(.-)%s+soulstone%s*%.?%s*$")
  return c and tier_key(c) or nil
end

local function tier(color) return TIER[color] end

-- parse_soulstones(inventory) -> ordered list of { ord, name, color }. `ord` is the game's `N.soulstone`
-- ordinal: the Nth item matching keyword "soulstone" in inventory order. EVERY soulstone-keyword item
-- takes an ordinal slot (even one whose colour we don't recognise — it still shifts the numbering), but
-- `color` is nil for those so the planner won't pick them.
local function parse_soulstones(inventory)
  local out, n = {}, 0
  for _, name in ipairs(inventory or {}) do
    if type(name) == "string" and name:lower():find("soulstone", 1, true) then
      n = n + 1
      out[#out + 1] = { ord = n, name = name, color = soulstone_color(name) }
    end
  end
  return out
end

local function count_color(stones, color)
  local n = 0
  for _, s in ipairs(stones) do if s.color == color then n = n + 1 end end
  return n
end

-- The tier we're climbing TOWARD: pale blue normally, but deep blue once pale is plentiful (so a big pile
-- of pale keeps climbing instead of stalling at pale). Purely informational (for the done summary) — the
-- actual "should this stone merge" decision is is_raw below.
local function target_tier(stones)
  return (count_color(stones, "pale") >= cfg.pale_lots) and TIER.deep or TIER.pale
end

-- is_raw(color, stones) — is a stone of this colour fuel we should merge, given the whole pile?
--   * below pale (red/yellow/green): always — push everything up to pale.
--   * pale: only the SURPLUS — plentiful (>= pale_lots) AND merging still leaves > keep_pale on hand.
--   * deep/purple: never (the goal, not fuel).
local function is_raw(color, stones)
  local t = TIER[color]
  if not t then return false end
  if t < TIER.pale then return true end
  if color == "pale" then
    local n = count_color(stones, "pale")
    return n >= cfg.pale_lots and n > cfg.keep_pale
  end
  return false
end

-- plan_next_forge(stones) -> { a=ord1, b=ord2 } (ord1 < ord2) for the next merge, or nil when nothing's
-- worth merging (fewer than two raw stones). Always CONSUMES THE LOWEST-TIER raw stone so low junk never
-- gets stranded: it pairs that stone with a SAME-colour partner when one exists (similar-level merges are
-- most effective), and otherwise MIXES it with the next-lowest raw stone — so a lone red combines with a
-- green/pale instead of sitting there while pales pair up around it. Pure — the whole policy lives here.
local function plan_next_forge(stones)
  local raw = {}
  for _, s in ipairs(stones) do
    if s.color and is_raw(s.color, stones) then raw[#raw + 1] = s end
  end
  if #raw < 2 then return nil end

  -- Lowest tier first (ties by inventory order) — that stone is the one we consume this merge.
  table.sort(raw, function(x, y)
    if TIER[x.color] ~= TIER[y.color] then return TIER[x.color] < TIER[y.color] end
    return x.ord < y.ord
  end)
  local lowest = raw[1]

  -- Prefer a SAME-colour partner for the lowest stone (a similar-level merge); scan in tier/ordinal order
  -- so it takes the nearest same-colour one.
  local partner
  for i = 2, #raw do
    if raw[i].color == lowest.color then partner = raw[i]; break end
  end
  -- No same-colour partner → MIX it with the next-lowest raw stone, consuming the low stone rather than
  -- leaving it stranded (the "different colours when that's all that's left" case, per stone).
  partner = partner or raw[2]

  local a, b = lowest.ord, partner.ord
  if a > b then a, b = b, a end
  return { a = a, b = b }
end

-- The exact wire command for a planned merge — ORDINALS scoped to the soulstone keyword (see the header:
-- color words would false-positive on gear).
local function forge_cmd(pair)
  return string.format("c soulforge %d.soulstone %d.soulstone", pair.a, pair.b)
end

-- ---- in-memory inventory model (so we don't re-read `inv` after every cast) ------------------------
-- After the FIRST real inventory read we keep our OWN ordered model of carried soulstones and update it
-- from each forge-result line (which names exactly what was produced and what the base was), instead of
-- re-sending `inv` every merge. renumber keeps each entry's .ord == its 1-based position, which IS the
-- game's `N.soulstone` numbering. We only fall back to a real `inv` if the model ever desyncs (see
-- apply_forge's false return / the bad-selection handler) — self-correcting, but rare.
local function renumber(model) for i, s in ipairs(model) do s.ord = i end end

-- Apply a forge to the model: the pair we cast (ords a, b) collapses to ONE stone of result_color — the
-- BASE stone (the one the game line calls "as a base") is upgraded IN PLACE and the other is consumed.
-- base_color disambiguates which of a/b survived (arbitrary for a same-colour pair — keep the lower slot).
-- Returns false when the ords aren't found or the colours don't match what the model expected (a desync,
-- so the caller re-inventories instead of trusting a wrong update).
local function apply_forge(model, a, b, result_color, base_color)
  if not result_color then return false end
  local ia, ib
  for i, s in ipairs(model) do
    if s.ord == a then ia = i elseif s.ord == b then ib = i end
  end
  if not ia or not ib then return false end
  local ca, cb = model[ia].color, model[ib].color
  if base_color and base_color ~= ca and base_color ~= cb then return false end   -- model desynced
  local survive, remove = ia, ib
  if base_color and cb == base_color and ca ~= base_color then survive, remove = ib, ia end
  model[survive].color = result_color
  table.remove(model, remove)
  renumber(model)
  return true
end

-- ---- carried containers (pull soulstones OUT before forging) --------------------------------------
-- soulforge only merges stones in your MAIN inventory (help: "another soulstone in your inventory"), but
-- the good stash usually lives in a pocket dimension / small sack / icy vortex. So before forging we look
-- through carried containers and pull every soulstone into inventory. Container keywords cover the common
-- carriers plus generic bag words (all verified from real play: `get soulstone sack/dimension/vortex`).
local CONTAINER_KW = { "sack", "bag", "backpack", "pack", "pouch", "chest", "box", "quiver", "basket",
                       "container", "purse", "case", "satchel", "crate", "barrel", "trunk", "dimension",
                       "vortex", "distortion", "pocket" }
local function looks_like_container(name)
  if type(name) ~= "string" then return false end
  local n = name:lower()
  if n:find("soulstone", 1, true) then return false end   -- a stone is never a container
  for _, kw in ipairs(CONTAINER_KW) do if n:find(kw, 1, true) then return true end end
  return false
end

-- The keyword AA wants for `get <x> <container>` is the container's LAST noun: "a small sack" -> "sack",
-- "a pocket dimension" -> "dimension", "an icy vortex" -> "vortex" (all confirmed in traces).
local function container_kw(name)
  return (type(name) == "string") and name:match("(%a+)%s*%.?%s*$") or nil
end

-- The distinct carried containers to search, as `get`-keywords. Deduped by keyword so two sacks aren't
-- scanned twice (a rare case; the second same-keyword container just isn't reached — acceptable).
local function carried_containers(inventory)
  local out, seen = {}, {}
  for _, name in ipairs(inventory or {}) do
    if looks_like_container(name) then
      local kw = container_kw(name)
      if kw and not seen[kw] then seen[kw] = true; out[#out + 1] = kw end
    end
  end
  return out
end

-- Parse ONE `look in` contents line for a soulstone: "(    2) a red soulstone" / "a pale blue soulstone".
-- Returns (colorKey, count) or nil for a non-soulstone line. The "(N)" is AA's count grouping (default 1).
-- Anchored to the bare item form, so "You get a red soulstone from …" / "You forge …" never match it.
local function container_soulstone(line)
  if type(line) ~= "string" then return nil end
  local count, phrase = line:match("^%s*%(%s*(%d+)%s*%)%s*[Aa]n?%s+(.-)%s+soulstone%s*%.?%s*$")
  if not phrase then phrase = line:match("^%s*[Aa]n?%s+(.-)%s+soulstone%s*%.?%s*$") end
  local color = phrase and tier_key(phrase) or nil
  if not color then return nil end
  return color, (tonumber(count) or 1)
end

-- ---- send capture (always on; cheap) --------------------------------------------------------------
-- Mirrors AutoFight: the script's own sends are captured so specs can read the exact command sequence
-- without stubbing the host `send`. `_SF_TEST.sent` aliases this table.
local sent = {}
local function clear_sent() for i = #sent, 1, -1 do sent[i] = nil end end
local function sf_send(cmd)
  sent[#sent + 1] = cmd
  if send then send(cmd) end
end

-- ---- the forge op as a promise (Equipment.lua eq_begin/eq_settle/eq_touch pattern) ----------------
-- One op runs at a time; starting a new one supersedes (rejects) the running one. A watchdog re-armed on
-- every step of progress force-settles a stalled op.
local sf_op = nil   -- { resolve, reject, promise, timer, inv_timer, recast_timer, gather_timer, cmd, pair,
                    --   model, no_progress, forged, phase, gathered, containers, cont_idx, pulled }

local function sf_settle(ok, reason)
  local op = sf_op; sf_op = nil
  if not op then return end
  if cancel then
    if op.timer then cancel(op.timer) end
    if op.inv_timer then cancel(op.inv_timer) end
    if op.recast_timer then cancel(op.recast_timer) end
    if op.gather_timer then cancel(op.gather_timer) end
  end
  if ok == false then op.reject(reason or "soulforge interrupted") else op.resolve() end
end

-- progress: re-arm the idle watchdog.
local function sf_touch()
  local op = sf_op; if not op then return end
  if op.timer and cancel then cancel(op.timer) end
  if after then op.timer = after(SF_IDLE, function()
    say("stalled — wrapping up.")
    sf_settle(false, "stalled")
  end) end
end

local plan_and_cast, start_gather, forge_done, done_looking   -- fwd

-- Read the freshly-repopulated inventory INTO the model, then plan. Used only for the INITIAL read and a
-- desync resync — NOT after every forge (the model is maintained in memory from forge-result feedback).
local function resync_and_plan()
  local op = sf_op; if not op then return end
  op.inv_timer = nil
  op.model = parse_soulstones(state.inventory)
  -- FIRST read of the run: look in the carried containers (once) and pull their soulstones. After that the
  -- whole run is memory-driven — this resync is reached again only on a desync re-inventory (see
  -- hit_forge_result / hit_bad_selection), where op.gathered is already set and we resume forging.
  if not op.gathered then return start_gather() end
  plan_and_cast()
end

-- Send `inv` and, once the output has had inv_wait to land in state.inventory, resync the model + plan.
-- Only the initial kick and desync recoveries call this — the steady state never re-inventories.
local function kick_inventory()
  local op = sf_op; if not op then return end
  sf_touch()
  if op.inv_timer and cancel then cancel(op.inv_timer) end
  sf_send("inv")
  op.inv_timer = after and after(cfg.inv_wait, resync_and_plan) or nil
end

-- Plan the next merge FROM THE MODEL and cast it, or FINISH — no inventory read (the model is kept current
-- from forge-result feedback). This is the steady-state heart of the loop.
plan_and_cast = function()
  local op = sf_op; if not op then return end
  local model = op.model or {}

  -- Nothing more to merge on hand (either <2 stones, or none of them pair up under the policy). This forge
  -- PASS is done — hand off to forge_done, which stows the results back into the container and, if this
  -- pass forged anything, runs another pull/forge/stow cycle until the stash is fully worked.
  if #model < 2 then return forge_done() end
  local pair = plan_next_forge(model)
  if not pair then return forge_done() end

  op.pair = pair
  op.cmd = forge_cmd(pair)
  sf_touch()
  sf_send(op.cmd)
end

-- ---- gather phase: LOOK IN carried containers, understand their soulstones, then pull the ones worth
-- forging -------------------------------------------------------------------------------------------
-- Two sub-phases (op.gphase): "look" then "pull".
--   LOOK: `look in <kw>` each carried container and capture the soulstones listed inside (colour+count)
--         so we KNOW the full picture — carried stones + every container's contents — before touching
--         anything. Each container's contents are reported.
--   DECIDE: with the complete picture we compute which colours are "raw" (worth merging up) via the SAME
--         is_raw policy the forge loop uses — so deep blue / purple (and a small pale stash) are left in
--         the container, not yanked out pointlessly.
--   PULL: `get <colour> soulstone <kw>` only the raw colours each container actually holds, response-
--         driven (a "You get …" pulls the next of that colour, a "don't see …" moves on). Then forge.
-- A per-step backstop timer means an unexpected reply never stalls the sweep; "You can't carry that many
-- items." ends the pull early (forging frees slots).
local gather_look, gather_look_done, gather_pull, gather_pull_advance, finish_gather   -- done_looking is fwd-declared above (resync_and_plan uses it on recycle)

-- Arm the quiet-time backstop for the current step (look / pull / stow): if the game draws no recognised
-- reply within gather_wait, run `cb` (advance) so we never hang waiting on a line that isn't coming. The
-- callback is step-appropriate, so no phase check is needed beyond "the op is still alive."
local function arm_gather_backstop(cb)
  local op = sf_op; if not op then return end
  if op.gather_timer and cancel then cancel(op.gather_timer) end
  op.gather_timer = after and after(cfg.gather_wait, function()
    op.gather_timer = nil
    if sf_op == op then cb() end
  end) or nil
end

-- Pretty "3 red, 2 green" from a { colour -> count } table, in tier order (nil if empty).
local function describe_counts(counts)
  local parts = {}
  for _, color in ipairs({ "red", "yellow", "green", "pale", "deep", "purple" }) do
    local n = counts[color]
    if n and n > 0 then parts[#parts + 1] = n .. " " .. TIER_LABEL[color] end
  end
  return (#parts > 0) and table.concat(parts, ", ") or nil
end

-- LOOK: `look in` the current container; the contents lines are captured by hit_look_soulstone while
-- op.capturing is set. A backstop closes the block once it goes quiet.
gather_look = function()
  local op = sf_op; if not op then return end
  local kw = op.containers[op.cont_idx]
  if not kw then return done_looking() end
  op.capturing, op.look_found = true, {}
  sf_touch()
  sf_send("look in " .. kw)
  arm_gather_backstop(gather_look_done)
end

-- The look-in block for the current container went quiet: record what it holds, report it, move on.
gather_look_done = function()
  local op = sf_op; if not op or not op.capturing then return end
  op.capturing = false
  if op.gather_timer and cancel then cancel(op.gather_timer); op.gather_timer = nil end
  local kw = op.containers[op.cont_idx]
  op.container_stones[kw] = op.look_found or {}
  local desc = describe_counts(op.container_stones[kw])
  say(kw .. " holds: " .. (desc or "no soulstones"))
  op.cont_idx = op.cont_idx + 1
  if op.cont_idx <= #op.containers then gather_look() else done_looking() end
end

-- All containers looked in. With carried + container contents known, decide which colours are worth
-- pulling (raw, per the merge policy) and queue `get`s for exactly those; leave deep/purple (and the pale
-- stash) where they are.
done_looking = function()
  local op = sf_op; if not op then return end
  op.phase = "gather"   -- a new pass may be entered from the stow phase (next_cycle) — back to gathering
  -- Combined multiset (carried model + every container's contents) → the is_raw decision context.
  local combined = {}
  for _, s in ipairs(op.model or {}) do if s.color then combined[#combined + 1] = { color = s.color } end end
  for _, counts in pairs(op.container_stones) do
    for color, n in pairs(counts) do for _ = 1, n do combined[#combined + 1] = { color = color } end end
  end
  -- Queue a pull for each raw colour a container actually holds (skip deep/purple and non-surplus pale).
  op.pull_queue = {}
  for _, kw in ipairs(op.containers) do
    for _, color in ipairs({ "red", "yellow", "green", "pale", "deep", "purple" }) do
      local n = (op.container_stones[kw] or {})[color]
      if n and n > 0 and is_raw(color, combined) then
        op.pull_queue[#op.pull_queue + 1] = { kw = kw, color = color }
      end
    end
  end
  if #op.pull_queue == 0 then
    say("nothing in your containers is worth forging — leaving them; forging what you carry.")
    return finish_gather()
  end
  op.gphase, op.pull_idx, op.pulled = "pull", 1, 0   -- per-pass pull count (drives the re-inv in finish_gather)
  gather_pull()
end

-- PULL: `get <colour> soulstone <kw>` for the current queue entry. hit_get_ok re-fires this (pull the next
-- of that colour); hit_get_empty advances the queue. A backstop advances if the game says nothing.
gather_pull = function()
  local op = sf_op; if not op then return end
  local item = op.pull_queue[op.pull_idx]
  if not item then return finish_gather() end
  sf_touch()
  sf_send(string.format("get %s soulstone %s", item.color, item.kw))
  arm_gather_backstop(gather_pull_advance)
end

-- Current colour/container drained (or no reply) → move to the next queued pull.
gather_pull_advance = function()
  local op = sf_op; if not op then return end
  if op.gather_timer and cancel then cancel(op.gather_timer); op.gather_timer = nil end
  op.pull_idx = op.pull_idx + 1
  if op.pull_idx > #op.pull_queue then finish_gather() else gather_pull() end
end

finish_gather = function()
  local op = sf_op; if not op then return end
  if op.gather_timer and cancel then cancel(op.gather_timer); op.gather_timer = nil end
  op.capturing = false
  op.gathered, op.phase = true, "forge"
  if (op.pulled or 0) > 0 then say(string.format("pulled %d soulstone(s) out — forging.", op.pulled)) end
  -- The carried model already reflects what we pulled (appended in hit_get_ok) — no re-inventory needed.
  plan_and_cast()
end

-- Look at the carried containers and, if any, start LOOKING (then decide + pull); otherwise straight to
-- forging the carried stones.
start_gather = function()
  local op = sf_op; if not op then return end
  op.phase, op.containers = "gather", carried_containers(state.inventory)
  op.cont_idx, op.pulled, op.container_stones, op.gphase = 1, 0, {}, "look"
  op.forged_this_cycle = 0                 -- fresh pass: did THIS look/pull/forge/stow cycle make progress?
  op.stow_kw = op.containers[1]            -- where finished stones go back (the first carried container)
  if #op.containers == 0 then op.gathered, op.phase = true, "forge"; return plan_and_cast() end
  say(string.format("looking in %d carried container(s) for soulstones…", #op.containers))
  gather_look()
end

-- ---- stow phase: put the forged soulstones back into the source container -------------------------
-- After a forge PASS finishes we put the soulstones back into the container we pulled from — so the stash
-- lives in the container, not your pack, AND it frees slots to pull the next batch. If the pass actually
-- forged something, we loop (re-look → pull → forge → stow) until the container has nothing left worth
-- forging. `put soulstone <kw>` is response-driven: a "You put a X soulstone in Y." puts the next; a
-- "not carrying" reply / a quiet gap ends it.
local next_cycle, stow_next

-- Final report at the very end of the run (once, at settle).
local function report_done()
  local op = sf_op; if not op then return end
  local back = (op.stowed_total and op.stowed_total > 0 and op.stow_kw)
    and string.format(" — put %d back in %s", op.stowed_total, op.stow_kw) or ""
  if (op.forged_total or 0) > 0 then
    say(string.format("done — forged %d time(s)%s.", op.forged_total, back))
  elseif back ~= "" then
    say("done" .. back .. " (nothing needed forging).")
  else
    say("nothing to forge (checked your inventory and carried containers).")
  end
end

local function stow_done()
  local op = sf_op; if not op then return end
  if op.gather_timer and cancel then cancel(op.gather_timer); op.gather_timer = nil end
  next_cycle()
end

stow_next = function()
  local op = sf_op; if not op or not op.stow_kw then return stow_done() end
  sf_touch()
  sf_send("put soulstone " .. op.stow_kw)
  arm_gather_backstop(stow_done)   -- quiet gap = nothing left to put
end

local function begin_stow()
  local op = sf_op; if not op then return end
  op.phase = "stow"
  stow_next()
end

-- A forge pass finished. If stowing is on and there's a container + carried stones, put them back; then
-- next_cycle decides whether to run another pass. Otherwise report and settle.
forge_done = function()
  local op = sf_op; if not op then return end
  if cfg.stow and op.stow_kw and #(op.model or {}) > 0 then return begin_stow() end
  report_done(); sf_settle(true)
end

-- Are there still at least TWO raw stones in the whole (in-memory) picture — i.e. another forge is
-- possible? Requires two so a lone unpairable stone doesn't trigger a wasted pull-and-stow pass.
local function container_has_raw(op)
  local combined = {}
  for _, s in ipairs(op.model or {}) do if s.color then combined[#combined + 1] = { color = s.color } end end
  for _, counts in pairs(op.container_stones or {}) do
    for color, n in pairs(counts) do for _ = 1, n do combined[#combined + 1] = { color = color } end end
  end
  local raw = 0
  for _, s in ipairs(combined) do if is_raw(s.color, combined) then raw = raw + 1 end end
  return raw >= 2
end

-- After stowing: if THIS pass forged anything AND a container still holds stones worth forging, run another
-- pass — decided straight from the in-memory model (pulled/forged/stowed are all tracked), so NO re-look and
-- NO re-inventory. Otherwise we've converged; settle. (This is why soulforge no longer re-reads inventory
-- between passes or at the end.)
next_cycle = function()
  local op = sf_op; if not op then return end
  if (op.forged_this_cycle or 0) > 0 and container_has_raw(op) then
    op.forged_this_cycle = 0     -- new pass
    done_looking()               -- decide + pull from memory — no `inv`, no `look in`
  else
    report_done(); sf_settle(true)
  end
end

-- Begin an op: supersede any running one, create+track the promise, wire sf_op, arm the watchdog, then
-- kick the first inventory read. Returns the promise (nil only if the promise layer isn't loaded).
local function begin_op()
  sf_settle(false, "superseded")
  if not __promise then say("promise layer unavailable — cannot run soulforge."); return nil end
  local p = __promise(function(resolve, reject, onCancel)
    sf_op = { resolve = resolve, reject = reject, cmd = nil, no_progress = 0,
              phase = "gather", gathered = false }
    onCancel(function()
      if sf_op and cancel then
        if sf_op.timer then cancel(sf_op.timer) end
        if sf_op.inv_timer then cancel(sf_op.inv_timer) end
        if sf_op.recast_timer then cancel(sf_op.recast_timer) end
        if sf_op.gather_timer then cancel(sf_op.gather_timer) end
      end
      sf_op = nil
    end)
  end, "soulforge")
  if p and p.__start then p.__start() end   -- run the executor NOW so sf_op is set before any capture
  if sf_op then sf_op.promise = p end
  say("merging soulstones up toward pale blue — reading what you're carrying…")
  kick_inventory()
  return p
end

-- ---- cast-result handlers (what the triggers fire; the _SF_TEST seam calls the SAME handlers) ------

-- A stone was produced: "You forge a <result> soulstone using a <base> soulstone as a base!" (2 consumed
-- -> 1 forged). Update the in-memory model from that feedback and plan the next merge WITHOUT a re-read —
-- this is the whole point of tracking the model. Only if we can't reconcile the result against the model
-- (a desync) do we fall back to a real `inv`.
local function hit_forge_result(result_phrase, base_phrase)
  local op = sf_op; if not op then return end
  op.forged = true       -- we produced at least one stone this run — a later <2 is "done", not "too thin"
  op.forged_total = (op.forged_total or 0) + 1        -- run total (reporting)
  op.forged_this_cycle = (op.forged_this_cycle or 0) + 1   -- per-cycle (did this pass make progress?)
  op.no_progress = 0     -- a real forge clears the bad-selection streak
  sf_touch()
  local ok = op.pair and apply_forge(op.model or {}, op.pair.a, op.pair.b,
                                     tier_key(result_phrase), tier_key(base_phrase))
  if ok then plan_and_cast()    -- model maintained in memory → no re-inventory
  else kick_inventory() end     -- couldn't reconcile (desync / spurious line) → resync from a real `inv`
end

-- The soulforge skill roll fizzled ("You fail to cast the spell 'soulforge'."): the SAME two stones are
-- still there, so re-send the SAME command after a short anti-spam pause. Do NOT re-inventory (the pile
-- didn't change; a fresh `inv` would just cost a round-trip).
local function resend_cmd()
  local op = sf_op; if not op or not op.cmd then return end
  op.recast_timer = nil
  sf_touch()
  sf_send(op.cmd)
end
local function hit_fail()
  local op = sf_op; if not op then return end
  sf_touch()
  if op.recast_timer and cancel then cancel(op.recast_timer) end
  op.recast_timer = after and after(cfg.recast_wait, resend_cmd) or nil
end

-- The selection was bad — the two ordinals collided on one stone, or matched gear ("You must specify two
-- different soulstones…"), or a named stone wasn't found ("You do not seem to have a soulstone by that
-- name."). Re-read the inventory and re-plan from scratch (the numbering may have shifted). SAFETY: count
-- consecutive bad selections with no forge in between — a genuine forge clears the streak (hit_forge_result)
-- — and bail after a few so a persistently-rejected plan can't spin forever.
local function hit_bad_selection()
  local op = sf_op; if not op then return end
  op.no_progress = (op.no_progress or 0) + 1
  if op.no_progress >= cfg.max_no_progress then
    say(string.format("no progress after %d rejected selections — stopping.", op.no_progress))
    sf_settle(true); return
  end
  kick_inventory()
end

-- Out of mana (soulforge costs 15): stop. There's no spell that makes mana; the caller can `recover mana`
-- and chain soulforge again.
local function hit_mana()
  if not sf_op then return end
  say("out of mana — stopping (recover mana, then run soulforge again).")
  sf_settle(false, "out of mana")
end

-- Informational-only lines: the merge is under way / inventory filled and the forged stone dropped. The
-- forge still worked (the result line drives the re-inventory); just re-arm the watchdog so a slow forge
-- doesn't trip it.
local function hit_progress() sf_touch() end

-- ---- gather-phase handlers -------------------------------------------------------------------------
-- LOOK sub-phase: a soulstone line inside the `look in` block ("(  2) a red soulstone" / "a green
-- soulstone"). Record its colour+count. Guarded by op.capturing so plain inventory soulstone lines (during
-- an `inv`) never feed it. Re-arm the backstop since the block is still streaming.
local function hit_look_soulstone(line)
  local op = sf_op; if not op or not op.capturing then return end
  local color, count = container_soulstone(line)
  if not color then return end
  op.look_found = op.look_found or {}
  op.look_found[color] = (op.look_found[color] or 0) + count
  sf_touch()
  arm_gather_backstop(gather_look_done)
end

-- PULL sub-phase: a soulstone came OUT of a container ("You get a X soulstone from Y.") → count it and
-- pull the NEXT of the same colour/container. Guarded to the pull sub-phase so a loot line from anything
-- else (or the look sub-phase) can't drive us.
local function hit_get_ok(color_phrase)
  local op = sf_op; if not op or op.phase ~= "gather" or op.gphase ~= "pull" then return end
  op.pulled = (op.pulled or 0) + 1
  local item = op.pull_queue[op.pull_idx]
  -- Keep the in-memory container model current so later cycles decide without re-looking: one stone of
  -- this colour just left this container.
  if item and op.container_stones[item.kw] and op.container_stones[item.kw][item.color] then
    op.container_stones[item.kw][item.color] = op.container_stones[item.kw][item.color] - 1
  end
  -- ...and APPEND it to the carried model (the game drops a gotten item at the end of inventory), so we
  -- forge straight from memory with NO re-inventory. Trust the line's colour, fall back to what we asked.
  local color = tier_key(color_phrase) or (item and item.color)
  if color then
    op.model = op.model or {}
    op.model[#op.model + 1] = { color = color }
    renumber(op.model)
  end
  sf_touch()
  gather_pull()   -- re-fires the SAME `get` → the next stone of this colour, until the container's empty
end
-- That colour/container is drained — "You don't see anything named '…' in <container>." → next queued pull.
local function hit_get_empty()
  local op = sf_op; if not op or op.phase ~= "gather" or op.gphase ~= "pull" then return end
  sf_touch()
  gather_pull_advance()
end
-- Inventory hit its item cap mid-pull ("You can't carry that many items."). Stop gathering and forge what
-- we have — each merge frees a slot, so the pile still shrinks toward the good stones.
local function hit_carry_full()
  local op = sf_op; if not op or op.phase ~= "gather" then return end
  say("inventory full — forging what I have to free space.")
  finish_gather()
end

-- STOW sub-phase: a soulstone went back into the container ("You put a X soulstone in Y.") → put the next.
-- The captured colour keeps the in-memory container model current (this colour just went back in), so the
-- next cycle's decision needs no re-look.
local function hit_put_ok(color_phrase)
  local op = sf_op; if not op or op.phase ~= "stow" then return end
  op.stowed_total = (op.stowed_total or 0) + 1
  local color = tier_key(color_phrase)
  if color and op.stow_kw then
    op.container_stones[op.stow_kw] = op.container_stones[op.stow_kw] or {}
    op.container_stones[op.stow_kw][color] = (op.container_stones[op.stow_kw][color] or 0) + 1
  end
  -- ...and REMOVE it from the carried model (this stone just left our pack for the container), so the next
  -- cycle decides from memory with no re-inventory. Drop the first carried entry of that colour.
  if color and op.model then
    for i, s in ipairs(op.model) do
      if s.color == color then table.remove(op.model, i); renumber(op.model); break end
    end
  end
  sf_touch()
  stow_next()
end
-- Nothing left to put back ("You aren't carrying …" / "You don't have …") → the stow is finished.
local function hit_put_empty()
  local op = sf_op; if not op or op.phase ~= "stow" then return end
  sf_touch()
  stow_done()
end

-- ---- live wire -> handlers ------------------------------------------------------------------------
-- Trigger REGEXES run in Swift (not unit-tested); each just calls the matching hit_* handler, which the
-- _SF_TEST seam also calls — one path, no second matcher to drift. All anchored so another player's
-- chatter can't trip a resolution. Wire strings are verbatim from the trace mining (see the spec).
if trigger then
  -- RESULT: a stone was produced. Capture 1 = the forged (result) colour, capture 2 = the base colour —
  -- both feed the in-memory model update (so we don't re-read the inventory).
  trigger([[^You forge a (.+) soulstone using a (.+) soulstone as a base!]],
    function(_, result, base) hit_forge_result(result, base) end)
  -- The merge started (informational) / inventory full, forged stone dropped (informational).
  trigger([[^You cast the spell to merge a (.+) soulstone and a (.+) soulstone]], function() hit_progress() end)
  trigger([[^You can't carry any more and drop a (.+) soulstone]], function() hit_progress() end)
  -- Cast fizzled (skill roll) -> recast the same command.
  trigger([[^You fail to cast the spell 'soulforge'\.]], function() hit_fail() end)
  -- Bad selection / named stone missing -> re-inventory & re-plan.
  trigger([[^You must specify two different soulstones]], function() hit_bad_selection() end)
  trigger([[^You do not seem to have a soulstone by that name\.]], function() hit_bad_selection() end)
  -- Out of mana -> stop (standard AA wording).
  trigger([[^You don't have enough mana]], function() hit_mana() end)
  -- GATHER/LOOK: a soulstone line inside a `look in` block ("(  2) a red soulstone" / "a green soulstone").
  -- Anchored to the bare-item form so "You get …" / "You forge …" never match; handler self-guards on
  -- op.capturing so ordinary inventory soulstone lines don't feed it either. We look in each container ONCE
  -- and remember its contents, so there's no repeated dump to hide.
  trigger([[^\s*(?:\(\s*\d+\s*\)\s*)?an? .+ soulstone\.?\s*$]], function(line) hit_look_soulstone(line) end)
  -- GATHER/PULL: a soulstone pulled from a container, an empty/no-match container, or a full pack. The
  -- handlers self-guard on op.phase/op.gphase, so these are inert during the look and forge phases.
  trigger([[^You get a (.+) soulstone from ]], function(_, color) hit_get_ok(color) end)
  trigger([[^You don't see anything named '.-' in ]], function() hit_get_empty() end)
  trigger([[^You can't carry that many items]], function() hit_carry_full() end)
  -- GATHER/STOW: a soulstone put back into the container, or nothing left to put. Handlers self-guard on
  -- op.phase == "stow", so they're inert outside the stow step.
  trigger([[^You put a (.+) soulstone in ]], function(_, color) hit_put_ok(color) end)
  trigger([[^You aren't carrying ]], function() hit_put_empty() end)
end

-- ---- control surface ------------------------------------------------------------------------------

-- soulforge() — start the grind and return a tracked promise (or the running one if already going).
local function soulforge_start()
  if sf_op then
    say("already forging — 'soulforge off' to stop.")
    return sf_op.promise
  end
  return begin_op()
end

local function soulforge_off()
  if sf_op then say("stopping."); sf_settle(false, "cancelled")
  else say("not running.") end
end

local function soulforge_status()
  if sf_op then
    say("running" .. (sf_op.cmd and (" — last cast: " .. sf_op.cmd) or " — reading inventory…") .. ".")
  else
    say("idle. Type `soulforge` to merge low-level soulstones up toward pale/deep blue.")
  end
end

-- soulforge([verb]) — the public entry. No arg (or an unrecognised one) starts the grind and returns a
-- chainable promise; 'off'/'stop' cancels; 'status' reports. Callable straight in (`soulforge`) via the
-- aliases below, in the REPL (`#soulforge`), and as a pipe step (`recover mana | soulforge`).
function soulforge(verb)
  verb = (verb or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  if verb == "off" or verb == "stop" then return soulforge_off() end
  if verb == "status" then return soulforge_status() end
  return soulforge_start()
end
doc("soulforge", { sig = "soulforge(['off'|'status']) -> promise", group = "combat",
  text = "Auto-merge low-level soulstones (the drops from soulsteal) upward toward pale blue — or deep "
      .. "blue once pale is plentiful. First pulls soulstones out of your carried containers (pocket "
      .. "dimension / sack / vortex …), then casts `soulforge` on the two best candidates and repeats "
      .. "until nothing's worth merging. Prefers same-colour pairs; never merges deep/purple; keeps a "
      .. "working stash of pale on hand. No arg starts it and returns a chainable promise (recover mana "
      .. "| soulforge); 'off' stops; 'status' reports.",
  example = "#soulforge   (or:  recover mana | soulforge)" })

-- Game-line aliases so it works typed straight in (no `#`), like recover/autofight: `soulforge` starts,
-- `soulforge off`/`status` dispatch. (`#soulforge …` via the REPL still works too.)
if alias then
  alias([[^soulforge$]], function() soulforge() end)
  alias([[^soulforge (.+)$]], function(_, rest) soulforge(rest) end)
end

-- ---- test seam ------------------------------------------------------------------------------------
-- Specs drive the flow by calling the SAME hit_* handlers the live triggers call, and assert on the
-- observable send sequence (SF.sent) / helper return values — never internal fields. `on_inv` is
-- step_forge (reads state.inventory + casts/finishes); the harness has no event loop, so specs set
-- state.inventory then call on_inv directly instead of waiting on the inv_wait timer.
_SF_TEST = {
  cfg            = cfg,
  sent           = sent,
  soulstone_color = soulstone_color,
  parse_soulstones = parse_soulstones,
  tier           = tier,
  tier_key       = tier_key,
  is_raw         = is_raw,
  target_tier    = target_tier,
  plan_next_forge = plan_next_forge,
  forge_cmd      = forge_cmd,
  apply_forge    = apply_forge,          -- model update from a forge-result (result_color, base_color)
  looks_like_container = looks_like_container,
  container_kw   = container_kw,
  carried_containers = carried_containers,
  container_soulstone = container_soulstone,   -- parse a `look in` line -> (color, count)
  begin          = soulforge_start,      -- start an op (returns the promise)
  on_inv         = function() resync_and_plan() end,  -- the after-inv step (gather → or read → cast/finish)
  forge_result   = hit_forge_result,     -- (result_phrase, base_phrase) — updates the model, casts next
  fail           = hit_fail,
  recast         = resend_cmd,           -- fire the pending recast (the harness timer never auto-fires)
  bad_selection  = hit_bad_selection,
  mana           = hit_mana,
  look_soulstone = hit_look_soulstone,   -- gather/look: a soulstone line inside a `look in` block
  look_done      = function() gather_look_done() end,   -- close the current look-in block (backstop stand-in)
  get_ok         = hit_get_ok,           -- gather/pull: a soulstone came out of a container
  get_empty      = hit_get_empty,        -- gather/pull: this colour/container drained → next queued pull
  carry_full     = hit_carry_full,       -- gather: pack full → stop gathering, forge what we have
  put_ok         = hit_put_ok,           -- stow: a soulstone went back into the container
  put_empty      = hit_put_empty,        -- stow: nothing left to put → stow done
  active         = function() return sf_op ~= nil end,
  reset          = function()
    if sf_op and sf_op.promise then sf_op.promise.cancel() end   -- settles+clears any lingering op
    sf_op = nil
    clear_sent()
  end,
}
