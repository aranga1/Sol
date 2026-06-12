import SwiftUI

/// Slides down from the top when NotificationService.shared.pending is set.
/// Auto-dismisses after 4 seconds. Tapping dismisses immediately.
struct InAppNotificationBanner: View {
    private let service = NotificationService.shared
    @State private var dismissTask: Task<Void, Never>? = nil

    private var notification: DaemonNotification? { service.pending }

    var body: some View {
        Group {
            if let n = notification {
                banner(n)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        dismissTask?.cancel()
                        dismissTask = Task {
                            try? await Task.sleep(for: .seconds(4))
                            guard !Task.isCancelled else { return }
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                service.pending = nil
                            }
                        }
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: notification?.id)
        .zIndex(100)
    }

    @ViewBuilder
    private func banner(_ n: DaemonNotification) -> some View {
        Button {
            dismissTask?.cancel()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                service.pending = nil
            }
        } label: {
            HStack(spacing: 14) {
                Image("SolMarkColor")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(n.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.inkDark)
                    Text(n.body)
                        .font(.system(size: 13))
                        .foregroundStyle(DS.inkMid)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Type indicator
                Circle()
                    .fill(typeColor(n.type))
                    .frame(width: 8, height: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(DS.inkDark.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 6)
            .padding(.horizontal, 16)
            .padding(.top, 56)  // below status bar
        }
        .buttonStyle(.plain)
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "warning": return .orange
        case "update":  return DS.terracotta
        default:        return .green
        }
    }
}
