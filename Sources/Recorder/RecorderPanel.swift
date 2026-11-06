import SwiftUI
import AppKit

struct RecorderPanel: View {
    @Environment(RecorderModel.self) private var model

    private var panelHeight: CGFloat {
        min(740, max(420, (NSScreen.main?.visibleFrame.height ?? 800) - 48))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            captureSection
                .padding(.horizontal, 20)
                .padding(.bottom, 18)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if hasProcessingActivity { processingSection }
                    meetingsSection
                    recentSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 400, height: panelHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Label("Recorder", systemImage: "waveform")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(stateColor).frame(width: 6, height: 6)
                Text(stateLabel).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(stateColor.opacity(0.10), in: Capsule())
        }
        .padding(20)
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if model.state == .idle {
                    Text("Nova gravação")
                        .font(.system(size: 24, weight: .semibold))
                    Text("Áudio do sistema e microfone")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text(formattedElapsed(model.elapsed))
                        .font(.system(size: 32, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(model.state == .paused ? .secondary : .primary)
                    Text(model.currentSession?.meetingTitle ?? "Gravação em andamento")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(model.currentSession?.meetingTitle ?? "Gravação em andamento")
                }
            }
            .frame(height: 58, alignment: .leading)

            contextRow

            if model.state == .idle {
                Button { model.startRecording(meeting: nil) } label: {
                    Label("Iniciar gravação", systemImage: "record.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: [.command])
            } else {
                recordingControls
            }

            HStack(spacing: 20) {
                LevelMeter(label: "Sistema", symbol: "speaker.wave.2", level: model.desktopLevel, tint: .teal)
                LevelMeter(label: "Microfone", symbol: "mic", level: model.micLevel, tint: .blue)
            }

            if let message = model.statusMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                    Text(message).lineLimit(2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(message)
            }
        }
    }

    private var contextRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text("Contexto").foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if model.availableContexts.isEmpty {
                Button("Configurar") { openPreferences() }
                    .buttonStyle(.borderless)
            } else {
                Picker("Contexto da gravação", selection: Binding(
                    get: { model.selectedContext }, set: { model.selectedContext = $0 }
                )) {
                    ForEach(model.availableContexts, id: \.self) { context in
                        Text(context).tag(context)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)
                .disabled(model.state != .idle)
                .help("Destino da próxima gravação")
            }
        }
        .font(.system(size: 12))
        .frame(height: 28)
    }

    private var recordingControls: some View {
        HStack(spacing: 8) {
            Button { model.togglePause() } label: {
                Label(model.state == .paused ? "Continuar" : "Pausar",
                      systemImage: model.state == .paused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
            Button { model.saveAndStop() } label: {
                Label("Salvar", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            Button(role: .destructive) { model.trashAndStop() } label: {
                Image(systemName: "trash").frame(minHeight: 34)
            }
            .buttonStyle(.bordered)
            .help("Descartar esta gravação")
            .accessibilityLabel("Descartar gravação")
        }
        .controlSize(.large)
    }

    private var hasProcessingActivity: Bool {
        model.mixingCount > 0 || model.transcriptionState == .running || model.canProcessNow
            || (model.lastOutcome != nil && model.lastOutcome?.kind != .nothingPending) || processingError != nil
    }

    private var processingError: String? {
        if case .failed(let message) = model.transcriptionState { return message }
        return nil
    }

    private var processingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.mixingCount > 0 {
                activityRow(symbol: "waveform", title: "Salvando áudio…", detail: "Você já pode iniciar outra gravação.")
            }
            if model.transcriptionState == .running {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Processando em segundo plano")
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.processingTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if !model.queuedTranscriptions.isEmpty {
                            Text("\(model.queuedTranscriptions.count) na fila")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else if let error = processingError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Não foi possível processar").font(.system(size: 12, weight: .semibold))
                        Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(error)
                    }
                    Spacer(minLength: 0)
                    Button { openPreferences() } label: { Image(systemName: "gearshape") }
                        .buttonStyle(.borderless).help("Abrir ajustes")
                }
            } else if let outcome = model.lastOutcome, outcome.kind != .nothingPending {
                resultRow(outcome)
            }
            if model.canProcessNow {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.badge.plus").foregroundStyle(.blue).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.pendingTranscriptions.count == 1 ? "Gravação pronta" : "\(model.pendingTranscriptions.count) gravações prontas")
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.pendingContext.isEmpty ? "Escolha um contexto nos Ajustes" : model.pendingContext)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button(model.transcriptionState == .running ? "Enfileirar" : "Processar") {
                        model.processLastRecording()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.pipelineIsReady)
                    .keyboardShortcut("p", modifiers: [.command])
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.06)))
    }

    private func activityRow(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func resultRow(_ outcome: PipelineRunner.Outcome) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: outcome.kind == .noSpeech ? "waveform.slash" : "checkmark.circle.fill")
                .foregroundStyle(outcome.kind == .noSpeech ? Color.orange : Color.green)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(outcome.headline).font(.system(size: 12, weight: .medium)).lineLimit(2).help(outcome.headline)
                if let url = outcome.noteURL {
                    Link(url.scheme == "obsidian" ? "Abrir no Obsidian" : "Abrir no Notion", destination: url)
                        .font(.caption)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("Copiar log") { model.copyTranscriptText() }
                Button("Mostrar no Finder") { model.revealTranscript() }
                Button("Processar novamente") { model.retryTranscription() }.disabled(!model.pipelineIsReady)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Ações do processamento")
        }
    }

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Agenda", symbol: "calendar")
                Spacer()
                Button { model.refreshMeetings() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Atualizar agenda").accessibilityLabel("Atualizar agenda")
            }
            if model.meetings.isEmpty {
                Text("Nenhuma reunião por perto.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                VStack(spacing: 2) {
                    ForEach(model.meetings) { meeting in
                        MeetingRow(meeting: meeting, inProgress: meeting.isInProgress(Date()),
                                   canStart: model.state == .idle,
                                   onRecord: { model.startRecording(meeting: meeting) })
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Gravações recentes", symbol: "clock")
                Spacer()
                Button("Ver pasta") { model.openRecordingsFolder() }
                    .font(.caption).buttonStyle(.borderless)
            }
            if model.recentRecordings.isEmpty {
                Text("Suas gravações salvas aparecem aqui.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.recentRecordings) { entry in
                        recentRow(entry)
                        if entry.id != model.recentRecordings.last?.id {
                            Divider().padding(.leading, 36)
                        }
                    }
                }
            }
        }
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func recentRow(_ entry: RecordingEntry) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: recentIcon(entry))
                    .font(.system(size: 16))
                    .foregroundStyle(recentTint(entry))
                    .frame(width: 26, height: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text(entry.date, format: .dateTime.day().month().hour().minute())
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(recentStatus(entry))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onDrag { recentDragProvider(entry) }
            .help("\(entry.displayTitle)\nArraste o arquivo ou use o menu de ações.")
            Menu {
                if let log = entry.transcriptURL {
                    Button("Copiar log do processamento") { model.copyTextOfFile(log) }
                    Button("Copiar arquivo de log") { model.copyFileToPasteboard(log) }
                }
                if entry.audioURL != nil {
                    Button(model.transcriptionState == .running ? "Adicionar à fila" : "Processar gravação") {
                        model.transcribeExisting(entry)
                    }
                    .disabled(!model.pipelineIsReady || model.isScheduled(entry))
                }
                if let legacy = entry.legacyTextURL {
                    Button("Copiar transcrição antiga") { model.copyTextOfFile(legacy) }
                }
                if let audio = entry.audioURL {
                    Button(entry.source == .obs ? "Copiar arquivo de vídeo" : "Copiar arquivo de áudio") {
                        model.copyFileToPasteboard(audio)
                    }
                }
                Divider()
                Button("Mostrar no Finder") { model.reveal(entry.revealURL) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Ações de \(entry.displayTitle)")
        }
        .padding(.vertical, 10)
    }

    private func recentDragProvider(_ entry: RecordingEntry) -> NSItemProvider {
        guard let url = entry.transcriptURL ?? entry.audioURL else { return NSItemProvider() }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }

    private func recentIcon(_ entry: RecordingEntry) -> String {
        if model.isScheduled(entry) { return "clock.arrow.circlepath" }
        switch entry.processingOutcome?.kind {
        case .published: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle"
        case .noSpeech: return "waveform.slash"
        default: return entry.source == .obs ? "film" : "waveform"
        }
    }

    private func recentTint(_ entry: RecordingEntry) -> Color {
        if model.isScheduled(entry) { return .blue }
        switch entry.processingOutcome?.kind {
        case .published: return .green
        case .failed, .noSpeech: return .orange
        default: return .secondary
        }
    }

    private func recentStatus(_ entry: RecordingEntry) -> String {
        if model.activeTranscription?.audioURL == entry.audioURL { return "Processando" }
        if model.isScheduled(entry) { return "Na fila" }
        let status: String
        switch entry.processingOutcome?.kind {
        case .published: status = "Publicada"
        case .failed: status = "Falha no processamento"
        case .noSpeech: status = "Sem fala detectada"
        case .processed: status = "Processada"
        case .nothingPending: status = "Sem novas pendências"
        case nil: status = entry.isPrepared ? "Preparada" : "Aguardando processamento"
        }
        return [entry.context, status].compactMap { $0 }.joined(separator: " · ")
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button { model.openRecordingsFolder() } label: { Label("Gravações", systemImage: "folder") }
                .buttonStyle(.borderless)
            Spacer()
            Button { openPreferences() } label: { Image(systemName: "gearshape").frame(width: 24, height: 24) }
                .buttonStyle(.borderless).help("Ajustes")
                .accessibilityLabel("Ajustes").keyboardShortcut(",", modifiers: [.command])
            Button { model.quit() } label: { Image(systemName: "power").frame(width: 24, height: 24) }
                .buttonStyle(.borderless).help("Sair do Recorder")
                .accessibilityLabel("Sair do Recorder").keyboardShortcut("q", modifiers: [.command])
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var stateLabel: String {
        switch model.state {
        case .idle: return "Pronto para gravar"
        case .recording: return "Gravando"
        case .paused: return "Em pausa"
        }
    }

    private var stateColor: Color {
        switch model.state {
        case .idle: return .secondary
        case .recording: return .red
        case .paused: return .orange
        }
    }

    private func openPreferences() { PreferencesWindowController.shared.show(model: model) }

    private func formattedElapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct LevelMeter: View {
    let label: String
    let symbol: String
    let level: Float
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: symbol)
                .font(.system(size: 10)).foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tint)
                        .frame(width: geometry.size.width * CGFloat(max(0, min(1, level))))
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(max(0, min(1, level)) * 100)) por cento")
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let inProgress: Bool
    let canStart: Bool
    let onRecord: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(inProgress ? Color.blue : Color.primary.opacity(0.12))
                .frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title).font(.system(size: 12, weight: .medium))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("\(meeting.start, format: .dateTime.hour().minute()) – \(meeting.end, format: .dateTime.hour().minute())")
                    if inProgress { Text("Agora").foregroundStyle(.blue) }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: onRecord) {
                Image(systemName: "record.circle").font(.system(size: 19))
                    .foregroundStyle(canStart ? Color.red : Color.secondary)
                    .frame(width: 28, height: 32)
            }
            .buttonStyle(.borderless).disabled(!canStart)
            .help("Gravar \(meeting.title)").accessibilityLabel("Gravar \(meeting.title)")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(inProgress ? Color.blue.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
    }
}
