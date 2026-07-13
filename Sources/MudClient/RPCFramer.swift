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
    case keepalive(XirrServerRpc_keepalive_info)
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
    private static let routes: [(fullName: String, serviceKey: String, decode: (Data) throws -> RPCMessage)] = [
        (DclientRpc_hpbar_data.protoMessageName, "hpbar", { .hpbar(try DclientRpc_hpbar_data(serializedBytes: $0)) }),
        (DclientRpc_enemy_hp_data.protoMessageName, "enemyhp", { .enemyHP(try DclientRpc_enemy_hp_data(serializedBytes: $0)) }),
        (DclientRpc_sky_and_time.protoMessageName, "skystate", { .skyAndTime(try DclientRpc_sky_and_time(serializedBytes: $0)) }),
        (DclientRpc_exp_to_level.protoMessageName, "xp2l", { .expToLevel(try DclientRpc_exp_to_level(serializedBytes: $0)) }),
        (DclientRpc_icon_bar_data.protoMessageName, "iconbar", { .iconBar(try DclientRpc_icon_bar_data(serializedBytes: $0)) }),
        (DclientRpc_room_terrain_metadata.protoMessageName, "room_terrain_metadata", { .roomTerrain(try DclientRpc_room_terrain_metadata(serializedBytes: $0)) }),
        (XirrSoundpackRpc_music_playout_data.protoMessageName, "music", { .music(try XirrSoundpackRpc_music_playout_data(serializedBytes: $0)) }),
        (DclientRpc_popup_window.protoMessageName, "popup_window_create", { .popupWindow(try DclientRpc_popup_window(serializedBytes: $0)) }),
        (DclientRpc_button_configuration.protoMessageName, "fkey", { .buttonConfig(try DclientRpc_button_configuration(serializedBytes: $0)) }),
        (XirrClientRpc_generic_kv_event.protoMessageName, "kvp", { .genericKV(try XirrClientRpc_generic_kv_event(serializedBytes: $0)) }),
        (XirrClientRpc_channel_send_data.protoMessageName, "channelsend", { .channelSend(try XirrClientRpc_channel_send_data(serializedBytes: $0)) }),
        (XirrClientRpc_text_block.protoMessageName, "text_block", { .textBlock(try XirrClientRpc_text_block(serializedBytes: $0)) }),
        (XirrClientRpc_audio_playout_data.protoMessageName, "audio_playout_data", { .audioPlayout(try XirrClientRpc_audio_playout_data(serializedBytes: $0)) }),
        (XirrServerRpc_keepalive_info.protoMessageName, "keepalive", { .keepalive(try XirrServerRpc_keepalive_info(serializedBytes: $0)) }),
        (XirrRpc_xirr_rpc_channel_auth.protoMessageName, "auth", { .auth(try XirrRpc_xirr_rpc_channel_auth(serializedBytes: $0)) }),
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
        return try route.decode(payload)
    }

    static func encodeBlock(protoName: String, serviceName: String, payload: Data) -> Data {
        var frameinfo = XirrRpc_xirr_proto_framer_frameinfo()
        frameinfo.protoName = protoName
        frameinfo.rpcServiceName = serviceName
        let frameinfoPayload: Data = (try? frameinfo.serializedBytes()) ?? Data()
        return LineFramer.encode(frameinfoPayload) + LineFramer.encode(payload)
    }
}
