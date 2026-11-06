import SwiftUI
import AppKit

struct RecorderPanel: View {
    @Environment(RecorderModel.self) private var model
    @State private var selectedSection: PanelSection

    enum PanelSection: String, CaseIterable {
        case agenda = "Agenda"
        case recent = "Recentes"
    }

    init(section: PanelSection = .agenda) {
        _selectedSection = State(initialValue: section)
    }

    private var panelHeight: CGFloat {
        min(640, max(420, (NSScreen.main?.visibleFrame.height ?? 800) - 48))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            captureSection
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            Divider()
            Picker("Conteúdo", selection: $selectedSection) {
                ForEach(PanelSection.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if hasProcessingActivity { processingSection }
                    switch selectedSection {
                    case .agenda: meetingsSection
                    case .recent: recentSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 380, height: panelHeight)
        .background(NativePanelBackground())
        .environment(\.locale, Locale(identifier: "pt_BR"))
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.red)
                .frame(width: 28, height: 28)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            Text("Recorder").font(.headline)
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(stateColor).frame(width: 5, height: 5)
                Text(stateLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(formattedElapsed(model.state == .idle ? 0 : model.elapsed))
                        .font(.system(size: 30, weight: .regular, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(model.state == .paused ? .secondary : .primary)
                    Text(model.state == .idle ? "Sistema e microfone" : (model.currentSession?.meetingTitle ?? "Gravação em andamento"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if model.state != .idle {
                    Button { model.togglePause() } label: {
                        Image(systemName: model.state == .paused ? "play.fill" : "pause.fill")
                            .frame(width: 18, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .help(model.state == .paused ? "Continuar gravação" : "Pausar gravação")
                    .accessibilityLabel(model.state == .paused ? "Continuar gravação" : "Pausar gravação")
                }
                captureButton
            }
            .frame(minHeight: 58)

            Divider()
            contextRow

            HStack(spacing: 20) {
                LevelMeter(label: "Sistema", symbol: "speaker.wave.2", level: model.desktopLevel, tint: .accentColor)
                LevelMeter(label: "Microfone", symbol: "mic", level: model.micLevel, tint: .accentColor)
            }

            if model.state != .idle {
                HStack {
                    Text(model.state == .paused ? "Em pausa" : "Gravando áudio")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) { model.trashAndStop() } label: {
                        Label("Descartar", systemImage: "trash")
                    }
                    .buttonStyle(.borderless).font(.caption)
                    .help("Descartar esta gravação")
                }
            }

            if let message = model.statusMessage {
                Label(message, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).help(message)
            }
        }
        .padding(16)
        .background(insetSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.06)))
    }

    private var captureButton: some View {
        Button {
            if model.state == .idle { model.startRecording(meeting: nil) }
            else { model.saveAndStop() }
        } label: {
            ZStack {
                Circle().strokeBorder(.secondary.opacity(0.35), lineWidth: 1.5)
                if model.state == .idle {
                    Circle().fill(.red).padding(6)
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(.red).padding(13)
                }
            }
            .frame(width: 48, height: 48)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(model.state == .idle ? "Iniciar gravação (⌘R)" : "Parar e salvar gravação (⌘R)")
        .accessibilityLabel(model.state == .idle ? "Iniciar gravação" : "Parar e salvar gravação")
        .keyboardShortcut("r", modifiers: [.command])
    }

    private var insetSurface: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.65)
    }

    private var contextRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            if model.availableContexts.isEmpty {
                Text("Contexto").foregroundStyle(.secondary)
                Spacer()
                Button("Configurar…") { openPreferences() }.buttonStyle(.borderless)
            } else {
                Picker("Contexto", selection: Binding(
                    get: { model.selectedContext }, set: { model.selectedContext = $0 }
                )) {
                    ForEach(model.availableContexts, id: \.self) { context in
                        Text(context).tag(context)
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.state != .idle)
                .help("Destino da próxima gravação")
            }
        }
        .font(.callout)
        .controlSize(.regular)
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
        .background(insetSurface, in: RoundedRectangle(cornerRadius: 10))
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
                VStack(spacing: 0) {
                    ForEach(model.meetings) { meeting in
                        MeetingRow(meeting: meeting, inProgress: meeting.isInProgress(Date()),
                                   canStart: model.state == .idle,
                                   onRecord: { model.startRecording(meeting: meeting) })
                        if meeting.id != model.meetings.last?.id {
                            Divider().padding(.leading, 50)
                        }
                    }
                }
                .background(insetSurface, in: RoundedRectangle(cornerRadius: 10))
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
                            Divider().padding(.leading, 46)
                        }
                    }
                }
                .background(insetSurface, in: RoundedRectangle(cornerRadius: 10))
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
                        .font(.callout.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text(entry.date, format: .dateTime.day().month().hour().minute())
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(recentStatus(entry))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        .padding(.horizontal, 10)
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
            Button { model.openRecordingsFolder() } label: { Label("Abrir gravações", systemImage: "folder") }
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
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var stateLabel: String {
        switch model.state {
        case .idle: return "Pronto"
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
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(meeting.start, format: .dateTime.day())
                    .font(.system(size: 17, weight: .medium))
                Text(meeting.start, format: .dateTime.month(.abbreviated))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 30, height: 36)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(meeting.title).font(.callout.weight(.medium))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text("\(meeting.start, format: .dateTime.hour().minute()) – \(meeting.end, format: .dateTime.hour().minute())")
                    if inProgress {
                        Text("Agora").foregroundStyle(Color.accentColor)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: onRecord) {
                Image(systemName: "record.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(canStart ? Color.red : Color.secondary)
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.borderless).disabled(!canStart)
            .help("Gravar \(meeting.title)").accessibilityLabel("Gravar \(meeting.title)")
        }
        .padding(10)
        .background(inProgress ? Color.accentColor.opacity(0.07) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Use the same adaptive vibrancy as a native macOS popover. The system also
/// handles Reduce Transparency, light/dark appearances and contrast settings.
private struct NativePanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
