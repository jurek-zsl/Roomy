import AppKit
import SwiftUI

/// Where the disk space goes, folder by folder. Green is what Roomy can
/// free; "Not explained" marks big folders no rule covers yet.
struct SpaceMapView: View {
    @Environment(CleanerStore.self) private var store
    /// The folders opened, from a root down.
    @State private var trail: [MapNode] = []
    /// The folder shown in the side panel.
    @State private var inspected: MapNode?

    var body: some View {
        Group {
            if let map = store.diskMap {
                VStack(spacing: 0) {
                    MapHeader(map: map)
                    Divider()
                    MapBrowser(map: map, trail: $trail, inspected: $inspected)
                }
                .inspector(isPresented: Binding(get: { inspected != nil }, set: { if !$0 { inspected = nil } })) {
                    if let node = inspected {
                        FolderInsightView(node: node)
                            .closablePanel { inspected = nil }
                            .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
                    }
                }
            } else if case .failed(let message) = store.mapState {
                ContentUnavailableView {
                    Label("Couldn't map the disk", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await store.loadMap() } }
                }
            } else if store.mapState == .loading {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Adding up every folder…").font(.title3)
                    Text("Your home folder, Applications and Homebrew. Usually under a minute.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("See where your space goes", systemImage: "chart.bar.doc.horizontal")
                } description: {
                    Text("Roomy adds up every folder in your home, Applications and Homebrew, and shows how much of each it can free. Big folders no rule explains stand out. Nothing is changed.")
                } actions: {
                    Button("Map My Disk") { Task { await store.loadMap() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
        .onChange(of: store.diskMap) {
            trail = []
            inspected = nil
        }
    }
}

/// A short name for each place the map starts from.
func rootTitle(_ path: String) -> String {
    let parts = path.split(separator: "/")
    if path == NSHomeDirectory() || (parts.count == 2 && parts[0] == "Users") { return "Home" }
    return switch path {
    case "/Applications": "Applications"
    case "/opt/homebrew", "/usr/local": "Homebrew & tools (\(path))"
    case "/Library": "Library (for all users)"
    case "/Users": "Users"
    case "/opt": "Homebrew & tools (/opt)"
    case "/System": "macOS downloads (/System)"
    case "/private": "System data (/private)"
    case "/usr": "Command line tools (/usr)"
    default: path == "/" ? path : (path as NSString).lastPathComponent
    }
}

private let rootColors: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo]

private struct MapHeader: View {
    @Environment(CleanerStore.self) private var store
    let map: DiskMap

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Space used")
                        .foregroundStyle(.secondary)
                    Text(formatBytes(map.usedBytes ?? map.mappedBytes))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                    Text("Roomy can free \(formatBytes(map.cleanableBytes)) of it. Orange tags mark big folders no rule covers yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if store.mapState == .loading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Mapping…").foregroundStyle(.secondary)
                        }
                    } else if store.mapIsStale {
                        Label("Out of date after the last clean", systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    } else if let date = store.mapDate {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text("Mapped \(formatAgo(date, now: context.date))").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            SpaceBar(map: map)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }
}

/// Each place the map covers, then macOS and system data, then free space.
private struct SpaceBar: View {
    let map: DiskMap

    private struct Part: Identifiable {
        let id: String
        let label: String
        let bytes: Int64
        let color: Color
    }

    private var parts: [Part] {
        var p = map.places.prefix(7).enumerated().map { i, r in
            Part(id: r.path, label: rootTitle(r.path), bytes: r.bytes, color: rootColors[i % rootColors.count])
        }
        if let sys = map.systemBytes, sys > 0 {
            p.append(Part(id: "system", label: "macOS & system data", bytes: sys, color: .gray))
        }
        if let free = map.freeBytes {
            p.append(Part(id: "free", label: "Free", bytes: free, color: Color.primary.opacity(0.08)))
        }
        return p
    }

    var body: some View {
        let parts = parts
        let total = max(Double(map.totalBytes ?? parts.reduce(0) { $0 + $1.bytes }), 1)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(parts) { part in
                        Rectangle()
                            .fill(part.color.gradient)
                            .frame(width: max(2, geo.size.width * Double(part.bytes) / total))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(height: 12)
            .accessibilityElement()
            .accessibilityLabel(parts.map { "\($0.label) \(formatBytes($0.bytes))" }.joined(separator: ", "))
            FlowLegend(items: parts.map { ($0.color, $0.label, $0.bytes) })
        }
    }
}

private struct FlowLegend: View {
    let items: [(Color, String, Int64)]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { entries }
            VStack(alignment: .leading, spacing: 4) { entries }
        }
        .font(.caption)
    }

    @ViewBuilder private var entries: some View {
        ForEach(items.indices, id: \.self) { i in
            HStack(spacing: 5) {
                Circle().fill(items[i].0).frame(width: 8, height: 8)
                Text(items[i].1).foregroundStyle(.secondary).lineLimit(1)
                Text(formatBytes(items[i].2)).monospacedDigit()
            }
        }
    }
}

private struct MapBrowser: View {
    let map: DiskMap
    @Binding var trail: [MapNode]
    @Binding var inspected: MapNode?
    @State private var showSystem = false

    private var unexplained: Set<String> { Set(map.unexplained(limit: 50).map(\.id)) }

    var body: some View {
        let rows = trail.last?.children ?? map.places
        let biggest = max(rows.map(\.bytes).max() ?? 1, 1)
        let flagged = unexplained
        List {
            if trail.isEmpty {
                let worth = map.unexplained()
                if !worth.isEmpty {
                    SwiftUI.Section {
                        ForEach(worth) { node in
                            Button { inspected = node } label: {
                                WorthRow(node: node, selected: inspected?.id == node.id)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { finder(node) }
                        }
                    } header: {
                        sectionHeader("Worth a look", "Big folders no rule explains. Click one to see what it is.")
                    }
                }
                SwiftUI.Section {
                    rowsView(rows, biggest: biggest, flagged: flagged)
                    if let sys = map.systemBytes, sys > 0 {
                        Button { showSystem = true } label: { SystemRow(bytes: sys, biggest: biggest) }
                            .buttonStyle(.plain)
                            .sheet(isPresented: $showSystem) { SystemDataView(bytes: sys) }
                    }
                } header: {
                    sectionHeader("Everything", "Click a folder to look inside.")
                }
            } else {
                SwiftUI.Section {
                    rowsView(rows, biggest: biggest, flagged: flagged)
                } header: {
                    Breadcrumb(trail: $trail)
                }
            }
        }
        .listStyle(.inset)
        .animation(.snappy(duration: 0.2), value: trail)
    }

    @ViewBuilder private func rowsView(_ rows: [MapNode], biggest: Int64, flagged: Set<String>) -> some View {
        ForEach(rows) { node in
            Button { if node.canOpen { trail.append(node) } } label: {
                MapRow(node: node, title: trail.isEmpty ? rootTitle(node.path) : node.name,
                       fraction: Double(node.bytes) / Double(biggest), flagged: flagged.contains(node.id),
                       explain: node.kind == .folder && !trail.isEmpty ? { inspected = node } : nil)
            }
            .buttonStyle(.plain)
            .contextMenu {
                if node.kind == .folder {
                    Button("What Is This?") { inspected = node }
                }
                finder(node)
            }
        }
    }

    @ViewBuilder private func finder(_ node: MapNode) -> some View {
        if trail.isEmpty, map.unexplained().contains(node) {
            Button("Show Where It Is") { open(node) }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }
    }

    private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).foregroundStyle(.primary)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .textCase(nil)
    }

    /// Open the map at this folder, with every folder above it in the trail.
    private func open(_ target: MapNode) {
        func path(in nodes: [MapNode]) -> [MapNode]? {
            for n in nodes {
                if n.id == target.id { return [n] }
                if target.path.hasPrefix(n.path + "/"), let rest = path(in: n.children) { return [n] + rest }
            }
            return nil
        }
        guard let chain = path(in: map.places) else { return }
        trail = target.canOpen ? chain : Array(chain.dropLast())
    }
}

private struct Breadcrumb: View {
    @Binding var trail: [MapNode]

    var body: some View {
        HStack(spacing: 4) {
            Button {
                trail.removeLast()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .help("Back (⌘←)")
            Button("All") { trail = [] }
                .buttonStyle(.borderless)
            ForEach(Array(trail.enumerated()), id: \.offset) { i, node in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                Button(i == 0 ? rootTitle(node.path) : node.name) { trail = Array(trail.prefix(i + 1)) }
                    .buttonStyle(.borderless)
                    .fontWeight(i == trail.count - 1 ? .semibold : .regular)
                    .lineLimit(1)
            }
            Spacer()
            if let last = trail.last {
                Text(formatBytes(last.bytes)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .textCase(nil)
        .padding(.vertical, 4)
    }
}

private struct MapIcon: View {
    let node: MapNode

    var body: some View {
        if node.kind == .bundle || node.name.hasSuffix("library") {
            Image(nsImage: NSWorkspace.shared.icon(forFile: node.path))
                .resizable()
                .frame(width: 26, height: 26)
        } else {
            let (symbol, tint): (String, Color) = switch node.kind {
            case .personal: ("person.crop.square.fill", .gray)
            case .files: ("doc.on.doc.fill", .gray)
            case .other: ("ellipsis.circle.fill", .gray)
            case .unreadable: ("lock.fill", .gray)
            case .folder, .bundle: ("folder.fill", .blue)
            }
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(tint.gradient.opacity(node.kind == .folder ? 1 : 0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

private struct MapRow: View {
    let node: MapNode
    let title: String
    let fraction: Double
    let flagged: Bool
    /// Shows a "What is this?" button.
    var explain: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            MapIcon(node: node)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if let known = node.known, !known.isGeneral, known.name != title {
                        Text(known.name).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(known.what)
                    }
                    tag
                }
                SizeBar(fraction: fraction, cleanable: node.bytes > 0 ? Double(node.cleanable) / Double(node.bytes) : 0)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatBytes(node.bytes)).fontWeight(.semibold).monospacedDigit()
                if node.cleanable > 0 {
                    Text("can free \(formatBytes(node.cleanable))")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .monospacedDigit()
                }
            }
            .frame(minWidth: 96, alignment: .trailing)
            if let explain {
                Button(action: explain) {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.borderless)
                .help("What is this folder?")
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(node.canOpen ? 1 : 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var tag: some View {
        switch node.kind {
        case .personal: Chip(text: "Your files", color: .secondary)
        case .unreadable: Chip(text: "No access", color: .secondary)
        case .folder where flagged && node.known == nil: Chip(text: "Not explained", color: .orange)
        default: EmptyView()
        }
    }
}

private struct WorthRow: View {
    let node: MapNode
    var selected = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "questionmark.folder.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(node.name).fontWeight(.medium)
                Text(friendlyPath(node.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(formatBytes(node.bytes)).fontWeight(.semibold).monospacedDigit()
            Label("What is this?", systemImage: "sparkles")
                .font(.caption.weight(.medium))
                .foregroundStyle(selected ? Color.white : Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(selected ? Color.accentColor : Color.accentColor.opacity(0.12), in: Capsule())
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private struct SystemRow: View {
    let bytes: Int64
    let biggest: Int64

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "applelogo")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.gray.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text("macOS & system data").fontWeight(.medium)
                Text("macOS itself, swap, Time Machine snapshots and what other users store. Click to see what's in it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(formatBytes(bytes)).fontWeight(.semibold).monospacedDigit()
                .frame(minWidth: 96, alignment: .trailing)
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// How big a folder is next to its siblings, with the part Roomy can free in green.
private struct SizeBar: View {
    let fraction: Double
    let cleanable: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width * min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule().fill(Color.accentColor.opacity(0.55)).frame(width: max(w, 3))
                Capsule().fill(Color.green).frame(width: cleanable > 0 ? max(w * min(cleanable, 1), 3) : 0)
            }
        }
        .frame(height: 5)
    }
}
