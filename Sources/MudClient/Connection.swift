//
//  Connection.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/11/24.
//

import Foundation
import NIO
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
    
    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
    
    nonisolated func makeAsyncIterator() -> AnyAsyncSequence<String>.AsyncIterator {
        stream.captureRaw()
            .handleIACCommunication(writeToStream: send)
            .processMSP()
            .processServerOutputForScripts()
            .eraseToAnyAsyncSequence()
            .makeAsyncIterator()
    }
    
    func connect() async throws {
        guard case .notConnected = state else {
            throw Error.alreadyConnected
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(TCPClientHandler(continuation: self.continuation))
            }

        let clientChannel = try await bootstrap.connect(host: host, port: Int(port))
            .get()
        
        self.state = .connected(channel: clientChannel)
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
        let continuation: AsyncThrowingStream<Data, any Swift.Error>.Continuation
        
        init(continuation: AsyncThrowingStream<Data, any Swift.Error>.Continuation) {
            self.continuation = continuation
        }
        
        // channel is connected, send a message
        func channelActive(context: ChannelHandlerContext) {
            Container.terminalService().print("Client connected to \(context.remoteAddress?.description ?? "unknown")")
            writeContext = context
        }
        
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var unwrappedInboundData = Self.unwrapInboundIn(data)
            receiveBuffer.writeBuffer(&unwrappedInboundData)
            if let bytes = receiveBuffer.readBytes(length: receiveBuffer.readableBytes) {
                continuation.yield(Data(bytes))
            }
        }
        
        func errorCaught(context: ChannelHandlerContext, error: Error) {
            continuation.finish(throwing: error)
            context.close(promise: nil)
        }
        
        func channelInactive(context: ChannelHandlerContext) {
            Container.terminalService().print("Disconnected from: \(context.remoteAddress?.description ?? "unknown")")
            continuation.finish()
        }
    }
}
