//
//  RAGRetriever.swift
//  MudClient
//
//  Generic retrieval over a prebuilt embedding index (tools/finetune/build_rag_index.py). Loads
//  [{text, vec}] from disk, embeds a query against the same LOCAL embedding model, and returns the
//  top-k most similar chunks by cosine similarity. The pilot uses it to hand the decision model the
//  game's own documentation relevant to the current situation — knowledge on demand, not hardcoded.
//

import Foundation

final class RAGRetriever: @unchecked Sendable {
    private struct Chunk { let text: String; let vec: [Float] }
    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private let embedURL: String
    private let embedModel: String

    init() {
        let env = ProcessInfo.processInfo.environment
        embedURL = env["LMSTUDIO_BASE_URL"] ?? "http://localhost:1234/v1"
        embedModel = env["EMB_MODEL"] ?? "text-embedding-nomic-embed-text-v1.5"
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return chunks.count }

    /// Load the index file (JSON array of {text, vec}). Silent no-op if missing/unreadable.
    func load(path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        var loaded: [Chunk] = []
        loaded.reserveCapacity(arr.count)
        for item in arr {
            guard let text = item["text"] as? String, let raw = item["vec"] as? [Any] else { continue }
            let vec = raw.compactMap { ($0 as? NSNumber)?.floatValue }
            if !vec.isEmpty { loaded.append(Chunk(text: text, vec: vec)) }
        }
        lock.lock(); chunks = loaded; lock.unlock()
    }

    /// Embed `query` and return the `k` most similar chunk texts. Empty if the index is unloaded.
    func retrieve(query: String, k: Int) async throws -> [String] {
        lock.lock(); let snapshot = chunks; lock.unlock()
        if snapshot.isEmpty { return [] }
        guard let qvec = try await embed(["search_query: " + query]).first, !qvec.isEmpty else { return [] }
        let qn = norm(qvec) + 1e-8
        var scored: [(Float, Int)] = []
        scored.reserveCapacity(snapshot.count)
        for (i, c) in snapshot.enumerated() {
            scored.append((dot(qvec, c.vec) / (qn * (norm(c.vec) + 1e-8)), i))
        }
        scored.sort { $0.0 > $1.0 }
        return scored.prefix(max(0, k)).map { snapshot[$0.1].text }
    }

    private func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let url = URL(string: embedURL + "/embeddings") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": embedModel, "input": texts])
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { ($0["embedding"] as? [Any])?.compactMap { ($0 as? NSNumber)?.floatValue } }
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0; let n = min(a.count, b.count)
        var i = 0; while i < n { s += a[i] * b[i]; i += 1 }
        return s
    }
    private func norm(_ a: [Float]) -> Float { dot(a, a).squareRoot() }
}
