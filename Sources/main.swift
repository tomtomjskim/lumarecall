import AppKit

do {
    let args = Array(CommandLine.arguments.dropFirst())
    let command = args.first ?? (Bundle.main.bundleURL.pathExtension == "app" ? "menu" : "toggle")
    let engine = BrightnessEngine()
    switch (command, args.count) {
    case ("menu", 0...1):
        let application = NSApplication.shared
        let delegate = BrightnessMenu()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    case ("list", 1):
        for display in try Display.connected() {
            print("\(display.name)\t\(display.builtIn ? "built-in" : "external")\t\(display.uuid)")
        }
    case ("restore", 1), ("toggle", 0...1), ("dim", 1):
        if command == "restore" || (command == "toggle" && FileManager.default.fileExists(atPath: engine.state.path)) {
            let result = try engine.restore()
            result.restored.forEach { print("\($0): restored") }
            guard result.errors.isEmpty else { throw Failure(result.errors.joined(separator: "\n")) }
        } else {
            try engine.dim(level: 0.25).forEach { print("\($0): dimmed") }
        }
    case ("hotkey-probe", 3):
        guard let key = UInt32(args[1]), let modifiers = UInt32(args[2]) else { throw Failure("Invalid shortcut") }
        let registration = HotKey()
        try registration.replace(with: Chord(key: key, modifiers: modifiers))
        print("global hotkey registered")
    case ("--help", 1): print("Usage: display-brightness-toggle [toggle|dim|restore|list|menu]")
    default: throw Failure("Usage: display-brightness-toggle [toggle|dim|restore|list|menu]")
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
