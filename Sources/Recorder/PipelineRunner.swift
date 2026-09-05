import Foundation

/// Dispara a pipeline local de processamento (repo `transcribe`) sobre uma
/// gravação recém-salva.
///
/// Substitui o `GeminiTranscriber`: em vez de enviar o áudio para a API do
/// Gemini, escreve um `meta.json` ao lado da gravação e chama
/// `docker compose run --rm app run`. A pipeline transcreve com Whisper local,
/// resume e publica no Notion.
///
/// O `meta.json` é o que resolve a identificação do contexto: quem gravou
/// escolhe na hora (com o evento do calendário como sugestão) e a pipeline
/// obedece, em vez de tentar adivinhar pelo horário.
struct PipelineRunner {
    /// Caminho absoluto do `docker`. App de GUI não herda `/usr/local/bin` no
    /// PATH, então resolver por nome falharia silenciosamente.
    static let dockerCandidates = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
    ]

    struct Context {
        let context: String
        let meetingTitle: String?
        let attendees: [String]
        let startedAt: Date
        let localSpeakerName: String?
    }

    enum Failure: LocalizedError {
        case dockerMissing
        case pipelineDirMissing(String)
        case exited(code: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case .dockerMissing:
                return "Docker não encontrado. Abra o Docker Desktop e tente de novo."
            case .pipelineDirMissing(let path):
                return "Pasta da pipeline não encontrada: \(path). Ajuste em Settings."
            case .exited(let code, let output):
                let tail = output
                    .split(separator: "\n")
                    .suffix(6)
                    .joined(separator: "\n")
                return "Pipeline falhou (código \(code)):\n\(tail)"
            }
        }
    }

    /// Diretório do repo `transcribe`, onde vive o docker-compose.yml.
    var pipelineDir: String

    static func resolveDocker() -> String? {
        dockerCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Grava o `meta.json` que a pipeline lê no `import`.
    ///
    /// Escrito ANTES de rodar a pipeline, e mantido depois: se a pipeline
    /// falhar, a escolha de contexto não se perde e a próxima tentativa não
    /// precisa perguntar de novo.
    static func writeMeta(folderURL: URL, context: Context) throws {
        var payload: [String: Any] = [
            "context": context.context,
            "startedAt": ISO8601DateFormatter().string(from: context.startedAt),
        ]
        if let t = context.meetingTitle, !t.isEmpty { payload["meetingTitle"] = t }
        if !context.attendees.isEmpty { payload["attendees"] = context.attendees }
        if let s = context.localSpeakerName, !s.isEmpty { payload["speakerName"] = s }

        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: folderURL.appendingPathComponent("meta.json"), options: .atomic)
    }

    /// Roda a pipeline e devolve a saída combinada.
    ///
    /// Chama `run`, que encadeia import, transcrição, resumo e publicação. O
    /// `import` encontra a gravação pelo `meta.json` que acabou de ser escrito.
    func run(folderURL: URL, context: Context) async throws -> String {
        guard let docker = Self.resolveDocker() else { throw Failure.dockerMissing }
        var isDir: ObjCBool = false
        let composeFile = (pipelineDir as NSString).appendingPathComponent("docker-compose.yml")
        guard FileManager.default.fileExists(atPath: composeFile, isDirectory: &isDir) else {
            throw Failure.pipelineDirMissing(pipelineDir)
        }

        try Self.writeMeta(folderURL: folderURL, context: context)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.arguments = [
            "compose", "-f", composeFile, "run", "--rm", "app", "run",
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: pipelineDir)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        // Lê enquanto roda: uma reunião longa produz saída suficiente para
        // encher o buffer do pipe, e aí o processo travaria esperando leitura.
        let handle = pipe.fileHandleForReading
        var output = ""
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            output += String(decoding: chunk, as: UTF8.self)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure.exited(code: process.terminationStatus, output: output)
        }
        return output
    }

    /// Contextos disponíveis: as subpastas da raiz de mídia da pipeline.
    ///
    /// Lidos do disco em vez de configurados aqui, porque é a subpasta que a
    /// pipeline usa como contexto — criar uma pasta nova em `~/Movies/OBS` já
    /// a faz aparecer no picker, sem tocar em configuração.
    static func discoverContexts(pipelineDir: String) -> [String] {
        let root = mediaRoot(pipelineDir: pipelineDir)
        let items = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// `MEDIA_ROOT_HOST` do .env da pipeline, com `~/Movies/OBS` como fallback.
    ///
    /// Ler do .env evita que o app e a pipeline discordem sobre onde a mídia
    /// vive — um desencontro que só apareceria na hora de processar.
    static func mediaRoot(pipelineDir: String) -> URL {
        let envPath = (pipelineDir as NSString).appendingPathComponent(".env")
        if let text = try? String(contentsOfFile: envPath, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("MEDIA_ROOT_HOST=") else { continue }
                let value = String(t.dropFirst("MEDIA_ROOT_HOST=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if !value.isEmpty { return URL(fileURLWithPath: value) }
            }
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies/OBS")
    }

    /// Resultado legível de uma rodada: título da ata e link do Notion.
    ///
    /// A primeira versão devolvia a última linha do log, que era o id cru da
    /// página — um UUID no painel não diz nada a quem acabou de gravar.
    struct Outcome {
        var headline: String
        var notionURL: URL?
    }

    static func outcome(from output: String) -> Outcome {
        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let url = lines
            .last { $0.hasPrefix("https://notion.so/") }
            .flatMap(URL.init(string:))

        // `ok "Título da ata"` é a linha que o sync emite ao publicar.
        if let ok = lines.last(where: { $0.hasPrefix("ok \"") }) {
            let title = ok.dropFirst(4).dropLast(ok.hasSuffix("\"") ? 1 : 0)
            return Outcome(headline: String(title), notionURL: url)
        }
        if lines.contains(where: { $0.contains("sem_fala") }) {
            return Outcome(headline: "Sem fala detectável — não publicada", notionURL: nil)
        }
        if let err = lines.last(where: { $0.contains("ERRO:") }) {
            return Outcome(headline: String(err.drop(while: { $0 != "E" })), notionURL: nil)
        }
        return Outcome(headline: "Processada", notionURL: url)
    }
}
