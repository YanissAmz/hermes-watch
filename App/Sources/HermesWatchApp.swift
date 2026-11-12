import SwiftUI

@main
struct HermesWatchApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            SessionsView()
                .environmentObject(model)
                #if DEBUG
                .onAppear { probeWebSocketIfAsked() }
                #endif
        }
    }
}

#if DEBUG
/// Diagnostic, debug builds only: launched with HERMES_WS_PROBE=wss://host/path, the app tries to open that WebSocket
/// and prints one line with what watchOS did. Run it in the simulator and on a real watch to see the difference
/// described in docs/PROPOSAL.md:  xcrun devicectl device process launch --console --environment-variables '{"HERMES_WS_PROBE":"wss://..."}' ...
private var webSocketProbe: URLSessionWebSocketTask?
func probeWebSocketIfAsked() {
    guard webSocketProbe == nil, let raw = ProcessInfo.processInfo.environment["HERMES_WS_PROBE"], let url = URL(string: raw) else { return }
    let task = URLSession.shared.webSocketTask(with: url)
    webSocketProbe = task
    let start = Date()
    var answered = false
    func elapsed() -> String { String(format: "%.1f", Date().timeIntervalSince(start)) }
    task.resume()
    task.sendPing { error in
        DispatchQueue.main.async {
            answered = true
            if let error = error as NSError? {
                print("WS_PROBE failed after \(elapsed())s: \(error.domain) \(error.code) \(error.localizedDescription)")
            } else {
                print("WS_PROBE ok after \(elapsed())s: the WebSocket opened and answered a ping")
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
        if !answered { print("WS_PROBE no answer after \(elapsed())s: task state \(task.state.rawValue), error \(String(describing: task.error))") }
    }
}
#endif
