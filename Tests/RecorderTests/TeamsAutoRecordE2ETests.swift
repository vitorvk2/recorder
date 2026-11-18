import XCTest
@testable import Recorder

@MainActor
final class TeamsAutoRecordE2ETests: XCTestCase {
    private func wired(capturing: Bool = false) -> (FakeTeamsActivity, TeamsCallObserver, RecorderModel) {
        let activity = FakeTeamsActivity(capturing: capturing)
        let observer = TeamsCallObserver(activity: activity, startDelay: 0.05, stopGrace: 0.2)
        let model = RecorderModel(recoverPublicationsAutomatically: false, teamsObserver: observer)
        model.startTeamsMonitoring()
        return (activity, observer, model)
    }

    private func waitFor(timeout: Int = 100, _ predicate: () -> Bool) async throws {
        for _ in 0..<timeout {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for end-to-end condition")
    }

    func testNoAutoStartWhenToggleOff() async throws {
        let (activity, observer, model) = wired()
        defer { observer.stop() }
        model.autoRecordTeams = false

        activity.isTeamsCapturing = true
        try await waitFor { model.teamsInCall }
        XCTAssertEqual(model.state, .idle)

        activity.isTeamsCapturing = false
        try await waitFor { !model.teamsInCall }
        XCTAssertEqual(model.state, .idle)
    }

    func testManualRecordingSurvivesCallEnd() async throws {
        let (activity, observer, model) = wired()
        defer { observer.stop() }

        model.state = .recording
        activity.isTeamsCapturing = true
        try await waitFor { model.teamsInCall }
        activity.isTeamsCapturing = false
        try await waitFor { !model.teamsInCall }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.state, .recording)
    }

    func testRecordingSurvivesWhenAutoStopOff() async throws {
        let (activity, observer, model) = wired()
        defer { observer.stop() }
        model.autoStopTeams = false

        model.state = .recording
        activity.isTeamsCapturing = true
        try await waitFor { model.teamsInCall }
        activity.isTeamsCapturing = false
        try await waitFor { !model.teamsInCall }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.state, .recording)
    }

    func testCallInProgressBeforeLaunchIsPickedUp() async throws {
        let (_, observer, model) = wired(capturing: true)
        defer { observer.stop() }
        model.autoRecordTeams = false
        try await waitFor { model.teamsInCall }
        XCTAssertTrue(observer.isInCall)
    }

    func testLiveAutoStartAttempt() async throws {
        let (activity, observer, model) = wired()
        defer { observer.stop() }

        activity.isTeamsCapturing = true
        try await waitFor { model.teamsInCall }
        if model.state == .recording {
            model.trashAndStop()
            XCTAssertEqual(model.state, .idle)
        } else {
            XCTAssertEqual(model.state, .idle)
            XCTAssertNotNil(model.statusMessage)
        }
    }
}
