-- Specs for Parse.lua — the bidirectional parser/PRINTER-combinator library. Covers each combinator's
-- parse direction, its print direction, and a round-trip (parse then print returns the input) for a
-- representative grammar, plus the duality failure modes (mapf/flatMap aren't printable) and the
-- _dsl.tl `:as` sub-grammar seam (parser_as_conversion).

local parse = __parse or dofile("Scripts/Foundation/Parse.lua")

-- ---- succeed / fail --------------------------------------------------------------------------------
test("succeed: always parses without consuming input; print writes nothing", function()
  local p = parse.succeed(42)
  local v, err = p.run("anything", 1)
  expect(v.ok):truthy()
  expect(v.value):eq(42)
  expect(v.pos):eq(1)                        -- didn't consume
  expect(err):eq(nil)
  local pr = p:print(999)                    -- no equality check against the sealed value (documented gap)
  expect(pr.ok):truthy()
  expect(pr.text):eq("")
end)

test("fail: always fails to parse without consuming input, and is never printable", function()
  local p = parse.fail("nope")
  local r = p.run("anything", 1)
  expect(r.ok):falsy()
  expect(r.pos):eq(1)
  expect(r.label):eq("nope")
  local pr = p:print(nil)
  expect(pr.ok):falsy()
end)

-- ---- lit --------------------------------------------------------------------------------------------
test("lit: matches an exact literal and advances past it; print reproduces the literal", function()
  local p = parse.lit("kxwq_hud")
  local r = p.run("kxwq_hud|100", 1)
  expect(r.ok):truthy()
  expect(r.pos):eq(9)
  local pr = p:print(parse.UNIT)
  expect(pr.ok):truthy()
  expect(pr.text):eq("kxwq_hud")
end)

test("lit: fails (without consuming) on a mismatch", function()
  local p = parse.lit("foo")
  local r = p.run("bar", 1)
  expect(r.ok):falsy()
  expect(r.pos):eq(1)
end)

-- ---- pat --------------------------------------------------------------------------------------------
test("pat: matches a Lua pattern anchored at pos; print round-trips a matching value", function()
  local p = parse.pat("%a+", "word")
  local r = p.run("hello world", 1)
  expect(r.ok):truthy()
  expect(r.value):eq("hello")
  expect(r.pos):eq(6)
  local pr = p:print("hello")
  expect(pr.ok):truthy()
  expect(pr.text):eq("hello")
end)

test("pat: print rejects a value that doesn't match the pattern (real round-trip protection)", function()
  local p = parse.pat("%a+", "word")
  local pr = p:print("123")
  expect(pr.ok):falsy()
end)

-- ---- digits / int_parser / number_parser -------------------------------------------------------------
test("digits: parses one-or-more ASCII digits into an integer, and prints it back", function()
  local r = parse.digits.run("80|rest", 1)
  expect(r.ok):truthy()
  expect(r.value):eq(80)
  expect(r.pos):eq(3)
  local pr = parse.digits:print(80)
  expect(pr.ok):truthy()
  expect(pr.text):eq("80")
end)

test("int_parser: parses a signed integer", function()
  local r = parse.int_parser.run("-42x", 1)
  expect(r.ok):truthy()
  expect(r.value):eq(-42)
  local pr = parse.int_parser:print(-42)
  expect(pr.text):eq("-42")
end)

test("number_parser: parses a decimal literal", function()
  local r = parse.number_parser.run("3.5!", 1)
  expect(r.ok):truthy()
  expect(r.value):eq(3.5)
  local pr = parse.number_parser:print(3.5)
  expect(pr.text):eq("3.5")
end)

-- ---- prefix_up_to / rest_of_input / end_of_input -----------------------------------------------------
test("prefix_up_to: consumes up to (not including) the separator", function()
  local p = parse.prefix_up_to("|")
  local r = p.run("standing|65", 1)
  expect(r.ok):truthy()
  expect(r.value):eq("standing")
  expect(r.pos):eq(9)                        -- points at the "|"
  local pr = p:print("standing")
  expect(pr.ok):truthy()
  expect(pr.text):eq("standing")
end)

test("prefix_up_to: consumes to end of input when the separator never occurs", function()
  local p = parse.prefix_up_to("|")
  local r = p.run("nosep", 1)
  expect(r.ok):truthy()
  expect(r.value):eq("nosep")
  expect(r.pos):eq(6)
end)

test("prefix_up_to: print rejects a value that itself contains the separator", function()
  local p = parse.prefix_up_to("|")
  local pr = p:print("a|b")
  expect(pr.ok):falsy()
end)

test("rest_of_input: consumes everything remaining; print reproduces it verbatim", function()
  local r = parse.rest_of_input.run("hello world", 7)
  expect(r.ok):truthy()
  expect(r.value):eq("world")
  local pr = parse.rest_of_input:print("world")
  expect(pr.text):eq("world")
end)

test("end_of_input: succeeds only at end of input, consuming nothing; print writes nothing", function()
  local ok_r = parse.end_of_input.run("abc", 4)
  expect(ok_r.ok):truthy()
  local fail_r = parse.end_of_input.run("abc", 1)
  expect(fail_r.ok):falsy()
  local pr = parse.end_of_input:print(parse.UNIT)
  expect(pr.text):eq("")
end)

-- ---- oneOf --------------------------------------------------------------------------------------------
test("oneOf: tries alternatives in order, first success wins", function()
  local p = parse.oneOf(parse.lit("kxwq_hud"), parse.lit("kxwt_hud"))
  expect(p.run("kxwq_hud", 1).ok):truthy()
  expect(p.run("kxwt_hud", 1).ok):truthy()
  expect(p.run("nope", 1).ok):falsy()
end)

test("oneOf: print prefers the FIRST alternative that can print the value (canonicalization)", function()
  local p = parse.oneOf(parse.lit("kxwq_hud"), parse.lit("kxwt_hud"))
  local pr = p:print(parse.UNIT)
  expect(pr.ok):truthy()
  expect(pr.text):eq("kxwq_hud")             -- canonical spelling, regardless of which synonym parsed
end)

-- ---- many / many1 -----------------------------------------------------------------------------------
test("many: zero-or-more separated elements; zero matches -> {}, never fails", function()
  local p = parse.many(parse.digits, parse.lit(","))
  local r = p.run("1,2,3", 1)
  expect(r.ok):truthy()
  expect(#r.value):eq(3)
  expect(r.value[1]):eq(1)
  expect(r.value[3]):eq(3)
  local empty_r = parse.many(parse.digits, parse.lit(",")).run("abc", 1)
  expect(empty_r.ok):truthy()
  expect(#empty_r.value):eq(0)
end)

test("many: print joins elements with the separator", function()
  local p = parse.many(parse.digits, parse.lit(","))
  local pr = p:print({ 1, 2, 3 })
  expect(pr.ok):truthy()
  expect(pr.text):eq("1,2,3")
end)

test("many1: requires at least one match; fails (not {}) on zero", function()
  local p = parse.many1(parse.digits, parse.lit(","))
  local r = p.run("abc", 1)
  expect(r.ok):falsy()
  local ok_r = p.run("7", 1)
  expect(ok_r.ok):truthy()
  expect(#ok_r.value):eq(1)
end)

test("many1: print rejects an empty array (couldn't have been produced by many1)", function()
  local p = parse.many1(parse.digits, parse.lit(","))
  local pr = p:print({})
  expect(pr.ok):falsy()
end)

-- ---- seq2 / seq3 / seq4 -------------------------------------------------------------------------------
test("seq2: sequences two parsers, combining outputs; print deconstructs and re-emits", function()
  local slash = parse.lit("/")
  local g = parse.seq2(
    parse.digits:skip(slash), parse.digits,
    function(cur, max) return { cur = cur, max = max } end,
    function(hm) return hm.cur, hm.max end
  )
  local r = g.run("80/100", 1)
  expect(r.ok):truthy()
  expect(r.value.cur):eq(80)
  expect(r.value.max):eq(100)
  local pr = g:print({ cur = 80, max = 100 })
  expect(pr.ok):truthy()
  expect(pr.text):eq("80/100")
end)

test("seq3: sequences three parsers", function()
  local slash = parse.lit("/")
  local g = parse.seq3(
    parse.digits:skip(slash), parse.digits:skip(slash), parse.digits,
    function(a, b, c) return { a, b, c } end,
    function(t) return t[1], t[2], t[3] end
  )
  local r = g.run("1/2/3", 1)
  expect(r.ok):truthy()
  expect(r.value[1]):eq(1)
  expect(r.value[3]):eq(3)
  local pr = g:print({ 1, 2, 3 })
  expect(pr.text):eq("1/2/3")
end)

test("seq4: sequences four parsers", function()
  local slash = parse.lit("/")
  local g = parse.seq4(
    parse.digits:skip(slash), parse.digits:skip(slash), parse.digits:skip(slash), parse.digits,
    function(a, b, c, d) return { a, b, c, d } end,
    function(t) return t[1], t[2], t[3], t[4] end
  )
  local r = g.run("1/2/3/4", 1)
  expect(r.ok):truthy()
  expect(r.value[4]):eq(4)
  local pr = g:print({ 1, 2, 3, 4 })
  expect(pr.text):eq("1/2/3/4")
end)

-- ---- map / mapf / flatMap duality --------------------------------------------------------------------
test("map(Conversion): stays printable both ways (digits is pat():map(int_conv) under the hood)", function()
  local r = parse.digits.run("5", 1)
  expect(r.ok):truthy()
  expect(r.value):eq(5)
  local pr = parse.digits:print(5)
  expect(pr.ok):truthy()
  expect(pr.text):eq("5")
end)

test("mapf: parses fine but print always fails at runtime with a clear message", function()
  local p = parse.digits:mapf(function(n) return n * 2 end)
  local r = p.run("21", 1)
  expect(r.ok):truthy()
  expect(r.value):eq(42)
  local pr = p:print(42)
  expect(pr.ok):falsy()
  expect(pr.err):eq("not printable: built with mapf (a one-way transform) — use map(Conversion) for a printable pipeline")
end)

test("flatMap: parses fine but print always fails at runtime", function()
  local p = parse.digits:flatMap(function(n) return parse.succeed(n) end)
  local r = p.run("7", 1)
  expect(r.ok):truthy()
  expect(r.value):eq(7)
  local pr = p:print(7)
  expect(pr.ok):falsy()
end)

-- ---- skip / take / opt --------------------------------------------------------------------------------
test("skip: keeps the left value, discards the right (a structural delimiter)", function()
  local p = parse.digits:skip(parse.lit("|"))
  local r = p.run("42|rest", 1)
  expect(r.ok):truthy()
  expect(r.value):eq(42)
  expect(r.pos):eq(4)
  local pr = p:print(42)
  expect(pr.ok):truthy()
  expect(pr.text):eq("42|")
end)

test("take: keeps the right value, discards the left (a structural prefix)", function()
  local p = parse.lit("kxwq_hud"):take(parse.lit("|")):take(parse.digits)
  local r = p.run("kxwq_hud|42", 1)
  expect(r.ok):truthy()
  expect(r.value):eq(42)
  local pr = p:print(42)
  expect(pr.ok):truthy()
  expect(pr.text):eq("kxwq_hud|42")
end)

test("opt: substitutes a default when the underlying parser fails, without erroring", function()
  local p = parse.digits:opt(0)
  local r = p.run("abc", 1)
  expect(r.ok):truthy()
  expect(r.value):eq(0)
  expect(r.pos):eq(1)                        -- no input consumed on the fallback
  local ok_r = p.run("9", 1)
  expect(ok_r.value):eq(9)
end)

-- ---- parse_all / print_all (entry points) --------------------------------------------------------------
test("parse_all: requires the WHOLE string to be consumed (implicit end_of_input)", function()
  local v, err = parse.parse_all(parse.digits, "42")
  expect(v):eq(42)
  expect(err):eq(nil)
  local v2, err2 = parse.parse_all(parse.digits, "42abc")
  expect(v2):eq(nil)
  expect(err2 ~= nil):truthy()
end)

test("print_all: returns the printed text, or nil+error on a print failure", function()
  local text, err = parse.print_all(parse.digits, 42)
  expect(text):eq("42")
  expect(err):eq(nil)
  local text2, err2 = parse.print_all(parse.fail("x"), nil)
  expect(text2):eq(nil)
  expect(err2 ~= nil):truthy()
end)

-- ---- parser_as_conversion (the _dsl.tl `:as` sub-grammar seam) -------------------------------------------
test("parser_as_conversion: adapts a full sub-grammar into a Conversion<string, T>", function()
  local slash = parse.lit("/")
  local hp_max_grammar = parse.seq2(
    parse.digits:skip(slash), parse.digits,
    function(cur, max) return { cur = cur, max = max } end,
    function(hm) return hm.cur, hm.max end
  )
  local conv = parse.parser_as_conversion(hp_max_grammar)
  local v = conv.apply("80/100")
  expect(v.cur):eq(80)
  expect(v.max):eq(100)
  local s = conv.unapply({ cur = 80, max = 100 })
  expect(s):eq("80/100")
  -- malformed input surfaces as a plain nil (not an error()), matching _dsl.tl's existing convention:
  expect(conv.apply("not-a-fraction")):eq(nil)
end)

-- ---- round-trip: a representative multi-field grammar (mirrors Prompt.lua's shape) -----------------------
test("round-trip: sentinel + pipe-delimited fields parses then prints back to the exact input", function()
  local sentinel = parse.oneOf(parse.lit("kxwq_hud"), parse.lit("kxwt_hud"))
  local pipe = parse.lit("|")
  local field = parse.prefix_up_to("|")
  local grammar = sentinel:take(pipe):take(parse.many1(field, pipe))

  local input = "kxwq_hud|80|100|standing"
  local fields, err = parse.parse_all(grammar, input)
  expect(err):eq(nil)
  expect(#fields):eq(3)
  expect(fields[1]):eq("80")
  expect(fields[3]):eq("standing")

  local printed, perr = parse.print_all(grammar, fields)
  expect(perr):eq(nil)
  expect(printed):eq(input)

  -- and the synonym sentinel canonicalizes to the primary spelling on print, exactly as oneOf's spec above:
  local syn_fields = parse.parse_all(grammar, "kxwt_hud|80|100|standing")
  local syn_printed = parse.print_all(grammar, syn_fields)
  expect(syn_printed):eq(input)
end)
