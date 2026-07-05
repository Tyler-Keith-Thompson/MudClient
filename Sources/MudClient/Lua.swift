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
    /// Raw bytes pushed to Lua byte-for-byte (via `lua_pushlstring`), preserving embedded NULs and
    /// high bytes that a UTF-8 `String` round-trip would mangle. Used for binary telnet payloads.
    /// Only ever produced host-side (pushed to Lua); Lua strings decode back as `.string`.
    case bytes(Data)
    /// A reference to a Lua function stashed in the registry (e.g. a trigger handler).
    case function(LuaFunctionRef)
    /// A Lua table, split into its array part (1..#t, in order) and its string-keyed part.
    /// Non-string keys other than the array sequence are dropped. Lets structured data (e.g. the
    /// declarative `panel.render` spec) cross the boundary.
    indirect case table([LuaValue], [String: LuaValue])
}

/// Owns a `luaL_ref` handle so a Lua function (a trigger/alias callback) survives
/// past the C call that produced it. Releases the registry slot on deinit.
final class LuaFunctionRef: @unchecked Sendable {
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

    // A LuaFunctionRef can be released on any thread (e.g. an `after`/`ai_request` closure being
    // deallocated off the engine thread). luaL_unref must NOT run concurrently with other lua_State
    // use, so deinit only records the ref here; it's actually released by `drainUnrefs()` at the top
    // of every operation, which always runs under the engine lock.
    private let unrefLock = NSLock()
    private var pendingUnrefs: [Int32] = []

    init() {
        state = luaL_newstate()
        luaL_openlibs(state)
    }

    deinit {
        lua_close(state)
        boxes.forEach { $0.release() }
    }

    private func drainUnrefs() {
        unrefLock.lock()
        let refs = pendingUnrefs
        pendingUnrefs.removeAll()
        unrefLock.unlock()
        for ref in refs { luaL_unref(state, clua_registryindex(), ref) }
    }

    // MARK: - Running code

    func run(_ source: String, name: String = "=script") throws {
        drainUnrefs()
        let status = source.withCString { luaL_loadstring(state, $0) }
        guard status == LUA_OK else { throw LuaError.load(popError()) }
        guard lua_pcallk(state, 0, 0, 0, 0, nil) == LUA_OK else {
            throw LuaError.runtime(popError())
        }
    }

    func runFile(_ path: String) throws {
        drainUnrefs()
        let status = path.withCString { luaL_loadfilex(state, $0, nil) }
        guard status == LUA_OK else { throw LuaError.load(popError()) }
        guard lua_pcallk(state, 0, 0, 0, 0, nil) == LUA_OK else {
            throw LuaError.runtime(popError())
        }
    }

    /// Call a previously-stored Lua function (e.g. a trigger handler).
    func call(_ ref: LuaFunctionRef, _ args: [LuaValue]) throws {
        drainUnrefs()
        lua_rawgeti(state, clua_registryindex(), lua_Integer(ref.ref)) // push the function
        for a in args { push(a) }
        guard lua_pcallk(state, Int32(args.count), 0, 0, 0, nil) == LUA_OK else {
            throw LuaError.runtime(popError())
        }
    }

    /// Like `call`, but keeps the function's FIRST return value and decodes it (any further results
    /// are discarded). Used by the line-rewrite stage, where a trigger handler's return controls the
    /// displayed line (nil/no-return leaves it unchanged, `false`/`""` gags it, a string replaces it).
    func callReturning(_ ref: LuaFunctionRef, _ args: [LuaValue]) throws -> LuaValue {
        drainUnrefs()
        lua_rawgeti(state, clua_registryindex(), lua_Integer(ref.ref)) // push the function
        for a in args { push(a) }
        guard lua_pcallk(state, Int32(args.count), 1, 0, 0, nil) == LUA_OK else {
            throw LuaError.runtime(popError())
        }
        let value = decode(at: -1)
        lua_settop(state, -2) // pop the (single) result
        return value
    }

    /// The outcome of evaluating a REPL chunk (see `evalChunk`).
    enum REPLResult {
        /// The chunk ran. `values` are the results to auto-print (empty for a statement or a
        /// side-effect-only expression — the caller prints nothing then).
        case values([LuaValue])
        /// The chunk failed to compile as either an expression or a statement.
        case compileError(String)
        /// The chunk compiled but raised at runtime.
        case runtimeError(String)
    }

    /// Evaluate `chunk` REPL-style. First tries to compile `return (<chunk>)` — a successful compile
    /// means it's an expression, so it's run and every result decoded for auto-printing. If that fails
    /// to COMPILE, the chunk is run as a statement (no results). Compile/runtime errors are captured as
    /// concise strings. The chunk name is `=repl`, so error messages read `repl:1: ...` (no source
    /// echo). Caller must hold the engine lock (single-threaded lua_State).
    func evalChunk(_ chunk: String) -> REPLResult {
        drainUnrefs()
        // Newlines around the chunk so a trailing comment can't swallow the closing paren.
        // Detection uses the parenthesized form (per the REPL contract); when it's an expression we
        // actually run the paren-FREE `return <chunk>` so all results survive and a void call (e.g.
        // `send("x")`) yields zero results — printing nothing rather than a spurious `nil`.
        if compiles("return (\n" + chunk + "\n)") {
            if !loadBuffer("return \n" + chunk + "\n", name: "=repl") {
                lua_settop(state, -2)                  // pop that error; fall back to the paren form
                _ = loadBuffer("return (\n" + chunk + "\n)", name: "=repl")
            }
            let baseTop = lua_gettop(state) - 1        // stack depth below the loaded function
            guard lua_pcallk(state, 0, -1 /* LUA_MULTRET */, 0, 0, nil) == LUA_OK else {
                return .runtimeError(popError())
            }
            let n = Int(lua_gettop(state) - baseTop)
            var vals: [LuaValue] = []
            if n > 0 {
                vals.reserveCapacity(n)
                for i in 0..<n { vals.append(decode(at: baseTop + Int32(i) + 1)) }
            }
            lua_settop(state, baseTop)                 // clear the results
            return .values(vals)
        }
        if loadBuffer(chunk, name: "=repl") {
            guard lua_pcallk(state, 0, 0, 0, 0, nil) == LUA_OK else {
                return .runtimeError(popError())
            }
            return .values([])
        }
        return .compileError(popError())               // couldn't compile either way
    }

    /// Does `source` compile (as a complete chunk)? Loads and immediately discards it; runs nothing.
    /// Used by the REPL's legacy-command detector to tell a real Lua expression apart from a bare
    /// `#word rest` typed-command form. Caller holds the lock.
    func compiles(_ source: String) -> Bool {
        drainUnrefs()
        let ok = loadBuffer(source, name: "=repl")
        lua_settop(state, -2)   // pop the compiled function (on success) or the error (on failure)
        return ok
    }

    /// Is the global `name` currently a Lua function? Used by the REPL to decide whether a typed
    /// `#word ...` should be rewritten to a call. Caller holds the lock.
    func globalIsFunction(_ name: String) -> Bool {
        drainUnrefs()
        name.withCString { _ = lua_getglobal(state, $0) }
        let isFn = lua_type(state, -1) == LUA_TFUNCTION
        lua_settop(state, -2)
        return isFn
    }

    /// Is the global `name` currently *callable* — a plain function, or a table carrying a `__call`
    /// metamethod? The migrated command surface exposes tables (`eq`, `kxwt`, `pilot`, `trivia`) that
    /// are documented member-by-member yet stay callable so a legacy `#eq scan` still rewrites to
    /// `eq("scan")`. The REPL uses this (not `globalIsFunction`) so those callable tables keep working.
    /// Caller holds the lock.
    func globalIsCallable(_ name: String) -> Bool {
        drainUnrefs()
        name.withCString { _ = lua_getglobal(state, $0) }
        defer { lua_settop(state, -2) }
        let t = lua_type(state, -1)
        if t == LUA_TFUNCTION { return true }
        if t == LUA_TTABLE, lua_getmetatable(state, -1) != 0 {   // pushes the metatable
            _ = "__call".withCString { lua_getfield(state, -1, $0) } // pushes mt.__call
            let callable = lua_type(state, -1) != LUA_TNIL
            lua_settop(state, -3)                                 // pop __call value + metatable
            return callable
        }
        return false
    }

    /// Load `src` under chunk name `name`, leaving the compiled function on the stack on success (and
    /// an error object on failure). Returns whether it compiled.
    private func loadBuffer(_ src: String, name: String) -> Bool {
        var ok = false
        src.withCString { s in
            let len = strlen(s)
            name.withCString { n in
                ok = luaL_loadbufferx(state, s, len, n, nil) == LUA_OK
            }
        }
        return ok
    }

    /// Call a global Lua function by name if it is defined; a no-op if the global is absent or not
    /// a function (lets the host notify scripts about optional hooks like `on_user_input`).
    func callGlobal(_ name: String, _ args: [LuaValue]) throws {
        drainUnrefs()
        name.withCString { _ = lua_getglobal(state, $0) }
        guard lua_type(state, -1) == LUA_TFUNCTION else {
            lua_settop(state, -2) // pop the non-function (nil) value
            return
        }
        for a in args { push(a) }
        guard lua_pcallk(state, Int32(args.count), 0, 0, 0, nil) == LUA_OK else {
            throw LuaError.runtime(popError())
        }
    }

    /// Call a global Lua function by name and return its first result coerced to a boolean (Lua
    /// truthiness). A no-op returning `false` if the global is absent or not a function. Used by the
    /// host to let an optional hook (e.g. `on_mouse`) signal that it consumed an event.
    func callGlobalBool(_ name: String, _ args: [LuaValue]) throws -> Bool {
        drainUnrefs()
        name.withCString { _ = lua_getglobal(state, $0) }
        guard lua_type(state, -1) == LUA_TFUNCTION else {
            lua_settop(state, -2) // pop the non-function (nil) value
            return false
        }
        for a in args { push(a) }
        guard lua_pcallk(state, Int32(args.count), 1, 0, 0, nil) == LUA_OK else {
            throw LuaError.runtime(popError())
        }
        let result = lua_toboolean(state, -1) != 0
        lua_settop(state, -2) // pop the result
        return result
    }

    /// Call a global function and return its first result, or `.nil` if it returned nothing. Returns
    /// Swift `nil` when the global is undefined or not a function — lets the host consult an optional
    /// hook that yields a value (e.g. `on_send`, `on_telnet_negotiate`) while distinguishing "no hook"
    /// from "hook returned nil".
    func callGlobalReturning(_ name: String, _ args: [LuaValue]) throws -> LuaValue? {
        drainUnrefs()
        name.withCString { _ = lua_getglobal(state, $0) }
        guard lua_type(state, -1) == LUA_TFUNCTION else {
            lua_settop(state, -2) // pop the non-function (nil) value
            return nil
        }
        for a in args { push(a) }
        guard lua_pcallk(state, Int32(args.count), 1, 0, 0, nil) == LUA_OK else {
            throw LuaError.runtime(popError())
        }
        let result = decode(at: -1)
        lua_settop(state, -2) // pop the result
        return result
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
        case LUA_TTABLE:
            return decodeTable(at: idx)
        default:
            return .nil
        }
    }

    /// Decode a Lua table into `.table(array, dict)`. The array part is the contiguous 1..#t
    /// sequence; the dict part is every string key. Recurses for nested tables. The stack is left
    /// exactly as found. Every index is resolved to an absolute one up front so nested pushes (and
    /// the `lua_next` traversal) don't shift the table out from under us.
    private func decodeTable(at idx: Int32) -> LuaValue {
        let t = lua_absindex(state, idx)
        var array: [LuaValue] = []
        let n = Int(lua_rawlen(state, t))
        if n > 0 {
            array.reserveCapacity(n)
            for i in 1...n {
                lua_geti(state, t, lua_Integer(i))   // push t[i]
                array.append(decode(at: -1))
                lua_settop(state, -2)                // pop it
            }
        }
        var dict: [String: LuaValue] = [:]
        lua_pushnil(state)                           // first key for lua_next
        while lua_next(state, t) != 0 {              // pushes key(-2), value(-1); pops the old key
            // Only take string keys. Guarding on the type first means the following lua_tolstring
            // can't mutate a numeric key in place (which would corrupt the lua_next traversal).
            if lua_type(state, -2) == LUA_TSTRING, let c = lua_tolstring(state, -2, nil) {
                dict[String(cString: c)] = decode(at: -1)
            }
            lua_settop(state, -2)                    // pop value, keep key for the next lua_next
        }
        return .table(array, dict)
    }

    func push(_ v: LuaValue) {
        switch v {
        case .nil: lua_pushnil(state)
        case .bool(let b): lua_pushboolean(state, b ? 1 : 0)
        case .int(let i): lua_pushinteger(state, i)
        case .number(let d): lua_pushnumber(state, d)
        case .string(let s): pushString(s)
        case .bytes(let d): pushBytes(d)
        case .function(let f): lua_rawgeti(state, clua_registryindex(), lua_Integer(f.ref))
        case .table(let array, let dict):
            lua_createtable(state, Int32(array.count), Int32(dict.count))
            for (i, v) in array.enumerated() {
                push(v)
                lua_seti(state, -2, lua_Integer(i + 1))   // t[i+1] = v (pops v)
            }
            for (k, v) in dict {
                push(v)
                k.withCString { lua_setfield(state, -2, $0) }  // t[k] = v (pops v)
            }
        }
    }

    private func pushBytes(_ d: Data) {
        if d.isEmpty { _ = lua_pushlstring(state, "", 0); return }
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            raw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: raw.count) {
                _ = lua_pushlstring(state, $0, raw.count)
            }
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
        // May be called from any thread (ref deallocated off the engine thread); defer the actual
        // luaL_unref to the next locked operation via drainUnrefs().
        unrefLock.lock(); pendingUnrefs.append(ref); unrefLock.unlock()
    }

    private func popError() -> String {
        defer { lua_settop(state, -2) } // pop the error object
        if let c = lua_tolstring(state, -1, nil) { return String(cString: c) }
        return "unknown error"
    }
}
