-- AlterAeon PROMPT layer — a supplementary state source so the HUD keeps working under `nomelee`.
--
-- With nocombat (nomelee) toggled on, the server sends NO kxwt_fighting at all during a fight (see
-- Combat.lua's engaged() note) — but it still terminates every prompt with a machine-parseable one if
-- you `prompt` it to. We set three prompt formats on connect (fighting/default/sleeping) that all start
-- with the sentinel `kxwq_hud|` (NOT `kxwt_` — deliberately a different letter so this doesn't collide
-- with the real kxwt_ protocol namespace) and pipe-delimit the vitals/position, with the fighting form
-- appending the current target's health%/gender/name. The host surfaces every GA-terminated prompt to
-- the optional `on_prompt(text)` global UPSTREAM of the trigger/gag pipeline, so this sees the prompt
-- even though our own `gag([[^kxw[qt]_hud]])` below hides it from the display. The PARSER accepts
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

state = state or {}
_PROMPT_TEST = _PROMPT_TEST or {}

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
trigger([[^kxwt_supported$]], set_prompt_formats)

-- A #reload runs this file fresh, but the connect trigger above only fires on a NEW `set kxwt` handshake —
-- which doesn't happen again mid-session. Re-apply immediately if we're already connected so the formats
-- survive a reload without forcing a reconnect.
if is_connected and is_connected() then set_prompt_formats() end

-- AlterAeon.lua's `gag([[^kxwt_]])` only catches the real protocol namespace — it does NOT match our
-- `kxwq_hud` sentinel, so without this the machine prompt would display. Gag both letters ourselves.
gag([[^kxw[qt]_hud]])

-- Parse a kxw[qt]_hud prompt into its fields, or nil if it's not one (or is too short/garbled to trust).
-- Returns { hp, maxhp, mana, maxmana, stam, maxstam, position, fight_pct, fight_gender, fight_name } —
-- the last three nil when the prompt is the default/sleeping (non-fighting) form.
local function parse_prompt(text)
  local t = (text or ""):match("^%s*(.-)%s*$")
  if not t:match("^kxw[qt]_hud|") then return nil end
  local fields = {}
  for f in (t .. "|"):gmatch("(.-)|") do fields[#fields + 1] = f end
  -- fields[1] == "kxw[qt]_hud" sentinel; 2..7 = hp/maxhp/mana/maxmana/mv/maxmv; 8 = pos; 9..11 = fighting.
  if #fields < 8 then return nil end
  local hp, maxhp = tonumber(fields[2]), tonumber(fields[3])
  local mana, maxmana = tonumber(fields[4]), tonumber(fields[5])
  local stam, maxstam = tonumber(fields[6]), tonumber(fields[7])
  local pos = fields[8]
  if not (hp and maxhp and mana and maxmana and stam and maxstam) or not pos or pos == "" then return nil end
  local out = { hp = hp, maxhp = maxhp, mana = mana, maxmana = maxmana,
                stam = stam, maxstam = maxstam, position = pos }
  if #fields >= 11 then
    local fpct = tonumber(fields[9])
    local fname = fields[11]
    if fpct and fname and fname ~= "" then
      out.fight_pct, out.fight_gender, out.fight_name = fpct, fields[10], fname
    end
  end
  return out
end

-- Apply a parsed prompt to `state`, driving the same downstream reactions kxwt does (recovery hooks +
-- HUD refresh). Split from the trigger so it's directly unit-testable without going through on_prompt.
local function apply_prompt(p)
  if not p then return end
  state.hp, state.maxhp = p.hp, p.maxhp
  state.mana, state.maxmana = p.mana, p.maxmana
  state.stam, state.maxstam = p.stam, p.maxstam
  if __recovery_on_vitals then __recovery_on_vitals() end

  local changed = (state.position ~= p.position)
  state.position = p.position
  if __recovery_on_position then __recovery_on_position(p.position, changed) end

  if p.fight_name then
    state.fighting, state.fight_pct, state.fight_name = true, p.fight_pct, p.fight_name
  else
    state.fighting, state.fight_name, state.fight_pct = false, nil, nil
  end

  -- AutoFight's kxwt_fighting-driven combat lifecycle never fires under nomelee (the server sends no
  -- kxwt_fighting there) — this prompt is its only signal. __autofight_prompt is a no-op guarded on
  -- AutoFight being loaded AND on kxwt having fired recently (see AutoFight.lua), so this call is always
  -- safe to make and harmless when kxwt is the live source.
  if __autofight_prompt then
    if p.fight_name then __autofight_prompt(p.fight_pct, p.fight_name)
    else __autofight_prompt(nil, nil) end
  end

  if on_update then on_update() end
end

function on_prompt(text)
  apply_prompt(parse_prompt(text))
end

_PROMPT_TEST.parse_prompt = parse_prompt
_PROMPT_TEST.apply_prompt = apply_prompt
