import Foundation
import AVFoundation

enum RecorderState: Equatable {
    case idle
    case recording
    case paused
}

enum TranscriptionState: Equatable {
    case idle
    case running

    case done(URL)

    case failed(String)
}

struct CaptureResult {
    var firstHostTime: UInt64?

    var sampleRate: Double

    var frameCount: AVAudioFramePosition

    init(firstHostTime: UInt64? = nil, sampleRate: Double = 0, frameCount: AVAudioFramePosition = 0) {
        self.firstHostTime = firstHostTime
        self.sampleRate = sampleRate
        self.frameCount = frameCount
    }
}

struct Meeting: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date

    let attendees: [String]

    init(id: String, title: String, start: Date, end: Date, attendees: [String] = []) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
    }

    func isInProgress(_ now: Date) -> Bool {
        start <= now && now <= end
    }

    var folderSuffix: String {
        Meeting.sanitize(title)
    }

    static func sanitize(_ raw: String) -> String {
        let illegal: Set<Character> = ["/", ":", "\\", "?", "%", "*", "|", "\"", "<", ">"]

        var cleaned = ""
        cleaned.reserveCapacity(raw.count)
        for ch in raw {
            if illegal.contains(ch) { continue }
            if ch.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { continue }
            cleaned.append(ch)
        }

        let pieces = cleaned.split(whereSeparator: { $0.isWhitespace })
        var collapsed = pieces.joined(separator: "-")

        if collapsed.count > 40 {
            collapsed = String(collapsed.prefix(40))
        }

        while let first = collapsed.first, first == "." || first == "-" {
            collapsed.removeFirst()
        }

        while let last = collapsed.last, last == "-" {
            collapsed.removeLast()
        }

        return collapsed.isEmpty ? "meeting" : collapsed
    }
}

struct RecordingSession {
    let folderURL: URL

    let desktopURL: URL

    let micURL: URL

    let outputURL: URL
    let startedAt: Date
    let meetingTitle: String?

    static func create(now: Date, meetingTitle: String?) throws -> RecordingSession {
        let fm = FileManager.default

        let documents = try fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let recordingsRoot = documents
            .appendingPathComponent("Recordings", isDirectory: true)

        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "en_US_POSIX")
        dateFmt.calendar = Calendar(identifier: .gregorian)
        dateFmt.dateFormat = "yyyy-M-d"

        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.calendar = Calendar(identifier: .gregorian)
        timeFmt.dateFormat = "HHmm"

        var folderName = "\(dateFmt.string(from: now))-\(timeFmt.string(from: now))"
        if let title = meetingTitle {
            folderName += "-\(Meeting.sanitize(title))"
        }

        var folderURL = recordingsRoot.appendingPathComponent(folderName, isDirectory: true)

        if fm.fileExists(atPath: folderURL.path) {
            var n = 2
            var candidate = recordingsRoot.appendingPathComponent("\(folderName)-\(n)", isDirectory: true)
            while fm.fileExists(atPath: candidate.path) {
                n += 1
                candidate = recordingsRoot.appendingPathComponent("\(folderName)-\(n)", isDirectory: true)
            }
            folderURL = candidate
        }
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)

        return RecordingSession(
            folderURL: folderURL,
            desktopURL: folderURL.appendingPathComponent("desktop.caf"),
            micURL: folderURL.appendingPathComponent("mic.caf"),
            outputURL: folderURL.appendingPathComponent("audio.m4a"),
            startedAt: now,
            meetingTitle: meetingTitle
        )
    }
}

func meterLevel(fromDB db: Float) -> Float {
    max(0, min(1, (db + 80) / 80))
}
