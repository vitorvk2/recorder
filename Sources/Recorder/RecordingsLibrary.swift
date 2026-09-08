import Foundation

enum RecordingSource: Equatable {
    case recorder
    case obs
}

struct RecordingEntry: Identifiable, Equatable {
    let id: String
    let source: RecordingSource

    let metaFolderURL: URL?

    let revealURL: URL

    let logURL: URL

    let title: String?

    let date: Date

    let audioURL: URL?

    let transcriptURL: URL?

    let legacyTextURL: URL?

    let context: String?

    let isPrepared: Bool

    let stateIsKnown: Bool

    var hasTranscript: Bool { transcriptURL != nil }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let context, !context.isEmpty { return context }
        return "Sem contexto"
    }
}

enum RecordingsLibrary {
    static let mediaExtensions: Set<String> = [
        "mp4", "mov", "mkv", "m4a", "mp3", "wav", "flac",
    ]

    private static let obsNamePattern = try? NSRegularExpression(
        pattern: #"(\d{4})-(\d{2})-(\d{2})[ _](\d{2})-(\d{2})-(\d{2})"#
    )

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

    static func recent(limit: Int, obsRoot: URL?) -> [RecordingEntry] {
        let merged = recorderEntries() + obsEntries(root: obsRoot)
        return Array(merged.sorted { $0.date > $1.date }.prefix(limit))
    }

    private static func recorderEntries() -> [RecordingEntry] {
        let fm = FileManager.default
        guard let root = recordingsRoot(),
              let items = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        return items.compactMap { url in
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
                id: url.path,
                source: .recorder,
                metaFolderURL: url,
                revealURL: url,
                logURL: transcript,
                title: title,
                date: parsedDate ?? fileDate,
                audioURL: hasAudio ? audio : nil,
                transcriptURL: hasTranscript ? transcript : nil,
                legacyTextURL: nil,
                context: contextFromMeta(url),
                isPrepared: fm.fileExists(
                    atPath: url.appendingPathComponent("processed.m4a").path
                ),
                stateIsKnown: true
            )
        }
    }

    private static func obsEntries(root: URL?) -> [RecordingEntry] {
        let fm = FileManager.default
        guard let root, fm.fileExists(atPath: root.path),
              let contexts = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var out: [RecordingEntry] = []
        for contextURL in contexts {
            guard (try? contextURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let files = try? fm.contentsOfDirectory(
                    at: contextURL,
                    includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }

            for fileURL in files {
                guard mediaExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }

                let base = fileURL.deletingPathExtension()
                let log = base.appendingPathExtension("pipeline.log")
                let legacy = base.appendingPathExtension("txt")
                let hasLog = fm.fileExists(atPath: log.path)
                let hasLegacy = fm.fileExists(atPath: legacy.path)

                let values = try? fileURL.resourceValues(forKeys: [
                    .contentModificationDateKey, .creationDateKey,
                ])
                let fileDate = values?.creationDate ?? values?.contentModificationDate ?? .distantPast

                out.append(
                    RecordingEntry(
                        id: fileURL.path,
                        source: .obs,
                        metaFolderURL: nil,
                        revealURL: fileURL,
                        logURL: log,
                        title: fileURL.deletingPathExtension().lastPathComponent,
                        date: parseObsName(fileURL.lastPathComponent) ?? fileDate,
                        audioURL: fileURL,
                        transcriptURL: hasLog ? log : nil,
                        legacyTextURL: hasLegacy ? legacy : nil,
                        context: contextURL.lastPathComponent,
                        isPrepared: false,
                        stateIsKnown: hasLog
                    )
                )
            }
        }
        return out
    }

    static func parseObsName(_ name: String) -> Date? {
        guard let pattern = obsNamePattern else { return nil }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let m = pattern.firstMatch(in: name, range: range), m.numberOfRanges == 7 else {
            return nil
        }

        var numbers: [Int] = []
        for i in 1..<7 {
            guard let r = Range(m.range(at: i), in: name), let v = Int(name[r]) else { return nil }
            numbers.append(v)
        }

        var components = DateComponents()
        components.year = numbers[0]
        components.month = numbers[1]
        components.day = numbers[2]
        components.hour = numbers[3]
        components.minute = numbers[4]
        components.second = numbers[5]
        return Calendar(identifier: .gregorian).date(from: components)
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
