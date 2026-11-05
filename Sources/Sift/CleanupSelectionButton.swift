import SwiftUI

/// Opens the existing confirmation; this control never performs deletion itself.
struct CleanupSelectionButton: View {
    let bytes: Int64
    let deletesImmediately: Bool
    var disabled = false
    let onReview: () -> Void

    var actionTitle: String { deletesImmediately ? "Delete" : "Move to Trash" }
    var accessibilityText: String {
        "Review \(deletesImmediately ? "permanent deletion" : "moving to Trash") of selected generated folders, \(ByteFormatting.string(bytes)) selected"
    }

    var body: some View {
        styledButton
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
            .disabled(disabled)
            .help(accessibilityText)
            .accessibilityLabel(accessibilityText)
    }

    private var button: some View {
        Button(action: onReview) {
            HStack(spacing: 7) {
                Image(systemName: "trash").accessibilityHidden(true)
                Text(actionTitle)
                Text("·").opacity(0.65)
                Text(ByteFormatting.string(bytes)).monospacedDigit()
            }
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5)
            .frame(minHeight: 24)
            .contentShape(Capsule())
        }
    }

    @ViewBuilder private var styledButton: some View {
        if #available(macOS 26, *) {
            button.buttonStyle(.glassProminent).tint(SiftChartStyle.accent)
        } else {
            button.buttonStyle(.borderedProminent).tint(SiftChartStyle.accent)
        }
    }
}
