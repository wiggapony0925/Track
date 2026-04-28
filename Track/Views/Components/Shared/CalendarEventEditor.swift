import EventKit
import EventKitUI
import SwiftUI

struct CalendarEventDraft: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let location: String?
    let notes: String?
    let startDate: Date
    let endDate: Date
}

struct CalendarEventEditor: UIViewControllerRepresentable {
    let eventStore: EKEventStore
    let draft: CalendarEventDraft

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let event = EKEvent(eventStore: eventStore)
        event.title = draft.title
        event.location = draft.location
        event.notes = draft.notes
        event.startDate = draft.startDate
        event.endDate = max(draft.endDate, draft.startDate.addingTimeInterval(15 * 60))
        event.calendar = eventStore.defaultCalendarForNewEvents

        let controller = EKEventEditViewController()
        controller.eventStore = eventStore
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(
        _ uiViewController: EKEventEditViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        func eventEditViewController(
            _ controller: EKEventEditViewController,
            didCompleteWith action: EKEventEditViewAction
        ) {
            dismiss()
        }
    }
}

enum CalendarEventAccess {
    static func request(for eventStore: EKEventStore) async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized, .fullAccess, .writeOnly:
            return true
        case .notDetermined:
            do {
                if #available(iOS 17.0, *) {
                    return try await eventStore.requestFullAccessToEvents()
                } else {
                    return try await eventStore.requestAccess(to: .event)
                }
            } catch {
                return false
            }
        case .restricted, .denied:
            return false
        @unknown default:
            return false
        }
    }
}
