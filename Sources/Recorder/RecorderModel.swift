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

    var pendingTranscriptions: [PendingTranscription] = []
    var queuedTranscriptions: [PendingTranscription] = []
    var activeTranscription: PendingTranscription?
    var mixingCount = 0

    var pendingContext: String { pendingTranscriptions.first?.context ?? "" }
    var processingTitle: String {
        activeTranscription?.meetingTitle ?? activeTranscription?.context ?? "Gravação"
    }

    // Injected in tests so queue behavior can be verified without Docker or publishing.
    @ObservationIgnored private let runPipeline: (PipelineRunner, PendingTranscription, PipelineRunner.Context) async throws -> String
    @ObservationIgnored private var didInitialize = false
    @ObservationIgnored private var recordingContext = ""
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var pausedDuration: TimeInterval = 0

    @ObservationIgnored private let recoverPublicationsAutomatically: Bool

    init(recoverPublicationsAutomatically: Bool = true, runPipeline: @escaping (PipelineRunner, PendingTranscription, PipelineRunner.Context) async throws -> String = { runner, pending, context in
        try await runner.run(metaFolderURL: pending.metaFolderURL, mediaURL: pending.audioURL, context: context)
    }) {
        self.runPipeline = runPipeline
        self.recoverPublicationsAutomatically = recoverPublicationsAutomatically
    }

    var recentRecordings: [RecordingEntry] = []
    var isLookingUpPublications = false

    @ObservationIgnored private let tap = SystemAudioTap()
    @ObservationIgnored private let mic = MicCapture()
    @ObservationIgnored private let calendar = CalendarAccess()
    @ObservationIgnored private let notifications = NotificationManager()
    @ObservationIgnored private var silenceMonitor: SilenceMonitor?

    @ObservationIgnored private var elapsedTimer: Timer?
    @ObservationIgnored private var recordingStartedAt: Date?

    @ObservationIgnored private var activeMeeting: Meeting?

    struct PendingTranscription: Identifiable {
        var id: URL { audioURL }
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
        guard !didInitialize else {
            refreshContexts()
            refreshRecordings()
            refreshMeetings()
            return
        }
        didInitialize = true
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
                self?.statusMessage = "Erro no áudio do sistema: \(error.localizedDescription)"
            }
        }
        mic.onFatalError = { [weak self] error in
            DispatchQueue.main.async {
                self?.statusMessage = "Erro no microfone: \(error.localizedDescription)"
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
            statusMessage = "Não foi possível criar a pasta da gravação: \(error.localizedDescription)"
            return
        }
        currentSession = session
        activeMeeting = meeting

        recordingContext = selectedContext

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
            statusMessage = "Não foi possível iniciar a gravação: \(error.localizedDescription)"
            _ = tap.stop()
            _ = mic.stop()
            resetToIdle()
            try? FileManager.default.removeItem(at: session.folderURL)
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
            elapsed = recordingStartedAt.map { Date().timeIntervalSince($0) - pausedDuration } ?? elapsed
            pausedAt = Date()
            state = .paused
        case .paused:
            tap.setPaused(false)
            mic.setPaused(false)
            silenceMonitor?.start()
            if let pausedAt { pausedDuration += Date().timeIntervalSince(pausedAt) }
            pausedAt = nil
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
        statusMessage = nil
        desktopLevel = 0
        micLevel = 0
        mixingCount += 1

        let outputURL = session.outputURL
        let desktopURL = session.desktopURL
        let micURL = session.micURL
        let folderURL = session.folderURL
        let startedAt = session.startedAt
        let meetingTitle = activeMeeting?.title ?? session.meetingTitle
        let attendees = activeMeeting?.attendees ?? []
        let chosenContext = recordingContext
        let shouldAutoProcess = autoProcess
        Task.detached(priority: .utility) {
            do {
                try StereoMixer.mix(
                    desktopURL: desktopURL,
                    micURL: micURL,
                    desktopResult: desktopResult,
                    micResult: micResult,
                    outputURL: outputURL
                )
                try PipelineRunner.writeMeta(
                    folderURL: folderURL,
                    context: PipelineRunner.Context(
                        context: chosenContext, meetingTitle: meetingTitle,
                        attendees: attendees, startedAt: startedAt, localSpeakerName: nil
                    )
                )
                // The importer must never see live or half-mixed capture files.
                try session.finalize()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.mixingCount -= 1
                    let savedFolder = session.savedFolderURL
                    let pending = PendingTranscription(
                        audioURL: savedFolder.appendingPathComponent("audio.m4a"),
                        metaFolderURL: savedFolder,
                        logURL: savedFolder.appendingPathComponent("pipeline.log"),
                        meetingTitle: meetingTitle, attendees: attendees,
                        startedAt: startedAt, context: chosenContext
                    )
                    self.recordingDidSave(pending, autoProcess: shouldAutoProcess)
                    self.refreshRecordings()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.mixingCount -= 1
                    self?.statusMessage = "Não foi possível salvar o áudio. Os arquivos originais estão em \(folderURL.path): \(error.localizedDescription)"
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
        desktopLevel = 0
        micLevel = 0
        elapsed = 0
        statusMessage = "Gravação descartada"
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
        pausedAt = nil
        pausedDuration = 0
        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let started = self.recordingStartedAt else { return }
                if self.state == .recording {
                    self.elapsed = Date().timeIntervalSince(started) - self.pausedDuration
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
        pausedAt = nil
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

    var canProcessNow: Bool { !pendingTranscriptions.isEmpty }

    func recordingDidSave(_ pending: PendingTranscription, autoProcess: Bool) {
        guard activeTranscription?.id != pending.id,
              !queuedTranscriptions.contains(where: { $0.id == pending.id }) else { return }
        if !pendingTranscriptions.contains(where: { $0.id == pending.id }) {
            pendingTranscriptions.append(pending)
        }
        if autoProcess { startTranscription(pending) }
    }

    func processLastRecording() {
        guard let pending = pendingTranscriptions.first else { return }
        startTranscription(pending)
    }

    func retryTranscription() {
        guard let pending = lastTranscription else { return }
        startTranscription(pending)
    }

    private func startTranscription(_ requested: PendingTranscription) {
        let pending = requested.context.isEmpty ? PendingTranscription(
            audioURL: requested.audioURL, metaFolderURL: requested.metaFolderURL,
            logURL: requested.logURL, meetingTitle: requested.meetingTitle,
            attendees: requested.attendees, startedAt: requested.startedAt, context: selectedContext
        ) : requested
        guard activeTranscription?.id != pending.id,
              !queuedTranscriptions.contains(where: { $0.id == pending.id }) else { return }
        guard pipelineIsReady else {
            if activeTranscription == nil {
                transcriptionState = .failed("Processamento indisponível. Confira o Docker e a pasta da pipeline nos Ajustes.")
            }
            return
        }
        guard !pending.context.isEmpty else {
            if activeTranscription == nil {
                transcriptionState = .failed("Escolha um contexto nos Ajustes antes de processar.")
            }
            return
        }

        pendingTranscriptions.removeAll { $0.id == pending.id }
        queuedTranscriptions.append(pending)
        runNextTranscription()
    }

    private func runNextTranscription() {
        guard activeTranscription == nil, !queuedTranscriptions.isEmpty else { return }
        let pending = queuedTranscriptions.removeFirst()
        activeTranscription = pending
        lastTranscription = pending
        lastTranscriptText = nil
        lastTranscriptURL = nil
        lastOutcome = nil
        transcriptionState = .running

        let runner = PipelineRunner(pipelineDir: pipelineDir)
        let operation = runPipeline
        let trimmedName = localSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = PipelineRunner.Context(
            context: pending.context, meetingTitle: pending.meetingTitle,
            attendees: pending.attendees, startedAt: pending.startedAt,
            localSpeakerName: trimmedName.isEmpty ? nil : trimmedName
        )

        Task { [weak self] in
            do {
                let output = try await Task.detached(priority: .utility) {
                    try await operation(runner, pending, context)
                }.value
                try output.write(to: pending.logURL, atomically: true, encoding: .utf8)
                guard let self else { return }
                let outcome = PipelineRunner.outcome(from: output)
                if let url = outcome.noteURL { try? PublicationStore.save(url, for: pending.logURL) }
                self.lastTranscriptText = output
                self.lastTranscriptURL = pending.logURL
                self.lastOutcome = outcome
                self.transcriptionState = outcome.kind == .failed
                    ? .failed(outcome.headline) : .done(pending.logURL)
                if outcome.kind == .failed { self.restorePending(pending) }
                self.activeTranscription = nil
                self.refreshRecordings()
                self.runNextTranscription()
            } catch {
                guard let self else { return }
                let failureLog: String
                if case PipelineRunner.Failure.exited(_, let output) = error {
                    failureLog = output
                } else {
                    failureLog = "ERRO: " + error.localizedDescription
                }
                try? failureLog.write(to: pending.logURL, atomically: true, encoding: .utf8)
                self.lastTranscriptText = failureLog
                self.lastTranscriptURL = pending.logURL
                self.lastOutcome = .init(kind: .failed, headline: error.localizedDescription, noteURL: nil)
                self.transcriptionState = .failed(error.localizedDescription)
                self.restorePending(pending)
                self.activeTranscription = nil
                self.refreshRecordings()
                self.runNextTranscription()
            }
        }
    }

    private func restorePending(_ pending: PendingTranscription) {
        if !pendingTranscriptions.contains(where: { $0.id == pending.id }) {
            pendingTranscriptions.append(pending)
        }
    }

    func copyTranscriptText() {
        guard let text = lastTranscriptText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusMessage = "Log copiado"
    }

    func copyTranscriptFile() {
        guard let url = lastTranscriptURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        statusMessage = "Arquivo de log copiado"
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
        guard recoverPublicationsAutomatically else { return }
        // Migrate existing successful logs to a durable publication record.
        for entry in recentRecordings {
            if let url = entry.noteURL { try? PublicationStore.save(url, for: entry.logURL) }
        }
        if pipelineIsReady { recoverPublishedNotes() }
    }

    func openPublishedNote(_ entry: RecordingEntry) {
        if let url = entry.noteURL { NSWorkspace.shared.open(url) }
        else { recoverPublishedNotes(openEntryID: entry.id) }
    }

    private func recoverPublishedNotes(openEntryID: String? = nil) {
        guard !isLookingUpPublications else { return }
        let entries = recentRecordings.filter { $0.noteURL == nil }
        let mediaRoot = PipelineRunner.mediaRoot(pipelineDir: pipelineDir)
        let requests = entries.compactMap { PublicationStore.request(for: $0, mediaRoot: mediaRoot) }
        guard !requests.isEmpty else { return }
        isLookingUpPublications = true
        let directory = pipelineDir
        Task { [weak self] in
            defer { self?.isLookingUpPublications = false }
            do {
                let urls = try await Task.detached(priority: .utility) {
                    let urls = try PublicationStore.lookup(requests, pipelineDir: directory)
                    for entry in entries {
                        if let url = urls[entry.id] { try? PublicationStore.save(url, for: entry.logURL) }
                    }
                    return urls
                }.value
                guard let self else { return }
                for index in self.recentRecordings.indices {
                    if let url = urls[self.recentRecordings[index].id] {
                        self.recentRecordings[index].publicationURL = url
                    }
                }
                if let id = openEntryID {
                    if let url = urls[id] { NSWorkspace.shared.open(url) }
                    else { self.statusMessage = "Esta gravação ainda não tem uma ata publicada na pipeline." }
                }
            } catch {
                if openEntryID != nil { self?.statusMessage = error.localizedDescription }
            }
        }
    }

    func isScheduled(_ entry: RecordingEntry) -> Bool {
        guard let audio = entry.audioURL else { return false }
        return activeTranscription?.audioURL == audio
            || queuedTranscriptions.contains { $0.audioURL == audio }
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
        statusMessage = "Arquivo copiado: \(url.lastPathComponent)"
    }

    func copyTextOfFile(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            statusMessage = "Não foi possível ler \(url.lastPathComponent)"
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusMessage = "Texto copiado: \(url.lastPathComponent)"
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
