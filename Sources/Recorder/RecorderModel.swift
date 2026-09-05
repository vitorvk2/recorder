import Foundation
import Observation
import AppKit

/// Owns every component and wires their callbacks. The model is @MainActor;
/// audio-thread callbacks hop to main via DispatchQueue.main.async before touching state.
@MainActor
@Observable
final class RecorderModel {

    // MARK: - Observable UI state

    var state: RecorderState = .idle
    var desktopLevel: Float = 0      // 0..1 meter (LEFT / desktop)
    var micLevel: Float = 0          // 0..1 meter (RIGHT / mic)
    var meetings: [Meeting] = []
    var currentSession: RecordingSession? = nil
    var elapsed: TimeInterval = 0
    var statusMessage: String? = nil

    // MARK: - Persisted preferences (mirrored to UserDefaults via Preferences)

    /// Your name — labels the local (mic / right-channel) voice in transcripts.
    /// Empty = omit. Replaces the old hardcoded speaker name.
    var localSpeakerName: String = "" {
        didSet { Preferences.speakerName = localSpeakerName }
    }
    /// Auto-stop after this many seconds of two-channel silence.
    var silenceTimeout: TimeInterval = 300 {
        didSet { Preferences.silenceTimeout = silenceTimeout }
    }
    /// dBFS below which a channel is considered silent.
    var silenceThresholdDB: Float = -50 {
        didSet { Preferences.silenceThresholdDB = silenceThresholdDB }
    }
    /// Whether silence auto-stop runs at all.
    var silenceAutoStopEnabled: Bool = true {
        didSet { Preferences.silenceAutoStop = silenceAutoStopEnabled }
    }
    /// Whether to run the pipeline automatically after a recording is saved.
    /// Off by default: the pipeline publishes to Notion, which is a bigger
    /// side effect than the local transcript file this replaced.
    var autoProcess: Bool = false {
        didSet { Preferences.autoProcess = autoProcess }
    }
    /// Directory of the `transcribe` repo.
    var pipelineDir: String = Preferences.pipelineDir {
        didSet {
            Preferences.pipelineDir = pipelineDir
            refreshContexts()
        }
    }
    /// Contexts offered in the picker — the subfolders of the pipeline's media root.
    var availableContexts: [String] = []
    /// Context that the next recording will be filed under.
    var selectedContext: String = "" {
        didSet { Preferences.lastContext = selectedContext }
    }

    // Pipeline (post-save).
    var transcriptionState: TranscriptionState = .idle
    var lastTranscriptText: String? = nil
    var lastTranscriptURL: URL? = nil
    /// Whether the pipeline can actually be invoked (docker + compose present).
    var pipelineIsReady: Bool = false
    /// Result of the last run, in a form the panel can show: the meeting
    /// title and a link, instead of the raw page id the log carries.
    var lastOutcome: PipelineRunner.Outcome? = nil
    /// Duration of the recording waiting to be processed, for the panel.
    var pendingDuration: TimeInterval = 0
    /// Context the pending recording was saved under.
    var pendingContext: String = ""

    /// The most recent recordings on disk (loaded at launch + after changes).
    var recentRecordings: [RecordingEntry] = []

    // MARK: - Heavy / audio objects (not observation-tracked)

    @ObservationIgnored private let tap = SystemAudioTap()
    @ObservationIgnored private let mic = MicCapture()
    @ObservationIgnored private let calendar = CalendarAccess()
    @ObservationIgnored private let notifications = NotificationManager()
    @ObservationIgnored private var silenceMonitor: SilenceMonitor?

    @ObservationIgnored private var elapsedTimer: Timer?
    @ObservationIgnored private var recordingStartedAt: Date?

    /// The meeting (if any) the current recording is attached to — kept so its
    /// title + attendees are available as transcription context at save time.
    @ObservationIgnored private var activeMeeting: Meeting?

    /// Everything needed to (re)run a transcription, captured at save time.
    private struct PendingTranscription {
        let audioURL: URL
        let folderURL: URL
        let meetingTitle: String?
        let attendees: [String]
        let startedAt: Date
        /// Chosen when the recording was saved, so a retry never re-asks.
        let context: String
    }
    @ObservationIgnored private var lastTranscription: PendingTranscription?

    // MARK: - Lifecycle

    func onAppear() {
        // Load persisted preferences first so the UI reflects them immediately.
        loadPreferences()

        // Which contexts exist, and whether the pipeline can be invoked at all.
        refreshContexts()

        // Load prior recordings from disk so they survive restarts.
        refreshRecordings()

        // Request permissions concurrently, then load meetings.
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

        // Refetch meetings on calendar changes.
        calendar.onChange = { [weak self] in
            // onChange is delivered on main (CalendarAccess is @MainActor).
            self?.refreshMeetings()
        }

        // A user tapping "Stop Recording" in the meeting-end notification stops + saves.
        notifications.onStopRequested = { [weak self] in
            guard let self else { return }
            if self.state != .idle {
                self.saveAndStop()
            }
        }

        // Surface fatal capture errors to the UI.
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

    /// Pull persisted preferences into the observable properties. The `didSet`
    /// write-backs are idempotent (same value in → same value out).
    private func loadPreferences() {
        localSpeakerName = Preferences.speakerName
        silenceTimeout = Preferences.silenceTimeout
        silenceThresholdDB = Preferences.silenceThresholdDB
        silenceAutoStopEnabled = Preferences.silenceAutoStop
        autoProcess = Preferences.autoProcess
        pipelineDir = Preferences.pipelineDir
    }

    /// Whether the prompt differs from the built-in default (drives the Reset button).
    /// Re-read the contexts from disk and whether docker is reachable.
    func refreshContexts() {
        pipelineIsReady = PipelineRunner.resolveDocker() != nil
            && FileManager.default.fileExists(
                atPath: (pipelineDir as NSString).appendingPathComponent("docker-compose.yml")
            )
        let stored = Preferences.contexts
        let discovered = PipelineRunner.discoverContexts(pipelineDir: pipelineDir)
        availableContexts = stored.isEmpty ? discovered : stored
        // Keep the previous choice when it still exists; otherwise fall back to
        // the first context so the picker is never empty-but-required.
        let last = Preferences.lastContext
        if availableContexts.contains(last) {
            selectedContext = last
        } else {
            selectedContext = availableContexts.first ?? ""
        }
    }

    // MARK: - Recording control

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

        // Clear any previous recording's transcription UI.
        transcriptionState = .idle
        lastTranscriptText = nil
        lastTranscriptURL = nil
        lastTranscription = nil

        // Silence monitor (auto-stop after prolonged silence on both channels).
        // Only armed when the user has auto-stop enabled.
        if silenceAutoStopEnabled {
            silenceMonitor = SilenceMonitor(
                thresholdDB: silenceThresholdDB,
                timeout: silenceTimeout,
                onTimeout: { [weak self] in
                    // onTimeout is invoked on MAIN per contract.
                    self?.saveAndStop()
                }
            )
        } else {
            silenceMonitor = nil
        }

        // Wire level callbacks (called on audio threads -> hop to main).
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

        // Start both captures.
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

        // Schedule a meeting-end alert when recording a known meeting.
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

        // Mix off the main actor; keep raw CAFs regardless of outcome.
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
                        folderURL: folderURL,
                        meetingTitle: meetingTitle,
                        attendees: attendees,
                        startedAt: startedAt,
                        context: chosenContext
                    )
                    // O meta.json e escrito SEMPRE, mesmo sem auto-process: e o
                    // que preserva a escolha de contexto para quando a pipeline
                    // for acionada depois, pelo botao.
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
                        // Pipeline manual: a gravacao fica pronta e o botao
                        // "Processar" no painel a envia quando voce quiser.
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

    /// The meeting currently in progress, if any. All-day events are already
    /// excluded from `meetings`, so this only matches timed meetings. Used as the
    /// default target for the main Record button so recording while you're in a
    /// meeting auto-tags it (folder name + end alert + transcription context).
    var currentMeeting: Meeting? {
        let now = Date()
        return meetings.first(where: { $0.isInProgress(now) })
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

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

    // MARK: - Pipeline

    /// Whether there is a saved recording waiting to be sent to the pipeline.
    var canProcessNow: Bool {
        lastTranscription != nil && transcriptionState != .running
    }

    /// Send the last saved recording to the pipeline — the panel's button.
    func processLastRecording() {
        guard let pending = lastTranscription else { return }
        // Recria com o contexto atual do picker: entre salvar e clicar, voce
        // pode ter percebido que escolheu a pasta errada.
        startTranscription(PendingTranscription(
            audioURL: pending.audioURL,
            folderURL: pending.folderURL,
            meetingTitle: pending.meetingTitle,
            attendees: pending.attendees,
            startedAt: pending.startedAt,
            context: selectedContext.isEmpty ? pending.context : selectedContext
        ))
    }

    /// Re-run the pipeline on the last recording (after a failure).
    ///
    /// Reuses the context chosen at save time, so a retry never asks again.
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
                // Fora da main actor: a pipeline leva minutos (Whisper + resumo
                // + Notion) e travaria a UI inteira aqui.
                let output = try await Task.detached(priority: .utility) {
                    try await runner.run(folderURL: pending.folderURL, context: context)
                }.value
                // O log da rodada fica ao lado da gravação: é o que explica por
                // que uma ata saiu com determinado título ou foi marcada
                // sem_fala, sem precisar reproduzir a execução.
                let logURL = pending.folderURL.appendingPathComponent("pipeline.log")
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

    /// Copy the transcript text to the clipboard.
    func copyTranscriptText() {
        guard let text = lastTranscriptText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusMessage = "Transcript text copied"
    }

    /// Copy the transcript *file* to the clipboard (paste into Finder / Mail / etc.).
    func copyTranscriptFile() {
        guard let url = lastTranscriptURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        statusMessage = "Transcript file copied"
    }

    /// Reveal the transcript in Finder.
    func revealTranscript() {
        guard let url = lastTranscriptURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Recordings library

    /// Reload the recent-recordings list from disk.
    func refreshRecordings() {
        recentRecordings = RecordingsLibrary.recent(limit: 4)
    }

    /// Transcribe (or re-transcribe) an existing recording's audio.
    func transcribeExisting(_ entry: RecordingEntry) {
        guard let audio = entry.audioURL else {
            statusMessage = "No audio.m4a to transcribe in that folder."
            return
        }
        // Uma gravacao antiga pode ja ter um meta.json com o contexto
        // escolhido na epoca; respeita-lo evita refilar no lugar errado.
        let ctx = RecorderModel.contextFromMeta(entry.folderURL) ?? selectedContext
        startTranscription(PendingTranscription(
            audioURL: audio,
            folderURL: entry.folderURL,
            meetingTitle: entry.title,
            attendees: [],
            startedAt: entry.date,
            context: ctx
        ))
    }

    /// Put a file on the clipboard (paste into Finder / Mail / …).
    func copyFileToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        statusMessage = "Copied \(url.lastPathComponent)"
    }

    /// Put a text file's contents on the clipboard.
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

    /// Reveal an arbitrary file/folder in Finder.
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Open ~/Documents/Recordings in Finder (creating it if needed).
    func openRecordingsFolder() {
        guard let root = RecordingsLibrary.recordingsRoot() else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    /// Wrap the model's Markdown with a small header (title / date / attendees).
    /// Context recorded in a folder's meta.json, if any.
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
