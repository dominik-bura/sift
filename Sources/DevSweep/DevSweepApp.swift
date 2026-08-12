import SwiftUI

@main
struct DevSweepApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("DevSweep", systemImage: "sparkles") {
            ContentView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
