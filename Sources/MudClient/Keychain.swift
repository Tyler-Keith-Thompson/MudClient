//
//  Keychain.swift
//  MudClient
//
//  Tiny read-only wrapper over the macOS keychain, used to fetch secrets (e.g. the Anthropic API
//  key for the memory head) without putting them in env vars or source. Store the secret yourself
//  with the `security` CLI so it never transits the app's input:
//
//      security add-generic-password -s "MudClient" -a "anthropic-api-key" -w "sk-ant-..." -A -U
//
//  (-A allows the app to read it without a per-launch access prompt; -U updates an existing item.)
//

import DependencyInjection
import Foundation
import Security

enum Keychain {
    /// Read a generic-password item's value, or nil if absent/unreadable.
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Anthropic API key for the memory head: keychain first, then env var as a fallback.
    static var anthropicAPIKey: String? {
        read(service: "MudClient", account: "anthropic-api-key")
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    }
}

extension Container {
    /// Injectable provider for the Anthropic API key. Defaults to the keychain (+ env fallback);
    /// tests can `.register { { nil } }` to avoid any keychain access. Callers hold onto the returned
    /// closure and invoke it lazily at request time, so configuration never triggers a keychain read.
    static let anthropicAPIKeyProvider = Factory { { Keychain.anthropicAPIKey } as () -> String? }
}
