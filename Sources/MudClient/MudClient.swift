// The Swift Programming Language
// https://docs.swift.org/swift-book

import NIO
import NIOCore
import NIOPosix
import ArgumentParser
import DependencyInjection
import Foundation
import Cocoa
import Fakery

@main
struct Connect: ParsableCommand {
    mutating func run() throws {
        TerminalService.setRawTerminal()
        
        let stdInSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        stdInSource.setEventHandler(qos: .default, flags: [], handler: self.handleInput)
        stdInSource.resume()
        
        signal(SIGINT, SIG_IGN)
        let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigIntSource.setEventHandler(qos: .default, flags: [], handler: self.stop)
        sigIntSource.resume()
        
        Container.terminalService().setup()
        
        Task {
//            let connection = Connection(host: "alteraeon.com", port: 3000)
//            try await connection.connect()
//            let interpreter = Container.scriptInterpreter()
////            try interpreter.parser.parse("#load {test.script}")
            Task {
                while true {
                    try await Task.sleep(for: .seconds(Double.random(in: 0.05...1.0)))
                    print(Faker().lorem.paragraphs(amount: Int.random(in: 1...3)))
                }
            }
//            Task {
//                for try await string in connection {
//                    Container.terminalService().print(string)
//                }
//            }
            Task {
                let stream = Container.inputService().commandStream.processScriptInput()
                for try await command in stream {
//                    try await connection.send(command)
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
    
    private func stop() {
        var tattr = termios()
        tcgetattr(STDIN_FILENO, &tattr)
        tattr.c_lflag |= tcflag_t(ECHO | ICANON)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &tattr)
        Swift.print("Stopping")
        Self.exit(withError: nil)
    }
}

func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    Container.terminalService().print(items, separator: separator, terminator: terminator)
}
