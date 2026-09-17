import AppKit
import SwiftUI
import QuartzCore

enum WorkStatus: String, Codable { case next, waiting }

struct TodoItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var completedAt: Date?
    var archivedAt: Date?
}

struct Project: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var detail: String
    var symbol: String
    var status: WorkStatus = .next
    var todos: [TodoItem] = []
    var waitingSince: Date?
    var visibleTodos: [TodoItem] { todos.filter { $0.archivedAt == nil } }
    var pendingCount: Int { todos.filter { $0.completedAt == nil }.count }
    static let defaults = [
        Project(id: "research", name: "研究", detail: "梳理问题和资料", symbol: "doc.text.magnifyingglass"),
        Project(id: "implementation", name: "开发", detail: "实现当前方案", symbol: "hammer.fill"),
        Project(id: "review", name: "验证", detail: "测试与检查", symbol: "checkmark.seal.fill"),
        Project(id: "release", name: "发布", detail: "整理交付事项", symbol: "shippingbox.fill")
    ]
    enum CodingKeys: String, CodingKey { case id, name, detail, symbol, status, todos, waitingSince, nextStep }
    init(id: String, name: String, detail: String, symbol: String) {
        self.id = id; self.name = name; self.detail = detail; self.symbol = symbol
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        detail = try c.decode(String.self, forKey: .detail)
        symbol = try c.decode(String.self, forKey: .symbol)
        status = try c.decode(WorkStatus.self, forKey: .status)
        waitingSince = try c.decodeIfPresent(Date.self, forKey: .waitingSince)
        if let items = try c.decodeIfPresent([TodoItem].self, forKey: .todos) { todos = items }
        else {
            let legacy = try c.decodeIfPresent(String.self, forKey: .nextStep) ?? ""
            todos = legacy.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.map { TodoItem(text: $0) }
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
        try c.encode(detail, forKey: .detail); try c.encode(symbol, forKey: .symbol)
        try c.encode(status, forKey: .status); try c.encode(todos, forKey: .todos)
        try c.encodeIfPresent(waitingSince, forKey: .waitingSince)
    }
}

struct RemovedProject: Codable, Identifiable {
    var project: Project
    var originalIndex: Int
    var id: String { project.id }
}

struct SavedState: Codable {
    var version = 3
    var projects: [Project]
    var removedProjects: [RemovedProject]? = nil
}

final class WorkStore: ObservableObject {
    @Published private(set) var projects = Project.defaults
    @Published private(set) var removedProjects: [RemovedProject] = []
    @Published var saveError: String?
    let file: URL
    private var writable = true
    private var completionTimers: [UUID: DispatchWorkItem] = [:]
    init(file: URL) {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { save(); return }
        do {
            let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file))
            guard (1...3).contains(state.version) else { throw CocoaError(.coderReadCorrupt) }
            projects = state.version < 3
                ? Project.defaults.map { original in state.projects.first { $0.id == original.id } ?? original }
                : state.projects
            removedProjects = state.removedProjects ?? []
            let allIDs = projects.map(\.id) + removedProjects.map(\.id)
            guard Set(allIDs).count == allIDs.count else { throw CocoaError(.coderReadCorrupt) }
            if state.version < 3 {
                let backup = file.deletingLastPathComponent().appendingPathComponent("state-v\(state.version)-backup-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: file, to: backup)
                save()
            }
            archiveExpired(now: Date())
            for project in projects {
                for todo in project.visibleTodos where todo.completedAt != nil { scheduleCompletion(project.id, todo: todo) }
            }
        } catch {
            writable = false
            saveError = "无法读取保存文件，原文件已保留。请从菜单栏打开数据目录检查。"
        }
    }
    deinit { completionTimers.values.forEach { $0.cancel() } }
    @discardableResult func addProject(name: String, detail: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let project = Project(id: UUID().uuidString, name: name,
                              detail: detail.trimmingCharacters(in: .whitespacesAndNewlines), symbol: "folder.fill")
        projects.append(project)
        save()
        return project.id
    }
    func removeProject(_ id: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let project = projects.remove(at: index)
        project.todos.forEach { completionTimers.removeValue(forKey: $0.id)?.cancel() }
        removedProjects.insert(RemovedProject(project: project, originalIndex: index), at: 0)
        save()
    }
    @discardableResult func editProject(_ id: String, name: String, detail: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else { return false }
        let previous = projects[index]
        projects[index].name = name
        projects[index].detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard save() else {
            projects[index] = previous
            return false
        }
        return true
    }
    func restoreProject(_ id: String) {
        guard let index = removedProjects.firstIndex(where: { $0.id == id }) else { return }
        let removed = removedProjects.remove(at: index)
        projects.insert(removed.project, at: min(removed.originalIndex, projects.count))
        archiveExpired(now: Date())
        if let project = projects.first(where: { $0.id == id }) {
            for todo in project.visibleTodos where todo.completedAt != nil { scheduleCompletion(id, todo: todo) }
        }
        save()
    }
    @discardableResult func clearRemovedProjects() -> Bool {
        guard !removedProjects.isEmpty else { return true }
        let previous = removedProjects
        removedProjects = []
        guard save() else {
            removedProjects = previous
            return false
        }
        return true
    }
    @discardableResult func addTodo(_ id: String, text: String) -> UUID? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let i = projects.firstIndex(where: { $0.id == id }) else { return nil }
        let todo = TodoItem(text: text)
        projects[i].todos.append(todo)
        save()
        return todo.id
    }
    func editTodo(_ id: String, todoID: UUID, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let i = projects.firstIndex(where: { $0.id == id }),
              let j = projects[i].todos.firstIndex(where: { $0.id == todoID }) else { return }
        projects[i].todos[j].text = text
        save()
    }
    func setCompleted(_ id: String, todoID: UUID, completed: Bool, now: Date = Date()) {
        guard let i = projects.firstIndex(where: { $0.id == id }),
              let j = projects[i].todos.firstIndex(where: { $0.id == todoID }),
              (projects[i].todos[j].completedAt != nil) != completed else { return }
        completionTimers.removeValue(forKey: todoID)?.cancel()
        projects[i].todos[j].completedAt = completed ? now : nil
        projects[i].todos[j].archivedAt = nil
        save()
        if completed { scheduleCompletion(id, todo: projects[i].todos[j]) }
    }
    private func scheduleCompletion(_ projectID: String, todo: TodoItem) {
        guard let completedAt = todo.completedAt else { return }
        completionTimers.removeValue(forKey: todo.id)?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  let current = self.projects.first(where: { $0.id == projectID })?.todos.first(where: { $0.id == todo.id }),
                  current.completedAt == completedAt else { return }
            self.archiveExpired(now: Date())
        }
        completionTimers[todo.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, completedAt.addingTimeInterval(10).timeIntervalSinceNow), execute: work)
    }
    func archiveExpired(now: Date) {
        var updated = projects
        var expired: [UUID] = []
        for i in updated.indices {
            for j in updated[i].todos.indices {
                let todo = updated[i].todos[j]
                if let completedAt = todo.completedAt, todo.archivedAt == nil, now.timeIntervalSince(completedAt) >= 10 {
                    updated[i].todos[j].archivedAt = now
                    expired.append(todo.id)
                }
            }
        }
        guard !expired.isEmpty else { return }
        projects = updated
        expired.forEach { completionTimers.removeValue(forKey: $0)?.cancel() }
        save()
    }
    func setStatus(_ id: String, _ status: WorkStatus) {
        guard let i = projects.firstIndex(where: { $0.id == id }), projects[i].status != status else { return }
        projects[i].status = status
        projects[i].waitingSince = status == .waiting ? Date() : nil
        save()
    }
    @discardableResult private func save() -> Bool {
        guard writable else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(SavedState(projects: projects, removedProjects: removedProjects)).write(to: file, options: .atomic)
            saveError = nil
            return true
        } catch { saveError = "保存失败：\(error.localizedDescription)"; return false }
    }
    var waitingCount: Int { projects.filter { $0.status == .waiting }.count }
    var nextCount: Int { projects.filter { $0.status == .next }.count }
}

enum Palette {
    static let background = Color(red: 0.045, green: 0.055, blue: 0.07)
    static let secondary = Color(red: 0.55, green: 0.60, blue: 0.65)
    static let green = Color(red: 0.55, green: 0.91, blue: 0.72)
    static let amber = Color(red: 0.98, green: 0.73, blue: 0.38)
    static func accent(_ id: String) -> Color {
        switch id {
        case "research": return Color(red: 0.62, green: 0.71, blue: 1)
        case "implementation": return Color(red: 0.81, green: 0.66, blue: 1)
        case "review": return Color(red: 0.51, green: 0.84, blue: 0.85)
        default: return Color(red: 1, green: 0.72, blue: 0.56)
        }
    }
}

enum PresentationMode: String, CaseIterable {
    case floating, island
    var title: String { self == .floating ? "悬浮模式" : "灵动岛模式" }
}

struct DisplayChoice: Identifiable {
    let id: String
    let title: String
}

extension NSScreen {
    var islandDisplayID: String {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else {
            return "screen-\(localizedName)"
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var managingProjects = false
    @Published var focusNewProject = false
    @Published var mode: PresentationMode { didSet { defaults.set(mode.rawValue, forKey: "presentationMode") } }
    @Published var selectedDisplayID: String { didSet { defaults.set(selectedDisplayID, forKey: "islandDisplayID") } }
    @Published var displays: [DisplayChoice] = []
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 0
    var topInset: CGFloat { mode == .island ? notchHeight : 0 }
    func panelSize(expanded: Bool) -> NSSize {
        if expanded { return NSSize(width: 630, height: 610 + topInset) }
        if hasCameraCutout { return NSSize(width: compactCenterWidth + 128, height: max(32, topInset + 2)) }
        return NSSize(width: 430, height: 50)
    }
    var hasCameraCutout: Bool { mode == .island && notchWidth > 0 && topInset > 0 }
    var compactCenterWidth: CGFloat { hasCameraCutout ? notchWidth + 8 : 16 }
    var outline: PanelOutline { PanelOutline(docked: mode == .island) }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = PresentationMode(rawValue: defaults.string(forKey: "presentationMode") ?? "") ?? .floating
        selectedDisplayID = defaults.string(forKey: "islandDisplayID") ?? ""
    }
    func refreshDisplays() {
        displays = NSScreen.screens.enumerated().map { index, screen in
            DisplayChoice(id: screen.islandDisplayID,
                title: "\(index + 1). \(screen.localizedName) · \(Int(screen.frame.width)) × \(Int(screen.frame.height))\(index == 0 ? "（主屏）" : "")")
        }
    }
    var selectedDisplayMissing: Bool {
        !selectedDisplayID.isEmpty && !displays.contains { $0.id == selectedDisplayID }
    }
    static func resolvedDisplayID(selected: String, available: [String]) -> String? {
        available.contains(selected) ? selected : available.first
    }
}

/// A black tab attached to the physical display edge; a capsule when freely floating.
struct PanelOutline: Shape {
    var docked: Bool
    func path(in rect: CGRect) -> Path {
        if !docked { return Path(roundedRect: rect, cornerRadius: 25) }
        let r: CGFloat = rect.height <= 40 ? 9 : min(25, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct StatusDot: View {
    var waiting: Bool
    var body: some View {
        Circle().fill(waiting ? Palette.amber : Palette.green).frame(width: 6, height: 6)
    }
}

struct IslandView: View {
    @ObservedObject var store: WorkStore
    @ObservedObject var state: IslandState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var toggle: () -> Void
    var presentationChanged: () -> Void
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                compact
                    .opacity(state.expanded ? 0 : 1)
                    .allowsHitTesting(!state.expanded)
                    .accessibilityHidden(state.expanded)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.16).delay(state.expanded ? 0 : 0.10), value: state.expanded)
                expanded
                    .padding(.top, state.topInset)
                    .opacity(state.expanded ? 1 : 0)
                    .allowsHitTesting(state.expanded)
                    .accessibilityHidden(!state.expanded)
                    .animation(reduceMotion ? nil : .easeInOut(duration: state.expanded ? 0.24 : 0.12).delay(state.expanded ? 0.07 : 0), value: state.expanded)
            }
            // Keep text at its natural size while the native window smoothly reveals it.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background(state.mode == .island ? Color.black : Palette.background)
            .clipShape(state.outline)
            .overlay(state.outline.stroke(.white.opacity(state.mode == .island ? 0 : 0.12), lineWidth: 1))
        }
        .environment(\.colorScheme, .dark)
        .onChange(of: state.mode) { _ in presentationChanged() }
        .onChange(of: state.selectedDisplayID) { _ in presentationChanged() }
    }
    @ViewBuilder private var compact: some View {
        if state.hasCameraCutout { summaryCompact }
        else { projectCompact }
    }
    private var summaryCompact: some View {
        Button(action: toggle) {
            HStack(spacing: 0) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 17)).foregroundStyle(Palette.green.opacity(0.9))
                    .frame(width: 64)
                // Reserve only the camera footprint; no information is placed behind it.
                Color.clear.frame(width: state.compactCenterWidth)
                (
                    Text("\(store.nextCount)").foregroundColor(store.nextCount > 0 ? Palette.green : Palette.secondary)
                    + Text(" / \(store.projects.count)").foregroundColor(Palette.secondary)
                )
                .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.65)
                .frame(width: 64)
            }
            .frame(width: state.panelSize(expanded: false).width, height: state.panelSize(expanded: false).height)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("FlowIsle，下一步 \(store.nextCount) 个方向，共 \(store.projects.count) 个方向")
            .help("下一步工作 \(store.nextCount) / 总方向 \(store.projects.count) · 悬浮展开")
    }
    private var projectCompact: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 15)).foregroundStyle(Palette.green.opacity(0.85))
                    .frame(width: 22)
                Rectangle().fill(.white.opacity(0.10)).frame(width: 1, height: 16)
                HStack(spacing: 4) {
                    ForEach(Array(store.projects.prefix(store.projects.count > 4 ? 3 : 4))) { project in
                        HStack(spacing: 5) {
                            StatusDot(waiting: project.status == .waiting)
                            Text(project.name)
                                .font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.tail)
                        }
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                        .help(project.name + (project.status == .waiting ? " · 等待 Agent" : " · 下一步工作"))
                    }
                    if store.projects.count > 4 {
                        Text("+\(store.projects.count - 3)")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.secondary)
                            .frame(maxWidth: .infinity).frame(height: 28)
                            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                            .help("展开查看其余 \(store.projects.count - 3) 个方向")
                    }
                    if store.projects.isEmpty {
                        Text("添加你的第一个方向").font(.system(size: 14))
                            .frame(maxWidth: .infinity)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.secondary.opacity(0.8))
                    .frame(width: 12)
            }
            .padding(.horizontal, 12)
            .foregroundStyle(.white.opacity(0.92))
            .frame(width: state.panelSize(expanded: false).width, height: 28)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help("悬浮展开 · 移开收起 · 黄色：等待 Agent · 绿色：下一步工作")
    }
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                HStack(spacing: 10) {
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 21)).foregroundStyle(Palette.green)
                    Text(state.managingProjects ? "管理" : "FlowIsle").font(.system(size: 26, weight: .semibold))
                }
                Spacer()
                HStack(spacing: 7) {
                    StatusDot(waiting: true)
                    Text("\(store.waitingCount) 等待 Agent").foregroundStyle(Palette.amber)
                }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Palette.amber.opacity(0.08), in: Capsule())
                Button { state.focusNewProject = false; state.managingProjects.toggle() } label: {
                    Label(state.managingProjects ? "完成" : "管理", systemImage: state.managingProjects ? "checkmark" : "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium)).padding(8)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityLabel(state.managingProjects ? "完成方向管理" : "管理")
                Button(action: toggle) { Image(systemName: "chevron.up").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).foregroundStyle(Palette.secondary).help("收起为灵动岛（Esc）").accessibilityLabel("收起面板")
            }
            Group {
                if state.managingProjects {
                    ProjectManagerView(store: store, state: state, focusNewProject: state.focusNewProject) {
                        if state.focusNewProject {
                            state.managingProjects = false
                            state.focusNewProject = false
                        }
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(store.projects) { project in ProjectCard(project: project, store: store) }
                            ForEach(0..<max(0, 4 - store.projects.count), id: \.self) { slot in
                                Button {
                                    state.focusNewProject = true
                                    state.managingProjects = true
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.system(size: 30, weight: .light))
                                        .foregroundStyle(Palette.secondary)
                                        .frame(maxWidth: .infinity).frame(height: 242)
                                        .background(.white.opacity(0.015), in: RoundedRectangle(cornerRadius: 16))
                                        .overlay(RoundedRectangle(cornerRadius: 16)
                                            .strokeBorder(.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
                                }.buttonStyle(.plain).help("添加方向")
                                    .accessibilityLabel("添加方向，占位 \(slot + 1)")
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
            }.frame(height: 494)
            HStack(spacing: 6) {
                Image(systemName: store.saveError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                Text(store.saveError ?? "本地自动保存")
                Spacer(minLength: 4)
                if store.saveError == nil { Text(state.managingProjects ? "管理中 · 点击完成返回" : "悬浮展开 · 移开收起") }
            }.font(.system(size: 12)).foregroundStyle(store.saveError == nil ? Palette.secondary : Palette.amber)
        }.padding(16).frame(width: 630, height: 610).foregroundStyle(.white.opacity(0.94))
    }
}

struct ProjectManagerView: View {
    @ObservedObject var store: WorkStore
    @ObservedObject var state: IslandState
    var focusNewProject = false
    var onProjectCreated: () -> Void = {}
    @State private var name = ""
    @State private var detail = ""
    @State private var showingRemoved = false
    @State private var confirmingClear = false
    @State private var feedback = ""
    @State private var editingProjectID: String?
    @State private var formSession = UUID()
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Label("显示模式", systemImage: "macwindow").font(.system(size: 14, weight: .medium))
                    Spacer()
                    Picker("显示模式", selection: $state.mode) {
                        ForEach(PresentationMode.allCases, id: \.self) { mode in Text(mode.title).tag(mode) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 270)
                }
                if state.mode == .island {
                    HStack {
                        Text("所在显示屏").font(.system(size: 13)).foregroundStyle(Palette.secondary)
                        Spacer()
                        Picker("灵动岛显示屏", selection: $state.selectedDisplayID) {
                            Text("跟随主显示屏").tag("")
                            ForEach(state.displays) { display in Text(display.title).tag(display.id) }
                            if state.selectedDisplayMissing { Text("已断开的显示屏（暂用主屏）").tag(state.selectedDisplayID) }
                        }.labelsHidden().frame(maxWidth: 390)
                    }
                }
                Text(state.mode == .floating ? "可拖动到任意位置 · 自动记住悬浮位置" : "固定在所选屏幕顶部 · 悬浮展开，移开收起")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }.padding(12).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 10) {
                Text(editingProjectID == nil ? "新增工作方向" : "编辑工作方向").font(.system(size: 16, weight: .semibold))
                HStack(spacing: 10) {
                    TextField("方向名称（必填）", text: $name)
                        .focused($nameFocused).onSubmit(saveProject).accessibilityLabel("方向标题")
                    TextField("备注（选填）", text: $detail)
                        .onSubmit(saveProject).accessibilityLabel("方向备注")
                }.textFieldStyle(.roundedBorder).font(.system(size: 14))
                HStack {
                    Text(feedback.isEmpty ? "名称和说明可自定义" : feedback)
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                    Spacer()
                    if editingProjectID != nil {
                        Button("取消", action: cancelProjectEditing).buttonStyle(.bordered).accessibilityLabel("取消方向编辑")
                    }
                    Button(action: saveProject) {
                        Label(editingProjectID == nil ? "添加方向" : "保存修改", systemImage: editingProjectID == nil ? "plus.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }.buttonStyle(.borderedProminent).tint(Palette.green).foregroundStyle(.black)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(editingProjectID == nil ? "确认添加方向" : "保存方向修改")
                }
            }.padding(14).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                .background {
                    if editingProjectID != nil {
                        OutsideClickRegion { [session = formSession] in
                            if editingProjectID != nil && formSession == session { cancelProjectEditing() }
                        }
                    }
                }
            HStack {
                Text("我的方向 · \(store.projects.count)").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("删除后可在下方恢复").font(.system(size: 12)).foregroundStyle(Palette.secondary)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.projects) { project in
                        HStack(spacing: 10) {
                            Image(systemName: project.symbol).foregroundStyle(Palette.accent(project.id)).frame(width: 25)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name).font(.system(size: 16, weight: .medium)).lineLimit(1).help(project.name)
                                Text(project.detail.isEmpty ? "\(project.pendingCount) 项待办" : "\(project.detail) · \(project.pendingCount) 项待办")
                                    .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button {
                                formSession = UUID()
                                editingProjectID = project.id
                                name = project.name; detail = project.detail
                                feedback = "修改后按回车或点击保存"
                                nameFocused = true
                            } label: { Image(systemName: "pencil").font(.system(size: 16)).frame(width: 32, height: 32) }
                                .buttonStyle(.plain).foregroundStyle(Palette.green)
                                .accessibilityLabel("编辑方向：\(project.name)").help("修改标题和备注")
                            Button {
                                if editingProjectID == project.id { cancelProjectEditing() }
                                store.removeProject(project.id)
                                feedback = "已删除「\(project.name)」，可在下方恢复"
                            } label: { Image(systemName: "trash").font(.system(size: 16)).frame(width: 32, height: 32) }
                                .buttonStyle(.plain).foregroundStyle(Palette.secondary)
                                .accessibilityLabel("删除方向：\(project.name)").help("删除方向（可恢复）")
                        }.padding(10).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if store.projects.isEmpty {
                        Text("还没有方向，在上方添加一个吧").font(.system(size: 14)).foregroundStyle(Palette.secondary).padding(20)
                    }
                    if !store.removedProjects.isEmpty {
                        DisclosureGroup(isExpanded: $showingRemoved) {
                            VStack(spacing: 8) {
                                ForEach(store.removedProjects) { removed in
                                    HStack {
                                        Text(removed.project.name).font(.system(size: 14)).lineLimit(1)
                                        Spacer()
                                        Button("恢复") {
                                            store.restoreProject(removed.id)
                                            feedback = "已恢复「\(removed.project.name)」"
                                        }.buttonStyle(.bordered).accessibilityLabel("恢复方向：\(removed.project.name)")
                                    }.padding(8)
                                }
                            }.padding(.top, 8)
                        } label: {
                            HStack {
                                Text("已删除（\(store.removedProjects.count)）")
                                Spacer()
                                Button("清空") { confirmingClear = true }
                                    .buttonStyle(.plain).foregroundStyle(.red)
                                    .accessibilityLabel("清空已删除方向")
                                    .help("永久清空已删除的方向和待办")
                            }
                        }.font(.system(size: 13)).padding(10)
                    }
                }
            }.scrollIndicators(.hidden)
        }
        .onAppear {
            if focusNewProject { DispatchQueue.main.async { nameFocused = true } }
        }
        .alert("清空已删除方向？", isPresented: $confirmingClear) {
            Button("取消", role: .cancel) {}
            Button("永久清空", role: .destructive) {
                if store.clearRemovedProjects() {
                    showingRemoved = false
                    feedback = "已清空已删除方向"
                }
            }
        } message: {
            Text("将永久移除这 \(store.removedProjects.count) 个已删除方向及其中的全部待办，清空后无法在应用内恢复。正在使用的方向不受影响。")
        }
    }
    private func saveProject() {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = editingProjectID {
            guard store.editProject(id, name: name, detail: detail) else { return }
            cancelProjectEditing()
            feedback = "已更新「\(title)」"
        } else {
            guard store.addProject(name: name, detail: detail) != nil else { return }
            feedback = "已添加「\(title)」"
            name = ""; detail = ""; nameFocused = true
            onProjectCreated()
        }
    }
    private func cancelProjectEditing() {
        formSession = UUID(); editingProjectID = nil
        name = ""; detail = ""; feedback = ""; nameFocused = false
    }
}

struct ProjectCard: View {
    var project: Project
    @ObservedObject var store: WorkStore
    @FocusState private var editing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var adding = false
    @State private var draft = ""
    @State private var editingTodoID: UUID?
    @State private var editSession = UUID()
    private var waiting: Bool { project.status == .waiting }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: project.symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.accent(project.id))
                    .frame(width: 30, height: 30).background(Palette.accent(project.id).opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                    Text(project.detail).font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    editSession = UUID()
                    draft = ""; editingTodoID = nil; adding = true
                    editing = true
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 23))
                        .foregroundStyle(Palette.accent(project.id))
                }.buttonStyle(.plain).accessibilityLabel("\(project.name) 新建待办").help("新建待办")
            }
            HStack(spacing: 3) {
                statusButton("等待 Agent", symbol: "hourglass", status: .waiting)
                statusButton("下一步工作", symbol: "arrow.turn.down.right", status: .next)
            }.padding(3).background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
            VStack(spacing: 5) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(project.visibleTodos) { todo in
                                TodoRow(projectID: project.id, todo: todo, store: store) {
                                    editSession = UUID()
                                    editingTodoID = todo.id
                                    draft = todo.text
                                    adding = true
                                    editing = true
                                }
                                .id(todo.id)
                                .transition(.opacity)
                                Divider().opacity(0.25)
                            }
                            if project.visibleTodos.isEmpty && !adding {
                                Text("点击 ＋ 添加待办")
                                    .font(.system(size: 14)).foregroundStyle(Palette.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 70)
                            }
                        }.padding(.horizontal, 3)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: project.visibleTodos.map(\.id))
                    }.scrollIndicators(.hidden)
                        .onChange(of: project.todos.count) { _ in
                            if let last = project.visibleTodos.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                }
                if adding {
                    HStack(spacing: 5) {
                        TextField(editingTodoID == nil ? "新待办…" : "编辑待办…", text: $draft)
                            .textFieldStyle(.plain).font(.system(size: 15)).focused($editing)
                            .onSubmit(commitTodo)
                            .accessibilityLabel("\(project.name) 待办输入")
                        Button(action: commitTodo) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 19))
                        }.buttonStyle(.plain).foregroundStyle(Palette.green)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("\(project.name) 确认待办")
                        Button(action: cancelEditing) { Image(systemName: "xmark").font(.system(size: 11)) }
                            .buttonStyle(.plain).foregroundStyle(Palette.secondary)
                            .accessibilityLabel("\(project.name) 取消输入")
                    }.padding(7).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        .background(OutsideClickRegion { [session = editSession] in
                            // An outside click may open a different row's editor in the same card.
                            guard adding, editSession == session else { return }
                            cancelEditing()
                        })
                }
            }.frame(height: 108)
            HStack(spacing: 5) {
                StatusDot(waiting: waiting)
                if waiting {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(waitText(now: context.date)).foregroundStyle(Palette.amber)
                    }
                } else {
                    Text(project.pendingCount == 0 ? "暂无待办" : "\(project.pendingCount) 项待办").foregroundStyle(Palette.green)
                }
                Spacer()
            }.font(.system(size: 12))
        }.padding(12).frame(height: 242)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.07)))
    }
    private func commitTodo() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let id = editingTodoID { store.editTodo(project.id, todoID: id, text: text) }
        else { store.addTodo(project.id, text: text) }
        cancelEditing()
    }
    private func cancelEditing() {
        editSession = UUID()
        draft = ""; editingTodoID = nil; adding = false; editing = false
    }
    private func statusButton(_ label: String, symbol: String, status: WorkStatus) -> some View {
        let selected = project.status == status
        let color = status == .waiting ? Palette.amber : Palette.green
        return Button { store.setStatus(project.id, status) } label: {
            HStack(spacing: 4) { Image(systemName: symbol); Text(label) }
                .font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 6)
                .foregroundStyle(selected ? color : Palette.secondary)
                .background(selected ? color.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel("\(project.name)：\(label)").accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func waitText(now: Date) -> String {
        guard let start = project.waitingSince else { return "Agent 正在处理中" }
        let minutes = max(0, Int(now.timeIntervalSince(start) / 60))
        if minutes < 1 { return "Agent 处理中 · 刚刚" }
        if minutes < 60 { return "Agent 处理中 · \(minutes) 分钟" }
        return "Agent 处理中 · \(minutes / 60) 小时 \(minutes % 60) 分"
    }
}

/// Observes clicks without consuming them, so the clicked control still performs its action.
struct OutsideClickRegion: NSViewRepresentable {
    var cancel: () -> Void
    func makeNSView(context: Context) -> OutsideClickView { OutsideClickView() }
    func updateNSView(_ view: OutsideClickView, context: Context) { view.cancel = cancel }
    static func dismantleNSView(_ view: OutsideClickView, coordinator: ()) { view.stopObserving() }
}

final class OutsideClickView: NSView {
    var cancel: (() -> Void)?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var localClick: (() -> Void)?
    private var globalClick: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard window != nil else { return }
        // Only cancel a click whose mouse-down was observed by this editor. The opening
        // button's mouse-up can arrive after this view is mounted and must be ignored.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, let window = self.window else { return event }
            if event.type == .leftMouseDown {
                let outside = event.window !== window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                self.localClick = outside ? self.cancel : nil
            } else {
                let action = self.localClick
                self.localClick = nil
                DispatchQueue.main.async { action?() }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return }
            if event.type == .leftMouseDown { self.globalClick = self.cancel }
            else {
                let action = self.globalClick
                self.globalClick = nil
                DispatchQueue.main.async { action?() }
            }
        }
    }
    func stopObserving() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil
        localClick = nil; globalClick = nil
    }
    deinit { stopObserving() }
}

struct TodoRow: View {
    let projectID: String
    let todo: TodoItem
    @ObservedObject var store: WorkStore
    var edit: () -> Void
    private var completed: Bool { todo.completedAt != nil }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                store.setCompleted(projectID, todoID: todo.id, completed: !completed)
            } label: {
                Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(completed ? Palette.green : Palette.secondary)
                    .frame(width: 24, height: 25)
            }.buttonStyle(.plain)
                .accessibilityLabel("\(completed ? "撤销完成" : "完成")：\(todo.text)")
                .help(completed ? "撤销完成" : "标记为已完成")
            VStack(alignment: .leading, spacing: 3) {
                Button(action: edit) {
                    Text(todo.text).font(.system(size: 16)).lineSpacing(2)
                        .strikethrough(completed, color: Palette.secondary)
                        .foregroundStyle(completed ? Palette.secondary : .white.opacity(0.94))
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.plain).disabled(completed).accessibilityLabel("编辑：\(todo.text)")
                if let completedAt = todo.completedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(ceil(10 - context.date.timeIntervalSince(completedAt))))
                        Text("已完成 · \(seconds) 秒内可撤销")
                            .font(.system(size: 11)).foregroundStyle(Palette.green)
                    }
                }
            }.padding(.top, 2)
        }.padding(.vertical, 5)
    }
}

final class IslandPanel: NSPanel {
    var reachesScreenEdge = false
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        reachesScreenEdge ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class HoverHostingView: NSHostingView<IslandView> {
    var pointerChanged: (() -> Void)?
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { pointerChanged?() }
    override func mouseExited(with event: NSEvent) { pointerChanged?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: IslandPanel!
    var item: NSStatusItem!
    var store: WorkStore!
    let state = IslandState()
    var keyMonitor: Any?
    var localPointerMonitor: Any?
    var globalPointerMonitor: Any?
    var previousPointerInside: Bool?
    var pendingHover: DispatchWorkItem?
    var suppressHoverUntilExit = false
    var isAnimating = false
    var pendingPresentation = false
    var appliedMode: PresentationMode = .floating
    var floatingFrame: NSRect?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent accidental duplicate menu bar instances.
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.workisland.app").count > 1 {
            NSApp.terminate(nil); return
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = WorkStore(file: support.appendingPathComponent("WorkIsland/state.json"))
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: state.panelSize(expanded: false)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        state.refreshDisplays()
        appliedMode = state.mode
        let hosting = HoverHostingView(rootView: IslandView(store: store, state: state,
            toggle: { [weak self] in self?.toggle() }, presentationChanged: { [weak self] in self?.applyPresentation() }))
        hosting.sizingOptions = []
        hosting.pointerChanged = { [weak self] in self?.pointerChanged() }
        panel.contentView = hosting
        buildMenu()
        setupMainMenu()
        restorePosition()
        panel.orderFrontRegardless()
        pointerChanged()
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.refreshPointerRouting()
            return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.refreshPointerRouting()
        }
        refreshPointerRouting()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.state.expanded == true {
                if self?.state.managingProjects == true { self?.state.managingProjects = false }
                else { self?.toggle() }
                return nil
            }
            return event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 FlowIsle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
    }
    func buildMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "circle.hexagongrid.fill", accessibilityDescription: "FlowIsle")
        let menu = NSMenu()
        for (title, selector) in [("管理", #selector(manageProjects)), ("展开 / 收起", #selector(toggle)), ("显示 / 隐藏", #selector(toggleVisible)), ("回到屏幕顶部", #selector(resetPosition))] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: ""); entry.target = self; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let folder = NSMenuItem(title: "打开数据目录", action: #selector(openDataFolder), keyEquivalent: ""); folder.target = self; menu.addItem(folder)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 FlowIsle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }
    @objc func toggle() {
        guard !isAnimating else { return }
        pendingHover?.cancel()
        suppressHoverUntilExit = state.expanded && panel.frame.contains(NSEvent.mouseLocation)
        setExpanded(!state.expanded, focus: true)
        pointerChanged()
    }
    @objc func manageProjects() {
        state.focusNewProject = false
        state.managingProjects = true
        pendingHover?.cancel()
        if !state.expanded { setExpanded(true, focus: true) }
        panel.makeKeyAndOrderFront(nil)
    }
    func pointerChanged() {
        pendingHover?.cancel()
        guard panel.isVisible, !isAnimating, !state.managingProjects else { return }
        let inside = containsPointer()
        if !inside { suppressHoverUntilExit = false }
        guard !suppressHoverUntilExit, inside != state.expanded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel.isVisible, !self.state.managingProjects else { return }
            // Check the current frame again: expansion and dragging can change the tracking area.
            guard self.containsPointer() == inside else { self.pointerChanged(); return }
            // Finish dragging / text selection before changing window geometry.
            guard NSEvent.pressedMouseButtons == 0 else { self.pointerChanged(); return }
            self.setExpanded(inside, focus: false)
        }
        pendingHover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.15 : 0.35), execute: work)
    }
    func containsPointer() -> Bool {
        let point = NSEvent.mouseLocation
        guard panel.frame.contains(point) else { return false }
        return state.outline.path(in: CGRect(origin: .zero, size: panel.frame.size))
            .contains(CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y))
    }
    func refreshPointerRouting() {
        guard panel != nil, panel.isVisible else { return }
        let inside = containsPointer()
        // Transparent rounded corners must leave the system menu bar usable.
        panel.ignoresMouseEvents = state.mode == .island && state.topInset > 0 && !inside
        if previousPointerInside != inside {
            previousPointerInside = inside
            pointerChanged()
        }
    }
    func setExpanded(_ expanded: Bool, focus: Bool) {
        guard state.expanded != expanded, !isAnimating else { return }
        pendingHover?.cancel()
        isAnimating = true
        if !expanded { panel.makeFirstResponder(nil); state.managingProjects = false }
        let old = panel.frame
        state.expanded = expanded
        let size = state.panelSize(expanded: state.expanded)
        let proposed = NSRect(x: old.midX - size.width / 2, y: old.maxY - size.height, width: size.width, height: size.height)
        panel.orderFrontRegardless()
        let target = state.mode == .island ? islandFrame(size: size) : clamped(proposed)
        let finish = { [weak self] in
            guard let self else { return }
            self.isAnimating = false
            self.refreshPointerRouting()
            if self.pendingPresentation {
                self.pendingPresentation = false
                self.applyPresentation()
            }
            if expanded && focus { self.panel.makeKey() }
            // Resizing itself generates tracking events; evaluate hover once geometry settles.
            // Menu / accessibility activation can expand while the pointer is elsewhere.
            // Let the next actual pointer movement handle dismissal in that case.
            if !expanded || !focus || self.panel.frame.contains(NSEvent.mouseLocation) {
                self.pointerChanged()
            }
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(target, display: true)
            finish()
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = expanded ? 0.36 : 0.28
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                panel.animator().setFrame(target, display: true)
            } completionHandler: { finish() }
        }
    }
    @objc func toggleVisible() {
        pendingHover?.cancel()
        if panel.isVisible { panel.orderOut(nil) }
        else { panel.orderFrontRegardless(); pointerChanged() }
    }
    @objc func resetPosition() {
        if state.mode == .island {
            panel.setFrame(islandFrame(size: panel.frame.size), display: true)
            panel.orderFrontRegardless()
            return
        }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let bounds = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: bounds.midX - panel.frame.width / 2, y: bounds.maxY - panel.frame.height - 8))
        panel.orderFrontRegardless()
    }
    @objc func screenChanged() {
        state.refreshDisplays()
        applyPresentation()
    }
    func selectedScreen() -> NSScreen {
        let resolved = IslandState.resolvedDisplayID(selected: state.selectedDisplayID,
                                                     available: NSScreen.screens.map(\.islandDisplayID))
        return NSScreen.screens.first { $0.islandDisplayID == resolved }
            ?? NSScreen.screens.first ?? NSScreen.main!
    }
    func islandFrame(size: NSSize) -> NSRect {
        Self.dockedFrame(size: size, screenFrame: selectedScreen().frame)
    }
    static func dockedFrame(size: NSSize, screenFrame: NSRect) -> NSRect {
        NSRect(x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }
    func applyPresentation() {
        guard panel != nil else { return }
        if isAnimating { pendingPresentation = true; return }
        pendingHover?.cancel()
        suppressHoverUntilExit = false
        if appliedMode == .floating && state.mode == .island {
            floatingFrame = panel.frame
            UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "islandFrame")
        }
        let screen = selectedScreen()
        state.notchHeight = screen.safeAreaInsets.top
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.notchWidth = max(0, right.minX - left.maxX)
        } else { state.notchWidth = 0 }
        let size = state.panelSize(expanded: state.expanded)
        panel.reachesScreenEdge = state.mode == .island
        panel.level = state.mode == .island ? NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1) : .floating
        let target: NSRect
        if state.mode == .island { target = islandFrame(size: size) }
        else if appliedMode == .island, let old = floatingFrame {
            target = clamped(NSRect(x: old.midX - size.width / 2, y: old.maxY - size.height,
                                    width: size.width, height: size.height))
        } else {
            target = clamped(NSRect(x: panel.frame.midX - size.width / 2, y: panel.frame.maxY - size.height,
                                    width: size.width, height: size.height))
        }
        appliedMode = state.mode
        panel.isMovableByWindowBackground = state.mode == .floating
        // Relocate directly between screens; expansion/collapse retains its usual animation.
        panel.setFrame(target, display: true)
        refreshPointerRouting()
    }
    @objc func openDataFolder() { NSWorkspace.shared.open(store.file.deletingLastPathComponent()) }
    func clamped(_ frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.max { a, b in
            let aa = a.visibleFrame.intersection(frame); let bb = b.visibleFrame.intersection(frame)
            return (aa.isNull ? 0 : aa.width * aa.height) < (bb.isNull ? 0 : bb.width * bb.height)
        } ?? NSScreen.main!
        let bounds = screen.visibleFrame
        return NSRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - frame.width), y: min(max(frame.minY, bounds.minY), bounds.maxY - frame.height), width: frame.width, height: frame.height)
    }
    func restorePosition() {
        if let position = UserDefaults.standard.string(forKey: "islandFrame") {
            let old = NSRectFromString(position)
            floatingFrame = old
            let size = state.panelSize(expanded: false)
            let frame = NSRect(x: old.midX - size.width / 2, y: old.maxY - size.height, width: size.width, height: size.height)
            panel.setFrame(clamped(frame), display: true)
        } else { resetPosition() }
        applyPresentation()
    }
    func applicationWillTerminate(_ notification: Notification) {
        pendingHover?.cancel()
        if let panel, state.mode == .floating { UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: "islandFrame") }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

func runSelfTests() throws {
    let suiteName = "work-island-settings-test-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suiteName)!
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let settings = IslandState(defaults: preferences)
    precondition(settings.mode == .floating && settings.selectedDisplayID.isEmpty)
    settings.mode = .island
    settings.selectedDisplayID = "external-uuid"
    let restartedSettings = IslandState(defaults: preferences)
    precondition(restartedSettings.mode == .island && restartedSettings.selectedDisplayID == "external-uuid")
    precondition(IslandState.resolvedDisplayID(selected: restartedSettings.selectedDisplayID, available: ["main", "external-uuid"]) == "external-uuid")
    precondition(IslandState.resolvedDisplayID(selected: restartedSettings.selectedDisplayID, available: ["main"]) == "main")
    precondition(restartedSettings.selectedDisplayID == "external-uuid") // Disconnect does not forget the preference.
    precondition(IslandState.resolvedDisplayID(selected: restartedSettings.selectedDisplayID, available: ["main", "external-uuid"]) == "external-uuid")
    precondition(IslandState.resolvedDisplayID(selected: "", available: ["main", "external-uuid"]) == "main")
    precondition(IslandState.resolvedDisplayID(selected: "", available: []) == nil)
    restartedSettings.notchWidth = 184
    restartedSettings.notchHeight = 32
    precondition(restartedSettings.panelSize(expanded: false) == NSSize(width: 320, height: 34))
    precondition(restartedSettings.compactCenterWidth == 192)
    let summarySize = restartedSettings.panelSize(expanded: false)
    let cameraLeft = summarySize.width / 2 - restartedSettings.notchWidth / 2
    let cameraRight = summarySize.width / 2 + restartedSettings.notchWidth / 2
    precondition(64 < cameraLeft && summarySize.width - 64 > cameraRight) // Both information areas clear the camera.
    restartedSettings.notchWidth = 230
    precondition(restartedSettings.panelSize(expanded: false).width == 366)
    precondition(restartedSettings.panelSize(expanded: true) == NSSize(width: 630, height: 642))
    restartedSettings.notchWidth = 0
    restartedSettings.notchHeight = 0
    precondition(!restartedSettings.hasCameraCutout)
    precondition(restartedSettings.panelSize(expanded: false) == NSSize(width: 430, height: 50))
    restartedSettings.notchWidth = 184
    restartedSettings.notchHeight = 32
    precondition(restartedSettings.hasCameraCutout && restartedSettings.panelSize(expanded: false).width == 320)
    restartedSettings.mode = .floating
    precondition(restartedSettings.panelSize(expanded: false) == NSSize(width: 430, height: 50))
    precondition(restartedSettings.panelSize(expanded: true) == NSSize(width: 630, height: 610))
    let physicalScreen = NSRect(x: 0, y: 0, width: 1470, height: 956)
    let topFrame = AppDelegate.dockedFrame(size: NSSize(width: 600, height: 50), screenFrame: physicalScreen)
    precondition(topFrame.maxY == 956 && topFrame.midX == 735) // Never subtract menu bar / safe area from the window origin.
    for bounds in [NSRect(x: 0, y: 0, width: 1728, height: 1079), NSRect(x: -2560, y: 200, width: 2560, height: 1415)] {
        for size in [NSSize(width: 430, height: 50), NSSize(width: 630, height: 610)] {
            let frame = AppDelegate.dockedFrame(size: size, screenFrame: bounds)
            precondition(frame.midX == bounds.midX && frame.maxY == bounds.maxY && bounds.contains(frame))
        }
    }
    print("PASS: mode + display preference persistence, monitor fallback + reconnect, physical screen top alignment, notch clearance + floating size restoration, offset screens")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("work-island-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let countFile = directory.appendingPathComponent("summary-counts.json")
    let countStore = WorkStore(file: countFile)
    precondition(countStore.nextCount == 4 && countStore.projects.count == 4)
    countStore.setStatus("research", .waiting)
    countStore.setStatus("implementation", .waiting)
    precondition(countStore.nextCount == 2 && countStore.projects.count == 4)
    let countedTodo = countStore.addTodo("review", text: "A todo does not add a direction")!
    countStore.setCompleted("review", todoID: countedTodo, completed: true)
    precondition(countStore.nextCount == 2) // Count project status, not pending todos.
    countStore.removeProject("research")
    precondition(countStore.nextCount == 2 && countStore.projects.count == 3)
    countStore.removeProject("review")
    precondition(countStore.nextCount == 1 && countStore.projects.count == 2)
    countStore.restoreProject("review")
    precondition(countStore.nextCount == 2 && countStore.projects.count == 3)
    precondition(WorkStore(file: countFile).nextCount == 2)
    for id in countStore.projects.map(\.id) { countStore.removeProject(id) }
    precondition(countStore.nextCount == 0 && countStore.projects.isEmpty)
    countStore.addProject(name: "New direction", detail: "")
    precondition(countStore.nextCount == 1 && countStore.projects.count == 1)
    print("PASS: next/total summary across status changes, todo completion, add/remove/restore, restart, and empty state")
    let file = directory.appendingPathComponent("state.json")
    let legacy = #"{"version":1,"projects":[{"id":"research","name":"研究","detail":"资料整理","symbol":"doc.text.magnifyingglass","status":"waiting","waitingSince":810541490,"nextStep":"检查实验结果\n\n整理研究资料：中文、emoji 🧪\n"}]}"#
    try Data(legacy.utf8).write(to: file)
    let store = WorkStore(file: file)
    precondition(store.saveError == nil && store.projects.count == 4 && store.waitingCount == 1)
    precondition(store.projects[0].todos.map(\.text) == ["检查实验结果", "整理研究资料：中文、emoji 🧪"])
    let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("state-v1-backup") }
    precondition(backups.count == 1)
    let backedUp = try String(contentsOf: backups[0], encoding: .utf8)
    precondition(backedUp == legacy)
    precondition(WorkStore(file: file).projects == store.projects) // Stable IDs; no duplicate migration.
    precondition(store.addTodo("research", text: " \n ") == nil)
    let added = store.addTodo("research", text: "第三条任务")!
    store.editTodo("research", todoID: added, text: "改写后的任务")
    precondition(store.projects[0].todos.last?.text == "改写后的任务")
    precondition(store.projects[1] == Project.defaults[1])
    let now = Date()
    store.setCompleted("research", todoID: added, completed: true, now: now)
    store.archiveExpired(now: now.addingTimeInterval(9.99))
    precondition(store.projects[0].visibleTodos.contains { $0.id == added })
    store.setCompleted("research", todoID: added, completed: false)
    store.archiveExpired(now: now.addingTimeInterval(11))
    precondition(store.projects[0].todos.last?.completedAt == nil && store.projects[0].todos.last?.archivedAt == nil)
    store.setCompleted("research", todoID: added, completed: true, now: now.addingTimeInterval(12))
    store.archiveExpired(now: now.addingTimeInterval(21.99))
    precondition(store.projects[0].todos.last?.archivedAt == nil)
    store.archiveExpired(now: now.addingTimeInterval(22))
    precondition(!store.projects[0].visibleTodos.contains { $0.id == added })
    precondition(store.projects[0].todos.last?.text == "改写后的任务") // Completion archives rather than destroys.
    precondition(WorkStore(file: file).projects == store.projects)
    let resumed = store.addTodo("implementation", text: "重启后继续计时")!
    store.setCompleted("implementation", todoID: resumed, completed: true, now: Date().addingTimeInterval(-9.85))
    let restarted = WorkStore(file: file)
    precondition(restarted.projects[1].visibleTodos.count == 1)
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    precondition(restarted.projects[1].visibleTodos.isEmpty) // Actual scheduled callback after restart.
    precondition(store.projects[1].visibleTodos.isEmpty)
    let start = store.projects[0].waitingSince
    store.setStatus("research", .waiting)
    precondition(store.projects[0].waitingSince == start)
    store.setStatus("research", .next)
    precondition(store.projects[0].waitingSince == nil && store.projects[0].todos.count == 3)
    let projectFile = directory.appendingPathComponent("project-management.json")
    let managed = WorkStore(file: projectFile)
    precondition(managed.addProject(name: " \n ", detail: "") == nil)
    let customID = managed.addProject(name: " 新方向 🧪 ", detail: " 新的目标 ")!
    let taskID = managed.addTodo(customID, text: "独立保存的待办")!
    managed.setStatus(customID, .waiting)
    let custom = managed.projects.last!
    precondition(custom.name == "新方向 🧪" && custom.detail == "新的目标")
    for number in 1...7 { managed.addProject(name: "方向 \(number)", detail: "") }
    precondition(WorkStore(file: projectFile).projects == managed.projects && managed.projects.count == 12)
    managed.removeProject(customID)
    precondition(!managed.projects.contains { $0.id == customID })
    precondition(WorkStore(file: projectFile).removedProjects.first?.project == custom)
    managed.restoreProject(customID)
    precondition(managed.projects[4] == custom && managed.projects[4].todos[0].id == taskID)
    managed.removeProject("research")
    precondition(!WorkStore(file: projectFile).projects.contains { $0.id == "research" })
    managed.restoreProject("research")
    precondition(managed.projects.first?.id == "research")
    for project in managed.projects { managed.removeProject(project.id) }
    let empty = WorkStore(file: projectFile)
    precondition(empty.projects.isEmpty && empty.removedProjects.count == 12)
    empty.restoreProject(customID)
    precondition(empty.projects.count == 1 && empty.projects[0] == custom)
    let beforeEdit = empty.projects[0]
    precondition(!empty.editProject(customID, name: " \n ", detail: "不应保存"))
    precondition(empty.projects[0] == beforeEdit)
    precondition(empty.editProject(customID, name: " 新标题 ", detail: " 更新后的备注 "))
    let edited = empty.projects[0]
    precondition(edited.name == "新标题" && edited.detail == "更新后的备注")
    precondition(edited.id == beforeEdit.id && edited.todos == beforeEdit.todos)
    precondition(edited.status == beforeEdit.status && edited.waitingSince == beforeEdit.waitingSince)
    precondition(WorkStore(file: projectFile).projects[0] == edited)
    precondition(empty.editProject(customID, name: "新标题", detail: ""))
    precondition(WorkStore(file: projectFile).projects[0].detail.isEmpty)
    print("PASS: edit project title + note, blank-title rejection, clear note, stable task IDs + status + timer, restart persistence")
    print("PASS: add/remove/restore projects, blank-name validation, custom names + IDs, 12 directions, deleted defaults stay deleted, empty-state restart, tasks + status restored")
    let activeBeforeClear = empty.projects
    precondition(!empty.removedProjects.isEmpty)
    precondition(empty.clearRemovedProjects())
    precondition(empty.projects == activeBeforeClear && empty.removedProjects.isEmpty)
    let afterClear = WorkStore(file: projectFile)
    precondition(afterClear.removedProjects.isEmpty && afterClear.projects == activeBeforeClear)
    precondition(empty.clearRemovedProjects())
    let failureFile = directory.appendingPathComponent("clear-failure.json")
    let failureStore = WorkStore(file: failureFile)
    failureStore.removeProject("research")
    let removedBeforeFailure = failureStore.removedProjects.map(\.project)
    try FileManager.default.removeItem(at: failureFile)
    try FileManager.default.createDirectory(at: failureFile, withIntermediateDirectories: false)
    let originalFailedEdit = failureStore.projects[0]
    precondition(!failureStore.editProject(originalFailedEdit.id, name: "不应保存的标题", detail: "不应保存的备注"))
    precondition(failureStore.projects[0] == originalFailedEdit && failureStore.saveError != nil)
    precondition(!failureStore.clearRemovedProjects())
    precondition(failureStore.saveError != nil && failureStore.removedProjects.map(\.project) == removedBeforeFailure)
    print("PASS: clear removed projects, active projects + todos untouched, restart persistence, empty clear, rollback on failed save")
    let corrupt = Data("corrupt test file".utf8)
    try corrupt.write(to: file)
    let broken = WorkStore(file: file)
    precondition(broken.saveError != nil)
    broken.addTodo("implementation", text: "must not overwrite original")
    let preserved = try Data(contentsOf: file)
    precondition(preserved == corrupt)
    print("PASS: legacy migration + backup, stable IDs, independent lists, add/edit/blank input, 10-second boundary, undo + re-complete, archive persistence, real timer + restart recovery, status preservation, corrupt-file protection")
}

if CommandLine.arguments.contains("--self-test") {
    do { try runSelfTests() } catch { fputs("Self-test failed: \(error)\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
