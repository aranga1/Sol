import WidgetKit
import SwiftUI

struct AlyshWidget: Widget {
    let kind = "AlyshWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AlyshWidgetProvider()) { _ in
            AlyshWidgetEntryView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Alysha")
        .description("Quick capture shortcuts for Voice and Text notes.")
        .supportedFamilies([.systemMedium])
    }
}

struct AlyshWidgetProvider: TimelineProvider {
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

struct AlyshWidgetEntryView: View {
    var body: some View {
        HStack(spacing: 0) {
            // Voice button — left half
            Link(destination: URL(string: "alysha://voice")!) {
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
            Link(destination: URL(string: "alysha://text")!) {
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
