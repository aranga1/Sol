import SwiftUI
// MarkdownTextStorage, MarkdownEditorCoordinator, MarkdownEditorView, FormattingToolbar
// are defined in MarkdownEditor.swift

// ── Composer mode ─────────────────────────────────────────────────────────────
enum ComposerMode {
    case text
    case voice(transcript: String, duration: Int)
}

// ── Main view ─────────────────────────────────────────────────────────────────
struct NoteComposerView: View {
    let mode: ComposerMode
    let onDismiss: () -> Void

    @State private var title = ""
    @State private var noteBody = ""
    @State private var selectedTags: [String] = []
    @State private var tagInput = ""
    @State private var showTagSuggestions = false
    @FocusState private var tagFieldFocused: Bool
    @State private var isEditorFocused = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var editorCoordinator: MarkdownEditorCoordinator? = nil

    private let tagStore = TagStore.shared

    private var isVoice: Bool {
        if case .voice = mode { return true }
        return false
    }
    private var voiceDuration: Int {
        if case .voice(_, let d) = mode { return d }
        return 0
    }

    var body: some View {
        ZStack {
            BreathingBackground()
            DS.parchmentMid.opacity(0.85).ignoresSafeArea()

            VStack(spacing: 0) {
                header.padding(.top, 56)

                if isVoice {
                    voiceBadge
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                TextField("Title (optional)", text: $title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DS.inkDark)
                    .padding(.horizontal, 20)
                    .padding(.top, isVoice ? 12 : 20)
                    .padding(.bottom, 12)

                Divider().padding(.horizontal, 20)

                MarkdownEditorView(
                    text: $noteBody,
                    isFocused: $isEditorFocused,
                    onCoordinator: { editorCoordinator = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let msg = errorMessage {
                    Text(msg)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 4)
                }

                tagSection

                if isEditorFocused {
                    FormattingToolbar(coordinator: editorCoordinator)
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .onAppear {
            if case .voice(let transcript, _) = mode { noteBody = transcript }
            Task { await tagStore.fetchIfNeeded() }
        }
        .animation(.easeOut(duration: 0.2), value: isEditorFocused)
        .animation(.easeOut(duration: 0.15), value: showTagSuggestions)
    }

    // ── Header ────────────────────────────────────────────────────────────────
    private var header: some View {
        HStack {
            Button("Cancel") { onDismiss() }
                .font(.system(size: 16))
                .foregroundStyle(DS.inkLight)
            Spacer()
            Text(isVoice ? "Voice Note" : "New Note")
                .font(DS.newsreader(19, weight: .medium))
                .foregroundStyle(DS.inkDark)
            Spacer()
            Button {
                Task { await send() }
            } label: {
                if isSending {
                    ProgressView().tint(DS.terracotta)
                } else {
                    Text("Send")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DS.terracotta)
                }
            }
            .disabled(isSending || noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // ── Voice badge ───────────────────────────────────────────────────────────
    private var voiceBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12))
                .foregroundStyle(DS.terracottaDark)
            Text("Transcribed from voice · \(formattedDuration)")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DS.terracottaDark)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(DS.terracotta.opacity(0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(DS.terracotta.opacity(0.18), lineWidth: 1))
    }

    private var formattedDuration: String {
        let m = voiceDuration / 60, s = voiceDuration % 60
        return m > 0 ? "\(m):\(String(format: "%02d", s))" : "0:\(String(format: "%02d", s))"
    }

    // ── Tags section ──────────────────────────────────────────────────────────
    private var tagSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()

            // ── Selected chips row ────────────────────────────────────────────
            HStack(spacing: 0) {
                // Tag button
                Button {
                    showTagSuggestions.toggle()
                    if showTagSuggestions {
                        tagFieldFocused = true
                    } else {
                        tagInput = ""
                        tagFieldFocused = false
                    }
                } label: {
                    Image(systemName: showTagSuggestions ? "tag.fill" : "tag")
                        .font(.system(size: 14))
                        .foregroundStyle(showTagSuggestions ? DS.terracotta : DS.inkFaint)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if selectedTags.isEmpty && !showTagSuggestions {
                    Text("Add tags…")
                        .font(.system(size: 14))
                        .foregroundStyle(DS.inkFaint)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(selectedTags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text("#\(tag)")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(DS.terracottaDark)
                                Button {
                                    selectedTags.removeAll { $0 == tag }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(DS.inkLight)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(DS.terracotta.opacity(0.08), in: Capsule())
                            .overlay(Capsule().strokeBorder(DS.terracotta.opacity(0.22), lineWidth: 1))
                        }
                    }
                    .padding(.trailing, 12)
                }
            }
            .frame(height: 44)

            // ── Search + create panel ─────────────────────────────────────────
            if showTagSuggestions {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()

                    // Search / create input
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundStyle(DS.inkFaint)
                        TextField("Search or create tag…", text: $tagInput)
                            .font(.system(size: 15))
                            .foregroundStyle(DS.inkDark)
                            .focused($tagFieldFocused)
                            .submitLabel(.done)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { commitTagInput() }
                        if !tagInput.isEmpty {
                            Button { tagInput = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(DS.inkFaint)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)

                    Divider()

                    // Results list (max 6 rows so it doesn't eat the screen)
                    let trimmed = tagInput
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                    let suggestions = tagStore.suggestions(for: tagInput, excluding: selectedTags)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            // "Create new tag" row — always first when typed
                            if !trimmed.isEmpty && !suggestions.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
                                tagRow(label: "Create \"\(trimmed)\"", icon: "plus.circle.fill", tinted: true) {
                                    if !selectedTags.contains(trimmed) {
                                        selectedTags.append(trimmed)
                                        Task { await tagStore.createTag(trimmed) }
                                    }
                                    tagInput = ""
                                    showTagSuggestions = false
                                    tagFieldFocused = false
                                }
                                if !suggestions.isEmpty { Divider().padding(.leading, 16) }
                            }

                            // Vault matches
                            ForEach(Array(suggestions.prefix(6).enumerated()), id: \.offset) { idx, tag in
                                tagRow(label: "#\(tag)", icon: "tag", tinted: false) {
                                    selectedTags.append(tag)
                                    tagInput = ""
                                    showTagSuggestions = false
                                    tagFieldFocused = false
                                }
                                if idx < min(suggestions.count, 6) - 1 {
                                    Divider().padding(.leading, 16)
                                }
                            }

                            if trimmed.isEmpty && suggestions.isEmpty {
                                Text("Type a name to create your first tag")
                                    .font(.system(size: 14))
                                    .foregroundStyle(DS.inkFaint)
                                    .padding(16)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                .background(DS.parchmentCard)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .background(DS.parchmentMid)
        .animation(.easeOut(duration: 0.18), value: showTagSuggestions)
    }

    @ViewBuilder
    private func tagRow(label: String, icon: String, tinted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(tinted ? DS.terracotta : DS.inkFaint)
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(tinted ? DS.terracotta : DS.inkDark)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // ── Actions ───────────────────────────────────────────────────────────────
    private func commitTagInput() {
        let t = tagInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !t.isEmpty, !selectedTags.contains(t) else { tagInput = ""; return }
        selectedTags.append(t)
        tagInput = ""
        showTagSuggestions = false
    }

    @MainActor
    private func send() async {
        commitTagInput()
        let content = noteBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        isSending = true
        errorMessage = nil
        do {
            _ = try await APIClient.shared.submitNote(NoteRequest(
                content: content,
                title: title.isEmpty ? nil : title,
                tags: selectedTags.isEmpty ? nil : selectedTags,
                source: isVoice ? .voice : .text
            ))
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSending = false
        }
    }
}

