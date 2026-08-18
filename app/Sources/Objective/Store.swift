import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var items: [ObjectiveItem] = []
    @Published private(set) var newIDs: Set<String> = []

    private var knownIDs: Set<String> = []
    private var firstLoadDone = false
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var dirFD: CInt = -1

    // Done items stay visible this long before they fade out of the overlay.
    private let doneLinger: TimeInterval = 6

    var visibleItems: [ObjectiveItem] {
        let now = Date().timeIntervalSince1970
        return items.filter { item in
            if item.isOpen { return true }
            if let doneAt = item.doneAt { return now - doneAt < doneLinger }
            return false
        }
        .sorted { a, b in
            // A blocked agent waits for this answer, so it outranks anything
            // that only sits in the queue. Done items keep their place while
            // they linger; a check-off must not reorder the list mid-animation.
            if rank(a) != rank(b) { return rank(a) > rank(b) }
            return a.createdAt < b.createdAt
        }
    }

    private func rank(_ item: ObjectiveItem) -> Int {
        guard item.isOpen else { return -1 }
        if !SessionFocus.isAgentAlive(item.origin) { return 0 }
        return (item.isUrgent ? 2 : 0) + (item.isBlocking ? 1 : 0)
    }

    var openCount: Int { items.filter(\.isOpen).count }

    func start() {
        try? FileManager.default.createDirectory(at: StatePaths.directory, withIntermediateDirectories: true)
        reload()
        watchDirectory()
    }

    // MARK: - File IO

    private func readState() -> BoardState {
        guard let data = try? Data(contentsOf: StatePaths.stateFile),
              let state = try? JSONDecoder().decode(BoardState.self, from: data)
        else { return .empty }
        return state
    }

    private func writeState(_ state: BoardState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let tmp = StatePaths.directory.appendingPathComponent("state.json.tmp-app")
        do {
            try data.write(to: tmp)
            _ = try FileManager.default.replaceItemAt(StatePaths.stateFile, withItemAt: tmp)
        } catch {
            try? data.write(to: StatePaths.stateFile)
        }
    }

    private func mutate(_ change: (inout BoardState) -> Void) {
        var state = readState()
        change(&state)
        state.rev += 1
        writeState(state)
        applyLoaded(state)
    }

    // MARK: - Actions

    func toggle(_ id: String) {
        mutate { state in
            guard let i = state.items.firstIndex(where: { $0.id == id }) else { return }
            if state.items[i].isOpen {
                state.items[i].status = "done"
                state.items[i].doneAt = Date().timeIntervalSince1970
            } else {
                state.items[i].status = "open"
                state.items[i].doneAt = nil
            }
        }
    }

    func answer(_ id: String, with text: String) {
        mutate { state in
            guard let i = state.items.firstIndex(where: { $0.id == id }), state.items[i].isOpen else { return }
            let now = Date().timeIntervalSince1970
            state.items[i].answer = text
            state.items[i].answeredAt = now
            state.items[i].status = "done"
            state.items[i].doneAt = now
        }
        NSSound(named: "Pop")?.play()
    }

    func clearAll() {
        mutate { state in
            let now = Date().timeIntervalSince1970
            for i in state.items.indices where state.items[i].isOpen {
                state.items[i].status = "done"
                state.items[i].doneAt = now
            }
        }
    }

    // MARK: - Loading and watching

    private func reload() {
        applyLoaded(readState())
    }

    private func applyLoaded(_ state: BoardState) {
        // Prune done items older than one day so the file stays small.
        let cutoff = Date().timeIntervalSince1970 - 86_400
        var pruned = state
        pruned.items.removeAll { !$0.isOpen && ($0.doneAt ?? 0) < cutoff }
        if pruned.items.count != state.items.count {
            writeState(pruned)
        }

        let fresh = pruned.items.filter { $0.isOpen && !knownIDs.contains($0.id) }
        for item in pruned.items { knownIDs.insert(item.id) }

        items = pruned.items

        if firstLoadDone, !fresh.isEmpty {
            announce(fresh)
        }
        firstLoadDone = true

        // Trigger a refresh after recently-done items must disappear.
        if items.contains(where: { !$0.isOpen }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + doneLinger + 0.3) { [weak self] in
                self?.objectWillChange.send()
                AppDelegate.shared?.fitPanel()
            }
        }
    }

    private func announce(_ fresh: [ObjectiveItem]) {
        for item in fresh { newIDs.insert(item.id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            for item in fresh { self?.newIDs.remove(item.id) }
        }

        let hasUrgent = fresh.contains(where: \.isUrgent)
        NSSound(named: hasUrgent ? "Sosumi" : "Glass")?.play()
        AppDelegate.shared?.showPanel()

        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        for item in fresh {
            let content = UNMutableNotificationContent()
            content.title = item.isUrgent ? "Urgent objective" : "New objective"
            if let source = item.source, !source.isEmpty {
                content.subtitle = source
            }
            content.body = item.text
            let request = UNNotificationRequest(identifier: item.id, content: content, trigger: nil)
            center.add(request)
        }
    }

    private func watchDirectory() {
        dirFD = open(StatePaths.directory.path, O_EVTONLY)
        guard dirFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.reload()
            AppDelegate.shared?.fitPanel()
        }
        source.setCancelHandler { [dirFD] in close(dirFD) }
        source.resume()
        dirWatcher = source
    }
}
