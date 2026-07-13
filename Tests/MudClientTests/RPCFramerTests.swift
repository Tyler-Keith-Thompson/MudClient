import Foundation
import Testing

@testable import MudClient

private func block(protoName: String, serviceName: String = "", payload: Data) -> Data {
  RPCFramer.encodeBlock(protoName: protoName, serviceName: serviceName, payload: payload)
}

@Test func rpcFramerRoutesHpbarByFullProtoName() throws {
  var hpbar = DclientRpc_hpbar_data()
  hpbar.f1 = 42
  hpbar.f2 = 100
  let payload: Data = try hpbar.serializedBytes()
  let frame = block(protoName: "dclient_rpc.hpbar_data", payload: payload)

  var framer = RPCFramer()
  let messages = try framer.push(frame)

  #expect(messages == [.hpbar(hpbar)])
}

@Test func rpcFramerRoutesHpbarByShortServiceKey() throws {
  var hpbar = DclientRpc_hpbar_data()
  hpbar.f1 = 7
  hpbar.f2 = 10
  let payload: Data = try hpbar.serializedBytes()
  // Defensive matching: protoName IS the short key here.
  let frame = block(protoName: "hpbar", payload: payload)

  var framer = RPCFramer()
  let messages = try framer.push(frame)

  #expect(messages == [.hpbar(hpbar)])
}

@Test func rpcFramerRoundTripsMusicPlayoutData() throws {
  var music = XirrSoundpackRpc_music_playout_data()
  music.channelName = "ambient"
  music.op = 5
  music.filename = "forest_loop.ogg"
  let payload: Data = try music.serializedBytes()
  let frame = block(protoName: "xirr_soundpack_rpc.music_playout_data", payload: payload)

  var framer = RPCFramer()
  let messages = try framer.push(frame)

  guard case .music(let decoded) = messages.first else {
    Issue.record("expected .music, got \(String(describing: messages.first))")
    return
  }
  #expect(decoded.channelName == "ambient")
  #expect(decoded.op == 5)
  #expect(decoded.filename == "forest_loop.ogg")
}

@Test func rpcFramerDecodesBlockSplitMidProtoFrameAndMidDataFrame() throws {
  var hpbar = DclientRpc_hpbar_data()
  hpbar.f1 = 1
  hpbar.f2 = 2
  let payload: Data = try hpbar.serializedBytes()
  let full = block(protoName: "dclient_rpc.hpbar_data", payload: payload)

  var framer = RPCFramer()
  var messages: [RPCMessage] = []
  // Split the whole block byte-by-byte, crossing both the proto-frame and data-frame boundaries.
  for byte in full {
    messages += try framer.push([byte])
  }

  #expect(messages == [.hpbar(hpbar)])
}

@Test func rpcFramerDecodesTwoBlocksInOnePush() throws {
  var hpbar = DclientRpc_hpbar_data()
  hpbar.f1 = 1
  hpbar.f2 = 2
  let hpbarPayload: Data = try hpbar.serializedBytes()
  let firstBlock = block(protoName: "dclient_rpc.hpbar_data", payload: hpbarPayload)

  var music = XirrSoundpackRpc_music_playout_data()
  music.channelName = "combat"
  let musicPayload: Data = try music.serializedBytes()
  let secondBlock = block(protoName: "xirr_soundpack_rpc.music_playout_data", payload: musicPayload)

  var framer = RPCFramer()
  let messages = try framer.push(firstBlock + secondBlock)

  #expect(messages == [.hpbar(hpbar), .music(music)])
}

@Test func rpcFramerRoutesUnknownProtoNameWithoutThrowing() throws {
  let payload = Data("mystery payload".utf8)
  let frame = block(protoName: "not_a_real_rpc.mystery_thing", serviceName: "mystery", payload: payload)

  var framer = RPCFramer()
  let messages = try framer.push(frame)

  #expect(messages == [.unknown(protoName: "not_a_real_rpc.mystery_thing", serviceName: "mystery", payload: payload)])
}

@Test func rpcFramerRoutesAuthMessage() throws {
  var auth = XirrRpc_xirr_rpc_channel_auth()
  auth.clientNonce = "nonce123"
  auth.clientHash = "hash456"
  let payload: Data = try auth.serializedBytes()
  let frame = block(protoName: "xirr_rpc.xirr_rpc_channel_auth", payload: payload)

  var framer = RPCFramer()
  let messages = try framer.push(frame)

  #expect(messages == [.auth(auth)])
}
