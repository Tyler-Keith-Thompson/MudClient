//
//  DocCoverageTests.swift
//  MudClientTests
//
//  Source-scanning enforcement that the Lua-visible host surface stays documented. The runtime side
//  (every registered builtin, every public-table member) is enforced by Scripts/tests/
//  doc_coverage_spec.lua against the live doc registry; these tests close the two gaps a Lua spec
//  can't see — call sites that only exist in Swift:
//    * every `on_*` hook the host consults via callGlobal/callGlobalBool/callGlobalReturning must
//      have a doc() entry in bootstrap.lua's hooks group;
//    * every `lua.register("…")` builtin name must appear as a doc() target in bootstrap.lua
//      (directly, or as its dotted table-member form — panel_render is documented as panel.render).
//  Adding a hook or builtin in Swift without documenting it fails these tests BY NAME.
//

import DependencyInjection
import Foundation
import Testing

/// Repo-root-relative path resolution that works both from a checkout and from Bazel runfiles
/// (the sources are in the test's `data`, laid out under the same relative paths).
private func repoFile(_ rel: String, file: StaticString = #filePath) -> String {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(rel).path
}

/// Every Swift source in Sources/MudClient, concatenated (name -> contents).
private func swiftSources() throws -> [String: String] {
    let dir = repoFile("Sources/MudClient")
    let names = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".swift") }
    #expect(!names.isEmpty, "no Swift sources found at \(dir) — runfiles data missing?")
    var out: [String: String] = [:]
    for n in names {
        out[n] = try String(contentsOfFile: dir + "/" + n, encoding: .utf8)
    }
    return out
}

private func bootstrapSource() throws -> String {
    try String(contentsOfFile: repoFile("Scripts/bootstrap.lua"), encoding: .utf8)
}

@Test func hookDocsCoverSwiftCallSites() throws {
  try withTestContainer {
    // Collect every distinct on_* hook name the host consults from Lua-global call sites.
    let callSite = try Regex(#"callGlobal\w*\(\s*"(on_[a-z_]+)""#)
    var hooks: Set<String> = []
    for (_, src) in try swiftSources() {
        for m in src.matches(of: callSite) {
            if let name = m.output[1].substring { hooks.insert(String(name)) }
        }
    }
    #expect(hooks.count >= 9, "hook scan looks broken — found only \(hooks.sorted())")

    // Each must be documented in bootstrap.lua's hooks group: a doc("<hook>", …) entry whose info
    // carries group = "hooks".
    let bootstrap = try bootstrapSource()
    var missing: [String] = []
    for hook in hooks.sorted() {
        guard let entryStart = bootstrap.range(of: "doc(\"\(hook)\"") else {
            missing.append(hook)
            continue
        }
        // The entry's info table must be tagged hooks (look within the entry's line).
        let tail = bootstrap[entryStart.lowerBound...].prefix(while: { $0 != "\n" })
        if !tail.contains("group = \"hooks\"") { missing.append(hook + " (not in group \"hooks\")") }
    }
    #expect(missing.isEmpty, """
        Swift consults hooks that Scripts/bootstrap.lua does not document: \(missing.joined(separator: ", ")).
        Add doc("<hook>", { sig = …, text = …, group = "hooks" }) entries for them.
        """)
  }
}

@Test func builtinDocsCoverSwiftRegistrations() throws {
  try withTestContainer {
    // Every lua.register("name") in the engine must be a doc() target in bootstrap.lua — by its own
    // name, or (for raw registrations wrapped into a table, like panel_render) by its dotted form.
    let registration = try Regex(#"lua\.register\(\s*"([A-Za-z0-9_]+)""#)
    var names: Set<String> = []
    for (_, src) in try swiftSources() {
        for m in src.matches(of: registration) {
            if let name = m.output[1].substring { names.insert(String(name)) }
        }
    }
    #expect(names.count >= 40, "builtin scan looks broken — found only \(names.count) registrations")

    let bootstrap = try bootstrapSource()
    var missing: [String] = []
    for name in names.sorted() where !name.hasPrefix("__") {
        if bootstrap.contains("doc(\"\(name)\"") { continue }
        // panel_render -> "panel.render", panel_top_height -> "panel.top_height", music_play -> …
        if let us = name.firstIndex(of: "_") {
            let dotted = name[..<us] + "." + name[name.index(after: us)...]
            if bootstrap.contains("\"\(dotted)\"") { continue }
        }
        missing.append(name)
    }
    #expect(missing.isEmpty, """
        Host builtins registered in Swift but not documented in Scripts/bootstrap.lua: \
        \(missing.joined(separator: ", ")). Add doc() entries (see THE RULE banner in bootstrap.lua).
        """)
  }
}
