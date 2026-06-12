import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @State private var scannerActive = true
    @State private var errorMessage: String?
    @State private var showManualEntry = false
    @Environment(\.dismiss) private var dismiss
    var onConnected: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                if !showManualEntry && AVCaptureDevice.authorizationStatus(for: .video) != .denied {
                    QRScannerView(onScan: handleScan)
                        .ignoresSafeArea()
                } else {
                    ManualEntryView(onConnect: handleManualConnect)
                }

                VStack {
                    Spacer()
                    if let error = errorMessage {
                        Text(error)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                            .padding()
                    }
                    Button(showManualEntry ? "Use QR Scanner" : "Enter manually") {
                        showManualEntry.toggle()
                        errorMessage = nil
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Connect to Sol")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { requestCameraPermission() }
        }
    }

    private func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { _ in }
    }

    private func handleScan(_ rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let json = try? JSONDecoder().decode(QRPayload.self, from: data) else {
            errorMessage = "Invalid QR code. Please scan the code shown by the setup script."
            return
        }
        connect(host: json.host, port: json.port, apiKey: json.apiKey)
    }

    private func handleManualConnect(host: String, port: Int, apiKey: String) {
        connect(host: host, port: port, apiKey: apiKey)
    }

    private func connect(host: String, port: Int, apiKey: String) {
        // Validate before saving
        guard !host.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Host cannot be empty."
            return
        }
        guard port >= 1 && port <= 65535 else {
            errorMessage = "Port must be between 1 and 65535."
            return
        }
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "API key cannot be empty."
            return
        }
        let config = ConnectionConfig(host: host, port: port, apiKey: apiKey)
        KeychainService.save(config)
        NotificationService.shared.requestAuthorization()
        onConnected()
    }
}

private struct QRPayload: Decodable {
    let host: String
    let port: Int
    let apiKey: String
}
