import SwiftUI

/// The content of the dedicated **Preferences window**.
///
/// The window itself is an AppKit `NSWindow` hosting this view — see
/// `PreferencesWindowController` for why we don't use SwiftUI's `Settings` scene.
/// Everything that used to live in the menu-bar panel's inline "Settings"
/// disclosure now lives here, opened with ⌘, or the panel's "Settings…" button:
///   - **General** — your name (transcript labelling) + silence auto-stop.
///   - **Pipeline** — pasta do repo transcribe, contexto e auto-processamento.
///
/// Grouped `Form`s in a `TabView` give the standard macOS System-Settings look,
/// and the window has far more room than the 340-pt menu-bar panel (the prompt
/// editor in particular is finally comfortable to edit). The `TabView` is given a
/// single fixed size so the host window doesn't clip the taller (Transcription) tab
/// or leave the window resizing as you switch tabs.
struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferences()
                .tabItem { Label("General", systemImage: "gearshape") }

            TranscriptionPreferences()
                .tabItem { Label("Transcription", systemImage: "text.bubble") }
        }
        .frame(width: 480, height: 560)
    }
}

// MARK: - General

private struct GeneralPreferences: View {
    @Environment(RecorderModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Your name", text: $model.localSpeakerName, prompt: Text("Optional"))
                Text("Labels your voice — the microphone, on the right channel — when the transcript guesses who said what. Leave blank to omit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Your name")
            }

            Section {
                Toggle("Stop automatically after silence", isOn: $model.silenceAutoStopEnabled)

                if model.silenceAutoStopEnabled {
                    Stepper(
                        value: Binding(
                            get: { Int((model.silenceTimeout / 60).rounded()) },
                            set: { model.silenceTimeout = TimeInterval(max(1, $0) * 60) }
                        ),
                        in: 1...60
                    ) {
                        Text("After \(Int((model.silenceTimeout / 60).rounded())) min of silence on both channels")
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Silence threshold")
                            Spacer()
                            Text("\(Int(model.silenceThresholdDB)) dB")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $model.silenceThresholdDB, in: -80 ... -20, step: 1)
                        Text("A channel counts as silent below this level. Lower = more tolerant of quiet rooms.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Auto-stop")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Pipeline

private struct TranscriptionPreferences: View {
    @Environment(RecorderModel.self) private var model

    /// Working copy for the path field; committed on blur so UserDefaults is
    /// not rewritten on every keystroke.
    @State private var dirDraft = ""
    @FocusState private var dirFocused: Bool

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("~/Documents/home/transcribe", text: $dirDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($dirFocused)
                        .onSubmit { commitDir() }
                    Button("Escolher…") { chooseDirectory() }
                }
                HStack(spacing: 6) {
                    Image(systemName: model.pipelineIsReady
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.pipelineIsReady ? .green : .orange)
                    Text(model.pipelineIsReady
                         ? "Docker e docker-compose.yml encontrados."
                         : "Docker não encontrado ou a pasta não tem docker-compose.yml.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Pipeline local")
            } footer: {
                Text("Pasta do repo transcribe. O processamento roda todo aqui: Whisper transcreve, o modelo resume e a ata vai para o Notion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if model.availableContexts.isEmpty {
                    Text("Nenhuma subpasta em \(PipelineRunner.mediaRoot(pipelineDir: model.pipelineDir).path). Crie uma (ex.: Funcional) para ela aparecer aqui.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Contexto padrão", selection: $model.selectedContext) {
                        ForEach(model.availableContexts, id: \.self) { Text($0).tag($0) }
                    }
                }
                Button("Recarregar contextos") { model.refreshContexts() }
            } header: {
                Text("Contexto")
            } footer: {
                Text("As subpastas da raiz de mídia. É o contexto que decide onde a ata é organizada no Notion — criar uma pasta nova já a faz aparecer, sem configurar nada.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Acionar a pipeline automaticamente ao salvar", isOn: $model.autoProcess)
                    .disabled(!model.pipelineIsReady)
                Text(model.autoProcess
                     ? "Cada gravação é processada e publicada no Notion assim que você salva."
                     : "A gravação fica pronta e o botão Processar, no painel, a envia quando você quiser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Automático")
            } footer: {
                Text("Desligado por padrão: a pipeline publica no Notion, e isso é um efeito maior do que gerar um arquivo local.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { dirDraft = model.pipelineDir }
        .onChange(of: dirFocused) { _, focused in if !focused { commitDir() } }
        .onDisappear { commitDir() }
    }

    private func commitDir() {
        let trimmed = dirDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            dirDraft = model.pipelineDir
            return
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if model.pipelineDir != expanded { model.pipelineDir = expanded }
        dirDraft = expanded
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: model.pipelineDir)
        if panel.runModal() == .OK, let url = panel.url {
            model.pipelineDir = url.path
            dirDraft = url.path
        }
    }
}
