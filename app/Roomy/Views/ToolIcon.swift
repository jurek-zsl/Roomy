import AppKit
import SwiftUI

/// A tool's app icon (see ToolIcons), or a plain badge.
struct ToolIcon: View {
    let tool: CLIAdvisor.Tool?
    var size: CGFloat = 32

    var body: some View {
        if let tool, let image = ToolIcons.icon(for: tool) {
            // App icons have a margin built in; let them fill the same box.
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size * 1.2, height: size * 1.2)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
        }
    }

    private var color: Color {
        switch tool {
        case .claude?: .orange
        case .codex?: .gray
        case .gemini?: .blue
        case nil: .purple
        }
    }
}
