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
    /// Identity of the index currently loaded (chosen path + size + mtime). A hot `#ai reload` calls
    /// load() again with the same unchanged file — this lets us skip re-parsing 69MB every time.
    private var loadedKey: String?
    private let embedURL: String
    private let embedModel: String

    init() {
        let env = ProcessInfo.processInfo.environment
        embedURL = env["LMSTUDIO_BASE_URL"] ?? "http://localhost:1234/v1"
        embedModel = env["EMB_MODEL"] ?? "text-embedding-nomic-embed-text-v1.5"
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return chunks.count }

    /// Load the index. Prefers a binary `.bin` sibling (built by build_rag_index.py) — a flat
    /// [magic|version|count|dim][texts][float32 block] that loads with one bulk copy — and falls
    /// back to the legacy JSON `[{text, vec}]`. Silent no-op if missing/unreadable.
    ///
    /// Parsing runs off-thread so a hot `#ai reload` never stalls line processing (the caller holds
    /// the engine lock while a script runs, and this fires from that script's top level). An index
    /// whose file is unchanged since the last load is skipped entirely.
    func load(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        // Prefer the binary sibling (same basename, `.bin`); fall back to the given (JSON) path.
        let binPath = (expanded as NSString).deletingPathExtension + ".bin"
        let fm = FileManager.default
        let chosen = fm.fileExists(atPath: binPath) ? binPath : expanded
        guard let attrs = try? fm.attributesOfItem(atPath: chosen),
              let size = attrs[.size] as? Int else { return }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(chosen)|\(size)|\(mtime)"
        lock.lock()
        if key == loadedKey, !chunks.isEmpty { lock.unlock(); return }   // unchanged — nothing to do
        lock.unlock()
        let isBinary = (chosen == binPath)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self,
                  let loaded = isBinary ? Self.loadBinary(chosen) : Self.loadJSON(chosen) else { return }
            self.install(loaded, key: key)
        }
    }

    private func install(_ loaded: [Chunk], key: String) {
        lock.lock(); chunks = loaded; loadedKey = key; lock.unlock()
    }

    /// Legacy path: JSON array of {text, vec}. Slow (boxes every float through NSNumber) — kept only
    /// so an old index without a `.bin` still works.
    private static func loadJSON(_ path: String) -> [Chunk]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var loaded: [Chunk] = []
        loaded.reserveCapacity(arr.count)
        for item in arr {
            guard let text = item["text"] as? String, let raw = item["vec"] as? [Any] else { continue }
            let vec = raw.compactMap { ($0 as? NSNumber)?.floatValue }
            if !vec.isEmpty { loaded.append(Chunk(text: text, vec: vec)) }
        }
        return loaded
    }

    /// Fast path: the flat binary index. Layout (all integers little-endian, which is native on macOS):
    ///   "RAGI" | u32 version(=1) | u32 count | u32 dim
    ///   count × [ u32 byteLen | UTF-8 text ]
    ///   count × dim × float32          (one contiguous block — read with a single memcpy)
    private static func loadBinary(_ path: String) -> [Chunk]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Chunk]? in
            guard raw.count >= 16,
                  raw[0] == 0x52, raw[1] == 0x41, raw[2] == 0x47, raw[3] == 0x49 else { return nil } // "RAGI"
            var off = 4
            func readU32() -> Int? {
                guard off + 4 <= raw.count else { return nil }
                let v = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self))
                off += 4
                return Int(v)
            }
            guard let version = readU32(), version == 1,
                  let count = readU32(), let dim = readU32() else { return nil }
            var texts: [String] = []
            texts.reserveCapacity(count)
            for _ in 0..<count {
                guard let len = readU32(), off + len <= raw.count else { return nil }
                let bytes = UnsafeRawBufferPointer(rebasing: raw[off..<off + len])
                texts.append(String(decoding: bytes, as: UTF8.self))
                off += len
            }
            let floatCount = count * dim
            guard off + floatCount * 4 <= raw.count else { return nil }
            var floats = [Float](repeating: 0, count: floatCount)   // native float32; bulk-copy the block
            floats.withUnsafeMutableBytes { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[off..<off + floatCount * 4]))
            }
            var chunks: [Chunk] = []
            chunks.reserveCapacity(count)
            for i in 0..<count {
                let start = i * dim
                chunks.append(Chunk(text: texts[i], vec: Array(floats[start..<start + dim])))
            }
            return chunks
        }
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
