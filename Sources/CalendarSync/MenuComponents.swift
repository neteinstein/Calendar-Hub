import AppKit
import CalendarSyncCore
import SwiftUI

/// A borderless icon button that shows its tint and a soft background on hover, with a tooltip
/// naming what it does (and its shortcut).
struct IconButton: View {
    let symbol: String
    let help: String
    var shortcut: KeyEquivalent?
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, help: String, shortcut: KeyEquivalent? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 24)
                .foregroundStyle(hovering ? .primary : .secondary)
                .background(hovering ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(PressableStyle())
        .keyboardShortcut(shortcut.map { KeyboardShortcut($0) })
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Shrinks a little while pressed.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// A small accent-tinted capsule, for "Today" and similar quiet actions.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.24 : 0.14), in: Capsule())
            .contentShape(Capsule())
    }
}

/// Opens a meeting's call: a filled accent capsule, larger in the Up next card.
struct JoinButton: View {
    let url: URL
    var large = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Label("Join", systemImage: "video.fill")
                .font(.system(size: large ? 13 : 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, large ? 13 : 9)
                .padding(.vertical, large ? 6 : 3.5)
                .background(Color.accentColor, in: Capsule())
                .shadow(color: Color.accentColor.opacity(0.4), radius: 4, y: 2)
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help(MeetingLink.serviceName(of: url).map { "Join on \($0)" } ?? "Join the call")
    }
}

/// Picks one of a few views, with a highlight that slides to the picked one.
struct SlidingSegments<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    @Namespace private var highlight
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.3)) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(colorScheme == .dark ? Color.white.opacity(0.16) : .white)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                                    .matchedGeometryEffect(id: "highlight", in: highlight)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(2)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Arrows that spin while something runs.
struct Spinner: View {
    var symbol = "arrow.triangle.2.circlepath"
    @State private var spinning = false

    var body: some View {
        Image(systemName: symbol)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
