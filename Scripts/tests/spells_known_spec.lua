-- Specs for the character's KNOWN spells: parsing the `spells` command output (AlterAeon.lua),
-- classifying offensive-vs-buff against SPELL_DB, and the combat pilot's use of that (AIPilot.lua) — the
-- damage-spell prompt line and the melee/hallucination -> real-spell substitution. Rows are VERBATIM
-- `spells` output (captured from a human trace: a Mage/Cleric multi-class caster).

local parse_spell_row     = _AA_TEST.parse_spell_row
local classify_spell      = _AA_TEST.classify_spell
local annotate_spells     = _AA_TEST.annotate_spells
local parse_spells_block  = _AA_TEST.parse_spells_block

-- Verbatim `spells` output. Column gaps are the real space-padding; buffs (crystal light, infravision,
-- mana shield, fly) and the cleric heal (soothe wounds) carry NO Damage tier so they are non-offensive.
local BLOCK = table.concat({
  "You know the following spells:",
  "Mage",
  "-----------------------------------------------------------------",
  "chill touch                         very good  81%",
  "frostflower                            poor  28%",
  "crystal light                       very good  84%",
  "shards                            very good  87%",
  "shower of sparks                    very good  87%",
  "burning hands                      moderate  56%",
  "infravision                          fair  43%",
  "static blast                        very good  87%",
  "mana shield                          moderate  56%",
  "fly                                moderate  56%",
  "Cleric",
  "-----------------------------------------------------------------",
  "soothe wounds                          good  62%",
  "<107hp 171m 167mv>",
}, "\n")

-- ---- parsing --------------------------------------------------------------------------------------
test("parse_spell_row reads a verbatim spells row into name + proficiency + percent", function()
  local r = parse_spell_row("shower of sparks                    very good  87%")
  expect(r):truthy()
  expect(r.name):eq("shower of sparks")   -- multi-word name kept whole
  expect(r.prof):eq("very good")
  expect(r.pct):eq(87)
  -- Single-word proficiency + name with a space.
  local r2 = parse_spell_row("frostflower                            poor  28%")
  expect(r2.name):eq("frostflower"); expect(r2.prof):eq("poor"); expect(r2.pct):eq(28)
  -- Class header, the "----" rule, and the header line are NOT spell rows.
  expect(parse_spell_row("Mage")):eq(nil)
  expect(parse_spell_row("-----------------------------------------------------------------")):eq(nil)
  expect(parse_spell_row("You know the following spells:")):eq(nil)
  expect(parse_spell_row("<107hp 171m 167mv>")):eq(nil)
end)

test("classify_spell flags DAMAGE spells offensive (with mana+tier) and buffs/utility non-offensive", function()
  local off, mana, tier = classify_spell("shower of sparks")
  expect(off):truthy(); expect(mana):eq(4); expect(tier):eq("low")
  local off2, mana2, tier2 = classify_spell("frostflower")
  expect(off2):truthy(); expect(tier2):eq("moderate")
  -- Case-insensitive.
  expect((classify_spell("Shards"))):truthy()
  -- Buffs / utility / heals are NOT offensive.
  expect((classify_spell("mana shield"))):falsy()
  expect((classify_spell("infravision"))):falsy()
  expect((classify_spell("crystal light"))):falsy()
  expect((classify_spell("soothe wounds"))):falsy()
end)

test("parse_spells_block captures ALL classes and annotates each known spell", function()
  local known = parse_spells_block(BLOCK)
  local by = {}
  for _, s in ipairs(known) do by[s.name] = s end
  -- Every listed spell captured across both class sections (buffs included, correctly non-offensive).
  expect(by["chill touch"]):truthy()
  expect(by["soothe wounds"]):truthy()        -- the Cleric section, past the second "----" rule
  expect(by["shards"].offensive):truthy()
  expect(by["shards"].mana):eq(4)
  expect(by["mana shield"].offensive):falsy()
  -- Exactly the offensive damage spells this character has.
  local offs = {}
  for _, s in ipairs(known) do if s.offensive then offs[#offs + 1] = s.name end end
  table.sort(offs)
  expect(table.concat(offs, ",")):eq("burning hands,chill touch,frostflower,shards,shower of sparks,static blast")
end)

test("annotate_spells drops a 'not learned' straggler", function()
  local out = annotate_spells({ { name = "shards", prof = "very good", pct = 87 },
                                { name = "fireball", prof = "not learned", pct = 0 } })
  expect(#out):eq(1)
  expect(out[1].name):eq("shards")
end)

-- ---- combat use (AIPilot.lua) ---------------------------------------------------------------------
local damage_spells_ranked = _AIP_TEST.damage_spells_ranked
local combat_spell_line    = _AIP_TEST.combat_spell_line
local best_damage_spell    = _AIP_TEST.best_damage_spell
local combat_substitute    = _AIP_TEST.combat_substitute
local build_combat_user    = _AIP_TEST.build_combat_user

local KNOWN = parse_spells_block(BLOCK)                              -- the caster's real known spells
local BUFFS_ONLY = { { name = "bless", offensive = false },
                     { name = "mana shield", offensive = false } }   -- a non-caster (warrior/thief)

-- Set of this character's offensive spell names, for asserting a substitution picked a REAL one.
local OFF_SET = {}
for _, s in ipairs(KNOWN) do if s.offensive then OFF_SET[s.name] = true end end

test("damage_spells_ranked orders known offensive spells strongest-first (weakest last)", function()
  local ranked = damage_spells_ranked(KNOWN)
  expect(#ranked):eq(6)
  expect(ranked[1].tier):eq("moderate")     -- strongest tier this caster has, first
  expect(ranked[#ranked].name):eq("static blast")   -- the only 'minor' spell, last
  expect(damage_spells_ranked(BUFFS_ONLY)[1]):eq(nil)   -- non-caster => no damage spells
end)

test("combat_spell_line names the character's REAL damage spells (and nil for a non-caster)", function()
  local line = combat_spell_line(KNOWN)
  expect(line:match("^YOUR DAMAGE SPELLS")):truthy()
  for name in pairs(OFF_SET) do expect(line:find(name, 1, true)):truthy() end   -- all 6 present
  expect(line:find("mana shield", 1, true)):eq(nil)   -- no buff leaks in
  expect(line:find("fireball", 1, true)):eq(nil)      -- no spell it doesn't have
  expect(combat_spell_line(BUFFS_ONLY)):eq(nil)
end)

test("build_combat_user injects the damage-spell line into the combat prompt", function()
  local saved = state.spells_known
  state.spells_known = KNOWN
  local user = build_combat_user("hp: 89/89, mana: 120/163", "an orc bachelor", "recent output", nil)
  expect(user:find("YOUR DAMAGE SPELLS", 1, true)):truthy()
  expect(user:find("frostflower", 1, true)):truthy()
  state.spells_known = nil
  local bare = build_combat_user("hp: 89/89", "", "out", nil)   -- no spells known => no line
  expect(bare:find("YOUR DAMAGE SPELLS", 1, true)):eq(nil)
  state.spells_known = saved
end)

test("best_damage_spell picks best AFFORDABLE, else the cheapest (never nothing) for a caster", function()
  local with_mana = best_damage_spell(KNOWN, 100)
  expect(OFF_SET[with_mana.name]):truthy()
  expect(with_mana.tier):eq("moderate")            -- affords the strongest tier it has
  -- Almost no mana: nothing strictly affordable, so fall back to a cheapest real spell (a stretch, but
  -- still a REAL known damage spell rather than a melee whiff).
  local broke = best_damage_spell(KNOWN, 1)
  expect(OFF_SET[broke.name]):truthy()
  expect(best_damage_spell(BUFFS_ONLY, 100)):eq(nil)
end)

test("combat_substitute rewrites a MELEE attack into the caster's best real damage spell", function()
  local out = combat_substitute("kill orc bachelor", KNOWN, 100)
  local spell, tgt = out:match("^cast '([^']+)' (.+)$")
  expect(OFF_SET[spell]):truthy()        -- a REAL known damage spell
  expect(tgt):eq("orc bachelor")         -- target preserved
  -- 'attack' verb too.
  expect(combat_substitute("attack goblin", KNOWN, 100):match("^cast '")):truthy()
end)

test("combat_substitute rewrites a HALLUCINATED (unknown) spell but LEAVES a valid known cast alone", function()
  -- Model invents a spell the character does not have -> substitute a real one, keep the target.
  local out = combat_substitute("cast 'fireball' orc", KNOWN, 100)
  local spell, tgt = out:match("^cast '([^']+)' (.+)$")
  expect(OFF_SET[spell]):truthy()
  expect(spell ~= "fireball"):truthy()
  expect(tgt):eq("orc")
  -- A valid known cast (offensive) is untouched...
  expect(combat_substitute("cast 'shards' orc", KNOWN, 100)):eq("cast 'shards' orc")
  -- ...and so is a valid known UTILITY cast (never rewrite a real cast, even a buff).
  expect(combat_substitute("cast 'mana shield'", KNOWN, 100)):eq("cast 'mana shield'")
  -- Unquoted known form is recognized too.
  expect(combat_substitute("cast shower of sparks orc", KNOWN, 100)):eq("cast shower of sparks orc")
end)

test("combat_substitute never touches a NON-caster's commands (no offensive spells known)", function()
  expect(combat_substitute("kill orc", BUFFS_ONLY, 100)):eq("kill orc")
  expect(combat_substitute("cast 'fireball' orc", BUFFS_ONLY, 100)):eq("cast 'fireball' orc")
  -- And never touches non-attack commands even for a caster.
  expect(combat_substitute("flee", KNOWN, 100)):eq("flee")
  expect(combat_substitute("get corpse", KNOWN, 100)):eq("get corpse")
end)

-- execute()'s gate now applies this rewrite to a melee-INITIATION command even OUT of combat (the
-- "attack" tool builds a raw `kill <target>`), so a caster never opens with melee (which can trigger a
-- nomelee tank-rescue kxwt flip). combat_substitute itself doesn't key off combat state, so the rewrite
-- is identical whether the fight has started or not — this documents that the initiation case is covered.
test("combat_substitute rewrites an OUT-of-combat melee INITIATION for a caster; a non-caster is untouched", function()
  local out = combat_substitute("kill goblin", KNOWN, 100)
  local spell, tgt = out:match("^cast '([^']+)' (.+)$")
  expect(OFF_SET[spell]):truthy()        -- engaged via a real known spell, not melee
  expect(tgt):eq("goblin")               -- target preserved
  expect(combat_substitute("kill goblin", BUFFS_ONLY, 100)):eq("kill goblin")   -- non-caster: melee left as-is
end)
