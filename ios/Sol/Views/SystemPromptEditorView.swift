import SwiftUI

struct SystemPromptEditorView: View {
    let initialText: String
    let defaultText: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var isFocused = false
    @State private var coordinator: MarkdownEditorCoordinator? = nil
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            DS.parchmentMid.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header — back chevron provided by NavigationStack; we add Save on the right
                HStack {
                    Button(action: onCancel) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .medium))
                            Text("Settings")
                                .font(.system(size: 16))
                        }
                        .foregroundStyle(DS.inkLight)
                    }

                    Spacer()

                    Text("System Prompt")
                        .font(DS.newsreader(19, weight: .medium))
                        .foregroundStyle(DS.inkDark)

                    Spacer()

                    Button {
                        isSaving = true
                        onSave(text)
                    } label: {
                        if isSaving {
                            ProgressView().tint(DS.terracotta)
                        } else {
                            Text("Save")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(DS.terracotta)
                        }
                    }
                    .disabled(isSaving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider().padding(.horizontal, 20)

                // Editor
                MarkdownEditorView(
                    text: $text,
                    isFocused: $isFocused,
                    onCoordinator: { coordinator = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Hint
                if !isFocused {
                    VStack(alignment: .leading, spacing: 6) {
                        Divider()
                        Text("Use `{context_str}` for retrieved note excerpts and `{query_str}` for the user's question.")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.inkFaint)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)

                        Button("Reset to default") {
                            text = defaultText
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DS.terracotta)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }
                    .background(DS.parchmentMid)
                    .transition(.opacity)
                }

                // Formatting toolbar when focused
                if isFocused {
                    FormattingToolbar(coordinator: coordinator)
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .onAppear { text = initialText }
        .animation(.easeOut(duration: 0.2), value: isFocused)
    }
}
