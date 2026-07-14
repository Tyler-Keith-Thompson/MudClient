//
//  ServerTextFeed.swift
//  MudClient
//
//  Lets Lua hand decoded game text back to the SAME inbound display/trigger pipeline the telnet
//  connection uses (`feed_server` builtin): an AsyncThrowingStream fed by `feed`, run through
//  captureRaw → IAC → line-endings → server-stream
//  filter → line assembly → MSP → script processing, then rendered + logged. Independent of
//  NetConnection/ConnectionManager — works whether or not a socket is connected, since the bytes
//  originate from Lua (e.g. a decoded protobuf payload), not a live wire read.
//

import Foundation
import DependencyInjection

final class ServerTextFeed: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var continuation: AsyncThrowingStream<Data, any Swift.Error>.Continuation?
    private var pumpTask: Task<Void, Never>?

    /// Inject `data` — ONE COMPLETE server message — into the inbound pipeline. Starts the pump lazily.
    ///
    /// Unlike a telnet socket read (arbitrary byte chunk), each `feed` is a whole, self-delimited message
    /// (a decoded protobuf `text_block`), and the server is idle after it. There is no telnet GO-AHEAD on
    /// the protobuf wire to flush a final no-newline line, so the line assembler would otherwise hold that
    /// line until the NEXT message arrives (the "off-by-one" prompt lag). We therefore flush at the message
    /// boundary: append the pipeline's own prompt-flush trigger (the byte sequence the IAC layer maps to
    /// the flush marker) so the message's last line renders immediately. This keys off the message, not a
    /// wire GA — protobuf messages ARE the chunk boundary.
    private static let messageFlush = Data([0xff, 0xf9])   // IAC GO-AHEAD → prompt-flush marker downstream
    func feed(_ data: Data) {
        lock.lock()
        if continuation == nil { startPump() }
        let cont = continuation
        lock.unlock()
        cont?.yield(data + Self.messageFlush)
    }

    private func startPump() {
        let (textStream, cont) = AsyncThrowingStream<Data, any Swift.Error>.makeStream()
        continuation = cont
        pumpTask = Task {
            let processed = textStream
                .captureRaw()
                .handleIACCommunication(writeToStream: { _ in })
                .normalizeLineEndings()
                .filterServerStream()
                .assembleLines()
                .processMSP()
                .processServerOutputForScripts()
            do {
                for try await string in processed {
                    Container.scriptInterpreter().engine.notifyUpdate()
                    Container.sessionLog().logServer(string)
                    Container.terminalService().render(string)
                }
            } catch {}
        }
    }
}

extension Container {
    static let serverTextFeed = Factory(scope: .cached) { ServerTextFeed() }
}
