//
//  NetConnection.swift
//  MudClient
//
//  A GENERIC outbound binary socket — no game/protocol/framing knowledge. Just "open a socket to
//  host:port (optionally TLS), move raw bytes". Lua owns everything above the wire (framing,
//  handshake, protobuf) via `net_connect`/`net_send`/`net_disconnect`/`net_is_connected` and the
//  `on_net`/`on_net_connect`/`on_net_disconnect` hooks (see LuaScriptEngine).
//

import Foundation
import NIO
import NIOSSL
import DependencyInjection

final class NetConnection: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var channel: (any Channel)?
    /// All three Lua-facing notifications (connect/data/disconnect) are dispatched onto this single
    /// serial queue, in the order NIO delivers them, so the NIO thread never blocks inside `notifyNet`
    /// (which takes a process-wide lock shared with slow Lua ops) — it just enqueues and keeps draining
    /// the socket. Serial + async preserves connect-before-data-before-disconnect ordering.
    private let inboundQueue = DispatchQueue(label: "net.inbound")

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return channel != nil }

    /// Open (or re-open) a connection to `host:port`. Any existing connection is torn down first.
    /// Inbound bytes, connect, and disconnect are surfaced to the script via
    /// `Container.scriptInterpreter().engine` (`on_net`/`on_net_connect`/`on_net_disconnect`).
    func connect(host: String, port: Int, tls: Bool) {
        disconnect()
        log("connecting to \(host):\(port)…\(tls ? " (tls)" : "")")

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                let handler = InboundHandler(
                    onData: { [weak self] data in self?.handleInbound(data) },
                    onActive: { [weak self] in
                        self?.log("connected")
                        self?.inboundQueue.async {
                            Container.scriptInterpreter().engine.notifyNetConnect()
                        }
                    },
                    onInactive: { [weak self] reason in
                        self?.log("disconnected: \(reason)")
                        self?.lock.lock(); self?.channel = nil; self?.lock.unlock()
                        self?.inboundQueue.async {
                            Container.scriptInterpreter().engine.notifyNetDisconnect(reason: reason)
                        }
                    })
                guard tls else {
                    return channel.pipeline.addHandler(handler)
                }
                var tlsConfig = TLSConfiguration.makeClientConfiguration()
                tlsConfig.certificateVerification = .none
                do {
                    let sslContext = try NIOSSLContext(configuration: tlsConfig)
                    let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    return channel.pipeline.addHandler(sslHandler).flatMap {
                        channel.pipeline.addHandler(handler)
                    }
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        bootstrap.connect(host: host, port: port).whenComplete { [weak self] result in
            switch result {
            case .success(let ch):
                self?.lock.lock(); self?.channel = ch; self?.lock.unlock()
            case .failure(let error):
                self?.log("connect failed: \(error)")
            }
        }
    }

    /// Raw, binary-safe write — no newline appended, no command splitting.
    func send(_ data: Data) {
        lock.lock(); let ch = channel; lock.unlock()
        guard let ch else { return }
        ch.writeAndFlush(ByteBuffer(bytes: data), promise: nil)
    }

    func disconnect() {
        lock.lock()
        let ch = channel
        channel = nil
        lock.unlock()
        ch?.close(promise: nil)
    }

    private func handleInbound(_ data: Data) {
        inboundQueue.async {
            Container.scriptInterpreter().engine.notifyNet(data)
        }
    }

    private func log(_ message: String) {
        Container.terminalService().print("[net] \(message)")
    }
}

extension NetConnection {
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
    static let netConnection = Factory(scope: .cached) { NetConnection() }
}
