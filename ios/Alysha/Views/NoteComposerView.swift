import SwiftUI
import UIKit

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
            DS.parchmentMid.ignoresSafeArea()

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

            // Chips + input row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Tap tag icon to toggle suggestion dropdown
                    Button {
                        showTagSuggestions.toggle()
                    } label: {
                        Image(systemName: showTagSuggestions ? "tag.fill" : "tag")
                            .font(.system(size: 14))
                            .foregroundStyle(showTagSuggestions ? DS.terracotta : DS.inkFaint)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

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

                    TextField("Add tag…", text: $tagInput)
                        .font(.system(size: 14))
                        .foregroundStyle(DS.inkDark)
                        .frame(minWidth: 80)
                        .submitLabel(.done)
                        .onSubmit { commitTagInput() }
                        .onChange(of: tagInput) { _, v in
                            if !v.isEmpty { showTagSuggestions = true }
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            // Suggestion chips — shown when dropdown open
            if showTagSuggestions {
                let suggestions = tagStore.suggestions(for: tagInput, excluding: selectedTags)
                if !suggestions.isEmpty || !tagInput.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            // Vault suggestions
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
                                        .padding(.vertical, 6)
                                        .background(DS.parchmentCard, in: Capsule())
                                        .overlay(Capsule().strokeBorder(DS.inkDark.opacity(0.1), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }

                            // "Create #newtag" button when input isn't in vault
                            let trimmed = tagInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                            if !trimmed.isEmpty && !suggestions.contains(trimmed) {
                                Button {
                                    if !selectedTags.contains(trimmed) {
                                        selectedTags.append(trimmed)
                                    }
                                    tagInput = ""
                                    showTagSuggestions = false
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 11, weight: .semibold))
                                        Text("Create #\(trimmed)")
                                            .font(.system(size: 13, weight: .medium))
                                    }
                                    .foregroundStyle(DS.terracotta)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(DS.terracotta.opacity(0.07), in: Capsule())
                                    .overlay(Capsule().strokeBorder(DS.terracotta.opacity(0.2), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                    }
                } else {
                    // No vault tags at all — show hint
                    Text("Type a tag name to create one")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.inkFaint)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
            }
        }
        .background(DS.parchmentMid)
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

// ── WYSIWYG NSTextStorage ─────────────────────────────────────────────────────
/// Stores raw markdown; applies visual attributes on every edit so rendered
/// text shows bold/italic/etc while the markdown markers are visually hidden.
final class MarkdownTextStorage: NSTextStorage {
    private let impl = NSMutableAttributedString()

    // Marker characters are rendered at 1pt in background colour — invisible.
    private static let baseSize: CGFloat = 17
    private static let baseFont   = UIFont.systemFont(ofSize: baseSize)
    private static let boldFont   = UIFont.boldSystemFont(ofSize: baseSize)
    private static let italicFont = UIFont.italicSystemFont(ofSize: baseSize)
    private static let codeFont   = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    private static let boldItalicFont: UIFont = {
        let d = UIFont.systemFont(ofSize: baseSize).fontDescriptor
        if let bd = d.withSymbolicTraits([.traitBold, .traitItalic]) {
            return UIFont(descriptor: bd, size: baseSize)
        }
        return UIFont.boldSystemFont(ofSize: baseSize)
    }()

    nonisolated(unsafe) private static let parasStyle: NSParagraphStyle = {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = 5
        return ps
    }()

    // MARK: Required overrides

    override var string: String { impl.string }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        guard !impl.string.isEmpty, location < impl.length else {
            range?.pointee = NSRange(location: location, length: 0)
            return [:]
        }
        return impl.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        let delta = (str as NSString).length - range.length
        beginEditing()
        impl.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: delta)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        guard range.location + range.length <= impl.length else { return }
        beginEditing()
        impl.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    // MARK: Markdown rendering

    override func processEditing() {
        guard impl.length > 0 else { super.processEditing(); return }

        let full = NSRange(location: 0, length: impl.length)

        // Reset to base
        impl.setAttributes([
            .font: Self.baseFont,
            .foregroundColor: UIColor(DS.inkDark),
            .paragraphStyle: Self.parasStyle
        ], range: full)

        // Apply rules most-specific first
        rule(#"\*\*\*(.+?)\*\*\*"#,   pre: 3, suf: 3, attrs: [.font: Self.boldItalicFont])
        rule(#"\*\*(.+?)\*\*"#,        pre: 2, suf: 2, attrs: [.font: Self.boldFont])
        rule(#"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, pre: 1, suf: 1, attrs: [.font: Self.italicFont])
        rule(#"~~(.+?)~~"#,             pre: 2, suf: 2, attrs: [
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: UIColor(DS.inkMid)
        ])
        rule(#"==(.+?)=="#,             pre: 2, suf: 2, attrs: [
            .backgroundColor: UIColor.systemYellow.withAlphaComponent(0.38)
        ])
        rule(#"`([^`\n]+)`"#,           pre: 1, suf: 1, attrs: [
            .font: Self.codeFont,
            .backgroundColor: UIColor(DS.parchmentCard)
        ])
        rule(#"<u>(.+?)</u>"#,          pre: 3, suf: 4, attrs: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: UIColor(DS.inkDark)
        ])
        rule(#"%%(.+?)%%"#,             pre: 2, suf: 2, attrs: [
            .foregroundColor: UIColor(DS.inkFaint)
        ])

        super.processEditing()
    }

    private func rule(_ pattern: String, pre: Int, suf: Int, attrs: [NSAttributedString.Key: Any]) {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return }
        let str = impl.string
        let full = NSRange(str.startIndex..., in: str)

        // Marker attrs: tiny font + background colour = invisible
        let markerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 1),
            .foregroundColor: UIColor(DS.parchmentMid)
        ]

        rx.enumerateMatches(in: str, range: full) { m, _, _ in
            guard let m = m, m.numberOfRanges >= 2 else { return }
            let whole = m.range
            let content = m.range(at: 1)
            guard content.location != NSNotFound,
                  whole.location + pre <= impl.length,
                  content.location + content.length <= impl.length,
                  whole.location + whole.length <= impl.length else { return }

            impl.addAttributes(markerAttrs, range: NSRange(location: whole.location, length: pre))
            impl.addAttributes(attrs, range: content)
            let sufStart = whole.location + whole.length - suf
            if sufStart >= 0 && sufStart + suf <= impl.length {
                impl.addAttributes(markerAttrs, range: NSRange(location: sufStart, length: suf))
            }
        }
    }
}

// ── UITextView-backed editor ──────────────────────────────────────────────────
final class MarkdownEditorCoordinator: NSObject, UITextViewDelegate {
    weak var textView: UITextView?

    func apply(prefix: String, suffix: String) {
        guard let tv = textView else { return }
        let range = tv.selectedRange

        if range.length > 0 {
            let selected = (tv.text as NSString).substring(with: range)
            if let tr = tv.selectedTextRange {
                tv.replace(tr, withText: prefix + selected + suffix)
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

    func makeCoordinator() -> MarkdownEditorCoordinator { MarkdownEditorCoordinator() }

    func makeUIView(context: Context) -> UITextView {
        // Wire custom text storage into the layout stack
        let storage = MarkdownTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = UITextView(frame: .zero, textContainer: container)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 40, right: 16)
        tv.delegate = context.coordinator
        // Remove system shortcut bar — we supply our own toolbar
        tv.inputAssistantItem.leadingBarButtonGroups  = []
        tv.inputAssistantItem.trailingBarButtonGroups = []

        context.coordinator.textView = tv
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

    private struct Fmt: Identifiable {
        let id: String; let icon: String; let prefix: String; let suffix: String
    }
    private let fmts: [Fmt] = [
        Fmt(id: "bold",      icon: "bold",                                    prefix: "**",  suffix: "**"),
        Fmt(id: "italic",    icon: "italic",                                  prefix: "*",   suffix: "*"),
        Fmt(id: "underline", icon: "underline",                               prefix: "<u>", suffix: "</u>"),
        Fmt(id: "strike",    icon: "strikethrough",                           prefix: "~~",  suffix: "~~"),
        Fmt(id: "highlight", icon: "highlighter",                             prefix: "==",  suffix: "=="),
        Fmt(id: "code",      icon: "chevron.left.forwardslash.chevron.right", prefix: "`",   suffix: "`"),
        Fmt(id: "math",      icon: "x.squareroot",                            prefix: "$",   suffix: "$"),
        Fmt(id: "comment",   icon: "bubble.left",                             prefix: "%%",  suffix: "%%"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(fmts) { fmt in
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

                        if fmt.id != fmts.last?.id {
                            Divider().frame(height: 20).padding(.horizontal, 2)
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
