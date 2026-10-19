import AppKit
import SwiftUI

/// Uses native equal-width segments instead of merely expanding a Picker's wrapper.
struct FullWidthSegmentedControl: NSViewRepresentable {
    let labels: [String]
    @Binding var selection: Int

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: labels,
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectSegment(_:))
        )
        control.segmentDistribution = .fillEqually
        control.controlSize = .large
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel("Sift section")
        control.selectedSegment = selection
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = selection
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject {
        var selection: Binding<Int>
        init(selection: Binding<Int>) { self.selection = selection }

        @objc func selectSegment(_ sender: NSSegmentedControl) {
            guard sender.selectedSegment >= 0 else { return }
            selection.wrappedValue = sender.selectedSegment
        }
    }
}
