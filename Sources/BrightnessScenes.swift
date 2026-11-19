import Foundation

struct SceneTarget: Codable, Equatable {
    let uuid: String
    let software: Bool
    let percent: Int
    var displayName: String? = nil
}

struct BrightnessScene: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let targets: [SceneTarget]
}

extension BrightnessScene {
    static func automaticName(for targets: [SceneTarget], allScreens: Bool, used: Set<String>) -> String {
        guard let first = targets.first else { return "" }
        let parts = targets.map { target in
            String((target.displayName ?? "화면").prefix(28)) + " " + String(target.percent) + "%"
        }
        let base: String
        if targets.count > 1, allScreens, targets.allSatisfy({ $0.percent == first.percent }) {
            base = "전체 " + String(first.percent) + "%"
        } else if parts.joined(separator: " · ").count <= 44 {
            base = parts.joined(separator: " · ")
        } else {
            base = parts[0] + " 외 " + String(parts.count - 1) + "대"
        }
        var name = base
        var number = 2
        while used.contains(name) {
            let suffix = " (" + String(number) + ")"
            name = String(base.prefix(50 - suffix.count)) + suffix
            number += 1
        }
        return name
    }
}

private struct UndoTarget: Codable {
    var display: SavedDisplay
    let previousCalibration: Data?
}

struct SceneApplication {
    let values: [String: DisplayValue]
    let total: Int
}

extension BrightnessEngine {
    private var library: URL { directory.appendingPathComponent("scenes.json") }
    private var undoFile: URL { directory.appendingPathComponent("scene-undo.json") }
    var canUndoScene: Bool { FileManager.default.fileExists(atPath: undoFile.path) }

    private func load<T: Decodable>(_ type: T.Type, at url: URL, fallback: T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    func scenes() throws -> [BrightnessScene] {
        try load([BrightnessScene].self, at: library, fallback: [])
    }

    @discardableResult
    func saveScene(name: String, ids: Set<String>, editing: UUID? = nil, displayNames: [String: String] = [:]) throws -> BrightnessScene {
        try locked {
            var title = name.trimmingCharacters(in: .whitespacesAndNewlines)
            var list = try scenes()
            guard (editing == nil || !title.isEmpty), title.count <= 50, !ids.isEmpty, try pending().isEmpty else {
                throw Failure("프리셋 이름과 저장할 화면을 확인하세요.")
            }
            guard !list.contains(where: { $0.name == title && $0.id != editing }) else { throw Failure("같은 이름의 프리셋이 있습니다.") }
            let old = list.first(where: { $0.id == editing })
            guard editing == nil || old != nil else { throw Failure("삭제된 프리셋입니다.") }
            let connected = try Display.connected()
            let targets = try ids.sorted().map { id -> SceneTarget in
                if let prior = old?.targets.first(where: { $0.uuid == id }) { return prior }
                let matches = connected.filter { $0.uuid == id }
                guard matches.count == 1, let display = matches.first else { throw Failure("화면 연결이 바뀌었습니다.") }
                let entry = try SavedDisplay(display)
                guard let value = entry.original, let reading = sliderReading(for: display, sample: value),
                      (10...100).contains(reading.percent) else { throw Failure(display.name + "의 밝기를 저장할 수 없습니다.") }
                return SceneTarget(uuid: display.uuid, software: reading.base != nil, percent: reading.percent,
                                   displayName: displayNames[id] ?? display.name)
            }
            if title.isEmpty {
                title = BrightnessScene.automaticName(for: targets, allScreens: ids == Set(connected.map(\.uuid)),
                                                      used: Set(list.map(\.name)))
            }
            let scene = BrightnessScene(id: editing ?? UUID(), name: title, targets: targets)
            if let index = list.firstIndex(where: { $0.id == scene.id }) { list[index] = scene }
            else { list.append(scene) }
            try JSONEncoder().encode(list).write(to: library, options: .atomic)
            return scene
        }
    }

    func deleteScene(_ id: UUID) throws {
        try locked {
            try JSONEncoder().encode(scenes().filter { $0.id != id }).write(to: library, options: .atomic)
        }
    }

    private func saveUndo(_ entries: [UndoTarget]) throws {
        if !entries.isEmpty {
            try JSONEncoder().encode(entries).write(to: undoFile, options: .atomic)
        } else if canUndoScene {
            try FileManager.default.removeItem(at: undoFile)
        }
    }

    func applyScene(_ scene: BrightnessScene) throws -> SceneApplication {
        try locked {
            guard try pending().isEmpty else { throw Failure("작업 종료 밝기를 먼저 복원하세요.") }
            let screens = try Display.connected()
            var plan: [(UndoTarget, String, GammaAdjustment?)] = []
            for target in scene.targets {
                let available = screens.filter { $0.uuid == target.uuid }
                guard let display = available.first else { continue }
                var entry = try SavedDisplay(display)
                guard available.count == 1, let sample = entry.original,
                      let reading = sliderReading(for: display, sample: sample),
                      target.software == (reading.base != nil), (10...100).contains(target.percent) else {
                    throw Failure(display.name + "의 제어 방식 또는 범위가 바뀌었습니다.")
                }
                let adjustment = reading.base.map { GammaAdjustment(base: $0, percent: target.percent) }
                let wanted = adjustment.map { DisplayValue.gamma($0.output) } ?? .backlight(Float(target.percent) / 100)
                guard wanted.isVisible else { throw Failure(display.name + "의 목표 밝기가 너무 낮습니다.") }
                entry.applied = wanted
                let prior = UserDefaults.standard.data(forKey: "gammaAdjustment." + target.uuid)
                plan.append((UndoTarget(display: entry, previousCalibration: prior), display.identity, adjustment))
            }
            guard !plan.isEmpty else { throw Failure("프리셋에 저장한 화면이 연결되어 있지 않습니다.") }
            let previous = try load([UndoTarget].self, at: undoFile, fallback: [])
            var attempted: [UndoTarget] = []
            var values: [String: DisplayValue] = [:]
            do {
                for (undo, identity, adjustment) in plan {
                    let entry = undo.display
                    let live = try liveDisplay(entry, expected: identity)
                    guard let original = entry.original, let wanted = entry.applied,
                          try entry.read(live.id).matches(original) else { throw Failure(entry.name + "의 밝기가 변경됐습니다.") }
                    attempted.append(undo)
                    try saveUndo(attempted)
                    if !original.matches(wanted) { try wanted.write(live.id) }
                    let checked = try entry.read(liveDisplay(entry, expected: identity).id)
                    guard checked.matches(wanted) else { throw Failure(entry.name + "의 적용값을 확인할 수 없습니다.") }
                    if let adjustment {
                        UserDefaults.standard.set(try JSONEncoder().encode(adjustment), forKey: "gammaAdjustment." + entry.uuid)
                    }
                    values[entry.uuid] = checked
                }
            } catch {
                let failure = error
                _ = try undoLocked(attempted)
                try saveUndo(previous)
                throw failure
            }
            return SceneApplication(values: values, total: scene.targets.count)
        }
    }

    func undoScene() throws -> String {
        try locked {
            guard try pending().isEmpty else { throw Failure("작업 종료 밝기를 먼저 복원하세요.") }
            let entries = try load([UndoTarget].self, at: undoFile, fallback: [])
            guard !entries.isEmpty else { throw Failure("되돌릴 프리셋이 없습니다.") }
            return try undoLocked(entries)
        }
    }

    private func undoLocked(_ entries: [UndoTarget]) throws -> String {
        var remaining = entries
        var kept = 0
        var failures: [String] = []
        for target in entries {
            let entry = target.display
            do {
                let live = try liveDisplay(entry)
                let current = try entry.read(live.id)
                guard let original = entry.original, let applied = entry.applied else { throw Failure("프리셋 기록 확인 필요") }
                if current.matches(original) || current.matches(applied) {
                    if !current.matches(original) { try original.write(live.id) }
                    guard try entry.read(liveDisplay(entry, expected: live.identity).id).matches(original) else {
                        throw Failure("이전 밝기를 확인할 수 없습니다.")
                    }
                    UserDefaults.standard.set(target.previousCalibration, forKey: "gammaAdjustment." + entry.uuid)
                } else { kept += 1 }
                remaining.removeAll { $0.display.uuid == entry.uuid }
                try saveUndo(remaining)
            } catch { failures.append(entry.name + " · " + error.localizedDescription) }
        }
        if !failures.isEmpty { throw Failure(failures.joined(separator: "\n")) }
        return kept == 0 ? "프리셋 적용 직전 밝기로 되돌렸습니다." : "외부에서 바뀐 화면 "+String(kept)+"대는 현재 값을 유지했습니다."
    }
}
