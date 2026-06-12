import SwiftUI

struct ManualEntryView: View {
    var onConnect: (String, Int, String) -> Void
    @State private var host = ""
    @State private var portText = "8765"
    @State private var apiKey = ""

    var body: some View {
        Form {
            Section("Mac connection details") {
                TextField("Tailscale IP (e.g. 100.x.x.x)", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $portText)
                    .keyboardType(.numberPad)
                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Button("Connect") {
                onConnect(host, Int(portText) ?? 0, apiKey)
            }
            .disabled(host.isEmpty || apiKey.isEmpty)
        }
    }
}
