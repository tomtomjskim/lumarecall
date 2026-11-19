import SwiftUI

let shortcutTestSeconds = 3

struct PanelDisplay: Identifiable, Equatable {
    let id: String
    let name, deviceName, alias: String
    let reading: SliderReading?
    let method, value, status: String
    let included, selectable, needsChoice: Bool
}

struct PanelState: Equatable {
    var title = "모두 어둡게", detail = "", shortcut = "미설정"
    var enabled = false, editable = false, deep = false, canTest = false
    var scenes: [BrightnessScene] = []
    var selectedScene: UUID?
    var sceneKeys: [UUID:String] = [:]
    var canUndo = false
    var libraryError: String?
    var message: String?
    var displays: [PanelDisplay] = []
}

enum ScenePage { case closed, list, pick, save }

final class PanelModel: ObservableObject {
    @Published var state = PanelState()
    @Published var settings = false
    @Published var scenePage = ScenePage.closed
}

enum PanelAction {
    case saveScene(String, Set<String>, UUID?), applyScene(UUID), deleteScene(UUID), undoScene
    case adjust(String, Int, SliderReading), alias(String, String)
    case record(ShortcutOwner), clear(ShortcutOwner)
    case toggle, test, deep(Bool), quit, include(String), restore(String), keep(String)
}

struct BrightnessPanel: View {
    @ObservedObject var model: PanelModel
    let perform: (PanelAction) -> Void
    @AccessibilityFocusState private var navigationFocus: Bool
    @State private var tab = "일반"
    @State private var detailID: String?
    @State private var aliasText = ""
    @State private var editingScene: BrightnessScene?
    @State private var sceneName = ""
    @State private var sceneTargets = Set<String>()
    @State private var showPresetHelp = false
    @State private var confirmQuit = false
    @State private var confirmDelete: UUID?
    private var state: PanelState { model.state }

    private func icon(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 25, height: 24) }
            .buttonStyle(.borderless).accessibilityLabel(label).help(label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(model.scenePage == .save ? (editingScene == nil ? "현재 구성 저장" : "프리셋 편집") : model.scenePage == .pick ? "프리셋 선택" : model.scenePage == .list ? "프리셋 관리" : detailID != nil ? "디스플레이 상세" : model.settings ? "설정" : "LumaRecall").font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                icon(model.scenePage != .closed || model.settings || detailID != nil ? "arrow.backward" : "gearshape",
                     model.scenePage != .closed || model.settings || detailID != nil ? "뒤로" : "설정") {
                    if model.scenePage == .save { model.scenePage = .list }
                    else if model.scenePage == .list || model.scenePage == .pick { model.scenePage = .closed; confirmDelete = nil }
                    else if detailID != nil { detailID = nil } else { model.settings.toggle() }
                    navigationFocus = true
                }.accessibilityFocused($navigationFocus)
            }
            if model.scenePage == .save { sceneEditor }
            else if model.scenePage == .list || model.scenePage == .pick { sceneList }
            else if let id = detailID {
                if let row = state.displays.first(where: { $0.id == id }) {
                    Text(row.deviceName).bold()
                    Text(row.method).foregroundStyle(.secondary)
                    TextField("화면 별칭", text: $aliasText, onCommit: { perform(.alias(id, aliasText)) })
                    Button("별칭 저장") { perform(.alias(id, aliasText)); detailID = nil }
                    inclusion(row)
                } else { Text("화면 연결 대기") }
            } else if model.settings { settings } else { dashboard }
            if let message = state.message {
                Divider()
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18).frame(width: 380)
        .onDisappear { detailID = nil }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Button { perform(.toggle) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(state.title).font(.headline); Spacer(); Text(state.shortcut).font(.caption.bold()) }
                    Text(state.detail).font(.caption)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .foregroundStyle(.white).background(Color(red: 0.09, green: 0.30, blue: 0.34),
                                                    in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).disabled(!state.enabled)
            Text("디스플레이").font(.caption).foregroundStyle(.secondary)
            ScrollView { VStack(spacing: 8) {
                ForEach(state.displays) { row in
                    Divider()
                    HStack {
                        Text(row.name).bold()
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(row.value).monospacedDigit()
                            if row.status != "연결됨" { Text(row.status).font(.caption) }
                        }
                        icon("info.circle", row.name + " 상세") { showDetail(row) }
                    }
                    HStack { Text(row.method).font(.caption).foregroundStyle(.secondary); Spacer() }
                    if let reading = row.reading {
                        DisplaySlider(row: row, reading: reading) { value, initial in
                            perform(.adjust(row.id, value, initial))
                        }.frame(height: 20)
                    }
                    if row.needsChoice {
                        HStack {
                            Button("이전 값 복원") { perform(.restore(row.id)) }
                            Button("현재 값 유지") { perform(.keep(row.id)) }
                        }
                    }
                }
            }}.frame(height: min(345, CGFloat(state.displays.count) * 66 + CGFloat(state.displays.filter { $0.reading != nil }.count) * 26 + CGFloat(state.displays.filter(\.needsChoice).count) * 32))
            if state.displays.isEmpty { Text("연결된 디스플레이가 없습니다.").foregroundStyle(.secondary) }
            Divider()
            HStack {
                Text("프리셋").font(.headline)
                icon("info.circle", "프리셋 사용법") { showPresetHelp = true }
                    .popover(isPresented: $showPresetHelp) { presetHelp }
                Spacer()
                Button("관리") {
                    confirmDelete = nil
                    model.scenePage = .list
                }.disabled(!state.editable || state.libraryError != nil)
                 .accessibilityIdentifier("scene.list")
            }
            HStack {
                if !state.scenes.isEmpty {
                    Button {
                        model.scenePage = .pick
                    } label: {
                        Text(state.scenes.first { $0.id == state.selectedScene }?.name ?? "프리셋 선택")
                            .lineLimit(1)
                    }.disabled(!state.editable || state.libraryError != nil)
                }
                Button("현재 밝기 저장") {
                    perform(.saveScene("", savableIDs, nil))
                }.disabled(!state.editable || savableIDs.isEmpty || state.libraryError != nil)
                Spacer(minLength: 0)
                icon("arrow.uturn.backward", "프리셋 되돌리기") { perform(.undoScene) }.disabled(!state.canUndo)
            }
            if !state.editable && state.libraryError == nil {
                Text("밝기를 복원한 뒤 프리셋을 저장하거나 적용할 수 있습니다.").font(.caption)
            }
        }
    }

    private var presetHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("밝기 프리셋 사용법").font(.headline)
                Spacer()
                icon("xmark", "사용법 닫기") { showPresetHelp = false }
                    .keyboardShortcut(.cancelAction)
            }
            Text("프리셋에는 화면별 밝기와 적용할 화면을 함께 저장합니다.")
            Text("저장").bold()
            Text("슬라이더를 맞춘 뒤 ‘현재 밝기 저장’을 누르세요. 대상 화면과 밝기가 이름에 들어갑니다.")
            Text("한 화면만 저장").bold()
            Text("예를 들어 Kado만 60%로 쓰려면 밝기를 먼저 맞추고 ‘관리 → 화면을 골라 저장’에서 Kado만 선택하세요.")
            Text("적용과 되돌리기").bold()
            Text("홈의 ‘프리셋 선택’에서 화면별 밝기를 확인한 뒤 이름을 누르세요. ↶를 누르면 적용 직전 밝기로 돌아갑니다.")
            Text("이름과 대상은 ‘관리’에서, 단축키는 ‘설정 → 단축키’에서 바꿀 수 있습니다.").font(.caption)
        }.padding(16).frame(width: 290).fixedSize(horizontal: false, vertical: true)
    }

    private var savableIDs: Set<String> {
        Set(state.displays.filter { row in row.reading.map { (10...100).contains($0.percent) } == true }.map(\.id))
    }

    private func beginSaving(_ scene: BrightnessScene? = nil) {
        editingScene = scene
        sceneName = scene?.name ?? ""
        sceneTargets = scene.map { Set($0.targets.map(\.uuid)) } ?? savableIDs
        model.scenePage = .save
    }

    private var sceneList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.scenes.isEmpty { Text("저장된 프리셋이 없습니다.").foregroundStyle(.secondary) }
            else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(state.scenes) { scene in
                            HStack(alignment: .top) {
                                Button {
                                    perform(.applyScene(scene.id))
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(scene.name).font(.headline)
                                        Text(targetSummary(scene)).font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                      .fixedSize(horizontal: false, vertical: true)
                                      .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                 .accessibilityIdentifier("scene.apply." + scene.id.uuidString)
                                 .disabled(!state.editable || state.libraryError != nil)
                                if model.scenePage == .list {
                                    if let key = state.sceneKeys[scene.id] { Text(key).font(.caption) }
                                    icon("pencil", scene.name + " 편집") { beginSaving(scene) }.disabled(!state.editable)
                                    if confirmDelete == scene.id {
                                        Button("삭제 확인") { perform(.deleteScene(scene.id)); confirmDelete = nil }
                                    } else {
                                        icon("trash", scene.name + " 삭제") { confirmDelete = scene.id }
                                    }
                                }
                            }
                            Divider()
                        }
                    }
                }.frame(height: min(280, CGFloat(state.scenes.count) * 80))
            }
            if model.scenePage == .list {
                Button("화면을 골라 저장") { beginSaving() }.disabled(!state.editable || savableIDs.isEmpty || state.libraryError != nil)
            }
        }
    }

    private func targetSummary(_ scene: BrightnessScene) -> String {
        scene.targets.map { target in
            let display = state.displays.first { $0.id == target.uuid }
            let name = display?.name ?? target.displayName ?? "화면 " + target.uuid.suffix(4)
            return name + " " + String(target.percent) + "%" + (display == nil ? " (분리됨)" : "")
        }.joined(separator: " · ")
    }

    private var sceneEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(editingScene == nil ? "이름 (비우면 화면과 밝기로 자동 지정)" : "프리셋 이름", text: $sceneName)
            Text("적용 대상").font(.headline)
            ForEach(state.displays) { row in
                HStack {
                    Toggle(row.name, isOn: Binding(get: { sceneTargets.contains(row.id) }, set: { on in
                        if on { sceneTargets.insert(row.id) } else { sceneTargets.remove(row.id) }
                    })).disabled(!savableIDs.contains(row.id) && editingScene?.targets.contains(where: { $0.uuid == row.id }) != true).accessibilityIdentifier("scene.target." + row.id)
                    Spacer()
                    Text(editingScene?.targets.first(where: { $0.uuid == row.id }).map { String($0.percent)+"%" } ?? row.value).monospacedDigit()
                }
            }
            ForEach((editingScene?.targets ?? []).filter { target in !state.displays.contains { $0.id == target.uuid } }, id: \.uuid) { target in
                Toggle("분리된 화면 · " + target.uuid.suffix(4), isOn: Binding(get: { sceneTargets.contains(target.uuid) },
                    set: { if $0 { sceneTargets.insert(target.uuid) } else { sceneTargets.remove(target.uuid) } }))
            }
            Button("프리셋 저장") { perform(.saveScene(sceneName, sceneTargets, editingScene?.id)) }
                .disabled(!state.editable || (editingScene != nil && sceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || sceneTargets.isEmpty)
        }
    }

    private func showDetail(_ row: PanelDisplay) {
        detailID = row.id
        aliasText = row.alias
    }

    private func inclusion(_ row: PanelDisplay) -> some View {
        Toggle("작업 종료에 포함", isOn: Binding(get: { row.included }, set: { _ in perform(.include(row.id)) }))
            .disabled(!row.selectable)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("설정 영역", selection: $tab) {
                ForEach(["일반", "디스플레이", "단축키"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented)
            if tab == "단축키" { shortcutSettings }
            else if tab == "일반" {
                Toggle("작업 종료 시 최저 밝기 (1%)", isOn: Binding(get: { state.deep }, set: { perform(.deep($0)) }))
                    .disabled(!state.editable || (!state.deep && !state.canTest))
                if state.shortcut == "미설정" {
                    Button("복원 단축키 설정") { tab = "단축키" }
                } else if !state.editable {
                    Text("복원 후 설정을 변경할 수 있습니다.").font(.caption)
                } else if !state.canTest {
                    Text("작업 종료에 적용할 화면을 선택하세요.").font(.caption)
                }
                Divider()
                HStack {
                    Spacer()
                    Button("앱 종료…") { confirmQuit = true }
                        .alert("LumaRecall을 종료할까요?", isPresented: $confirmQuit) {
                            Button("취소", role: .cancel) {}.keyboardShortcut(.defaultAction)
                            Button("종료", role: .destructive) { perform(.quit) }
                        } message: {
                            Text("다시 열 때까지 메뉴바 버튼과 밝기 단축키를 사용할 수 없습니다.")
                        }
                }
            } else {
                ForEach(state.displays) { row in
                    HStack {
                        Text(row.name)
                        Spacer()
                        icon("info.circle", row.name + " 상세") { showDetail(row) }
                    }
                }
            }
        }
    }

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("전체 디밍 · 복원"); Spacer(); Text(state.shortcut).bold()
                icon("pencil", "단축키 기록") { perform(.record(.workEnd)) }.disabled(!state.editable)
                icon("xmark.circle", "단축키 해제") { perform(.clear(.workEnd)) }.disabled(!state.editable || state.shortcut == "미설정")
            }
            if !state.editable { Text("복원 후 설정을 변경할 수 있습니다.").font(.caption) }
            Button("복원 단축키 시험 (\(shortcutTestSeconds)초)") { perform(.test) }.disabled(!state.canTest)
            Divider()
            Text("프리셋 단축키").font(.headline)
            if state.scenes.isEmpty {
                Text("밝기 패널에서 ‘현재 밝기 저장’을 누르세요.").font(.caption)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(state.scenes) { scene in
                            HStack {
                                Text(scene.name).lineLimit(2)
                                Spacer()
                                Text(state.sceneKeys[scene.id] ?? "미설정").font(.callout)
                                icon("pencil", scene.name + " 단축키 기록") { perform(.record(.scene(scene.id))) }
                                icon("xmark.circle", scene.name + " 단축키 해제") { perform(.clear(.scene(scene.id))) }
                                    .disabled(state.sceneKeys[scene.id] == nil)
                            }.disabled(!state.editable)
                        }
                    }
                }.frame(height: min(220, CGFloat(state.scenes.count) * 32))
            }
        }
    }
}
