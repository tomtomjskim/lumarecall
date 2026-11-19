// Local acceptance probe. Operates only the installed brightness app's controls.
import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, key as CFString, &value)
    return value
}

func subtree(_ element: AXUIElement) -> [AXUIElement] {
    [element] + ((attribute(element, "AXChildren") as? [AXUIElement]) ?? []).flatMap(subtree)
}

func verify() throws {
    let engine = BrightnessEngine()
    let devices = try Display.connected()
    guard devices.count == 3, try engine.pending().isEmpty,
          let kado = devices.first(where: { $0.name == "Kado F16" }),
          let app = NSRunningApplication.runningApplications(withBundleIdentifier: "local.displaybrightness.toggle").first else {
        throw Failure("Requires the installed app and all three restored displays.")
    }
    let samples = try devices.map(SavedDisplay.init)
    guard let base = samples.first(where: { $0.uuid == kado.uuid })?.gamma else { throw Failure("No Kado baseline") }
    var reference = base
    if let data = UserDefaults(suiteName: "local.displaybrightness.toggle")?.data(forKey: "gammaAdjustment." + kado.uuid),
       let saved = try? JSONDecoder().decode(GammaAdjustment.self, from: data),
       base.approximatelyMatches(saved.output) {
        reference = saved.base
    }
    let expected = reference.scaled(by: 0.60)
    let root = AXUIElementCreateApplication(app.processIdentifier)
    guard let bars = attribute(root, "AXExtrasMenuBar") else { throw Failure("No brightness status item") }
    let bar = bars as! AXUIElement
    func elements() throws -> [AXUIElement] {
        var items = subtree(bar)
        if !items.contains(where: { attribute($0, "AXRole") as? String == "AXPopover" }) {
            guard let icon = items.first(where: { attribute($0, "AXRole") as? String == "AXMenuBarItem" }),
                  AXUIElementPerformAction(icon, kAXPressAction as CFString) == .success else { throw Failure("Open panel failed") }
            Thread.sleep(forTimeInterval: 0.55)
            items = subtree(bar)
        }
        return items
    }
    func checkReadings() throws {
        for (device,sample) in zip(devices,samples) {
            guard let wanted = device.uuid == kado.uuid ? DisplayValue.gamma(expected) : sample.original,
                  try sample.read(device.id).matches(wanted) else { throw Failure("Readback mismatch: " + device.name) }
        }
    }
    func button(_ title: String) throws {
        guard let item = try elements().first(where: { element in
            guard attribute(element, "AXRole") as? String == "AXButton" else { return false }
            return ["AXTitle","AXDescription"].contains { key in
                (attribute(element, key) as? String)?.contains(title) == true
            }
        }), AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { throw Failure("Button missing: " + title) }
        Thread.sleep(forTimeInterval: 0.55)
    }
    for index in 1...2 {
        guard let slider = try elements().first(where: {
            attribute($0, "AXIdentifier") as? String == "brightness." + kado.uuid
        }), AXUIElementSetAttributeValue(slider, kAXValueAttribute as CFString, NSNumber(value: 60)) == .success else {
            throw Failure("Could not set Kado slider")
        }
        Thread.sleep(forTimeInterval: 0.55)
        try checkReadings()
        print("Kado 60% input", index, "matched RGB table; other two matched baseline")
    }
    try button("작업 종료")
    do {
        guard let dim = try engine.pending().first(where: { $0.uuid == kado.uuid }),
              dim.original?.matches(.gamma(expected)) == true,
              let applied = dim.applied, try dim.read(kado.id).matches(applied),
              !applied.matches(.gamma(expected)) else { throw Failure("Dim not observed") }
        try button("원래 밝기로 복원")
        try checkReadings()
        guard try engine.pending().isEmpty else { throw Failure("Restore pending") }
        print("Work-end and restore verified. Kado peak", try Gamma(kado.id).peak)
    } catch {
        if try !engine.pending().isEmpty { _ = try engine.restore() }
        throw error
    }
}

do { try verify() } catch { print(error.localizedDescription); exit(1) }
