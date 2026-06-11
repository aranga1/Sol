import WidgetKit
import SwiftUI

struct AlyshWidget: Widget {
    let kind = "AlyshWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AlyshWidgetProvider()) { _ in
            Text("Alysha Widget — coming soon")
        }
        .configurationDisplayName("Alysha")
        .description("Quick capture shortcuts")
        .supportedFamilies([.systemMedium])
    }
}

struct AlyshWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry { SimpleEntry() }
    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) { completion(SimpleEntry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        completion(Timeline(entries: [SimpleEntry()], policy: .never))
    }
}

struct SimpleEntry: TimelineEntry {
    let date = Date()
}
