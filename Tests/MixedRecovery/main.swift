// Compile alongside BrightnessEngine.swift with -D RECOVERY_FIXTURE.
// Native reads, isolated journal. The connected entries use only conflict,
// already-restored and keep-current paths.
import AppKit

func verify() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    let engine = BrightnessEngine(directory: dir)
    let screens = try Display.connected()
    guard let builtin = screens.first(where: { $0.builtIn }),
          let external = screens.first(where: { !$0.builtIn && !$0.mirrorMember }) else { throw Failure("Requires internal and external screens") }
    let live = try Backlight.read(builtin.id)
    let original: Float = live > 0.5 ? 0.2 : 0.8
    let applied: Float = live > 0.5 ? 0.1 : 0.9
    func fixture(_ uuid: String) throws -> SavedDisplay {
        let json = try JSONSerialization.data(withJSONObject: ["uuid":uuid,"name":uuid,"backlight":original,"attempted":true])
        var entry = try JSONDecoder().decode(SavedDisplay.self, from: json)
        entry.applied = .backlight(applied)
        return entry
    }
    let conflict = try fixture(builtin.uuid)
    let absent = try fixture(UUID().uuidString)
    let complete = try SavedDisplay(external)
    try JSONEncoder().encode([absent, conflict, complete]).write(to: engine.state)
    let result = try engine.restore()
    guard result.conflicts == [builtin.uuid], result.errors.count == 2, result.restored == [external.name],
          Set(try engine.pending().map(\.uuid)) == [builtin.uuid, absent.uuid] else { throw Failure("Mixed recovery routing") }
    _ = try engine.restore(choice: builtin.uuid, keepCurrent: true, expected: conflict)
    guard try engine.pending().map(\.uuid) == [absent.uuid], try Backlight.read(builtin.id) == live else { throw Failure("Retain choice or detached record lost") }
    print("PASS mixed recovery")
}
do { try verify() } catch { print(error); exit(1) }
