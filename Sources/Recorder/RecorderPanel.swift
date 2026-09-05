import SwiftUI
import AppKit

struct RecorderPanel: View {
    @Environment(RecorderModel.self) private var model

    private let panelWidth: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            actionZone

            Divider()

            meters

            Divider()

            meetingsSection

            if !model.recentRecordings.isEmpty {
                Divider()
                recentSection
            }

            footer
        }
        .padding(14)
        .frame(width: panelWidth)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: stateSymbolName)
                .foregroundStyle(stateColor)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)

            Text(stateLabel)
                .font(.headline)

            Spacer(minLength: 8)

            if model.state != .idle {
                Text(formattedElapsed(model.elapsed))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(model.state == .paused ? .secondary : .primary)
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var actionZone: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.state {
            case .idle:
                if !model.availableContexts.isEmpty {
                    contextRow
                }
                if model.transcriptionState == .running {
                    runningRow
                } else if let outcome = model.lastOutcome {
                    resultRow(outcome)
                    recordButton(prominent: true)
                } else if model.canProcessNow {
                    pendingRow
                    recordButton(prominent: false)
                } else {
                    recordButton(prominent: true)
                }

            case .recording, .paused:
                recordingControls
            }
        }
    }

    private var contextRow: some View {
        HStack(spacing: 8) {
            Text("Gravar em")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { model.selectedContext },
                set: { model.selectedContext = $0 }
            )) {
                ForEach(model.availableContexts, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
        }
    }

    @ViewBuilder
    private func recordButton(prominent: Bool) -> some View {
        let label = Label("Gravar", systemImage: "record.circle.fill")
            .frame(maxWidth: .infinity)
        if prominent {
            Button { model.startRecording(meeting: nil) } label: { label }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut("r", modifiers: [.command])
        } else {
            Button { model.startRecording(meeting: nil) } label: { label }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .tint(.red)
                .keyboardShortcut("r", modifiers: [.command])
        }
    }

    private var pendingRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Gravação pronta")
                    .font(.callout.weight(.medium))
                Text(model.pendingContext.isEmpty ? "sem contexto" : model.pendingContext)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                model.processLastRecording()
            } label: {
                Text("Processar")
            }
            .buttonStyle(.borderedProminent)
            .tint(.indigo)
            .disabled(!model.pipelineIsReady)
            .keyboardShortcut("p", modifiers: [.command])
            .help(model.pipelineIsReady
                  ? "Transcreve, resume e publica no Notion"
                  : "Abra o Docker Desktop e confira a pasta em Settings")
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var runningRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Processando…")
                    .font(.callout.weight(.medium))
                Text("transcrevendo, resumindo e publicando")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func resultRow(_ outcome: PipelineRunner.Outcome) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: outcome.notionURL == nil
                  ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(outcome.notionURL == nil ? .orange : .green)
            VStack(alignment: .leading, spacing: 3) {
                Text(outcome.headline)
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = outcome.notionURL {
                    Link(destination: url) {
                        Label("Abrir no Notion", systemImage: "arrow.up.forward.square")
                            .font(.caption)
                    }
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button("Copiar log") { model.copyTranscriptText() }
                Button("Mostrar no Finder") { model.revealTranscript() }
                if model.pipelineIsReady {
                    Divider()
                    Button("Processar de novo") { model.retryTranscription() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private var recordingControls: some View {
        HStack(spacing: 8) {
            Button {
                model.togglePause()
            } label: {
                Label(
                    model.state == .paused ? "Continuar" : "Pausar",
                    systemImage: model.state == .paused ? "play.fill" : "pause.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .tint(.orange)

            Button {
                model.saveAndStop()
            } label: {
                Label("Salvar", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            Button(role: .destructive) {
                model.trashAndStop()
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.large)
            .buttonStyle(.bordered)
            .tint(.red)
            .help("Descartar esta gravação")
        }
    }

    private var stateLabel: String {
        switch model.state {
        case .idle:      return "Pronto"
        case .recording: return "Gravando"
        case .paused:    return "Pausado"
        }
    }

    private var stateSymbolName: String {
        switch model.state {
        case .idle:      return "circle"
        case .recording: return "record.circle.fill"
        case .paused:    return "pause.circle.fill"
        }
    }

    private var stateColor: Color {
        switch model.state {
        case .idle:      return .secondary
        case .recording: return .red
        case .paused:    return .orange
        }
    }

    private func transcriptDragHandle(_ url: URL) -> some View {
        let folder = url.deletingLastPathComponent().lastPathComponent
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .font(.caption)
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.forward.app")
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onDrag {
            NSItemProvider(contentsOf: url) ?? NSItemProvider()
        } preview: {
            Label(url.lastPathComponent, systemImage: "doc.text")
                .padding(8)
        }
        .help("Drag \(folder)/\(url.lastPathComponent) into another app or window")
    }

    private var meters: some View {
        VStack(alignment: .leading, spacing: 8) {
            LevelMeter(label: "Sistema",   level: model.desktopLevel, tint: .green)
            LevelMeter(label: "Microfone", level: model.micLevel,     tint: .blue)
        }
    }

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Agenda")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    model.refreshMeetings()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh meetings")
            }

            if model.meetings.isEmpty {
                Text("No meetings nearby.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                VStack(spacing: 4) {
                    ForEach(model.meetings) { meeting in
                        MeetingRow(
                            meeting: meeting,
                            inProgress: meeting.isInProgress(Date()),
                            canStart: model.state == .idle,
                            onRecord: { model.startRecording(meeting: meeting) }
                        )
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Gravações recentes")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 2) {
                ForEach(model.recentRecordings) { entry in
                    recentRow(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func recentRow(_ entry: RecordingEntry) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: entry.hasTranscript ? "checkmark.circle.fill" : "waveform.circle.fill")
                    .foregroundStyle(entry.hasTranscript ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayTitle)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(recentSubtitle(entry))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if entry.hasTranscript {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
            }
            .contentShape(Rectangle())
            .onDrag { recentDragProvider(entry) }
            .help(entry.hasTranscript
                  ? "Drag the transcript out, or use ⋯ for more"
                  : "Drag the audio out, or use ⋯ to transcribe")

            Menu {
                if let transcript = entry.transcriptURL {
                    Button { model.copyTextOfFile(transcript) } label: {
                        Label("Copy transcript text", systemImage: "doc.on.clipboard")
                    }
                    Button { model.copyFileToPasteboard(transcript) } label: {
                        Label("Copy transcript file", systemImage: "doc.on.doc")
                    }
                } else if entry.audioURL != nil {
                    Button { model.transcribeExisting(entry) } label: {
                        Label("Processar na pipeline", systemImage: "gearshape.arrow.trianglehead.2.clockwise.rotate.90")
                    }
                    .disabled(!model.pipelineIsReady || model.transcriptionState == .running)
                }
                if let audio = entry.audioURL {
                    Button { model.copyFileToPasteboard(audio) } label: {
                        Label("Copy audio file", systemImage: "waveform")
                    }
                }
                Divider()
                Button { model.reveal(entry.folderURL) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func recentDragProvider(_ entry: RecordingEntry) -> NSItemProvider {
        if let transcript = entry.transcriptURL {
            return NSItemProvider(contentsOf: transcript) ?? NSItemProvider()
        }
        if let audio = entry.audioURL {
            return NSItemProvider(contentsOf: audio) ?? NSItemProvider()
        }
        return NSItemProvider()
    }

    private func recentSubtitle(_ entry: RecordingEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let when = formatter.string(from: entry.date)

        let status: String
        if entry.hasTranscript {
            status = "publicada"
        } else if entry.isPrepared {
            status = "preparada"
        } else {
            status = "não processada"
        }
        return "\(when) · \(status)"
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                model.openRecordingsFolder()
            } label: {
                Label("Gravações", systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .help("Open ~/Documents/Recordings in Finder")

            Spacer()

            Button {
                openPreferences()
            } label: {
                Label("Ajustes…", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: [.command])
            .help("Open Preferences")

            Button {
                model.quit()
            } label: {
                Label("Sair", systemImage: "power")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q", modifiers: [.command])
        }
    }

    private func openPreferences() {
        PreferencesWindowController.shared.show(model: model)
    }

    private func formattedElapsed(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct LevelMeter: View {
    let label: String
    let level: Float
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                let clamped = CGFloat(max(0, min(1, level)))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(2, geo.size.width * clamped))
                        .animation(.linear(duration: 0.08), value: clamped)
                }
            }
            .frame(height: 8)
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let inProgress: Bool
    let canStart: Bool
    let onRecord: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(inProgress ? Color.red : Color.clear)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(timeRange(meeting.start, meeting.end))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button {
                onRecord()
            } label: {
                Image(systemName: "record.circle")
                    .foregroundStyle(canStart ? Color.red : Color.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!canStart)
            .help("Record this meeting")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(inProgress ? Color.red.opacity(0.10) : Color.clear)
        )
    }

    private func timeRange(_ start: Date, _ end: Date) -> String {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        return "\(fmt.string(from: start)) – \(fmt.string(from: end))"
    }
}
