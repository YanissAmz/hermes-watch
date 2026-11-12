import HermesCore
import SwiftUI

struct ModelPickerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let session: SessionRow
    @State private var busy = false

    /// The provider in use first: on a watch nobody scrolls past four providers to find the current model.
    private var ordered: [ProviderOption] {
        model.choices.providers.sorted { a, b in (a.slug == model.choices.provider ? 0 : 1) < (b.slug == model.choices.provider ? 0 : 1) }
    }

    var body: some View {
        NavigationStack {
            List {
                if model.choices.providers.isEmpty { ProgressView() }
                ForEach(ordered) { provider in
                    Section(provider.name) {
                        ForEach(provider.models, id: \.self) { name in
                            Button {
                                busy = true
                                Task {
                                    await model.pick(model: name, provider: provider, in: session)
                                    busy = false
                                    dismiss()
                                }
                            } label: {
                                HStack {
                                    Text(name).font(.footnote).lineLimit(2)
                                    Spacer()
                                    if model.choices.isCurrent(name, in: provider) { Image(systemName: "checkmark").foregroundStyle(.green) }
                                }
                            }
                            .disabled(busy)
                        }
                    }
                }
            }
            .navigationTitle("Model")
        }
    }
}
