import XCTest
import SwiftUI
import AppKit
@testable import Recorder

private actor PipelineStub {
    private var continuations: [URL: CheckedContinuation<String, Error>] = [:]
    private(set) var started: [URL] = []
    private(set) var maxConcurrent = 0

    func run(_ pending: RecorderModel.PendingTranscription) async throws -> String {
        started.append(pending.id)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[pending.id] = continuation
            maxConcurrent = max(maxConcurrent, continuations.count)
        }
    }

    func finish(_ id: URL, error: Bool = false) {
        let continuation = continuations.removeValue(forKey: id)
        if error {
            continuation?.resume(throwing: NSError(domain: "TestPipeline", code: 1,
                                                  userInfo: [NSLocalizedDescriptionKey: "Falha de teste"]))
        } else {
            continuation?.resume(returning: "ok \"Reunião publicada\"\nobsidian://open?vault=Trabalho")
        }
    }
}

@MainActor
final class RecorderTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func pending(_ name: String, context: String = "Funcional") throws -> RecorderModel.PendingTranscription {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return .init(audioURL: folder.appendingPathComponent("audio.m4a"), metaFolderURL: folder,
                     logURL: folder.appendingPathComponent("pipeline.log"), meetingTitle: name,
                     attendees: [], startedAt: Date(), context: context)
    }

    private func waitFor(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for processing state")
    }

    func testAutomaticProcessingIsSerialAndDeduplicated() async throws {
        let stub = PipelineStub()
        let model = RecorderModel(recoverPublicationsAutomatically: false) { _, pending, _ in try await stub.run(pending) }
        model.pipelineIsReady = true
        let first = try pending("first")
        let second = try pending("second")
        model.recordingDidSave(first, autoProcess: true)
        model.recordingDidSave(second, autoProcess: true)
        model.recordingDidSave(first, autoProcess: true)
        model.recordingDidSave(second, autoProcess: true)
        try await waitFor { await stub.started.count == 1 }
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.queuedTranscriptions.count, 1)
        XCTAssertTrue(model.pendingTranscriptions.isEmpty)
        await stub.finish(first.id)
        try await waitFor { await stub.started.count == 2 }
        XCTAssertEqual(model.activeTranscription?.id, second.id)
        await stub.finish(second.id)
        try await waitFor { model.activeTranscription == nil }
        let concurrent = await stub.maxConcurrent
        XCTAssertEqual(concurrent, 1)
        XCTAssertEqual(model.lastOutcome?.kind, .published)
    }

    func testSavingWhileProcessingPreservesBothJobsAndTheirContexts() async throws {
        let stub = PipelineStub()
        let model = RecorderModel(recoverPublicationsAutomatically: false) { _, pending, _ in try await stub.run(pending) }
        model.pipelineIsReady = true
        let first = try pending("first")
        let second = try pending("second", context: "Pedbot")
        model.recordingDidSave(first, autoProcess: true)
        try await waitFor { await stub.started.count == 1 }
        model.recordingDidSave(second, autoProcess: false)
        XCTAssertEqual(model.transcriptionState, .running)
        XCTAssertEqual(model.activeTranscription?.id, first.id)
        XCTAssertEqual(model.pendingContext, "Pedbot")
        model.processLastRecording()
        XCTAssertEqual(model.queuedTranscriptions.first?.context, "Pedbot")
        await stub.finish(first.id)
        try await waitFor { await stub.started.count == 2 }
        await stub.finish(second.id)
        try await waitFor { model.activeTranscription == nil }
        XCTAssertFalse(model.canProcessNow)
    }

    func testCompletionDoesNotInterruptANewRecording() async throws {
        let stub = PipelineStub()
        let model = RecorderModel(recoverPublicationsAutomatically: false) { _, pending, _ in try await stub.run(pending) }
        model.pipelineIsReady = true
        let first = try pending("first")
        model.recordingDidSave(first, autoProcess: true)
        try await waitFor { await stub.started.count == 1 }
        model.state = .recording
        model.elapsed = 42
        await stub.finish(first.id)
        try await waitFor { model.activeTranscription == nil }
        XCTAssertEqual(model.state, .recording)
        XCTAssertEqual(model.elapsed, 42)
    }

    func testFailureKeepsJobForRetryAndContinuesQueue() async throws {
        let stub = PipelineStub()
        let model = RecorderModel(recoverPublicationsAutomatically: false) { _, pending, _ in try await stub.run(pending) }
        model.pipelineIsReady = true
        let first = try pending("first")
        let second = try pending("second")
        model.recordingDidSave(first, autoProcess: true)
        model.recordingDidSave(second, autoProcess: true)
        try await waitFor { await stub.started.count == 1 }
        await stub.finish(first.id, error: true)
        try await waitFor { await stub.started.count == 2 }
        XCTAssertEqual(model.pendingTranscriptions.first?.id, first.id)
        await stub.finish(second.id)
        try await waitFor { model.activeTranscription == nil }
        model.processLastRecording()
        try await waitFor { await stub.started.count == 3 }
        XCTAssertEqual(model.activeTranscription?.id, first.id)
        await stub.finish(first.id)
        try await waitFor { model.activeTranscription == nil }
        XCTAssertFalse(model.canProcessNow)
    }

    func testDiscardingNewCapturePreservesRunningPipeline() async throws {
        let stub = PipelineStub()
        let model = RecorderModel(recoverPublicationsAutomatically: false) { _, pending, _ in try await stub.run(pending) }
        model.pipelineIsReady = true
        let first = try pending("first")
        model.recordingDidSave(first, autoProcess: true)
        try await waitFor { await stub.started.count == 1 }
        let capture = try RecordingSession.create(now: Date(), meetingTitle: "Discard me", root: root)
        model.currentSession = capture
        model.state = .recording
        model.trashAndStop()
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(model.transcriptionState, .running)
        XCTAssertEqual(model.activeTranscription?.id, first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.folderURL.path))
        await stub.finish(first.id)
        try await waitFor { model.activeTranscription == nil }
        XCTAssertEqual(model.lastOutcome?.kind, .published)
    }

    func testUnavailablePipelineKeepsPendingRecording() throws {
        let model = RecorderModel(recoverPublicationsAutomatically: false)
        let job = try pending("first")
        model.recordingDidSave(job, autoProcess: true)
        XCTAssertTrue(model.canProcessNow)
        XCTAssertNil(model.activeTranscription)
        guard case .failed = model.transcriptionState else { return XCTFail("Expected setup error") }
    }

    func testCapturesStayHiddenUntilFinalizedAndUseUniqueFolders() throws {
        let now = Date()
        let first = try RecordingSession.create(now: now, meetingTitle: "Daily", root: root)
        let second = try RecordingSession.create(now: now, meetingTitle: "Daily", root: root)
        XCTAssertNotEqual(first.savedFolderURL, second.savedFolderURL)
        XCTAssertTrue(first.folderURL.lastPathComponent.hasPrefix(".recording-"))
        let visible = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        XCTAssertTrue(visible.isEmpty)
        try Data("complete audio".utf8).write(to: first.outputURL)
        try first.finalize()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.folderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.savedFolderURL.appendingPathComponent("audio.m4a").path))
        let (date, title) = RecordingsLibrary.parseFolderName(first.savedFolderURL.lastPathComponent)
        XCTAssertNotNil(date)
        XCTAssertEqual(title, "Daily")
    }

    func testPipelineLogDoesNotImplyPublication() {
        XCTAssertEqual(PipelineRunner.outcome(from: "nada para transcrever\nnada para resumir").kind, .nothingPending)
        XCTAssertEqual(PipelineRunner.outcome(from: "[stt] audio\nERRO: indisponível").kind, .failed)
        XCTAssertEqual(PipelineRunner.outcome(from: "[stt] audio\nsem_fala").kind, .noSpeech)
    }

    func testRenderPanelStatesWhenRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["RECORDER_RENDER_DIR"] else { return }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let model = RecorderModel(recoverPublicationsAutomatically: false)
        // Populate only in memory; no real recording, pipeline or calendar requests.
        model.availableContexts = ["Funcional", "Pedbot", "Pessoal"]
        let previousContext = Preferences.lastContext
        model.selectedContext = "Funcional"
        defer { Preferences.lastContext = previousContext }
        let now = Date()
        var meetings: [Meeting] = []
        for i in 0..<6 {
            let title = i == 0 ? "FUTURO — Reposição e planejamento de uma reunião com título comprido" : "Reunião de acompanhamento \(i)"
            let start = now.addingTimeInterval(TimeInterval(i - 1) * 1800)
            let end = now.addingTimeInterval(TimeInterval(i + 1) * 1800)
            meetings.append(Meeting(id: String(i), title: title, start: start, end: end))
        }
        model.meetings = meetings
        model.recentRecordings = (0..<6).map { i in
            RecordingEntry(id: "\(i)", source: .recorder, metaFolderURL: nil, revealURL: root, logURL: root,
                           title: "Reunião de validação de requisitos com título longo \(i)", date: now,
                           audioURL: root.appendingPathComponent("\(i).m4a"), transcriptURL: nil,
                           legacyTextURL: nil, context: "Funcional", isPrepared: false, stateIsKnown: true)
        }
        for (name, state) in [("idle", RecorderState.idle), ("recording", .recording), ("paused", .paused)] {
            model.state = state
            model.elapsed = 3672
            model.desktopLevel = 0.6
            model.micLevel = 0.35
            if state != .idle {
                let job = try pending("Reunião anterior")
                model.activeTranscription = job
                model.transcriptionState = .running
                model.queuedTranscriptions = [try pending("Próxima")]
                model.pendingTranscriptions = [try pending("Manual")]
            }
            for section in RecorderPanel.PanelSection.allCases {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    let view = NSHostingView(rootView: RecorderPanel(section: section).environment(model))
                    view.appearance = NSAppearance(named: appearance)
                    let size = view.fittingSize
                    XCTAssertEqual(size.width, 380, accuracy: 1)
                    XCTAssertLessThanOrEqual(size.height, 640)
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = view
                    window.orderFront(nil)
                    view.layoutSubtreeIfNeeded()
                    view.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                        return XCTFail("Could not render panel")
                    }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { return XCTFail("Could not encode panel") }
                    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(section.rawValue)-\(appearance.rawValue).png"))
                    window.orderOut(nil)
                }
            }
        }
    }
}
