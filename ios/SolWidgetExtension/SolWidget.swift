import WidgetKit
import SwiftUI

struct SolWidget: Widget {
    let kind = "SolWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SolWidgetProvider()) { _ in
            SolWidgetEntryView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Sol")
        .description("Quick capture shortcuts for Voice and Text notes.")
        .supportedFamilies([.systemMedium])
    }
}

struct SolWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry { SimpleEntry() }
    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        completion(SimpleEntry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        completion(Timeline(entries: [SimpleEntry()], policy: .never))
    }
}

struct SimpleEntry: TimelineEntry {
    let date = Date()
}

struct SolWidgetEntryView: View {
    var body: some View {
        HStack(spacing: 0) {
            // Voice button — left half
            Link(destination: URL(string: "sol://voice")!) {
                VStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                    Text("Voice")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.indigo)
            }

            Divider()

            // Text button — right half
            Link(destination: URL(string: "sol://text")!) {
                VStack(spacing: 8) {
                    Image(systemName: "pencil")
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                    Text("Text")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.teal)
            }
        }
    }
}
