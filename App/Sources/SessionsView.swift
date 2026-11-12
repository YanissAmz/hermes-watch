import HermesCore
import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [SessionRow] = []
    @State private var showSettings = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Button {
                    Task { if let row = await model.newSession() { path = [row] } }
                } label: {
                    Label("New conversation", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("new-chat")

                if let error = model.listError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
                if model.loadingSessions {
                    ProgressView()
                }
                ForEach(model.sessions) { row in
                    NavigationLink(value: row) { SessionRowView(row: row) }
                }
            }
            .navigationTitle("Hermes")
            .navigationDestination(for: SessionRow.self) { ChatView(session: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task { await model.refreshSessions() }
            .refreshable { await model.refreshSessions() }
            #if DEBUG
            .onAppear { runDemoIfAsked() }
            #endif
        }
    }
}

#if DEBUG
extension SessionsView {
    /// Simulator runs only: HERMES_DEMO_PROMPT opens a new conversation and sends that text through the normal code path,
    /// so a screenshot can show a real turn without driving the watch keyboard.
    fileprivate func runDemoIfAsked() {
        guard let prompt = ProcessInfo.processInfo.environment["HERMES_DEMO_PROMPT"], path.isEmpty, !Self.demoStarted else { return }
        Self.demoStarted = true
        Task {      // not tied to this screen: it is covered as soon as the conversation opens
            guard let row = await model.newSession() else { return }
            path = [row]
            try? await Task.sleep(for: .seconds(3))
            await model.send(prompt, in: row)
        }
    }
    private static var demoStarted = false
}
#endif

extension SessionRow: Hashable {
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct SessionRowView: View {
    let row: SessionRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if row.running {
                    Circle().fill(.green).frame(width: 6, height: 6).accessibilityLabel("Running")
                }
                Text(row.title).font(.headline).lineLimit(2)
            }
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let d = row.startedAt { parts.append(d.formatted(.relative(presentation: .named))) }
        if !row.model.isEmpty { parts.append(row.model) }
        return parts.joined(separator: " · ")
    }
}
