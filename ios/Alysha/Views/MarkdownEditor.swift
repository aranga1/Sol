/// Shared WYSIWYG markdown editing components.
/// Used by NoteComposerView (notes) and SystemPromptEditorView (system prompt).
import SwiftUI
import UIKit

// ── WYSIWYG NSTextStorage ─────────────────────────────────────────────────────
/// Parses markdown on every keystroke; renders bold/italic/etc while hiding
/// the raw markers (1pt invisible font). The raw markdown string is preserved
/// so Obsidian-compatible output is always available.
final class MarkdownTextStorage: NSTextStorage {
    private let impl = NSMutableAttributedString()

    private static let baseSize: CGFloat = 17
    private static let baseFont   = UIFont.systemFont(ofSize: baseSize)
    private static let boldFont   = UIFont.boldSystemFont(ofSize: baseSize)
    private static let italicFont = UIFont.italicSystemFont(ofSize: baseSize)
    private static let codeFont   = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    private static let boldItalicFont: UIFont = {
        let d = UIFont.systemFont(ofSize: baseSize).fontDescriptor
        if let bd = d.withSymbolicTraits([.traitBold, .traitItalic]) { return UIFont(descriptor: bd, size: baseSize) }
        return UIFont.boldSystemFont(ofSize: baseSize)
    }()
    nonisolated(unsafe) private static let parasStyle: NSParagraphStyle = {
        let ps = NSMutableParagraphStyle(); ps.lineSpacing = 5; return ps
    }()

    override var string: String { impl.string }

    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        guard !impl.string.isEmpty, location < impl.length else {
            range?.pointee = NSRange(location: location, length: 0); return [:]
        }
        return impl.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        impl.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        guard range.location + range.length <= impl.length else { return }
        beginEditing(); impl.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0); endEditing()
    }

    override func processEditing() {
        guard impl.length > 0 else { super.processEditing(); return }
        let full = NSRange(location: 0, length: impl.length)
        impl.setAttributes([.font: Self.baseFont, .foregroundColor: UIColor(DS.inkDark), .paragraphStyle: Self.parasStyle], range: full)
        rule(#"\*\*\*(.+?)\*\*\*"#,   pre: 3, suf: 3, attrs: [.font: Self.boldItalicFont])
        rule(#"\*\*(.+?)\*\*"#,        pre: 2, suf: 2, attrs: [.font: Self.boldFont])
        rule(#"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, pre: 1, suf: 1, attrs: [.font: Self.italicFont])
        rule(#"~~(.+?)~~"#,             pre: 2, suf: 2, attrs: [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: UIColor(DS.inkMid)])
        rule(#"==(.+?)=="#,             pre: 2, suf: 2, attrs: [.backgroundColor: UIColor.systemYellow.withAlphaComponent(0.38)])
        rule(#"`([^`\n]+)`"#,           pre: 1, suf: 1, attrs: [.font: Self.codeFont, .backgroundColor: UIColor(DS.parchmentCard)])
        rule(#"<u>(.+?)</u>"#,          pre: 3, suf: 4, attrs: [.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: UIColor(DS.inkDark)])
        rule(#"%%(.+?)%%"#,             pre: 2, suf: 2, attrs: [.foregroundColor: UIColor(DS.inkFaint)])
        super.processEditing()
    }

    private func rule(_ pattern: String, pre: Int, suf: Int, attrs: [NSAttributedString.Key: Any]) {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return }
        let str = impl.string
        let markerAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 1), .foregroundColor: UIColor(DS.parchmentMid)]
        rx.enumerateMatches(in: str, range: NSRange(str.startIndex..., in: str)) { m, _, _ in
            guard let m = m, m.numberOfRanges >= 2 else { return }
            let whole = m.range; let content = m.range(at: 1)
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

// ── Coordinator ───────────────────────────────────────────────────────────────
final class MarkdownEditorCoordinator: NSObject, UITextViewDelegate {
    weak var textView: UITextView?
    var onTextChange: ((String) -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    /// Wrap selection (or insert at cursor) with markdown markers.
    func apply(prefix: String, suffix: String) {
        guard let tv = textView else { return }
        if tv.selectedRange.length > 0 {
            let selected = (tv.text as NSString).substring(with: tv.selectedRange)
            if let tr = tv.selectedTextRange { tv.replace(tr, withText: prefix + selected + suffix) }
        } else {
            tv.insertText(prefix + suffix)
            if let start = tv.selectedTextRange?.start,
               let pos = tv.position(from: start, offset: -suffix.count) {
                tv.selectedTextRange = tv.textRange(from: pos, to: pos)
            }
        }
    }

    func textViewDidChange(_ textView: UITextView) { onTextChange?(textView.text) }
    func textViewDidBeginEditing(_ textView: UITextView) { onFocusChange?(true) }
    func textViewDidEndEditing(_ textView: UITextView) { onFocusChange?(false) }
}

// ── UIViewRepresentable wrapper ───────────────────────────────────────────────
struct MarkdownEditorView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var onCoordinator: (MarkdownEditorCoordinator) -> Void

    func makeCoordinator() -> MarkdownEditorCoordinator { MarkdownEditorCoordinator() }

    func makeUIView(context: Context) -> UITextView {
        let storage = MarkdownTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = UITextView(frame: .zero, textContainer: container)
        tv.backgroundColor = UIColor.clear
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 40, right: 16)
        tv.delegate = context.coordinator
        tv.inputAssistantItem.leadingBarButtonGroups  = []
        tv.inputAssistantItem.trailingBarButtonGroups = []

        context.coordinator.textView = tv
        context.coordinator.onTextChange  = { [weak tv] s in if tv?.text != s { tv?.text = s } }
        context.coordinator.onFocusChange = { f in DispatchQueue.main.async { isFocused = f } }
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
                        if fmt.id != fmts.last?.id { Divider().frame(height: 20).padding(.horizontal, 2) }
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
