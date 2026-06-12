import SwiftUI
import UIKit

// ── Composer mode ──────────────────────────────────────────────────────────────
enum ComposerMode {
    case text
    case voice(transcript: String, duration: Int)  // duration in seconds
}

// ── Main view ──────────────────────────────────────────────────────────────────
struct NoteComposerView: View {
    let mode: ComposerMode
    let onDismiss: () -> Void

    @State private var title = ""
    @State private var body = ""
    @State private var selectedTags: [String] = []
    @State private var tagInput = ""
    @State private var showTagSuggestions = false
    @State private var isEditorFocused = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var editorCoordinator: MarkdownEditorCoordinator? = nil

    @ObservedObject private var tagStore = TagStore.shared

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
            DS.parchmentMid.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 56)

                // Voice badge
                if isVoice {
                    voiceBadge
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Title
                TextField("Title (optional)", text: $title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(DS.inkDark)
                    .padding(.horizontal, 20)
                    .padding(.top, isVoice ? 12 : 20)
                    .padding(.bottom, 12)

                Divider()
                    .padding(.horizontal, 20)

                // Markdown body editor
                MarkdownEditorView(
                    text: $body,
                    isFocused: $isEditorFocused,
                    onCoordinator: { editorCoordinator = $0 }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Tags section
                tagSection

                // Formatting toolbar — shown when editor is focused
                if isEditorFocused {
                    FormattingToolbar(coordinator: editorCoordinator)
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .onAppear {
            if case .voice(let transcript, _) = mode {
                body = transcript
            }
            Task { await tagStore.fetchIfNeeded() }
        }
        .animation(.easeOut(duration: 0.2), value: isEditorFocused)
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
            .disabled(isSending || body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            // Selected tag chips + input
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Image(systemName: "tag")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.inkFaint)

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
                        .padding(.vertical, 4)
                        .background(DS.terracotta.opacity(0.08), in: Capsule())
                        .overlay(Capsule().strokeBorder(DS.terracotta.opacity(0.22), lineWidth: 1))
                    }

                    // Tag input field
                    TextField("Add tag…", text: $tagInput)
                        .font(.system(size: 14))
                        .foregroundStyle(DS.inkDark)
                        .frame(minWidth: 80)
                        .onSubmit { commitTagInput() }
                        .onChange(of: tagInput) { _, v in
                            showTagSuggestions = !v.isEmpty
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            // Autocomplete suggestions
            if showTagSuggestions {
                let suggestions = tagStore.suggestions(for: tagInput, excluding: selectedTags)
                if !suggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(suggestions, id: \.self) { tag in
                                Button {
                                    selectedTags.append(tag)
                                    tagInput = ""
                                    showTagSuggestions = false
                                } label: {
                                    Text("#\(tag)")
                                        .font(.system(size: 13))
                                        .foregroundStyle(DS.inkMid)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(DS.parchmentCard, in: Capsule())
                                        .overlay(Capsule().strokeBorder(DS.inkDark.opacity(0.1), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    }
                    .transition(.opacity)
                }
            }
        }
        .background(DS.parchmentMid)
    }

    // ── Actions ───────────────────────────────────────────────────────────────
    private func commitTagInput() {
        let t = tagInput.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !t.isEmpty, !selectedTags.contains(t) else { tagInput = ""; return }
        selectedTags.append(t)
        tagInput = ""
        showTagSuggestions = false
    }

    @MainActor
    private func send() async {
        commitTagInput()
        let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
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

// ── UITextView-backed markdown editor ─────────────────────────────────────────
final class MarkdownEditorCoordinator: NSObject, UITextViewDelegate {
    weak var textView: UITextView?

    /// Wrap current selection (or insert at cursor) with prefix/suffix markdown markers.
    func apply(prefix: String, suffix: String) {
        guard let tv = textView else { return }
        let ns = tv.text as NSString
        let range = tv.selectedRange

        if range.length > 0 {
            let selected = ns.substring(with: range)
            let replacement = prefix + selected + suffix
            if let tr = tv.selectedTextRange {
                tv.replace(tr, withText: replacement)
            }
        } else {
            tv.insertText(prefix + suffix)
            // Move cursor between the markers
            if let start = tv.selectedTextRange?.start,
               let pos = tv.position(from: start, offset: -suffix.count) {
                tv.selectedTextRange = tv.textRange(from: pos, to: pos)
            }
        }
    }

    // MARK: UITextViewDelegate
    var onTextChange: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    func textViewDidChange(_ textView: UITextView) { onTextChange?(textView.text) }
    func textViewDidBeginEditing(_ textView: UITextView) { onFocusChange?(true) }
    func textViewDidEndEditing(_ textView: UITextView) { onFocusChange?(false) }
}

struct MarkdownEditorView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var onCoordinator: (MarkdownEditorCoordinator) -> Void

    func makeCoordinator() -> MarkdownEditorCoordinator {
        MarkdownEditorCoordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.font = UIFont.systemFont(ofSize: 17)
        tv.textColor = UIColor(DS.inkDark)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 40, right: 16)
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        // Remove predictive text bar — we have our own toolbar
        tv.inputAssistantItem.leadingBarButtonGroups = []
        tv.inputAssistantItem.trailingBarButtonGroups = []

        context.coordinator.onTextChange = { [weak tv] str in
            if tv?.text != str { tv?.text = str }
        }
        context.coordinator.onFocusChange = { focused in
            DispatchQueue.main.async { isFocused = focused }
        }
        DispatchQueue.main.async { onCoordinator(context.coordinator) }
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
        context.coordinator.onTextChange = { str in text = str }
    }
}

// ── Formatting toolbar ────────────────────────────────────────────────────────
struct FormattingToolbar: View {
    let coordinator: MarkdownEditorCoordinator?

    private struct Format: Identifiable {
        let id: String
        let icon: String
        let prefix: String
        let suffix: String
        var label: String? = nil
    }

    private let formats: [Format] = [
        Format(id: "bold",          icon: "bold",                              prefix: "**",  suffix: "**"),
        Format(id: "italic",        icon: "italic",                            prefix: "*",   suffix: "*"),
        Format(id: "underline",     icon: "underline",                         prefix: "<u>", suffix: "</u>"),
        Format(id: "strike",        icon: "strikethrough",                     prefix: "~~",  suffix: "~~"),
        Format(id: "highlight",     icon: "highlighter",                       prefix: "==",  suffix: "=="),
        Format(id: "code",          icon: "chevron.left.forwardslash.chevron.right", prefix: "`", suffix: "`"),
        Format(id: "math",          icon: "x.squareroot",                      prefix: "$",   suffix: "$"),
        Format(id: "comment",       icon: "bubble.left",                       prefix: "%%",  suffix: "%%"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(formats) { fmt in
                        Button {
                            coordinator?.apply(prefix: fmt.prefix, suffix: fmt.suffix)
                        } label: {
                            Image(systemName: fmt.icon)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(DS.inkMid)
                                .frame(width: 42, height: 42)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if fmt.id != formats.last?.id {
                            Divider()
                                .frame(height: 20)
                                .padding(.horizontal, 2)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(height: 48)
        .background(DS.parchmentCard)
        .overlay(alignment: .top) { Divider() }
    }
}
