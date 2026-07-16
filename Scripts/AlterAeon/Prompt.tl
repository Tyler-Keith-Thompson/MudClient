-- AlterAeon PROMPT layer — a supplementary state source so the HUD keeps working under `nomelee`.
--
-- With nocombat (nomelee) toggled on, the server sends NO kxwt_fighting at all during a fight (see
-- Combat.lua's engaged() note) — but it still terminates every prompt with a machine-parseable one if
-- you `prompt` it to. We set three prompt formats on connect (fighting/default/sleeping) that all start
-- with the sentinel `kxwq_hud|` (NOT `kxwt_` — deliberately a different letter so this doesn't collide
-- with the real kxwt_ protocol namespace) and pipe-delimit the vitals/position, with the fighting form
-- appending the current target's health%/gender/name. The host surfaces every GA-terminated prompt to
-- the optional `on_prompt(text)` global UPSTREAM of the trigger/gag pipeline, so this sees the prompt
-- even though our own trigger below replaces it with a bare colour reset (hidden data, colour cleared at
-- the prompt boundary — see there). The PARSER accepts
-- either letter (`kxw[qt]_hud|`) — kxwq_ is what we send, but kxwt_hud is tolerated too (e.g. an old
-- session's prompt format still configured server-side) since it's the same shape either way.
--
-- Fighting prompt: kxwq_hud|%hp|%hpx|%ma|%mnx|%mv|%mvx|%pos|%fp|%fg|%fi
-- Default prompt:  kxwq_hud|%hp|%hpx|%ma|%mnx|%mv|%mvx|%pos
-- Sleeping prompt:  kxwq_hud|%hp|%hpx|%ma|%mnx|%mv|%mvx|%pos
-- (the game uses the FIGHTING form only while fighting, so the prompt's SHAPE is itself an authoritative
-- fighting/not-fighting signal — this is what makes the HUD's combat block work with nomelee on, where
-- kxwt_fighting never arrives.)
--
-- SCOPE: feeds state (vitals/position/single fighting target) + HUD refresh only. Does not rewire
-- AutoFight (still keyed off kxwt_fighting) or the inferred-opponent tracker (Combat.lua) — those are
-- separate, deliberately out of scope here.

global _PROMPT_TEST: {string:any}

state = state or {}
_PROMPT_TEST = _PROMPT_TEST or {}

-- The parsing library (__parse): parse_prompt below is expressed as a declarative, BIDIRECTIONAL
-- grammar (Scripts/Foundation/Parse.tl) rather than a hand-rolled gmatch scan — see the grammar block
-- just above parse_prompt. `_`-prefixed files aren't auto-loaded by the directory loader; Parse.lua
-- isn't `_`-prefixed, but the dofile-fallback convention (see AutoFight.tl's `boot("_rx")`) still
-- applies in the bare CLI test harness, which loads scripts via an explicit dofile list, not `require`.
local function boot(name: string) pcall(require, name) end
boot("Parse")
if not __parse then dofile("Scripts/Foundation/Parse.lua") end
boot("Route")
if not __route then dofile("Scripts/Foundation/Route.lua") end
local route = __route.route

-- Send the three prompt formats. Shared by the connect trigger below and the load-time call further down,
-- so a mid-session #reload re-applies them without needing a reconnect.
-- CRITICAL: the `|` in these commands MUST be escaped as `\|`. The client's outbound pipeline treats an
-- unescaped `|` as the promise-pipe operator and SPLITS the command on it — so a raw `prompt fighting
-- kxwq_hud|%hp|...` becomes `prompt fighting kxwq_hud` (sets a tagless prompt) + `%hp` + `%hpx` + ... each
-- sent as its own command, spamming the game ("Invalid command for channel controls."). `\|` (written
-- `\\|` in this Lua literal) passes a LITERAL pipe through, so the game receives the intended format.
local function set_prompt_formats()
   send("prompt fighting kxwq_hud\\|%hp\\|%hpx\\|%ma\\|%mnx\\|%mv\\|%mvx\\|%pos\\|%fp\\|%fg\\|%fi")
   send("prompt default kxwq_hud\\|%hp\\|%hpx\\|%ma\\|%mnx\\|%mv\\|%mvx\\|%pos")
   send("prompt sleeping kxwq_hud\\|%hp\\|%hpx\\|%ma\\|%mnx\\|%mv\\|%mvx\\|%pos")
end

-- Mirrors AlterAeon.lua:67's `set kxwt` handshake trigger — a SEPARATE trigger on the same line, so both
-- fire (multiple triggers per line are fine). Sets the three prompt formats once kxwt is confirmed live.
trigger([[^kxw[tq]_supported$]], set_prompt_formats)

-- A #reload runs this file fresh, but the connect trigger above only fires on a NEW `set kxwt` handshake —
-- which doesn't happen again mid-session. Re-apply immediately if we're already connected so the formats
-- survive a reload without forcing a reconnect.
if is_connected and is_connected() then set_prompt_formats() end

-- Hide the machine prompt from the display, but REPLACE it with a bare ANSI reset (ESC[0m) rather than
-- dropping it outright. AlterAeon relies on the prompt to reset colour at the end of a turn — a lot of
-- game lines set a colour and never reset it (e.g. "\27[35mOn the ground lies a book."), trusting the
-- prompt that follows to clear it. A plain `gag` dropped that reset, so the leftover colour bled into the
-- next output. The prompt carries no newline (GA-terminated) and `render` writes chunks verbatim, so the
-- lone reset lands exactly at the prompt boundary — clearing colour there, adding NO blank line. This is
-- "the prompt contains a reset" done client-side; do NOT reset every line, only here. (AlterAeon's own
-- `^kxwt_` gag doesn't match our `kxwq_` sentinel, so we own this rule.)
trigger([[^kxw[qt]_hud]], function(): string return "\27[0m" end)

-- Parse a kxw[qt]_hud prompt into its fields, or nil if it's not one (or is too short/garbled to trust).
-- Returns { hp, maxhp, mana, maxmana, stam, maxstam, position, fight_pct, fight_gender, fight_name } —
-- the last three nil when the prompt is the default/sleeping (non-fighting) form.
local record PromptFields
   hp: number
   maxhp: number
   mana: number
   maxmana: number
   stam: number
   maxstam: number
   position: string
   fight_pct: number
   fight_gender: string
   fight_name: string
end

-- The wire grammar, declaratively: sentinel, then a pipe, then 7-10 pipe-delimited fields (fight_gender
-- can legitimately be empty, e.g. some non-"male"/"female" case, so we don't require non-empty per
-- field). `sentinel`/`pipe` are `Parser<Unit>` (nothing to extract from a literal) — exactly what makes
-- them safe to `.take` through (see foundation.d.tl's note on why `.skip`/`.take`'s discarded side must
-- be structural). Building blocks are independently reusable/testable, and — the actual payoff over a
-- hand-rolled gmatch scan — read as a SPEC of the wire format, not a scan.
local sentinel: Parser<Unit> = __parse.oneOf(__parse.lit("kxwq_hud"), __parse.lit("kxwt_hud"))
local pipe: Parser<Unit> = __parse.lit("|")
local field: Parser<string> = __parse.prefix_up_to("|")
local prompt_fields: Parser<{string}> = sentinel:take(pipe):take(__parse.many1(field, pipe))

-- Semantic mapping: array of raw field strings <-> typed record. No combinator library makes "field 8
-- is only meaningful when 3 more fields exist" disappear; both directions of that variable-arity
-- optional suffix are written by hand. Bundled as a `Conversion<{string}, PromptFields>` (rather than a
-- plain closure via `mapf`) specifically so `.map` keeps this printable — see `from_prompt_fields`
-- below, the print-direction inverse this grammar gets "for free" that the old gmatch scan never had.
local function to_prompt_fields(fields: {string}): PromptFields
   if #fields < 7 then return nil end
   local hp, maxhp = tonumber(fields[1]), tonumber(fields[2])
   local mana, maxmana = tonumber(fields[3]), tonumber(fields[4])
   local stam, maxstam = tonumber(fields[5]), tonumber(fields[6])
   local pos = fields[7]
   if not (hp and maxhp and mana and maxmana and stam and maxstam) or not pos or pos == "" then return nil end
   local out: PromptFields = { hp = hp, maxhp = maxhp, mana = mana, maxmana = maxmana,
                               stam = stam, maxstam = maxstam, position = pos }
   if #fields >= 10 then
      local fpct = tonumber(fields[8])
      local fname = fields[10]
      if fpct and fname and fname ~= "" then
         out.fight_pct, out.fight_gender, out.fight_name = fpct, fields[9], fname
      end
   end
   return out
end

-- The inverse of `to_prompt_fields` — reconstructs the raw wire fields from a typed record. Not used by
-- on_prompt (which only ever RECEIVES a prompt from the server), but wiring it into a Conversion is
-- what keeps `prompt_parser` below printable via `__parse.print_all`, should a caller ever need to
-- reconstruct a wire line from `state`.
local function from_prompt_fields(p: PromptFields): {string}
   local out: {string} = {
      tostring(p.hp), tostring(p.maxhp), tostring(p.mana), tostring(p.maxmana),
      tostring(p.stam), tostring(p.maxstam), p.position,
   }
   if p.fight_name then
      out[8], out[9], out[10] = tostring(p.fight_pct), p.fight_gender, p.fight_name
   end
   return out
end

local prompt_fields_conv: Conversion<{string}, PromptFields> = {
   apply = to_prompt_fields,
   unapply = from_prompt_fields,
}

-- Wire the grammar to the semantics with `.map(Conversion)` — bidirectional, unlike `.flatMap`/`.mapf`
-- (which would make this parse-only). `to_prompt_fields` can still return `nil` on malformed input (a
-- `Conversion.apply` obligation this library doesn't statically enforce).
local prompt_parser: Parser<PromptFields> = prompt_fields:map(prompt_fields_conv)

local function parse_prompt(text: string): PromptFields
   local t = (text or ""):match("^%s*(.-)%s*$")
   local p = __parse.parse_all(prompt_parser, t)
   return p
end

-- Apply a parsed prompt to `state`, driving the same downstream reactions kxwt does (recovery hooks +
-- HUD refresh). Split from the trigger so it's directly unit-testable without going through on_prompt.
local function apply_prompt(p: PromptFields)
   if not p then return end
   state.hp, state.maxhp = p.hp, p.maxhp
   state.mana, state.maxmana = p.mana, p.maxmana
   state.stam, state.maxstam = p.stam, p.maxstam
   if __recovery_on_vitals then __recovery_on_vitals() end

   local changed = (state.position ~= p.position)
   state.position = p.position
   if __recovery_on_position then __recovery_on_position(p.position, changed) end

   apply_fight(p.fight_pct, p.fight_name)   -- shared with the kxwq_fighting-as-prompt path (see on_prompt)

   if on_update then on_update() end
end

-- Drive ONLY the combat state (state.fighting + AutoFight), shared by apply_prompt and the kxwq_fighting
-- prompt handler. fight_name nil = not fighting. Kept separate so the fighting bar can update WITHOUT
-- touching vitals/position (the kxwq_fighting prompt carries no vitals — feeding it through apply_prompt
-- would wipe state.hp/etc).
function apply_fight(fight_pct: number, fight_name: string)
   if fight_name then
      state.fighting, state.fight_pct, state.fight_name = true, fight_pct, fight_name
   else
      state.fighting, state.fight_name, state.fight_pct = false, nil, nil
   end
   if __autofight_prompt then
      if fight_name then __autofight_prompt(fight_pct, fight_name) else __autofight_prompt(nil, nil) end
   end
end

-- The enemy health bar arrives as its OWN line "kxwq_fighting <pct> <gender> <name>" (or "… -1" at combat
-- end). Over the 1.105 RPC the server GLUES it to the following ;sgroup; frame with a Telnet GO-AHEAD
-- (IAC GA) between them — VERIFIED in the raw log: `kxwq_fighting 52 male A doctor\xff\xf9;sgroup;…`. The
-- GA makes the line-assembler flush "kxwq_fighting 52 male A doctor" as a PROMPT, so Combat.lua's
-- kxwt_fighting TRIGGER never sees it (triggers run on newline lines, not prompts) — the HUD didn't know we
-- were fighting. on_prompt DOES get the clean text, so parse the fighting bar here and drive the state.
-- Idempotent with Combat.lua's trigger (only one of the two ever sees a given tag), so no double-fire.
local function fighting_from_prompt(text: string): boolean
   local pct, name = text:match("^kxw[tq]_fighting (%d+) %S+ (.+)$")
   if pct then apply_fight(tonumber(pct), name); if on_update then on_update() end; return true end
   if text:match("^kxw[tq]_fighting %-1%f[%D]") then apply_fight(nil, nil); if on_update then on_update() end; return true end
   return false
end

-- kxwq_fighting isn't the ONLY GA-flushed tag — the server ends several kxwt/kxwq telemetry tags with IAC
-- GO-AHEAD, so the line assembler hands them to on_prompt instead of the trigger pipeline (VERIFIED in the
-- raw log: `kxwq_spellup fire shield\xff\xf9…`). Their REAL triggers then never fire — which is why
-- auto-maintain stopped (`maintain <spell>` is issued from the kxwt_spellup trigger, AlterAeon.lua), along
-- with the spells widget, spelldown/spst, the recovery spellup/spelldown hooks, and the death banners. So any
-- kxwt tag that lands here (other than the kxwq_hud vitals prompt parsed above, and kxwq_fighting driven
-- directly) is RE-INJECTED as a proper newline line via feed_server, so the normal pipeline dispatches it to
-- its actual trigger. The re-fed line ends in \n (no GA) so it can't loop back into on_prompt, and the kxwt
-- catch-all gag still hides it from the display.
local function reinject_kxwt_tag(text: string): boolean
   if feed_server and text:match("^kxw[tq]_") then feed_server(text .. "\n"); return true end
   return false
end

-- First-match dispatch table (`route`, Scripts/Foundation/Route.tl) mirroring on_prompt's original
-- if/elseif priority: fighting bar (kxwq_fighting, GA-flushed) → hud vitals prompt (kxwq_hud, parsed) →
-- any other GA-flushed kxwt tag (reinjected). Predicates are mutually exclusive by construction (the
-- fighting-bar prefix can never also parse as a hud prompt), so this is byte-identical to the original
-- first-match chain, not merely equivalent.
local function is_fighting_bar(text: string): boolean
   return text:match("^kxw[tq]_fighting") ~= nil
end

local function is_hud_prompt(text: string): boolean
   return parse_prompt(text) ~= nil
end

local any_case = __route.any

local function handle_fighting(text: string)
   fighting_from_prompt(text)
end

local function apply_prompt_line(text: string)
   apply_prompt(parse_prompt(text))
end

on_prompt = route({
   { is_fighting_bar, handle_fighting },   -- kxwq_fighting line
   { is_hud_prompt,   apply_prompt_line }, -- kxwq_hud vitals prompt (parse + apply)
   { any_case,        reinject_kxwt_tag }, -- other GA-flushed kxwt tag
})

_PROMPT_TEST.parse_prompt = parse_prompt
_PROMPT_TEST.apply_prompt = apply_prompt
_PROMPT_TEST.fighting_from_prompt = fighting_from_prompt
_PROMPT_TEST.reinject_kxwt_tag = reinject_kxwt_tag
