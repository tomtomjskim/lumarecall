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
    let screens = try Display.connected()
    let originals = try screens.map(SavedDisplay.init)
    guard try engine.pending().isEmpty, !engine.canUndoScene, screens.count == 3,
          let kado = screens.first(where: { $0.name == "Kado F16" }),
          let mac = screens.first(where: { $0.builtIn }),
          let app = NSRunningApplication.runningApplications(withBundleIdentifier: "local.displaybrightness.toggle").first,
          let barObject = attribute(AXUIElementCreateApplication(app.processIdentifier), "AXExtrasMenuBar")
    else { throw Failure("Requires three restored displays, no previous scene undo, and installed app") }
    let bar = barObject as! AXUIElement
    func controls() throws -> [AXUIElement] {
        let elements = subtree(bar)
        if elements.contains(where: { attribute($0,"AXRole") as? String == "AXPopover" }) { return elements }
        guard let item = elements.first(where: { attribute($0,"AXRole") as? String == "AXMenuBarItem" }),
              AXUIElementPerformAction(item,kAXPressAction as CFString) == .success else { throw Failure("No popover") }
        Thread.sleep(forTimeInterval:0.45)
        return subtree(bar)
    }
    func find(_ text: String) throws -> AXUIElement {
        let items = try controls()
        guard let match = items.first(where: { e in
            ["AXIdentifier","AXDescription","AXTitle"].contains { key in
                let label = attribute(e,key) as? String ?? ""
                return label == text || (["작업 종료","원래 밝기로 복원"].contains(text) && label.hasPrefix(text+","))
            }
        }) else { throw Failure("Control missing: "+text) }
        return match
    }
    func press(_ name: String) throws {
        guard AXUIElementPerformAction(try find(name),kAXPressAction as CFString) == .success else { throw Failure("Press failed: "+name) }
        Thread.sleep(forTimeInterval:0.45)
    }
    func slider(_ display: Display, _ percent: Int) throws {
        let control = try find("brightness."+display.uuid)
        guard AXUIElementSetAttributeValue(control,kAXValueAttribute as CFString,NSNumber(value:percent)) == .success else { throw Failure("Slider failed") }
        Thread.sleep(forTimeInterval:0.45)
    }
    func level(_ display: Display) throws -> Int {
        guard let number = attribute(try find("brightness."+display.uuid),"AXValue") as? NSNumber else { throw Failure("Missing slider value") }
        return number.intValue
    }
    var created: [BrightnessScene] = []
    func save(_ selected: Set<String>) throws -> BrightnessScene {
        let prior = Set(try engine.scenes().map(\.id))
        try press("scene.list")
        try press("화면을 골라 저장")
        for screen in screens where !selected.contains(screen.uuid) { try press("scene.target."+screen.uuid) }
        try press("프리셋 저장")
        let added = try engine.scenes().filter { !prior.contains($0.id) }
        guard added.count == 1 else { throw Failure("No unique saved scene") }
        let scene = added[0]
        created.append(scene)
        guard Set(scene.targets.map(\.uuid)) == selected else { throw Failure("Incorrect scene membership") }
        try press("뒤로")
        return scene
    }
    func apply(_ scene: BrightnessScene) throws {
        try press("scene.list")
        try press("scene.apply."+scene.id.uuidString)
    }
    func current() throws -> [DisplayValue] {
        try zip(originals,screens).map { try $0.0.read($0.1.id) }
    }
    func check(_ expected: [DisplayValue], _ label: String) throws {
        let values = try current()
        guard zip(values,expected).allSatisfy({ $0.matches($1) }) else { throw Failure("Mismatch: "+label) }
        print("PASS", label)
    }
    let initial = try current()
    let initialKado = try level(kado), initialMac = try level(mac)
    let kadoB = initialKado == 43 ? 58 : 43
    let macB = initialMac == 76 ? 69 : 76
    guard (10...100).contains(initialMac) else { throw Failure("Internal baseline outside slider range") }
    var failure: Error?
    do {
        let a = try save([kado.uuid])
        try slider(kado,kadoB); try slider(mac,macB)
        let b = try save([kado.uuid,mac.uuid])
        guard b.targets.contains(where: { $0.uuid == kado.uuid && $0.percent == kadoB }),
              b.targets.contains(where: { $0.uuid == mac.uuid && $0.percent == macB }) else { throw Failure("Saved levels incorrect") }
        let sceneB = try current()
        try apply(b)
        try apply(a)
        var partial = sceneB
        let index = screens.firstIndex(where: { $0.uuid == kado.uuid })!
        partial[index] = initial[index]
        try check(partial,"A applied to Kado only")
        try press("프리셋 되돌리기")
        try check(sceneB,"undo A restored B")
        try press("작업 종료")
        guard try engine.pending().count == 3, !(try current()[index]).matches(sceneB[index]) else { throw Failure("Work-end did not dim") }
        try press("원래 밝기로 복원")
        try check(sceneB,"work-end restore returned to B")
        guard try engine.pending().isEmpty else { throw Failure("Work-end journal still present") }
        print("Scene B: Kado",kadoB,"iMac",macB)
    } catch { failure = error }
    if try !engine.pending().isEmpty { _ = try engine.restore() }
    if try controls().contains(where: { attribute($0,"AXDescription") as? String == "뒤로" }) { try press("뒤로") }
    try slider(kado,initialKado); try slider(mac,initialMac)
    for scene in created {
        try press("scene.list")
        try press(scene.name+" 삭제")
        try press("삭제 확인")
        try press("뒤로")
    }
    try check(initial,"original three values restored after QA")
    if let failure { throw failure }
}

do { try verify() } catch { print(error.localizedDescription); exit(1) }
