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

enum Position {
    case standing
    case sitting
    case sleeping
    case unknown(String)
    
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
    func setCharacterName<S: StringProtocol & Sendable>(_ name: S) {
        self.characterName = String(name)
    }

    var gold: Int?
    func setCharacterGold(_ gold: Int) {
        self.gold = gold
    }

    var experience: Int?
    func setCharacterExperience(_ exp: Int) {
        self.experience = exp
    }
    
    var experienceCap: Int?
    func setCharacterExperienceCap(_ cap: Int) {
        self.experienceCap = cap
    }
    //                kxwt_group_start
    //                kxwt_group 549 549 143 143 362 362 XL Sarevok
    //                kxwt_group_end
    var sky: Sky?
    func setSky(_ sky: Sky) {
        self.sky = sky
    }

    var time: Time?
    func setTime(_ time: Time) {
        self.time = time
    }

    var room: Room?
    func setRoom(_ room: Room) {
        self.room = room
        waypoint = false
    }

    var terrain: Terrain?
    func setTerrain(_ terrain: Terrain) {
        self.terrain = terrain
    }

    var roomShort: String?
    func setRoomShort<S: StringProtocol & Sendable>(_ short: S) {
        self.roomShort = String(short)
    }

    var waypoint: Bool = false
    func setWaypoint() {
        waypoint = true
    }

    var area: Area?
    func setArea(_ area: Area) {
        self.area = area
    }

    var position: Position?
    func setPosition(_ position: Position) {
        self.position = position
    }

    var prompt: Prompt?
    func setPrompt(_ prompt: Prompt) {
        self.prompt = prompt
    }

    var combatStatus: CombatStatus = .notFighting
    func setCombatStatus(_ status: CombatStatus) {
        self.combatStatus = status
    }
    
    var walkDirection: WalkDirection?
    func setWalkDirection(_ walkDirection: WalkDirection) {
        self.walkDirection = walkDirection
    }
    
    var precipitation: Int?
    func setPrecipitation(_ precipitation: Int) {
        self.precipitation = precipitation
    }
    
    var activeSpells = [String]()
    func spellUp<S: StringProtocol & Sendable>(_ spellName: S) {
        if !activeSpells.contains(String(spellName)) {
            activeSpells.append(String(spellName))
        }
    }
    func spellDown<S: StringProtocol & Sendable>(_ spellName: S) {
        activeSpells.removeAll { $0 == String(spellName) }
    }
    
    var killLog = [String]()
    func mdeath<S: StringProtocol & Sendable>(_ mdeath: S) {
        killLog.append(String(mdeath))
    }
}

struct KXWT: Sendable {
    var name: some Parser<Substring, () async throws -> Void> {
        Parse {
            "myname"
            Skip { Optionally { CharacterSet.whitespaces } }
            Prefix { $0 != "\n" }
        }.map { name in
            { await Container.state().setCharacterName(name) }
        }
    }
    
    var gold: some Parser<Substring, () async throws -> Void> {
        Parse {
            "gold"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
        }.map { gold in
            { await Container.state().setCharacterGold(gold) }
        }
    }
    
    var room: some Parser<Substring, () async throws -> Void> {
        Parse {
            Room.parser
        }.map { room in
            { await Container.state().setRoom(room) }
        }
    }
    
    var prompt: some Parser<Substring, () async throws -> Void> {
        Parse {
            Prompt.parser
        }.map { prompt in
            { await Container.state().setPrompt(prompt) }
        }
    }
    
    var fighting: some Parser<Substring, () async throws -> Void> {
        Parse {
            CombatStatus.parser
        }.map { combatStatus in
            { await Container.state().setCombatStatus(combatStatus) }
        }
    }
    
    var sky: some Parser<Substring, () async throws -> Void> {
        Parse {
            Sky.parser
        }.map { sky in
            { await Container.state().setSky(sky) }
        }
    }
    
    var time: some Parser<Substring, () async throws -> Void> {
        Parse {
            Time.parser
        }.map { time in
            { await Container.state().setTime(time) }
        }
    }
    
    var area: some Parser<Substring, () async throws -> Void> {
        Parse {
            Area.parser
        }.map { area in
            { await Container.state().setArea(area) }
        }
    }
    
    var terrain: some Parser<Substring, () async throws -> Void> {
        Parse {
            Terrain.parser
        }.map { terrain in
            { await Container.state().setTerrain(terrain) }
        }
    }
    
    var exp: some Parser<Substring, () async throws -> Void> {
        Parse {
            "exp"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
        }.map { exp in
            { await Container.state().setCharacterExperience(exp) }
        }
    }
    
    var expCap: some Parser<Substring, () async throws -> Void> {
        Parse {
            "expcap"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
        }.map { expCap in
            { await Container.state().setCharacterExperienceCap(expCap) }
        }
    }
    
    var waypoint: some Parser<Substring, () async throws -> Void> {
        Parse {
            "waypoint"
        }.map { expCap in
            { await Container.state().setWaypoint() }
        }
    }
    
    var rshort: some Parser<Substring, () async throws -> Void> {
        Parse {
            "rshort"
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest()
        }.map { rshort in
            { await Container.state().setRoomShort(rshort) }
        }
    }
    
    var position: some Parser<Substring, () async throws -> Void> {
        Parse {
            Position.parser
        }.map { position in
            { await Container.state().setPosition(position) }
        }
    }
    
    var walkDir: some Parser<Substring, () async throws -> Void> {
        Parse {
            WalkDirection.parser
        }.map { walkDir in
            { await Container.state().setWalkDirection(walkDir) }
        }
    }
    
    var precipitation: some Parser<Substring, () async throws -> Void> {
        Parse {
            "precipitation"
            Skip { Optionally { CharacterSet.whitespaces } }
            Int.parser()
        }.map { precipitation in
            { await Container.state().setPrecipitation(precipitation) }
        }
    }
    
    var spellUp: some Parser<Substring, () async throws -> Void> {
        Parse {
            "spellup"
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest()
        }.map { spellName in
            { await Container.state().spellUp(spellName) }
        }
    }
    
    var spellDown: some Parser<Substring, () async throws -> Void> {
        Parse {
            "spelldown"
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest()
        }.map { spellName in
            { await Container.state().spellDown(spellName) }
        }
    }
    
    var spst: some Parser<Substring, () async throws -> Void> {
        Parse {
            "spst"
            Skip { Optionally { CharacterSet.whitespaces } }
            Prefix { $0 != "," }
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest() // time remaining
//                Unknown kxwt command: kxwt_spst faith shield, two hours, 40 minutes
        }.map { spellName, _ in
            { await Container.state().spellUp(spellName) }
        }
    }
    
    var mdeath: some Parser<Substring, () async throws -> Void> {
        Parse {
            "mdeath"
            Skip { Optionally { CharacterSet.whitespaces } }
            Rest()
        }.map { monsterName in
            { await Container.state().mdeath(monsterName) }
        }
    }
    
    var parser: some Parser<Substring, () async throws -> Void> {
        Parse {
            OneOf {
                name
                gold
                room
                prompt
                fighting
                sky
                time
                area
                terrain
                exp
                expCap
                waypoint
                rshort
                position
                walkDir
                precipitation
                spellUp
                spellDown
                spst
                mdeath
            }
        }
    }
}

class AAFactory: ScriptFactory {
    override func getScript() -> Script {
        Script {
            Trigger(/.*? is DEAD!/) { _, context in
                try context.send("cry")
                try context.send("bsac corpse")
            }
            Trigger(/^kxwt_supported$/.anchorsMatchLineEndings()) { _, context in
                try context.send("set kxwt")
            }
            Trigger(/^kxwt_(.*?)$/.anchorsMatchLineEndings()) { match, context in
                if let task = try? KXWT().parser.parse(match.output.1) {
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
            }
            Gag(/^kxwt_.*?$/.anchorsMatchLineEndings())
            Alias(/^state$/.anchorsMatchLineEndings()) { _, context in
                var stateDumped = String()
                dump(Container.state(), to: &stateDumped)
                context.echo(stateDumped)
            }
        }
    }
}
