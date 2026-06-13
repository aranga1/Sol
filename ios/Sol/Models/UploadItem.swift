import Foundation

enum UploadState {
    case uploading
    case done
    case failed(Error)
}

@MainActor
final class UploadItem: ObservableObject, Identifiable {
    let id = UUID()
    let filename: String
    let imageData: Data
    @Published var state: UploadState = .uploading
    var embedString: String { "![[\(filename)]]" }

    init(filename: String, imageData: Data) {
        self.filename = filename
        self.imageData = imageData
    }
}
