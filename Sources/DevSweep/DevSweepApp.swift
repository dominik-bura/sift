import SwiftUI

@main
struct DevSweepApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("DevSweep", systemImage: "paintbrush.fill") {
            ContentView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
