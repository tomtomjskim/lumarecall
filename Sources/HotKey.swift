import AppKit
import Carbon

struct Chord: Codable, Equatable {
    let key: UInt32
    let modifiers: UInt32

    var label: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + (Self.keys[key] ?? "키 "+String(key))
    }

    private static let keys: [UInt32:String] = [
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",
        13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",
        24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",
        35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",
        49:"Space",50:"`",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",
        101:"F9",109:"F10",103:"F11",111:"F12"
    ]

    init?(label: String) {
        var value = label.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var flags: UInt32 = 0
        for (symbol, flag) in [("⌃",controlKey),("⌥",optionKey),("⇧",shiftKey),("⌘",cmdKey)] {
            if value.contains(symbol) { flags |= UInt32(flag); value.removeAll { String($0) == symbol } }
        }
        guard flags & UInt32(controlKey | optionKey | cmdKey) != 0,
              let code = Self.keys.first(where: { $0.value.uppercased() == value })?.key else { return nil }
        self.init(key: code, modifiers: flags)
    }

    init(key: UInt32, modifiers: UInt32) {
        self.key = key
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0, event.keyCode != 53 else { return nil }
        self.init(key: UInt32(event.keyCode), modifiers: carbon)
    }
}

enum ShortcutOwner: Hashable {
    case workEnd, scene(UUID)
}

final class HotKey {
    private struct Binding {
        let chord: Chord
        let reference: EventHotKeyRef
        let id: UInt32
    }
    private var bindings: [ShortcutOwner: Binding] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var held = Set<UInt32>()
    var action: ((ShortcutOwner, Chord) -> Void)?
    var chord: Chord? { binding(for: .workEnd) }
    func binding(for owner: ShortcutOwner) -> Chord? { bindings[owner]?.chord }

    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            return Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().handle(event)
        }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        for binding in bindings.values { UnregisterEventHotKey(binding.reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    func clear(_ owner: ShortcutOwner = .workEnd) {
        if let old = bindings.removeValue(forKey: owner) {
            UnregisterEventHotKey(old.reference)
            held.remove(old.id)
        }
    }

    func replace(with candidate: Chord, for owner: ShortcutOwner = .workEnd) throws {
        if binding(for: owner) == candidate { return }
        if let conflict = bindings.first(where: { $0.value.chord == candidate }) {
            throw Failure(conflict.key == .workEnd ? "작업 종료에 등록된 조합입니다." : "다른 프리셋에 등록된 조합입니다.")
        }
        guard handler != nil else { throw Failure("전역 단축키 처리를 시작할 수 없습니다.") }
        var reference: EventHotKeyRef?
        let id = nextID
        nextID &+= 1
        let status = RegisterEventHotKey(candidate.key, candidate.modifiers,
            EventHotKeyID(signature: 0x44494d4d, id: id), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { throw Failure("macOS에서 이 단축키를 등록할 수 없습니다. (\(status))") }
        clear(owner)
        bindings[owner] = Binding(chord: candidate, reference: reference, id: id)
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var id = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
              id.signature == 0x44494d4d, let pair = bindings.first(where: { $0.value.id == id.id })
        else { return OSStatus(eventNotHandledErr) }
        if GetEventKind(event) == UInt32(kEventHotKeyReleased) { held.remove(id.id) }
        else if held.insert(id.id).inserted { action?(pair.key, pair.value.chord) }
        return noErr
    }
}
