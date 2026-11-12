import HermesCore
import SwiftUI

/// A question from the dashboard, shown in the chat until it is answered here or elsewhere, or times out.
struct RequestCard: View {
    @EnvironmentObject private var model: AppModel
    let request: OpenRequest
    let session: SessionRow
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch request.kind {
            case .approval: approval
            case .clarify: clarify
            }
        }
        .padding(6)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var approval: some View {
        Label("Approval needed", systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.yellow)
        if !request.description.isEmpty {
            Text(request.description).font(.caption2)
        }
        if !request.command.isEmpty {
            Text(request.command).font(.system(.caption2, design: .monospaced)).lineLimit(6)
                .padding(4).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        }
        ForEach(request.choices, id: \.self) { choice in
            Button(role: choice == "deny" ? .destructive : nil) { send(choice) } label: {
                Text(Self.label(choice)).font(.footnote).frame(maxWidth: .infinity)
            }
            .tint(choice == "deny" ? .red : .green)
            .accessibilityIdentifier("approval-\(choice)")
        }
    }

    @ViewBuilder private var clarify: some View {
        Label("Hermes is asking", systemImage: "questionmark.bubble").font(.caption).foregroundStyle(.yellow)
        Text(request.question).font(.footnote)
        if request.multiSelect {
            Text("Several answers are possible: answer in the phone or desktop app.").font(.caption2).foregroundStyle(.secondary)
        } else {
            ForEach(request.choices, id: \.self) { choice in
                Button { send(choice) } label: { Text(choice).font(.footnote).frame(maxWidth: .infinity) }
            }
            TextField("Answer", text: $typed)
                .onSubmit { let t = typed.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { send(t) } }
                .submitLabel(.send)
                .accessibilityIdentifier("clarify-answer")
        }
    }

    private func send(_ text: String) {
        Task { await model.answer(request, with: text, in: session) }
    }

    static func label(_ choice: String) -> LocalizedStringKey {
        switch choice {
        case "once": return "Allow once"
        case "session": return "Allow for this conversation"
        default: return "Deny"
        }
    }
}
