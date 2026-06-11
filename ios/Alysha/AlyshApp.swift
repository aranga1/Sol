import SwiftUI

@main
struct AlyshApp: App {
    @State private var isOnboarded = KeychainService.load() != nil
    @State private var deepLinkTarget: DeepLinkTarget?
    @State private var pendingDeepLink: DeepLinkTarget?

    enum DeepLinkTarget {
        case voice, text
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if isOnboarded {
                    HomeView(onResetConnection: {
                        KeychainService.delete()
                        isOnboarded = false
                    })
                        .onAppear {
                            if let pending = pendingDeepLink {
                                deepLinkTarget = pending
                                pendingDeepLink = nil
                            }
                        }
                        .sheet(item: $deepLinkTarget) { target in
                            switch target {
                            case .voice: VoiceNoteView()
                            case .text: TextNoteView()
                            }
                        }
                } else {
                    OnboardingView(onConnected: { isOnboarded = true })
                }
            }
            .onOpenURL { url in
                guard url.scheme == "alysha" else { return }
                let target: DeepLinkTarget? = switch url.host {
                case "voice": .voice
                case "text": .text
                default: nil
                }
                if isOnboarded {
                    deepLinkTarget = target
                } else {
                    pendingDeepLink = target
                }
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
