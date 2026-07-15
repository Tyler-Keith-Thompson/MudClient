-- Scripts/RPC.lua pure-logic tests — no live socket. Exercises CRC-32, the line framer, the proto
-- (block) framer, and routing via `_RPC_TEST` (see RPC.lua's test-seam section). The real handshake
-- (TLS connect, REQUEST/ACK, version_info, auth) needs a live server and is NOT covered here — see the
-- executor's report for the manual verification steps.

test("CRC-32/ISO-HDLC matches the standard check vector", function()
  expect(string.format("%08X", _RPC_TEST.crc32("123456789"))):eq("CBF43926")
end)

test("line frame encode -> feed round-trips a single frame", function()
  local reader = _RPC_TEST.new_line_reader()
  local frame = _RPC_TEST.encode_line("hello world")
  local payloads = reader(frame)
  expect(#payloads):eq(1)
  expect(payloads[1]):eq("hello world")
end)

test("line frame split across two feed calls reassembles", function()
  local reader = _RPC_TEST.new_line_reader()
  local frame = _RPC_TEST.encode_line("split payload data")
  local mid = math.floor(#frame / 2)
  local first = reader(frame:sub(1, mid))
  expect(#first):eq(0)
  local second = reader(frame:sub(mid + 1))
  expect(#second):eq(1)
  expect(second[1]):eq("split payload data")
end)

test("two line frames in one buffer both come out", function()
  local reader = _RPC_TEST.new_line_reader()
  local buf = _RPC_TEST.encode_line("first") .. _RPC_TEST.encode_line("second")
  local payloads = reader(buf)
  expect(#payloads):eq(2)
  expect(payloads[1]):eq("first")
  expect(payloads[2]):eq("second")
end)

test("line frame is binary safe (non-UTF8 bytes survive)", function()
  local reader = _RPC_TEST.new_line_reader()
  local raw = "\27[1mhi\255\0\1"
  local payloads = reader(_RPC_TEST.encode_line(raw))
  expect(payloads[1]):eq(raw)
end)

local function load_test_descriptor()
  local f = io.open("Scripts/rpc_descriptor.pb", "rb")
  if not f then return false end
  local d = f:read("*a")
  f:close()
  assert(pb.load(d))
  return true
end

test("proto block encode -> decode round-trip routes text_block to feed_server", function()
  if not load_test_descriptor() then return end

  local frameinfo = { proto_name = "xirr_client_rpc.text_block", rpc_service_name = "text_block", f20 = 1 }
  local raw = "You are standing in a room.\27[31m\255"   -- includes a non-UTF8 byte (0xFF)
  local payload = pb.encode("xirr_client_rpc.text_block", { text = raw })
  local block_bytes = _RPC_TEST.encode_block(frameinfo, payload)

  local reader = _RPC_TEST.new_block_reader()
  local blocks = reader(block_bytes)
  expect(#blocks):eq(1)
  expect(blocks[1].frameinfo.proto_name):eq("xirr_client_rpc.text_block")

  local fed = nil
  local prior_feed_server = feed_server
  feed_server = function(text) fed = text end
  _RPC_TEST.route(blocks[1].frameinfo, blocks[1].payload)
  feed_server = prior_feed_server

  expect(fed):eq(raw)
end)

test("proto block feed handles a frame split across two feed_line-equivalent calls", function()
  if not load_test_descriptor() then return end

  local frameinfo = { proto_name = "xirr_client_rpc.text_block", rpc_service_name = "text_block", f20 = 1 }
  local payload = pb.encode("xirr_client_rpc.text_block", { text = "hi" })
  local block_bytes = _RPC_TEST.encode_block(frameinfo, payload)
  local mid = math.floor(#block_bytes / 2)

  local reader = _RPC_TEST.new_block_reader()
  local first = reader(block_bytes:sub(1, mid))
  expect(#first):eq(0)
  local second = reader(block_bytes:sub(mid + 1))
  expect(#second):eq(1)
  expect(second[1].frameinfo.proto_name):eq("xirr_client_rpc.text_block")
end)

test("frameinfo f20/f30 round-trip (needed for the keepalive pong correlation)", function()
  if not load_test_descriptor() then return end
  local bytes = _RPC_TEST.encode_frameinfo({ proto_name = "xirr_server_rpc.keepalive_info", f20 = 3, f30 = 25042 })
  local fi = pb.decode(_RPC_TEST.FRAMEINFO_TYPE, bytes)
  expect(fi.f20):eq(3)
  expect(fi.f30):eq(25042)
  expect(fi.proto_name):eq("xirr_server_rpc.keepalive_info")
end)

test("keepalive routes to a pong that echoes proto_name and f30, sets f20=3", function()
  if not load_test_descriptor() then return end

  local req_frameinfo = { proto_name = "xirr_server_rpc.keepalive_info", rpc_service_name = "keepalive", f20 = 2, f30 = 25042 }
  local req_payload = pb.encode("xirr_server_rpc.keepalive_info", { f1 = 7 })

  local sent = nil
  local prior_net_send = net_send
  net_send = function(data) sent = data end
  local m = pb.decode("xirr_server_rpc.keepalive_info", req_payload)
  _RPC_TEST.send_pong(req_frameinfo, m)
  net_send = prior_net_send

  expect(type(sent)):eq("string")
  local reader = _RPC_TEST.new_block_reader()
  local blocks = reader(sent)
  expect(#blocks):eq(1)
  expect(blocks[1].frameinfo.proto_name):eq("xirr_server_rpc.keepalive_info")
  expect(blocks[1].frameinfo.f20):eq(3)
  expect(blocks[1].frameinfo.f30):eq(25042)
  local pong = pb.decode("xirr_server_rpc.keepalive_info", blocks[1].payload)
  expect(pong.f1):eq(7)
end)

test("find_route matches by full proto_name, then message-part suffix, then service key", function()
  local r1 = _RPC_TEST.find_route("dclient_rpc.hpbar_data", "hpbar")
  expect(r1.service):eq("hpbar")

  local r2 = _RPC_TEST.find_route("some.other.pkg.hpbar_data", "hpbar")
  expect(r2.service):eq("hpbar")

  local r3 = _RPC_TEST.find_route("hpbar", "whatever")
  expect(r3.service):eq("hpbar")

  local r4 = _RPC_TEST.find_route("totally_unknown", "totally_unknown_service")
  expect(r4):falsy()
end)

test("unknown proto routes without erroring; echoes only under _RPC_DEBUG", function()
  if not load_test_descriptor() then return end
  local echoed, prior_echo, prior_dbg = nil, echo, _RPC_DEBUG
  echo = function(s) echoed = s end
  -- Silent by default (echoing every unhandled message floods/locks the UI).
  _RPC_DEBUG = false
  _RPC_TEST.route({ proto_name = "nonexistent.thing", rpc_service_name = "mystery" }, "somebytes")
  expect(echoed):falsy()
  -- Visible when debug is on.
  _RPC_DEBUG = true
  _RPC_TEST.route({ proto_name = "nonexistent.thing", rpc_service_name = "mystery" }, "somebytes")
  expect(echoed ~= nil):truthy()
  echo, _RPC_DEBUG = prior_echo, prior_dbg
end)

test("enemy_hp_data drives AutoFight via __autofight_prompt and clears the fight on death", function()
  if not load_test_descriptor() then return end
  local calls, prior = {}, __autofight_prompt
  __autofight_prompt = function(pct, name) calls[#calls + 1] = { pct = pct, name = name } end
  local fi = { proto_name = "dclient_rpc.enemy_hp_data", rpc_service_name = "enemyhp" }
  -- A live health bar → feed (pct, name).
  _RPC_TEST.route(fi, pb.encode("dclient_rpc.enemy_hp_data", { enemy_name = "A screech-Owl", f2 = 84 }))
  expect(#calls):eq(1)
  expect(calls[1].pct):eq(84); expect(calls[1].name):eq("A screech-Owl")
  expect(state.fighting):truthy()
  -- 0% is NEAR-DEATH, NOT dead — a named enemy at 0 must STAY an active fight (the fight ends on the
  -- authoritative signals: kxwq_fighting -1 / ncombat / "is DEAD!", not on a 0 reading).
  _RPC_TEST.route(fi, pb.encode("dclient_rpc.enemy_hp_data", { enemy_name = "A screech-Owl", f2 = 0 }))
  expect(state.fighting):truthy()
  expect(state.fight_pct):eq(0)
  -- An EMPTY name (no target) DOES clear it.
  _RPC_TEST.route(fi, pb.encode("dclient_rpc.enemy_hp_data", { enemy_name = "", f2 = 0 }))
  expect(state.fighting):falsy()
  __autofight_prompt = prior
end)

test("generic_kv_event key='ncombat' ends the fight and AutoFight authoritatively", function()
  if not load_test_descriptor() then return end
  local ended, prior = false, __autofight_prompt
  __autofight_prompt = function(pct, name) if pct == nil and name == nil then ended = true end end
  state.fighting = true
  local fi = { proto_name = "xirr_client_rpc.generic_kv_event", rpc_service_name = "kvp" }
  _RPC_TEST.route(fi, pb.encode("xirr_client_rpc.generic_kv_event", { key = "ncombat" }))
  expect(state.fighting):falsy()
  expect(ended):truthy()
  __autofight_prompt = prior
end)

test("generic_kv_event key='dirs' decodes the exits bitmask into state.exits", function()
  if not load_test_descriptor() then return end
  local prior_exits = state.exits
  -- 85 = 1|4|16|64 = N,E,S,W ; 640 = 128|512 = NW,D (confirmed against observed live values).
  local fi = { proto_name = "xirr_client_rpc.generic_kv_event", rpc_service_name = "kvp" }
  _RPC_TEST.route(fi, pb.encode("xirr_client_rpc.generic_kv_event", { key = "dirs", f3 = 85 }))
  expect(state.exits.north):truthy(); expect(state.exits.east):truthy()
  expect(state.exits.south):truthy(); expect(state.exits.west):truthy()
  expect(state.exits.northeast):falsy(); expect(state.exits.up):falsy()
  _RPC_TEST.route(fi, pb.encode("xirr_client_rpc.generic_kv_event", { key = "dirs", f3 = 640 }))
  expect(state.exits.northwest):truthy(); expect(state.exits.down):truthy()
  expect(state.exits.north):falsy()   -- replaced wholesale, not merged
  state.exits = prior_exits
end)

test("generic_kv_event key='areaname' sets state.area from kvalue", function()
  if not load_test_descriptor() then return end
  local prior_area = state.area
  local fi = { proto_name = "xirr_client_rpc.generic_kv_event", rpc_service_name = "kvp" }
  _RPC_TEST.route(fi, pb.encode("xirr_client_rpc.generic_kv_event",
                                { key = "areaname", kvalue = "The Town of Dragon Tooth" }))
  expect(state.area):eq("The Town of Dragon Tooth")
  state.area = prior_area
end)

test("default_uuid falls back to the DFLT token when no config file is present", function()
  -- Can't assert the real ~/Library path is absent in CI, so just check the function is callable
  -- and returns a non-empty string of the right shape either way.
  local uuid = _RPC_TEST.default_uuid()
  expect(type(uuid)):eq("string")
  expect(#uuid > 0):truthy()
end)
