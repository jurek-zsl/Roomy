import SwiftUI

/// A close button above a side panel; Esc closes it too.
struct ClosablePanel: ViewModifier {
    let close: () -> Void

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help("Close (Esc)")
                .accessibilityLabel("Close panel")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            content
        }
    }
}

extension View {
    func closablePanel(_ close: @escaping () -> Void) -> some View {
        modifier(ClosablePanel(close: close))
    }
}
