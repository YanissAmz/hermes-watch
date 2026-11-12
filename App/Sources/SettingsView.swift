import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var result = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Hermes bridge") {
                    TextField("Address", text: model.$bridgeURL)
                        .textContentType(.URL)
                    TextField("Token", text: model.$bridgeToken)
                }
                Section {
                    Button("Test connection") {
                        result = "…"
                        Task { result = await model.testConnection() }
                    }
                    if !result.isEmpty { Text(result).font(.footnote) }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
