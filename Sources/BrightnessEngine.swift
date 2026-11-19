import AppKit
import CoreGraphics
import Darwin
import Foundation

struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct Gamma: Codable, Equatable {
    let red: [Float]
    let green: [Float]
    let blue: [Float]

    init(_ id: CGDirectDisplayID) throws {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { throw Failure("Display has no readable gamma table.") }
        var r = [Float](repeating: 0, count: Int(capacity))
        var g = r
        var b = r
        var count: UInt32 = 0
        let error = CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count)
        guard error == .success, count > 0, count <= capacity else {
            throw Failure("Could not read the display gamma table (\(error.rawValue)).")
        }
        red = Array(r.prefix(Int(count)))
        green = Array(g.prefix(Int(count)))
        blue = Array(b.prefix(Int(count)))
    }

    private init(red: [Float], green: [Float], blue: [Float]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    func scaled(by factor: Float) -> Gamma {
        Gamma(red: red.map { $0 * factor }, green: green.map { $0 * factor }, blue: blue.map { $0 * factor })
    }

    func apply(to id: CGDirectDisplayID) throws {
        guard !red.isEmpty, red.count == green.count, red.count == blue.count,
              red.count <= Int(CGDisplayGammaTableCapacity(id)) else {
            throw Failure("Saved gamma table does not match the display.")
        }
        let error = CGSetDisplayTransferByTable(id, UInt32(red.count), red, green, blue)
        guard error == .success else {
            throw Failure("Could not set the display gamma table (\(error.rawValue)).")
        }
    }

    var peak: Float { [red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0].max() ?? 0 }

    func approximatelyMatches(_ other: Gamma) -> Bool {
        func matches(_ first: [Float], _ second: [Float]) -> Bool {
            first.count == second.count && zip(first, second).allSatisfy { abs($0 - $1) <= 0.005 }
        }
        return matches(red, other.red) && matches(green, other.green) && matches(blue, other.blue)
    }
}

enum Backlight {
    typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    // AppKit has no public API for setting the built-in backlight.
    static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    static func read(_ id: CGDirectDisplayID) throws -> Float {
        guard let library, let symbol = dlsym(library, "DisplayServicesGetBrightness") else {
            throw Failure("Built-in backlight API unavailable.")
        }
        var value: Float = 0
        guard unsafeBitCast(symbol, to: Get.self)(id, &value) == 0, (0...1).contains(value) else {
            throw Failure("Could not read the built-in backlight.")
        }
        return value
    }

    static func write(_ value: Float, to id: CGDirectDisplayID) throws {
        guard let library, let symbol = dlsym(library, "DisplayServicesSetBrightness") else {
            throw Failure("Built-in backlight API unavailable.")
        }
        guard unsafeBitCast(symbol, to: Set.self)(id, value) == 0 else {
            throw Failure("Could not set the built-in backlight.")
        }
    }
}

struct Display {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    var builtIn: Bool { CGDisplayIsBuiltin(id) != 0 }

    static func connected() throws -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            throw Failure("Could not count active displays.")
        }
        if count == 0 { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            throw Failure("Could not enumerate active displays.")
        }
        let names = NSScreen.screens.reduce(into: [CGDirectDisplayID: String]()) { result, screen in
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                result[number.uint32Value] = screen.localizedName
            }
        }
        return try ids.prefix(Int(count)).map { id in
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else {
                throw Failure("Could not identify display \(id).")
            }
            return Display(id: id, uuid: CFUUIDCreateString(nil, uuid) as String, name: names[id] ?? "Display \(id)")
        }
    }
}

struct SavedDisplay: Codable {
    let uuid: String
    let name: String
    let backlight: Float?
    let gamma: Gamma?
    var applied: DisplayValue?
    var attempted: Bool?
    var restoring: Bool?

    init(_ display: Display) throws {
        uuid = display.uuid
        name = display.name
        if display.builtIn, let value = try? Backlight.read(display.id) {
            backlight = value
            gamma = nil
        } else {
            backlight = nil
            gamma = try Gamma(display.id)
        }
    }

    var original: DisplayValue? {
        if let backlight { return .backlight(backlight) }
        if let gamma { return .gamma(gamma) }
        return nil
    }

    func read(_ id: CGDirectDisplayID) throws -> DisplayValue {
        if backlight != nil {
            guard CGDisplayIsBuiltin(id) != 0 else { throw Failure("제어 방식이 바뀌었습니다.") }
            return .backlight(try Backlight.read(id))
        }
        return .gamma(try Gamma(id))
    }
}

enum DisplayValue: Codable, Equatable {
    case backlight(Float), gamma(Gamma)

    func dimmed(_ level: Float) throws -> DisplayValue {
        switch self {
        case .backlight(let value):
            guard value >= 0.005 else { throw Failure("먼저 화면 밝기를 올려 주세요.") }
            return .backlight(min(value, level))
        case .gamma(let table):
            guard table.peak >= 0.05 else { throw Failure("먼저 화면 밝기를 올려 주세요.") }
            return .gamma(table.scaled(by: level))
        }
    }

    var isVisible: Bool {
        switch self {
        case .backlight(let value): return value > 0
        case .gamma(let table): return table.peak > 0.002
        }
    }

    func matches(_ other: DisplayValue) -> Bool {
        switch (self, other) {
        case (.backlight(let a), .backlight(let b)): return abs(a - b) <= 0.005
        case (.gamma(let a), .gamma(let b)): return a.approximatelyMatches(b)
        default: return false
        }
    }

    func write(_ id: CGDirectDisplayID) throws {
        switch self {
        case .backlight(let value): try Backlight.write(value, to: id)
        case .gamma(let table): try table.apply(to: id)
        }
    }
}

extension Display {
    func qualificationIdentity(backlight: Bool) -> String {
        identity + (backlight ? ":backlight" : ":gamma")
    }
    var qualificationIdentity: String {
        qualificationIdentity(backlight: builtIn && (try? Backlight.read(id)) != nil)
    }
    var mirrorMember: Bool { CGDisplayIsInMirrorSet(id) != 0 }
    var identity: String { "\(uuid):\(id):\(builtIn):\(mirrorMember)" }
}

// Keep the unscaled profile alongside the last slider setting across app launches.
struct GammaAdjustment: Codable {
    let base: Gamma
    let percent: Int
    var output: Gamma { base.scaled(by: Float(percent) / 100) }
}

struct SliderReading: Equatable {
    let identity: String
    let sample: DisplayValue
    let base: Gamma?
    let percent: Int
}

struct BrightnessEngine {
    #if RECOVERY_FIXTURE
    let directory: URL
    #else
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NativeDisplayBrightnessToggle")
    #endif
    var state: URL { directory.appendingPathComponent("restore.json") }

    func pending() throws -> [SavedDisplay] {
        guard FileManager.default.fileExists(atPath: state.path) else { return [] }
        return try JSONDecoder().decode([SavedDisplay].self, from: Data(contentsOf: state))
    }

    private func save(_ saved: [SavedDisplay]) throws {
        if saved.isEmpty {
            if FileManager.default.fileExists(atPath: state.path) {
                try FileManager.default.removeItem(at: state)
            }
        } else {
            try JSONEncoder().encode(saved).write(to: state, options: .atomic)
        }
    }

    func locked<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure("잠금 파일을 열 수 없습니다.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure("밝기 변경이 진행 중입니다.") }
        return try operation()
    }

    func sliderReading(for display: Display, sample: DisplayValue) -> SliderReading? {
        guard !display.mirrorMember else { return nil }
        switch sample {
        case .backlight(let value):
            return SliderReading(identity: display.identity, sample: sample, base: nil,
                                 percent: Int((value * 100).rounded()))
        case .gamma(let current):
            guard current.peak >= 0.005 else { return nil }
            if let data = UserDefaults.standard.data(forKey: "gammaAdjustment." + display.uuid),
               let stored = try? JSONDecoder().decode(GammaAdjustment.self, from: data),
               (10...100).contains(stored.percent), current.approximatelyMatches(stored.output) {
                return SliderReading(identity: display.identity, sample: sample, base: stored.base, percent: stored.percent)
            }
            return SliderReading(identity: display.identity, sample: sample, base: current, percent: 100)
        }
    }

    func adjust(uuid: String, percent: Int, from reading: SliderReading) throws {
        try locked {
            guard (10...100).contains(percent), try pending().isEmpty else {
                throw Failure("복원을 마친 뒤 밝기를 조절하세요.")
            }
            let matches = try Display.connected().filter { $0.uuid == uuid }
            guard matches.count == 1, let display = matches.first,
                  display.identity == reading.identity, !display.mirrorMember else {
                throw Failure("화면 구성이 바뀌었습니다. 다시 조절하세요.")
            }
            let entry = try SavedDisplay(display)
            guard let current = entry.original, current.matches(reading.sample) else {
                throw Failure("화면 값이 외부에서 변경됐습니다. 현재 값을 확인하고 다시 조절하세요.")
            }
            let adjustment = reading.base.map { GammaAdjustment(base: $0, percent: percent) }
            let value = adjustment.map { DisplayValue.gamma($0.output) } ?? .backlight(Float(percent) / 100)
            guard value.isVisible else { throw Failure("이 화면에서는 요청한 밝기가 너무 낮습니다.") }
            if !current.matches(value) {
                try value.write(liveDisplay(entry, expected: reading.identity).id)
                let actual = try entry.read(liveDisplay(entry, expected: reading.identity).id)
                guard actual.matches(value), actual.isVisible else { throw Failure("조절한 밝기를 확인할 수 없습니다.") }
            }
            if let adjustment {
                UserDefaults.standard.set(try JSONEncoder().encode(adjustment), forKey: "gammaAdjustment." + uuid)
            }
        }
    }

    func dim(level: Float, excluding: Set<String> = [], required: [String]? = nil) throws -> [String] {
        try locked {
            guard try pending().isEmpty else { throw Failure("이전 밝기를 먼저 복원하세요.") }
            let displays = try Display.connected()
            let targets = displays.filter { !$0.mirrorMember && !excluding.contains($0.uuid) }
            guard !targets.isEmpty else { throw Failure("제어 가능한 화면이 없습니다.") }
            var saved = try targets.map(SavedDisplay.init)
            if let required, required != zip(targets, saved).map({ $0.0.qualificationIdentity(backlight: $0.1.backlight != nil) }).sorted() {
                throw Failure("화면 구성이 변경됐습니다. 복원 단축키를 다시 확인하세요.")
            }
            let topology = displays.map(\.identity).sorted()
            let values = try saved.map { entry -> DisplayValue in
                guard let original = entry.original else { throw Failure("저장할 밝기가 없습니다.") }
                return try original.dimmed(level)
            }
            for index in saved.indices { saved[index].attempted = false }
            try save(saved)
            do {
                for index in saved.indices {
                    let display = targets[index]
                    guard try Display.connected().map(\.identity).sorted() == topology else {
                        throw Failure("화면 구성이 바뀌었습니다.")
                    }
                    saved[index].attempted = true
                    saved[index].applied = values[index]
                    try save(saved)
                    let current = try liveDisplay(saved[index], expected: display.identity)
                    try values[index].write(current.id)
                    let checked = try liveDisplay(saved[index], expected: display.identity)
                    let actual = try saved[index].read(checked.id)
                    guard actual.isVisible, actual.matches(values[index]) else {
                        throw Failure("\(display.name): 밝기를 확인할 수 없습니다.")
                    }
                    saved[index].applied = actual
                    try save(saved)
                }
                return saved.map(\.name)
            } catch {
                let recovery = try restoreLocked(rollback: true)
                throw Failure(([error.localizedDescription] + recovery.errors).joined(separator: "\n"))
            }
        }
    }

    func liveDisplay(_ entry: SavedDisplay, expected: String? = nil) throws -> Display {
        let matches = try Display.connected().filter { $0.uuid == entry.uuid }
        guard matches.count == 1, let match = matches.first, !match.mirrorMember,
              expected == nil || expected == match.identity else {
            throw Failure("화면을 다시 연결하고 복원을 시도하세요.")
        }
        return match
    }

    struct Recovery {
        var restored: [String] = []
        var conflicts: [String] = []
        var errors: [String] = []
    }

    func restore(choice: String? = nil, keepCurrent: Bool = false, expected: SavedDisplay? = nil) throws -> Recovery {
        try locked {
            if let expected {
                guard let current = try pending().first(where: { $0.uuid == choice }),
                      let original = expected.original, current.original?.matches(original) == true,
                      let applied = expected.applied, current.applied?.matches(applied) == true else {
                    throw Failure("복원 대상이 변경됐습니다. 현재 화면 상태를 확인하세요.")
                }
            }
            return try restoreLocked(choice: choice, keepCurrent: keepCurrent)
        }
    }

    private func restoreLocked(choice: String? = nil, keepCurrent: Bool = false,
                               rollback: Bool = false) throws -> Recovery {
        var entries = try pending()
        var result = Recovery()
        for entry in entries {
            if let choice, entry.uuid != choice { continue }
            do {
                if entry.attempted != false {
                    guard let original = entry.original else { throw Failure("이전 밝기 자료가 없습니다.") }
                    let display = try liveDisplay(entry)
                    let current = try entry.read(display.id)
                    if !keepCurrent && !current.matches(original) {
                        guard choice != nil || rollback || entry.applied == nil ||
                              entry.applied?.matches(current) == true else {
                            result.conflicts.append(entry.uuid)
                            throw Failure("외부 변경이 감지됐습니다. 이전 값 또는 현재 값을 선택하세요.")
                        }
                        guard let index = entries.firstIndex(where: { $0.uuid == entry.uuid }) else { continue }
                        entries[index].restoring = true
                        try save(entries)
                        let verified = try liveDisplay(entry, expected: display.identity)
                        try original.write(verified.id)
                        guard try entry.read(liveDisplay(entry, expected: display.identity).id).matches(original) else {
                            throw Failure("복원값을 확인할 수 없습니다.")
                        }
                    }
                }
                let remaining = entries.filter { $0.uuid != entry.uuid }
                try save(remaining)
                entries = remaining
                result.restored.append(entry.name)
            } catch {
                result.errors.append("\(entry.name): \(error.localizedDescription)")
            }
        }
        return result
    }
}
