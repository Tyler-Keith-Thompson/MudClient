//
//  Lua.swift
//  MudClient
//
//  A thin, hand-written Swift bridge over the embedded Lua 5.4 C library
//  (vendored as the `CLua` target). Replaces the old swift-build + dlopen
//  scripting pipeline: scripts are now interpreted Lua loaded at runtime.
//
//  Threading: a lua_State is NOT thread-safe. All access to a `Lua` instance
//  must be serialized by the caller (see LuaScriptEngine, which holds a lock).
//

import CLua
import Foundation

/// A value crossing the Swift <-> Lua boundary.
enum LuaValue {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case number(Double)
    case string(String)
    /// A reference to a Lua function stashed in the registry (e.g. a trigger handler).
    case function(LuaFunctionRef)
}

/// Owns a `luaL_ref` handle so a Lua function (a trigger/alias callback) survives
/// past the C call that produced it. Releases the registry slot on deinit.
final class LuaFunctionRef {
    fileprivate let ref: Int32
    fileprivate weak var lua: Lua?
    fileprivate init(ref: Int32, lua: Lua) {
        self.ref = ref
        self.lua = lua
    }
    deinit { lua?.unref(ref) }
}

enum LuaError: Error, CustomStringConvertible {
    case load(String)
    case runtime(String)
    var description: String {
        switch self {
        case .load(let m): return "Lua load error: \(m)"
        case .runtime(let m): return "Lua runtime error: \(m)"
        }
    }
}

/// A Swift closure exposed to Lua as a global function.
typealias LuaHostFunction = (_ args: [LuaValue]) throws -> [LuaValue]

/// Retained box carrying a host closure (and an unowned back-pointer to the
/// interpreter) so the C trampoline can recover both from a light-userdata upvalue.
private final class HostFnBox {
    unowned let lua: Lua
    let fn: LuaHostFunction
    init(_ lua: Lua, _ fn: @escaping LuaHostFunction) {
        self.lua = lua
        self.fn = fn
    }
}

final class Lua: @unchecked Sendable {
    let state: OpaquePointer
    private var boxes: [Unmanaged<HostFnBox>] = []

    init() {
        state = luaL_newstate()
        luaL_openlibs(state)
    }

    deinit {
        lua_close(state)
        boxes.forEach { $0.release() }
    }

    // MARK: - Running code

    func run(_ source: String, name: String = "=script") throws {
        let status = source.withCString { luaL_loadstring(state, $0) }
        guard status == LUA_OK else { throw LuaError.load(popError()) }
        guard lua_pcallk(state, 0, 0, 0, 0, nil) == LUA_OK else {
            throw LuaError.runtime(popError())
        }
    }

    func runFile(_ path: String) throws {
        let status = path.withCString { luaL_loadfilex(state, $0, nil) }
        guard status == LUA_OK else { throw LuaError.load(popError()) }
        guard lua_pcallk(state, 0, 0, 0, 0, nil) == LUA_OK else {
            throw LuaError.runtime(popError())
        }
    }

    /// Call a previously-stored Lua function (e.g. a trigger handler).
    func call(_ ref: LuaFunctionRef, _ args: [LuaValue]) throws {
        lua_rawgeti(state, clua_registryindex(), lua_Integer(ref.ref)) // push the function
        for a in args { push(a) }
        guard lua_pcallk(state, Int32(args.count), 0, 0, 0, nil) == LUA_OK else {
            throw LuaError.runtime(popError())
        }
    }

    // MARK: - Registering host functions

    func register(_ name: String, _ fn: @escaping LuaHostFunction) {
        let boxed = Unmanaged.passRetained(HostFnBox(self, fn))
        boxes.append(boxed)
        lua_pushlightuserdata(state, boxed.toOpaque())
        lua_pushcclosure(state, Lua.trampoline, 1)
        name.withCString { lua_setglobal(state, $0) }
    }

    /// C entry point for every host function. Captures nothing (required for
    /// `@convention(c)`); recovers the Swift closure from the upvalue box.
    private static let trampoline: @convention(c) (OpaquePointer?) -> Int32 = { s in
        guard let s, let raw = lua_touserdata(s, clua_upvalueindex(1)) else { return 0 }
        let box = Unmanaged<HostFnBox>.fromOpaque(raw).takeUnretainedValue()
        let lua = box.lua
        let n = lua_gettop(s)
        var args: [LuaValue] = []
        if n > 0 {
            args.reserveCapacity(Int(n))
            for i in 1...n { args.append(lua.decode(at: i)) }
        }
        do {
            let results = try box.fn(args)
            for r in results { lua.push(r) }
            return Int32(results.count)
        } catch {
            // Never longjmp (lua_error) across this Swift frame — just report.
            lua.errorHandler("script error in host call: \(error)")
            return 0
        }
    }

    /// Where host-side errors are surfaced. Overridden by the engine.
    var errorHandler: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    // MARK: - Stack marshalling

    func decode(at idx: Int32) -> LuaValue {
        switch lua_type(state, idx) {
        case LUA_TBOOLEAN:
            return .bool(lua_toboolean(state, idx) != 0)
        case LUA_TNUMBER:
            if lua_isinteger(state, idx) != 0 {
                return .int(lua_tointegerx(state, idx, nil))
            }
            return .number(lua_tonumberx(state, idx, nil))
        case LUA_TSTRING:
            if let c = lua_tolstring(state, idx, nil) { return .string(String(cString: c)) }
            return .nil
        case LUA_TFUNCTION:
            lua_pushvalue(state, idx)                                  // copy to top
            let ref = luaL_ref(state, clua_registryindex())            // pops it, returns handle
            return .function(LuaFunctionRef(ref: ref, lua: self))
        default:
            return .nil
        }
    }

    func push(_ v: LuaValue) {
        switch v {
        case .nil: lua_pushnil(state)
        case .bool(let b): lua_pushboolean(state, b ? 1 : 0)
        case .int(let i): lua_pushinteger(state, i)
        case .number(let d): lua_pushnumber(state, d)
        case .string(let s): pushString(s)
        case .function(let f): lua_rawgeti(state, clua_registryindex(), lua_Integer(f.ref))
        }
    }

    private func pushString(_ s: String) {
        var copy = s
        copy.withUTF8 { buf in
            if let base = buf.baseAddress {
                base.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                    _ = lua_pushlstring(state, $0, buf.count)
                }
            } else {
                _ = lua_pushlstring(state, "", 0)
            }
        }
    }

    // MARK: - Internals

    fileprivate func unref(_ ref: Int32) {
        luaL_unref(state, clua_registryindex(), ref)
    }

    private func popError() -> String {
        defer { lua_settop(state, -2) } // pop the error object
        if let c = lua_tolstring(state, -1, nil) { return String(cString: c) }
        return "unknown error"
    }
}
