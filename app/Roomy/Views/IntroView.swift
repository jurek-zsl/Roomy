import AppKit
import SwiftUI

/// First launch: what Roomy does, Full Disk Access, an AI if you want one.
struct IntroView: View {
    @Environment(CleanerStore.self) private var store
    @State private var step: Int

    init(step: Int = 0) {
        _step = State(initialValue: step)
    }

    var body: some View {
        VStack(spacing: 24) {
            Group {
                switch step {
                case 0: welcome
                case 1: access
                default: ai
                }
            }
            .frame(maxWidth: 520)
            .transition(.opacity)
            HStack {
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<3) { i in
                        Circle().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step < 2 {
                    Button("Continue") { withAnimation { step += 1 } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Scan My Mac") {
                        store.hasSeenIntro = true
                        Task { await store.scan() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: 520)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcome: some View {
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
            }
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("lock.shield.fill", .gray, "Let Roomy see the whole disk",
                   "With Full Disk Access, Roomy can map every folder, including other apps' containers, Mail and system data. It only reads; nothing is removed without you.")
            DiskAccessView()
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("You can skip this. Roomy then asks for Documents, Desktop and Downloads as it needs them, and shows other folders as locked.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ai: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("sparkles", .purple, "Add an AI (optional)",
                   "Roomy can ask the AI you already use to explain folders and scan the whole disk. It runs through your own account, and Roomy shows exactly what it sends: names and sizes, never file contents.")
            AISetupView()
                .padding(.horizontal, 16)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("No AI? Roomy works fully without one. You can set it up later in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func header(_ symbol: String, _ tint: Color, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(title).font(.system(size: 26, weight: .bold, design: .rounded))
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
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
