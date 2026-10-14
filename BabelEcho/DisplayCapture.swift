#if !targetEnvironment(simulator)
import Foundation
import ScreenCaptureKit

/// Delegate callbacks may arrive on arbitrary queues. All state lives on MainActor.
@available(iOS 27.0, *)
@MainActor
final class DisplayCapture: NSObject, SCContentSharingPickerObserver, SCRecordingOutputDelegate, SCStreamDelegate {
    var onStarted: (() -> Void)?
    var onFinished: ((URL) -> Void)?
    var onError: ((Error, URL?) -> Void)?
    var onCancelled: (() -> Void)?

    private var stream: SCStream?
    private var recording: SCRecordingOutput?
    private var outputURL: URL?
    private var pickerActive = false
    private var lifecycle = CaptureLifecycle()
    private var pendingError: Error?
    private var deadline: Task<Void, Never>?

    func present() throws {
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else { throw AppError.message("Screen capture is unavailable on this device") }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        pickerActive = true
        picker.present()
    }

    func stop() async {
        guard lifecycle.requestStop() else { return }
        armDeadline("Screen capture did not finish. Any unfinished capture will be recovered on next launch.")
        await stopStream()
    }

    func cancelPicker() {
        if lifecycle.phase == .picking {
            guard lifecycle.finish() else { return }
            deactivatePicker()
            onCancelled?()
        } else if lifecycle.phase == .starting {
            pendingError = AppError.message("Screen capture startup cancelled")
            // startCapture must settle before stopCapture is called.
            _ = lifecycle.requestStop()
            armDeadline("Screen capture cancellation timed out. Any unfinished capture will be recovered on next launch.")
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.cancelPicker() }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            guard self.lifecycle.selected() else { return }
            self.deactivatePicker()
            self.armDeadline("Screen capture startup timed out. Try again from the system picker.")
            await self.start(with: filter)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in await self.fail(error, outputFinalized: true) }
    }

    private func start(with filter: SCContentFilter) async {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 720
        configuration.height = 1280
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("BabelEcho-screen-\(UUID().uuidString).mp4")
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = target
        let capture = SCStream(filter: filter, configuration: configuration, delegate: self)
        let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        do {
            try capture.addRecordingOutput(output)
            outputURL = target
            recording = output
            stream = capture
            try await capture.startCapture()
            // A cancellation/timeout may have arrived while the system was starting.
            if lifecycle.phase == .stopping || lifecycle.phase == .finished { try? await capture.stopCapture() }
        } catch { await fail(error, outputFinalized: true) }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard self.lifecycle.started() else { return }
            self.deadline?.cancel()
            if let url = self.outputURL {
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            }
            self.onStarted?()
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.complete(outputFinalized: true) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in await self.fail(error, outputFinalized: true) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in await self.fail(error, outputFinalized: false) }
    }

    private func stopStream() async {
        guard let stream else { complete(outputFinalized: true); return }
        do { try await stream.stopCapture() }
        catch { await fail(error, outputFinalized: false) }
        // Successful output is consumed only after the recording delegate finalizes it.
    }

    private func fail(_ error: Error, outputFinalized: Bool) async {
        guard lifecycle.phase != .finished else { return }
        pendingError = pendingError ?? error
        deactivatePicker()
        _ = lifecycle.requestStop()
        armDeadline("Screen capture could not close safely. Any unfinished capture will be recovered on next launch.")
        if let stream { try? await stream.stopCapture() }
        if outputFinalized || outputURL == nil { complete(outputFinalized: outputFinalized) }
    }

    private func complete(outputFinalized: Bool) {
        guard lifecycle.finish() else { return }
        deadline?.cancel()
        deadline = nil
        deactivatePicker()
        let url = outputFinalized ? outputURL : nil
        recording = nil
        stream = nil
        outputURL = nil
        if let error = pendingError { onError?(error, url) }
        else if let url { onFinished?(url) }
        else { onCancelled?() }
    }

    private func armDeadline(_ message: String) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            guard let self, self.lifecycle.phase != .finished else { return }
            self.pendingError = AppError.message(message)
            let capture = self.stream
            // Never move an MP4 still owned by the recording output. Startup recovery
            // finds this app-owned temporary file on the next launch.
            self.complete(outputFinalized: false)
            if let capture { try? await capture.stopCapture() }
        }
    }

    private func deactivatePicker() {
        guard pickerActive else { return }
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
        pickerActive = false
    }
}
#endif
