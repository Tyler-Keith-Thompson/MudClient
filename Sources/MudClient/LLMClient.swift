//
//  LLMClient.swift
//  MudClient
//
//  A generic, game-agnostic bridge to an OpenAI-compatible chat-completions endpoint
//  (LM Studio by default). It backs the `ai_request` Lua builtin: scripts decide what to
//  send and how to react; this just performs the call. Endpoint/model come from the
//  environment but can be overridden at runtime (so a script can implement `#ai url/model`).
//

import Foundation

final class LLMClient: @unchecked Sendable {
    private let lock = NSLock()
    private var baseURL: String
    private var configuredModel: String?   // nil => auto-discover
    private var resolvedModel: String?
    private var temperature: Double = 0.6
    // Bearer token provider (e.g. for a hosted API); resolved at REQUEST time, not when set — so a
    // keychain-backed key isn't read (and can't prompt) just by configuring the client. nil => local.
    private var authKeyProvider: () -> String? = { nil }
    private var useAnthropic = false       // use Anthropic's NATIVE /v1/messages API (enables prompt caching)

    init() {
        let env = ProcessInfo.processInfo.environment
        baseURL = env["LMSTUDIO_BASE_URL"] ?? "http://localhost:1234/v1"
        configuredModel = env["LMSTUDIO_MODEL"].flatMap { $0.isEmpty ? nil : $0 }
    }

    func setEndpoint(_ url: String) { lock.lock(); baseURL = url; lock.unlock() }
    func setModel(_ model: String?) {
        lock.lock(); configuredModel = (model?.isEmpty == true) ? nil : model; resolvedModel = nil; lock.unlock()
    }
    /// Set a fixed Bearer auth token (for a hosted OpenAI-compatible endpoint, e.g. Anthropic).
    func setAuthKey(_ key: String?) {
        let k = (key?.isEmpty == true) ? nil : key
        lock.lock(); authKeyProvider = { k }; lock.unlock()
    }
    /// Set a *lazy* Bearer token source, resolved on each request rather than now. Use this for a
    /// keychain-backed key so merely configuring the client never performs a keychain read.
    func setAuthKeyProvider(_ provider: @escaping () -> String?) {
        lock.lock(); authKeyProvider = provider; lock.unlock()
    }
    /// Use Anthropic's native /v1/messages API (so we can mark the system + tools with cache_control
    /// and pay ~10% for that constant prefix instead of full price every turn). Off = OpenAI format.
    func setAnthropic(_ on: Bool) { lock.lock(); useAnthropic = on; lock.unlock() }
    var endpoint: String { lock.lock(); defer { lock.unlock() }; return baseURL }

    /// The outcome of a chat completion: free-text reasoning plus, if the model used tool calling,
    /// the calls it made (already normalized to a compact `[{name, arguments}]` JSON string the Lua
    /// side can decode). `toolCallsJSON` is nil when the model answered with plain text.
    struct Completion {
        let content: String
        let toolCallsJSON: String?
    }

    /// Run a system+user chat completion. `tools`, when provided, is a raw JSON array of OpenAI
    /// tool definitions injected verbatim into the request (the *definitions* are the caller's
    /// concern — this client stays game-agnostic). `assistantPrefix`, when non-empty, is appended as
    /// a trailing partial assistant turn the model continues from — a generic mechanism the caller
    /// uses for model-specific prefills (e.g. a closed reasoning block to suppress thinking). This
    /// client attaches no meaning to it.
    func complete(system: String, user: String, maxTokens: Int, tools: String? = nil,
                  assistantPrefix: String? = nil) async throws -> Completion {
        let model = try await resolveModel()
        lock.lock(); let base = baseURL; let temp = temperature; let provider = authKeyProvider; let native = useAnthropic; lock.unlock()
        let key = provider()   // resolve the key now, at request time (may read the keychain)
        if native {
            return try await completeAnthropic(model: model, base: base, key: key, temp: temp, system: system,
                                               user: user, maxTokens: maxTokens, tools: tools, assistantPrefix: assistantPrefix)
        }
        var req = URLRequest(url: try Self.url(base, "/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 60
        var messages: [[String: Any]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": user],
        ]
        if let assistantPrefix, !assistantPrefix.isEmpty {
            messages.append(["role": "assistant", "content": assistantPrefix])
        }
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": temp,
            "max_tokens": maxTokens,
            "stream": false,
        ]
        if let tools, let parsed = try? JSONSerialization.jsonObject(with: Data(tools.utf8)) {
            body["tools"] = parsed
            // "required" forces the model to emit a tool call every turn instead of replying with
            // prose (a weak/small model otherwise narrates "I'll cast X" and never acts). The script
            // provides a `wait` tool for "do nothing", so requiring a call never traps the model.
            body["tool_choice"] = "required"
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw Error.http("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(snippet)")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else { throw Error.badResponse }
        let content = (message["content"] as? String) ?? ""

        var toolCallsJSON: String? = nil
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            var simplified: [[String: Any]] = []
            for call in rawCalls {
                guard let fn = call["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }
                // Per the OpenAI shape arguments is a JSON *string*; some servers emit an object —
                // accept both and always hand Lua a string.
                let arguments: String
                if let s = fn["arguments"] as? String {
                    arguments = s
                } else if let obj = fn["arguments"],
                          let d = try? JSONSerialization.data(withJSONObject: obj) {
                    arguments = String(data: d, encoding: .utf8) ?? "{}"
                } else {
                    arguments = "{}"
                }
                simplified.append(["name": name, "arguments": arguments])
            }
            if !simplified.isEmpty, let d = try? JSONSerialization.data(withJSONObject: simplified) {
                toolCallsJSON = String(data: d, encoding: .utf8)
            }
        }
        return Completion(content: content, toolCallsJSON: toolCallsJSON)
    }

    /// Anthropic's native Messages API. Marks the system prompt + tools with `cache_control` so that
    /// constant prefix (resent every turn) is billed at ~10% after the first call. Converts our
    /// OpenAI-shaped tools to Anthropic's `input_schema` form and normalizes the response back to the
    /// same `Completion` the caller expects.
    private func completeAnthropic(model: String, base: String, key: String?, temp: Double,
                                   system: String, user: String, maxTokens: Int,
                                   tools: String?, assistantPrefix: String?) async throws -> Completion {
        var req = URLRequest(url: try Self.url(base, "/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let key { req.setValue(key, forHTTPHeaderField: "x-api-key") }
        req.timeoutInterval = 60

        // System as a text block; cache it when it's big enough to be worth caching (Anthropic ignores
        // cache_control below its minimum, but we guard to keep small calls — e.g. the memory head — clean).
        var systemBlock: [String: Any] = ["type": "text", "text": system]
        let cacheSystem = system.utf8.count > 4000
        if cacheSystem { systemBlock["cache_control"] = ["type": "ephemeral"] }

        var messages: [[String: Any]] = [["role": "user", "content": user]]
        if let assistantPrefix, !assistantPrefix.isEmpty {
            messages.append(["role": "assistant", "content": assistantPrefix])
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temp,
            "system": [systemBlock],
            "messages": messages,
        ]

        // Convert OpenAI tools -> Anthropic tools; one cache_control on the LAST tool caches the whole
        // constant prefix (system + all tools), since the cache boundary is cumulative.
        if let tools, let parsed = try? JSONSerialization.jsonObject(with: Data(tools.utf8)) as? [[String: Any]] {
            var atools: [[String: Any]] = []
            for t in parsed {
                guard let fn = t["function"] as? [String: Any], let name = fn["name"] as? String else { continue }
                var at: [String: Any] = ["name": name]
                if let desc = fn["description"] as? String { at["description"] = desc }
                at["input_schema"] = (fn["parameters"] as? [String: Any]) ?? ["type": "object", "properties": [:]]
                atools.append(at)
            }
            if !atools.isEmpty {
                atools[atools.count - 1]["cache_control"] = ["type": "ephemeral"]
                body["tools"] = atools
                body["tool_choice"] = ["type": "any"]   // force a tool call (== OpenAI "required")
            }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw Error.http("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(snippet)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { throw Error.badResponse }

        var text = ""
        var toolCalls: [[String: Any]] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                text += (block["text"] as? String) ?? ""
            case "tool_use":
                if let name = block["name"] as? String {
                    let input = (block["input"] as? [String: Any]) ?? [:]
                    let argStr = (try? JSONSerialization.data(withJSONObject: input))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    toolCalls.append(["name": name, "arguments": argStr])
                }
            default:
                break
            }
        }
        var toolCallsJSON: String? = nil
        if !toolCalls.isEmpty, let d = try? JSONSerialization.data(withJSONObject: toolCalls) {
            toolCallsJSON = String(data: d, encoding: .utf8)
        }
        // Accumulate real usage so the pilot can show spend + confirm caching (cache_read > 0).
        if let u = json["usage"] as? [String: Any] {
            lock.lock()
            accIn += (u["input_tokens"] as? Int) ?? 0
            accOut += (u["output_tokens"] as? Int) ?? 0
            accCacheRead += (u["cache_read_input_tokens"] as? Int) ?? 0
            accCacheWrite += (u["cache_creation_input_tokens"] as? Int) ?? 0
            lock.unlock()
        }
        return Completion(content: text, toolCallsJSON: toolCallsJSON)
    }

    // Cumulative token usage (this session) for cost reporting.
    private var accIn = 0, accOut = 0, accCacheRead = 0, accCacheWrite = 0
    /// (input, output, cache_read, cache_write) tokens accumulated since the last reset.
    func usageCounts() -> (Int, Int, Int, Int) {
        lock.lock(); defer { lock.unlock() }; return (accIn, accOut, accCacheRead, accCacheWrite)
    }
    func resetUsage() { lock.lock(); accIn = 0; accOut = 0; accCacheRead = 0; accCacheWrite = 0; lock.unlock() }

    private func resolveModel() async throws -> String {
        lock.lock()
        if let m = resolvedModel { lock.unlock(); return m }
        if let m = configuredModel { resolvedModel = m; lock.unlock(); return m }
        let base = baseURL
        lock.unlock()

        let (data, _) = try await URLSession.shared.data(from: try Self.url(base, "/models"))
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let arr = json["data"] as? [[String: Any]],
            let id = arr.first?["id"] as? String
        else { throw Error.noModel }
        lock.lock(); resolvedModel = id; lock.unlock()
        return id
    }

    private static func url(_ base: String, _ path: String) throws -> URL {
        guard let u = URL(string: base + path) else { throw Error.badURL(base) }
        return u
    }

    enum Error: LocalizedError {
        case http(String), badResponse, noModel, badURL(String)
        var errorDescription: String? {
            switch self {
            case .http(let s): return s
            case .badResponse: return "unexpected response shape"
            case .noModel: return "no model reported by /v1/models — load one in LM Studio"
            case .badURL(let s): return "bad base URL: \(s)"
            }
        }
    }
}
