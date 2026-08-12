import SwiftUI

@main
struct SiftApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Sift", image: "SiftMenuBarIconTemplate") {
            ContentView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
