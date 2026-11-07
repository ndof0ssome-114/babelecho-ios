import Foundation

private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    let allowHTTP: Bool
    init(allowHTTP: Bool) { self.allowHTTP = allowHTTP }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let scheme = request.url?.scheme?.lowercased(),
              let destination = request.url?.host?.lowercased(),
              destination == task.originalRequest?.url?.host?.lowercased(),
              scheme == "https" || (allowHTTP && scheme == "http" && NetworkPolicy.isLocalNetworkHost(destination)) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}

struct ASRUterance {
    let startSeconds: Double
    let endSeconds: Double
    let text: String
    let speaker: String
}

struct ASRResult {
    let text: String
    let provider: String
    let utterances: [ASRUterance]
    let billedSeconds: Double?
}

struct ReportedTextUsage {
    let promptTokens: Int?
    let completionTokens: Int?
    var reasoningTokens: Int? = nil
}

/// Pure network rules shared by every provider call.
enum NetworkPolicy {
    static let maxAttempts = 3
    private static let retryStatus: Set<Int> = [408, 425, 429, 500, 502, 503, 504]

    /// Plain HTTP is only for engines on this device or the local network (Ollama, LM Studio,
    /// whisper.cpp); anything else would carry audio, transcripts and keys unencrypted.
    static func isLocalNetworkHost(_ hostname: String) -> Bool {
        var host = hostname.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.isEmpty { return false }
        if !host.contains(".") && !host.contains(":") { return true }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".lan") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, let octets = Optional(parts.compactMap { Int($0) }), octets.count == 4,
           octets.allSatisfy({ (0...255).contains($0) }) {
            let a = octets[0], b = octets[1]
            return a == 127 || a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) ||
                (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
        }
        if host.contains(":") {
            if host == "::1" { return true }
            let first = host.split(separator: ":").first.map(String.init) ?? ""
            guard first.count == 4, let value = Int(first, radix: 16) else { return false }
            return (0xfc00...0xfdff).contains(value) || (0xfe80...0xfebf).contains(value)
        }
        return false
    }

    /// Seconds before retrying, or nil when the failure must not be retried. Network errors
    /// are never retried here: a timed-out request may already have been billed.
    static func retryDelay(status: Int, retryAfter: String?, attempt: Int, now: Date = .now) -> Double? {
        guard retryStatus.contains(status), attempt + 1 < maxAttempts else { return nil }
        let header = retryAfter?.trimmingCharacters(in: .whitespaces) ?? ""
        var seconds = Double(header)
        if seconds == nil, !header.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            seconds = formatter.date(from: header).map { $0.timeIntervalSince(now) }
        }
        if let value = seconds, value > 0 { return min(30, value) }
        return Double(attempt + 1)
    }

    /// Removes the request's own credential from provider error text before it is shown.
    static func redact(_ text: String, authorization: String?) -> String {
        guard let secret = authorization?.split(separator: " ").last.map(String.init), secret.count >= 4 else { return text }
        return text.replacingOccurrences(of: secret, with: "[redacted]")
    }
}

private struct HTTPFailure: LocalizedError {
    let status: Int
    let detail: String
    let retryAfter: Double?
    var retryAfterHeader: String? = nil
    var errorDescription: String? { "HTTP \(status): \(detail)" }
}

private actor GroqRateGate {
    static let shared = GroqRateGate()
    private var nextRequestAt = Date.distantPast

    func waitForSlot() async throws {
        let slot = max(nextRequestAt, Date.now)
        nextRequestAt = slot.addingTimeInterval(3.5)
        let delay = slot.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    }

    func deferNext(_ seconds: Double) {
        nextRequestAt = max(nextRequestAt, Date.now.addingTimeInterval(seconds))
    }
}

struct CloudClient {
    let settings: AppSettings
    private let asrKey: String
    private let llmKey: String
    private let credentials: (String) -> String
    private let transport: ((URLRequest) async throws -> (Data, HTTPURLResponse))?
    var onTextUsage: ((String, ReportedTextUsage) -> Void)? = nil

    init(settings: AppSettings, credentials: @escaping (String) -> String = SecretStore.read,
         transport: ((URLRequest) async throws -> (Data, HTTPURLResponse))? = nil) {
        self.settings = settings
        self.credentials = credentials
        self.transport = transport
        asrKey = credentials("asr")
        llmKey = credentials("llm")
    }

    var canTranscribe: Bool {
        chosenASR(for: settings.asrLanguage) != nil
    }

    var canChat: Bool { canChat(task: "minutes") }

    func canChat(task: String) -> Bool { chosenTextProvider(for: task) != nil }

    private func chosenASR(for language: String) -> (ASRProvider, String)? {
        for provider in settings.providers?.candidates(for: language) ?? [] {
            let key = credentials("asr.\(provider.id)")
            if !provider.baseURL.isEmpty, !provider.model.isEmpty, provider.noAuth || !key.isEmpty {
                return (provider, provider.noAuth ? "" : key)
            }
        }
        if !settings.asrBaseURL.isEmpty, !settings.asrModel.isEmpty, settings.asrNoAuth || !asrKey.isEmpty {
            return (ASRProvider(id: "custom", kind: "openai-audio", enabled: true,
                                baseURL: settings.asrBaseURL, model: settings.asrModel,
                                languages: ["auto"], noAuth: settings.asrNoAuth), settings.asrNoAuth ? "" : asrKey)
        }
        return nil
    }

    private func chosenTextProvider(for task: String) -> (String, String, String, String?)? {
        if let catalog = settings.providers, let role = catalog.roles[task],
           let provider = catalog.text.first(where: { $0.id == role.provider && $0.enabled }),
           !provider.baseURL.isEmpty, !role.model.isEmpty {
            let key = credentials("llm.\(provider.id)")
            if provider.noAuth || !key.isEmpty { return (provider.baseURL, role.model, provider.noAuth ? "" : key, role.thinking) }
        }
        let model: String
        switch task {
        case "summary": model = settings.summaryModel.isEmpty ? settings.llmModel : settings.summaryModel
        case "minutes": model = settings.minutesModel.isEmpty ? settings.llmModel : settings.minutesModel
        case "translation": model = settings.translationModel.isEmpty ? settings.llmModel : settings.translationModel
        case "ask": model = settings.askModel.isEmpty ? settings.llmModel : settings.askModel
        default: model = settings.llmModel
        }
        if !settings.llmBaseURL.isEmpty, !model.isEmpty, settings.llmNoAuth || !llmKey.isEmpty {
            return (settings.llmBaseURL, model, settings.llmNoAuth ? "" : llmKey, nil)
        }
        return nil
    }

    private func endpoint(_ base: String, path: String) throws -> URL {
        guard let url = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), let host = url.host,
              scheme == "https" || (settings.allowInsecureHTTP && scheme == "http" && NetworkPolicy.isLocalNetworkHost(host)),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AppError.message("Use an HTTPS endpoint. Plain HTTP is only allowed to this device or the local network, after enabling it")
        }
        return url.appendingPathComponent(path)
    }

    /// Sends a request, retrying rate limits and transient server errors after Retry-After.
    /// Groq ASR passes `retryRateLimits: false` because its own rate gate handles 429.
    private func send(_ request: URLRequest, retryRateLimits: Bool = true) async throws -> Data {
        var attempt = 0
        while true {
            do { return try await sendOnce(request) }
            catch let failure as HTTPFailure {
                guard retryRateLimits || failure.status != 429,
                      let delay = NetworkPolicy.retryDelay(status: failure.status, retryAfter: failure.retryAfterHeader, attempt: attempt)
                else { throw failure }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            }
        }
    }

    private func sendOnce(_ request: URLRequest) async throws -> Data {
        let data: Data
        let http: HTTPURLResponse
        if let transport {
            (data, http) = try await transport(request)
        } else {
            let guardDelegate = RedirectGuard(allowHTTP: settings.allowInsecureHTTP)
            let session = URLSession(configuration: .ephemeral, delegate: guardDelegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (body, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw AppError.message("No HTTP response") }
            data = body
            http = response
        }
        guard (200...299).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let provider = (object?["error"] as? [String: Any])?["message"] as? String
            let raw = provider ?? String(decoding: data.prefix(300), as: UTF8.self)
            // Some providers echo the submitted key in their error text.
            let detail = NetworkPolicy.redact(raw, authorization: request.value(forHTTPHeaderField: "Authorization"))
            let header = http.value(forHTTPHeaderField: "Retry-After")
            throw HTTPFailure(status: http.statusCode, detail: String(detail.prefix(300)),
                              retryAfter: header.flatMap(Double.init), retryAfterHeader: header)
        }
        return data
    }

    func transcribe(_ wav: Data, prompt: String = "") async throws -> String {
        try await transcribeResult(wav, prompt: prompt).text
    }

    func transcribeResult(_ wav: Data, prompt: String = "", language: String? = nil) async throws -> ASRResult {
        let language = language ?? settings.asrLanguage
        guard let (provider, key) = chosenASR(for: language) else {
            throw AppError.message("No configured ASR provider supports \(language)")
        }
        switch provider.kind {
        case "mimo": return try await transcribeMiMo(wav, provider: provider, key: key, language: language)
        case "deepgram": return try await transcribeDeepgram(wav, provider: provider, key: key, language: language)
        default:
            let attempts = provider.id == "groq" ? 4 : 1
            for attempt in 0..<attempts {
                if provider.id == "groq" { try await GroqRateGate.shared.waitForSlot() }
                do { return try await transcribeOpenAI(wav, prompt: prompt, provider: provider, key: key, language: language,
                                                       retryRateLimits: provider.id != "groq") }
                catch let failure as HTTPFailure where provider.id == "groq" && failure.status == 429 && attempt + 1 < attempts {
                    await GroqRateGate.shared.deferNext(min(60, max(1, failure.retryAfter ?? 5)))
                }
            }
            throw AppError.message("Groq rate limit persisted after retries")
        }
    }

    private func transcribeOpenAI(_ wav: Data, prompt: String, provider: ASRProvider, key: String, language: String,
                                  retryRateLimits: Bool = true) async throws -> ASRResult {
        let url = try endpoint(provider.baseURL, path: "audio/transcriptions")
        let boundary = UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", provider.model)
        field("response_format", "verbose_json")
        field("temperature", "0")
        if language != "auto" { field("language", language) }
        if !prompt.isEmpty { field("prompt", String(prompt.suffix(240))) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 150
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        let data = try await send(request, retryRateLimits: retryRateLimits)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { throw AppError.message("ASR response has no text") }
        let items = object["segments"] as? [[String: Any]] ?? []
        let utterances = items.compactMap { item -> ASRUterance? in
            guard let start = item["start"] as? Double, let end = item["end"] as? Double,
                  let text = item["text"] as? String, !text.isEmpty else { return nil }
            let speaker = (item["speaker"] as? String) ?? ""
            return ASRUterance(startSeconds: start, endSeconds: end, text: text, speaker: speaker)
        }
        let usage = object["usage"] as? [String: Any]
        let seconds = (usage?["seconds"] as? NSNumber)?.doubleValue ?? (object["duration"] as? NSNumber)?.doubleValue
        return ASRResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider.id,
                         utterances: utterances, billedSeconds: seconds)
    }

    private func transcribeMiMo(_ wav: Data, provider: ASRProvider, key: String, language: String) async throws -> ASRResult {
        guard provider.supports(language) else { throw AppError.message("MiMo ASR only supports Chinese and English") }
        var request = URLRequest(url: try endpoint(provider.baseURL, path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": provider.model,
            "messages": [["role": "user", "content": [["type": "input_audio", "input_audio": ["data": "data:audio/wav;base64,\(wav.base64EncodedString())"]]]]],
            "asr_options": ["language": language == "auto" ? "auto" : language]
        ])
        let data = try await send(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let raw = message["content"] as? String else { throw AppError.message("MiMo response has no text") }
        let cleaned = raw.replacingOccurrences(of: "^\\s*<[a-z_-]{2,20}>\\s*", with: "", options: [.regularExpression, .caseInsensitive])
        let seconds = ((root["usage"] as? [String: Any])?["seconds"] as? NSNumber)?.doubleValue
        return ASRResult(text: cleaned.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider.id,
                         utterances: [], billedSeconds: seconds)
    }

    private func transcribeDeepgram(_ wav: Data, provider: ASRProvider, key: String, language: String) async throws -> ASRResult {
        var components = URLComponents(url: try endpoint(provider.baseURL, path: "listen"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "model", value: provider.model),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "utterances", value: "true")
        ] + (language == "auto" ? [] : [URLQueryItem(name: "language", value: language)])
        guard let url = components?.url else { throw AppError.message("Invalid Deepgram URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Token \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = wav
        let data = try await send(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [String: Any],
              let channels = results["channels"] as? [[String: Any]],
              let alternatives = channels.first?["alternatives"] as? [[String: Any]],
              let text = alternatives.first?["transcript"] as? String else {
            throw AppError.message("Deepgram response has no transcript")
        }
        let items = results["utterances"] as? [[String: Any]] ?? []
        let utterances = items.compactMap { item -> ASRUterance? in
            guard let start = item["start"] as? Double, let end = item["end"] as? Double,
                  let text = item["transcript"] as? String, !text.isEmpty else { return nil }
            let speaker = (item["speaker"] as? Int).map { "Speaker \($0 + 1)" } ?? ""
            return ASRUterance(startSeconds: start, endSeconds: end, text: text, speaker: speaker)
        }
        let seconds = ((root["metadata"] as? [String: Any])?["duration"] as? NSNumber)?.doubleValue
        return ASRResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines), provider: provider.id,
                         utterances: utterances, billedSeconds: seconds)
    }

    func chat(task: String, system: String, user: String) async throws -> String {
        guard let (baseURL, model, key, thinking) = chosenTextProvider(for: task) else {
            throw AppError.message("Configure the text model URL and key first")
        }
        let url = try endpoint(baseURL, path: "chat/completions")
        var object: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]]
        ]
        let usesThinking = ModelRole.isDeepSeek(baseURL) && thinking != "disabled"
        object["max_tokens"] = usesThinking || task == "minutes" ? 16_384 : 4_096 // detailed notes need room, as on desktop
        if ModelRole.isDeepSeek(baseURL), let thinking, ["enabled", "disabled"].contains(thinking) {
            object["thinking"] = ["type": thinking]
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        let data = try await send(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.message("Invalid text model response")
        }
        let usage = root["usage"] as? [String: Any]
        let details = usage?["completion_tokens_details"] as? [String: Any]
        onTextUsage?(task, ReportedTextUsage(
            promptTokens: (usage?["prompt_tokens"] as? NSNumber)?.intValue,
            completionTokens: (usage?["completion_tokens"] as? NSNumber)?.intValue,
            reasoningTokens: (details?["reasoning_tokens"] as? NSNumber)?.intValue))
        guard
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.message("Text model returned no content. Check the model and thinking mode; reported usage has been saved.")
        }
        guard choices.first?["finish_reason"] as? String != "length" else {
            throw AppError.message("Text model reached its output limit. Existing meeting content is preserved; reported usage has been saved.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func discoverModels(baseURL: String, key: String, noAuth: Bool) async throws -> [String] {
        guard noAuth || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.message("Enter this provider's API key or select no API key")
        }
        var request = URLRequest(url: try endpoint(baseURL, path: "models"))
        request.timeoutInterval = 30
        if !noAuth { request.setValue("Bearer \(key.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization") }
        let data = try await send(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { throw AppError.message("This provider has no compatible model list; enter a model ID manually") }
        let models = Set(items.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }).sorted()
        guard !models.isEmpty else { throw AppError.message("No models returned; enter a model ID manually") }
        return models
    }

    private var summaryMaxCharacters: Int { settings.summaryMaxCharacters ?? 900 }

    /// Rolling summary: previous summary plus only the new transcript (desktop prompt).
    func incrementalSummary(previous: String, newSegments: [TranscriptSegment], title: String = "",
                            mode: String = NotesPrompts.meeting) async throws -> String {
        let prompt = NotesPrompts.summary(previous: previous, newSegments: newSegments, maxChars: summaryMaxCharacters, title: title, mode: mode)
        return try await chat(task: "summary", system: prompt.system, user: prompt.user)
    }

    /// Full summary, folded over the transcript in slices exactly like the live summary.
    func fullSummary(_ meeting: Meeting) async throws -> String {
        guard !meeting.segments.isEmpty else { throw AppError.message("Transcribe the meeting first") }
        var summary = ""
        for slice in Self.slices(meeting.segments, maxCharacters: Self.summarySliceCharacters) {
            summary = try await incrementalSummary(previous: summary, newSegments: slice, title: meeting.title, mode: meeting.noteMode)
        }
        return summary
    }

    /// Structured notes in the desktop JSON schema, rendered to Markdown; non-JSON replies are kept as written.
    func minutes(_ meeting: Meeting) async throws -> (text: String, document: MinutesDocument?) {
        guard !meeting.segments.isEmpty else { throw AppError.message("Transcribe the meeting first") }
        var transcript = NotesPrompts.renderTranscript(meeting.segments)
        // Desktop sends the whole transcript; only far beyond a typical context window is it condensed first.
        if transcript.count > Self.minutesFullCharacters {
            transcript = "（转写过长，以下为按顺序整理的完整要点）\n" + (try await fullSummary(meeting))
        }
        let target = meeting.language.isEmpty || meeting.language == "auto" ? "zh" : meeting.language
        let prompt = NotesPrompts.minutes(transcript: transcript, title: meeting.title, summary: meeting.summary,
                                          targetLanguage: target, mode: meeting.noteMode, notesDetail: meeting.noteDetail)
        let answer = try await chat(task: "minutes", system: prompt.system, user: prompt.user)
        guard let data = MinutesRenderer.parse(answer) else { return (answer, nil) }
        let markdown = MinutesRenderer.render(data, mode: meeting.noteMode, language: settings.uiLanguage)
        let document = (try? JSONSerialization.data(withJSONObject: data)).flatMap { try? JSONDecoder().decode(MinutesDocument.self, from: $0) }
        return (markdown, document)
    }

    /// Batches of 20 with the two preceding sentences as context (desktop behaviour).
    func translate(_ segments: [TranscriptSegment], to language: String, context: [String] = []) async throws -> [UUID: String] {
        guard !segments.isEmpty, !language.isEmpty else { return [:] }
        var map: [UUID: String] = [:]
        var before = Array(context.suffix(2))
        for start in stride(from: 0, to: segments.count, by: Self.translateBatch) {
            let batch = Array(segments[start..<min(start + Self.translateBatch, segments.count)])
            let prompt = NotesPrompts.translate(batch.map { ($0.id.uuidString, $0.text) }, target: language, context: before)
            let answer = try await chat(task: "translation", system: prompt.system, user: prompt.user)
            guard let result = MinutesRenderer.parse(answer), let items = result["translations"] as? [[String: Any]] else {
                throw AppError.message("Translation response was not valid JSON")
            }
            for item in items {
                if let id = item["id"] as? String, let uuid = UUID(uuidString: id), let text = item["text"] as? String, !text.isEmpty { map[uuid] = text }
            }
            before = batch.suffix(2).map(\.text)
        }
        return map
    }

    func answer(_ question: String, meeting: Meeting) async throws -> String {
        guard !meeting.segments.isEmpty else { throw AppError.message("Transcribe the meeting first") }
        let prompt = NotesPrompts.ask(question, transcript: NotesPrompts.renderTranscript(meeting.segments), summary: meeting.summary,
                                      history: meeting.questions.map { ($0.question, $0.answer) })
        return try await chat(task: "ask", system: prompt.system, user: prompt.user)
    }

    /// Text-only speaker attribution in batches of 150, keeping labels consistent across batches.
    func resplitSpeakers(_ segments: [TranscriptSegment]) async throws -> [UUID: String] {
        guard !segments.isEmpty else { return [:] }
        var known: [String] = []
        for segment in segments where !segment.speaker.isEmpty && !known.contains(segment.speaker) { known.append(segment.speaker) }
        var result: [UUID: String] = [:]
        for start in stride(from: 0, to: segments.count, by: Self.resplitBatch) {
            let batch = Array(segments[start..<min(start + Self.resplitBatch, segments.count)])
            let prompt = NotesPrompts.speakerSplit(batch, known: known)
            let answer = try await chat(task: "speaker", system: prompt.system, user: prompt.user)
            guard let root = MinutesRenderer.parse(answer), let items = root["assignments"] as? [[String: Any]] else {
                throw AppError.message("Speaker assignment was not valid JSON")
            }
            for item in items {
                guard let rawID = item["id"] as? String, let id = UUID(uuidString: rawID),
                      let speaker = (item["speaker"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !speaker.isEmpty else { continue }
                result[id] = String(speaker.prefix(60))
                if !known.contains(speaker) { known.append(speaker) }
            }
        }
        return result
    }

    static let summarySliceCharacters = 24_000
    static let minutesFullCharacters = 120_000
    static let translateBatch = 20
    static let resplitBatch = 150

    static func slices(_ segments: [TranscriptSegment], maxCharacters: Int) -> [[TranscriptSegment]] {
        var out: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var size = 0
        for segment in segments {
            let length = segment.text.count + 16
            if !current.isEmpty && size + length > maxCharacters { out.append(current); current = []; size = 0 }
            current.append(segment)
            size += length
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func render(_ segments: [TranscriptSegment]) -> String {
        segments.map { "[\(String(format: "%02d:%02d", $0.startMs / 60_000, $0.startMs / 1000 % 60))] \($0.speaker.isEmpty ? "Speaker" : $0.speaker): \($0.text)" }.joined(separator: "\n")
    }
}

private extension String {
    func chunked(maxLength: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in split(separator: "\n", omittingEmptySubsequences: false) {
            var remaining = String(line) + "\n"
            while !remaining.isEmpty {
                let capacity = max(1, maxLength - current.count)
                let part = String(remaining.prefix(capacity))
                current += part
                remaining.removeFirst(part.count)
                if current.count >= maxLength { chunks.append(current); current = "" }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
