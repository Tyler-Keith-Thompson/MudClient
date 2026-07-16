-- Parse.tl — a declarative parser-PRINTER-combinator library (compiles to Scripts/Foundation/Parse.lua
-- via `tl gen`), modeled on the local swift-parsing fork (pointfreeco/swift-parsing).
--
-- CORE MODEL: a Parser<T> wraps a pure function `run(input: string, pos: integer) -> Result<T>` (parse)
-- and a `print(self, T) -> PrintResult` (print), rather than swift-parsing's single
-- `parse(inout Input) throws -> Output` + conditional `print`. Swift mutates a `Substring` in place
-- (cheap slice, moves a start index); Teal strings are immutable and slicing copies, so instead of
-- slicing the string we thread an integer BYTE POSITION through every parser (1-based, Lua
-- string-index convention) and never touch the string itself on the parse side. On the print side there
-- is no position to thread — printing builds a fresh string bottom-up via ordinary concatenation
-- (forward order; swift-parsing's printers PREPEND because Swift's `Substring`/`RangeReplaceableCollection`
-- make prepending cheap and the printer builds "the remaining input to print" in reverse — that
-- optimization doesn't apply here since we always start from an empty string, so plain left-to-right
-- concatenation is both simpler and correct).
--
-- No result builders: Teal/Lua has no `@resultBuilder` equivalent, so sequencing is explicit
-- combinators (`seq2`/`seq3`/`seq4`, `.skip()`, `.take()`) and transformation is `.map()` (Conversion,
-- bidirectional) / `.mapf()` / `.flatMap()` (one-way), chained with `:` method syntax so a pipeline
-- still reads top-to-bottom declaratively.
--
-- PARSER/PRINTER DUALITY: every Parser<T> carries BOTH `run` (parse) and `print` (print), modeled on
-- swift-parsing's `ParserPrinter` protocol. The tension that duality creates: a plain closure
-- `function(T): U` transform (`mapf`, `flatMap`) can't be run backwards — you'd need to invert an
-- arbitrary function, which is undecidable in general. swift-parsing's answer is `Conversion`
-- (`apply`/`unapply`, a value pair the AUTHOR proves is invertible) plus TYPE SYSTEM enforcement:
-- `Parser.map(_ f:)` returns a plain `Parser` (parse-only), `Parser.map(_ c: Conversion)` returns a
-- `ParserPrinter` (both directions) — Swift's conditional conformance statically prevents calling
-- `.print` on a `mapf`'d/`flatMap`'d pipeline; the type just doesn't have a `print` method.
--
-- Teal has no conditional conformance (a record's field set can't vary by how it was constructed), so
-- `Parser<T>.print` exists UNCONDITIONALLY on every parser, including ones built with `mapf`/`flatMap`.
-- Those two combinators's `print` is a documented, always-fails RUNTIME stub ("not printable: built
-- with mapf/flatMap") rather than a compile error — the one real degradation versus Swift: a caller who
-- calls `.print` on a `mapf`'d parser finds out at run time, not compile time. Naming (`map` =
-- bidirectional/preferred, `mapf` = "map with a plain function", explicitly the escape hatch) is the
-- mitigation.
--
-- Similarly `.skip`/`.take` require their DISCARDED side to be a "structural" parser (one whose print
-- ignores its input value entirely — `lit`, `succeed`, `end_of_input`) for the round trip to make
-- sense; there's no `Output == Void` constraint to enforce this statically, so it's convention +
-- runtime failure (a placeholder `nil` is fed to the discarded side's `print`; if that print actually
-- inspects its argument, it throws). Every primitive here that's meant to be used as a discardable
-- delimiter/keyword is typed `Parser<Unit>` specifically to signal "print-argument-free."
--
-- Parser<T>/Conversion<A,B>/Result<T>/PrintResult/Unit are declared GLOBAL, ambient, in foundation.d.tl
-- (not here — this file is checked against that contract, same decoupling as every other Foundation
-- module). Published as the `__parse` global (mirrors __rx/__promise/__persist): `local parse = __parse`,
-- then `parse.lit(...)`, `parse.oneOf(...)`, `parse.digits`, etc. `_`-prefixed files aren't auto-loaded
-- by the directory loader, so pull this in the documented way: `pcall(require, "Parse"); if not
-- __parse then dofile("Scripts/Foundation/Parse.lua") end` — except this file isn't `_`-prefixed (it's
-- meant to be reusable/testable on its own, like Promise.lua), so a plain `require("Parse")` also works.
--
-- HONEST GAPS vs. the Swift original (flagged, not papered over):
--   * `succeed(v)`'s print does not verify the printed value equals `v` (no general Equatable in this
--     library, unlike swift-parsing's `Always`) — a mismatched value silently "succeeds" on print.
--   * `Conversion.apply`/`unapply` invertibility is an author obligation, not statically verified.
--   * `.skip`/`.take`'s "discarded side must be structural" is convention + runtime failure, not a type
--     constraint (Teal has no `Output == Void`/`Never` equivalent to enforce it at compile time).

-- global test seam (matches _AA_TEST/_AIP_TEST/_PROMISE_TEST/etc's declare-inline-in-the-defining-script
-- convention)
global _PARSE_TEST: {string:any}

-- Wires the method fields onto a bare `{ run = ..., print = ... }` table. Every combinator below
-- funnels through this so `.map`/`.mapf`/`.flatMap`/`.skip`/`.take`/`.opt` are always available on
-- anything this library hands back, INCLUDING the parser each method itself returns — the method
-- closures call `mk` again on their way out (`mk` is a `local function`, so it can recurse), which is
-- what keeps a chain like `p:map(f):skip(q):take(r)` working at every link rather than only the first.
-- This is also why the methods are built as closures here rather than shared top-level functions: a
-- shared function assigned to `p.map` before `mk` itself is fully defined hits a Lua/Teal
-- forward-reference wall (locals resolve lexically, not at call time) — closing over `mk` from inside
-- `mk`'s own body sidesteps that. (Internal only — not part of the `Parse` module surface.)
local function mk<T>(run: function(string, integer): Result<T>,
                      print_: function(T): PrintResult): Parser<T>
   local p: Parser<T> = { run = run }
   p.print = function(_self: Parser<T>, v: T): PrintResult
      return print_(v)
   end
   p.map = function<U>(self: Parser<T>, conv: Conversion<T, U>): Parser<U>
      return mk(
         function(s: string, pos: integer): Result<U>
            local r = self.run(s, pos)
            if not r.ok then
               return { ok = false, pos = r.pos, label = r.label }
            end
            return { ok = true, value = conv.apply(r.value), pos = r.pos }
         end,
         function(u: U): PrintResult
            return self:print(conv.unapply(u))
         end
      )
   end
   p.mapf = function<U>(self: Parser<T>, f: function(T): U): Parser<U>
      return mk(
         function(s: string, pos: integer): Result<U>
            local r = self.run(s, pos)
            if not r.ok then
               return { ok = false, pos = r.pos, label = r.label }
            end
            return { ok = true, value = f(r.value), pos = r.pos }
         end,
         function(_u: U): PrintResult
            return { ok = false, err = "not printable: built with mapf (a one-way transform) — use map(Conversion) for a printable pipeline" }
         end
      )
   end
   p.flatMap = function<U>(self: Parser<T>, f: function(T): Parser<U>): Parser<U>
      return mk(
         function(s: string, pos: integer): Result<U>
            local r = self.run(s, pos)
            if not r.ok then
               return { ok = false, pos = r.pos, label = r.label }
            end
            return f(r.value).run(s, r.pos)
         end,
         function(_u: U): PrintResult
            return { ok = false, err = "not printable: built with flatMap (a one-way transform)" }
         end
      )
   end
   p.skip = function<U>(self: Parser<T>, other: Parser<U>): Parser<T>
      return mk(
         function(s: string, pos: integer): Result<T>
            local r = self.run(s, pos)
            if not r.ok then return r end
            local r2 = other.run(s, r.pos)
            if not r2.ok then
               return { ok = false, pos = r2.pos, label = r2.label }
            end
            return { ok = true, value = r.value, pos = r2.pos }
         end,
         function(t: T): PrintResult
            local pr1 = self:print(t)
            if not pr1.ok then return pr1 end
            -- `other`'s value is discarded on parse, so there is none to print here; this only makes
            -- sense (see the file-top note) if `other` is a "structural" parser whose print ignores its
            -- argument (lit/succeed/end_of_input) — hence the unchecked placeholder cast.
            local pr2 = other:print(nil as U)
            if not pr2.ok then return pr2 end
            return { ok = true, text = pr1.text .. pr2.text }
         end
      )
   end
   p.take = function<U>(self: Parser<T>, other: Parser<U>): Parser<U>
      return mk(
         function(s: string, pos: integer): Result<U>
            local r = self.run(s, pos)
            if not r.ok then
               return { ok = false, pos = r.pos, label = r.label }
            end
            return other.run(s, r.pos)
         end,
         function(u: U): PrintResult
            local pr2 = other:print(u)
            if not pr2.ok then return pr2 end
            -- Same placeholder-cast caveat as `skip`, mirrored: `self`'s value is discarded on parse.
            local pr1 = self:print(nil as T)
            if not pr1.ok then return pr1 end
            return { ok = true, text = pr1.text .. pr2.text }
         end
      )
   end
   p.opt = function(self: Parser<T>, default: T): Parser<T>
      return mk(
         function(s: string, pos: integer): Result<T>
            local r = self.run(s, pos)
            if r.ok then return r end
            return { ok = true, value = default, pos = pos }
         end,
         function(t: T): PrintResult
            local pr = self:print(t)
            if pr.ok then return pr end
            return { ok = true, text = "" }   -- couldn't print `t` through self -> treat as "absent"
         end
      )
   end
   return p
end

-- ── Primitives ──────────────────────────────────────────────────────────────────────────────────────

local UNIT: Unit = {}

-- Always succeeds without consuming input. Print writes nothing (no round-trip equality check against
-- `v` — see the file-top honest-gaps note).
local function succeed<T>(v: T): Parser<T>
   return mk(
      function(_s: string, pos: integer): Result<T>
         return { ok = true, value = v, pos = pos }
      end,
      function(_t: T): PrintResult
         return { ok = true, text = "" }
      end
   )
end

-- Always fails with the given label, without consuming input. Print always fails too — there is no
-- value this parser could ever have produced, so nothing is printable through it.
local function fail<T>(label: string): Parser<T>
   return mk(
      function(_s: string, pos: integer): Result<T>
         return { ok = false, pos = pos, label = label }
      end,
      function(_t: T): PrintResult
         return { ok = false, err = "not printable: unconditional fail(\"" .. label .. "\")" }
      end
   )
end

-- Matches (and prints) an exact literal string. Output is `Unit` — like swift-parsing's `String:
-- ParserPrinter` (whose `parse` returns `Void`), a literal carries no information once matched, so
-- there is nothing to extract; this is what makes `lit(...)` safe to use as the discarded side of
-- `.skip`/`.take` (its print ignores the passed `Unit`).
local function lit(match: string): Parser<Unit>
   return mk(
      function(s: string, pos: integer): Result<Unit>
         if s:sub(pos, pos + #match - 1) == match then
            return { ok = true, value = UNIT, pos = pos + #match }
         end
         return { ok = false, pos = pos, label = "\"" .. match .. "\"" }
      end,
      function(_u: Unit): PrintResult
         return { ok = true, text = match }
      end
   )
end

-- Matches a Lua pattern anchored at the current position (the pattern should NOT include a leading
-- `^`; one is added). Returns the full match. Print re-verifies the printed value actually matches the
-- same pattern (anchored both ends) before emitting it — cheap, real round-trip protection, unlike
-- `succeed`'s "no check at all".
local function pat(pattern: string, label: string): Parser<string>
   return mk(
      function(s: string, pos: integer): Result<string>
         local m = s:match("^(" .. pattern .. ")", pos)
         if m then
            return { ok = true, value = m, pos = pos + #m }
         end
         return { ok = false, pos = pos, label = label }
      end,
      function(v: string): PrintResult
         if v:match("^" .. pattern .. "$") then
            return { ok = true, text = v }
         end
         return { ok = false, err = "value " .. v .. " does not match pattern for " .. label }
      end
   )
end

local number_conv: Conversion<string, number> = {
   apply = function(s: string): number return tonumber(s) or 0.0 end,
   unapply = function(n: number): string return tostring(n) end,
}

local flag_conv: Conversion<string, boolean> = {
   apply = function(s: string): boolean return tonumber(s) == 1 end,
   unapply = function(b: boolean): string if b then return "1" else return "0" end end,
}

local int_conv: Conversion<string, integer> = {
   apply = function(s: string): integer return math.tointeger(tonumber(s)) or 0 end,
   unapply = function(n: integer): string return tostring(n) end,
}

-- One or more ASCII digits, converted to an integer — via `map(Conversion)`, so (unlike a hand-rolled
-- `mapf`) this stays printable: `digits:print(80)` -> `"80"`.
local digits: Parser<integer> = pat("%d+", "digits"):map(int_conv)

-- A signed integer literal (`-`? digits), also printable.
local int_parser: Parser<integer> = pat("%-?%d+", "integer"):map(int_conv)

-- A decimal number literal (digits, optional `.` + digits), also printable.
local number_parser: Parser<number> = pat("%-?%d+%.?%d*", "number"):map(number_conv)

-- Consumes up to (not including) the next occurrence of `sep`, or to end of input if `sep` never
-- occurs. Print rejects a value that itself contains `sep` (it couldn't have been produced by this
-- parser, and re-emitting it verbatim would silently corrupt the delimiter structure).
local function prefix_up_to(sep: string): Parser<string>
   return mk(
      function(s: string, pos: integer): Result<string>
         local found = s:find(sep, pos, true)
         local stop = found and (found - 1) or #s
         return { ok = true, value = s:sub(pos, stop), pos = stop + 1 }
      end,
      function(v: string): PrintResult
         if v:find(sep, 1, true) then
            return { ok = false, err = "value contains delimiter \"" .. sep .. "\"" }
         end
         return { ok = true, text = v }
      end
   )
end

-- Consumes the entire remainder of the input; nothing to validate on print (it's always terminal).
local rest_of_input: Parser<string> = mk(
   function(s: string, pos: integer): Result<string>
      return { ok = true, value = s:sub(pos), pos = #s + 1 }
   end,
   function(v: string): PrintResult
      return { ok = true, text = v }
   end
)

-- Succeeds only at end of input, consuming nothing; output `Unit` (nothing to extract), print writes
-- nothing (like swift-parsing's `End()`).
local end_of_input: Parser<Unit> = mk(
   function(s: string, pos: integer): Result<Unit>
      if pos > #s then
         return { ok = true, value = UNIT, pos = pos }
      end
      return { ok = false, pos = pos, label = "end of input" }
   end,
   function(_u: Unit): PrintResult
      return { ok = true, text = "" }
   end
)

-- ── Combinators ─────────────────────────────────────────────────────────────────────────────────────

-- Tries each alternative in order (most-specific first — same rule as swift-parsing's `OneOf`),
-- returning the first success on parse. On print, tries each alternative's print in order and returns
-- the first that succeeds — for alternatives with identical (e.g. `Unit`) output this deterministically
-- prints the FIRST one, which is usually exactly what you want (a canonical spelling, independent of
-- which synonym was originally parsed).
local function oneOf<T>(...: Parser<T>): Parser<T>
   local alts: {Parser<T>} = { ... }
   return mk(
      function(s: string, pos: integer): Result<T>
         local lastLabel = "no alternatives"
         for i = 1, #alts do
            local r = alts[i].run(s, pos)
            if r.ok then return r end
            lastLabel = r.label
         end
         return { ok = false, pos = pos, label = lastLabel }
      end,
      function(t: T): PrintResult
         local lastErr = "no alternatives"
         for i = 1, #alts do
            local pr = alts[i]:print(t)
            if pr.ok then return pr end
            lastErr = pr.err
         end
         return { ok = false, err = lastErr }
      end
   )
end

-- Runs `element` zero or more times, separated by `sep` (pass `nil` for no separator — consecutive
-- runs of `element`), accumulating outputs into an array. Never fails to parse (zero matches -> `{}`).
-- `sep` is `Parser<Unit>` — a separator carries no information of its own, only shape.
local function many<T>(element: Parser<T>, sep: Parser<Unit>): Parser<{T}>
   return mk(
      function(s: string, pos: integer): Result<{T}>
         local out: {T} = {}
         local cur = pos
         while true do
            local r = element.run(s, cur)
            if not r.ok then break end
            out[#out + 1] = r.value
            cur = r.pos
            if sep then
               local rs = sep.run(s, cur)
               if not rs.ok then break end
               cur = rs.pos
            end
         end
         return { ok = true, value = out, pos = cur }
      end,
      function(xs: {T}): PrintResult
         local text = ""
         for i = 1, #xs do
            if i > 1 and sep then
               local sepr = sep:print(UNIT)
               if not sepr.ok then return sepr end
               text = text .. sepr.text
            end
            local er = element:print(xs[i])
            if not er.ok then return er end
            text = text .. er.text
         end
         return { ok = true, text = text }
      end
   )
end

-- Like `many`, but fails to parse (rather than returning `{}`) if `element` doesn't match at least
-- once. Implemented directly (not via `flatMap`) so it stays printable.
local function many1<T>(element: Parser<T>, sep: Parser<Unit>): Parser<{T}>
   return mk(
      function(s: string, pos: integer): Result<{T}>
         local r1 = element.run(s, pos)
         if not r1.ok then
            return { ok = false, pos = r1.pos, label = r1.label }
         end
         local out: {T} = { r1.value }
         local cur = r1.pos
         while true do
            local rs = sep.run(s, cur)
            if not rs.ok then break end
            local re = element.run(s, rs.pos)
            if not re.ok then break end
            out[#out + 1] = re.value
            cur = re.pos
         end
         return { ok = true, value = out, pos = cur }
      end,
      function(xs: {T}): PrintResult
         if #xs == 0 then
            return { ok = false, err = "at least one element required" }
         end
         local text = ""
         for i = 1, #xs do
            if i > 1 then
               local sepr = sep:print(UNIT)
               if not sepr.ok then return sepr end
               text = text .. sepr.text
            end
            local er = element:print(xs[i])
            if not er.ok then return er end
            text = text .. er.text
         end
         return { ok = true, text = text }
      end
   )
end

-- Sequences two-to-four parsers, combining outputs with `combine` and — the printable-pipeline cost of
-- not having a result-builder auto-tupling the outputs — DEconstructing them back with `uncombine`.
-- Reads as: run `pa`, then `pb`, then fold both outputs through `combine`; print by splitting `r` with
-- `uncombine` and printing each piece through its own parser, concatenated in order.
local function seq2<A, B, R>(pa: Parser<A>, pb: Parser<B>,
                             combine: function(A, B): R,
                             uncombine: function(R): (A, B)): Parser<R>
   return mk(
      function(s: string, pos: integer): Result<R>
         local ra = pa.run(s, pos)
         if not ra.ok then return { ok = false, pos = ra.pos, label = ra.label } end
         local rb = pb.run(s, ra.pos)
         if not rb.ok then return { ok = false, pos = rb.pos, label = rb.label } end
         return { ok = true, value = combine(ra.value, rb.value), pos = rb.pos }
      end,
      function(r: R): PrintResult
         local a, b = uncombine(r)
         local pra = pa:print(a)
         if not pra.ok then return pra end
         local prb = pb:print(b)
         if not prb.ok then return prb end
         return { ok = true, text = pra.text .. prb.text }
      end
   )
end

local function seq3<A, B, C, R>(pa: Parser<A>, pb: Parser<B>, pc: Parser<C>,
                                 combine: function(A, B, C): R,
                                 uncombine: function(R): (A, B, C)): Parser<R>
   return mk(
      function(s: string, pos: integer): Result<R>
         local ra = pa.run(s, pos)
         if not ra.ok then return { ok = false, pos = ra.pos, label = ra.label } end
         local rb = pb.run(s, ra.pos)
         if not rb.ok then return { ok = false, pos = rb.pos, label = rb.label } end
         local rc = pc.run(s, rb.pos)
         if not rc.ok then return { ok = false, pos = rc.pos, label = rc.label } end
         return { ok = true, value = combine(ra.value, rb.value, rc.value), pos = rc.pos }
      end,
      function(r: R): PrintResult
         local a, b, c = uncombine(r)
         local pra = pa:print(a)
         if not pra.ok then return pra end
         local prb = pb:print(b)
         if not prb.ok then return prb end
         local prc = pc:print(c)
         if not prc.ok then return prc end
         return { ok = true, text = pra.text .. prb.text .. prc.text }
      end
   )
end

local function seq4<A, B, C, D, R>(pa: Parser<A>, pb: Parser<B>, pc: Parser<C>, pd: Parser<D>,
                                    combine: function(A, B, C, D): R,
                                    uncombine: function(R): (A, B, C, D)): Parser<R>
   return mk(
      function(s: string, pos: integer): Result<R>
         local ra = pa.run(s, pos)
         if not ra.ok then return { ok = false, pos = ra.pos, label = ra.label } end
         local rb = pb.run(s, ra.pos)
         if not rb.ok then return { ok = false, pos = rb.pos, label = rb.label } end
         local rc = pc.run(s, rb.pos)
         if not rc.ok then return { ok = false, pos = rc.pos, label = rc.label } end
         local rd = pd.run(s, rc.pos)
         if not rd.ok then return { ok = false, pos = rd.pos, label = rd.label } end
         return { ok = true, value = combine(ra.value, rb.value, rc.value, rd.value), pos = rd.pos }
      end,
      function(r: R): PrintResult
         local a, b, c, d = uncombine(r)
         local pra = pa:print(a)
         if not pra.ok then return pra end
         local prb = pb:print(b)
         if not prb.ok then return prb end
         local prc = pc:print(c)
         if not prc.ok then return prc end
         local prd = pd:print(d)
         if not prd.ok then return prd end
         return { ok = true, text = pra.text .. prb.text .. prc.text .. prd.text }
      end
   )
end

-- ── Top-level entry points ─────────────────────────────────────────────────────────────────────────
-- Forward-declared (mirrors _rx.tl's `merge_all` forward-decl): `parser_as_conversion` below needs to
-- call these before their bodies are assigned further down.
local parse_all: function<T>(Parser<T>, string): (T, string)
local print_all: function<T>(Parser<T>, T): (string, string)

-- Adapts any Parser<T> into a Conversion<string, T> by round-tripping through parse_all/print_all — a
-- full sub-grammar can stand in anywhere a flat string<->T converter was expected (see _dsl.tl's
-- `field(...):as(parser_as_conversion(...))`). Failure surfaces as a plain Lua `nil` (matching
-- `tonumber`'s existing "silently nil on bad input" convention in `_dsl.tl`, rather than `error()`ing).
local function parser_as_conversion<T>(p: Parser<T>): Conversion<string, T>
   return {
      apply = function(s: string): T
         local v = parse_all(p, s)
         return v
      end,
      unapply = function(v: T): string
         local s = print_all(p, v)
         return s
      end,
   }
end

-- Runs `p` against the full string `s`, requiring it to consume every byte (like swift-parsing's
-- `Parser.parse(_ input:)`, which implicitly appends `End()`). Returns `value, nil` on success or
-- `nil, errorMessage` on failure — the idiomatic Lua "ok-or-error" return shape.
parse_all = function<T>(p: Parser<T>, s: string): T, string
   local r = p:skip(end_of_input).run(s, 1)
   if r.ok then return r.value, nil end
   return nil, ("expected " .. r.label .. " at byte " .. tostring(r.pos))
end

-- Prints `v` through `p`. Returns `text, nil` on success or `nil, errorMessage` on failure.
print_all = function<T>(p: Parser<T>, v: T): string, string
   local pr = p:print(v)
   if pr.ok then return pr.text, nil end
   return nil, pr.err
end

-- ── Export ──────────────────────────────────────────────────────────────────────────────────────────
local M: Parse = {
   UNIT = UNIT,
   succeed = succeed,
   fail = fail,
   lit = lit,
   pat = pat,
   digits = digits,
   int_parser = int_parser,
   number_parser = number_parser,
   prefix_up_to = prefix_up_to,
   rest_of_input = rest_of_input,
   end_of_input = end_of_input,
   number_conv = number_conv,
   flag_conv = flag_conv,
   parser_as_conversion = parser_as_conversion,
   oneOf = oneOf,
   many = many,
   many1 = many1,
   seq2 = seq2,
   seq3 = seq3,
   seq4 = seq4,
   parse_all = parse_all,
   print_all = print_all,
}
__parse = M

_PARSE_TEST = { mk = mk }

return M
