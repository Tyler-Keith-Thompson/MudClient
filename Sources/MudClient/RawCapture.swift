//
//  RawCapture.swift
//  MudClient
//
//  Env-gated capture of the raw server byte stream, for faithful offline replay when
//  debugging the IAC/MSP/gag pipeline. Enable by launching with MUD_RAW_LOG set:
//
//      MUD_RAW_LOG=/tmp/mud_raw.log just run
//
//  Each network chunk is written as one base64 line, preserving exact chunk boundaries
//  (so a replay reproduces the same streaming fragmentation that triggers buffer bugs).
//  The file is a ring buffer capped at the last `keep` chunks so it never grows without
//  bound. Off entirely when the env var is unset.
//

import Afluent
import Foundation

final class RawCapture: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var sinceTrim = 0
    private static let keep = 1000

    init?() {
        // On by default to `mud_raw.log` (ring-buffered, so bounded) — a capture is always ready
        // for debugging without fiddling with env vars. Override the path with MUD_RAW_LOG, or
        // disable entirely with MUD_RAW_LOG=off (or "").
        let env = ProcessInfo.processInfo.environment["MUD_RAW_LOG"]
        if env == "" || env?.lowercased() == "off" { return nil }
        url = URL(fileURLWithPath: env ?? "mud_raw.log")
        try? Data().write(to: url)   // start each session fresh
    }

    func record(_ data: Data) {
        let line = Data((data.base64EncodedString() + "\n").utf8)
        lock.lock(); defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(line); try? handle.close()
        } else {
            try? line.write(to: url)
        }
        sinceTrim += 1
        if sinceTrim >= Self.keep { trim(); sinceTrim = 0 }
    }

    /// Keep only the last `keep` lines.
    private func trim() {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > Self.keep else { return }
        let kept = lines.suffix(Self.keep).joined(separator: "\n") + "\n"
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }
}

extension AsyncSequence where Self: Sendable, Element == Data {
    /// Tap the raw byte stream to MUD_RAW_LOG (no-op when the env var is unset).
    func captureRaw() -> AnyAsyncSequence<Data> {
        let capture = RawCapture()
        return map { data in
            capture?.record(data)
            return data
        }
        .eraseToAnyAsyncSequence()
    }
}

/// Collapses every line-ending convention — CRLF, lone CR (classic Mac), and LF — to a single
/// LF, statefully across chunk boundaries. This is a generic MUD client, not AlterAeon-specific,
/// so we don't assume CRLF. Iterating Unicode scalars (not Characters) is essential: Swift fuses
/// "\r\n" into ONE Character, which is exactly the trap that made `firstIndex(of: "\n")` silently
/// miss CRLF lines downstream. A trailing CR is held as `pendingCR` until the next chunk so a CRLF
/// split across two TCP reads becomes one LF, not two.
final class LineEndingNormalizer: @unchecked Sendable {
    private var pendingCR = false

    func normalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            if pendingCR {
                pendingCR = false
                out.append("\n")              // the CR ended a line
                if scalar == "\n" { continue } // CRLF: absorb the following LF
            }
            if scalar == "\r" { pendingCR = true }   // wait to see if an LF follows
            else { out.append(scalar) }
        }
        return String(out)
    }
}

extension AsyncSequence where Self: Sendable, Element == String {
    /// Normalize CR/CRLF/LF to LF once, centrally, right after IAC decoding, so no downstream
    /// code can hit Swift's "\r\n is one grapheme" trap when splitting/searching on "\n".
    func normalizeLineEndings() -> AnyAsyncSequence<String> {
        let normalizer = LineEndingNormalizer()
        return map { normalizer.normalize($0) }.eraseToAnyAsyncSequence()
    }
}

