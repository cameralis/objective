import SwiftUI

struct BoardView: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if store.visibleItems.isEmpty {
                emptyRow
            } else {
                ForEach(store.visibleItems) { item in
                    ItemRow(
                        item: item,
                        isNew: store.newIDs.contains(item.id),
                        onToggle: { store.toggle(item.id) },
                        onAnswer: { store.answer(item.id, with: $0) }
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .zIndex(store.newIDs.contains(item.id) ? 2 : (item.isOpen ? 1 : 0))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 340, alignment: .leading)
        .animation(.spring(duration: 0.4), value: store.visibleItems)
        .glassCard()
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

    private var emptyRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
            Text("All clear")
                .font(.system(size: 13))
        }
        .foregroundStyle(.tertiary)
        .padding(.vertical, 6)
    }
}

private struct ItemRow: View {
    let item: ObjectiveItem
    let isNew: Bool
    let onToggle: () -> Void
    let onAnswer: (String) -> Void

    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    private var accent: Color { item.isUrgent ? .red : .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(statusStyle)
                    .contentTransition(.symbolEffect(.replace))
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
                    if !item.isOpen, let answer = item.answer, !answer.isEmpty {
                        Label(answer, systemImage: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            if item.isOpen, let choices = item.choices, !choices.isEmpty {
                HStack(spacing: 6) {
                    ForEach(choices, id: \.self) { choice in
                        Button {
                            onAnswer(choice)
                        } label: {
                            Text(choice)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(accent.opacity(0.18), in: Capsule())
                                .overlay(Capsule().strokeBorder(accent.opacity(0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 25)
            }

            if item.isOpen, item.allowReply ?? false {
                HStack(spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    TextField("Reply…", text: $reply)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($replyFocused)
                        .onSubmit {
                            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            onAnswer(trimmed)
                        }
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
        .geometryGroup()
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

private extension View {
    @ViewBuilder
    func glassCard() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            self.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}
