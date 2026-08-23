import AppKit
import QuartzCore
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static var shared: AppDelegate?

    private var panel: NSPanel!
    private var hosting: BoardHostingView!
    private var statusItem: NSStatusItem!

    private let originKey = "panelOrigin"
    private let anchorKey = "panelAnchorPoint"
    private let anchorSideKey = "panelAnchorTrailing"

    // The anchored corner: the top edge, plus the left or right edge, whichever
    // the panel hangs from. Every resize keeps this point fixed.
    private var anchorPoint: NSPoint = .zero
    private var anchorTrailing = true
    private var isFitting = false

    private let resizeDuration: TimeInterval = 0.34

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setUpPanel()
        setUpStatusItem()
        requestNotificationPermission()
        Store.shared.start()
        fitPanel(animated: false)
        panel.orderFrontRegardless()
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

    func fitPanel(animated: Bool = true) {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }

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
        // clip that keeps the glass inside the card must follow the height.
        let radius = min(22, size.height / 2)

        isFitting = true
        if animated {
            hosting.layer?.add(cornerAnimation(to: radius), forKey: "cornerRadius")
            hosting.layer?.cornerRadius = radius
            NSAnimationContext.runAnimationGroup { context in
                context.duration = resizeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: {
                MainActor.assumeIsolated {
                    self.isFitting = false
                    panel.invalidateShadow()
                }
            }
        } else {
            hosting.layer?.cornerRadius = radius
            panel.setFrame(frame, display: true, animate: false)
            isFitting = false
            panel.invalidateShadow()
        }
    }

    private func cornerAnimation(to radius: CGFloat) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "cornerRadius")
        animation.fromValue = hosting.layer?.cornerRadius ?? radius
        animation.toValue = radius
        animation.duration = resizeDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
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
