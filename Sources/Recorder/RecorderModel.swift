import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class RecorderModel {
    var state: RecorderState = .idle
    var desktopLevel: Float = 0
    var micLevel: Float = 0
    var meetings: [Meeting] = []
    var currentSession: RecordingSession? = nil
    var elapsed: TimeInterval = 0
    var statusMessage: String? = nil

    var localSpeakerName: String = "" {
        didSet { Preferences.speakerName = localSpeakerName }
    }

    var silenceTimeout: TimeInterval = 300 {
        didSet { Preferences.silenceTimeout = silenceTimeout }
    }

    var silenceThresholdDB: Float = -50 {
        didSet { Preferences.silenceThresholdDB = silenceThresholdDB }
    }

    var silenceAutoStopEnabled: Bool = true {
        didSet { Preferences.silenceAutoStop = silenceAutoStopEnabled }
    }

    var autoProcess: Bool = false {
        didSet { Preferences.autoProcess = autoProcess }
    }

    var pipelineDir: String = Preferences.pipelineDir {
        didSet {
            Preferences.pipelineDir = pipelineDir
            refreshContexts()
        }
    }

    var availableContexts: [String] = []

    var selectedContext: String = "" {
        didSet { Preferences.lastContext = selectedContext }
    }

    var transcriptionState: TranscriptionState = .idle
    var lastTranscriptText: String? = nil
    var lastTranscriptURL: URL? = nil

    var pipelineIsReady: Bool = false

    var lastOutcome: PipelineRunner.Outcome? = nil

    var pendingDuration: TimeInterval = 0

    var pendingContext: String = ""

    var recentRecordings: [RecordingEntry] = []

    @ObservationIgnored private let tap = SystemAudioTap()
    @ObservationIgnored private let mic = MicCapture()
    @ObservationIgnored private let calendar = CalendarAccess()
    @ObservationIgnored private let notifications = NotificationManager()
    @ObservationIgnored private var silenceMonitor: SilenceMonitor?

    @ObservationIgnored private var elapsedTimer: Timer?
    @ObservationIgnored private var recordingStartedAt: Date?

    @ObservationIgnored private var activeMeeting: Meeting?

    private struct PendingTranscription {
        let audioURL: URL
        let metaFolderURL: URL?
        let logURL: URL
        let meetingTitle: String?
        let attendees: [String]
        let startedAt: Date

        let context: String
    }
    @ObservationIgnored private var lastTranscription: PendingTranscription?

    func onAppear() {
        loadPreferences()

        refreshContexts()

        refreshRecordings()

        Task { @MainActor in
            _ = await MicCapture.requestAccess()
        }
        Task { @MainActor in
            _ = await calendar.requestAccess()
            refreshMeetings()
        }
        Task { @MainActor in
            await notifications.requestAuthorization()
        }

        calendar.onChange = { [weak self] in

            self?.refreshMeetings()
        }

        notifications.onStopRequested = { [weak self] in
            guard let self else { return }
            if self.state != .idle {
                self.saveAndStop()
            }
        }

        tap.onFatalError = { [weak self] error in
            DispatchQueue.main.async {
                self?.statusMessage = "Desktop audio error: \(error.localizedDescription)"
            }
        }
        mic.onFatalError = { [weak self] error in
            DispatchQueue.main.async {
                self?.statusMessage = "Mic error: \(error.localizedDescription)"
            }
        }
    }

    private func loadPreferences() {
        localSpeakerName = Preferences.speakerName
        silenceTimeout = Preferences.silenceTimeout
        silenceThresholdDB = Preferences.silenceThresholdDB
        silenceAutoStopEnabled = Preferences.silenceAutoStop
        autoProcess = Preferences.autoProcess
        pipelineDir = Preferences.pipelineDir
    }

    func refreshContexts() {
        pipelineIsReady = PipelineRunner.resolveDocker() != nil
            && FileManager.default.fileExists(
                atPath: (pipelineDir as NSString).appendingPathComponent("docker-compose.yml")
            )
        let stored = Preferences.contexts
        let discovered = PipelineRunner.discoverContexts(pipelineDir: pipelineDir)
        availableContexts = stored.isEmpty ? discovered : stored

        let last = Preferences.lastContext
        if availableContexts.contains(last) {
            selectedContext = last
        } else {
            selectedContext = availableContexts.first ?? ""
        }
    }

    func startRecording(meeting: Meeting?) {
        guard state == .idle else { return }

        let now = Date()
        let session: RecordingSession
        do {
            session = try RecordingSession.create(now: now, meetingTitle: meeting?.title)
        } catch {
            statusMessage = "Could not create recording folder: \(error.localizedDescription)"
            return
        }
        currentSession = session
        activeMeeting = meeting

        transcriptionState = .idle
        lastTranscriptText = nil
        lastTranscriptURL = nil
        lastTranscription = nil

        if silenceAutoStopEnabled {
            silenceMonitor = SilenceMonitor(
                thresholdDB: silenceThresholdDB,
                timeout: silenceTimeout,
                onTimeout: { [weak self] in

                    self?.saveAndStop()
                }
            )
        } else {
            silenceMonitor = nil
        }

        tap.onLevelDB = { [weak self] db in
            DispatchQueue.main.async {
                guard let self else { return }
                self.desktopLevel = meterLevel(fromDB: db)
                self.silenceMonitor?.noteLevel(db)
            }
        }
        mic.onLevelDB = { [weak self] db in
            DispatchQueue.main.async {
                guard let self else { return }
                self.micLevel = meterLevel(fromDB: db)
                self.silenceMonitor?.noteLevel(db)
            }
        }

        do {
            try tap.start(writingTo: session.desktopURL)
            try mic.start(writingTo: session.micURL)
        } catch {
            statusMessage = "Could not start capture: \(error.localizedDescription)"
            _ = tap.stop()
            _ = mic.stop()
            currentSession = nil
            silenceMonitor = nil
            return
        }

        silenceMonitor?.start()

        if let meeting {
            notifications.scheduleMeetingEndAlert(at: meeting.end, meetingTitle: meeting.title)
        }

        state = .recording
        statusMessage = nil
        startElapsedTimer(from: now)
    }

    func togglePause() {
        switch state {
        case .recording:
            tap.setPaused(true)
            mic.setPaused(true)
            silenceMonitor?.stop()
            state = .paused
        case .paused:
            tap.setPaused(false)
            mic.setPaused(false)
            silenceMonitor?.start()
            state = .recording
        case .idle:
            break
        }
    }

    func saveAndStop() {
        guard state != .idle, let session = currentSession else {
            resetToIdle()
            return
        }

        let desktopResult = tap.stop()
        let micResult = mic.stop()

        cancelTimersAndAlerts()
        state = .idle
        statusMessage = "Mixing…"

        let outputURL = session.outputURL
        let desktopURL = session.desktopURL
        let micURL = session.micURL
        let folderURL = session.folderURL
        let startedAt = session.startedAt
        let meetingTitle = activeMeeting?.title ?? session.meetingTitle
        let attendees = activeMeeting?.attendees ?? []
        let chosenContext = selectedContext
        Task.detached(priority: .utility) {
            do {
                try StereoMixer.mix(
                    desktopURL: desktopURL,
                    micURL: micURL,
                    desktopResult: desktopResult,
                    micResult: micResult,
                    outputURL: outputURL
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let pending = PendingTranscription(
                        audioURL: outputURL,
                        metaFolderURL: folderURL,
                        logURL: folderURL.appendingPathComponent("pipeline.log"),
                        meetingTitle: meetingTitle,
                        attendees: attendees,
                        startedAt: startedAt,
                        context: chosenContext
                    )

                    try? PipelineRunner.writeMeta(
                        folderURL: folderURL,
                        context: PipelineRunner.Context(
                            context: chosenContext,
                            meetingTitle: meetingTitle,
                            attendees: attendees,
                            startedAt: startedAt,
                            localSpeakerName: nil
                        )
                    )
                    if self.autoProcess {
                        self.statusMessage = "Saved \(outputURL.lastPathComponent)"
                        self.startTranscription(pending)
                    } else {
                        self.lastTranscription = pending
                        self.pendingContext = chosenContext
                        self.transcriptionState = .idle
                        self.statusMessage = "Saved \(outputURL.lastPathComponent) · pronta para processar"
                    }
                    self.refreshRecordings()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.statusMessage = "Mix failed (raw files kept): \(error.localizedDescription)"
                }
            }
        }

        currentSession = nil
        activeMeeting = nil
        silenceMonitor = nil
    }

    func trashAndStop() {
        guard state != .idle else {
            resetToIdle()
            return
        }

        _ = tap.stop()
        _ = mic.stop()

        cancelTimersAndAlerts()

        if let session = currentSession {
            try? FileManager.default.removeItem(at: session.folderURL)
        }

        state = .idle
        currentSession = nil
        activeMeeting = nil
        silenceMonitor = nil
        statusMessage = "Discarded"
        transcriptionState = .idle
        lastTranscriptText = nil
        lastTranscriptURL = nil
        lastTranscription = nil
        refreshRecordings()
    }

    func refreshMeetings() {
        let now = Date()
        meetings = calendar.meetingsAroundNow(now)
    }

    var currentMeeting: Meeting? {
        let now = Date()
        return meetings.first(where: { $0.isInProgress(now) })
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func startElapsedTimer(from start: Date) {
        recordingStartedAt = start
        elapsed = 0
        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let started = self.recordingStartedAt else { return }
                if self.state == .recording {
                    self.elapsed = Date().timeIntervalSince(started)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func cancelTimersAndAlerts() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartedAt = nil
        silenceMonitor?.stop()
        notifications.cancelMeetingEndAlert()
    }

    private func resetToIdle() {
        cancelTimersAndAlerts()
        state = .idle
        currentSession = nil
        activeMeeting = nil
        silenceMonitor = nil
        elapsed = 0
    }

    var canProcessNow: Bool {
        lastTranscription != nil && transcriptionState != .running
    }

    func processLastRecording() {
        guard let pending = lastTranscription else { return }

        startTranscription(PendingTranscription(
            audioURL: pending.audioURL,
            metaFolderURL: pending.metaFolderURL,
            logURL: pending.logURL,
            meetingTitle: pending.meetingTitle,
            attendees: pending.attendees,
            startedAt: pending.startedAt,
            context: selectedContext.isEmpty ? pending.context : selectedContext
        ))
    }

    func retryTranscription() {
        guard let pending = lastTranscription else { return }
        startTranscription(pending)
    }

    private func startTranscription(_ pending: PendingTranscription) {
        lastTranscription = pending
        lastTranscriptText = nil
        lastTranscriptURL = nil
        lastOutcome = nil

        guard pipelineIsReady else {
            transcriptionState = .failed(
                "Pipeline indisponível: confira se o Docker está aberto e se a pasta em Settings aponta para o repo transcribe."
            )
            statusMessage = "Saved (pipeline não acionada)"
            return
        }
        guard !pending.context.isEmpty else {
            transcriptionState = .failed(
                "Nenhum contexto escolhido. Crie uma subpasta em ~/Movies/OBS e escolha no painel."
            )
            statusMessage = "Saved (sem contexto)"
            return
        }

        transcriptionState = .running
        statusMessage = "Processando na pipeline local…"

        let runner = PipelineRunner(pipelineDir: pipelineDir)
        let trimmedName = localSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = PipelineRunner.Context(
            context: pending.context,
            meetingTitle: pending.meetingTitle,
            attendees: pending.attendees,
            startedAt: pending.startedAt,
            localSpeakerName: trimmedName.isEmpty ? nil : trimmedName
        )

        Task { [weak self] in
            do {
                let output = try await Task.detached(priority: .utility) {
                    try await runner.run(metaFolderURL: pending.metaFolderURL, context: context)
                }.value

                let logURL = pending.logURL
                try? output.write(to: logURL, atomically: true, encoding: .utf8)
                await MainActor.run {
                    guard let self else { return }
                    let outcome = PipelineRunner.outcome(from: output)
                    self.lastTranscriptText = output
                    self.lastTranscriptURL = logURL
                    self.lastOutcome = outcome
                    self.transcriptionState = .done(logURL)
                    self.statusMessage = outcome.headline
                    self.refreshRecordings()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.transcriptionState = .failed(
                        error.localizedDescription
                    )
                    self.statusMessage = "Pipeline falhou"
                }
            }
        }
    }

    func copyTranscriptText() {
        guard let text = lastTranscriptText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusMessage = "Transcript text copied"
    }

    func copyTranscriptFile() {
        guard let url = lastTranscriptURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        statusMessage = "Transcript file copied"
    }

    func revealTranscript() {
        guard let url = lastTranscriptURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func refreshRecordings() {
        recentRecordings = RecordingsLibrary.recent(
            limit: 6,
            obsRoot: PipelineRunner.mediaRoot(pipelineDir: pipelineDir)
        )
    }

    func transcribeExisting(_ entry: RecordingEntry) {
        guard let audio = entry.audioURL else {
            statusMessage = "Sem arquivo de mídia para processar nessa gravação."
            return
        }

        let ctx: String
        if let metaFolder = entry.metaFolderURL {
            ctx = RecorderModel.contextFromMeta(metaFolder) ?? entry.context ?? selectedContext
        } else {
            ctx = entry.context ?? selectedContext
        }

        startTranscription(PendingTranscription(
            audioURL: audio,
            metaFolderURL: entry.metaFolderURL,
            logURL: entry.logURL,
            meetingTitle: entry.source == .obs ? nil : entry.title,
            attendees: [],
            startedAt: entry.date,
            context: ctx
        ))
    }

    func copyFileToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        statusMessage = "Copied \(url.lastPathComponent)"
    }

    func copyTextOfFile(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            statusMessage = "Could not read \(url.lastPathComponent)"
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusMessage = "Copied text of \(url.lastPathComponent)"
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openRecordingsFolder() {
        guard let root = RecordingsLibrary.recordingsRoot() else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func contextFromMeta(_ folderURL: URL) -> String? {
        let url = folderURL.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ctx = obj["context"] as? String,
              !ctx.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return ctx
    }
}
