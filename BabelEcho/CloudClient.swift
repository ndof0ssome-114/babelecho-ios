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
              scheme == "https" || (allowHTTP && scheme == "http") else {
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

private struct HTTPFailure: LocalizedError {
    let status: Int
    let detail: String
    let retryAfter: Double?
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
              let scheme = url.scheme?.lowercased(), url.host != nil,
              scheme == "https" || (settings.allowInsecureHTTP && scheme == "http"),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AppError.message("Use an HTTPS endpoint, or explicitly enable HTTP for a trusted service")
        }
        return url.appendingPathComponent(path)
    }

    private func send(_ request: URLRequest) async throws -> Data {
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
            let detail = provider ?? String(decoding: data.prefix(300), as: UTF8.self)
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw HTTPFailure(status: http.statusCode, detail: String(detail.prefix(300)), retryAfter: retryAfter)
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
                do { return try await transcribeOpenAI(wav, prompt: prompt, provider: provider, key: key, language: language) }
                catch let failure as HTTPFailure where provider.id == "groq" && failure.status == 429 && attempt + 1 < attempts {
                    await GroqRateGate.shared.deferNext(min(60, max(1, failure.retryAfter ?? 5)))
                }
            }
            throw AppError.message("Groq rate limit persisted after retries")
        }
    }

    private func transcribeOpenAI(_ wav: Data, prompt: String, provider: ASRProvider, key: String, language: String) async throws -> ASRResult {
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
        let data = try await send(request)
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
        object["max_tokens"] = usesThinking ? 16_384 : (task == "minutes" ? 8_192 : 4_096)
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

    func incrementalSummary(previous: String, newSegments: [TranscriptSegment]) async throws -> String {
        let transcript = Self.render(newSegments)
        return try await chat(task: "summary", system:
            "Update the complete meeting summary using only stated facts. Keep names, numbers, decisions and unresolved items. Use the transcript's primary language and concise Markdown. Never invent facts.",
            user: "Previous summary:\n\(previous.isEmpty ? "(none)" : previous)\n\nNew transcript only:\n\(transcript)")
    }

    func fullSummary(_ meeting: Meeting) async throws -> String {
        guard !meeting.segments.isEmpty else { throw AppError.message("Transcribe the meeting first") }
        let text = Self.render(meeting.segments)
        let pieces = text.chunked(maxLength: 12_000)
        if pieces.count == 1 {
            return try await chat(task: "summary", system: "Summarize this meeting in its primary language. Preserve stated names, numbers, decisions, actions and unresolved questions. Never invent facts.", user: text)
        }
        var partials: [String] = []
        for piece in pieces {
            partials.append(try await chat(task: "summary", system: "Summarize this portion of a meeting without inventing facts. Preserve names, numbers, decisions and actions.", user: piece))
        }
        return try await chat(task: "summary", system: "Combine these partial summaries into complete concise Markdown meeting summary. Do not invent facts.", user: partials.joined(separator: "\n\n---\n\n"))
    }

    func minutes(_ meeting: Meeting) async throws -> (text: String, document: MinutesDocument?) {
        guard !meeting.segments.isEmpty else { throw AppError.message("Transcribe the meeting first") }
        let transcript = Self.render(meeting.segments)
        let pieces = transcript.chunked(maxLength: 12_000)
        let evidence: String
        if pieces.count == 1 { evidence = transcript }
        else {
            var notes: [String] = []
            for (index, piece) in pieces.enumerated() {
                let note = try await chat(task: "minutes", system: "Extract factual meeting notes from this portion only. Preserve stated names, dates, decisions, actions, risks, questions and timestamps. Never invent facts. Keep it concise Markdown.",
                                          user: "Part \(index + 1) of \(pieces.count):\n\(piece)")
                notes.append(note)
            }
            evidence = notes.joined(separator: "\n\n---\n\n")
        }
        let schema = """
        {"title":"one-line topic","abstract":"overview","participants":[],
         "decisions":[{"decision":"","context":""}],
         "actionItems":[{"task":"","owner":"TBD","due":"TBD"}],
         "risks":[{"risk":"","impact":""}],"openQuestions":[],"keywords":[],
         "chapters":[{"title":"","start":"mm:ss","summary":""}]}
        """
        let answer = try await chat(task: "minutes", system: "Write structured meeting minutes using only transcript facts. Preserve names, numbers and timestamps. Never invent participants, decisions, owners or dates. Return one JSON object with this schema and no markdown fences: \(schema)",
                                    user: "Title: \(meeting.title)\nSummary: \(meeting.summary)\nTranscript evidence:\n\(evidence)")
        if let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start <= end,
           let document = try? JSONDecoder().decode(MinutesDocument.self, from: Data(answer[start...end].utf8)),
           !document.markdown.isEmpty {
            return (document.markdown, document)
        }
        return (answer, nil)
    }

    func translate(_ segments: [TranscriptSegment], to language: String) async throws -> [UUID: String] {
        guard !segments.isEmpty, !language.isEmpty else { return [:] }
        let input = segments.map { ["id": $0.id.uuidString, "text": $0.text] }
        let data = try JSONSerialization.data(withJSONObject: input)
        let answer = try await chat(task: "translation", system: "Translate every segment into language code \(language). Preserve meaning, tone, names and terms. Return only JSON: {\"translations\":[{\"id\":\"UUID\",\"text\":\"translation\"}]}", user: String(decoding: data, as: UTF8.self))
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start <= end,
              let result = try JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) as? [String: Any],
              let items = result["translations"] as? [[String: Any]] else { throw AppError.message("Translation response was not valid JSON") }
        var map: [UUID: String] = [:]
        for item in items {
            if let id = item["id"] as? String, let uuid = UUID(uuidString: id), let text = item["text"] as? String { map[uuid] = text }
        }
        return map
    }

    func answer(_ question: String, meeting: Meeting) async throws -> String {
        guard !meeting.segments.isEmpty else { throw AppError.message("Transcribe the meeting first") }
        let history = meeting.questions.suffix(4).map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n")
        return try await chat(task: "ask", system: "Answer only from the meeting record. If absent, say so. Cite timestamps when possible. Never invent facts.",
                              user: "Summary:\n\(meeting.summary)\nTranscript:\n\(Self.render(meeting.segments))\nRecent Q&A:\n\(history)\nQuestion: \(question)")
    }

    func resplitSpeakers(_ segments: [TranscriptSegment]) async throws -> [UUID: String] {
        guard !segments.isEmpty else { return [:] }
        let input = segments.map { ["id": $0.id.uuidString, "startMs": String($0.startMs), "text": $0.text] }
        let data = try JSONSerialization.data(withJSONObject: input)
        let answer = try await chat(task: "speaker", system: "Assign meeting transcript segments to plausible speakers using only linguistic clues such as names, questions, answers and turn-taking. Do not alter the words. If uncertain, retain the original assignment. Return only JSON: {\"assignments\":[{\"id\":\"UUID\",\"speaker\":\"Speaker 1\"}]}",
                                    user: "Segments:\n\(String(decoding: data, as: UTF8.self))")
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start <= end,
              let root = try JSONSerialization.jsonObject(with: Data(answer[start...end].utf8)) as? [String: Any],
              let items = root["assignments"] as? [[String: Any]] else {
            throw AppError.message("Speaker assignment was not valid JSON")
        }
        var result: [UUID: String] = [:]
        for item in items {
            if let rawID = item["id"] as? String, let id = UUID(uuidString: rawID),
               let speaker = item["speaker"] as? String, !speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result[id] = String(speaker.prefix(80))
            }
        }
        return result
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
