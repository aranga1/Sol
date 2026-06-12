import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let connectingItems: [(String, String)] = [
        ("What is the QR code?",
         "The QR code encodes your Mac's Tailscale IP address. Scan it once during setup to connect your iPhone to the Alysha daemon running on your Mac. To re-scan, go to Settings → Reset Connection."),
        ("Why does the app show \"Unreachable\"?",
         "The most common reasons: your Mac is asleep (wake it up), NordVPN is running on your iPhone (disconnect it — NordVPN and Tailscale can't run together), or your phone has no internet connection."),
        ("Can I use a VPN with Alysha?",
         "Alysha uses Tailscale for the phone-to-Mac connection. Tailscale is itself a VPN, so you can't run another VPN (like NordVPN) at the same time. Disconnect any other VPN before using Alysha.")
    ]

    private let appleNotesItems: [(String, String)] = [
        ("Can I import my existing Apple Notes?",
         "Apple Notes uses a private format that only macOS can read — there is no reliable automated import. To bring notes across, copy and paste them into new Alysha voice or text notes, or open Obsidian on Mac and create notes there directly. They will sync to your iPhone vault via iCloud.")
    ]

    private let voiceItems: [(String, String)] = [
        ("Why does the app need to download something on first use?",
         "Voice transcription uses WhisperKit, an on-device AI model (~150 MB). It downloads once on first launch of the Voice Note screen and is stored locally — nothing is sent to the cloud."),
        ("How does live transcription work?",
         "While you're recording, the transcript updates every 3 seconds. When you stop recording, a final high-accuracy pass runs. You can edit the transcript before saving."),
        ("What does the Title field do?",
         "The title becomes the filename of the note in your Obsidian vault (e.g. \"Morning reflection\" → Morning reflection.md). If left blank, a timestamp is used.")
    ]

    private let queryItems: [(String, String)] = [
        ("What can I ask?",
         "You can ask anything about notes you've captured in Alysha. The AI searches your vault and answers based on what it finds. It only knows what's in your vault — not general world knowledge."),
        ("Can I ask follow-up questions?",
         "Yes. Each follow-up shares the context of the previous answer, so you can have a multi-turn conversation about your notes."),
        ("Why does it take a few seconds to answer?",
         "Alysha runs AI inference locally on your Mac using Ollama — no cloud, no API keys. Answers typically take 3–10 seconds depending on query complexity and Mac load.")
    ]

    private let privacyItems: [(String, String)] = [
        ("Does my data leave my devices?",
         "No. All AI processing runs on your Mac using Ollama (a local model runner). Your notes, questions, and answers never leave your home network."),
        ("How is the connection secured?",
         "Tailscale creates an encrypted peer-to-peer tunnel between your iPhone and Mac using WireGuard. Even on public Wi-Fi, the connection is private.")
    ]

    var body: some View {
        NavigationStack {
            List {
                HelpSection(title: "Connecting", items: connectingItems)
                HelpSection(title: "Apple Notes Import", items: appleNotesItems)
                HelpSection(title: "Voice Notes", items: voiceItems)
                HelpSection(title: "Asking Questions", items: queryItems)
                HelpSection(title: "Privacy", items: privacyItems)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct HelpSection: View {
    let title: String
    let items: [(String, String)]  // (question, answer)

    var body: some View {
        Section(title) {
            ForEach(items, id: \.0) { item in
                DisclosureGroup(item.0) {
                    Text(item.1)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
            }
        }
    }
}
