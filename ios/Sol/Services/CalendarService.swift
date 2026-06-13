import EventKit
import EventKitUI
import UIKit

@MainActor
final class CalendarService: NSObject {
    static let shared = CalendarService()
    private let store = EKEventStore()
    var eventStore: EKEventStore { store }
    private var onResult: ((Bool) -> Void)?

    func requestAccess() async -> Bool {
        if #available(iOS 17.0, *) {
            return (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            return await withCheckedContinuation { continuation in
                store.requestAccess(to: .event) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func presentEventEditor(
        payload: CreateEventPayload,
        from viewController: UIViewController,
        onResult: @escaping (Bool) -> Void
    ) {
        self.onResult = onResult

        let event = EKEvent(eventStore: store)
        event.title = payload.title
        event.startDate = payload.start
        event.endDate = payload.start.addingTimeInterval(
            TimeInterval(payload.durationMinutes * 60)
        )
        if let notes = payload.notes, !notes.isEmpty {
            event.notes = notes
        }
        event.calendar = store.defaultCalendarForNewEvents

        let editVC = EKEventEditViewController()
        editVC.eventStore = store
        editVC.event = event
        editVC.editViewDelegate = self
        viewController.present(editVC, animated: true)
    }
}

extension CalendarService: EKEventEditViewDelegate {
    nonisolated func eventEditViewController(
        _ controller: EKEventEditViewController,
        didCompleteWith action: EKEventEditViewAction
    ) {
        let saved = action == .saved
        Task { @MainActor in
            controller.dismiss(animated: true)
            self.onResult?(saved)
            self.onResult = nil
        }
    }
}
