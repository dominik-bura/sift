import AppKit
import SwiftUI

enum SelectionState { case off, mixed, on }

/// A real checkbox owns the full hit target, keyboard handling, and mixed-state
/// accessibility. Transparent SwiftUI artwork must not define its click region.
struct SelectionCheckbox: NSViewRepresentable {
    let state: SelectionState
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = FirstClickCheckbox(checkboxWithTitle: "", target: context.coordinator,
                                        action: #selector(Coordinator.clicked(_:)))
        button.allowsMixedState = true
        button.controlSize = .regular
        button.imagePosition = .imageOnly
        button.contentTintColor = NSColor(SiftChartStyle.accent)
        button.setAccessibilityLabel("Select generated folders")
        update(button, context: context)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { update(button, context: context) }

    private func update(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.state = state == .off ? .off : state == .mixed ? .mixed : .on
        button.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        CGSize(width: 30, height: 30)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func clicked(_ sender: NSButton) { action() }
    }
}

private final class FirstClickCheckbox: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
