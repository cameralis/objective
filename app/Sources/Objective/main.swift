import AppKit
import SwiftUI
import UserNotifications

// Borderless windows refuse key status by default. This one may become key, so
// the answer box can take the keyboard when you click into it. The panel stays
// non-activating: a click that answers or jumps must not pull the front app
// away from what it was doing, and a jump would bounce straight back.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    // A non-activating panel never makes its app active, so the keyboard keeps
    // going to the terminal, and the reply field stays dead. The panel becomes
    // key only when a view needs it, which is the text field, so activating
    // here costs no focus anywhere else.
    // A menu bar extra has no Edit menu, and the standard editing shortcuts
    // travel through it. Without this, Command-V in the reply field does
    // nothing. Send the shortcut down the responder chain instead.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), flags.subtracting([.command, .shift]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return false }

        let shifted = flags.contains(.shift)
        let action: Selector?
        switch key {
        case "v": action = shifted ? nil : #selector(NSText.paste(_:))
        case "c": action = shifted ? nil : #selector(NSText.copy(_:))
        case "x": action = shifted ? nil : #selector(NSText.cut(_:))
        case "a": action = shifted ? nil : #selector(NSText.selectAll(_:))
        case "z": action = shifted ? Selector(("redo:")) : Selector(("undo:"))
        default: action = nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

// An inactive app swallows the first click in its window, which would cost you
// one click for every answer. This view takes that click as well.
final class BoardHostingView: NSHostingView<BoardView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?

    private var panel: NSPanel!
    private var hosting: BoardHostingView!
    private var statusItem: NSStatusItem!

    private let originKey = "panelOrigin"

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setUpPanel()
        setUpStatusItem()
        requestNotificationPermission()
        Store.shared.start()
        fitPanel()
        panel.orderFrontRegardless()
    }

    // MARK: - Panel

    private func setUpPanel() {
        hosting = BoardHostingView(rootView: BoardView(store: Store.shared))
        // When the panel becomes key, the glass backdrop paints the full
        // square window bounds. Clip it to the card's rounded shape.
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 22
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true

        panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hosting
        panel.delegate = self

        restoreOrigin()
    }

    func fitPanel() {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        guard size.height > 0, size != panel.frame.size else { return }
        var frame = panel.frame
        // Keep the top edge in place while the height changes.
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        // A long queue must not push the last items off the screen edge,
        // where nothing can be clicked any more.
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.maxY - frame.height, visible.minY))
            frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.maxX - frame.width, visible.minX))
        }
        panel.setFrame(frame, display: true, animate: false)
        panel.invalidateShadow()
    }

    func showPanel() {
        panel.orderFrontRegardless()
    }

    func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func restoreOrigin() {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: originKey) {
            let origin = NSPointFromString(stored)
            panel.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.maxX - panel.frame.width - 24,
                y: visible.maxY - panel.frame.height - 24
            )
            panel.setFrameOrigin(origin)
        }
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: originKey)
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "scope",
            accessibilityDescription: "Objective"
        )

        let menu = NSMenu()
        menu.addItem(withTitle: "Show / Hide Overlay", action: #selector(toggleFromMenu), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Objective", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func toggleFromMenu() {
        togglePanel()
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
