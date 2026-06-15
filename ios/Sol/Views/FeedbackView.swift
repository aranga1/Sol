import SwiftUI

// ── FeedbackViewModel ─────────────────────────────────────────────────────────
@Observable
@MainActor
final class FeedbackViewModel {
    var segment: Int = 0           // 0 = Bug Report, 1 = Feature Request
    var title: String = ""
    var description: String = ""
    var selectedImages: [UIImage] = []
    var isSubmitting: Bool = false
    var errorMessage: String? = nil
    var didSubmit: Bool = false

    var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !isSubmitting
    }

    private let service: GitHubService

    init(service: GitHubService = GitHubService()) {
        self.service = service
    }

    func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        var imageURLs: [String] = []
        for image in selectedImages {
            guard let data = image.jpegData(compressionQuality: 0.8) else { continue }
            let uuid = UUID().uuidString
            do {
                let url = try await service.uploadImage(data, uuid: uuid)
                imageURLs.append(url)
            } catch {
                errorMessage = "Image upload failed: \(error.localizedDescription)"
                return
            }
        }

        let prefix = segment == 0 ? "[iOS Bug]" : "[iOS Feature]"
        let labels = segment == 0 ? ["bug", "ios"] : ["enhancement", "ios"]
        let imageMarkdown = imageURLs.map { "![screenshot](\($0))" }.joined(separator: "\n")
        let body = description + (imageMarkdown.isEmpty ? "" : "\n\n" + imageMarkdown)

        do {
            try await service.createIssue(title: "\(prefix) \(title)", body: body, labels: labels)
            didSubmit = true
        } catch {
            errorMessage = "Failed to submit: \(error.localizedDescription)"
        }
    }
}

// ── FeedbackView ──────────────────────────────────────────────────────────────
struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var vm = FeedbackViewModel()
    @State private var showImagePicker = false

    var body: some View {
        NavigationStack {
            ZStack {
                DS.parchmentMid.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // ── Segment picker ────────────────────────────────
                        Picker("Type", selection: $vm.segment) {
                            Text("Bug Report").tag(0)
                            Text("Feature Request").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .tint(DS.terracotta)
                        .padding(.top, 8)

                        // ── Title field ───────────────────────────────────
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Title")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DS.inkFaint)

                            TextField("Short summary…", text: $vm.title)
                                .font(.system(size: 16))
                                .foregroundStyle(DS.inkDark)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(DS.parchmentCard, in: RoundedRectangle(cornerRadius: DS.radiusButton))
                                .overlay(
                                    RoundedRectangle(cornerRadius: DS.radiusButton)
                                        .strokeBorder(DS.inkFaint.opacity(0.2), lineWidth: 1)
                                )
                        }

                        // ── Description field ─────────────────────────────
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Description")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(DS.inkFaint)

                            ZStack(alignment: .topLeading) {
                                if vm.description.isEmpty {
                                    Text("Describe the issue or idea…")
                                        .font(.system(size: 15))
                                        .foregroundStyle(DS.inkFaint)
                                        .padding(.horizontal, 18)
                                        .padding(.vertical, 14)
                                }

                                TextEditor(text: $vm.description)
                                    .font(.system(size: 15))
                                    .foregroundStyle(DS.inkDark)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 120)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                            }
                            .background(DS.parchmentCard, in: RoundedRectangle(cornerRadius: DS.radiusButton))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.radiusButton)
                                    .strokeBorder(DS.inkFaint.opacity(0.2), lineWidth: 1)
                            )
                        }

                        // ── Photo strip ───────────────────────────────────
                        if !vm.selectedImages.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Attachments")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(DS.inkFaint)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(vm.selectedImages.indices, id: \.self) { idx in
                                            ZStack(alignment: .topTrailing) {
                                                Image(uiImage: vm.selectedImages[idx])
                                                    .resizable()
                                                    .scaledToFill()
                                                    .frame(width: 72, height: 72)
                                                    .clipShape(RoundedRectangle(cornerRadius: 10))

                                                Button {
                                                    vm.selectedImages.remove(at: idx)
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .font(.system(size: 18))
                                                        .foregroundStyle(DS.inkLight)
                                                        .background(Circle().fill(DS.parchmentCard).padding(3))
                                                }
                                                .buttonStyle(.plain)
                                                .offset(x: 8, y: -8)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 8)
                                }
                                .animation(.easeOut(duration: 0.2), value: vm.selectedImages.count)
                            }
                        }

                        // ── Add photo button ──────────────────────────────
                        if vm.selectedImages.count < 3 {
                            Button {
                                showImagePicker = true
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: 15))
                                    Text("Add Screenshot")
                                        .font(.system(size: 15, weight: .medium))
                                }
                                .foregroundStyle(DS.terracotta)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(DS.terracotta.opacity(0.08), in: Capsule())
                                .overlay(Capsule().strokeBorder(DS.terracotta.opacity(0.22), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }

                        // ── Error message ─────────────────────────────────
                        if let msg = vm.errorMessage {
                            Text(msg)
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                        }

                        // ── Submit button ─────────────────────────────────
                        Button {
                            Task { await vm.submit() }
                        } label: {
                            ZStack {
                                if vm.isSubmitting {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Text("Submit")
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background {
                                RoundedRectangle(cornerRadius: DS.radiusButton)
                                    .fill(vm.canSubmit ? AnyShapeStyle(DS.terracottaGradient) : AnyShapeStyle(DS.inkFaint.opacity(0.25)))
                            }
                        }
                        .disabled(!vm.canSubmit)
                        .animation(.easeOut(duration: 0.15), value: vm.canSubmit)
                        .padding(.top, 4)
                        .padding(.bottom, 20)
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(DS.inkLight)
                }
                ToolbarItem(placement: .principal) {
                    Text("Feedback")
                        .font(DS.newsreader(19, weight: .medium))
                        .foregroundStyle(DS.inkDark)
                }
            }
            .toolbarBackground(DS.parchmentMid, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(DS.parchmentMid)
        // ── Image picker sheet ────────────────────────────────────────────────
        .sheet(isPresented: $showImagePicker) {
            ImagePickerView(sourceType: .photoLibrary) { image in
                if vm.selectedImages.count < 3 {
                    vm.selectedImages.append(image)
                }
            }
        }
        // ── Sent confirmation overlay ─────────────────────────────────────────
        .overlay {
            if vm.didSubmit {
                SentConfirmationOverlay {
                    dismiss()
                }
            }
        }
    }
}

// ── Sent confirmation overlay ─────────────────────────────────────────────────
private struct SentConfirmationOverlay: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .transition(.opacity)

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(DS.terracottaGradient)
                        .frame(width: 72, height: 72)
                    Image(systemName: "checkmark")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                }

                Text("Thanks!")
                    .font(DS.newsreader(26, weight: .medium))
                    .foregroundStyle(.white)

                Text("Your feedback has been submitted.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            .padding(40)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                onDismiss()
            }
        }
    }
}
