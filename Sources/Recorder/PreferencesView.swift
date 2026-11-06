import SwiftUI

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferences()
                .tabItem { Label("Geral", systemImage: "gearshape") }

            TranscriptionPreferences()
                .tabItem { Label("Processamento", systemImage: "text.bubble") }
        }
        .frame(width: 480, height: 560)
    }
}

private struct GeneralPreferences: View {
    @Environment(RecorderModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Seu nome", text: $model.localSpeakerName, prompt: Text("Opcional"))
                Text("Ajuda a identificar sua voz, captada pelo microfone, na transcrição. Deixe em branco para não informar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Seu nome")
            }

            Section {
                Toggle("Parar automaticamente após silêncio", isOn: $model.silenceAutoStopEnabled)

                if model.silenceAutoStopEnabled {
                    Stepper(
                        value: Binding(
                            get: { Int((model.silenceTimeout / 60).rounded()) },
                            set: { model.silenceTimeout = TimeInterval(max(1, $0) * 60) }
                        ),
                        in: 1...60
                    ) {
                        Text("Após \(Int((model.silenceTimeout / 60).rounded())) min de silêncio nos dois canais")
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Limite de silêncio")
                            Spacer()
                            Text("\(Int(model.silenceThresholdDB)) dB")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $model.silenceThresholdDB, in: -80 ... -20, step: 1)
                        Text("O canal é considerado silencioso abaixo deste nível. Valores menores toleram sons mais baixos.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Parada automática")
            }
        }
        .formStyle(.grouped)
    }
}

private struct TranscriptionPreferences: View {
    @Environment(RecorderModel.self) private var model

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
                Text("Pasta do repo transcribe. Whisper transcreve, o modelo resume e a ata pessoal vai ao Notion por MCP. Atas de trabalho continuam no Obsidian.")
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
                Text("As subpastas da raiz de mídia. O contexto decide o destino: Funcional e Pedbot no Obsidian Trabalho, English e Pessoal no Notion. Pasta nova precisa de um destino no .env do transcribe, senão a ata fica pendente.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Acionar a pipeline automaticamente ao salvar", isOn: $model.autoProcess)
                    .disabled(!model.pipelineIsReady)
                Text(model.autoProcess
                     ? "Cada gravação entra na fila de processamento assim que você salva."
                     : "A gravação fica pronta e o botão Processar, no painel, a envia quando você quiser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Automático")
            } footer: {
                Text("O processamento transcreve, resume e publica a ata no destino do contexto escolhido.")
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
