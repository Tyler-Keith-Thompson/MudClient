//
//  RPCConnection.swift
//  MudClient
//
//  Second TLS connection to AlterAeon's dclient RPC channel (www.alteraeon.com:3103): the
//  version_info handshake, the 3-way RSA channel_auth (xirr_rpc.xirr_rpc_channel_auth), and
//  then live telemetry/music decode via RPCFramer. Mirrors Connection.swift's NIO/TLS setup,
//  but speaks the two-line-frame RPC block encoding instead of dclient's line-oriented text —
//  so it gets its own minimal inbound handler rather than reusing Connection's text pipeline.
//

import Foundation
import NIO
import NIOSSL
import Security
import SwiftProtobuf
import DependencyInjection

final class RPCConnection: @unchecked Sendable {
    static let host = "www.alteraeon.com"
    static let port = 3103
    static let clientVersion = "1.105-g64-rc2"
    /// Unknown on the wire — dclient sends this empty in every capture we have. Kept as a named
    /// constant so it's a one-line change once we observe what (if anything) the server expects.
    static let clientProtocol = ""
    /// The socket-layer text handshake the client sends FIRST (before any binary framing): a line
    /// `REQUEST <proto>\n`. The server replies `ACK <proto>` or `NACK <reason>`. `_noauth` is a variant
    /// that skips the RSA challenge; set `requestProtocol` to it to try the no-auth path.
    static let requestProtocol = "xirr_proto_rpc_1.0_noauth"

    private enum Phase { case awaitingAck, binary }

    private let lock = NSRecursiveLock()
    private var channel: (any Channel)?
    private var framer = RPCFramer()
    private var privateKey: SecKey?
    private var phase: Phase = .awaitingAck
    private var ackBuffer = Data()
    private var pendingUUID = ""

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return channel != nil }

    /// The install identity to present as version_info.client_uuid. Prefer the real AlterAeon client's
    /// uuid from its config (so we look like a known install); fall back to a stable DFLT token.
    static func defaultUUID() -> String {
        let cfg = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/AlterAeon/alter_aeon.cfg")
        if let text = try? String(contentsOf: cfg, encoding: .utf8),
           let range = text.range(of: "<uuid>([^<]+)</uuid>", options: .regularExpression) {
            let inner = text[range].dropFirst("<uuid>".count).dropLast("</uuid>".count)
            if !inner.isEmpty { return String(inner) }
        }
        return "DFLT000000000000000000000000"
    }

    func connect(uuid rawUUID: String) {
        let uuid = rawUUID.isEmpty ? Self.defaultUUID() : rawUUID
        disconnect()
        log("connecting to \(Self.host):\(Self.port)… (uuid=\(uuid))")

        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        let sslContext: NIOSSLContext
        do {
            sslContext = try NIOSSLContext(configuration: tlsConfig)
        } catch {
            log("TLS context error: \(error)")
            return
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                let handler = InboundHandler(
                    onData: { [weak self] data in self?.handleInbound(data) },
                    onActive: { [weak self] in
                        self?.log("TLS up")
                        self?.pendingUUID = uuid
                        self?.sendHandshakeRequest()
                    },
                    onInactive: { [weak self] reason in
                        self?.log("disconnected: \(reason)")
                        self?.lock.lock(); self?.channel = nil; self?.lock.unlock()
                    })
                do {
                    let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: Self.host)
                    return channel.pipeline.addHandler(sslHandler).flatMap {
                        channel.pipeline.addHandler(handler)
                    }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        bootstrap.connect(host: Self.host, port: Self.port).whenComplete { [weak self] result in
            switch result {
            case .success(let ch):
                self?.lock.lock(); self?.channel = ch; self?.lock.unlock()
            case .failure(let error):
                self?.log("connect failed: \(error)")
            }
        }
    }

    func disconnect() {
        lock.lock(); let ch = channel; channel = nil; lock.unlock()
        ch?.close(promise: nil)
        framer = RPCFramer()
        privateKey = nil
        phase = .awaitingAck
        ackBuffer = Data()
    }

    private func write(_ data: Data) {
        lock.lock(); let ch = channel; lock.unlock()
        guard let ch else { return }
        // DEBUG: dump outbound bytes so we can validate our framing against the server's expectation.
        let dump = data.prefix(120)
        let hex = dump.map { String(format: "%02x", $0) }.joined(separator: " ")
        log("TX \(data.count)B: \(hex)")
        ch.writeAndFlush(ByteBuffer(bytes: data), promise: nil)
    }

    private func log(_ message: String) {
        Container.terminalService().print("[rpc] \(message)")
    }

    /// Outbound user input / commands / login over the RPC. CONFIRMED from the binary's send_command()
    /// (0xec870 → serializer 0xee300): the user's line goes in `xirr_client_rpc.text_block { text }` with
    /// frameinfo.proto_name = the SHORT "text_block" (the client sends the short name outbound, even though
    /// the server sends the full "xirr_client_rpc.text_block" inbound). text_block is bidirectional — this
    /// carries login name, password, and every in-game command. A newline is appended (the server expects a
    /// line, same as telnet).
    func send(text: String) {
        guard phase == .binary else { log("send: channel not ready"); return }
        var msg = XirrClientRpc_text_block()
        msg.text = Data((text + "\n").utf8)
        guard let payload: Data = try? msg.serializedBytes() else { log("send: encode error"); return }
        // Outbound frame byte-matched to the client's tx_send_packet (0x15d480): FULL proto_name, short
        // rpc_service_name, f20=1 (EVENT). All three are required or the server drops the packet.
        var frameinfo = XirrRpc_xirr_proto_framer_frameinfo()
        frameinfo.protoName = XirrClientRpc_text_block.protoMessageName   // full "xirr_client_rpc.text_block"
        frameinfo.rpcServiceName = "text_block"                          // short form (required)
        frameinfo.f20 = 1                                                // EVENT/PUSH
        write(RPCFramer.encodeBlock(frameinfo: frameinfo, payload: payload))
        log("send: '\(text)'")
    }

    // MARK: - Handshake

    /// Step 0: the text preamble. Sent RAW (no line framing) as `REQUEST <proto>\n`. The server's
    /// `ACK`/`NACK` reply is also raw text; only AFTER an ACK does the binary line/proto framing begin.
    private func sendHandshakeRequest() {
        let line = "REQUEST \(Self.requestProtocol)\n"
        write(Data(line.utf8))
        log("handshake: sent 'REQUEST \(Self.requestProtocol)'")
    }

    private func sendVersionInfo(uuid: String) {
        var info = XirrClientRpc_version_info()
        info.clientVersion = Self.clientVersion
        info.clientUuid = uuid
        info.clientProtocol = Self.clientProtocol
        guard let payload: Data = try? info.serializedBytes() else {
            log("version_info encode error")
            return
        }
        // Same framing rules as user input: full proto_name, short rpc_service_name "versioninfo", f20=1.
        var frameinfo = XirrRpc_xirr_proto_framer_frameinfo()
        frameinfo.protoName = XirrClientRpc_version_info.protoMessageName
        frameinfo.rpcServiceName = "versioninfo"
        frameinfo.f20 = 1
        write(RPCFramer.encodeBlock(frameinfo: frameinfo, payload: payload))
        log("version_info sent (version=\(Self.clientVersion) uuid=\(uuid))")
    }

    private func beginAuth() {
        guard let (privKey, pubKeyString) = Self.generateKeypair() else {
            log("AUTH FAILED: could not generate RSA keypair")
            return
        }
        privateKey = privKey
        let nonce = Self.randomNonce()

        var auth = XirrRpc_xirr_rpc_channel_auth()
        auth.f1 = 1   // CLIENT_NONCE
        auth.clientNonce = nonce
        auth.clientPublicKey = pubKeyString
        guard let payload: Data = try? auth.serializedBytes() else {
            log("auth CLIENT_NONCE encode error")
            return
        }
        write(RPCFramer.encodeBlock(protoName: XirrRpc_xirr_rpc_channel_auth.protoMessageName, serviceName: "auth", payload: payload))
        log("auth: client nonce sent")
    }

    private func handleInbound(_ data: Data) {
        // DEBUG: dump raw inbound bytes (pre-framing) so we can see the server's exact preamble/framing.
        let dump = data.prefix(160)
        let hex = dump.map { String(format: "%02x", $0) }.joined(separator: " ")
        let ascii = String(dump.map { (0x20...0x7e).contains($0) ? Character(UnicodeScalar($0)) : "." })
        log("raw \(data.count)B: \(hex)")
        log("raw ascii: \(ascii)")

        var payload = data
        if phase == .awaitingAck {
            // Accumulate the raw text reply until the first newline = the ACK/NACK line.
            ackBuffer.append(data)
            guard let nl = ackBuffer.firstIndex(of: 0x0a) else { return }   // wait for the full line
            let lineData = ackBuffer[ackBuffer.startIndex..<nl]
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let remainder = ackBuffer[ackBuffer.index(after: nl)...]        // bytes after the ACK line
            ackBuffer = Data()
            if line.uppercased().hasPrefix("ACK") {
                log("handshake: server \(line) — starting binary channel")
                phase = .binary
                sendVersionInfo(uuid: pendingUUID)
                if Self.requestProtocol.contains("noauth") {
                    log("noauth protocol — skipping RSA handshake")
                } else {
                    beginAuth()
                }
                payload = Data(remainder)          // feed any trailing binary bytes to the framer below
                if payload.isEmpty { return }
            } else {
                log("handshake: server rejected us: '\(line)'")
                disconnect()
                return
            }
        }

        let messages: [RPCMessage]
        do {
            messages = try framer.push(payload)
        } catch {
            log("decode error: \(error)")
            return
        }
        for message in messages { handle(message) }
    }

    private func handle(_ message: RPCMessage) {
        switch message {
        case .auth(let m):
            handleAuth(m)
        case .hpbar(let m):
            log("hpbar f1=\(m.f1) f2=\(m.f2) f3=\(m.f3) f4=\(m.f4) f5=\(m.f5) f6=\(m.f6)")
        case .enemyHP(let m):
            log("enemyHP name='\(m.enemyName)' hp=\(m.f2)")
        case .skyAndTime(let m):
            log("sky f1=\(m.f1) f2=\(m.f2) f3=\(m.f3) f4=\(m.f4) f5=\(m.f5) '\(m.printedTimeOfDayString)'")
        case .expToLevel(let m):
            log("expToLevel values=\(m.f1)")
        case .iconBar(let m):
            log("iconBar f1=\(m.f1) f2=\(m.f2) f3=\(m.f3) f4=\(m.f4) f5=\(m.f5) f6=\(m.f6)")
        case .roomTerrain(let m):
            log("roomTerrain f1=\(m.f1) f2=\(m.f2) f3=\(m.f3) f4=\(m.f4)")
        case .music(let m):
            log("music op=\(m.op) channel='\(m.channelName)' file='\(m.filename)'")
        case .popupWindow(let m):
            log("popupWindow name='\(m.name)' display='\(m.displayName)' cmd='\(m.command)'")
        case .buttonConfig(let m):
            log("buttonConfig f1=\(m.f1) display='\(m.displayString)' action='\(m.actionString)'")
        case .genericKV(let m):
            log("genericKV key='\(m.key)' value='\(m.kvalue)' f3=\(m.f3)")
        case .channelSend(let m):
            log("channelSend channel='\(m.channelName)' message='\(m.sentMessage)'")
        case .textBlock(let m):
            // The game's actual output. `text` is raw ANSI + Latin-1 bytes (its own \r\n embedded), so
            // decode byte→scalar (Latin-1, lossless — keeps ESC/high bytes). Mirror the telnet inbound path
            // (ConnectionManager): refresh the panel model, RECORD TO THE RAW LOG (so we can build parsers
            // for the tagged data that rides inside text_block), then render() verbatim.
            let text = String(m.text.map { Character(UnicodeScalar($0)) })
            Container.scriptInterpreter().engine.notifyUpdate()
            Container.sessionLog().logServer(text)
            Container.terminalService().render(text)
        case .audioPlayout(let m):
            log("audioPlayout file='\(m.shortClipFilename)'")
        case .keepalive(let m, let reqFrameinfo):
            // Answer the server's rpc/ping or it drops us (~15s). Reply is a keepalive_info transaction
            // RESPONSE: echo the request's f30 (transaction id), set frameinfo.f20 = 3, echo the type name.
            var respFrameinfo = XirrRpc_xirr_proto_framer_frameinfo()
            respFrameinfo.protoName = reqFrameinfo.protoName   // echo "xirr_server_rpc.keepalive_info"
            respFrameinfo.f20 = 3                              // RESPONSE
            respFrameinfo.f30 = reqFrameinfo.f30               // echo transaction id (correlation key)
            var pong = XirrServerRpc_keepalive_info()
            pong.f1 = m.f1
            if let payload: Data = try? pong.serializedBytes() {
                write(RPCFramer.encodeBlock(frameinfo: respFrameinfo, payload: payload))
                log("keepalive ping (txn \(reqFrameinfo.f30)) — ponged")
            }
        case .unknown(let protoName, let serviceName, let payload):
            log("unknown proto=\(protoName) service=\(serviceName) bytes=\(payload.count)")
        }
    }

    private func handleAuth(_ auth: XirrRpc_xirr_rpc_channel_auth) {
        switch auth.f1 {
        case 2:   // SERVER_NONCE
            log("auth: server nonce received")
            guard let privateKey else {
                log("AUTH FAILED: no local private key (auth message out of order)")
                return
            }
            guard let signature = Self.sign(nonce: auth.serverNonce, with: privateKey) else {
                log("AUTH FAILED: could not sign server nonce")
                return
            }
            var reply = XirrRpc_xirr_rpc_channel_auth()
            reply.f1 = 3   // CLIENT_HASH
            reply.clientHash = signature
            guard let payload: Data = try? reply.serializedBytes() else {
                log("auth CLIENT_HASH encode error")
                return
            }
            write(RPCFramer.encodeBlock(protoName: XirrRpc_xirr_rpc_channel_auth.protoMessageName, serviceName: "auth", payload: payload))
            log("auth: client hash sent")
        case 4:   // SERVER_RESPONSE
            log("AUTH OK")
        case 5:   // FAIL
            log("AUTH FAILED: \(auth.serverFailString)")
        default:
            log("auth: unexpected state f1=\(auth.f1)")
        }
    }

    // MARK: - Crypto helpers

    static func generateKeypair() -> (SecKey, String)? {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            return nil
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return nil
        }
        return (privateKey, publicKeyString(der: der))
    }

    /// The DER PKCS#1 RSAPublicKey, base64-encoded, wrapped in dclient's wire prefix — the two
    /// label fields are the literal string "(null)" (verified against the decompile).
    static func publicKeyString(der: Data) -> String {
        "0:(null):(null):" + der.base64EncodedString()
    }

    static func randomNonce(length: Int = 16) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    /// PKCS#1 v1.5 / SHA-256 signature over the raw nonce bytes, base64-encoded (the wire format
    /// for `client_hash`/`server_hash`).
    static func sign(nonce: String, with privateKey: SecKey) -> String? {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(nonce.utf8) as CFData,
            &error
        ) as Data? else {
            return nil
        }
        return signature.base64EncodedString()
    }
}

extension RPCConnection {
    final class InboundHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let onData: (Data) -> Void
        private let onActive: () -> Void
        private let onInactive: (String) -> Void
        private var disconnectReason: String?

        init(onData: @escaping (Data) -> Void, onActive: @escaping () -> Void, onInactive: @escaping (String) -> Void) {
            self.onData = onData
            self.onActive = onActive
            self.onInactive = onInactive
        }

        func channelActive(context: ChannelHandlerContext) {
            onActive()
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = Self.unwrapInboundIn(data)
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                onData(Data(bytes))
            }
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            disconnectReason = error.localizedDescription
            context.close(promise: nil)
        }

        func channelInactive(context: ChannelHandlerContext) {
            onInactive(disconnectReason ?? "connection closed")
        }
    }
}

extension Container {
    static let rpcConnection = Factory(scope: .cached) { RPCConnection() }
}
