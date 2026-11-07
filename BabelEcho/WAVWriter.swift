import Foundation

final class WAVWriter {
    let url: URL
    private let handle: FileHandle
    private var closed = false
    private(set) var sampleCount = 0

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 44))
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        handle = try FileHandle(forWritingTo: url)
        // forWritingTo opens at offset 0; samples belong after the placeholder.
        try handle.seek(toOffset: 44)
    }

    func append(_ samples: [Int16]) throws {
        guard !closed else { throw AppError.message("WAV writer is closed") }
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        try handle.write(contentsOf: data)
        sampleCount += samples.count
    }

    func close() throws {
        guard !closed else { return }
        defer { try? handle.close(); closed = true }
        let byteCount = sampleCount * 2
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(bytes: byteCount))
    }

    deinit { try? close() }

    /// Finish a WAV whose writer never reached `close()` because the app was
    /// killed or crashed mid-recording: drop a torn half sample and write the
    /// real header over the 44-byte placeholder. Returns the duration in ms.
    static func repair(url: URL) throws -> Int {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        guard size > 44 else { return 0 }
        let bytes = (size - 44) & ~1
        try handle.truncate(atOffset: UInt64(44 + bytes))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(bytes: bytes))
        return bytes / 32 // 16 kHz mono 16-bit = 32 bytes per millisecond
    }

    static func header(bytes: Int) -> Data {
        var data = Data()
        func word(_ value: Int) {
            let number = UInt32(clamping: value)
            for shift in stride(from: 0, through: 24, by: 8) { data.append(UInt8(truncatingIfNeeded: number >> shift)) }
        }
        func half(_ value: Int) {
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        data.append(contentsOf: "RIFF".utf8); word(36 + bytes)
        data.append(contentsOf: "WAVEfmt ".utf8); word(16); half(1); half(1)
        word(16_000); word(32_000); half(2); half(16)
        data.append(contentsOf: "data".utf8); word(bytes)
        return data
    }
}
