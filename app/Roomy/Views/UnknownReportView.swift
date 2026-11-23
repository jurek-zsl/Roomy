import AppKit
import SwiftUI

/// "Tell Roomy about these": the big folders Roomy can't explain, as a
/// report the person checks, then sends as a GitHub issue or copies.
struct UnknownReportView: View {
    let folders: [MapNode]
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var note = ""
    @State private var copied = false

    private var chosen: [MapNode] { folders.filter { picked.contains($0.id) } }
    private var body_: String {
        UnknownReport.body(chosen, home: NSHomeDirectory(), note: note,
                           version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                           macOS: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tell Roomy about these folders").font(.title2.bold())
            Text("Roomy doesn't know what these big folders are yet. Send the list, and a later update of Roomy will explain them, for you and everyone else. Only what you see below is sent; untick anything private.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(folders) { f in
                Toggle(isOn: Binding(get: { picked.contains(f.id) },
                                     set: { if $0 { picked.insert(f.id) } else { picked.remove(f.id) } })) {
                    HStack {
                        Text(tildePath(f.path)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(formatBytes(f.bytes)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .frame(minHeight: 140)
            TextField("What made them, if you know (\"I edit video in DaVinci Resolve\")", text: $note, axis: .vertical)
                .lineLimit(2...4)
            DisclosureGroup("What will be sent") {
                ScrollView {
                    Text(body_).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
            }
            Text("Sending opens GitHub with the report filled in; you need a free GitHub account and press Submit there. Or copy it and send it any way you like.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(copied ? "Copied" : "Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(body_, forType: .string)
                    copied = true
                }
                .disabled(chosen.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Send on GitHub") {
                    if let url = UnknownReport.url(body: body_) { NSWorkspace.shared.open(url) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 560, height: 560)
        .onAppear { picked = Set(folders.map(\.id)) }
    }
}
