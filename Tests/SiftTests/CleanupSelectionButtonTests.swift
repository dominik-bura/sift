import AppKit
import SwiftUI
import XCTest
@testable import Sift

final class CleanupSelectionButtonTests: XCTestCase {
    @MainActor func testSingleLineButtonFitsFooterInBothCleanupModes() {
        for immediate in [false, true] {
            let button = CleanupSelectionButton(bytes: 3_100_000_000, deletesImmediately: immediate) {
                XCTFail("Rendering must not trigger cleanup confirmation")
            }
            let host = NSHostingView(rootView: button)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThan(host.fittingSize.width, 240)
            XCTAssertGreaterThan(host.fittingSize.height, 24)
            XCTAssertLessThanOrEqual(host.fittingSize.height, 44)
            XCTAssertEqual(button.actionTitle, immediate ? "Delete" : "Move to Trash")
            XCTAssertTrue(button.accessibilityText.contains(immediate ? "permanent deletion" : "moving to Trash"))
            XCTAssertTrue(button.accessibilityText.contains("selected generated folders"))
        }
    }
}
