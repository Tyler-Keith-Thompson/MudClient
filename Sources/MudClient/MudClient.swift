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
        
        Container.terminalService().setup()
        
        try Container.scriptInterpreter().parser.parse("#load {AlterAeon}")
        
        Task {
//            let connection = Connection(host: "godwars2.org", port: 3000)
            let connection = Connection(host: "alteraeon.com", port: 3002)
            try await connection.connect()
            Task {
                for try await string in connection {
                    Container.terminalService().print(string, terminator: "")
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
