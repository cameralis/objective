import AppKit
import SwiftUI
import UserNotifications

// Which screen edge the panel hangs from. The card and the badge have very
// different widths, so the side nearest the screen edge must stay put while
// the panel contracts, or the badge walks away from where you left the card.
@MainActor
final class PanelLayout: ObservableObject {
    static let shared = PanelLayout()
    @Published var anchorTrailing = true
}

// Borderless windows refuse key status by default. This one may become key, so
// the answer box can take the keys, which is what a non-activating panel is
// for: the board answers and jumps without ever pulling the front app away.
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

// A decorative badge must not steal clicks from the status item below it.
final class StatusBadgeImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?

    private var panel: NSPanel!
    private var hosting: BoardHostingView!
    private var statusItem: NSStatusItem!
    private var enabledMenuItem: NSMenuItem!
    private var overlayMenuItem: NSMenuItem!
    private var disabledBadge: StatusBadgeImageView!
    private var presenceMenuItem: NSMenuItem!
    private var presenceMenuTimer: Timer?
    private var hereMenuItem: NSMenuItem!
    private var awayMenuItem: NSMenuItem!
    private var automaticMenuItem: NSMenuItem!
    private var inputMonitoringMenuItem: NSMenuItem!
    private let objectiveConfiguration = ObjectiveConfiguration()

    private let originKey = "panelOrigin"
    private let anchorKey = "panelAnchorPoint"
    private let anchorSideKey = "panelAnchorTrailing"

    // The anchored corner: the top edge, plus the left or right edge, whichever
    // the panel hangs from. Every resize keeps this point fixed.
    private var anchorPoint: NSPoint = .zero
    private var anchorTrailing = true
    private var isFitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setUpPanel()
        setUpStatusItem()
        requestNotificationPermission()
        Store.shared.start()
        Presence.shared.start()
        try? objectiveConfiguration.captureCurrentConfiguration()
        fitPanel()
        if objectiveConfiguration.isEnabled {
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Panel

    private func setUpPanel() {
        hosting = BoardHostingView(rootView: BoardView(store: Store.shared, layout: PanelLayout.shared))
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

        restoreAnchor()
    }

    // The board reports the size of its own card, once for every frame of its
    // own animation. The window copies that size, so the glass edge and the
    // shadow always sit exactly on the card, and no ghost of an older, larger
    // frame stays behind it.
    func resize(to size: CGSize) {
        guard let panel, let hosting, size.width > 1, size.height > 1 else { return }
        let size = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))

        var frame = NSRect(
            x: anchorTrailing ? anchorPoint.x - size.width : anchorPoint.x,
            y: anchorPoint.y - size.height,
            width: size.width,
            height: size.height
        )
        // A long queue must not push the last items off the screen edge,
        // where nothing can be clicked any more.
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.maxY - frame.height, visible.minY))
            frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.maxX - frame.width, visible.minX))
        }
        guard frame != panel.frame else { return }

        // The card is a wide rectangle and the badge is a small capsule, so the
        // clip that keeps the glass inside the window must follow the height.
        hosting.layer?.cornerRadius = min(22, size.height / 2)

        isFitting = true
        panel.setFrame(frame, display: true, animate: false)
        isFitting = false
        panel.invalidateShadow()
    }

    // The first frame, before the board has ever reported a size.
    private func fitPanel() {
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        resize(to: hosting.fittingSize)
    }

    func showPanel() {
        guard objectiveConfiguration.isEnabled else { return }
        panel.orderFrontRegardless()
    }

    func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func restoreAnchor() {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: anchorKey) {
            anchorPoint = NSPointFromString(stored)
            anchorTrailing = defaults.bool(forKey: anchorSideKey)
            PanelLayout.shared.anchorTrailing = anchorTrailing
            return
        }
        // Before the badge there was only an origin, saved for a card that was
        // always 340 wide. Read it back as a frame and take the anchor from it.
        if let stored = defaults.string(forKey: originKey) {
            adoptAnchor(from: NSRect(origin: NSPointFromString(stored), size: panel.frame.size))
            return
        }
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            anchorTrailing = true
            anchorPoint = NSPoint(x: visible.maxX - 24, y: visible.maxY - 24)
            PanelLayout.shared.anchorTrailing = true
        }
    }

    private func adoptAnchor(from frame: NSRect) {
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? frame
        anchorTrailing = frame.midX > visible.midX
        anchorPoint = NSPoint(x: anchorTrailing ? frame.maxX : frame.minX, y: frame.maxY)
        PanelLayout.shared.anchorTrailing = anchorTrailing

        let defaults = UserDefaults.standard
        defaults.set(NSStringFromPoint(anchorPoint), forKey: anchorKey)
        defaults.set(anchorTrailing, forKey: anchorSideKey)
    }

    func windowDidMove(_ notification: Notification) {
        // A resize moves the window too. Only a drag by hand changes the anchor.
        guard !isFitting else { return }
        adoptAnchor(from: panel.frame)
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setUpStatusIcon()

        let menu = NSMenu()
        menu.delegate = self

        // Agents use this to choose between the overlay and Telegram, so the
        // reading and the way to correct it sit at the top.
        menu.addItem(.sectionHeader(title: "Presence"))
        presenceMenuItem = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        hereMenuItem = menu.addItem(withTitle: "Here for 1 Hour", action: #selector(chooseHere), keyEquivalent: "")
        awayMenuItem = menu.addItem(withTitle: "Away Until I Return", action: #selector(chooseAway), keyEquivalent: "")
        automaticMenuItem = menu.addItem(withTitle: "Detect Automatically", action: #selector(chooseAutomatic), keyEquivalent: "")
        inputMonitoringMenuItem = menu.addItem(withTitle: "Allow Input Monitoring…", action: #selector(openInputMonitoring), keyEquivalent: "")
        inputMonitoringMenuItem.toolTip = "Without it, fake input from computer use counts as you"
        for item in [hereMenuItem, awayMenuItem, automaticMenuItem, inputMonitoringMenuItem] {
            item?.target = self
        }
        menu.addItem(.separator())

        enabledMenuItem = menu.addItem(
            withTitle: "Objective Enabled",
            action: #selector(toggleObjectiveFromMenu),
            keyEquivalent: ""
        )
        enabledMenuItem.target = self
        enabledMenuItem.toolTip = "Adds or removes Objective from new Claude Code sessions"
        menu.addItem(.separator())
        overlayMenuItem = menu.addItem(withTitle: "Show / Hide Overlay", action: #selector(toggleFromMenu), keyEquivalent: "")
        overlayMenuItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Objective", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        updateStatusMenu()
    }

    private func setUpStatusIcon() {
        guard let button = statusItem.button else { return }

        let image = NSImage(
            systemSymbolName: "scope",
            accessibilityDescription: "Objective"
        )
        image?.isTemplate = true
        button.image = image

        let badgeSymbol = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: nil
        )
        let pointSize = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        let palette = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
        let badgeImage = badgeSymbol?.withSymbolConfiguration(pointSize.applying(palette))
        badgeImage?.isTemplate = false

        disabledBadge = StatusBadgeImageView(image: badgeImage ?? NSImage())
        disabledBadge.translatesAutoresizingMaskIntoConstraints = false
        disabledBadge.imageScaling = .scaleProportionallyUpOrDown
        disabledBadge.setAccessibilityElement(false)
        button.addSubview(disabledBadge)

        NSLayoutConstraint.activate([
            disabledBadge.widthAnchor.constraint(equalToConstant: 10),
            disabledBadge.heightAnchor.constraint(equalToConstant: 10),
            disabledBadge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
            disabledBadge.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: 1),
        ])
    }

    @objc private func toggleFromMenu() {
        togglePanel()
    }

    @objc private func chooseHere() { Presence.shared.choose(.here) }
    @objc private func chooseAway() { Presence.shared.choose(.away) }
    @objc private func chooseAutomatic() { Presence.shared.choose(nil) }
    @objc private func openInputMonitoring() { Presence.shared.openInputMonitoringSettings() }

    private func updatePresenceMenu() {
        let presence = Presence.shared
        let name: String
        switch presence.reading.state {
        case .present: name = "At the Mac"
        case .unsure: name = "Maybe at the Mac"
        case .away: name = "Away"
        }
        var detail = presence.reading.reason
        if let last = presence.lastInput {
            detail += ", last input \(Self.ago(Date().timeIntervalSince1970 - last))"
        }
        presenceMenuItem.title = "\(name): \(detail)"
        hereMenuItem.state = presence.override?.kind == .here ? .on : .off
        awayMenuItem.state = presence.override?.kind == .away ? .on : .off
        automaticMenuItem.state = presence.override == nil ? .on : .off
        inputMonitoringMenuItem.isHidden = presence.seesRealInput
    }

    private static func ago(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(max(Int(seconds), 0)) s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        return "\(Int(seconds / 3600)) h ago"
    }

    @objc private func toggleObjectiveFromMenu() {
        let enable = !objectiveConfiguration.isEnabled
        do {
            try objectiveConfiguration.setEnabled(enable)
            if enable {
                showPanel()
            } else {
                panel.orderOut(nil)
            }
            updateStatusMenu()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Objective could not update Claude Code"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func updateStatusMenu() {
        let enabled = objectiveConfiguration.isEnabled
        enabledMenuItem?.state = enabled ? .on : .off
        overlayMenuItem?.isEnabled = enabled
        disabledBadge?.isHidden = enabled
        statusItem.button?.setAccessibilityLabel(enabled ? "Objective" : "Objective disabled")
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        Presence.shared.refresh()
        updatePresenceMenu()
        updateStatusMenu()
        // The reading stays live while the menu is open: keep the mouse still
        // and the last input counts up. An open menu runs its own run loop
        // mode, so the timer must run in the common modes.
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                Presence.shared.refresh()
                AppDelegate.shared?.updatePresenceMenu()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        presenceMenuTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        presenceMenuTimer?.invalidate()
        presenceMenuTimer = nil
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
