import AppKit
import SwiftUI
import Testing
@testable import Objective

@Suite(.serialized) @MainActor
struct BoardHeaderInteractionTests {
    @Test(arguments: [0, 1]) func expandedHeaderHandlesDragging(openCount: Int) throws {
        let hosting = NSHostingView(rootView: BoardHeader(openCount: openCount, onClear: {}))
        let panel = OverlayPanel(
            contentRect: NSRect(x: 200, y: 200, width: 308, height: 24),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let target = try #require(hosting.hitTest(NSPoint(x: 100, y: 12)))
        #expect(target is WindowInteractionView)
        if openCount > 0 {
            let clearTarget = try #require(hosting.hitTest(NSPoint(x: 300, y: 12)))
            #expect(!(clearTarget is WindowInteractionView))
        }
        let origin = panel.frame.origin
        target.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 100, y: 12), in: panel))
        target.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: 140, y: 32), in: panel))
        #expect(panel.frame.origin == NSPoint(x: origin.x + 40, y: origin.y + 20))
        // Moving back to the starting screen point must undo the full translation.
        target.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: 60, y: -8), in: panel))
        #expect(panel.frame.origin == origin)
        target.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 100, y: 12), in: panel))
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in panel: NSPanel) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    @Test func badgeDragMovesWithoutOpeningAndNextClickStillOpens() throws {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 200, y: 200, width: 113, height: 30),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        let target = WindowInteractionView()
        var clicks = 0
        target.onClick = { clicks += 1 }
        panel.contentView = target
        target.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 10, y: 10), in: panel))
        target.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: 40, y: 20), in: panel))
        target.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 10, y: 10), in: panel))
        #expect(panel.frame.origin == NSPoint(x: 230, y: 210))
        #expect(clicks == 0)

        target.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 10, y: 10), in: panel))
        target.mouseUp(with: try event(.leftMouseUp, at: NSPoint(x: 10, y: 10), in: panel))
        #expect(clicks == 1)
    }
}
