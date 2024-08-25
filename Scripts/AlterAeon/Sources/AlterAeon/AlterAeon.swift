// The Swift Programming Language
// https://docs.swift.org/swift-book

import ScriptDescription

@_cdecl("createFactory")
public func createFactory() -> UnsafeMutableRawPointer {
    return Unmanaged.passRetained(AAFactory()).toOpaque()
}

class AAFactory: ScriptFactory {
    override func getScript() -> Script {
        Script {
            Trigger(/.*? is DEAD!/) { _ in
                [
                    .send("cry")
                ]
            }
        }
    }
}
