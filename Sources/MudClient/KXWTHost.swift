//
//  KXWTHost.swift
//  MudClient
//
//  AlterAeon's KXWT ("supported MUD client") protocol handling. This is the
//  swift-parsing machinery that used to live *inside* the compiled AlterAeon
//  script (Scripts/AlterAeon). It now lives on the host: parsing stays in Swift
//  (where the Parsing DSL belongs), and the Lua script just forwards `kxwt(...)`
//  payloads here via the `kxwt` builtin. The old `State` actor is now a plain,
//  synchronously-accessed class — Lua dispatch is single-threaded and already
//  serialized by LuaScriptEngine's lock.
//

import DependencyInjection
import Foundation
import Parsing

/// Sync bridge to the client's IO, mirroring the old ScriptContext.
struct HostScriptContext {
    func send(_ message: String) { try? Container.inputService().send(verbatim: message) }
    func echo(_ message: String) { Container.terminalService().print(message) }
}

// MARK: - Models (parsers are context-free; copied verbatim from the old script)

struct Room {
    let id: Int
    let xSize: Int
    let ySize: Int
    let coordinate: Coordinate
    let plane: UInt

    struct Coordinate {
        let x: Int
        let y: Int
        let z: Int
    }

    static var parser: some Parser<Substring, Room> {
        Parse {
            "rvnum"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
            Skip { Optionally { CharacterSet.whitespaces } }
            UInt.parser()
        }.map { vnum, xsize, ysize, xpos, ypos, zpos, plane in
            Room(id: vnum,
                 xSize: xsize,
                 ySize: ysize,
                 coordinate: .init(x: xpos, y: ypos, z: zpos),
                 plane: plane)
        }
    }
}

enum Terrain: Int {
    case NOTSET, BUILDING, TOWN, FIELD, LFOREST, TFOREST, DFOREST, SWAMP, PLATEAU,
         SANDY, MOUNTAIN, ROCK, DESERT, TUNDRA, BEACH, HILL, DUNES, JUNGLE, OCEAN,
         STREAM, RIVER, UNDERWATER, UNDERGROUND, AIR, ICE, LAVA, RUINS, CAVE, CITY,
         MARSH, WASTELAND, CLOUD, WATER, METAL, TAIGA, SEWER, SHADOW, CATACOMB, MIRE, CRYSTAL

    static var parser: some Parser<Substring, Terrain> {
        Parse {
            "terrain"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser().compactMap { Terrain(rawValue: $0) }
        }
    }
}

struct Prompt {
    let currentHealth: Int
    let maxHealth: Int
    let currentMana: Int
    let maxMana: Int
    let currentStamina: Int
    let maxStamina: Int

    var ready: Bool {
        let hpPercent = Double(currentHealth) / Double(maxHealth)
        let mpPercent = Double(currentMana) / Double(maxMana)
        let spPercent = Double(currentStamina) / Double(maxStamina)
        return hpPercent > 0.85 && mpPercent > 0.85 && spPercent > 0.85
    }

    static var parser: some Parser<Substring, Prompt> {
        Parse {
            "prompt"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
        }.map { chp, mhp, cm, mm, cs, ms in
            Prompt(currentHealth: chp, maxHealth: mhp, currentMana: cm,
                   maxMana: mm, currentStamina: cs, maxStamina: ms)
        }
    }
}

enum CombatStatus {
    case notFighting
    case fighting(percent: Int, gender: String, name: String)

    private static var notFightingParser: some Parser<Substring, CombatStatus> {
        Parse { "-1" }.map { _ in CombatStatus.notFighting }
    }

    private static var fightingParser: some Parser<Substring, CombatStatus> {
        Parse {
            Int.parser()
            Skip { Optionally { CharacterSet.whitespaces } }
            Prefix { $0 != " " }
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest()
        }.map { percent, gender, name in
            CombatStatus.fighting(percent: percent, gender: String(gender), name: String(name))
        }
    }

    static var parser: some Parser<Substring, CombatStatus> {
        Parse {
            "fighting"
            Skip { Optionally { CharacterSet.whitespaces } }
            OneOf {
                notFightingParser
                fightingParser
            }
        }
    }
}

enum WalkDirection {
    case north, northwest, northeast, south, southwest, southeast, east, west, up, down
    case unknown(Int)

    static var parser: some Parser<Substring, WalkDirection> {
        Parse {
            "walkdir"
            Skip { Optionally { CharacterSet.whitespaces } }
            OneOf {
                "20".map { _ in WalkDirection.up }
                "30".map { _ in WalkDirection.down }
                "0".map { _ in WalkDirection.north }
                "7".map { _ in WalkDirection.northwest }
                "4".map { _ in WalkDirection.northeast }
                "2".map { _ in WalkDirection.south }
                "6".map { _ in WalkDirection.southwest }
                "5".map { _ in WalkDirection.southeast }
                "1".map { _ in WalkDirection.east }
                "3".map { _ in WalkDirection.west }
                Int.parser().map { WalkDirection.unknown($0) }
            }
        }
    }
}

enum Position: Equatable {
    case standing, sitting, sleeping
    case unknown(String)

    var recovering: Bool {
        switch self {
        case .sitting, .sleeping: return true
        default: return false
        }
    }

    static var parser: some Parser<Substring, Position> {
        Parse {
            "position"
            Skip { Optionally { CharacterSet.whitespaces } }
            OneOf {
                "standing".map { _ in Position.standing }
                "sitting".map { _ in Position.sitting }
                "sleeping".map { _ in Position.sleeping }
                Rest().map { Position.unknown(String($0)) }
            }
        }
    }
}

struct Sky {
    let outdoors: Bool
    let skyVisible: Bool
    let overcast: Bool

    private static var boolParser: some Parser<Substring, Bool> {
        OneOf {
            "0".map { _ in false }
            "1".map { _ in true }
        }
    }

    static var parser: some Parser<Substring, Sky> {
        Parse {
            "sky"
            Skip { Optionally { CharacterSet.whitespaces } }
            boolParser
            Skip { Optionally { CharacterSet.whitespaces } }
            boolParser
            Skip { Optionally { CharacterSet.whitespaces } }
            boolParser
        }.map { Sky(outdoors: $0, skyVisible: $1, overcast: $2) }
    }
}

struct Time {
    let durationSinceDayStart: Duration
    let timeOfDay: String
    let printableTimeString: String

    static var parser: some Parser<Substring, Time> {
        Parse {
            "time"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
            Skip { Optionally { CharacterSet.whitespaces } }
            Prefix { $0 != " " }
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest()
        }.map { (minutes: Int, timeOfDay: Substring, printableTimeString: Substring) in
            Time(durationSinceDayStart: .seconds(minutes * 60),
                 timeOfDay: String(timeOfDay),
                 printableTimeString: String(printableTimeString))
        }
    }
}

struct Area {
    let id: Int
    let printableAreaName: String

    static var parser: some Parser<Substring, Area> {
        Parse {
            "area"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest()
        }.map { Area(id: $0, printableAreaName: String($1)) }
    }
}

// MARK: - State (was an actor; now synchronous)

final class State {
    var characterName: String?
    func setCharacterName<S: StringProtocol>(_ name: S, context: HostScriptContext) throws {
        characterName = String(name)
    }

    var gold: Int?
    func setCharacterGold(_ gold: Int, context: HostScriptContext) throws { self.gold = gold }

    var experience: Int?
    func setCharacterExperience(_ exp: Int, context: HostScriptContext) throws { experience = exp }

    var experienceCap: Int?
    func setCharacterExperienceCap(_ cap: Int, context: HostScriptContext) throws { experienceCap = cap }

    var sky: Sky?
    func setSky(_ sky: Sky, context: HostScriptContext) throws { self.sky = sky }

    var time: Time?
    func setTime(_ time: Time, context: HostScriptContext) throws { self.time = time }

    var room: Room?
    func setRoom(_ room: Room, context: HostScriptContext) throws {
        self.room = room
        waypoint = false
        recover = false
    }

    var terrain: Terrain?
    func setTerrain(_ terrain: Terrain, context: HostScriptContext) throws { self.terrain = terrain }

    var roomShort: String?
    func setRoomShort<S: StringProtocol>(_ short: S, context: HostScriptContext) throws {
        roomShort = String(short)
    }

    var waypoint: Bool = false
    func setWaypoint(context: HostScriptContext) throws { waypoint = true }

    var area: Area?
    func setArea(_ area: Area, context: HostScriptContext) throws { self.area = area }

    var position: Position?
    func setPosition(_ position: Position, context: HostScriptContext) throws {
        self.position = position
        if recover && position.recovering != true {
            try chooseRecoveryPosition(context: context)
        }
    }

    func chooseRecoveryPosition(context: HostScriptContext) throws {
        guard let prompt else { return }
        let hpPercent = Double(prompt.currentHealth) / Double(prompt.maxHealth)
        let mpPercent = Double(prompt.currentMana) / Double(prompt.maxMana)
        let spPercent = Double(prompt.currentStamina) / Double(prompt.maxStamina)
        if hpPercent > 0.85 && mpPercent < 1 && spPercent > 0.75 {
            context.send("rest")
        } else {
            context.send("sleep")
        }
    }

    var prompt: Prompt?
    func setPrompt(_ prompt: Prompt, context: HostScriptContext) throws {
        self.prompt = prompt
        if case .some(true) = position?.recovering, recover, prompt.ready {
            context.echo("You have recovered and are ready to adventure!")
            context.send("stand")
            recover = false
        }
    }

    var combatStatus: CombatStatus = .notFighting
    func setCombatStatus(_ status: CombatStatus, context: HostScriptContext) throws {
        combatStatus = status
        if case .fighting = status { recover = false }
    }

    var walkDirection: WalkDirection?
    func setWalkDirection(_ walkDirection: WalkDirection, context: HostScriptContext) throws {
        self.walkDirection = walkDirection
    }

    var precipitation: Int?
    func setPrecipitation(_ precipitation: Int, context: HostScriptContext) throws {
        self.precipitation = precipitation
    }

    var activeSpells = [String]()
    func spellUp<S: StringProtocol>(_ spellName: S, context: HostScriptContext) throws {
        if !activeSpells.contains(String(spellName)) {
            activeSpells.append(String(spellName))
        }
    }

    func spellDown<S: StringProtocol>(_ spellName: S, context: HostScriptContext) throws {
        activeSpells.removeAll { $0 == String(spellName) }
        if recover, let prompt {
            if case .sleeping = position {
                let mpPercent = Double(prompt.currentMana) / Double(prompt.maxMana)
                if mpPercent > 0.3 {
                    context.send("rest")
                    position = .sitting
                }
            }
        }
    }

    var killLog = [String]()
    func mdeath<S: StringProtocol>(_ mdeath: S, context: HostScriptContext) throws {
        killLog.append(String(mdeath))
    }

    var recover = false
    func setRecovery(_ recover: Bool) { self.recover = recover }
}

// MARK: - KXWT parser (returns a synchronous action to run against State)

struct KXWT {
    let state: State
    let context: HostScriptContext

    private func parse(_ keyword: String) -> some Parser<Substring, Substring> {
        Parse {
            keyword
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest()
        }
    }

    func name() -> some Parser<Substring, () throws -> Void> {
        Parse {
            "myname"
            Skip { Optionally { CharacterSet.whitespaces } }
            Prefix { $0 != "\n" }
        }.map { name in { try state.setCharacterName(name, context: context) } }
    }

    func gold() -> some Parser<Substring, () throws -> Void> {
        Parse {
            "gold"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
        }.map { gold in { try state.setCharacterGold(gold, context: context) } }
    }

    func room() -> some Parser<Substring, () throws -> Void> {
        Parse { Room.parser }.map { room in { try state.setRoom(room, context: context) } }
    }

    func prompt() -> some Parser<Substring, () throws -> Void> {
        Parse { Prompt.parser }.map { prompt in { try state.setPrompt(prompt, context: context) } }
    }

    func fighting() -> some Parser<Substring, () throws -> Void> {
        Parse { CombatStatus.parser }.map { status in { try state.setCombatStatus(status, context: context) } }
    }

    func sky() -> some Parser<Substring, () throws -> Void> {
        Parse { Sky.parser }.map { sky in { try state.setSky(sky, context: context) } }
    }

    func time() -> some Parser<Substring, () throws -> Void> {
        Parse { Time.parser }.map { time in { try state.setTime(time, context: context) } }
    }

    func area() -> some Parser<Substring, () throws -> Void> {
        Parse { Area.parser }.map { area in { try state.setArea(area, context: context) } }
    }

    func terrain() -> some Parser<Substring, () throws -> Void> {
        Parse { Terrain.parser }.map { terrain in { try state.setTerrain(terrain, context: context) } }
    }

    func exp() -> some Parser<Substring, () throws -> Void> {
        Parse {
            "exp"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
        }.map { exp in { try state.setCharacterExperience(exp, context: context) } }
    }

    func expCap() -> some Parser<Substring, () throws -> Void> {
        Parse {
            "expcap"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
        }.map { expCap in { try state.setCharacterExperienceCap(expCap, context: context) } }
    }

    func waypoint() -> some Parser<Substring, () throws -> Void> {
        Parse { "waypoint" }.map { _ in { try state.setWaypoint(context: context) } }
    }

    func rshort() -> some Parser<Substring, () throws -> Void> {
        parse("rshort").map { rshort in { try state.setRoomShort(rshort, context: context) } }
    }

    func position() -> some Parser<Substring, () throws -> Void> {
        Parse { Position.parser }.map { position in { try state.setPosition(position, context: context) } }
    }

    func walkDir() -> some Parser<Substring, () throws -> Void> {
        Parse { WalkDirection.parser }.map { walkDir in { try state.setWalkDirection(walkDir, context: context) } }
    }

    func precipitation() -> some Parser<Substring, () throws -> Void> {
        Parse {
            "precipitation"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
        }.map { precipitation in { try state.setPrecipitation(precipitation, context: context) } }
    }

    func spellUp() -> some Parser<Substring, () throws -> Void> {
        parse("spellup").map { spellName in { try state.spellUp(spellName, context: context) } }
    }

    func spellDown() -> some Parser<Substring, () throws -> Void> {
        parse("spelldown").map { spellName in { try state.spellDown(spellName, context: context) } }
    }

    func spst() -> some Parser<Substring, () throws -> Void> {
        Parse {
            "spst"
            Skip { Optionally { CharacterSet.whitespaces } }
            Prefix { $0 != "," }
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest() // time remaining
        }.map { spellName, _ in { try state.spellUp(spellName, context: context) } }
    }

    func mdeath() -> some Parser<Substring, () throws -> Void> {
        parse("mdeath").map { monsterName in { try state.mdeath(monsterName, context: context) } }
    }

    func group() -> some Parser<Substring, () throws -> Void> {
        parse("group").map { _ in {} }
    }

    func parser() -> some Parser<Substring, () throws -> Void> {
        OneOf {
            name()
            gold()
            room()
            prompt()
            fighting()
            sky()
            time()
            area()
            terrain()
            exp()
            expCap()
            waypoint()
            rshort()
            position()
            walkDir()
            precipitation()
            spellUp()
            spellDown()
            spst()
            mdeath()
            group()
        }
    }
}

// MARK: - Host entry point (the `kxwt`, `recover`, `dump_state` builtins)

final class KXWTHost {
    private let state = State()

    /// Handle a `kxwt_<payload>` line, e.g. payload == "prompt 100 100 ...".
    func handle(_ payload: String) {
        let context = HostScriptContext()
        if let action = try? KXWT(state: state, context: context).parser().parse(payload) {
            try? action()
        }
        // Unknown kxwt commands are ignored (the line is gagged anyway).
    }

    /// The `recover` alias.
    func toggleRecovery() {
        let context = HostScriptContext()
        if state.recover {
            context.echo("Ending recovery")
            state.setRecovery(false)
        } else if state.prompt?.ready != true {
            context.echo("Starting recovery")
            state.setRecovery(true)
            try? state.chooseRecoveryPosition(context: context)
        }
    }

    /// The `state` alias — dump the current parsed state.
    func dumpState() {
        var dumped = String()
        dump(state, to: &dumped)
        HostScriptContext().echo(dumped)
    }

    /// A compact, model-friendly snapshot of the parsed state (used by AIPilotService).
    func summary() -> String {
        var out: [String] = []
        out.append("name: \(state.characterName ?? "unknown")")
        if let p = state.prompt {
            out.append("hp: \(p.currentHealth)/\(p.maxHealth), mana: \(p.currentMana)/\(p.maxMana), stamina: \(p.currentStamina)/\(p.maxStamina)\(p.ready ? " (ready)" : "")")
        }
        if let pos = state.position {
            let s: String
            switch pos {
            case .standing: s = "standing"
            case .sitting: s = "sitting"
            case .sleeping: s = "sleeping"
            case .unknown(let u): s = u
            }
            out.append("position: \(s)")
        }
        if let rs = state.roomShort { out.append("room: \(rs)") }
        if let a = state.area { out.append("area: \(a.printableAreaName)") }
        if let t = state.terrain { out.append("terrain: \(String(describing: t).lowercased())") }
        switch state.combatStatus {
        case .notFighting: out.append("combat: not fighting")
        case .fighting(let percent, _, let name): out.append("combat: fighting \(name) (\(percent)%)")
        }
        if !state.activeSpells.isEmpty { out.append("active spells: \(state.activeSpells.joined(separator: ", "))") }
        if let g = state.gold { out.append("gold: \(g)") }
        out.append("recovery mode: \(state.recover ? "on" : "off")")
        return out.joined(separator: "\n")
    }
}

extension Container {
    static let kxwtHost = Factory(scope: .cached) { KXWTHost() }
}
