-- Machine.tl — tiny fluent phase-based state-machine combinator, published as `__machine` (mirrors
-- __route/__rx/__promise/__persist), for the "state-machine" script shape in Scripts/CLAUDE.md: a chain
-- that IS the driving control, not a legend describing it elsewhere.
--
--   local machine, loop_if = __machine, __machine.loop_if
--   local run = machine("gather")
--     :phase("gather", start_gather)                        -- runs start_gather; default next = "forge"
--     :phase("forge",  plan_and_cast)                        -- default next = "stow"
--     :phase("stow",   begin_stow, loop_if(made_progress))   -- back to "gather" if pred(), else DONE
--     :start()
--
-- Each phase's handler is called with an `advance` callback: the handler runs some async game
-- interaction (sends, waits on triggers) and, whenever IT decides the phase is finished, calls
-- `advance()` to move on. `advance()` (no arg) uses that phase's TRANSITION (3rd arg to :phase(), if
-- given) or else the DEFAULT NEXT (the next phase declared, in :phase() call order — "gather" then
-- "forge" then "stow" above); `advance("other")` jumps straight to a named phase, overriding both;
-- `advance(machine.DONE)` (or a transition/override that resolves to it) finishes the run. An override
-- may also be a `function(): string` computed at the moment advance() is called, for a decision that
-- can't be precomputed as a static per-phase transition.
--
-- `loop_if(pred)` / `goto_phase(name)` are the two transition helpers, hung off `__machine` rather than
-- bare globals (matching route/any living under `__route`, not as bare globals, in Route.tl):
-- `loop_if(pred)` goes back to the machine's START phase (the name passed to `machine(...)`) when
-- `pred()` is true, else `machine.DONE`; `goto_phase(name)` is an unconditional jump to a named phase
-- (Lua/Teal reserve the bare word `goto` for the `goto` statement, so the helper can't be spelled that
-- literally).
--
-- STALE-SIGNAL SAFE: entering a phase mints a token; `advance()` from anything but the CURRENT phase's
-- callback (a superseded/late trigger firing after the machine already moved on, or after `:cancel()`)
-- is silently ignored — the same "op was replaced out from under a stale callback" guard AlterAeon's
-- promise ops (sf_op/eq_op/…) hand-roll per script; here it's built in once.
--
-- Pure Lua, no host dependency beyond an optional `echo` for a bad phase name. Hot-reloadable: a machine
-- is just a plain table with no registered rules/timers of its own (the game script that builds one owns
-- all of ITS triggers/timers, which the normal reload teardown already clears), so nothing here needs
-- special reload handling. Exercised indirectly via soulforge_spec.lua (Soulforge.tl's phase machine).

global _MACHINE_TEST: {string:any}

-- Named aliases for the phase-handler shapes (a bare inline `function(function(? any))` return/param
-- type nests two function types and Teal's parser can swallow the outer one's return — the same trap
-- CLAUDE.md's "nested-function-type return swallow" note warns about elsewhere in this codebase; naming
-- the pieces sidesteps it).
local type Advance    = function(? any)             -- ? string | machine.DONE | function(): string
local type PhaseFn     = function(Advance)
local type Transition  = function(MachineT): string  -- MachineT forward-declared below

local record MPhase
   name:       string
   handler:    PhaseFn
   transition: Transition
end

local record MachineT
   phase:   function(MachineT, string, PhaseFn, ? Transition): MachineT
   start:   function(MachineT, ? function()): MachineT
   cancel:  function(MachineT)
   current: function(MachineT): string
   active:  function(MachineT): boolean
   -- structural (not part of the fluent surface) — mirrors Promise.tl's Prom pattern of one flat record
   _phases:  {MPhase}
   _index:   {string:integer}
   _start:   string
   _cur:     integer
   _token:   integer
   _stopped: boolean
   _done_cb: function()
end

-- The "finished" sentinel: a plain string is enough (never a real phase name — no phase name can equal
-- it because __-double-underscore names aren't ones a game script would pick).
local DONE = "__machine_done__"

-- default_next(m, i) -> the phase declared right after index i, or DONE if i is the last declared.
local function default_next(m: MachineT, i: integer): string
   local nxt = m._phases[i + 1]
   return nxt and nxt.name or DONE
end

-- Resolve what `advance(explicit)` should go to: an explicit string wins outright; an explicit
-- `function(): string` is called for its answer; with nothing explicit, the phase's own transition (if
-- any) decides, else the default (next-declared) phase.
local function resolve_next(m: MachineT, i: integer, explicit: any): string
   if explicit ~= nil then
      if type(explicit) == "function" then return (explicit as function(): string)() end
      return explicit as string
   end
   local ph = m._phases[i]
   if ph.transition then return ph.transition(m) end
   return default_next(m, i)
end

-- Enter phase i: mint a fresh token (invalidating any advance() still outstanding from a superseded
-- phase) and run its handler, handing it an advance() closed over THIS token/index.
local function enter(m: MachineT, i: integer)
   m._cur = i
   m._token = (m._token or 0) + 1
   local token = m._token
   local ph = m._phases[i]
   local function advance(explicit?: any)
      if m._stopped or token ~= m._token then return end   -- stale/cancelled → ignore
      local nxt = resolve_next(m, i, explicit)
      if nxt == DONE then
         m._cur = nil
         if m._done_cb then m._done_cb() end
         return
      end
      local j = m._index[nxt]
      if not j then
         if echo then echo("[machine] unknown phase '" .. tostring(nxt) .. "' — stopping.") end
         return
      end
      enter(m, j)
   end
   ph.handler(advance)
end

local function new(start_name: string): MachineT
   local m: MachineT
   m = {
      _phases = {}, _index = {}, _start = start_name, _token = 0, _stopped = false,
      phase = function(self: MachineT, name: string, handler: PhaseFn, transition?: Transition): MachineT
         self._phases[#self._phases + 1] = { name = name, handler = handler, transition = transition }
         self._index[name] = #self._phases
         return self
      end,
      start = function(self: MachineT, done_cb?: function()): MachineT
         self._done_cb, self._stopped = done_cb, false
         local i = self._index[self._start]
         if not i then
            if echo then echo("[machine] unknown start phase '" .. tostring(self._start) .. "'.") end
            return self
         end
         enter(self, i)
         return self
      end,
      -- Stop the machine: any advance() still outstanding from the current phase becomes a no-op (the
      -- token bump is redundant with _stopped but keeps `current()`/a stray late enter() consistent).
      cancel = function(self: MachineT) self._stopped = true; self._token = (self._token or 0) + 1 end,
      current = function(self: MachineT): string
         local ph = self._cur and self._phases[self._cur]
         return ph and ph.name or nil
      end,
      active = function(self: MachineT): boolean return not self._stopped and self._cur ~= nil end,
   }
   return m
end

-- loop_if(pred) -> a Transition that returns to the machine's START phase when pred() is true, else
-- machine.DONE. The natural "keep cycling while there's still work" shape (see Soulforge's stow phase).
local function loop_if(pred: function(): boolean): Transition
   return function(m: MachineT): string return pred() and m._start or DONE end
end

-- goto_phase(name) -> a Transition that unconditionally jumps to `name` (named _phase, not `goto`,
-- because `goto` is a Lua/Teal keyword — see the file-top note).
local function goto_phase(name: string): Transition
   return function(_: MachineT): string return name end
end

-- The callable module surface, published as `__machine` (declared in foundation.d.tl, mirroring how
-- __promise/__persist/__rx are declared there and only ASSIGNED here): `__machine("start_phase")` builds
-- a fresh MachineT (a consumer typically aliases `local machine = __machine`, so the pseudocode above
-- reads as `machine("gather")`); `.DONE` is the finish sentinel; `.loop_if`/`.goto_phase` are the
-- transition helpers.
__machine = setmetatable({ DONE = DONE, loop_if = loop_if, goto_phase = goto_phase } as MachineModule,
   { __call = function(_: MachineModule, start_name: string): MachineT return new(start_name) end } as metatable<MachineModule>)

_MACHINE_TEST = { new = new, DONE = DONE, resolve_next = resolve_next, default_next = default_next }
