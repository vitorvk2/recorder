import XCTest
@testable import Recorder

final class PublicationStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testPublishedLinkSurvivesNoopRunAndLibraryReload() throws {
        let folder = root.appendingPathComponent("2026-11-5-1829")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = folder.appendingPathComponent("pipeline.log")
        let note = try XCTUnwrap(URL(string: "obsidian://open?vault=Trabalho&file=reunioes%2FReuni%C3%A3o.md"))
        try PublicationStore.save(note, for: log)
        try "nada para transcrever\nnada para resumir\nnada para sincronizar".write(to: log, atomically: true, encoding: .utf8)
        let entries = RecordingsLibrary.recent(limit: 6, obsRoot: nil, recorderRoot: root)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.processingOutcome?.kind, .nothingPending)
        XCTAssertEqual(entry.noteURL, note)
    }

    func testObsidianDestinationEncodesVaultAndNoteSeparately() throws {
        let record = PublicationStore.Publication(id: "recording", note_path: "Trabalho da equipe/reuniões/DNS & migração.md", notion_page_id: nil)
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(record.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "obsidian")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "vault" })?.value, "Trabalho da equipe")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "file" })?.value, "reuniões/DNS & migração.md")
    }

    func testNotionDestinationsAndUnrecognizedLinks() {
        let link = "https://notion.so/123456781234123412341234567890ab"
        XCTAssertEqual(PublicationStore.Publication(id: "a", note_path: link, notion_page_id: nil).url?.absoluteString, link)
        XCTAssertEqual(PublicationStore.Publication(id: "b", note_path: nil, notion_page_id: "12345678-1234-1234-1234-1234567890ab").url?.absoluteString, link)
        XCTAssertNil(PublicationStore.Publication(id: "c", note_path: "https://example.com/note", notion_page_id: nil).url)
    }

    func testPublicationQueryUsesExactIdentityAndRequiresCompletedPublication() throws {
        let db = root.appendingPathComponent("test.db")
        let fixture = """
        CREATE TABLE meetings(source TEXT, rel_path TEXT, status TEXT, note_path TEXT, notion_page_id TEXT);
        INSERT INTO meetings VALUES('recorder','session/processed.m4a','sincronizado','Trabalho/reunioes/ata.md',NULL);
        INSERT INTO meetings VALUES('obs','session/processed.m4a','sincronizado','https://notion.so/123456781234123412341234567890ab',NULL);
        INSERT INTO meetings VALUES('recorder','pending/processed.m4a','resumido',NULL,'12345678-1234-1234-1234-1234567890ab');
        """
        let create = Process()
        create.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        create.arguments = [db.path, fixture]
        try create.run()
        create.waitUntilExit()
        XCTAssertEqual(create.terminationStatus, 0)
        let requests = [
            PublicationStore.Request(id: "recorder", source: "recorder", path: "session/processed.m4a"),
            PublicationStore.Request(id: "obs", source: "obs", path: "session/processed.m4a"),
            PublicationStore.Request(id: "pending", source: "recorder", path: "pending/processed.m4a"),
            PublicationStore.Request(id: "prefix", source: "recorder", path: "session/"),
        ]
        let query = Process()
        query.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        query.arguments = ["-c", PublicationStore.queryScript, String(decoding: try JSONEncoder().encode(requests), as: UTF8.self)]
        var environment = ProcessInfo.processInfo.environment
        environment["DB_PATH"] = db.path
        query.environment = environment
        let pipe = Pipe()
        query.standardOutput = pipe
        query.standardError = pipe
        try query.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        query.waitUntilExit()
        XCTAssertEqual(query.terminationStatus, 0, output)
        let urls = try PublicationStore.decodeOutput(output)
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls["recorder"]?.scheme, "obsidian")
        XCTAssertEqual(urls["obs"]?.host, "notion.so")
        XCTAssertNil(urls["pending"])
        XCTAssertNil(urls["prefix"])
    }

    func testRecoverReportedRecordingFromConfiguredPipelineWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["RECORDER_VERIFY_PUBLICATION"] else {
            throw XCTSkip("Requires the configured local pipeline; query is read-only.")
        }
        let request = PublicationStore.Request(id: "reported-recording", source: "recorder", path: "2026-11-5-1829/processed.m4a")
        let urls = try PublicationStore.lookup([request], pipelineDir: directory)
        let url = try XCTUnwrap(urls[request.id])
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "obsidian")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "vault" })?.value, "Trabalho")
        XCTAssertTrue(components.queryItems?.first(where: { $0.name == "file" })?.value?.contains("2026-11-05 Migração de banco") == true)
    }
}
