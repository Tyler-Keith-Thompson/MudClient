-- Specs for the local fine-tune's JSON action parsing (handle_reply's tool-call path). The combat
-- fine-tune answers with a JSON action, not `CMD:` text; extract_calls + from_tool_calls must turn
-- every shape it emits into a REAL game command, and drop anything unparseable rather than send garbage.

local extract_calls   = _AIP_TEST.extract_calls
local from_tool_calls = _AIP_TEST.from_tool_calls

-- Parse a raw model reply the whole way to the command string it should send (first action only).
local function cmd_of(reply)
  local calls = extract_calls(reply)
  if #calls == 0 then return nil end
  local actions = from_tool_calls(calls)
  return actions[1] and actions[1].cmd, calls
end

test("extracts the trained tool-call form (Qwen <tool_call> wrapper) into a real command", function()
  expect(cmd_of([[<tool_call>{"name":"command","arguments":{"text":"c shower"}}</tool_call>]])):eq("c shower")
end)

test("extracts a bare (untagged) tool-call object", function()
  expect(cmd_of([[{"name":"command","arguments":{"text":"c shower"}}]])):eq("c shower")
end)

test("maps the flattened {action,target} attack shorthand to `kill <target>`", function()
  expect(cmd_of([[{"action":"attack","target":"town guard"}]])):eq("kill town guard")
end)

test("maps the flattened cast shorthand to `cast '<spell>'` (target is the spell, no duplicate)", function()
  -- The real loaded model emits exactly this, pretty-printed with newlines.
  expect(cmd_of("{\n  \"action\": \"cast\",\n  \"target\": \"shower of sparks\"\n}")):eq("cast 'shower of sparks'")
end)

test("the malformed eval case {action:cast,target:shards} parses leniently to a valid-form command", function()
  -- Never garbage: `cast 'shards'` is a syntactically valid command (the MUD rejects the unknown spell).
  expect(cmd_of([[{"action":"cast","target":"shards"}]])):eq("cast 'shards'")
end)

test("a cast tool-call missing its spell is skipped, never sent as `cast ''`", function()
  local calls = extract_calls([[{"name":"cast","arguments":{"target":"guard"}}]])
  expect(#calls):eq(1)                       -- the call is recognized...
  local actions = from_tool_calls(calls)
  expect(#actions):eq(0)                     -- ...but build fails -> dropped, nothing sent
end)

test("an object with no recognizable action yields no calls (falls through to CMD: parsing)", function()
  expect(#extract_calls([[{"foo":"bar","baz":1}]])):eq(0)
  expect(#extract_calls("just some prose, no json")):eq(0)
end)

test("kill is normalized to attack; flattened move routes to a direction", function()
  expect(cmd_of([[{"action":"kill","target":"rat"}]])):eq("kill rat")
  expect(cmd_of([[{"action":"move","direction":"west"}]])):eq("west")
  expect(cmd_of([[{"action":"move","target":"east"}]])):eq("east")
end)
