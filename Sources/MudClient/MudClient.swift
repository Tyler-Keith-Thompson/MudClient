// The Swift Programming Language
// https://docs.swift.org/swift-book

import NIO
import NIOCore
import NIOPosix
import ArgumentParser
import DependencyInjection
import Foundation
import Cocoa

@main
struct Connect: ParsableCommand {
    mutating func run() throws {
        TerminalService.setRawTerminal()
        
        let stdInSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        stdInSource.setEventHandler(qos: .default, flags: [], handler: self.handleInput)
        stdInSource.resume()
        
        signal(SIGINT, SIG_IGN)
        let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigIntSource.setEventHandler(qos: .default, flags: [], handler: Container.terminalService().handleSigInt)
        sigIntSource.resume()

        // On resize the scroll region and furniture positions move, so rebuild the whole layout.
        signal(SIGWINCH, SIG_IGN)
        let sigWinchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        sigWinchSource.setEventHandler(qos: .default, flags: [], handler: Container.terminalService().handleResize)
        sigWinchSource.resume()

        Container.terminalService().setup()

        // Start the main-queue heartbeat that detects UI hitches (see LagMonitor). Must run on `.main`,
        // where rendering + input live, so it measures the loop the user actually feels stall.
        Container.lagMonitor().start()

        // Load the Scripts/ directory. This runs each script's top-level code, which is what wires
        // the client up: AlterAeon.lua opens the connection itself (a guarded top-level `connect()`),
        // so there is no hardcoded host/port here. The connection lifecycle lives in ConnectionManager
        // (driven by the Lua connect/disconnect builtins); `reload()` re-runs this same loader.
        Container.scriptInterpreter().loadScripts()

        Task {
            let stream = Container.inputService().commandStream.processScriptInput()
            for try await command in stream {
                // Consult the optional Lua `on_send` hook per final atomic command (may drop it,
                // replace it, or inject additional commands), then transmit and log what's sent.
                for outbound in Container.scriptInterpreter().engine.filterOutbound(command.text) {
                    // Record every wire-level send with the origin of the command that produced it
                    // (on_send-injected sends inherit that origin) for the searchable transcript.
                    Container.transcriptStore().recordSent(outbound, origin: command.origin)
                    Container.sessionLog().logCommand(outbound)
                    Container.connectionManager().send(outbound)
                }
            }
        }

        dispatchMain()
    }
    
    private func handleInput() {
        let data = FileHandle.standardInput.availableData

        guard let string = String(data: data, encoding: .utf8) else {
            return
        }

        Container.terminalService().handle(input: string)
    }
}

func print(_ item: Any, terminator: String = "\n") {
    Container.terminalService().print(item, terminator: terminator)
}
