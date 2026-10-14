import AVFoundation
import Foundation

/// Decodes the audio track of an audio or video file into the same WAV format as live recording.
enum MediaImporter {
    static func convertToWAV(source: URL, destination: URL) async throws -> Int {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AppError.message("The selected file has no readable audio track")
        }
        return try await Task.detached(priority: .userInitiated) {
            let partial = destination.deletingLastPathComponent().appendingPathComponent("importing.wav")
            try? FileManager.default.removeItem(at: partial)
            do {
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ])
                guard reader.canAdd(output) else { throw AppError.message("Cannot decode this audio track") }
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? AppError.message("Could not read media") }
                let writer = try WAVWriter(url: partial)
                var totalSamples = 0
                while let sampleBuffer = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                          let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                          format.mSampleRate == 16_000, format.mChannelsPerFrame == 1,
                          format.mBitsPerChannel == 16, format.mFormatID == kAudioFormatLinearPCM else {
                        throw AppError.message("Media decoder did not produce 16 kHz mono PCM")
                    }
                    guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                        throw AppError.message("Could not read decoded audio samples")
                    }
                    let count = CMBlockBufferGetDataLength(block)
                    guard count % 2 == 0 else { throw AppError.message("Invalid PCM sample length") }
                    var bytes = [UInt8](repeating: 0, count: count)
                    let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: &bytes)
                    guard status == kCMBlockBufferNoErr else { throw AppError.message("Could not copy decoded audio") }
                    var samples: [Int16] = []
                    samples.reserveCapacity(count / 2)
                    for index in stride(from: 0, to: count, by: 2) {
                        samples.append(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8))
                    }
                    try writer.append(samples)
                    totalSamples += samples.count
                    guard totalSamples < 1_800_000_000 else { throw AppError.message("Imported audio is too long for WAV") }
                }
                guard reader.status == .completed, totalSamples > 0 else {
                    throw reader.error ?? AppError.message("The media contains no decodable audio")
                }
                try writer.close()
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial)
                } else {
                    try FileManager.default.moveItem(at: partial, to: destination)
                }
                return totalSamples * 1000 / 16_000
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw error
            }
        }.value
    }
}
