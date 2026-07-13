//
//  RPCFramer.swift
//  MudClient
//
//  The dclient 1.105 RPC block codec, layered on LineFramer: a logical RPC block is two
//  consecutive line-frames — a proto_framer_frameinfo frame (routing key) followed by a
//  data frame (the payload it routes to).
//

import Foundation
import SwiftProtobuf

enum RPCMessage: Equatable {
    case hpbar(DclientRpc_hpbar_data)
    case enemyHP(DclientRpc_enemy_hp_data)
    case skyAndTime(DclientRpc_sky_and_time)
    case expToLevel(DclientRpc_exp_to_level)
    case iconBar(DclientRpc_icon_bar_data)
    case roomTerrain(DclientRpc_room_terrain_metadata)
    case music(XirrSoundpackRpc_music_playout_data)
    case popupWindow(DclientRpc_popup_window)
    case buttonConfig(DclientRpc_button_configuration)
    case genericKV(XirrClientRpc_generic_kv_event)
    case channelSend(XirrClientRpc_channel_send_data)
    case textBlock(XirrClientRpc_text_block)
    case audioPlayout(XirrClientRpc_audio_playout_data)
    // keepalive carries its frameinfo too: the pong must echo the request's transaction id (frameinfo.f30)
    // and set f20=3 (RESPONSE) — correlation is by f30 (see AUTH_WIRE.md keepalive section).
    case keepalive(XirrServerRpc_keepalive_info, frameinfo: XirrRpc_xirr_proto_framer_frameinfo)
    case auth(XirrRpc_xirr_rpc_channel_auth)
    case unknown(protoName: String, serviceName: String, payload: Data)
}

struct RPCFramer: Sendable {
    private enum State {
        case expectingProto
        case expectingData(XirrRpc_xirr_proto_framer_frameinfo)
    }

    // Maps a routing key (either the full dotted proto name or the short rpc_service_name) to the
    // decode+wrap step for that message type. Tried in order: exact protoName match, then suffix
    // match on the message part of protoName (after the last "."), then rpcServiceName match.
    private typealias Decoder = (Data, XirrRpc_xirr_proto_framer_frameinfo) throws -> RPCMessage
    private static let routes: [(fullName: String, serviceKey: String, decode: Decoder)] = [
        (DclientRpc_hpbar_data.protoMessageName, "hpbar", { d, _ in .hpbar(try DclientRpc_hpbar_data(serializedBytes: d)) }),
        (DclientRpc_enemy_hp_data.protoMessageName, "enemyhp", { d, _ in .enemyHP(try DclientRpc_enemy_hp_data(serializedBytes: d)) }),
        (DclientRpc_sky_and_time.protoMessageName, "skystate", { d, _ in .skyAndTime(try DclientRpc_sky_and_time(serializedBytes: d)) }),
        (DclientRpc_exp_to_level.protoMessageName, "xp2l", { d, _ in .expToLevel(try DclientRpc_exp_to_level(serializedBytes: d)) }),
        (DclientRpc_icon_bar_data.protoMessageName, "iconbar", { d, _ in .iconBar(try DclientRpc_icon_bar_data(serializedBytes: d)) }),
        (DclientRpc_room_terrain_metadata.protoMessageName, "room_terrain_metadata", { d, _ in .roomTerrain(try DclientRpc_room_terrain_metadata(serializedBytes: d)) }),
        (XirrSoundpackRpc_music_playout_data.protoMessageName, "music", { d, _ in .music(try XirrSoundpackRpc_music_playout_data(serializedBytes: d)) }),
        (DclientRpc_popup_window.protoMessageName, "popup_window_create", { d, _ in .popupWindow(try DclientRpc_popup_window(serializedBytes: d)) }),
        (DclientRpc_button_configuration.protoMessageName, "fkey", { d, _ in .buttonConfig(try DclientRpc_button_configuration(serializedBytes: d)) }),
        (XirrClientRpc_generic_kv_event.protoMessageName, "kvp", { d, _ in .genericKV(try XirrClientRpc_generic_kv_event(serializedBytes: d)) }),
        (XirrClientRpc_channel_send_data.protoMessageName, "channelsend", { d, _ in .channelSend(try XirrClientRpc_channel_send_data(serializedBytes: d)) }),
        (XirrClientRpc_text_block.protoMessageName, "text_block", { d, _ in .textBlock(try XirrClientRpc_text_block(serializedBytes: d)) }),
        (XirrClientRpc_audio_playout_data.protoMessageName, "audio_playout_data", { d, _ in .audioPlayout(try XirrClientRpc_audio_playout_data(serializedBytes: d)) }),
        (XirrServerRpc_keepalive_info.protoMessageName, "keepalive", { d, fi in .keepalive(try XirrServerRpc_keepalive_info(serializedBytes: d), frameinfo: fi) }),
        (XirrRpc_xirr_rpc_channel_auth.protoMessageName, "auth", { d, _ in .auth(try XirrRpc_xirr_rpc_channel_auth(serializedBytes: d)) }),
    ]

    private var lineFramer = LineFramer()
    private var state: State = .expectingProto

    mutating func push(_ bytes: some Sequence<UInt8>) throws -> [RPCMessage] {
        var messages: [RPCMessage] = []
        for payload in try lineFramer.push(bytes) {
            switch state {
            case .expectingProto:
                let frameinfo = try XirrRpc_xirr_proto_framer_frameinfo(serializedBytes: payload)
                state = .expectingData(frameinfo)
            case .expectingData(let frameinfo):
                messages.append(try Self.decode(frameinfo: frameinfo, payload: payload))
                state = .expectingProto
            }
        }
        return messages
    }

    private static func decode(frameinfo: XirrRpc_xirr_proto_framer_frameinfo, payload: Data) throws -> RPCMessage {
        let protoName = frameinfo.protoName
        let serviceName = frameinfo.rpcServiceName
        let messagePart = protoName.split(separator: ".").last.map(String.init) ?? protoName

        let route = routes.first { $0.fullName == protoName }
            ?? routes.first { $0.fullName.split(separator: ".").last.map(String.init) == messagePart }
            ?? routes.first { $0.serviceKey == protoName }
            ?? routes.first { $0.serviceKey == serviceName }

        guard let route else {
            return .unknown(protoName: protoName, serviceName: serviceName, payload: payload)
        }
        return try route.decode(payload, frameinfo)
    }

    static func encodeBlock(protoName: String, serviceName: String, payload: Data) -> Data {
        var frameinfo = XirrRpc_xirr_proto_framer_frameinfo()
        frameinfo.protoName = protoName
        frameinfo.rpcServiceName = serviceName
        return encodeBlock(frameinfo: frameinfo, payload: payload)
    }

    /// Encode a block with a fully-specified frameinfo (needed for transaction responses like the
    /// keepalive pong, which set frameinfo.f20 = 3 (RESPONSE) and echo the request's f30 transaction id).
    static func encodeBlock(frameinfo: XirrRpc_xirr_proto_framer_frameinfo, payload: Data) -> Data {
        let frameinfoPayload: Data = (try? frameinfo.serializedBytes()) ?? Data()
        return LineFramer.encode(frameinfoPayload) + LineFramer.encode(payload)
    }
}
