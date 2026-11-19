// Native acceptance driver. AX operations address the brightness app only.
// "occupied" probes Carbon registration; it never posts a keyboard event.
import AppKit
import Carbon

func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, key as CFString, &value)
    return value
}
func nodes(_ root: AXUIElement) -> [AXUIElement] {
    [root] + ((attr(root,"AXChildren") as? [AXUIElement]) ?? []).flatMap(nodes)
}
func perform() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.first == "occupied", args.count == 2, let chord = Chord(label: args[1]) {
        let registration = HotKey()
        do { try registration.replace(with: chord); print("free") }
        catch { guard error.localizedDescription.contains("-9878") else {throw error}; print("occupied") }
        return
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier:"local.displaybrightness.toggle").first,
          let command = args.first else { throw Failure("Missing app or operation") }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    guard let bars = attr(root,"AXExtrasMenuBar") else {throw Failure("No status item")}
    let bar = bars as! AXUIElement
    let windows = (attr(root,"AXWindows") as? [AXUIElement]) ?? []
    var list = windows.flatMap(nodes) + nodes(bar)
    if command == "open" {
        if !list.contains(where:{ attr($0,"AXRole") as? String == "AXPopover" }) {
            guard let icon = list.first(where:{attr($0,"AXRole") as? String == "AXMenuBarItem"}),
                  AXUIElementPerformAction(icon,kAXPressAction as CFString) == .success else {throw Failure("Could not open panel")}
        };return
    }
    if command == "tree" {
        for e in list {print(["AXRole","AXDescription","AXTitle","AXIdentifier","AXValue"].compactMap {attr(e,$0) as? String}.joined(separator:" | "))}
        return
    }
    if command == "checked", args.count == 2 {
        guard let checkbox = list.first(where: { element in
            attr(element, "AXRole") as? String == "AXCheckBox" &&
                ["AXTitle", "AXDescription"].contains { attr(element, $0) as? String == args[1] }
        }), let checked = attr(checkbox, "AXValue") as? NSNumber else { throw Failure("Checkbox unavailable") }
        print(checked.boolValue ? "on" : "off")
        return
    }
    if command == "field", args.count==2 {
        guard let field = list.first(where:{attr($0,"AXRole") as? String == "AXTextField"}),
              AXUIElementSetAttributeValue(field,kAXValueAttribute as CFString,args[1] as CFString) == .success else {throw Failure("Field unavailable")}
        return
    }
    guard command == "press", args.count==2 else {throw Failure("Unknown operation")}
    list = list.filter { ["AXButton","AXRadioButton","AXCheckBox"].contains(attr($0,"AXRole") as? String ?? "") }
    guard let target = list.first(where:{e in ["AXTitle","AXIdentifier","AXDescription"].contains {attr(e,$0) as? String == args[1]}}),
          (attr(target,"AXEnabled") as? NSNumber)?.boolValue != false,
          AXUIElementPerformAction(target,kAXPressAction as CFString) == .success else {throw Failure("Control unavailable: "+args[1])}
}
do {try perform()} catch {print(error.localizedDescription);exit(1)}
