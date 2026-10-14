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
