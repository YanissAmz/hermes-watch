import SwiftUI

@main
struct HermesWatchApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            SessionsView()
                .environmentObject(model)
        }
    }
}
