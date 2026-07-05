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

        try Container.scriptInterpreter().parser.parse("#load {AlterAeon}")
        try Container.scriptInterpreter().parser.parse("#load {AIPilot}")
        try Container.scriptInterpreter().parser.parse("#load {HUD}")
        try Container.scriptInterpreter().parser.parse("#load {Trivia}")
        
        // The connection lifecycle now lives in ConnectionManager, which owns the current connection,
        // pumps its output to the terminal/HUD, and can be re-driven at runtime (by the Lua
        // connect/disconnect builtins). The default startup connection is unchanged.
//        Container.connectionManager().connect(host: "godwars2.org", port: 3000)
        Container.connectionManager().connect(host: "alteraeon.com", port: 3002)
//        Container.connectionManager().connect(host: "localhost", port: 3000)
        Task {
            let stream = Container.inputService().commandStream.processScriptInput()
            for try await command in stream {
                // Consult the optional Lua `on_send` hook per final atomic command (may drop it,
                // replace it, or inject additional commands), then transmit and log what's sent.
                for outbound in Container.scriptInterpreter().engine.filterOutbound(command) {
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
