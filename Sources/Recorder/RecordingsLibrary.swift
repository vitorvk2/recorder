import Foundation

struct RecordingEntry: Identifiable, Equatable {
    var id: String { folderURL.path }
    let folderURL: URL

    let title: String?

    let date: Date

    let audioURL: URL?

    let transcriptURL: URL?

    let context: String?

    let isPrepared: Bool

    var hasTranscript: Bool { transcriptURL != nil }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let context, !context.isEmpty { return context }
        return "Sem contexto"
    }
}

enum RecordingsLibrary {
    static func contextFromMeta(_ folderURL: URL) -> String? {
        let url = folderURL.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ctx = obj["context"] as? String,
              !ctx.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return ctx
    }

    static func recordingsRoot() -> URL? {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        return documents.appendingPathComponent("Recordings", isDirectory: true)
    }

    static func recent(limit: Int) -> [RecordingEntry] {
        let fm = FileManager.default
        guard let root = recordingsRoot(),
              let items = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let entries: [RecordingEntry] = items.compactMap { url in
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .creationDateKey, .contentModificationDateKey,
            ])
            guard values?.isDirectory == true else { return nil }

            let audio = url.appendingPathComponent("audio.m4a")
            let transcript = url.appendingPathComponent("pipeline.log")
            let hasAudio = fm.fileExists(atPath: audio.path)
            let hasTranscript = fm.fileExists(atPath: transcript.path)
            let hasRaw = fm.fileExists(atPath: url.appendingPathComponent("desktop.caf").path)
                || fm.fileExists(atPath: url.appendingPathComponent("mic.caf").path)

            guard hasAudio || hasTranscript || hasRaw else { return nil }

            let (parsedDate, title) = parseFolderName(url.lastPathComponent)
            let fileDate = values?.creationDate ?? values?.contentModificationDate ?? .distantPast

            return RecordingEntry(
                folderURL: url,
                title: title,
                date: parsedDate ?? fileDate,
                audioURL: hasAudio ? audio : nil,
                transcriptURL: hasTranscript ? transcript : nil,
                context: contextFromMeta(url),
                isPrepared: fm.fileExists(
                    atPath: url.appendingPathComponent("processed.m4a").path
                )
            )
        }

        return Array(entries.sorted { $0.date > $1.date }.prefix(limit))
    }

    static func parseFolderName(_ name: String) -> (Date?, String?) {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              parts[3].count == 4, let hhmm = Int(parts[3]) else {
            return (nil, name.isEmpty ? nil : name)
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hhmm / 100
        components.minute = hhmm % 100
        let date = Calendar(identifier: .gregorian).date(from: components)

        var titleParts = Array(parts.dropFirst(4))
        if let last = titleParts.last, last.count <= 3, !last.isEmpty, last.allSatisfy(\.isNumber) {
            titleParts.removeLast()
        }
        let title = titleParts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (date, title.isEmpty ? nil : title)
    }
}
