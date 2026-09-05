import Foundation
import EventKit

@MainActor
final class CalendarAccess {
    var onChange: (() -> Void)?

    private let store = EKEventStore()

    private var changeObserver: NSObjectProtocol?

    private let windowBack: TimeInterval = -2 * 3600
    private let windowForward: TimeInterval = 8 * 3600

    init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in

            Task { @MainActor [weak self] in
                self?.onChange?()
            }
        }
    }

    deinit {
        if let token = changeObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func requestAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            do {
                return try await store.requestFullAccessToEvents()
            } catch {
                return false
            }
        case .writeOnly, .denied, .restricted, .authorized:

            return false
        @unknown default:
            return false
        }
    }

    func meetingsAroundNow(_ now: Date) -> [Meeting] {
        let start = now.addingTimeInterval(windowBack)
        let end = now.addingTimeInterval(windowForward)

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)

        let events = store.events(matching: predicate)

        var seen = Set<String>()
        let meetings: [Meeting] = events
            .filter { !$0.isAllDay }
            .filter { ($0.title?.isEmpty == false) }
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .compactMap { ev -> Meeting? in
                guard let s = ev.startDate, let e = ev.endDate else { return nil }

                let dedupKey = ev.eventIdentifier
                    ?? "\(ev.title ?? "")|\(s.timeIntervalSince1970)"
                guard seen.insert(dedupKey).inserted else { return nil }

                let id = ev.eventIdentifier ?? UUID().uuidString
                return Meeting(id: id, title: ev.title ?? "Untitled", start: s, end: e,
                               attendees: self.attendeeNames(ev))
            }

        return trimmedAroundNow(meetings, now: now)
    }

    func currentMeeting(_ now: Date) -> Meeting? {
        let all = sortedMeetings(now: now)
        return all.last(where: { $0.isInProgress(now) })
            ?? all.last(where: { $0.start <= now })
            ?? all.first
    }

    private func attendeeNames(_ ev: EKEvent) -> [String] {
        var names: [String] = []
        if let organizer = ev.organizer, let name = displayName(organizer) {
            names.append(name)
        }
        for participant in ev.attendees ?? [] {
            if let name = displayName(participant) {
                names.append(name)
            }
        }
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0.lowercased()).inserted }
        return Array(unique.prefix(25))
    }

    private func displayName(_ participant: EKParticipant) -> String? {
        if let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let urlString = participant.url.absoluteString
        if urlString.lowercased().hasPrefix("mailto:") {
            let email = String(urlString.dropFirst("mailto:".count))
            if !email.isEmpty { return email }
        }
        return nil
    }

    private func sortedMeetings(now: Date) -> [Meeting] {
        let start = now.addingTimeInterval(windowBack)
        let end = now.addingTimeInterval(windowForward)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        var seen = Set<String>()
        return events
            .filter { !$0.isAllDay }
            .filter { ($0.title?.isEmpty == false) }
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .compactMap { ev -> Meeting? in
                guard let s = ev.startDate, let e = ev.endDate else { return nil }
                let dedupKey = ev.eventIdentifier
                    ?? "\(ev.title ?? "")|\(s.timeIntervalSince1970)"
                guard seen.insert(dedupKey).inserted else { return nil }
                let id = ev.eventIdentifier ?? UUID().uuidString
                return Meeting(id: id, title: ev.title ?? "Untitled", start: s, end: e,
                               attendees: self.attendeeNames(ev))
            }
    }

    private func trimmedAroundNow(_ meetings: [Meeting], now: Date) -> [Meeting] {
        guard !meetings.isEmpty else { return [] }

        let past = meetings.filter { $0.end < now }
        let current = meetings.filter { $0.isInProgress(now) }
        let upcoming = meetings.filter { $0.start > now && $0.end >= now }

        let lastTwoPast = Array(past.suffix(2))
        let nextTwoUpcoming = Array(upcoming.prefix(2))

        var seen = Set<String>()
        let combined = (lastTwoPast + current + nextTwoUpcoming).filter { seen.insert($0.id).inserted }
        return combined.sorted { $0.start < $1.start }
    }
}
