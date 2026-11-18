import XCTest
@testable import Recorder

@MainActor
final class FakeTeamsActivity: TeamsAudioActivity {
    var isTeamsCapturing = false {
        didSet { onChange?() }
    }
    private(set) var isStarted = false
    private var onChange: (@MainActor @Sendable () -> Void)?

    init(capturing: Bool = false) {
        isTeamsCapturing = capturing
    }

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        isStarted = true
        self.onChange = onChange
    }

    func stop() {
        isStarted = false
        onChange = nil
    }
}

@MainActor
final class TeamsCallObserverTests: XCTestCase {
    func testCallStartsAfterDelayAndEndsAfterGrace() async throws {
        let activity = FakeTeamsActivity()
        let observer = TeamsCallObserver(activity: activity, startDelay: 0.1, stopGrace: 0.2)
        var started = 0
        var ended = 0
        observer.onFirstCall = { started += 1 }
        observer.onAllCallsEnded = { ended += 1 }
        observer.start()
        defer { observer.stop() }
        XCTAssertTrue(activity.isStarted)

        activity.isTeamsCapturing = true
        XCTAssertFalse(observer.isInCall)
        try await waitFor { observer.isInCall }
        XCTAssertEqual(started, 1)

        activity.isTeamsCapturing = false
        XCTAssertTrue(observer.isInCall)
        try await waitFor { ended == 1 }
        XCTAssertFalse(observer.isInCall)
        XCTAssertEqual(started, 1)
    }

    func testCallAlreadyInProgressAtStartIsDetected() async throws {
        let activity = FakeTeamsActivity(capturing: true)
        let observer = TeamsCallObserver(activity: activity, startDelay: 0.1, stopGrace: 0.2)
        var started = 0
        observer.onFirstCall = { started += 1 }
        observer.start()
        defer { observer.stop() }
        try await waitFor { observer.isInCall }
        XCTAssertEqual(started, 1)
    }

    func testShortMicBlipDoesNotStartCall() async throws {
        let activity = FakeTeamsActivity()
        let observer = TeamsCallObserver(activity: activity, startDelay: 0.3, stopGrace: 0.2)
        var started = 0
        observer.onFirstCall = { started += 1 }
        observer.start()
        defer { observer.stop() }

        activity.isTeamsCapturing = true
        try await Task.sleep(for: .milliseconds(100))
        activity.isTeamsCapturing = false
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(observer.isInCall)
        XCTAssertEqual(started, 0)
    }

    func testBriefMicDropDuringCallKeepsCall() async throws {
        let activity = FakeTeamsActivity(capturing: true)
        let observer = TeamsCallObserver(activity: activity, startDelay: 0.05, stopGrace: 0.4)
        var ended = 0
        observer.onAllCallsEnded = { ended += 1 }
        observer.start()
        defer { observer.stop() }
        try await waitFor { observer.isInCall }

        activity.isTeamsCapturing = false
        try await Task.sleep(for: .milliseconds(100))
        activity.isTeamsCapturing = true
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(observer.isInCall)
        XCTAssertEqual(ended, 0)
    }

    func testStopDetachesFromActivity() {
        let activity = FakeTeamsActivity()
        let observer = TeamsCallObserver(activity: activity, startDelay: 0.05, stopGrace: 0.05)
        observer.start()
        observer.stop()
        XCTAssertFalse(activity.isStarted)
    }

    func testCoreAudioActivityStartsAndStops() {
        let activity = CoreAudioTeamsActivity()
        activity.start {}
        _ = activity.isTeamsCapturing
        activity.stop()
    }

    private func waitFor(timeout: Int = 5, _ predicate: () -> Bool) async throws {
        for _ in 0..<(timeout * 20) {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for observer condition")
    }
}
