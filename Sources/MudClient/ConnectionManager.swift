//
//  ConnectionManager.swift
//  MudClient
//
//  Owns the *current* live ``Connection`` and its I/O pumps, so the connection lifecycle can be
//  driven at runtime (including by Lua via the `connect`/`disconnect`/`is_connected` builtins)
//  instead of being pinned to a single connection created at startup. The output pump forwards
//  assembled server lines to the terminal (and refreshes the HUD); the input side routes commands
//  and raw telnet bytes to whichever connection is current.
//

import Foundation
import DependencyInjection

final class ConnectionManager: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var connection: Connection?
    private var pumpTask: Task<Void, Never>?
    private var _connected = false
    /// Guards against a doubled disconnect notification: the NIO `channelInactive` callback and the
    /// output pump's stream-error path can both observe the same teardown. Reset on each `connect`.
    private var notifiedDisconnect = false

    /// Whether a socket is currently connected (as observed by the NIO channel-active/inactive events).
    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return _connected }

    /// Open a new connection to `host:port`, tearing down any existing one first. Fires the script's
    /// `on_connect` once the socket is active and `on_disconnect(reason)` when it goes down.
    func connect(host: String, port: UInt16) {
        disconnect()
        lock.lock(); notifiedDisconnect = false; lock.unlock()

        let conn = Connection(
            host: host, port: port,
            onChannelActive: { [weak self] in
                self?.setConnected(true)
                Container.scriptInterpreter().engine.notifyConnect()
            },
            onChannelInactive: { [weak self] reason in
                self?.setConnected(false)
                self?.notifyDisconnectOnce(reason)
            })

        lock.lock(); connection = conn; lock.unlock()

        pumpTask = Task { [weak self] in
            do {
                try await conn.connect()
                for try await string in conn {
                    // Refresh the panel model first (triggers have updated `state`), then paint.
                    Container.scriptInterpreter().engine.notifyUpdate()
                    Container.sessionLog().logServer(string)   // TinTin #log: record live server output
                    Container.terminalService().render(string)
                }
            } catch {
                // `connect()` failed outright (no channel — so no channelInactive), or the stream
                // errored. Ensure the script hears exactly one disconnect for this cycle.
                self?.setConnected(false)
                self?.notifyDisconnectOnce(error.localizedDescription)
            }
        }
    }

    /// Close the current connection (if any). Idempotent.
    func disconnect() {
        lock.lock()
        let conn = connection
        connection = nil
        pumpTask?.cancel()
        pumpTask = nil
        lock.unlock()
        if let conn { Task { await conn.close() } }
    }

    /// Send a line of input (a `\n` is appended by ``Connection``) to the current connection.
    func send(_ command: String) {
        lock.lock(); let conn = connection; lock.unlock()
        guard let conn else { return }
        Task { try? await conn.send(command) }
    }

    /// Send raw bytes (e.g. a telnet subnegotiation) to the current connection, verbatim.
    func sendRaw(_ data: Data) {
        lock.lock(); let conn = connection; lock.unlock()
        guard let conn else { return }
        Task { try? await conn.send(data) }
    }

    private func setConnected(_ value: Bool) { lock.lock(); _connected = value; lock.unlock() }

    private func notifyDisconnectOnce(_ reason: String) {
        lock.lock()
        if notifiedDisconnect { lock.unlock(); return }
        notifiedDisconnect = true
        lock.unlock()
        // The game's soundscape must not outlive the connection: fade out music channels, cut
        // in-flight MSP one-shots, and flush any queued speech.
        Container.musicService().stopAll()
        Container.mspService().stopAll()
        Container.speechService().stop()
        Container.scriptInterpreter().engine.notifyDisconnect(reason: reason)
    }
}

extension Container {
    static let connectionManager = Factory(scope: .cached) { ConnectionManager() }
}
