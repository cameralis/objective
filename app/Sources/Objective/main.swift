import AppKit
import SwiftUI
import UserNotifications

// Borderless windows refuse key status by default. The reply text field
// needs it, so allow it while the panel stays non-activating.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?

    private var panel: NSPanel!
    private var hosting: NSHostingView<BoardView>!
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
        hosting = NSHostingView(rootView: BoardView(store: Store.shared))
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
