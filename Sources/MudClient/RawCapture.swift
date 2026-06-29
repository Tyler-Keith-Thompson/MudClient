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
        guard let path = ProcessInfo.processInfo.environment["MUD_RAW_LOG"], !path.isEmpty else { return nil }
        url = URL(fileURLWithPath: path)
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

extension AsyncSequence where Self: Sendable, Element == String {
    /// Normalize line endings to LF once, centrally, right after IAC decoding. Swift fuses
    /// "\r\n" into a single grapheme-cluster Character, so any `firstIndex(of: "\n")`,
    /// `contains("\n")`, or split-on-"\n" downstream silently misses CRLF-terminated lines
    /// (the MSP bug). Stripping \r (rather than mapping CRLF->LF) is correct even when a chunk
    /// boundary splits "\r" from "\n". Downstream display already expects \r-free text.
    func normalizeLineEndings() -> AnyAsyncSequence<String> {
        map { $0.replacingOccurrences(of: "\r", with: "") }.eraseToAnyAsyncSequence()
    }
}
