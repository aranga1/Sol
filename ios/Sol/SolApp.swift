import SwiftUI

@main
struct SolApp: App {
    @UIApplicationDelegateAdaptor(SolAppDelegate.self) var appDelegate
    @State private var isOnboarded = KeychainService.load() != nil
    @Environment(\.scenePhase) private var scenePhase
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
                            NotificationService.shared.startPolling()
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
            .onChange(of: scenePhase) { _, phase in
                guard isOnboarded else { return }
                if phase == .active {
                    NotificationService.shared.startPolling()
                } else {
                    NotificationService.shared.stopPolling()
                }
            }
            .onOpenURL { url in
                guard url.scheme == "sol" else { return }
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

extension SolApp.DeepLinkTarget: Identifiable {
    var id: String {
        switch self {
        case .voice: return "voice"
        case .text: return "text"
        }
    }
}
