import AppKit
import SwiftUI

struct RestoreQualification: Codable, Equatable {
    let chord: Chord
    let targets: [String]

    func confirms(current: Self?, fromShortcut: Bool, remaining: TimeInterval, fullyRestored: Bool) -> Bool {
        fromShortcut && remaining > 0 && fullyRestored && self == current
    }
}

final class BrightnessMenu: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let engine = BrightnessEngine()
    private let hotkey = HotKey()
    private let defaults = UserDefaults.standard
    private var item: NSStatusItem!
    private let panel = NSPopover()
    private let model = PanelModel()
    private var refreshTimer: Timer?
    private var disconnected = Set<String>()
    private var preview: Timer?
    private var previewProof: RestoreQualification?
    private var unresolved = Set<String>()
    private var selectedScene: (id: UUID, result: SceneApplication)?
    private var beforeScene: (id: UUID, result: SceneApplication)?
    private var choosing = false
    private var capture: ((Chord) -> Void)?
    private var recording = false
    private var busy = false
    private var lastToggle = Date.distantPast
    private var notice: String?
    private var startupFailure: String?

    private var excluded: Set<String> { Set(defaults.stringArray(forKey: "excludedDisplays") ?? []) }
    private var pending: [SavedDisplay]? { try? engine.pending() }
    private var targets: [String] {
        ((try? Display.connected()) ?? []).filter { !$0.mirrorMember && !excluded.contains($0.uuid) }
            .map(\.qualificationIdentity).sorted()
    }

    private func qualification(_ targets: [String]) -> RestoreQualification? {
        guard let chord = hotkey.chord, !targets.isEmpty else { return nil }
        return RestoreQualification(chord: chord, targets: targets)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sessionChanged),
            name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sessionChanged),
            name: NSWorkspace.didWakeNotification, object: nil)
        hotkey.action = { [weak self] owner, chord in
            guard let self else { return }
            if self.recording { if NSApp.isActive { self.capture?(chord) }; return }
            guard !self.choosing, !self.busy else { return }
            switch owner {
            case .workEnd: self.toggle(fromShortcut: true)
            case .scene(let id):
                guard self.pending?.isEmpty == true else { self.announce("작업 종료 밝기를 먼저 복원하세요."); return }
                self.perform(.applyScene(id))
            }
        }
        if let chord = savedChord(.workEnd) {
            do { try hotkey.replace(with: chord) } catch { startupFailure = error.localizedDescription }
        }
        for scene in (try? engine.scenes()) ?? [] {
            let owner = ShortcutOwner.scene(scene.id)
            if let chord = savedChord(owner) { try? hotkey.replace(with: chord, for: owner) }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "LumaRecall")
        item.button?.setAccessibilityLabel("LumaRecall · 화면 밝기 제어")
        item.button?.toolTip = "LumaRecall · 화면 밝기 제어"
        panel.behavior = .transient
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: BrightnessPanel(model: model) { [weak self] in self?.perform($0) })
        item.button?.target = self
        item.button?.action = #selector(openPanel)
        NotificationCenter.default.addObserver(self, selector: #selector(configurationChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        configurationChanged()
        if startupFailure != nil, pending?.isEmpty == false { restore() }
    }

    @objc private func sessionChanged() {
        configurationChanged()
        if preview != nil || (defaults.bool(forKey: "deepDim") && pending?.isEmpty == false) { restore() }
        updateIcon()
    }

    private func updateIcon() {
        let title = pending?.isEmpty == true ? "LumaRecall · 화면 밝기 제어" : "LumaRecall · 화면 밝기 제어 · 복원 필요"
        item.button?.image = NSImage(systemSymbolName: pending?.isEmpty == true ? "sun.max" : "sun.min",
                                    accessibilityDescription: title)
        item.button?.setAccessibilityLabel(title)
        item.button?.toolTip = notice ?? title
    }

    @objc private func configurationChanged() {
        let current = qualification(targets)
        if previewProof != current { previewProof = nil }
        updateIcon()
        if panel.isShown { refreshPanel() }
    }

    @objc private func openPanel() {
        if panel.isShown { panel.performClose(nil); return }
        guard let button = item.button else { return }
        model.settings = false
        model.scenePage = .closed
        refreshPanel()
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panel.contentViewController?.view.window?.makeKey()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshPanel() }
    }

    func popoverDidClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func perform(_ action: PanelAction) {
        switch action {
        case .toggle: toggle(fromShortcut: false)
        case .saveScene(let name, let ids, let editing):
            do {
                let names = Dictionary(uniqueKeysWithValues: model.state.displays.map { ($0.id, $0.name) })
                let scene = try engine.saveScene(name: name, ids: ids, editing: editing, displayNames: names)
                model.scenePage = model.scenePage == .save ? .list : .closed
                if selectedScene?.id == editing { selectedScene = nil }
                announce(scene.name + " · " + String(scene.targets.count) + "대 저장됨")
            } catch { announce(error.localizedDescription) }
        case .applyScene(let id):
            do {
                guard let scene = try engine.scenes().first(where: { $0.id == id }) else { throw Failure("삭제된 프리셋입니다.") }
                let result = try engine.applyScene(scene)
                beforeScene = selectedScene
                selectedScene = (id, result)
                model.scenePage = .closed
                announce(scene.name + " · " + String(result.total) + "대 중 " + String(result.values.count) + "대 적용")
            } catch { announce(error.localizedDescription) }
        case .undoScene:
            do {
                let message = try engine.undoScene()
                selectedScene = beforeScene
                beforeScene = nil
                model.scenePage = .closed
                announce(message)
            } catch { announce(error.localizedDescription) }
        case .deleteScene(let id):
            do {
                try engine.deleteScene(id)
                clearBinding(.scene(id))
                if selectedScene?.id == id { selectedScene = nil }
                if beforeScene?.id == id { beforeScene = nil }
                announce("프리셋을 삭제했습니다.")
            } catch { announce(error.localizedDescription) }
        case .adjust(let uuid, let percent, let reading):
            do { try engine.adjust(uuid: uuid, percent: percent, from: reading); selectedScene = nil; notice = nil }
            catch { announce(error.localizedDescription) }
        case .alias(let uuid, let value):
            defaults.set(String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(50)), forKey: "alias." + uuid)
        case .record(let owner):
            guard !recording, pending?.isEmpty == true else { return }
            recording = true
            DispatchQueue.main.async { [weak self] in self?.showRecorder(owner) }
        case .clear(let owner):
            if pending?.isEmpty == true { clearBinding(owner) }
        case .test: startPreview()
        case .deep(let enabled):
            guard pending?.isEmpty == true, !enabled || qualification(targets) != nil else { break }
            defaults.set(enabled, forKey: "deepDim")
        case .quit: quit()
        case .include(let id): toggleTarget(id)
        case .restore(let id): restore(choice: id)
        case .keep(let id): restore(choice: id, keep: true)
        }
        refreshPanel()
    }

    private func refreshPanel() {
        var view = PanelState()
        let journal = pending
        let entries = journal ?? []
        let displays = (try? Display.connected()) ?? []
        let connected = Set(displays.map(\.uuid))
        let available = entries.filter { connected.contains($0.uuid) }
        let missing = entries.filter { !connected.contains($0.uuid) }
        disconnected.formIntersection(entries.map(\.uuid))
        disconnected.formUnion(missing.map(\.uuid))
        let eligible = displays.filter { !$0.mirrorMember && !excluded.contains($0.uuid) }
        view.editable = journal?.isEmpty == true
        view.canTest = view.editable && hotkey.chord != nil && !eligible.isEmpty
        view.deep = defaults.bool(forKey: "deepDim")
        view.shortcut = hotkey.chord?.label ?? "미설정"
        view.enabled = !busy && journal != nil && (entries.isEmpty ? !eligible.isEmpty : !available.isEmpty)
        if journal == nil {
            view.title = "복원 기록 확인 필요"; view.detail = "복원 기록을 읽을 수 없습니다."
        } else if !entries.isEmpty {
            if available.isEmpty {
                view.title = "화면 연결 대기"; view.detail = "분리한 화면을 연결하면 복원할 수 있습니다."
            } else {
                view.title = preview != nil ? "지금 복원" : (!missing.isEmpty ? "연결된 "+String(available.count)+"대 복원" :
                    (available.count == 1 ? available[0].name+" 복원" : "원래 밝기로 복원"))
                view.detail = preview.map { "자동 복원까지 "+String(max(0,Int(ceil($0.fireDate.timeIntervalSinceNow))))+"초" } ??
                    "저장된 이전 값으로 복원합니다."
            }
        } else if eligible.isEmpty {
            view.title = "적용할 화면 없음"; view.detail = "화면 연결과 설정의 적용 대상을 확인하세요."
        } else {
            let first = !view.deep && !defaults.bool(forKey: "previewConfirmed")
            view.title = view.deep && hotkey.chord == nil ? "복원 단축키 설정 필요" : first ? "25%로 미리보기" : "작업 종료"
            if view.deep && hotkey.chord == nil { view.enabled = false }
            view.detail = first ? "10초 후 자동 복원" : "화면 "+String(eligible.count)+"대 · "+(view.deep ? "1%" : "25%")+" 목표"
        }
        for display in displays {
            let entry = entries.first { $0.uuid == display.uuid }
            let sample = try? SavedDisplay(display)
            let value = sample?.backlight ?? sample?.gamma?.peak
            let current = sample?.original
            let changed = current.map { v in
                entry?.applied.map { !$0.matches(v) } == true && entry?.original.map { !$0.matches(v) } == true
            } ?? false
            let included = !display.mirrorMember && !excluded.contains(display.uuid)
            let name = displays.filter { $0.name == display.name }.count > 1 ? display.name+" · "+display.uuid.suffix(4) : display.name
            let status: String
            if changed { status = "외부 변경 · 복원 선택" }
            else if entry != nil { status = disconnected.contains(display.uuid) ? "복원 대기" : "디밍 · 복원 가능" }
            else { status = included ? "연결됨" : "제외" }
            let alias = defaults.string(forKey: "alias." + display.uuid) ?? ""
            let reading = view.editable ? current.flatMap { engine.sliderReading(for: display, sample: $0) } : nil
            let shown = reading.map { String($0.percent) + "%" } ?? value.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
            view.displays.append(PanelDisplay(id: display.uuid, name: alias.isEmpty ? name : alias, deviceName: name, alias: alias, reading: reading,
                method: display.mirrorMember ? "미러링" : sample?.backlight != nil ? "내장 백라이트" : (reading == nil ? "소프트웨어 · 감마 피크" : "소프트웨어 배율"),
                value: shown, status: current == nil ? "값 읽기 실패" : status,
                included: included, selectable: view.editable && !display.mirrorMember, needsChoice: changed))
        }
        for entry in missing {
            view.displays.append(PanelDisplay(id: entry.uuid, name: entry.name, deviceName: entry.name, alias: "", reading: nil, method: entry.backlight != nil ? "내장 백라이트" : "소프트웨어 디밍",
                value: "—", status: "분리 · 복원 대기", included: true, selectable: false, needsChoice: false))
        }
        if let row = view.displays.first(where: { $0.needsChoice && unresolved.contains($0.id) }) {
            view.title = row.name + " 밝기 선택"
            view.detail = "현재 값 유지 또는 이전 값 복원"
        }
        if view.editable, let selected = selectedScene {
            let changed = view.displays.contains { row in
                guard let expected = selected.result.values[row.id], let reading = row.reading else { return false }
                return !expected.matches(reading.sample)
            }
            if changed { selectedScene = nil }
        }
        do { view.scenes = try engine.scenes() }
        catch { view.libraryError = error.localizedDescription }
        for scene in view.scenes {
            let owner = ShortcutOwner.scene(scene.id)
            if let saved = savedChord(owner) {
                view.sceneKeys[scene.id] = saved.label + (hotkey.binding(for: owner) == nil ? " · 비활성" : "")
            }
        }
        if let saved = savedChord(.workEnd), hotkey.chord == nil { view.shortcut = saved.label + " · 비활성" }
        view.selectedScene = selectedScene?.id
        view.canUndo = view.editable && engine.canUndoScene
        view.message = view.libraryError ?? startupFailure ?? notice
        if model.state != view { model.state = view }
    }

    private func toggleTarget(_ uuid: String) {
        guard pending?.isEmpty == true else { return }
        var ids = excluded
        if ids.contains(uuid) { ids.remove(uuid) } else { ids.insert(uuid) }
        defaults.set(Array(ids), forKey: "excludedDisplays")
    }



    private func toggle(fromShortcut: Bool) {
        guard !busy, !choosing, Date().timeIntervalSince(lastToggle) > 0.35 else { return }
        lastToggle = Date()
        guard let entries = pending else { announce("복원 기록을 읽을 수 없습니다."); return }
        if !entries.isEmpty {
            if !unresolved.isEmpty {
                refreshPanel()
                if let row = model.state.displays.first(where: { unresolved.contains($0.id) && $0.needsChoice }),
                   let entry = entries.first(where: { $0.uuid == row.id }) {
                    presentChoice(row, entry: entry)
                    return
                }
            }
            let wasPreview = preview != nil
            let remaining = preview?.fireDate.timeIntervalSinceNow ?? 0
            let proof = previewProof
            let restored = restore() && pending?.isEmpty == true
            if let proof, proof.confirms(current: qualification(targets), fromShortcut: fromShortcut,
                                         remaining: remaining, fullyRestored: restored) {
                defaults.set(true, forKey: "previewConfirmed")
                announce("복원 단축키를 확인했습니다.")
            } else if wasPreview, restored {
                defaults.set(true, forKey: "previewConfirmed")
            }
            return
        }
        if defaults.bool(forKey: "deepDim") {
            guard let current = qualification(targets) else {
                announce("1%를 적용하려면 복원 단축키와 대상 화면을 확인하세요.")
                return
            }
            dim(0.01, required: current.targets)
        } else if !defaults.bool(forKey: "previewConfirmed") {
            startPreview(seconds: 10)
        } else {
            dim(0.25)
        }
    }

    private func presentChoice(_ row: PanelDisplay, entry: SavedDisplay) {
        choosing = true
        let previous = NSWorkspace.shared.frontmostApplication
        DispatchQueue.main.async { [self] in
            defer { choosing = false }
            let alert = NSAlert()
            alert.messageText = row.name + " 밝기 선택"
            alert.informativeText = "이 화면의 밝기가 외부에서 변경됐습니다. 현재 값을 유지하거나 디밍 전 값으로 복원할 수 있습니다."
            let keep = alert.addButton(withTitle: "현재 값 유지")
            alert.addButton(withTitle: "이전 값 복원")
            alert.addButton(withTitle: "나중에").keyEquivalent = "\u{1b}"
            alert.window.initialFirstResponder = keep
            NSApp.activate(ignoringOtherApps: true)
            let answer = alert.runModal()
            alert.window.orderOut(nil)
            if answer == .alertFirstButtonReturn || answer == .alertSecondButtonReturn {
                restore(choice: row.id, keep: answer == .alertFirstButtonReturn, expected: entry)
            }
            if NSApp.isActive, previous?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previous?.activate(options: [])
            }
        }
    }

    @discardableResult
    private func dim(_ level: Float, required: [String]? = nil) -> Bool {
        busy = true
        defer { busy = false; updateIcon() }
        do {
            unresolved.removeAll()
            let changed = try engine.dim(level: level, excluding: excluded, required: required)
            announce("화면 \(changed.count)대를 어둡게 했습니다.")
            return true
        } catch { announce(error.localizedDescription); return false }
    }

    @objc private func testShortcut() { startPreview() }

    private func startPreview(seconds: Int = shortcutTestSeconds) {
        guard preview == nil, pending?.isEmpty == true else { return }
        let plan = targets
        let proof = qualification(plan)
        guard dim(0.25, required: plan) else { return }
        previewProof = proof
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.restore()
            if self.panel.isShown { self.refreshPanel() }
        }
        preview = timer
        RunLoop.main.add(timer, forMode: .common)
        announce(hotkey.chord.map { "\(seconds)초 안에 \($0.label)로 복원하세요." }
                 ?? "\(seconds)초 후 자동 복원됩니다.")
    }

    @discardableResult
    private func restore(choice: String? = nil, keep: Bool = false, expected: SavedDisplay? = nil) -> Bool {
        preview?.invalidate()
        preview = nil
        previewProof = nil
        busy = true
        defer { busy = false; updateIcon() }
        do {
            let result = try engine.restore(choice: choice, keepCurrent: keep, expected: expected)
            unresolved.formIntersection((pending ?? []).map(\.uuid))
            unresolved.formUnion(result.conflicts)
            if !result.errors.isEmpty {
                var lines = result.errors
                if !result.restored.isEmpty { lines.insert("화면 "+String(result.restored.count)+"대 복원됨", at: 0) }
                if !result.conflicts.isEmpty { lines.append("밝기 선택을 열려면 "+(hotkey.chord?.label ?? "패널의 상단 버튼")+"을 누르세요.") }
                announce(lines.joined(separator: "\n"))
                return false
            }
            if keep && !result.restored.isEmpty {
                announce(result.restored.joined(separator: ", ")+" · 현재 값을 유지했습니다.")
                return true
            }
            if pending?.isEmpty == true {
                announce("이전 밝기 복원이 끝났습니다.")
            } else { announce("아직 복원하지 않은 화면이 있습니다.") }
            return true
        } catch { announce(error.localizedDescription); return false }
    }

    private func preferenceKey(_ owner: ShortcutOwner) -> String {
        switch owner {
        case .workEnd: return "hotkey"
        case .scene(let id): return "sceneShortcut." + id.uuidString
        }
    }

    private func savedChord(_ owner: ShortcutOwner) -> Chord? {
        defaults.data(forKey: preferenceKey(owner)).flatMap { try? JSONDecoder().decode(Chord.self, from: $0) }
    }

    private func clearBinding(_ owner: ShortcutOwner) {
        hotkey.clear(owner)
        defaults.removeObject(forKey: preferenceKey(owner))
        if owner == .workEnd { startupFailure = nil }
    }

    private func register(_ chord: Chord, for owner: ShortcutOwner) throws {
        guard try engine.pending().isEmpty else { throw Failure("작업 종료 밝기를 먼저 복원하세요.") }
        let scenes = try engine.scenes()
        if case let .scene(id) = owner, !scenes.contains(where: { $0.id == id }) { throw Failure("삭제된 프리셋입니다.") }
        if owner != .workEnd && savedChord(.workEnd) == chord { throw Failure("작업 종료에 등록된 조합입니다.") }
        for scene in scenes where owner != .scene(scene.id) && savedChord(.scene(scene.id)) == chord {
            throw Failure("‘" + scene.name + "’에 등록된 조합입니다.")
        }
        let data = try JSONEncoder().encode(chord)
        try hotkey.replace(with: chord, for: owner)
        defaults.set(data, forKey: preferenceKey(owner))
        if owner == .workEnd { startupFailure = nil }
    }

    private func showRecorder(_ owner: ShortcutOwner) {
        guard pending?.isEmpty == true else { recording = false; return }
        panel.behavior = .applicationDefined
        let alert = NSAlert()
        switch owner {
        case .workEnd: alert.messageText = "작업 종료 단축키"
        case .scene(let id): alert.messageText = (model.state.scenes.first { $0.id == id }?.name ?? "프리셋") + " 단축키"
        }
        alert.informativeText = "새 조합을 누른 뒤 저장하세요."
        let field = NSTextField(string: savedChord(owner)?.label ?? "")
        field.frame.size = NSSize(width: 230, height: 24)
        field.placeholderString = "예: ⌃⌥1"
        field.setAccessibilityLabel("새 단축키")
        alert.accessoryView = field
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소").keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
        var captured: Chord? = savedChord(owner)
        capture = { chord in
            captured = chord
            field.stringValue = chord.label
            field.currentEditor()?.string = chord.label
        }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.window === alert.window, !event.isARepeat, let chord = Chord(event: event) else { return event }
            self?.capture?(chord)
            return nil
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            capture = nil
            alert.window.orderOut(nil)
            recording = false
            panel.behavior = .transient
        }
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                let text = field.stringValue
                guard let chord = captured.flatMap({ $0.label == text ? $0 : nil }) ?? Chord(label: text) else {
                    throw Failure("Command, Control 또는 Option이 포함된 조합을 입력하세요.")
                }
                try register(chord, for: owner)
                announce("단축키 " + chord.label + " 저장됨")
                break
            } catch { alert.informativeText = error.localizedDescription }
        }
    }

    private func announce(_ message: String) {
        notice = message
        item.button?.toolTip = message
        if let button = item.button {
            NSAccessibility.post(element: button, notification: .announcementRequested,
                                 userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if pending?.isEmpty == true { return .terminateNow }
        if restore(), pending?.isEmpty == true { return .terminateNow }
        while true {
            let alert = NSAlert()
            alert.messageText = "복원하지 않은 화면이 있습니다."
            alert.informativeText = "연결을 확인하고 다시 복원하거나, 기록을 남긴 채 종료할 수 있습니다."
            alert.addButton(withTitle: "다시 복원")
            alert.addButton(withTitle: "종료 취소")
            alert.addButton(withTitle: "기록 보존 후 종료")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if restore(), pending?.isEmpty == true { return .terminateNow }
            case .alertThirdButtonReturn: return .terminateNow
            default: return .terminateCancel
            }
        }
    }
}
