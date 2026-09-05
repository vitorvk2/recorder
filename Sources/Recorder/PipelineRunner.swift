import Foundation

struct PipelineRunner {
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

    var pipelineDir: String

    static func resolveDocker() -> String? {
        dockerCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

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
