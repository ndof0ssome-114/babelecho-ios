import Foundation

@MainActor
final class MeetingStore {
    private var root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(root override: URL? = nil) {
        root = override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BabelEcho/Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func audioURL(for meeting: Meeting) -> URL { directory(for: meeting.id).appendingPathComponent(meeting.audioFile) }
    func screenRecoveryURL(for meeting: Meeting) -> URL { directory(for: meeting.id).appendingPathComponent("screen-recovery.mp4") }

    func save(_ meeting: Meeting) throws {
        var directory = directory(for: meeting.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        let destination = directory.appendingPathComponent("meeting.json")
        try encoder.encode(meeting).write(to: destination, options: .atomic)
    }

    func list() -> [Meeting] {
        let paths = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return paths.compactMap { directory in
            let file = directory.appendingPathComponent("meeting.json")
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(Meeting.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Repair microphone recordings left open by a crash or a killed app.
    /// Returns how many meetings regained playable audio.
    func recoverInterruptedRecordings() -> Int {
        var recovered = 0
        for var meeting in list() where meeting.wasInterrupted {
            var audioMs = 0
            let audio = audioURL(for: meeting)
            if meeting.isInterruptedLiveRecording, FileManager.default.fileExists(atPath: audio.path) {
                // An unreadable file (for example before first unlock) is
                // retried on a later launch instead of being marked failed.
                guard let repaired = try? WAVWriter.repair(url: audio) else { continue }
                audioMs = repaired
            }
            meeting.settleInterruption(recoveredAudioMs: audioMs)
            guard (try? save(meeting)) != nil else { continue }
            if meeting.state == "stopped" { recovered += 1 }
        }
        return recovered
    }

    func recoverOrphanedScreenCaptures() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil)) ?? []
        var recovered = 0
        for file in files where file.lastPathComponent.hasPrefix("BabelEcho-screen-") && file.pathExtension == "mp4" {
            var meeting = Meeting(title: "Recovered screen capture \(Date.now.formatted(date: .abbreviated, time: .shortened))")
            meeting.state = "failed"
            meeting.source = "screen"
            do {
                try save(meeting)
                try FileManager.default.moveItem(at: file, to: screenRecoveryURL(for: meeting))
                recovered += 1
            } catch {
                if FileManager.default.fileExists(atPath: file.path) { try? delete(meeting) }
                continue
            }
        }
        return recovered
    }

    func delete(_ meeting: Meeting) throws { try FileManager.default.removeItem(at: directory(for: meeting.id)) }

    func export(_ meeting: Meeting, format: String) throws -> URL {
        let safeTitle = meeting.title.replacingOccurrences(of: "[/\\:]", with: "_", options: .regularExpression)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(safeTitle)-\(meeting.id.uuidString.prefix(8))\(MeetingExport.suffix(format)).\(MeetingExport.fileExtension(format))")
        let text = format == "json" ? String(decoding: try encoder.encode(meeting), as: UTF8.self) : MeetingExport.text(meeting, format: format)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
