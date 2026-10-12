import Foundation

/// Persistent record of one cleanup, so every move is accounted for even after a crash or relaunch.
/// Written atomically to ~/Library/Application Support/Tidybo/sessions/<id>.json
/// before anything is touched and after every single move.
struct CleanupSession: Codable {
    enum State: String, Codable { case cleaning, done }
    enum ItemStatus: String, Codable { case pending, moved, failed }

    struct Item: Codable {
        var source: String          // original path on the desktop
        var destination: String     // path inside the cleanup folder
        var axPosition: CGPoint     // icon's top-left in global AX coordinates at cleanup time
        var status: ItemStatus
        var error: String?
    }

    var id: String
    var createdAt: Date
    var folder: String
    var state: State
    var items: [Item]
}

final class Journal {
    static let directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tidybo/sessions", isDirectory: true)

    private(set) var session: CleanupSession
    let url: URL

    init(session: CleanupSession) throws {
        self.session = session
        url = Journal.directory.appendingPathComponent("\(session.id).json")
        try FileManager.default.createDirectory(at: Journal.directory, withIntermediateDirectories: true)
        try save()
    }

    private init(session: CleanupSession, url: URL) { self.session = session; self.url = url }

    func update(_ change: (inout CleanupSession) -> Void) {
        change(&session)
        do { try save() } catch { print("Journal write failed: \(error)") }
    }

    private func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(session).write(to: url, options: .atomic)
    }

    /// All sessions on disk, newest first.
    static func all() -> [Journal] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { u in (try? Data(contentsOf: u)).flatMap { try? dec.decode(CleanupSession.self, from: $0) }.map { Journal(session: $0, url: u) } }
            .sorted { $0.session.createdAt > $1.session.createdAt }
    }

    /// Cleanup folders of all known sessions: never cleaned up themselves.
    static func knownFolders() -> Set<String> { Set(all().map(\.session.folder)) }
}

enum FileMover {
    /// Creates "Tidybo Folder N" with the first free N. Never reuses an existing folder.
    static func createCleanupFolder(in desktop: URL) throws -> URL {
        let fm = FileManager.default
        for n in 1...999 {
            let url = desktop.appendingPathComponent("Tidybo Folder \(n)", isDirectory: true)
            if fm.fileExists(atPath: url.path) { continue }
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            } catch CocoaError.fileWriteFileExists {
                continue // raced with someone else; try the next number
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Moves without ever overwriting: fails if the destination exists.
    static func move(_ source: String, to destination: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source]) }
        guard !fm.fileExists(atPath: destination) else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: destination]) }
        try fm.moveItem(atPath: source, toPath: destination) // moveItem itself also refuses to overwrite
    }
}
