import AppKit
import SwiftUI

// The overlay is a non-activating panel, so a click inside it leaves the
// keyboard with the app you were using. A SwiftUI TextField therefore looks
// focused and receives nothing. This field takes the keyboard itself: it
// activates the app, makes the panel key, and becomes first responder.
final class TypingField: NSTextField {
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        takeKeyboard()
        super.mouseDown(with: event)
    }

    func takeKeyboard() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
    }
}

struct ReplyField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focusNow: Bool
    var onSubmit: (String) -> Void

    func makeNSView(context: Context) -> TypingField {
        let field = TypingField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.placeholderString = "Your answer…"
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: TypingField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit
        if field.stringValue != text { field.stringValue = text }
        if focusNow {
            DispatchQueue.main.async {
                field.takeKeyboard()
                focusNow = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: (String) -> Void

        init(text: Binding<String>, onSubmit: @escaping (String) -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        @objc func submit(_ sender: NSTextField) {
            let answer = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { return }
            onSubmit(answer)
        }
    }
}
