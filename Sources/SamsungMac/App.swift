import SwiftUI

@main
struct SamsungMacApp: App {
    @State private var tv = TVSystem()

    init() {
        ScreenshotRenderer.runIfRequested()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(tv)
        } label: {
            Image(systemName: "tv")
        }
        .menuBarExtraStyle(.window)
    }
}
