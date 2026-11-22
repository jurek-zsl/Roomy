import AppKit
import SwiftUI
import Testing

/// Roomy's icon: three storage shelves, the top one mostly empty (room).
struct IconArt: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.38, green: 0.90, blue: 0.70), Color(red: 0.09, green: 0.52, blue: 0.86)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 12)
            VStack(spacing: 44) {
                shelf(0.3)
                shelf(1)
                shelf(1)
            }
            .offset(y: 40)
            Image(systemName: "sparkle")
                .font(.system(size: 150, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: 205, y: -228)
        }
        .frame(width: 1024, height: 1024)
    }

    private func shelf(_ fill: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.3)).frame(width: 520, height: 108)
            Capsule().fill(.white).frame(width: max(108, 520 * fill), height: 108)
        }
    }
}

@MainActor @Test func renderAppIcon() throws {
    let renderer = ImageRenderer(content: IconArt())
    renderer.scale = 1
    let cg = try #require(renderer.cgImage)
    let png = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
    try png.write(to: Snap.dir.appending(path: "icon-1024.png"))
}
