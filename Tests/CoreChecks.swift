import AVFoundation
import Foundation
import XCTest
@testable import BabelEchoCoreChecks

final class CoreChecks: XCTestCase {
    func testOlderMeetingDecodesWithoutNewFields() throws {
        let json = """
        {"schemaVersion":1,"id":"00000000-0000-0000-0000-000000000001", "title":"Earlier meeting",
         "createdAt":"2026-09-28T08:00:00Z","durationMs":1000,"state":"stopped",
         "audioFile":"recording.wav","language":"zh","translateTo":"","segments":[
         {"id":"00000000-0000-0000-0000-000000000002","startMs":0,"endMs":1000,
          "text":"你好","translation":"","speaker":"Speaker 1"}],
         "summary":"","summaryUpTo":0,"minutes":"","questions":[],"asrCalls":1,"llmCalls":0}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meeting = try decoder.decode(Meeting.self, from: Data(json.utf8))
        XCTAssertNil(meeting.minutesDocument)
        XCTAssertNil(meeting.source)
        XCTAssertNil(meeting.segments[0].provider)
        XCTAssertEqual(meeting.transcript, "你好")
    }

    func testClosedWAVKeepsEverySampleAfterTheHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVWriter(url: url)
        try writer.append([Int16](repeating: 1_000, count: 16_000))
        try writer.close()
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 32_000)
        XCTAssertEqual(data.prefix(44), WAVWriter.header(bytes: 32_000))
        XCTAssertEqual(data[44], 0xE8, "the first sample is not overwritten by the header")
    }

    func testInterruptedRecordingWAVIsRepaired() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        // What an unclosed WAVWriter leaves: a zero header, one second of
        // samples and a torn half sample.
        let writer = try WAVWriter(url: url)
        try writer.append([Int16](repeating: 1_000, count: 16_000))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([7]))
        try handle.close()
        XCTAssertEqual(try Data(contentsOf: url).prefix(4), Data(count: 4))

        XCTAssertEqual(try WAVWriter.repair(url: url), 1_000)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 32_000)
        XCTAssertEqual(data.prefix(44), WAVWriter.header(bytes: 32_000))
        XCTAssertEqual(data[44], 0xE8, "samples are kept")
        XCTAssertEqual(try WAVWriter.repair(url: url), 1_000, "repair is idempotent")

        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: empty) }
        FileManager.default.createFile(atPath: empty.path, contents: Data(count: 44))
        XCTAssertEqual(try WAVWriter.repair(url: empty), 0)
    }

    func testInterruptedMeetingsSettleWithoutClaimingPartialConversions() {
        var live = Meeting(title: "Live")
        live.state = "paused"
        XCTAssertTrue(live.wasInterrupted)
        live.settleInterruption(recoveredAudioMs: 2_500)
        XCTAssertEqual(live.state, "stopped")
        XCTAssertEqual(live.durationMs, 2_500)
        XCTAssertFalse(live.wasInterrupted)

        var silent = Meeting(title: "No audio")
        silent.settleInterruption(recoveredAudioMs: 0)
        XCTAssertEqual(silent.state, "failed")

        var imported = Meeting(title: "Import")
        imported.source = "import"
        imported.state = "processing"
        XCTAssertFalse(imported.isInterruptedLiveRecording)
        imported.settleInterruption(recoveredAudioMs: 9_000)
        XCTAssertEqual(imported.state, "failed")

        var screen = Meeting(title: "Screen")
        screen.source = "screen"
        screen.settleInterruption(recoveredAudioMs: 9_000)
        XCTAssertEqual(screen.state, "failed")

        var finished = Meeting(title: "Done")
        finished.state = "stopped"
        XCTAssertFalse(finished.wasInterrupted)
    }

    func testExplicitJapaneseNeverRoutesToMiMo() {
        var catalog = ProviderCatalog()
        catalog.asr = catalog.asr.map { provider in
            var copy = provider
            copy.enabled = true
            return copy
        }
        catalog.activeASR = "mimo"
        XCTAssertFalse(catalog.candidates(for: "ja").contains { $0.id == "mimo" })
        XCTAssertEqual(catalog.candidates(for: "ja").first?.id, "groq")
        catalog.asr[0].pricePerHour = -1
        XCTAssertThrowsError(try catalog.validated())
    }

    func testMinutesMarkdownRetainsStructuredItems() {
        let document = MinutesDocument(title: "Planning", abstract: "A review",
            participants: ["A"], decisions: [.init(decision: "Ship", context: nil)],
            actionItems: [.init(task: "Test", owner: "A", due: "Friday")], risks: nil,
            openQuestions: ["When?"], keywords: nil, chapters: nil)
        XCTAssertTrue(document.markdown.contains("## Decisions\n- Ship"))
        XCTAssertTrue(document.markdown.contains("Test (A, Friday)"))
    }

    func testMediaImporterConvertsAACToMono16kWAV() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.m4a")
        let destination = directory.appendingPathComponent("recording.wav")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        let samples = buffer.floatChannelData![0]
        for index in 0..<48_000 { samples[index] = sin(Float(index) * .pi * 2 * 440 / 48_000) * 0.2 }
        do {
            let file = try AVAudioFile(forWriting: source, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ])
            try file.write(from: buffer)
        }
        let duration = try await MediaImporter.convertToWAV(source: source, destination: destination)
        let data = try Data(contentsOf: destination)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertGreaterThan(duration, 900)
        XCTAssertLessThan(duration, 1_100)
        XCTAssertLessThan(abs(data.count - (44 + duration * 32)), 33)
        // Recovery must also succeed when an earlier WAV exists; replacement is atomic.
        let retried = try await MediaImporter.convertToWAV(source: source, destination: destination)
        XCTAssertEqual(retried, duration)
        XCTAssertEqual(try Data(contentsOf: destination), data)
    }
}
