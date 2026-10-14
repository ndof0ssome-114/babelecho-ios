import AVFoundation
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    @Published var selectedID: UUID?
    @Published private(set) var settings: AppSettings
    @Published private(set) var isRecording = false
    @Published private(set) var startingRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var finishing = false
    @Published private(set) var level: Float = 0
    @Published private(set) var recordingDurationMs = 0
    @Published private(set) var busy = false
    @Published private(set) var importStatus = ""
    @Published private(set) var partialText = ""
    @Published private(set) var isScreenCapturing = false
    @Published private(set) var isScreenPickerPending = false
    @Published private(set) var screenCaptureFinishing = false
    @Published var message: String?

    private let store: MeetingStore
    private let defaults: UserDefaults
    private let recorder = AudioRecorder()
    private var asrTail: Task<Void, Never>?
    private var pendingChunks = 0
    private var previousASRText = ""
    private var lastSummaryAt = Date()
    private var recordingID: UUID?
    private var activeUtteranceID: UUID?
    private var displayCapture: AnyObject?
    private var screenSessionID: UUID?
    private var summarizing = Set<UUID>()

    var canStartCapture: Bool {
        !startingRecording && !isRecording && !finishing && !busy && !isScreenPickerPending && !isScreenCapturing && !screenCaptureFinishing
    }

    var selected: Meeting? { meetings.first { $0.id == selectedID } }
    var asrKey: String { SecretStore.read("asr") }
    var llmKey: String { SecretStore.read("llm") }

    init() {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-fixture") {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BabelEcho-UITests/Meetings")
            store = MeetingStore(root: root)
            defaults = UserDefaults(suiteName: "app.babelecho.ios.uitests")!
            defaults.removePersistentDomain(forName: "app.babelecho.ios.uitests")
            var fixture = Meeting(title: "Synthetic UI test")
            fixture.id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
            fixture.state = "stopped"
            fixture.durationMs = 4000
            fixture.segments = [TranscriptSegment(startMs: 0, endMs: 1000, text: "Synthetic test transcript.", translation: "合成测试文字。", speaker: "Speaker 1")]
            fixture.summary = "Synthetic summary."
            fixture.minutes = "Synthetic minutes."
            fixture.questions = [QuestionAnswer(question: "Test question?", answer: "Synthetic answer.")]
            try? store.save(fixture)
            if let writer = try? WAVWriter(url: store.audioURL(for: fixture)) {
                try? writer.append([Int16](repeating: 0, count: 64_000))
                try? writer.close()
            }
            var testSettings = AppSettings()
            testSettings.uiLanguage = "en"
            defaults.set(try? JSONEncoder().encode(testSettings), forKey: "settings.v1")
        } else {
            store = MeetingStore()
            defaults = .standard
        }
        #else
        store = MeetingStore()
        defaults = .standard
        #endif
        if let data = defaults.data(forKey: "settings.v1"),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) { settings = decoded }
        else { settings = AppSettings() }
        let recoveredScreens = store.recoverOrphanedScreenCaptures()
        meetings = store.list()
        selectedID = meetings.first?.id
        if recoveredScreens > 0 { message = "Recovered \(recoveredScreens) interrupted screen capture(s); open the meeting to retry audio extraction or export the original." }
        recorder.onChunk = { [weak self] chunk in self?.enqueue(chunk) }
        recorder.onLevel = { [weak self] value in
            self?.level = value
            self?.recordingDurationMs = self?.recorder.durationMs ?? 0
        }
        recorder.onInterruption = { [weak self] in
            Task { await self?.stopRecording(); self?.message = "Recording stopped because audio was interrupted" }
        }
    }

    func saveSettings(_ value: AppSettings, asrKey: String, llmKey: String, providerKeys: [String: String] = [:]) {
        do {
            let validated = try value.validated()
            try SecretStore.write(asrKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "asr")
            try SecretStore.write(llmKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "llm")
            for (account, key) in providerKeys {
                try SecretStore.write(key.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
            }
            let data = try JSONEncoder().encode(validated)
            defaults.set(data, forKey: "settings.v1")
            settings = validated
            message = L10n.text(settings.uiLanguage, "设置已保存", "設定を保存しました", "Settings saved")
        } catch { message = error.localizedDescription }
    }

    func startRecording() async {
        guard canStartCapture else { return }
        startingRecording = true
        defer { startingRecording = false }
        let permitted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard permitted else {
            message = L10n.text(settings.uiLanguage, "请在系统设置中允许麦克风权限", "設定でマイクの使用を許可してください", "Allow microphone access in Settings")
            return
        }
        var meeting = Meeting(title: Date.now.formatted(date: .abbreviated, time: .shortened))
        meeting.language = settings.asrLanguage
        meeting.translateTo = settings.translateTo
        do {
            try store.save(meeting)
            try recorder.start(url: store.audioURL(for: meeting), settings: settings)
            recordingID = meeting.id
            previousASRText = ""
            partialText = ""
            activeUtteranceID = nil
            pendingChunks = 0
            lastSummaryAt = .now
            isRecording = true
            isPaused = false
            recordingDurationMs = 0
            refresh(select: meeting.id)
            if settings.liveTranscription && !CloudClient(settings: settings).canTranscribe {
                message = L10n.text(settings.uiLanguage, "录音已保存；实时识别需要先配置 ASR", "録音中です。リアルタイム認識には ASR 設定が必要です", "Recording locally; configure ASR for live transcription")
            }
        } catch {
            meeting.state = "failed"
            try? store.save(meeting)
            message = error.localizedDescription
        }
    }

    func pauseOrResume() {
        guard isRecording, let id = recordingID else { return }
        isPaused.toggle()
        recorder.setPaused(isPaused)
        update(id) { $0.state = isPaused ? "paused" : "recording" }
    }

    func stopRecording() async {
        guard isRecording, let id = recordingID else { return }
        finishing = true
        defer { finishing = false }
        isRecording = false
        isPaused = false
        do {
            let duration = try recorder.stop()
            update(id) { $0.durationMs = duration; $0.state = "stopped" }
        } catch { message = error.localizedDescription }
        level = 0
        partialText = ""
        activeUtteranceID = nil
        // Recorder callbacks are queued on the main dispatch queue in audio order.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        await asrTail?.value
        asrTail = nil
        recordingID = nil
        if CloudClient(settings: settings).canChat(task: "minutes"),
           let meeting = meetings.first(where: { $0.id == id }), !meeting.segments.isEmpty {
            Task { await createMinutes(for: id) }
        }
    }

    private func enqueue(_ chunk: AudioRecorder.Chunk) {
        guard let id = recordingID else { return }
        if !chunk.isFinal && pendingChunks > 0 { return }
        activeUtteranceID = chunk.isFinal ? nil : chunk.utteranceID
        if chunk.isFinal { partialText = "" }
        guard pendingChunks < 6 else {
            message = L10n.text(settings.uiLanguage, "识别处理较慢，部分实时片段已跳过；完整录音仍在本机，可稍后重新转写。", "認識が遅いため一部のリアルタイム区間をスキップしました。録音は端末に残り、後で再認識できます。", "ASR is behind; some live chunks were skipped. The full recording remains available for retranscription.")
            return
        }
        pendingChunks += 1
        let predecessor = asrTail
        let snapshot = settings
        asrTail = Task { [weak self] in
            await predecessor?.value
            guard let self else { return }
            defer { self.pendingChunks -= 1 }
            let client = self.client(for: id, settings: snapshot)
            guard client.canTranscribe else { return }
            do {
                let result = try await client.transcribeResult(chunk.wav, prompt: self.previousASRText)
                self.recordASRUsage(result, for: id, fallbackSeconds: Double(chunk.endMs - chunk.startMs) / 1000,
                                    settings: snapshot)
                if !chunk.isFinal {
                    if self.activeUtteranceID == chunk.utteranceID { self.partialText = result.text }
                    return
                }
                let additions = Self.makeSegments(result, startMs: chunk.startMs,
                                                  endMs: chunk.endMs, previous: self.previousASRText)
                guard !additions.isEmpty else { return }
                self.previousASRText = String(result.text.suffix(240))
                self.update(id) { meeting in
                    meeting.segments.append(contentsOf: Self.assignSpeakers(additions, after: meeting.segments))
                }
                if !snapshot.translateTo.isEmpty { await self.translateLatest(for: id, with: client, target: snapshot.translateTo) }
                await self.summarizeIfDue(for: id, with: client, settings: snapshot)
            } catch { if chunk.isFinal { self.message = "ASR: \(error.localizedDescription)" } }
        }
    }

    private func summarizeIfDue(for id: UUID, with client: CloudClient, settings: AppSettings) async {
        guard !summarizing.contains(id), settings.autoSummarySeconds > 0,
              client.canChat(task: "summary"),
              Date.now.timeIntervalSince(lastSummaryAt) >= Double(settings.autoSummarySeconds),
              let meeting = meetings.first(where: { $0.id == id }),
              meeting.summaryUpTo < meeting.segments.count else { return }
        let upTo = meeting.segments.count
        let newSegments = Array(meeting.segments[meeting.summaryUpTo..<upTo])
        guard newSegments.reduce(0, { $0 + $1.text.count }) >= (settings.autoSummaryMinCharacters ?? 200) else { return }
        summarizing.insert(id)
        defer { summarizing.remove(id) }
        do {
            let summary = try await client.incrementalSummary(previous: meeting.summary,
                newSegments: newSegments)
            update(id) { $0.summary = summary; $0.summaryUpTo = upTo; $0.llmCalls += 1 }
            lastSummaryAt = .now
        } catch { message = "Summary: \(error.localizedDescription)" }
    }

    private func translateLatest(for id: UUID, with client: CloudClient, target: String) async {
        guard let segment = meetings.first(where: { $0.id == id })?.segments.last else { return }
        do {
            let map = try await client.translate([segment], to: target)
            if let text = map[segment.id] {
                update(id) { meeting in
                    if let index = meeting.segments.firstIndex(where: { $0.id == segment.id }) {
                        meeting.segments[index].translation = text
                        meeting.llmCalls += 1
                    }
                }
            }
        } catch { message = "Translation: \(error.localizedDescription)" }
    }

    func transcribeSaved(for id: UUID) async {
        guard !busy && !finishing, let meeting = meetings.first(where: { $0.id == id }), meeting.state == "stopped" else { return }
        busy = true
        defer { busy = false }
        do { try await transcribeFile(meeting, client: client(for: id, settings: settings)) }
        catch { message = error.localizedDescription }
    }

    func importMedia(_ urls: [URL], processAI: Bool) async {
        guard canStartCapture else { return }
        busy = true
        defer { busy = false; importStatus = "" }
        for source in urls {
            let scoped = source.startAccessingSecurityScopedResource()
            var meeting = Meeting(title: source.deletingPathExtension().lastPathComponent)
            meeting.source = "import"
            meeting.state = "processing"
            meeting.language = settings.asrLanguage
            meeting.translateTo = settings.translateTo
            do {
                try store.save(meeting)
                refresh(select: meeting.id)
                importStatus = L10n.text(settings.uiLanguage, "正在导入 \(meeting.title)", "\(meeting.title) を読み込み中", "Importing \(meeting.title)")
                let duration = try await MediaImporter.convertToWAV(source: source, destination: store.audioURL(for: meeting))
                update(meeting.id) { $0.durationMs = duration; $0.state = "stopped" }
                if processAI {
                    let client = client(for: meeting.id, settings: settings)
                    if client.canTranscribe {
                        guard let saved = meetings.first(where: { $0.id == meeting.id }) else {
                            throw AppError.message("Imported meeting was not saved")
                        }
                        try await transcribeFile(saved, client: client)
                        if client.canChat(task: "minutes"), let ready = meetings.first(where: { $0.id == meeting.id }), !ready.segments.isEmpty {
                            let result = try await client.minutes(ready)
                            update(meeting.id) { $0.minutes = result.text; $0.minutesDocument = result.document; $0.llmCalls += 1 }
                        }
                    }
                }
            } catch {
                if meetings.first(where: { $0.id == meeting.id })?.durationMs == 0 { update(meeting.id) { $0.state = "failed" } }
                message = "\(meeting.title): \(error.localizedDescription)"
            }
            if scoped { source.stopAccessingSecurityScopedResource() }
        }
    }

    func startScreenCapture() {
        guard canStartCapture else { return }
        #if !targetEnvironment(simulator)
        guard #available(iOS 27.0, *) else {
            message = "Full-display audio capture requires iOS 27 or later"
            return
        }
        let capture = DisplayCapture()
        let sessionID = UUID()
        screenSessionID = sessionID
        capture.onStarted = { [weak self] in
            Task { @MainActor in
                guard let self, self.screenSessionID == sessionID else { return }
                self.isScreenPickerPending = false
                self.isScreenCapturing = true
            }
        }
        capture.onFinished = { [weak self] url in
            Task { @MainActor in
                guard let self, self.screenSessionID == sessionID else { return }
                await self.finishScreenCapture(url)
            }
        }
        capture.onError = { [weak self] error, recovery in
            Task { @MainActor in
                guard let self, self.screenSessionID == sessionID else { return }
                if let recovery, FileManager.default.fileExists(atPath: recovery.path) {
                    self.preserveFailedScreenCapture(recovery)
                }
                self.isScreenCapturing = false
                self.isScreenPickerPending = false
                self.screenCaptureFinishing = false
                self.displayCapture = nil
                self.screenSessionID = nil
                self.message = error.localizedDescription
            }
        }
        capture.onCancelled = { [weak self] in
            Task { @MainActor in
                guard let self, self.screenSessionID == sessionID else { return }
                self.isScreenPickerPending = false
                self.displayCapture = nil
                self.screenSessionID = nil
            }
        }
        displayCapture = capture
        isScreenPickerPending = true
        do { try capture.present() }
        catch {
            isScreenPickerPending = false
            displayCapture = nil
            screenSessionID = nil
            message = error.localizedDescription
        }
        #else
        message = "Full-display audio capture requires a physical iOS 27 device"
        #endif
    }

    func cancelScreenCapturePicker() {
        #if !targetEnvironment(simulator)
        guard #available(iOS 27.0, *), isScreenPickerPending,
              let capture = displayCapture as? DisplayCapture else { return }
        capture.cancelPicker()
        #endif
    }

    func stopScreenCapture() async {
        #if !targetEnvironment(simulator)
        guard #available(iOS 27.0, *), let capture = displayCapture as? DisplayCapture,
              isScreenCapturing, !screenCaptureFinishing else { return }
        screenCaptureFinishing = true
        await capture.stop()
        #endif
    }

    private func finishScreenCapture(_ url: URL) async {
        isScreenPickerPending = false
        isScreenCapturing = false
        screenCaptureFinishing = true
        defer { screenCaptureFinishing = false; displayCapture = nil; screenSessionID = nil }
        guard !busy else {
            preserveFailedScreenCapture(url)
            message = "Screen recording preserved; retry audio extraction when the current task finishes"
            return
        }
        busy = true
        defer { busy = false; importStatus = "" }
        var meeting = Meeting(title: Date.now.formatted(date: .abbreviated, time: .shortened))
        meeting.source = "screen"
        meeting.state = "processing"
        meeting.language = settings.asrLanguage
        meeting.translateTo = settings.translateTo
        do {
            try store.save(meeting)
            refresh(select: meeting.id)
            importStatus = L10n.text(settings.uiLanguage, "正在保存屏幕声音", "画面の音声を保存中", "Saving screen audio")
            let duration = try await MediaImporter.convertToWAV(source: url, destination: store.audioURL(for: meeting))
            meeting.durationMs = duration
            meeting.state = "stopped"
            try store.save(meeting)
            refresh(select: meeting.id)
            try FileManager.default.removeItem(at: url)
            message = L10n.text(settings.uiLanguage, "屏幕声音已存到本机；可按需转写。", "画面の音声を端末に保存しました。必要なら文字起こしできます。", "Screen audio saved locally. You can transcribe it when ready.")
        } catch {
            let recovery = store.screenRecoveryURL(for: meeting)
            if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.moveItem(at: url, to: recovery) }
            update(meeting.id) { $0.state = "failed" }
            message = "Screen audio conversion failed: \(error.localizedDescription). Original capture preserved for recovery."
        }
    }

    private func preserveFailedScreenCapture(_ url: URL) {
        var meeting = Meeting(title: "Screen capture recovery \(Date.now.formatted(date: .abbreviated, time: .shortened))")
        meeting.source = "screen"
        meeting.state = "failed"
        do {
            try store.save(meeting)
            let recovery = store.screenRecoveryURL(for: meeting)
            try FileManager.default.moveItem(at: url, to: recovery)
            refresh(select: meeting.id)
        } catch { message = "Could not preserve screen capture: \(error.localizedDescription)" }
    }

    func screenRecoveryURL(for id: UUID) -> URL? {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return nil }
        let url = store.screenRecoveryURL(for: meeting)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func retryScreenRecovery(for id: UUID) async {
        guard canStartCapture,
              let meeting = meetings.first(where: { $0.id == id }),
              let recovery = screenRecoveryURL(for: id) else { return }
        busy = true
        defer { busy = false; importStatus = "" }
        do {
            importStatus = L10n.text(settings.uiLanguage, "正在恢复屏幕声音", "画面の音声を復旧中", "Recovering screen audio")
            let duration = try await MediaImporter.convertToWAV(source: recovery, destination: store.audioURL(for: meeting))
            var ready = meeting
            ready.durationMs = duration
            ready.state = "stopped"
            try store.save(ready)
            refresh(select: id)
            try FileManager.default.removeItem(at: recovery)
            message = L10n.text(settings.uiLanguage, "屏幕声音恢复成功", "画面の音声を復旧しました", "Screen audio recovered")
        } catch { message = "Screen capture recovery failed: \(error.localizedDescription)" }
    }

    private func transcribeFile(_ meeting: Meeting, client: CloudClient) async throws {
            guard client.canTranscribe else { throw AppError.message("Configure ASR first") }
            let id = meeting.id
            let url = store.audioURL(for: meeting)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 44)
            let window = settings.chunkSeconds * 32_000
            let overlap = settings.overlapSeconds * 32_000
            var carry = Data()
            var segments: [TranscriptSegment] = []
            var calls = 0
            var startMs = 0
            var tail = ""
            while true {
                var bytes = Data()
                let requested = max(1, window - carry.count)
                while bytes.count < requested {
                    let part = try handle.read(upToCount: requested - bytes.count) ?? Data()
                    if part.isEmpty { break }
                    bytes.append(part)
                }
                if bytes.isEmpty { break }
                var pcm = carry
                pcm.append(bytes)
                if pcm.isEmpty { break }
                var wav = AudioRecorder.wavHeader(bytes: pcm.count)
                wav.append(pcm)
                let result = try await client.transcribeResult(wav, prompt: tail)
                recordASRUsage(result, for: id, fallbackSeconds: Double(pcm.count) / 32_000,
                               settings: settings)
                let additions = Self.makeSegments(result, startMs: startMs,
                    endMs: startMs + pcm.count / 32, previous: tail)
                segments.append(contentsOf: Self.assignSpeakers(additions, after: segments))
                tail = String(result.text.suffix(240))
                calls += 1
                importStatus = L10n.text(settings.uiLanguage, "正在识别第 \(calls) 段", "\(calls) 番目の区間を認識中", "Transcribing chunk \(calls)")
                if pcm.count < window { break }
                carry = Data(pcm.suffix(overlap))
                startMs += (window - overlap) / 32
            }
            update(id) {
                $0.segments = segments
                $0.summary = ""
                $0.summaryUpTo = 0
                $0.minutes = ""
                $0.minutesDocument = nil
            }
    }

    func summarize(for id: UUID) async {
        guard !summarizing.contains(id) else { return }
        summarizing.insert(id)
        defer { summarizing.remove(id) }
        await operate(id) { meeting, client in
            let summary = try await client.fullSummary(meeting)
            self.update(id) { $0.summary = summary; $0.summaryUpTo = meeting.segments.count; $0.llmCalls += 1 }
        }
    }

    func createMinutes(for id: UUID) async {
        await operate(id) { meeting, client in
            let result = try await client.minutes(meeting)
            self.update(id) { $0.minutes = result.text; $0.minutesDocument = result.document; $0.llmCalls += 1 }
        }
    }

    func translateAll(for id: UUID) async {
        await operate(id) { meeting, client in
            guard !self.settings.translateTo.isEmpty else { throw AppError.message("Choose a translation language") }
            for batch in stride(from: 0, to: meeting.segments.count, by: 20) {
                let slice = Array(meeting.segments[batch..<min(batch + 20, meeting.segments.count)])
                let map = try await client.translate(slice, to: self.settings.translateTo)
                self.update(id) { value in
                    for index in value.segments.indices {
                        if let text = map[value.segments[index].id] { value.segments[index].translation = text }
                    }
                    value.translateTo = self.settings.translateTo
                    value.llmCalls += 1
                }
            }
        }
    }

    func ask(_ question: String, for id: UUID) async {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await operate(id) { meeting, client in
            let answer = try await client.answer(question, meeting: meeting)
            self.update(id) { $0.questions.append(QuestionAnswer(question: question, answer: answer)); $0.llmCalls += 1 }
        }
    }

    func renameSpeaker(_ source: String, to name: String, for id: UUID) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !clean.isEmpty else { return }
        update(id) { meeting in
            for index in meeting.segments.indices where meeting.segments[index].speaker == source {
                meeting.segments[index].speaker = String(clean.prefix(80))
            }
        }
    }

    func resplitSpeakers(for id: UUID) async {
        await operate(id) { meeting, client in
            let assignments = try await client.resplitSpeakers(meeting.segments)
            self.update(id) { value in
                for index in value.segments.indices {
                    if let speaker = assignments[value.segments[index].id] { value.segments[index].speaker = speaker }
                }
                value.llmCalls += 1
            }
        }
    }

    private func operate(_ id: UUID, action: (Meeting, CloudClient) async throws -> Void) async {
        guard !busy && !finishing, let meeting = meetings.first(where: { $0.id == id }) else { return }
        busy = true
        defer { busy = false }
        do { try await action(meeting, client(for: id, settings: settings)) }
        catch { message = error.localizedDescription }
    }

    private func client(for id: UUID, settings: AppSettings) -> CloudClient {
        var client = CloudClient(settings: settings)
        client.onTextUsage = { [weak self] task, reported in
            Task { @MainActor in
                self?.update(id) { meeting in
                    var byTask = meeting.textUsageByTask ?? [:]
                    var item = byTask[task] ?? TextUsage()
                    item.calls += 1
                    if let input = reported.promptTokens, let output = reported.completionTokens {
                        item.promptTokens += max(0, input)
                        item.completionTokens += max(0, output)
                    } else { item.unreportedCalls += 1 }
                    if let reasoning = reported.reasoningTokens {
                        item.reasoningTokens = (item.reasoningTokens ?? 0) + max(0, reasoning)
                    }
                    byTask[task] = item
                    meeting.textUsageByTask = byTask
                }
            }
        }
        return client
    }

    private func recordASRUsage(_ result: ASRResult, for id: UUID, fallbackSeconds: Double, settings: AppSettings) {
        let seconds = max(0, result.billedSeconds ?? fallbackSeconds)
        let provider = settings.providers?.asr.first(where: { $0.id == result.provider })
        update(id) { meeting in
            meeting.asrCalls += 1
            meeting.asrProcessedSeconds = (meeting.asrProcessedSeconds ?? 0) + seconds
            if let price = provider?.pricePerHour, price > 0 {
                let currency = provider?.currency ?? "USD"
                var costs = meeting.asrEstimatedCostByCurrency ?? [:]
                costs[currency, default: 0] += seconds / 3600 * price
                meeting.asrEstimatedCostByCurrency = costs
            }
        }
    }

    func rename(_ id: UUID, title: String) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        update(id) { $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func delete(_ id: UUID) {
        guard !isRecording, let meeting = meetings.first(where: { $0.id == id }) else { return }
        do { try store.delete(meeting); refresh() }
        catch { message = error.localizedDescription }
    }

    func export(_ id: UUID, format: String) -> URL? {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return nil }
        do { return try store.export(meeting, format: format) }
        catch { message = error.localizedDescription; return nil }
    }

    func audioURL(for id: UUID) -> URL? {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return nil }
        let url = store.audioURL(for: meeting)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func update(_ id: UUID, edit: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        var value = meetings[index]
        edit(&value)
        do { try store.save(value); meetings[index] = value }
        catch { message = "Save: \(error.localizedDescription)" }
    }

    private func refresh(select id: UUID? = nil) {
        meetings = store.list()
        selectedID = id ?? selectedID.flatMap { current in meetings.contains(where: { $0.id == current }) ? current : nil } ?? meetings.first?.id
    }

    private static func trimOverlap(previous: String, current: String) -> String {
        let current = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let maximum = min(120, previous.count, current.count)
        if maximum >= 4 {
            for count in stride(from: maximum, through: 4, by: -1) {
                if previous.suffix(count).lowercased() == current.prefix(count).lowercased() {
                    return String(current.dropFirst(count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return current
    }

    private static func makeSegments(_ result: ASRResult, startMs: Int, endMs: Int, previous: String) -> [TranscriptSegment] {
        if result.utterances.isEmpty {
            let text = trimOverlap(previous: previous, current: result.text)
            return text.isEmpty ? [] : [TranscriptSegment(startMs: startMs, endMs: endMs,
                text: text, provider: result.provider)]
        }
        return result.utterances.enumerated().compactMap { index, utterance in
            let text = index == 0 ? trimOverlap(previous: previous, current: utterance.text) : utterance.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TranscriptSegment(startMs: startMs + Int(utterance.startSeconds * 1000),
                endMs: min(endMs, startMs + Int(utterance.endSeconds * 1000)), text: text,
                speaker: utterance.speaker, provider: result.provider)
        }
    }

    private static func assignSpeakers(_ additions: [TranscriptSegment], after existing: [TranscriptSegment]) -> [TranscriptSegment] {
        var previous = existing.last
        return additions.map { segment in
            var value = segment
            if value.speaker.isEmpty {
                if let prior = previous, value.startMs - prior.endMs < 1_400 {
                    value.speaker = prior.speaker.isEmpty ? "Speaker 1" : prior.speaker
                } else if previous?.speaker == "Speaker 1" { value.speaker = "Speaker 2" }
                else { value.speaker = "Speaker 1" }
            }
            previous = value
            return value
        }
    }
}
