import SwiftUI

struct HelpView: View {
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private func close() { if let onDismiss { onDismiss() } else { dismiss() } }

    private let sections: [(String, [(String, String)])] = [
        ("Connecting", [
            ("What is the QR code?",
             "The QR code encodes your Mac's Tailscale IP address. Scan it once during setup to connect your iPhone to the Sol daemon running on your Mac. To re-scan, go to Settings → Reset Connection."),
            ("Why does the app show \"Unreachable\"?",
             "The most common reasons: your Mac is asleep (wake it up), NordVPN is running on your iPhone (disconnect it — NordVPN and Tailscale can't run together), or your phone has no internet connection."),
            ("Can I use a VPN with Sol?",
             "Sol uses Tailscale for the phone-to-Mac connection. Tailscale is itself a VPN, so you can't run another VPN (like NordVPN) at the same time. Disconnect any other VPN before using Sol.")
        ]),
        ("Apple Notes Import", [
            ("Can I import my existing Apple Notes?",
             "Apple Notes uses a private format that only macOS can read — there is no reliable automated import. To bring notes across, copy and paste them into new Sol voice or text notes, or open Obsidian on Mac and create notes there directly. They will sync to your iPhone vault via iCloud.")
        ]),
        ("Voice Notes", [
            ("Why does the app need to download something on first use?",
             "Voice transcription uses WhisperKit, an on-device AI model (~150 MB). It downloads once on first launch of the Voice Note screen and is stored locally — nothing is sent to the cloud."),
            ("How does live transcription work?",
             "While you're recording, the transcript updates every 3 seconds. When you stop recording, a final high-accuracy pass runs. You can edit the transcript before saving."),
            ("What does the Title field do?",
             "The title becomes the filename of the note in your Obsidian vault (e.g. \"Morning reflection\" → Morning reflection.md). If left blank, a timestamp is used.")
        ]),
        ("Asking Questions", [
            ("What can I ask?",
             "You can ask anything about notes you've captured in Sol. The AI searches your vault and answers based on what it finds. It only knows what's in your vault — not general world knowledge."),
            ("Can I ask follow-up questions?",
             "Yes. Each follow-up shares the context of the previous answer, so you can have a multi-turn conversation about your notes."),
            ("Why does it take a few seconds to answer?",
             "Sol runs AI inference locally on your Mac using Ollama — no cloud, no API keys. Answers typically take 3–10 seconds depending on query complexity and Mac load.")
        ]),
        ("Privacy", [
            ("Does my data leave my devices?",
             "No. All AI processing runs on your Mac using Ollama (a local model runner). Your notes, questions, and answers never leave your home network."),
            ("How is the connection secured?",
             "Tailscale creates an encrypted peer-to-peer tunnel between your iPhone and Mac using WireGuard. Even on public Wi-Fi, the connection is private.")
        ])
    ]

    var body: some View {
        ZStack {
            DS.parchmentMid.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 16)
                // Header — adapts to context (back button if pushed, Done if sheet)
                HStack {
                    Button(action: close) {
                        if onDismiss != nil {
                            // standalone sheet
                            Text("Done")
                                .font(.system(size: 16))
                                .foregroundStyle(DS.inkLight)
                        } else {
                            // pushed from NavigationStack
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 16, weight: .medium))
                                Text("Settings")
                                    .font(.system(size: 16))
                            }
                            .foregroundStyle(DS.inkLight)
                        }
                    }
                    Spacer()
                    Text("Help")
                        .font(DS.newsreader(19, weight: .medium))
                        .foregroundStyle(DS.inkDark)
                    Spacer()
                    Text("Done").font(.system(size: 16)).foregroundStyle(.clear)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                Divider()

                ScrollView {
                    VStack(spacing: 20) {
                        ForEach(sections, id: \.0) { section in
                            helpSection(title: section.0, items: section.1)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    @ViewBuilder
    private func helpSection(title: String, items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(DS.inkFaint)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HelpItemRow(question: item.0, answer: item.1)
                    if idx < items.count - 1 {
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .background(DS.parchmentCard, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(DS.inkDark.opacity(0.06), lineWidth: 1))
        }
    }
}

private struct HelpItemRow: View {
    let question: String
    let answer: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Text(question)
                        .font(.system(size: 15))
                        .foregroundStyle(DS.inkDark)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.inkFaint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(answer)
                    .font(.system(size: 14))
                    .foregroundStyle(DS.inkMid)
                    .lineSpacing(4)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
