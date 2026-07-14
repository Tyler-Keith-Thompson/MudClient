//
//  ServerTextFeed.swift
//  MudClient
//
//  Lets Lua hand decoded game text back to the SAME inbound display/trigger pipeline the telnet
//  connection uses (`feed_server` builtin). Structured exactly like RPCConnection's text_block pump:
//  an AsyncThrowingStream fed by `feed`, run through captureRaw → IAC → line-endings → server-stream
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

    /// Inject `data` into the inbound pipeline. Starts the pump lazily on first use.
    func feed(_ data: Data) {
        lock.lock()
        if continuation == nil { startPump() }
        let cont = continuation
        lock.unlock()
        cont?.yield(data)
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
