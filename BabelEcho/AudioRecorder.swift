import AVFoundation
import Foundation

final class AudioRecorder {
    struct Chunk {
        let wav: Data
        let startMs: Int
        let endMs: Int
        let utteranceID: UUID
        let isFinal: Bool
    }

    var onChunk: ((Chunk) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onInterruption: (() -> Void)?
    private var engine: AVAudioEngine?
    private var writer: WAVWriter?
    private let queue = DispatchQueue(label: "app.babelecho.audio", qos: .userInitiated)
    private var utteranceSamples: [Int16] = []
    private var idleSamples: [Int16] = []
    private var utteranceStart = 0
    private var lastVoiceEnd = 0
    private var lastPartialAt = 0
    private var utteranceID = UUID()
    private var writtenSamples = 0
    private var sourcePosition = 0.0
    private var previousSample: Float = 0
    private var isPaused = false
    private var realtime = RealtimeSettings()
    private var emitChunks = false
    private var interruptionObserver: NSObjectProtocol?

    var durationMs: Int { queue.sync { writtenSamples * 1000 / 16_000 } }
    static func wavHeader(bytes: Int) -> Data { WAVWriter.header(bytes: bytes) }

    func start(url: URL, settings: AppSettings) throws {
        guard engine == nil else { throw AppError.message("Recording is already active") }
        let session = AVAudioSession.sharedInstance()
        let engine = AVAudioEngine()
        var tapInstalled = false
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setActive(true)
            let writer = try WAVWriter(url: url)
            self.writer = writer
            utteranceSamples = []
            idleSamples = []
            utteranceStart = 0
            lastVoiceEnd = 0
            lastPartialAt = 0
            utteranceID = UUID()
            writtenSamples = 0
            sourcePosition = 0
            previousSample = 0
            isPaused = false
            realtime = settings.realtime ?? RealtimeSettings()
            emitChunks = settings.liveTranscription

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw AppError.message("Microphone format is unavailable") }
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self, let channels = buffer.floatChannelData else { return }
                let frames = Int(buffer.frameLength)
                let channelCount = Int(buffer.format.channelCount)
                var mono = [Float](repeating: 0, count: frames)
                for frame in 0..<frames {
                    var value: Float = 0
                    for channel in 0..<channelCount { value += channels[channel][frame] }
                    mono[frame] = value / Float(max(1, channelCount))
                }
                let rate = format.sampleRate
                self.queue.async { [weak self] in self?.consume(mono, sourceRate: rate) }
            }
            tapInstalled = true
            try engine.start()
        } catch {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
            queue.sync {
                try? self.writer?.close()
                self.writer = nil
            }
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        self.engine = engine
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in self?.onInterruption?() }
        }
    }

    func setPaused(_ paused: Bool) {
        queue.sync {
            if paused && !isPaused { finalizeUtterance() }
            isPaused = paused
        }
    }

    func stop() throws -> Int {
        guard let engine else { return durationMs }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        if let observer = interruptionObserver { NotificationCenter.default.removeObserver(observer) }
        interruptionObserver = nil
        var result: Result<Int, Error> = .success(0)
        queue.sync {
            do {
                finalizeUtterance()
                try writer?.close()
                result = .success(writtenSamples * 1000 / 16_000)
                writer = nil
            } catch { result = .failure(error) }
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return try result.get()
    }

    private func consume(_ input: [Float], sourceRate: Double) {
        guard !isPaused, let writer, !input.isEmpty else { return }
        let step = sourceRate / 16_000
        var output: [Int16] = []
        var index = sourcePosition
        while index < Double(input.count) {
            let lower = Int(index)
            let fraction = Float(index - Double(lower))
            let left = lower < input.count ? input[lower] : previousSample
            let right = lower + 1 < input.count ? input[lower + 1] : left
            let sample = max(-1, min(1, left + (right - left) * fraction))
            output.append(Int16((sample * 32767).rounded()))
            index += step
        }
        sourcePosition = index - Double(input.count)
        previousSample = input[input.count - 1]
        guard !output.isEmpty else { return }
        do { try writer.append(output) }
        catch { return }
        writtenSamples += output.count
        let level = Float(sqrt(output.reduce(0.0) { sum, sample in
            let normalized = Double(sample) / 32768
            return sum + normalized * normalized
        } / Double(output.count)))
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
        guard emitChunks else { return }
        let bufferStart = writtenSamples - output.count
        if Double(level) >= realtime.vadThreshold {
            if utteranceSamples.isEmpty {
                utteranceSamples = idleSamples
                utteranceStart = bufferStart - idleSamples.count
                utteranceID = UUID()
                lastPartialAt = bufferStart
                idleSamples = []
            }
            utteranceSamples.append(contentsOf: output)
            lastVoiceEnd = writtenSamples
        } else if !utteranceSamples.isEmpty {
            utteranceSamples.append(contentsOf: output)
            if writtenSamples - lastVoiceEnd >= realtime.silenceMilliseconds * 16 {
                finalizeUtterance()
                idleSamples = Array(output.suffix(4_800))
                return
            }
        } else {
            idleSamples.append(contentsOf: output)
            if idleSamples.count > 4_800 { idleSamples.removeFirst(idleSamples.count - 4_800) }
        }
        guard !utteranceSamples.isEmpty else { return }
        if utteranceSamples.count >= realtime.maxUtteranceSeconds * 16_000 {
            publish(utteranceSamples, isFinal: true)
            let overlap = min(realtime.overlapMilliseconds * 16, utteranceSamples.count)
            utteranceSamples = Array(utteranceSamples.suffix(overlap))
            utteranceStart = writtenSamples - overlap
            utteranceID = UUID()
            lastPartialAt = writtenSamples
        } else if writtenSamples - lastPartialAt >= realtime.stepSeconds * 16_000,
                  writtenSamples - lastPartialAt >= Int(realtime.minNewSeconds * 16_000) {
            publish(utteranceSamples, isFinal: false)
            lastPartialAt = writtenSamples
        }
    }

    private func finalizeUtterance() {
        if emitChunks && utteranceSamples.count >= 4_000 { publish(utteranceSamples, isFinal: true) }
        utteranceSamples = []
        idleSamples = []
    }

    private func publish(_ samples: [Int16], isFinal: Bool) {
        var wav = WAVWriter.header(bytes: samples.count * 2)
        for sample in samples {
            let value = UInt16(bitPattern: sample)
            wav.append(UInt8(truncatingIfNeeded: value))
            wav.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        let chunk = Chunk(wav: wav, startMs: utteranceStart * 1000 / 16_000,
                          endMs: (utteranceStart + samples.count) * 1000 / 16_000,
                          utteranceID: utteranceID, isFinal: isFinal)
        DispatchQueue.main.async { [weak self] in self?.onChunk?(chunk) }
    }
}
