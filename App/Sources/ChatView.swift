import HermesCore
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var model: AppModel
    let session: SessionRow
    @State private var input = ""
    @State private var showModels = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if model.loadingChat { ProgressView().frame(maxWidth: .infinity) }
                    if !model.choices.model.isEmpty {
                        Text(model.choices.model).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                    ForEach(model.chat.messages) { Bubble(message: $0).id($0.id) }
                    if !model.chat.draft.isEmpty {
                        Bubble(message: ChatMessage(id: "draft", role: .assistant, text: model.chat.draft)).id("draft")
                    }
                    if model.chat.streaming {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(model.chat.status ?? (model.chat.thinking ? L("Thinking…") : L("Writing…")))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button { Task { await model.stop(session) } } label: { Image(systemName: "stop.fill") }
                                .buttonStyle(.plain).foregroundStyle(.red).accessibilityLabel("Stop")
                        }
                    }
                    if let error = model.chatError {
                        Text(error).font(.caption2).foregroundStyle(.orange)
                    }
                    TextField("Message", text: $input)
                        .onSubmit(sendInput)
                        .submitLabel(.send)
                        .accessibilityIdentifier("message-field")
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 2)
            }
            // A reply is read from its first line: show its top and let the crown do the rest, instead of chasing the last word.
            .onChange(of: model.chat.messages.last?.id) { _, _ in
                if let last = model.chat.messages.last, last.role == .assistant { scroll(proxy, to: last.id, anchor: .top) } else { scroll(proxy) }
            }
            .onChange(of: model.chat.draft.isEmpty) { _, empty in if !empty { scroll(proxy, to: "draft", anchor: .top) } }
            .onChange(of: model.loadingChat) { _, _ in scroll(proxy) }
        }
        .navigationTitle(session.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showModels = true } label: { Image(systemName: "cpu") }
                    .accessibilityLabel("Model")
            }
        }
        .sheet(isPresented: $showModels) { ModelPickerView(session: session) }
        .task(id: session.id) { await model.follow(session) }
        #if DEBUG
        .task {
            if let delay = ProcessInfo.processInfo.environment["HERMES_DEMO_MODELS_AFTER"].flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(delay))
                showModels = true
            }
        }
        #endif
    }

    private func sendInput() {
        let text = input
        input = ""
        Task { await model.send(text, in: session) }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: String = "bottom", anchor: UnitPoint = .bottom) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: anchor) }
    }
}

private struct Bubble: View {
    let message: ChatMessage

    var body: some View {
        let mine = message.role == .user
        Text(rendered)
            .font(.footnote)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(mine ? Color.blue.opacity(0.55) : Color.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            .padding(mine ? .leading : .trailing, 14)
            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    /// Inline Markdown (bold, code, links) where it parses; the raw text otherwise.
    private var rendered: AttributedString {
        (try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(message.text)
    }
}
