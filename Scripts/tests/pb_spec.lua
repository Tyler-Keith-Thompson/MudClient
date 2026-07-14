-- lua-protobuf (starwing/lua-protobuf 0.5.2, vendored Sources/CLua/pb.c) smoke tests: the harness
-- registers `pb` the same way the real host does (luaL_requiref in Lua.swift / tools/luatest/main.c),
-- so these prove pb is usable from Lua at all, and that it round-trips the RPC message shapes the
-- AlterAeon protocol refactor needs (plain ints and raw ANSI/Latin-1 bytes).

test("pb module is registered", function()
  expect(type(pb)):eq("table")
  expect(type(pb.encode)):eq("function")
  expect(type(pb.decode)):eq("function")
end)

-- A tiny inline schema (NOT the real descriptor) proves encode/decode round-trips without depending
-- on any file on disk — this always runs, regardless of whether Scripts/rpc_descriptor.pb is readable
-- from the current working directory.
test("pb encode/decode round-trips scalar ints", function()
  -- FileDescriptorSet for: syntax="proto2"; package dclient_rpc; message hpbar_data { optional
  -- int32 f1 = 1; optional int32 f2 = 2; } (compiled with protoc, embedded as raw bytes below —
  -- this is a MINIMAL standalone schema, not the real Scripts/rpc_descriptor.pb).
  assert(pb.load(
    "\10\72\10\11\109\105\110\105\49\46\112\114\111\116\111\18\11\100\99\108\105\101\110\116\95\114\112\99\34\44\10\10\104\112\98\97\114\95\100\97\116\97\18\14\10\2\102\49\24\1\32\1\40\5\82\2\102\49\18\14\10\2\102\50\24\2\32\1\40\5\82\2\102\50"
  ))
  local bytes = pb.encode("dclient_rpc.hpbar_data", { f1 = 100, f2 = 200 })
  expect(type(bytes)):eq("string")
  local t = pb.decode("dclient_rpc.hpbar_data", bytes)
  expect(t.f1):eq(100)
  expect(t.f2):eq(200)
end)

test("pb encode/decode round-trips raw bytes (ANSI/Latin-1 safe)", function()
  -- FileDescriptorSet for: syntax="proto2"; package xirr_client_rpc; message text_block { optional
  -- bytes text = 1; } — same minimal-standalone-schema approach as the scalar-int case above.
  assert(pb.load(
    "\10\64\10\11\109\105\110\105\50\46\112\114\111\116\111\18\15\120\105\114\114\95\99\108\105\101\110\116\95\114\112\99\34\32\10\10\116\101\120\116\95\98\108\111\99\107\18\18\10\4\116\101\120\116\24\1\32\1\40\12\82\4\116\101\120\116"
  ))
  local raw = "\27[1mhi\255"
  local bytes = pb.encode("xirr_client_rpc.text_block", { text = raw })
  local t = pb.decode("xirr_client_rpc.text_block", bytes)
  expect(t.text):eq(raw)
end)

-- The real checked-in descriptor (Scripts/rpc_descriptor.pb, regenerated via `just
-- regen-rpc-descriptor`) is only readable when the CWD is the repo root — true for run.sh and the
-- in-app `#test`, but the Bazel test's runfiles-root CWD also happens to mirror the repo layout (see
-- Scripts/BUILD.bazel's rpc_descriptor.pb data dep). Gate on readability so a CWD that can't see it
-- skips gracefully rather than failing the whole suite.
test("real rpc_descriptor.pb loads and round-trips hpbar_data", function()
  local f = io.open("Scripts/rpc_descriptor.pb", "rb")
  if not f then return end -- descriptor not reachable from this CWD; covered by the inline-schema cases above
  local d = f:read("*a")
  f:close()
  assert(pb.load(d))
  local bytes = pb.encode("dclient_rpc.hpbar_data", { f1 = 100, f2 = 200 })
  local t = pb.decode("dclient_rpc.hpbar_data", bytes)
  expect(t.f1):eq(100)
  expect(t.f2):eq(200)
end)
