import AppKit
import ApplicationServices
import Foundation
import UserNotifications

// Brings the agent that asked to the front.
//
// Claude Code owns the terminal title and repaints it, so a marker written
// when the question was asked is often gone by the time you click. The app
// therefore writes the marker again, to the agent's own terminal device, at
// the moment of the click, and then looks for that exact title through the
// accessibility API. Older items carry no terminal device, so the search falls
// back to the stored marker, the project, and the source tag.
enum SessionFocus {
    static func isAgentAlive(_ origin: ItemOrigin?) -> Bool {
        guard let pid = origin?.pid, pid > 1 else { return true }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    // MARK: - What to look for, and where

    private struct Plan {
        var apps: [NSRunningApplication]
        var tty: String?
        var mark: String?
        var exact: [String]
        var contains: [String]

        var isEmpty: Bool { apps.isEmpty || (mark == nil && exact.isEmpty && contains.isEmpty) }
    }

    private static func plan(for item: ObjectiveItem) -> Plan {
        let origin = item.origin
        let name = origin?.project ?? item.source
        let device = origin?.tty ?? nil
        let tty = (device?.isEmpty == false) ? device : nil
        // Reuse the marker the server wrote, so both spellings match.
        let mark = tty == nil ? nil : (origin?.marker ?? "◆ \(name ?? "agent") · \(origin?.code ?? "?")")

        var exact: [String] = []
        for candidate in [mark, origin?.marker] {
            if let candidate, !candidate.isEmpty, !exact.contains(candidate) { exact.append(candidate) }
        }
        var contains: [String] = []
        for candidate in [origin?.project, item.source] {
            if let candidate, !candidate.isEmpty, !contains.contains(candidate) { contains.append(candidate) }
        }

        return Plan(apps: apps(for: origin?.terminal), tty: tty, mark: mark, exact: exact, contains: contains)
    }

    static func canFocus(_ item: ObjectiveItem) -> Bool {
        !plan(for: item).isEmpty
    }

    // MARK: - The jump

    static func focus(_ item: ObjectiveItem) {
        let plan = plan(for: item)
        guard !plan.isEmpty else {
            trace("no plan for \(item.text)")
            return
        }
        guard AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        ) else {
            trace("not trusted for accessibility")
            notify(
                "Objective needs Accessibility",
                "Allow Objective in Privacy & Security > Accessibility, then click the item again."
            )
            return
        }

        // The title write and the accessibility poll both take time.
        DispatchQueue.global(qos: .userInitiated).async {
            var exact = plan.exact
            let marked = plan.tty.map { tty in plan.mark.map { setTitle($0, on: tty) } ?? false } ?? false
            if marked, let mark = plan.mark {
                exact = [mark] + exact.filter { $0 != mark }
            }
            trace("jump \(item.text) tty=\(plan.tty ?? "-") marked=\(marked) exact=\(exact) contains=\(plan.contains)")

            for app in plan.apps {
                // The terminal comes forward first, then the right window is
                // raised inside it.
                bringForward(app)
                let element = AXUIElementCreateApplication(app.processIdentifier)
                // Ghostty publishes its windows only while it is the active
                // app, and the new title needs a moment to arrive.
                for attempt in 0..<12 {
                    usleep(80_000)
                    let windows = list(element, kAXWindowsAttribute)
                    if windows.isEmpty { continue }
                    if let hit = search(windows, exact: exact, contains: attempt >= 4 ? plan.contains : []) {
                        trace("raised \(title(of: hit.tab ?? hit.window)) in \(app.localizedName ?? "?")")
                        raise(hit, in: app)
                        // The marker did its work. Give the tab its name back,
                        // unless the agent still waits and owns that marker.
                        if marked, !item.isBlocking, let tty = plan.tty, let name = plan.contains.first {
                            _ = setTitle(name, on: tty)
                        }
                        return
                    }
                    if attempt == 11 {
                        trace("no match in \(app.localizedName ?? "?"): \(windows.map { title(of: $0) })")
                    }
                }
            }
            notify(
                "No window found",
                "Objective could not find the terminal of \(plan.contains.first ?? "that agent")."
            )
        }
    }

    // A terminal restores its own last window and tab when it comes forward, so
    // the choice is made again after the activation, until it holds.
    private static func raise(_ hit: (window: AXUIElement, tab: AXUIElement?), in app: NSRunningApplication) {
        bringForward(app)
        for attempt in 0..<5 {
            AXUIElementSetAttributeValue(hit.window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(hit.window, kAXRaiseAction as CFString)
            if let tab = hit.tab {
                AXUIElementPerformAction(tab, kAXPressAction as CFString)
            }
            usleep(attempt == 0 ? 60_000 : 150_000)
            if settled(hit) { break }
            if attempt == 4 { trace("could not hold \(title(of: hit.tab ?? hit.window))") }
        }
        // Says whether the terminal kept the front, or something took it back.
        var report = ""
        for wait in [100_000, 400_000, 1_000_000] as [UInt32] {
            usleep(wait)
            let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            report += " \(front)"
        }
        trace("after jump:\(report) tabHeld=\(settled(hit))")
    }

    // A background app may not hand the front to another app: NSRunningApplication
    // .activate is refused, or it holds for a moment and falls back. Opening the
    // app that already runs is the same move the `open -a` command makes, and it
    // works from here.
    private static func bringForward(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else {
            _ = DispatchQueue.main.sync { app.activate(options: []) }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let opened = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            opened.signal()
        }
        _ = opened.wait(timeout: .now() + 2)
        // The front changes a moment after the call returns.
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                return
            }
            usleep(50_000)
        }
    }

    private static func settled(_ hit: (window: AXUIElement, tab: AXUIElement?)) -> Bool {
        if let tab = hit.tab, (attribute(tab, kAXValueAttribute) as? NSNumber)?.intValue != 1 {
            return false
        }
        return (attribute(hit.window, kAXMainAttribute) as? NSNumber)?.boolValue ?? false
    }

    private static func search(
        _ windows: [AXUIElement],
        exact: [String],
        contains: [String]
    ) -> (window: AXUIElement, tab: AXUIElement?)? {
        func hit(_ title: String) -> Bool {
            if exact.contains(title) { return true }
            return contains.contains { !$0.isEmpty && title.localizedCaseInsensitiveContains($0) }
        }
        // A window title only shows the active tab, so tabs are searched first.
        for window in windows {
            for tab in tabs(of: window) where hit(title(of: tab)) {
                return (window, tab)
            }
        }
        for window in windows where hit(title(of: window)) {
            return (window, nil)
        }
        return nil
    }

    // MARK: - Accessibility helpers

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func list(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        (attribute(element, name) as? [AXUIElement]) ?? []
    }

    private static func title(of element: AXUIElement) -> String {
        (attribute(element, kAXTitleAttribute) as? String) ?? ""
    }

    private static func role(of element: AXUIElement) -> String {
        (attribute(element, kAXRoleAttribute) as? String) ?? ""
    }

    // The tab bar sits a few levels below the window, so walk down to it.
    private static func tabs(of window: AXUIElement) -> [AXUIElement] {
        var queue = list(window, kAXChildrenAttribute)
        for _ in 0..<5 {
            var next: [AXUIElement] = []
            for element in queue {
                if role(of: element) == kAXTabGroupRole {
                    return list(element, kAXChildrenAttribute)
                        .filter { role(of: $0) == kAXRadioButtonRole }
                }
                next.append(contentsOf: list(element, kAXChildrenAttribute))
            }
            if next.isEmpty { break }
            queue = next
        }
        return []
    }

    // MARK: - The terminal

    // An escape sequence written to the agent's terminal device renames that
    // window or tab, and stays invisible in the text.
    private static func setTitle(_ title: String, on tty: String) -> Bool {
        guard let handle = FileHandle(forWritingAtPath: "/dev/\(tty)"),
              let data = "\u{1b}]2;\(title)\u{7}".data(using: .utf8)
        else { return false }
        defer { try? handle.close() }
        do { try handle.write(contentsOf: data) } catch { return false }
        return true
    }

    private static let terminals: [String: String] = [
        "ghostty": "com.mitchellh.ghostty",
        "iterm.app": "com.googlecode.iterm2",
        "apple_terminal": "com.apple.Terminal",
        "warpterminal": "dev.warp.Warp-Stable",
        "wezterm": "com.github.wez.wezterm",
        "kitty": "net.kovidgoyal.kitty",
        "alacritty": "org.alacritty",
        "vscode": "com.microsoft.VSCode",
    ]

    // The item names its terminal. An older item names none, so every terminal
    // that runs now is a candidate.
    private static func apps(for terminal: String?) -> [NSRunningApplication] {
        var wanted = Array(terminals.values)
        if let key = terminal?.lowercased(), let known = terminals[key] { wanted = [known] }
        return NSWorkspace.shared.runningApplications.filter {
            guard let id = $0.bundleIdentifier else { return false }
            return wanted.contains(id)
        }
    }

    // One line for each jump, so a failure can be read instead of guessed.
    private static func trace(_ message: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
        let file = StatePaths.directory.appendingPathComponent("focus.log")
        guard let data = line.data(using: .utf8) else { return }
        // Only the recent jumps are interesting, so the file stays small.
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > 32_000 { try? FileManager.default.removeItem(at: file) }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }

    private static func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }
}
