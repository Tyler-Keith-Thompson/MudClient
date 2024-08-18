//
//  Cursor.swift
//  MudClient
//
//  Created by Tyler Thompson on 8/17/24.
//

import Foundation
import DependencyInjection

final class Cursor {
    let lock = NSRecursiveLock()
    
    private(set) var column = 1
    
    init() { }
    
    func update(column: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.column = column
    }
    
    func moveLeft() {
        lock.lock()
        defer { lock.unlock() }
        if column > 0 {
            writeToStandardOut(data: Data("\u{1B}[D".utf8))
            column -= 1
        }
    }

    func moveRight(line lineBuffer: String) {
        lock.lock()
        defer { lock.unlock() }
        if column <= lineBuffer.count {
            writeToStandardOut(data: Data("\u{1B}[C".utf8))
            column += 1
        }
    }

    func moveRightBy(amount: Int) {
        lock.lock()
        defer { lock.unlock() }
        if amount > 0 {
            column += amount
            writeToStandardOut(data: Data("\u{1B}[\(amount)C".utf8))
        }
    }

    func moveToStartOfLine() {
        lock.lock()
        defer { lock.unlock() }
        writeToStandardOut(data: Data("\u{1B}[1G".utf8))
        column = 1
    }

    func moveToEndOf(line lineBuffer: String) {
        lock.lock()
        defer { lock.unlock() }
        let endPosition = lineBuffer.count
        column = endPosition+1
        writeToStandardOut(data: Data("\u{1B}[\(endPosition+1)G".utf8))
    }
    
    func writeToStandardOut(data: Data) {
        Container.terminalService().writeToStandardOut(data: data)
    }
}

extension Container {
    static let cursor = Factory(scope: .cached) { Cursor() }
}
