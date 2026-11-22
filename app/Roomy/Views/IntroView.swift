import AppKit
import SwiftUI

/// Shown once, before the first scan.
struct IntroView: View {
    @Environment(CleanerStore.self) private var store

    var body: some View {
        VStack(spacing: 26) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 8) {
                Text("Make room on your Mac")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Roomy finds the space apps and tools leave behind, and tells you the truth about it.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 16) {
                point("magnifyingglass", .blue, "Finds what others miss",
                      "Package caches, build folders, app web caches, old versions and leftovers, each one explained.")
                point("ruler", .green, "Honest sizes",
                      "Only space you really get back. Space shared with copies elsewhere isn't counted.")
                point("hand.raised.fill", .orange, "You decide",
                      "Nothing is removed until you tick it and confirm. Anything in use is left alone.")
                point("lock.shield.fill", .gray, "macOS will ask for access",
                      "To Documents, Desktop and Downloads, where project build folders live. Say no and Roomy skips them.")
            }
            .frame(maxWidth: 480)
            Button {
                store.hasSeenIntro = true
                Task { await store.scan() }
            } label: {
                Text("Scan My Mac").frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func point(_ symbol: String, _ tint: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
