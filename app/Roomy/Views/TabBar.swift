import AppKit
import SwiftUI

/// The main tabs as a native segmented control whose segments share the
/// whole width (SwiftUI's segmented picker sizes each one to its text).
struct TabBar: NSViewRepresentable {
    @Binding var selection: MainTab

    func makeNSView(context: Context) -> NSSegmentedControl {
        let c = NSSegmentedControl(labels: MainTab.allCases.map(\.title), trackingMode: .selectOne,
                                   target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        c.segmentDistribution = .fillEqually
        c.setAccessibilityLabel("View")
        return c
    }

    func updateNSView(_ c: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        c.selectedSegment = MainTab.allCases.firstIndex(of: selection) ?? 0
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    final class Coordinator: NSObject {
        var selection: Binding<MainTab>
        init(selection: Binding<MainTab>) { self.selection = selection }
        @MainActor @objc func changed(_ sender: NSSegmentedControl) {
            selection.wrappedValue = MainTab.allCases[max(0, sender.selectedSegment)]
        }
    }
}
