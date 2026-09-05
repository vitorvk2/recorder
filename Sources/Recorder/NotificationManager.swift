import Foundation
import UserNotifications
import AppKit

@MainActor
final class NotificationManager {
    private static let categoryIdentifier = "RECORDING"

    nonisolated private static let stopActionIdentifier = "STOP"

    private static let meetingEndRequestIdentifier = "meeting-end"

    var onStopRequested: (() -> Void)?

    private let delegate = Delegate()

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()

        delegate.onStopRequested = { [weak self] in
            self?.onStopRequested?()
        }

        center.delegate = delegate

        let stopAction = UNNotificationAction(
            identifier: Self.stopActionIdentifier,
            title: "Stop Recording",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [stopAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
        }
    }

    func scheduleMeetingEndAlert(at endDate: Date, meetingTitle: String) {
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = "Meeting ended — still recording"
        content.body = "\(meetingTitle) was scheduled to end. Stop and save?"
        content.categoryIdentifier = Self.categoryIdentifier
        content.interruptionLevel = .timeSensitive
        content.sound = .default

        let interval = max(1, endDate.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)

        let request = UNNotificationRequest(
            identifier: Self.meetingEndRequestIdentifier,
            content: content,
            trigger: trigger
        )

        center.removePendingNotificationRequests(withIdentifiers: [Self.meetingEndRequestIdentifier])
        center.add(request)
    }

    func cancelMeetingEndAlert() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.meetingEndRequestIdentifier])
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        var onStopRequested: (() -> Void)?

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            [.banner, .sound]
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            let isStop = response.actionIdentifier == NotificationManager.stopActionIdentifier
            let isDefault = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            guard isStop || isDefault else { return }

            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                self.onStopRequested?()
            }
        }
    }
}
