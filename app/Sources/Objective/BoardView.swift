import SwiftUI

private struct ContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct BoardView: View {
    @ObservedObject var store: Store
    @ObservedObject var layout: PanelLayout
    @State private var measuredHeight: CGFloat = 0
    @State private var peeking = false

    // Nothing waits for you, so the card has nothing to say. It contracts to a
    // badge that keeps the board in sight without taking a corner of a screen.
    private var isCollapsed: Bool { store.visibleItems.isEmpty && !peeking }

    var body: some View {
        Group {
            if isCollapsed {
                badge
                    .transition(.scale(scale: 0.86, anchor: layout.anchorTrailing ? .topTrailing : .topLeading).combined(with: .opacity))
            } else {
                card
                    .transition(.opacity)
            }
        }
        // Report every step of the card's own animation, so the window can
        // follow it exactly instead of jumping to the size it ends at.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            AppDelegate.shared?.resize(to: size)
        }
        // The window grows from the edge it hangs on, so the content must sit
        // against that same edge while the frame is still on its way.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: badgeAnchor)
        .animation(.easeInOut(duration: 0.3), value: isCollapsed)
        .onChange(of: store.visibleItems.isEmpty) { _, empty in
            // A peek lasts until the queue takes over. After that the board
            // contracts again by itself.
            if !empty { peeking = false }
        }
    }

    private var badgeAnchor: Alignment { layout.anchorTrailing ? .topTrailing : .topLeading }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if store.visibleItems.isEmpty {
                emptyRow
            } else {
                items
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 340, alignment: .leading)
        .animation(.spring(duration: 0.4), value: store.visibleItems)
        .glassCard(radius: 22)
    }

    // One click opens the card again, for the times you want to move the panel
    // or read what you answered a moment ago.
    private var badge: some View {
        Button { peeking = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("ALL CLEAR")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show the board")
        .glassCard(radius: 999)
    }

    // The queue may be long when many agents work at once, so it scrolls
    // instead of growing over the whole screen.
    private var items: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.visibleItems) { item in
                    ItemRow(
                        item: item,
                        isNew: store.newIDs.contains(item.id),
                        onToggle: { store.toggle(item.id) },
                        onAnswer: { store.answer(item.id, with: $0) },
                        onJump: { SessionFocus.focus(item) }
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .zIndex(store.newIDs.contains(item.id) ? 2 : (item.isOpen ? 1 : 0))
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeight.self, value: proxy.size.height)
                }
            )
        }
        .frame(height: min(measuredHeight, 460))
        .scrollDisabled(measuredHeight <= 460)
        .onPreferenceChange(ContentHeight.self) { measuredHeight = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("OBJECTIVE")
                .font(.system(size: 11, weight: .bold))
                .tracking(2.5)
                .foregroundStyle(.secondary)
            Spacer()
            if store.openCount > 0 {
                Text("\(store.openCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Button {
                    store.clearAll()
                } label: {
                    Image(systemName: "checkmark.circle.badge.xmark")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Mark all done")
            }
        }
        .padding(.bottom, 4)
    }

    // The card is empty on purpose here, so the row is also the way back to
    // the badge.
    private var emptyRow: some View {
        Button { peeking = false } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                Text("All clear")
                    .font(.system(size: 13))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.tertiary)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Contract to a badge")
    }
}

private struct ItemRow: View {
    let item: ObjectiveItem
    let isNew: Bool
    let onToggle: () -> Void
    let onAnswer: (String) -> Void
    let onJump: () -> Void

    @State private var reply = ""
    @State private var writingReply = false
    @State private var replyFocused = false

    private var accent: Color { item.isUrgent ? .red : .accentColor }
    private var agentGone: Bool { item.isOpen && !SessionFocus.isAgentAlive(item.origin) }
    private var canJump: Bool { item.isOpen && !agentGone && SessionFocus.canFocus(item) }
    // A pure permission question needs no text box; a fact question keeps one
    // for the answer that is not on a button.
    private var showsReplyField: Bool {
        guard item.isOpen, item.allowReply ?? false else { return false }
        return item.choices?.isEmpty != false || writingReply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button(action: onToggle) {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(statusStyle)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help("Mark done")

                // A button, not a tap gesture: a gesture ignores the first
                // click that arrives while the overlay's app is not active,
                // which is every click you make while you work elsewhere.
                Button { if canJump { onJump() } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        summary
                        Spacer(minLength: 0)
                        if canJump {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // The board routes; it does not try to be the conversation.
                .help(canJump ? "Go to the agent that asked" : "")
            }

            if item.isOpen, let choices = item.choices, !choices.isEmpty {
                choiceButtons(choices)
                    .padding(.leading, 25)
            }

            if showsReplyField {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    ReplyField(text: $reply, focusNow: $replyFocused) { onAnswer($0) }
                        .frame(height: 16)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.leading, 25)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(rowStroke, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.8), value: isNew)
        .animation(.snappy(duration: 0.25), value: writingReply)
        .geometryGroup()
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(item.text)
                    .font(.system(size: 13, weight: .medium))
                    .strikethrough(!item.isOpen, color: .secondary)
                    .foregroundStyle(item.isOpen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if let source = item.source, !source.isEmpty {
                    Text(source)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(.quaternary, in: Capsule())
                }
            }
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if item.isOpen { statusLine }
            if !item.isOpen, let answer = item.answer, !answer.isEmpty {
                Label(answer, systemImage: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // Says why this item is at the top: an agent is stalled inside its tool
    // call, or the session that asked has gone away.
    @ViewBuilder
    private var statusLine: some View {
        if agentGone {
            Label("the agent is gone", systemImage: "moon.zzz")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        } else if item.isBlocking {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                Label(
                    "blocked \(Self.duration(item.blockedFor ?? 0))",
                    systemImage: "hourglass"
                )
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
            }
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(max(Int(seconds), 1))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m"
    }

    // Buttons only sit side by side while every label stays fully readable.
    // Otherwise they stack, because a truncated option cannot be chosen.
    @ViewBuilder
    private func choiceButtons(_ choices: [String]) -> some View {
        let escapeHatch = (item.allowReply ?? false) && !writingReply
        let longest = choices.map(\.count).max() ?? 0
        let fitsInARow = choices.count <= 2 && longest <= 14 && !escapeHatch

        if fitsInARow {
            HStack(spacing: 6) {
                ForEach(choices, id: \.self) { choice in
                    ChoiceButton(title: choice, accent: accent, wide: false) {
                        onAnswer(choice)
                    }
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(choices, id: \.self) { choice in
                    ChoiceButton(title: choice, accent: accent, wide: true) {
                        onAnswer(choice)
                    }
                }
                if escapeHatch {
                    ChoiceButton(title: "Other…", accent: .secondary, wide: true) {
                        writingReply = true
                        replyFocused = true
                    }
                }
            }
        }
    }

    private var statusSymbol: String {
        if !item.isOpen { return "checkmark.circle.fill" }
        return item.isUrgent ? "exclamationmark.circle.fill" : "circle"
    }

    private var statusStyle: AnyShapeStyle {
        if !item.isOpen { return AnyShapeStyle(.green) }
        return item.isUrgent ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)
    }

    private var rowFill: Color {
        if isNew { return accent.opacity(0.18) }
        if item.isOpen, item.isUrgent { return Color.red.opacity(0.10) }
        return Color.primary.opacity(0.05)
    }

    private var rowStroke: Color {
        if isNew { return accent.opacity(0.6) }
        if item.isOpen, item.isUrgent { return Color.red.opacity(0.35) }
        return .clear
    }
}

private struct ChoiceButton: View {
    let title: String
    let accent: Color
    let wide: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(accent.opacity(hovering ? 0.34 : 0.18), in: shape)
                .overlay(shape.strokeBorder(accent.opacity(hovering ? 0.75 : 0.4), lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    // A radius wider than half the height draws a capsule, so one shape covers
    // both the inline pill and the stacked full-width button.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: wide ? 9 : 999, style: .continuous)
    }
}

private extension View {
    @ViewBuilder
    func glassCard(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}
