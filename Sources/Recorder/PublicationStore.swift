import Foundation

/// Publication records outlive individual pipeline runs. A no-op run may replace
/// pipeline.log, so retain the destination separately and recover old links from
/// the pipeline's SQLite database without running transcription or publishing.
enum PublicationStore {
    struct Request: Codable {
        let id: String
        let source: String
        let path: String
    }

    struct Publication: Decodable {
        let id: String
        let note_path: String?
        let notion_page_id: String?

        var url: URL? {
            if let path = note_path, !path.isEmpty {
                if let url = URL(string: path), Self.isNoteURL(url) { return url }
                // Obsidian destinations are stored as "Vault/folder/note.md".
                guard !path.contains("://"), let slash = path.firstIndex(of: "/") else { return nil }
                let vault = String(path[..<slash])
                let file = String(path[path.index(after: slash)...])
                guard !vault.isEmpty, !file.isEmpty else { return nil }
                var components = URLComponents()
                components.scheme = "obsidian"
                components.host = "open"
                components.queryItems = [URLQueryItem(name: "vault", value: vault), URLQueryItem(name: "file", value: file)]
                return components.url
            }
            if let page = notion_page_id, UUID(uuidString: page) != nil {
                return URL(string: "https://notion.so/" + page.replacingOccurrences(of: "-", with: ""))
            }
            return nil
        }

        static func isNoteURL(_ url: URL) -> Bool {
            if url.scheme == "obsidian" { return url.host == "open" }
            return url.scheme == "https" && ["notion.so", "www.notion.so"].contains(url.host ?? "")
        }
    }

    enum Failure: LocalizedError {
        case unavailable
        case lookupFailed

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Abra o Docker e confira a pasta da pipeline nos Ajustes para localizar a ata."
            case .lookupFailed: return "Não foi possível consultar o registro das atas. Confira se o Docker está aberto e tente novamente."
            }
        }
    }

    private struct CachedPublication: Codable { let url: URL }

    private static func cacheURL(for logURL: URL) -> URL {
        if logURL.lastPathComponent == "pipeline.log" {
            return logURL.deletingLastPathComponent().appendingPathComponent("publication.json")
        }
        return logURL.deletingPathExtension().deletingPathExtension().appendingPathExtension("publication.json")
    }

    static func cachedURL(for logURL: URL) -> URL? {
        guard let data = try? Data(contentsOf: cacheURL(for: logURL)),
              let record = try? JSONDecoder().decode(CachedPublication.self, from: data),
              Publication.isNoteURL(record.url) else { return nil }
        return record.url
    }

    static func save(_ url: URL, for logURL: URL) throws {
        guard Publication.isNoteURL(url) else { return }
        let data = try JSONEncoder().encode(CachedPublication(url: url))
        try data.write(to: cacheURL(for: logURL), options: .atomic)
    }

    static func request(for entry: RecordingEntry, mediaRoot: URL) -> Request? {
        if entry.source == .recorder, let folder = entry.metaFolderURL {
            return Request(id: entry.id, source: "recorder", path: folder.lastPathComponent + "/processed.m4a")
        }
        guard let audio = entry.audioURL else { return nil }
        let root = mediaRoot.standardizedFileURL.path + "/"
        let path = audio.standardizedFileURL.path
        guard path.hasPrefix(root) else { return nil }
        return Request(id: entry.id, source: "obs", path: String(path.dropFirst(root.count)))
    }

    // Only exact source/path matches that reached the published state qualify.
    // A Notion page ID may be checkpointed before publication finishes.
    static let queryScript = #"""
import json, os, sqlite3, sys
requests = json.loads(sys.argv[1])
path = os.environ.get("DB_PATH", "/data/transcribe.db")
from pathlib import Path
connection = sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", uri=True)
connection.row_factory = sqlite3.Row
result = []
for request in requests:
    row = connection.execute(
        "SELECT note_path, notion_page_id FROM meetings WHERE source = ? AND rel_path = ? AND status = 'sincronizado'",
        (request["source"], request["path"])
    ).fetchone()
    if row:
        result.append(dict(row, id=request["id"]))
connection.close()
print("RECORDER_PUBLICATIONS=" + json.dumps(result))
"""#

    static func decodeOutput(_ output: String) throws -> [String: URL] {
        let prefix = "RECORDER_PUBLICATIONS="
        guard let line = output.split(separator: "\n").last(where: { $0.hasPrefix(prefix) }),
              let data = String(line.dropFirst(prefix.count)).data(using: .utf8) else { throw Failure.lookupFailed }
        let records = try JSONDecoder().decode([Publication].self, from: data)
        return records.reduce(into: [:]) { result, record in
            if let url = record.url { result[record.id] = url }
        }
    }

    static func lookup(_ requests: [Request], pipelineDir: String) throws -> [String: URL] {
        guard !requests.isEmpty else { return [:] }
        let composeFile = (pipelineDir as NSString).appendingPathComponent("docker-compose.yml")
        guard let docker = PipelineRunner.resolveDocker(),
              FileManager.default.fileExists(atPath: composeFile) else { throw Failure.unavailable }
        let data = try JSONEncoder().encode(requests)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: docker)
        process.currentDirectoryURL = URL(fileURLWithPath: pipelineDir)
        process.arguments = ["compose", "-f", composeFile, "run", "--rm", "--no-deps", "--entrypoint", "python", "app",
                             "-c", queryScript, String(decoding: data, as: UTF8.self)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.lookupFailed }
        return try decodeOutput(output)
    }
}
