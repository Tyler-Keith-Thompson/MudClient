//
//  AIPilotService.swift
//  MudClient
//
//  A bridge from the live MUD session to a local LLM served by LM Studio (or any
//  OpenAI-compatible endpoint). It tails the visible server output into a rolling
//  transcript, and when output goes quiet (the "prompt/idle" signal) it sends the
//  transcript + the parsed game state (see KXWTHost) to the model and executes the
//  commands the model returns.
//
//  Design notes:
//   - Disabled by default. `#ai on` arms it; `#ai off` is the kill switch.
//   - Single in-flight request: it never starts a new turn while one is pending.
//   - Guardrails apply even in "full autonomous" mode: a minimum interval between
//     turns, a per-turn command cap, and a loop detector that disarms the pilot if
//     it starts repeating the same command (a classic stuck-LLM failure mode).
//   - Config via env: LMSTUDIO_BASE_URL (default http://localhost:1234/v1) and
//     LMSTUDIO_MODEL (default: first model reported by /v1/models).
//
//  The model's reply contract: put each MUD command on its own line prefixed with
//  `CMD:`. Any other text is treated as the model's reasoning and echoed dimmed to
//  the player. Example reply:
//      I'm low on mana, better rest before moving on.
//      CMD: rest
//

import DependencyInjection
import Foundation

final class AIPilotService: @unchecked Sendable {
    // MARK: - Config

    struct Config {
        var baseURL: String
        var model: String?          // nil => auto-discover via /v1/models
        var quietPeriod: TimeInterval = 0.75   // idle settle before a turn
        var minTurnInterval: TimeInterval = 2.0
        var maxCommandsPerTurn = 3
        var transcriptLines = 80
        var temperature = 0.6
        var maxTokens = 256
        var loopThreshold = 4       // identical commands in a row => disarm
        var humanGrace: TimeInterval = 4.0   // after you type, the pilot waits this long before acting
        var traceFile: String? = "ai-traces.jsonl"   // on by default; nil = off

        static func fromEnvironment() -> Config {
            let env = ProcessInfo.processInfo.environment
            var c = Config(
                baseURL: env["LMSTUDIO_BASE_URL"] ?? "http://localhost:1234/v1",
                model: env["LMSTUDIO_MODEL"]
            )
            if let t = env["AI_TRACE_FILE"] { c.traceFile = t.isEmpty ? nil : t }
            return c
        }
    }

    // MARK: - State (guarded by `lock`)

    private let lock = NSRecursiveLock()
    private var config = Config.fromEnvironment()
    private var enabled = false
    private var busy = false
    private var goal = "Play the character well: survive, recover when hurt, and make steady progress."
    private var transcript: [String] = []
    private var lastTurn = Date.distantPast
    private var recentCommands: [String] = []
    private var loopBreaks = 0   // consecutive loop-breaks without a good turn between
    private var requestedScripts: Set<String> = []
    private var resolvedModel: String?
    private var inputSeq = 0   // bumped per observed line; see takeTurn backlog drain
    private var lastHumanInput = Date.distantPast
    private var pendingDirective: String?   // one-off `#ai tell` note, consumed next turn

    /// Debounce machinery. A turn fires only if no new activity arrived during the
    /// quiet period (generation token guards against stale timers).
    private let queue = DispatchQueue(label: "ai.pilot.debounce")
    private var generation = 0

    fileprivate init() {}

    // MARK: - Ingest (called from the output pipeline)

    /// Feed one visible server line into the rolling transcript.
    func observe(_ line: String) {
        let clean = Self.stripANSI(line).trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        lock.lock()
        transcript.append(clean)
        inputSeq &+= 1   // monotonic; lets a finishing turn detect output it didn't see
        if transcript.count > config.transcriptLines {
            transcript.removeFirst(transcript.count - config.transcriptLines)
        }
        lock.unlock()
    }

    /// A command YOU typed (not one the pilot or a script sent). Recorded in the
    /// transcript so the model knows you acted, and it starts a short grace window
    /// during which the pilot defers to you instead of countermanding your move.
    func noteUserCommand(_ command: String) {
        let c = command.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, !c.hasPrefix("#") else { return }   // ignore client commands like #ai
        lock.lock()
        transcript.append("[you typed] \(c)")
        inputSeq &+= 1
        lastHumanInput = Date()
        if transcript.count > config.transcriptLines {
            transcript.removeFirst(transcript.count - config.transcriptLines)
        }
        lock.unlock()
    }

    /// The character actually moved to a different room (KXWT rvnum changed). Drop a
    /// hard boundary into the transcript so the model stops acting on creatures/items
    /// that were in the room it just left.
    func noteRoomChange() {
        lock.lock()
        transcript.append("--- [MOVED to a NEW room. Everything above is a PREVIOUS room — creatures and items there are gone; act only on what's below.] ---")
        inputSeq &+= 1
        if transcript.count > config.transcriptLines {
            transcript.removeFirst(transcript.count - config.transcriptLines)
        }
        lock.unlock()
    }

    /// Server output arrived; (re)start the idle countdown. A turn fires once the
    /// stream settles for `quietPeriod`.
    func noteActivity() {
        lock.lock()
        let armed = enabled
        let quiet = config.quietPeriod
        generation += 1
        let token = generation
        lock.unlock()
        guard armed else { return }
        queue.asyncAfter(deadline: .now() + quiet) { [weak self] in
            self?.fireIfReady(token: token)
        }
    }

    private func fireIfReady(token: Int) {
        lock.lock()
        if token != generation { lock.unlock(); return }   // newer activity superseded us
        let now = Date()
        let graceLeft = config.humanGrace - now.timeIntervalSince(lastHumanInput)
        let throttled = now.timeIntervalSince(lastTurn) < config.minTurnInterval
        let canRun = enabled && !busy && graceLeft <= 0 && !throttled
        if canRun { busy = true }
        let deferring = enabled && !busy && graceLeft > 0
        lock.unlock()

        if canRun {
            Task { await self.takeTurn() }
        } else if deferring {
            // You just acted — wait out the grace window, then re-check.
            queue.asyncAfter(deadline: .now() + graceLeft + 0.05) { [weak self] in
                self?.fireIfReady(token: token)
            }
        }
    }

    // MARK: - Control surface (`#ai ...`)

    func command(_ raw: String) {
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts.first?.lowercased() ?? "status"
        let rest = parts.count > 1 ? parts[1] : ""
        switch verb {
        case "", "status": echoStatus()
        case "on", "start": setEnabled(true)
        case "off", "stop": setEnabled(false)
        case "once", "go", "step": forceTurn()
        case "reload": Container.scriptInterpreter().reload()
        case "goal":
            lock.lock(); goal = rest.isEmpty ? goal : rest; let g = goal; lock.unlock()
            echo("[ai] goal: \(g)")
        case "model":
            lock.lock(); config.model = rest.isEmpty ? nil : rest; resolvedModel = nil; lock.unlock()
            echo("[ai] model: \(rest.isEmpty ? "(auto)" : rest)")
        case "url":
            lock.lock(); if !rest.isEmpty { config.baseURL = rest }; let u = config.baseURL; lock.unlock()
            echo("[ai] endpoint: \(u)")
        case "tell", "say", "nudge":
            guard !rest.isEmpty else { echo("[ai] usage: #ai tell <one-off instruction for the next turn>"); return }
            lock.lock(); pendingDirective = rest; let armed = enabled; lock.unlock()
            echo("[ai] director note (next turn): \(rest)")
            if armed { noteActivity() } else { echo("[ai] (idle — #ai on to act on it)") }
        case "trace":
            lock.lock()
            switch rest.lowercased() {
            case "": break
            case "off": config.traceFile = nil
            case "on": config.traceFile = "ai-traces.jsonl"
            default: config.traceFile = rest
            }
            let p = config.traceFile
            lock.unlock()
            echo("[ai] trace logging: \(p ?? "off")")
        default:
            echo("[ai] commands: on | off | once | reload | status | goal <text> | tell <text> | model <name> | url <base> | trace [on|off|<path>]")
        }
    }

    private func setEnabled(_ on: Bool) {
        lock.lock(); enabled = on; if on { recentCommands.removeAll() }; lock.unlock()
        echo(on ? "[ai] armed — the local model is now driving. `#ai off` to stop." : "[ai] disengaged.")
        if on { noteActivity() }
    }

    private func forceTurn() {
        lock.lock()
        let canRun = !busy
        if canRun { busy = true }
        lock.unlock()
        guard canRun else { echo("[ai] busy; try again in a moment."); return }
        Task { await takeTurn() }
    }

    private func echoStatus() {
        lock.lock()
        let s = """
        [ai] \(enabled ? "ARMED" : "idle") | endpoint=\(config.baseURL) \
        model=\(resolvedModel ?? config.model ?? "(auto)") | trace=\(config.traceFile ?? "off") | defers \(Int(config.humanGrace))s after you type | goal=\(goal)
        """
        lock.unlock()
        echo(s)
    }

    // MARK: - A turn

    private func takeTurn() async {
        // Backlog drain: if the game streamed more output while we were thinking
        // (inputSeq advanced past the snapshot we acted on), re-arm once we're done
        // so the next settle picks up everything that batched up mid-request.
        var snapSeq = 0
        defer {
            lock.lock()
            busy = false
            lastTurn = Date()
            let more = enabled && inputSeq != snapSeq
            lock.unlock()
            if more { noteActivity() }
        }

        let messages: [[String: String]]
        lock.lock()
        // Show only the CURRENT room's output (everything from the last room-change
        // marker on). This deterministically stops the model anchoring on creatures or
        // instructions from a room it already left — a reasoning trap a 14B won't escape
        // on its own, no matter what the prompt says.
        let recent = transcript.suffix(config.transcriptLines)
        let convoLines = recent.lastIndex(where: { $0.contains("MOVED to a NEW room") })
            .map { Array(recent[$0...]) } ?? Array(recent)
        let convo = convoLines.joined(separator: "\n")
        let theGoal = goal
        let directive = pendingDirective
        pendingDirective = nil
        snapSeq = inputSeq
        lock.unlock()
        let state = Container.kxwtHost().summary()

        let directiveBlock = directive.map {
            "\n=== DIRECTOR NOTE (one-off, the human just told you this — act on it now) ===\n\($0)\n"
        } ?? ""

        messages = [
            ["role": "system", "content": Self.systemPrompt(goal: theGoal)],
            ["role": "user", "content": """
            === CHARACTER STATE ===
            \(state)

            === RECENT GAME OUTPUT ===
            \(convo)
            \(directiveBlock)
            Decide what to do now. Reply with brief reasoning, then each command on \
            its own line prefixed with `CMD:`. Send at most \(self.config.maxCommandsPerTurn) commands.
            """]
        ]

        do {
            let reply = try await complete(messages: messages)
            logTrace(messages: messages, reply: reply)
            handleReply(reply)
        } catch {
            echo("[ai] request failed: \(error.localizedDescription). Is LM Studio's server running? (\(config.baseURL))")
        }
    }

    private func handleReply(_ reply: String) {
        var commands: [String] = []
        var thoughts: [String] = []
        var scriptRequests: [String] = []
        for line in reply.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: #"^SCRIPT\s*:?\s*"#, options: [.regularExpression, .caseInsensitive]) {
                let req = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !req.isEmpty { scriptRequests.append(req) }
            } else if let r = t.range(of: #"^(CMD|cmd|>)\s*:?\s*"#, options: .regularExpression) {
                var cmd = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                while cmd.hasSuffix(".") { cmd.removeLast() }   // models sometimes write "get all corpse."
                cmd = cmd.trimmingCharacters(in: .whitespaces)
                if !cmd.isEmpty { commands.append(cmd) }
            } else if !t.isEmpty {
                thoughts.append(t)
            }
        }

        if !thoughts.isEmpty { echo("[ai] " + thoughts.joined(separator: " ")) }
        for req in scriptRequests.prefix(1) { requestScriptChange(req) }   // at most one new rule per turn

        lock.lock()
        let cap = config.maxCommandsPerTurn
        let threshold = config.loopThreshold
        commands = Array(commands.prefix(cap))
        // Loop detection: count trailing identical commands across turns.
        for c in commands {
            if recentCommands.last == c { recentCommands.append(c) }
            else { recentCommands = [c] }
        }
        let loopCmd = recentCommands.last ?? ""
        let looping = recentCommands.count >= threshold
        var disarm = false
        if looping {
            loopBreaks += 1
            recentCommands.removeAll()
            if loopBreaks >= 2 {
                disarm = true               // ignored the nudge — really stuck
                enabled = false
            } else {
                // Break the loop WITHOUT stopping: steer it to try something else.
                pendingDirective = "You've repeated `\(loopCmd)` with no progress — it isn't working (e.g. a blocked exit or wrong target). Do NOT repeat it; try a different action."
            }
        } else if !commands.isEmpty {
            loopBreaks = 0
        }
        lock.unlock()

        if commands.isEmpty {
            echo("[ai] (no command this turn)")
            return
        }

        if looping {
            if disarm {
                echo("[ai] still repeating `\(loopCmd)` after a nudge — disarming. `#ai on` to resume.")
            } else {
                echo("[ai] `\(loopCmd)` isn't working — nudging it to try something else.")
                noteActivity()              // re-arm so it acts on the correction
            }
            return
        }

        // If you hit `#ai off` while this turn was in flight, honor it: don't send.
        lock.lock(); let armed = enabled; lock.unlock()
        guard armed else {
            echo("[ai] (disengaged mid-turn — withheld: \(commands.joined(separator: ", ")))")
            return
        }

        for c in commands {
            echo("[ai] > \(c)")
            try? Container.inputService().send(verbatim: c)
        }
    }

    // MARK: - HTTP (OpenAI-compatible /chat/completions)

    private func complete(messages: [[String: String]]) async throws -> String {
        let model = try await resolveModel()
        var req = URLRequest(url: try url("/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
            "stream": false,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw PilotError.http("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(snippet)")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw PilotError.badResponse }
        return content
    }

    /// Resolve and cache the model id. If none configured, pick the first one the
    /// server reports loaded.
    private func resolveModel() async throws -> String {
        lock.lock()
        if let m = resolvedModel { lock.unlock(); return m }
        if let m = config.model { resolvedModel = m; lock.unlock(); return m }
        lock.unlock()

        let (data, _) = try await URLSession.shared.data(from: try url("/models"))
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let arr = json["data"] as? [[String: Any]],
            let id = arr.first?["id"] as? String
        else { throw PilotError.noModel }
        lock.lock(); resolvedModel = id; lock.unlock()
        return id
    }

    private func url(_ path: String) throws -> URL {
        guard let u = URL(string: config.baseURL + path) else { throw PilotError.badURL(config.baseURL) }
        return u
    }

    enum PilotError: LocalizedError {
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

    // MARK: - Script-edit delegation

    /// The model asked for a *persistent* automation (a new trigger/alias/gag).
    /// We don't let the local model rewrite Lua directly — instead the request is
    /// (1) appended to an inbox file for review, and (2) optionally handed to a
    /// developer agent (e.g. headless Claude Code) that edits Scripts/AlterAeon.lua,
    /// after which the script is hot-reloaded.
    ///
    /// Set the agent via env, e.g.:
    ///   export AI_SCRIPT_AGENT='claude -p "Edit $AI_SCRIPT_FILE to satisfy: $AI_SCRIPT_REQUEST. Only add trigger()/alias()/gag() using existing builtins; keep it valid Lua." --permission-mode acceptEdits'
    /// When unset, requests just queue + notify (so a human/Claude can apply them).
    private static let inboxPath = "Scripts/.ai-script-requests.jsonl"
    private static let scriptPath = "Scripts/AlterAeon.lua"

    private func requestScriptChange(_ request: String) {
        // Don't resubmit the same standing-rule request; the edit+reload cycle is
        // slow and the model may keep asking until it sees the reflex take effect.
        let key = request.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        let seen = requestedScripts.contains(key)
        if !seen { requestedScripts.insert(key) }
        lock.unlock()
        guard !seen else { return }

        appendToInbox(request)
        echo("[ai] ✎ requested a script change: \"\(request)\" (queued in \(Self.inboxPath))")

        guard let agent = ProcessInfo.processInfo.environment["AI_SCRIPT_AGENT"], !agent.isEmpty else {
            echo("[ai]   no AI_SCRIPT_AGENT set — apply it yourself, then `#ai reload`.")
            return
        }
        echo("[ai]   delegating to script agent…")
        runScriptAgent(agent, request: request)
    }

    private func appendToInbox(_ request: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        lock.lock()
        let recent = transcript.suffix(25).joined(separator: "\n")
        lock.unlock()
        let obj: [String: Any] = [
            "time": stamp,
            "request": request,
            "state": Container.kxwtHost().summary(),
            "recent_output": recent,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = URL(fileURLWithPath: Self.inboxPath)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Run the configured agent command via `/bin/sh -c`, passing the request and
    /// target file through the environment. On success, hot-reload the script.
    private func runScriptAgent(_ command: String, request: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        proc.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var env = ProcessInfo.processInfo.environment
        env["AI_SCRIPT_REQUEST"] = request
        env["AI_SCRIPT_FILE"] = Self.scriptPath
        proc.environment = env
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                if p.terminationStatus == 0 {
                    self?.echo("[ai]   script agent finished — reloading.")
                    Container.scriptInterpreter().reload()
                } else {
                    self?.echo("[ai]   script agent exited \(p.terminationStatus); change not applied.")
                }
            }
        }
        do { try proc.run() } catch { echo("[ai]   couldn't launch script agent: \(error.localizedDescription)") }
    }

    // MARK: - Trace logging (fine-tuning corpus)

    /// If AI_TRACE_FILE is set, append each turn as a chat-format JSONL row
    /// ({"messages":[...]} including the assistant reply). This is raw material for
    /// a control-behavior fine-tune — curate/filter for GOOD turns before training.
    private func logTrace(messages: [[String: String]], reply: String) {
        lock.lock(); let path = config.traceFile; lock.unlock()
        guard let path, !path.isEmpty else { return }
        var rows = messages
        rows.append(["role": "assistant", "content": reply])
        guard let data = try? JSONSerialization.data(withJSONObject: ["messages": rows]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    // MARK: - Helpers

    private func echo(_ s: String) { Container.terminalService().print(s) }

    private static func systemPrompt(goal: String) -> String {
        """
        You are an expert player of the text MUD Alter Aeon, driving a character live \
        through a terminal client. You receive the character's parsed state and the \
        most recent game output, and you respond with two kinds of directives:

          CMD: <raw mud command>      — do this ONE thing right now (a judgment call)
          SCRIPT: <plain description> — create a STANDING RULE in the client's script

        Your current goal: \(goal)

        ## CMD is your default. SCRIPT is the rare exception for RECURRING reflexes.

        Almost everything you do is a `CMD:`. A `SCRIPT:` creates a PERMANENT standing
        rule, so request one ONLY for a pattern you will face again and again where the
        response is always identical. One-time things — tutorial steps, intro prompts,
        unique NPC dialog, a specific quest action, story beats — happen ONCE, so handle
        them with `CMD:` and NEVER script them.

        Before any `SCRIPT:`, ALL of these must be true:
          1. It will RECUR many times (not a one-off event).
          2. The response is ALWAYS the same, with zero judgment.
          3. You have actually SEEN the pattern happen — don't script hypotheticals.
        If any one is false, use `CMD:`.

        Good SCRIPT candidates (rare): "loot every corpse after a kill: get all corpse",
        "flee whenever health drops below 30%". That's about it for most sessions.
        Do NOT script: tutorial/intro steps, one-time messages, quest-specific actions,
        or anything you're merely guessing might repeat.

        At most ONE `SCRIPT:` per turn, and only when it clearly earns a permanent rule.
        Scripts can match game lines (triggers), match your typed input (aliases), hide
        lines (gags), and send commands; describe the rule in plain English and a
        developer agent writes the Lua.

        CMD these (need judgment): which way to explore, whether to engage or avoid a \
        specific mob, when to retreat strategically, quest/spend/training choices.

        ## Output rules
        - First, one short line of reasoning.
        - Then your directives, each on its own line (`CMD:` and/or `SCRIPT:` lines).
        - Raw commands look like: n/s/e/w/u/d, `look`, `kill <mob>`, \
        `cast '<spell>' <target>`, `get all corpse`, `rest`, `sleep`, `stand`.
        - Don't spam: at most a couple of `CMD:`s per turn.
        - If a reflex you already requested hasn't taken effect yet, don't re-request it.
        - If there's nothing worth doing, reply with reasoning and NO directives.
        - Never invent output you didn't see. Base decisions only on the state and log.
        - If the game gives an explicit instruction (a tutorial/help prompt telling you \
        to cast a spell, type a command, go somewhere), FOLLOW it — don't wander off.
        - If a command just failed ("Alas, you cannot go that way", "you can't"), do NOT \
        repeat it. Pick a different exit or action. Repeating a failed command is useless.
        - Act on your CURRENT room only — the most recent room description. A line reading \
        "MOVED to a NEW room" means everything above it is a PAST room; creatures and \
        items there are GONE. Never cast at or attack something from a room you've left.
        - Finish what a room demands BEFORE leaving it. If a creature blocks your way and \
        the game says to fight/cast on it, do that FIRST — do not walk off and leave it.
        - To attack or cast on a creature you must be in the SAME room as it. If it was in \
        a room you left (above a "MOVED to a NEW room" line, or any earlier room), the \
        cast will FAIL from here — MOVE back toward that room first (e.g. reverse your \
        last step), THEN cast once you're there. "isn't a valid target" / "isn't here" \
        means the creature is not in your current room.

        Co-driving: a human is sharing control of this character. Lines marked \
        `[you typed]` are commands the HUMAN just issued. Respect their intent — \
        continue or support what they're doing; do not undo or fight their moves.
        """
    }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*[A-Za-z]")
    static func stripANSI(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return ansi.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
}

extension Container {
    static let aiPilot = Factory(scope: .cached) { AIPilotService() }
}
