// Read-only hardware acceptance probe. Start with all three displays restored,
// then use the installed app. Pass --disconnect to require the Kado F16 cycle.
import AppKit

func observe(requireDisconnect: Bool) throws {
    let engine = BrightnessEngine()
    let baseline = try Display.connected().map { try SavedDisplay($0) }
    guard baseline.count == 3, try engine.pending().isEmpty else {
        throw Failure("Connect all three screens and restore brightness before testing.")
    }
    let deadline = Date().addingTimeInterval(300)
    var dimmed = false
    var detached = false
    var othersRestored = false
    print("READY"); fflush(stdout)
    while Date() < deadline {
        let connected = try Display.connected()
        let pending = try engine.pending()
        func matches(_ item: SavedDisplay, _ expected: DisplayValue?) -> Bool {
            guard let id = connected.first(where: { $0.uuid == item.uuid })?.id,
                  let value = try? item.read(id), let expected else { return false }
            return value.matches(expected)
        }
        if !dimmed && pending.count == baseline.count && baseline.allSatisfy({ item in
            guard let saved = pending.first(where: { $0.uuid == item.uuid }) else { return false }
            return matches(item, saved.applied) && !matches(item, item.original)
        }) {
            dimmed = true
            print("All three dimmed"); fflush(stdout)
        }
        if dimmed && connected.count == 2 && !connected.contains(where: { $0.name == "Kado F16" }) {
            detached = true
        }
        if detached && pending.count == 1 && pending.first?.name == "Kado F16" &&
            baseline.filter({ $0.name != "Kado F16" }).allSatisfy({ matches($0, $0.original) }) {
            if !othersRestored { print("Only Kado F16 pending"); fflush(stdout) }
            othersRestored = true
        }
        if dimmed && pending.isEmpty && baseline.allSatisfy({ matches($0, $0.original) }) {
            guard !requireDisconnect || othersRestored else { throw Failure("Partial recovery was not observed.") }
            print("All three restored")
            return
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    throw Failure("Timed out before recovery could be verified.")
}

do { try observe(requireDisconnect: CommandLine.arguments.contains("--disconnect")) }
catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
