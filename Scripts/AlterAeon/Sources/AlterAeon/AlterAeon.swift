// The Swift Programming Language
// https://docs.swift.org/swift-book

import ScriptDescription
import Afluent
import Parsing
import Foundation
import DependencyInjection

@_cdecl("createFactory")
public func createFactory() -> UnsafeMutableRawPointer {
    return Unmanaged.passRetained(AAFactory()).toOpaque()
}

extension Container {
    static let state = Factory(scope: .cached) { State() }
}

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
                 coordinate: .init(x: xpos,
                                   y: ypos,
                                   z: zpos),
                 plane: plane)
        }
    }
}

enum Terrain: Int {
    case NOTSET
    case BUILDING
    case TOWN
    case FIELD
    case LFOREST
    case TFOREST
    case DFOREST
    case SWAMP
    case PLATEAU
    case SANDY
    case MOUNTAIN
    case ROCK
    case DESERT
    case TUNDRA
    case BEACH
    case HILL
    case DUNES
    case JUNGLE
    case OCEAN
    case STREAM
    case RIVER
    case UNDERWATER
    case UNDERGROUND
    case AIR
    case ICE
    case LAVA
    case RUINS
    case CAVE
    case CITY
    case MARSH
    case WASTELAND
    case CLOUD
    case WATER
    case METAL
    case TAIGA
    case SEWER
    case SHADOW
    case CATACOMB
    case MIRE
    case CRYSTAL
    
    static var parser: some Parser<Substring, Terrain> {
        Parse {
            "terrain"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser().compactMap {
                Terrain(rawValue: $0)
            }
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
        let hpPercent = Double(Double(currentHealth) / Double(maxHealth))
        let mpPercent = Double(Double(currentMana) / Double(maxMana))
        let spPercent = Double(Double(currentStamina) / Double(maxStamina))

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
            Prompt(currentHealth: chp,
                   maxHealth: mhp,
                   currentMana: cm,
                   maxMana: mm,
                   currentStamina: cs,
                   maxStamina: ms)
        }
    }
}

enum CombatStatus {
    case notFighting
    case fighting(percent: Int, gender: String, name: String)
    
    private static var notFightingParser: some Parser<Substring, CombatStatus> {
        Parse {
            "-1"
        }.map { _ in CombatStatus.notFighting }
    }
    
    private static var fightingParser: some Parser<Substring, CombatStatus> {
        Parse {
            Int.parser()
            Skip { Optionally { CharacterSet.whitespaces } }
            Prefix { $0 != " " }
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest()
        }
        .map { percent, gender, name in
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
    case north
    case northwest
    case northeast
    case south
    case southwest
    case southeast
    case east
    case west
    case up
    case down
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
    case standing
    case sitting
    case sleeping
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
        Parse {
            OneOf {
                "0".map { _ in false }
                "1".map { _ in true }
            }
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
        }.map {
            Sky(outdoors: $0, skyVisible: $1, overcast: $2)
        }
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
            Time(durationSinceDayStart: .seconds(minutes * 60), timeOfDay: String(timeOfDay), printableTimeString: String(printableTimeString))
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
        }.map {
            Area(id: $0, printableAreaName: String($1))
        }
    }
}

actor State {
    var characterName: String?
    func setCharacterName<S: StringProtocol & Sendable>(_ name: S, context: ScriptContext) throws {
        self.characterName = String(name)
    }

    var gold: Int?
    func setCharacterGold(_ gold: Int, context: ScriptContext) throws {
        self.gold = gold
    }

    var experience: Int?
    func setCharacterExperience(_ exp: Int, context: ScriptContext) throws {
        self.experience = exp
    }
    
    var experienceCap: Int?
    func setCharacterExperienceCap(_ cap: Int, context: ScriptContext) throws {
        self.experienceCap = cap
    }
    //                kxwt_group_start
    //                kxwt_group 549 549 143 143 362 362 XL Sarevok
    //                kxwt_group_end
    var sky: Sky?
    func setSky(_ sky: Sky, context: ScriptContext) throws {
        self.sky = sky
    }

    var time: Time?
    func setTime(_ time: Time, context: ScriptContext) throws {
        self.time = time
    }

    var room: Room?
    func setRoom(_ room: Room, context: ScriptContext) throws {
        self.room = room
        waypoint = false
        recover = false
    }

    var terrain: Terrain?
    func setTerrain(_ terrain: Terrain, context: ScriptContext) throws {
        self.terrain = terrain
    }

    var roomShort: String?
    func setRoomShort<S: StringProtocol & Sendable>(_ short: S, context: ScriptContext) throws {
        self.roomShort = String(short)
    }

    var waypoint: Bool = false
    func setWaypoint(context: ScriptContext) throws {
        waypoint = true
    }

    var area: Area?
    func setArea(_ area: Area, context: ScriptContext) throws {
        self.area = area
    }

    var position: Position?
    func setPosition(_ position: Position, context: ScriptContext) throws {
        self.position = position
        
        if recover && position.recovering != true {
            try chooseRecoveryPosition(context: context)
        }
    }
    
    func chooseRecoveryPosition(context: ScriptContext) throws {
        guard let prompt else { return }

        let hpPercent = Double(Double(prompt.currentHealth) / Double(prompt.maxHealth))
        let mpPercent = Double(Double(prompt.currentMana) / Double(prompt.maxMana))
        let spPercent = Double(Double(prompt.currentStamina) / Double(prompt.maxStamina))
        
        if hpPercent > 0.85 && mpPercent < 1 && spPercent > 0.75 {
            try context.send("rest")
        } else {
            try context.send("sleep")
        }
    }

    var prompt: Prompt?
    func setPrompt(_ prompt: Prompt, context: ScriptContext) throws {
        self.prompt = prompt
        
        if case .some(true) = position?.recovering, recover, prompt.ready {
            context.echo("You have recovered and are ready to adventure!")
            try context.send("stand")
            recover = false
        }
    }

    var combatStatus: CombatStatus = .notFighting
    func setCombatStatus(_ status: CombatStatus, context: ScriptContext) throws {
        self.combatStatus = status
        
        if case .fighting = status {
            recover = false
        }
    }
    
    var walkDirection: WalkDirection?
    func setWalkDirection(_ walkDirection: WalkDirection, context: ScriptContext) throws {
        self.walkDirection = walkDirection
    }
    
    var precipitation: Int?
    func setPrecipitation(_ precipitation: Int, context: ScriptContext) throws {
        self.precipitation = precipitation
    }
    
    var activeSpells = [String]()
    func spellUp<S: StringProtocol & Sendable>(_ spellName: S, context: ScriptContext) throws {
        if !activeSpells.contains(String(spellName)) {
            activeSpells.append(String(spellName))
        }
    }
    func spellDown<S: StringProtocol & Sendable>(_ spellName: S, context: ScriptContext) throws {
        activeSpells.removeAll { $0 == String(spellName) }
        
        if recover, let prompt {
            if case .sleeping = position {
                let mpPercent = Double(Double(prompt.currentMana) / Double(prompt.maxMana))
                
                if mpPercent > 0.3 {
                    try context.send("rest")
                    position = .sitting
                }
            }
        }
    }
    
    var killLog = [String]()
    func mdeath<S: StringProtocol & Sendable>(_ mdeath: S, context: ScriptContext) throws {
        killLog.append(String(mdeath))
    }
    
    var recover = false
    func setRecovery(_ recover: Bool) {
        self.recover = recover
    }
}

struct KXWT: Sendable {
    func name(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            "myname"
            Skip { Optionally { CharacterSet.whitespaces } }
            Prefix { $0 != "\n" }
        }.map { name in
            { try await Container.state().setCharacterName(name, context: context) }
        }
    }
    
    func gold(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            "gold"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
        }
        .map { gold in
            { try await Container.state().setCharacterGold(gold, context: context) }
        }
    }
    
    func room(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            Room.parser
        }.map { room in
            { try await Container.state().setRoom(room, context: context) }
        }
    }
    
    func prompt(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            Prompt.parser
        }.map { prompt in
            { try await Container.state().setPrompt(prompt, context: context) }
        }
    }
    
    func fighting(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            CombatStatus.parser
        }.map { combatStatus in
            { try await Container.state().setCombatStatus(combatStatus, context: context) }
        }
    }
    
    func sky(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            Sky.parser
        }.map { sky in
            { try await Container.state().setSky(sky, context: context) }
        }
    }
    
    func time(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            Time.parser
        }.map { time in
            { try await Container.state().setTime(time, context: context) }
        }
    }
    
    func area(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            Area.parser
        }.map { area in
            { try await Container.state().setArea(area, context: context) }
        }
    }
    
    func terrain(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            Terrain.parser
        }.map { terrain in
            { try await Container.state().setTerrain(terrain, context: context) }
        }
    }
    
    func exp(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            "exp"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
        }.map { exp in
            { try await Container.state().setCharacterExperience(exp, context: context) }
        }
    }
    
    func expCap(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            "expcap"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
        }.map { expCap in
            { try await Container.state().setCharacterExperienceCap(expCap, context: context) }
        }
    }
    
    func waypoint(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            "waypoint"
        }.map { expCap in
            { try await Container.state().setWaypoint(context: context) }
        }
    }
    
    func rshort(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            "rshort"
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest()
        }.map { rshort in
            { try await Container.state().setRoomShort(rshort, context: context) }
        }
    }
    
    func position(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            Position.parser
        }.map { position in
            { try await Container.state().setPosition(position, context: context) }
        }
    }
    
    func walkDir(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            WalkDirection.parser
        }.map { walkDir in
            { try await Container.state().setWalkDirection(walkDir, context: context) }
        }
    }
    
    func precipitation(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            "precipitation"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
        }.map { precipitation in
            { try await Container.state().setPrecipitation(precipitation, context: context) }
        }
    }
    
    func spellUp(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            "spellup"
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest()
        }.map { spellName in
            { try await Container.state().spellUp(spellName, context: context) }
        }
    }
    
    func spellDown(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            "spelldown"
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest()
        }.map { spellName in
            { try await Container.state().spellDown(spellName, context: context) }
        }
    }
    
    func spst(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            "spst"
            Skip { Optionally { CharacterSet.whitespaces } }
            Prefix { $0 != "," }
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest() // time remaining
//                Unknown kxwt command: kxwt_spst faith shield, two hours, 40 minutes
        }.map { spellName, _ in
            { try await Container.state().spellUp(spellName, context: context) }
        }
    }
    
    func mdeath(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            "mdeath"
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest()
        }.map { monsterName in
            { try await Container.state().mdeath(monsterName, context: context) }
        }
    }
    
    func group(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            "group"
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest()
        }.map { _ in
            {  }
        }
    }
    
    func parser(context: ScriptContext) -> some Parser<Substring, () async throws -> Void> {
        Parse {
            OneOf {
                name(context: context)
                gold(context: context)
                room(context: context)
                prompt(context: context)
                fighting(context: context)
                sky(context: context)
                time(context: context)
                area(context: context)
                terrain(context: context)
                exp(context: context)
                expCap(context: context)
                waypoint(context: context)
                rshort(context: context)
                position(context: context)
                walkDir(context: context)
                precipitation(context: context)
                spellUp(context: context)
                spellDown(context: context)
                spst(context: context)
                mdeath(context: context)
                group(context: context)
            }
        }
    }
}

class AAFactory: ScriptFactory {
    override func getScript() -> Script {
        Script {
            Trigger(/.*? is DEAD!/) { _, context in
                try context.send("cry")
//                try context.send("bsac corpse")
            }
            Trigger(/^kxwt_supported$/.anchorsMatchLineEndings()) { _, context in
                try context.send("set kxwt")
            }
            Trigger(/^kxwt_(.*?)$/.anchorsMatchLineEndings()) { match, context in
                if let task = try? KXWT().parser(context: context).parse(match.output.1) {
                    try await task()
                } else {
                    context.echo("Unknown kxwt command: \(match.output.0)")
                }
                
//                kxwt_group_start
//                kxwt_group 549 549 143 143 362 362 XL Sarevok
//                kxwt_group_end
                // kxwt_event level 18 cleric
//                Unknown kxwt command: kxwt_event quest Ended the devastation of a swarm of locust during the end of summer 2024.
//                Unknown kxwt command: kxwt_nocast
                // Unknown kxwt command: kxwt_idle
//                Unknown kxwt command: kxwt_action 60
                // harvest teeth???????
//                kxwt_action %d                - actions like butchering, turn, etc
//                                                 numbers of 50 and up prevent spellcasting
//                kxwt_audio spell/faithshield
//                kxwt_group_start
    //
    //            Unknown kxwt command: kxwt_group 615 615 150 173 359 359 XL Sarevok
    //
    //            Unknown kxwt command: kxwt_group 82 82 4 4 220 220 MT A clay man
    //
    //            Unknown kxwt command: kxwt_group_end

            }
            Gag(/^kxwt_.*?$/.anchorsMatchLineEndings())
            Alias(/^state$/.anchorsMatchLineEndings()) { _, context in
                var stateDumped = String()
                dump(Container.state(), to: &stateDumped)
                context.echo(stateDumped)
            }
            Alias(/^recover$/.anchorsMatchLineEndings()) { _, context in
                let state = Container.state()
                if await state.recover == true {
                    context.echo("Ending recovery")
                    await state.setRecovery(false)
                } else if await state.prompt?.ready != true {
                    context.echo("Starting recovery")
                    await state.setRecovery(true)
                    try await state.chooseRecoveryPosition(context: context)
                }
            }
        }
    }
}
