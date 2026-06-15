import SwiftUI

// ── FolderPickerSection ───────────────────────────────────────────────────────
// Collapsible panel for choosing a destination folder.
// Visually mirrors tagSection in NoteComposerView.swift.

struct FolderPickerSection: View {
    @Binding var selectedFolder: String?
    let apiClient: APIClient

    // ── Internal state ────────────────────────────────────────────────────────
    @State private var isExpanded: Bool = false
    @State private var searchText: String = ""
    @State private var suggestions: [String] = []
    @State private var isLoading: Bool = false
    @FocusState private var fieldFocused: Bool

    // ── UserDefaults ──────────────────────────────────────────────────────────
    private static let recentsKey = "sol.recentFolders"
    private static let maxRecents = 10

    // ── Body ──────────────────────────────────────────────────────────────────
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()

            // ── Header / collapsed row ────────────────────────────────────────
            HStack(spacing: 0) {
                // Toggle button — folder icon
                Button {
                    isExpanded.toggle()
                    if isExpanded {
                        fieldFocused = true
                    } else {
                        searchText = ""
                        fieldFocused = false
                    }
                } label: {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 14))
                        .foregroundStyle(isExpanded ? DS.terracotta : DS.inkFaint)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Placeholder or selected chip
                if let folder = selectedFolder {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(DS.terracottaDark)
                                Text(folder)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(DS.terracottaDark)
                                    .lineLimit(1)
                                Button {
                                    selectedFolder = nil
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
                        .padding(.trailing, 12)
                    }
                } else if !isExpanded {
                    Text("Add to folder…")
                        .font(.system(size: 14))
                        .foregroundStyle(DS.inkFaint)
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.inkFaint)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeOut(duration: 0.18), value: isExpanded)
                    .padding(.trailing, 16)
            }
            .frame(height: 44)

            // ── Expanded search + suggestion panel ────────────────────────────
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()

                    // Search field
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundStyle(DS.inkFaint)
                        TextField("Search or type a path…", text: $searchText)
                            .font(.system(size: 15))
                            .foregroundStyle(DS.inkDark)
                            .focused($fieldFocused)
                            .submitLabel(.done)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { commitTyped() }
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(DS.inkFaint)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)

                    Divider()

                    // Suggestion list
                    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let filtered = filteredSuggestions(trimmed: trimmed)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            // "Create <path>" row — when typed text isn't an exact match
                            if !trimmed.isEmpty && !filtered.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
                                folderRow(
                                    label: "Create \"\(trimmed)\"",
                                    icon: "plus.circle.fill",
                                    isSelected: false,
                                    tinted: true
                                ) {
                                    selectFolder(trimmed)
                                }
                                if !filtered.isEmpty {
                                    Divider().padding(.leading, 16)
                                }
                            }

                            // Suggestions
                            ForEach(Array(filtered.enumerated()), id: \.offset) { idx, path in
                                folderRow(
                                    label: path,
                                    icon: "folder",
                                    isSelected: selectedFolder == path,
                                    tinted: false
                                ) {
                                    selectFolder(path)
                                }
                                if idx < filtered.count - 1 {
                                    Divider().padding(.leading, 16)
                                }
                            }

                            if isLoading {
                                HStack {
                                    Spacer()
                                    ProgressView().tint(DS.terracotta)
                                    Spacer()
                                }
                                .padding(16)
                            } else if trimmed.isEmpty && filtered.isEmpty {
                                Text("Type a path to create a folder")
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
                .task {
                    await loadSuggestions()
                }
            }
        }
        .background(DS.parchmentMid)
        .animation(.easeOut(duration: 0.18), value: isExpanded)
    }

    // ── Row builder ───────────────────────────────────────────────────────────
    @ViewBuilder
    private func folderRow(
        label: String,
        icon: String,
        isSelected: Bool,
        tinted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(tinted ? DS.terracotta : DS.inkFaint)
                    .frame(width: 20)
                Text(label)
                    .font(.system(size: 15))
                    .foregroundStyle(tinted ? DS.terracotta : DS.inkDark)
                    .lineLimit(1)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.terracotta)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // ── Data helpers ──────────────────────────────────────────────────────────
    private func filteredSuggestions(trimmed: String) -> [String] {
        guard !trimmed.isEmpty else { return suggestions }
        return suggestions.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    private func loadSuggestions() async {
        isLoading = true
        var remote: [String] = []
        do {
            remote = try await apiClient.fetchDirectories()
        } catch {
            // On error show recents only — don't crash
            remote = []
        }
        let recents = Self.loadRecents()
        // Merge: recents first (preserves recency order), then remote, deduplicated
        var seen = Set<String>()
        var merged: [String] = []
        for path in recents + remote.sorted() {
            let key = path.lowercased()
            if seen.insert(key).inserted {
                merged.append(path)
            }
        }
        suggestions = merged
        isLoading = false
    }

    private func selectFolder(_ path: String) {
        selectedFolder = path
        Self.prependRecent(path)
        searchText = ""
        isExpanded = false
        fieldFocused = false
    }

    private func commitTyped() {
        let t = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        selectFolder(t)
    }

    // ── UserDefaults recents management ───────────────────────────────────────
    private static func loadRecents() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
    }

    private static func prependRecent(_ path: String) {
        var recents = loadRecents().filter { $0 != path }
        recents.insert(path, at: 0)
        if recents.count > maxRecents {
            recents = Array(recents.prefix(maxRecents))
        }
        UserDefaults.standard.set(recents, forKey: recentsKey)
    }
}
