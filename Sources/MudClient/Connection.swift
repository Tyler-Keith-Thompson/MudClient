//
//  Connection.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/11/24.
//

import Foundation
import NIO
import NIOSSL
import Parsing
import Afluent
import DependencyInjection

actor Connection: AsyncSequence {
    enum Error: Swift.Error {
        case notConnected
        case alreadyConnected
    }
    
    enum State {
        case notConnected
        case connected(channel: any Channel)
    }
    
    typealias Element = String
    
    let host: String
    let port: UInt16
    private nonisolated let (stream, continuation) = AsyncThrowingStream<Data, any Swift.Error>.makeStream()
    private var state: State = .notConnected
    /// Fired from the NIO handler when the channel goes active / inactive. Wired by the owner
    /// (``ConnectionManager``) to surface connect/disconnect to the Lua scripts. No-ops by default.
    private nonisolated let onChannelActive: @Sendable () -> Void
    private nonisolated let onChannelInactive: @Sendable (_ reason: String) -> Void

    init(host: String, port: UInt16,
         onChannelActive: @escaping @Sendable () -> Void = {},
         onChannelInactive: @escaping @Sendable (_ reason: String) -> Void = { _ in }) {
        self.host = host
        self.port = port
        self.onChannelActive = onChannelActive
        self.onChannelInactive = onChannelInactive
    }
    
    nonisolated func makeAsyncIterator() -> AnyAsyncSequence<String>.AsyncIterator {
        stream.captureRaw()
            .handleIACCommunication(writeToStream: send)
            .normalizeLineEndings()
            // Peel any script-owned in-band protocol (e.g. dclient's `;s..;e..;` framing) FIRST, so the
            // downstream line assembler sees clean text. dclient bytes interleaved mid-line otherwise
            // break line assembly / MSP's `!!SOUND` line detection (the directive leaks to the display).
            .filterServerStream()
            .assembleLines()
            .processMSP()
            .processServerOutputForScripts()
            .eraseToAnyAsyncSequence()
            .makeAsyncIterator()
    }
    
    func connect() async throws {
        guard case .notConnected = state else {
            throw Error.alreadyConnected
        }

        // AlterAeon's dclient port (3102) speaks TLS; the plain port (3002) only gives a
        // degraded dclient stream. Encryption is transparent to everything downstream of
        // TCPClientHandler in the pipeline.
        let useTLS = port == 3102
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none
        let sslContext = useTLS ? try NIOSSLContext(configuration: tlsConfig) : nil

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                let tcpHandler = TCPClientHandler(continuation: self.continuation,
                                                   onActive: self.onChannelActive,
                                                   onInactive: self.onChannelInactive)
                if let sslContext {
                    do {
                        let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: self.host)
                        return channel.pipeline.addHandler(sslHandler).flatMap {
                            channel.pipeline.addHandler(tcpHandler)
                        }
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                return channel.pipeline.addHandler(tcpHandler)
            }

        let clientChannel = try await bootstrap.connect(host: host, port: Int(port))
            .get()

        self.state = .connected(channel: clientChannel)
    }

    /// Whether the socket is currently connected.
    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Close the channel (if any) and mark the connection down. The stream finishes via the handler's
    /// `channelInactive`, which also fires the disconnect callback.
    func close() {
        guard case .connected(let channel) = state else { return }
        state = .notConnected
        channel.close(promise: nil)
    }
    
    func send(_ message: String) async throws {
        guard case .connected(let channel) = state else { throw Error.notConnected }
        try await channel.writeAndFlush(ByteBuffer(string: "\(message)\n"))
    }
    
    func send(_ data: Data) async throws {
        guard case .connected(let channel) = state else { throw Error.notConnected }
        try await channel.writeAndFlush(ByteBuffer(bytes: data))
    }
}

extension Connection {
    class TCPClientHandler: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        private var receiveBuffer: ByteBuffer = ByteBuffer()
        private var writeContext: ChannelHandlerContext?
        /// Set by `errorCaught` so the subsequent `channelInactive` reports the real cause. Fired
        /// exactly once (from `channelInactive`) to avoid a double disconnect notification.
        private var disconnectReason: String?
        private var didNotifyInactive = false
        let continuation: AsyncThrowingStream<Data, any Swift.Error>.Continuation
        let onActive: @Sendable () -> Void
        let onInactive: @Sendable (_ reason: String) -> Void

        init(continuation: AsyncThrowingStream<Data, any Swift.Error>.Continuation,
             onActive: @escaping @Sendable () -> Void = {},
             onInactive: @escaping @Sendable (_ reason: String) -> Void = { _ in }) {
            self.continuation = continuation
            self.onActive = onActive
            self.onInactive = onInactive
        }

        // channel is connected, send a message
        func channelActive(context: ChannelHandlerContext) {
            Container.terminalService().print("Client connected to \(context.remoteAddress?.description ?? "unknown")")
            writeContext = context
            onActive()
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var unwrappedInboundData = Self.unwrapInboundIn(data)
            receiveBuffer.writeBuffer(&unwrappedInboundData)
            if let bytes = receiveBuffer.readBytes(length: receiveBuffer.readableBytes) {
                continuation.yield(Data(bytes))
            }
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            disconnectReason = error.localizedDescription
            continuation.finish(throwing: error)
            context.close(promise: nil)
        }

        func channelInactive(context: ChannelHandlerContext) {
            Container.terminalService().print("Disconnected from: \(context.remoteAddress?.description ?? "unknown")")
            continuation.finish()
            guard !didNotifyInactive else { return }
            didNotifyInactive = true
            onInactive(disconnectReason ?? "connection closed")
        }
    }
}
