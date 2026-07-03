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

        // On resize the scroll region's bottom row moves, so re-set it and repaint the top panel.
        signal(SIGWINCH, SIG_IGN)
        let sigWinchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        sigWinchSource.setEventHandler(qos: .default, flags: []) { Container.panelHost().flush(force: true) }
        sigWinchSource.resume()

        Container.terminalService().setup()

        try Container.scriptInterpreter().parser.parse("#load {AlterAeon}")
        try Container.scriptInterpreter().parser.parse("#load {AIPilot}")
        try Container.scriptInterpreter().parser.parse("#load {HUD}")
        
        Task {
//            let connection = Connection(host: "godwars2.org", port: 3000)
            let connection = Connection(host: "alteraeon.com", port: 3002)
//            let connection = Connection(host: "localhost", port: 3000)
            try await connection.connect()
            Task {
                for try await string in connection {
                    // A fully-gagged chunk (e.g. an idle kxwt_ status batch) renders to "". Don't print
                    // it — print() unconditionally paints a divider line, so print("") leaves a blank line
                    // on screen. But DO still refresh the panel: those gagged kxwt_ batches are exactly
                    // the status updates (hp/mana/room) the HUD is built from.
                    if !string.isEmpty {
                        Container.terminalService().print(string, terminator: "")
                    }
                    Container.scriptInterpreter().engine.notifyUpdate()
                }
            }
            Task {
                let stream = Container.inputService().commandStream.processScriptInput()
                for try await command in stream {
                    try await connection.send(command)
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
