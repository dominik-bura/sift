import SwiftUI

@main
struct SiftApp: App {
    @StateObject private var model = AppModel()

    init() {
        SiftAssets.registerNamedImages()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            Image(nsImage: SiftAssets.menuBarIcon)
                .accessibilityLabel(applicationName)
        }
        .menuBarExtraStyle(.window)
    }

    private var applicationName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Sift"
    }
}
