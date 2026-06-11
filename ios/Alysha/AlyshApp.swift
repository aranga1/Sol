import SwiftUI

@main
struct AlyshApp: App {
    @State private var deepLinkTarget: DeepLinkTarget?

    enum DeepLinkTarget {
        case voice, text
    }

    var body: some Scene {
        WindowGroup {
            if KeychainService.load() != nil {
                HomeView()
                    .sheet(item: $deepLinkTarget) { target in
                        switch target {
                        case .voice: VoiceNoteView()
                        case .text: TextNoteView()
                        }
                    }
            } else {
                OnboardingView()
            }
        }
        .onOpenURL { url in
            guard url.scheme == "alysha" else { return }
            switch url.host {
            case "voice": deepLinkTarget = .voice
            case "text": deepLinkTarget = .text
            default: break
            }
        }
    }
}

extension AlyshApp.DeepLinkTarget: Identifiable {
    var id: String {
        switch self {
        case .voice: return "voice"
        case .text: return "text"
        }
    }
}
