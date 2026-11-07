import Foundation
import Security

/// Shared, independently testable lifecycle for asynchronous system capture callbacks.
struct CaptureLifecycle {
    enum Phase { case picking, starting, recording, stopping, finished }
    private(set) var phase: Phase = .picking
    mutating func selected() -> Bool {
        guard phase == .picking else { return false }
        phase = .starting
        return true
    }
    mutating func started() -> Bool {
        guard phase == .starting else { return false }
        phase = .recording
        return true
    }
    mutating func requestStop() -> Bool {
        guard phase == .starting || phase == .recording else { return false }
        phase = .stopping
        return true
    }
    mutating func finish() -> Bool {
        guard phase != .finished else { return false }
        phase = .finished
        return true
    }
}

struct TranscriptSegment: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var startMs: Int
    var endMs: Int
    var text: String
    var translation: String = ""
    var speaker: String = ""
    var provider: String? = nil
}

struct MinutesDocument: Codable {
    struct Decision: Codable { var decision: String; var context: String? }
    struct ActionItem: Codable { var task: String; var owner: String?; var due: String? }
    struct Risk: Codable { var risk: String; var impact: String? }
    struct Chapter: Codable { var title: String; var start: String; var summary: String? }

    var title: String?
    var abstract: String?
    var participants: [String]?
    var decisions: [Decision]?
    var actionItems: [ActionItem]?
    var risks: [Risk]?
    var openQuestions: [String]?
    var keywords: [String]?
    var chapters: [Chapter]?

    var markdown: String {
        var sections: [String] = []
        if let title, !title.isEmpty { sections.append("# \(title)") }
        if let abstract, !abstract.isEmpty { sections.append("## Overview\n\(abstract)") }
        if let participants, !participants.isEmpty { sections.append("## Participants\n" + participants.map { "- \($0)" }.joined(separator: "\n")) }
        if let decisions, !decisions.isEmpty { sections.append("## Decisions\n" + decisions.map { "- \($0.decision)\($0.context.map { " — \($0)" } ?? "")" }.joined(separator: "\n")) }
        if let actionItems, !actionItems.isEmpty { sections.append("## Action items\n" + actionItems.map { "- \($0.task) (\($0.owner ?? "TBD"), \($0.due ?? "TBD"))" }.joined(separator: "\n")) }
        if let risks, !risks.isEmpty { sections.append("## Risks\n" + risks.map { "- \($0.risk)\($0.impact.map { " — \($0)" } ?? "")" }.joined(separator: "\n")) }
        if let openQuestions, !openQuestions.isEmpty { sections.append("## Open questions\n" + openQuestions.map { "- \($0)" }.joined(separator: "\n")) }
        if let keywords, !keywords.isEmpty { sections.append("## Keywords\n" + keywords.joined(separator: ", ")) }
        if let chapters, !chapters.isEmpty { sections.append("## Chapters\n" + chapters.map { "- [\($0.start)] \($0.title)\($0.summary.map { " — \($0)" } ?? "")" }.joined(separator: "\n")) }
        return sections.joined(separator: "\n\n")
    }
}

struct QuestionAnswer: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var question: String
    var answer: String
    var createdAt: Date = .now
}

struct TextUsage: Codable, Equatable {
    var calls = 0
    var promptTokens = 0
    var completionTokens = 0
    var unreportedCalls = 0
    // A subset of completion tokens, never add this again to the total.
    var reasoningTokens: Int? = nil
}

struct Meeting: Identifiable, Codable {
    var schemaVersion: Int = 1
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = .now
    var durationMs: Int = 0
    var state: String = "recording"
    var audioFile: String = "recording.wav"
    var language: String = "auto"
    var translateTo: String = ""
    var segments: [TranscriptSegment] = []
    var summary: String = ""
    var summaryUpTo: Int = 0
    var minutes: String = ""
    var minutesDocument: MinutesDocument? = nil
    var source: String? = nil
    var questions: [QuestionAnswer] = []
    var asrCalls: Int = 0
    var llmCalls: Int = 0
    var asrProcessedSeconds: Double? = nil
    var asrEstimatedCostByCurrency: [String: Double]? = nil
    var textUsageByTask: [String: TextUsage]? = nil
    /// Desktop scene ("meeting"/"class") and notes detail ("standard"/"detailed"); nil in old meetings.
    var mode: String? = nil
    var notesDetail: String? = nil

    var noteMode: String { NotesPrompts.normalizeMode(mode) }
    var noteDetail: String { NotesPrompts.normalizeDetail(notesDetail) }

    var transcript: String { segments.map(\.text).joined(separator: "\n") }

    /// A meeting can only still be in one of these states on launch if the app
    /// stopped while it was recording or converting.
    var wasInterrupted: Bool { ["recording", "paused", "processing"].contains(state) }

    /// Only a live microphone recording owns its WAV as original audio; an
    /// interrupted import or screen conversion holds at most a partial copy.
    var isInterruptedLiveRecording: Bool {
        (state == "recording" || state == "paused") && (source == nil || source == "live")
    }

    /// Settle an interrupted meeting after its audio was repaired, so it can be
    /// played and re-transcribed. Partial conversions are marked failed rather
    /// than presented as complete; their files are left in place.
    mutating func settleInterruption(recoveredAudioMs: Int) {
        if isInterruptedLiveRecording && recoveredAudioMs > 0 {
            durationMs = max(durationMs, recoveredAudioMs)
            state = "stopped"
        } else {
            state = "failed"
        }
    }
}

struct ASRProvider: Identifiable, Codable, Equatable {
    var id: String
    var kind: String
    var enabled: Bool
    var baseURL: String
    var model: String
    var languages: [String]
    var noAuth: Bool = false
    var pricePerHour: Double? = nil
    var currency: String? = nil

    func supports(_ language: String) -> Bool {
        if language == "auto" { return true }
        if kind == "mimo" { return ["zh", "en"].contains(language) }
        return languages.contains(language) || languages.contains("auto")
    }
}

struct TextProvider: Identifiable, Codable, Equatable {
    var id: String
    var enabled: Bool
    var baseURL: String
    var noAuth: Bool = false
}

struct ModelRole: Codable, Equatable {
    var provider: String
    var model: String
    var thinking: String? = nil

    static func isDeepSeek(_ baseURL: String) -> Bool {
        URL(string: baseURL)?.host?.lowercased() == "api.deepseek.com"
    }

    static func initial(provider: TextProvider, task: String) -> ModelRole {
        if isDeepSeek(provider.baseURL) {
            return ModelRole(provider: provider.id, model: task == "minutes" ? "deepseek-v4-pro" : "deepseek-flash",
                             thinking: ["summary", "translation"].contains(task) ? "disabled" : nil)
        }
        // A model belonging to the previous service must not silently follow it.
        return ModelRole(provider: provider.id, model: "")
    }
}

struct ProviderCatalog: Codable, Equatable {
    var activeASR = "auto"
    var routes: [String: String] = ["zh": "mimo", "en": "mimo", "ja": "groq", "auto": "mimo"]
    var asr: [ASRProvider] = [
        ASRProvider(id: "mimo", kind: "mimo", enabled: false, baseURL: "https://api.xiaomimimo.com/v1", model: "mimo-v2.5-asr", languages: ["zh", "en"], pricePerHour: 0.5, currency: "CNY"),
        ASRProvider(id: "groq", kind: "openai-audio", enabled: false, baseURL: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo", languages: ["ja", "zh", "en", "ko", "fr", "de", "es", "auto"], pricePerHour: 0.04, currency: "USD"),
        ASRProvider(id: "deepgram", kind: "deepgram", enabled: false, baseURL: "https://api.deepgram.com/v1", model: "nova-3", languages: ["ja", "zh", "en", "auto"], pricePerHour: 0.26, currency: "USD"),
        ASRProvider(id: "local", kind: "openai-audio", enabled: false, baseURL: "http://127.0.0.1:8080/v1", model: "whisper-1", languages: ["auto"], noAuth: true, pricePerHour: 0, currency: "USD")
    ]
    var text: [TextProvider] = [
        TextProvider(id: "deepseek", enabled: false, baseURL: "https://api.deepseek.com/v1"),
        TextProvider(id: "mimo", enabled: false, baseURL: "https://api.xiaomimimo.com/v1"),
        TextProvider(id: "local", enabled: false, baseURL: "http://127.0.0.1:11434/v1", noAuth: true)
    ]
    var roles: [String: ModelRole] = [
        "summary": ModelRole(provider: "deepseek", model: "deepseek-flash", thinking: "disabled"),
        "minutes": ModelRole(provider: "deepseek", model: "deepseek-v4-pro"),
        "translation": ModelRole(provider: "deepseek", model: "deepseek-flash", thinking: "disabled"),
        "ask": ModelRole(provider: "deepseek", model: "deepseek-flash"),
        "speaker": ModelRole(provider: "deepseek", model: "deepseek-flash")
    ]

    func candidates(for language: String) -> [ASRProvider] {
        let preferred = [activeASR == "auto" ? nil : activeASR, routes[language], routes["auto"],
                         language == "ja" ? "groq" : "mimo", "deepgram", "local"].compactMap { $0 }
        let order = preferred + asr.map(\.id)
        var seen = Set<String>()
        return order.compactMap { id in
            guard seen.insert(id).inserted, let provider = asr.first(where: { $0.id == id }),
                  provider.enabled, provider.supports(language) else { return nil }
            return provider
        }
    }

    func validated() throws -> ProviderCatalog {
        let ids = asr.map(\.id) + text.map(\.id)
        for id in ids {
            guard !id.isEmpty, id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                throw AppError.message("Provider IDs may contain only letters, digits, _ and -")
            }
        }
        guard Set(asr.map(\.id)).count == asr.count, Set(text.map(\.id)).count == text.count else {
            throw AppError.message("Provider IDs must be unique")
        }
        for provider in asr {
            if let price = provider.pricePerHour, !price.isFinite || price < 0 {
                throw AppError.message("ASR price must be zero or greater")
            }
            if let currency = provider.currency,
               currency.range(of: "^[A-Z]{3}$", options: .regularExpression) == nil {
                throw AppError.message("Currency must be a three-letter code")
            }
        }
        for role in roles.values {
            guard [nil, "default", "enabled", "disabled"].contains(role.thinking) else {
                throw AppError.message("Unknown thinking mode")
            }
        }
        return self
    }
}

struct RealtimeSettings: Codable, Equatable {
    var stepSeconds: Int = 3
    var minNewSeconds: Double = 1.5
    var silenceMilliseconds: Int = 1_200
    var maxUtteranceSeconds: Int = 30
    var overlapMilliseconds: Int = 1_200
    var vadThreshold: Double = 0.003

    func validated() throws -> RealtimeSettings {
        guard (2...10).contains(stepSeconds), (0.5...5).contains(minNewSeconds),
              (400...4_000).contains(silenceMilliseconds), (10...120).contains(maxUtteranceSeconds),
              (0...3_000).contains(overlapMilliseconds), (0.0001...0.1).contains(vadThreshold) else {
            throw AppError.message("Realtime recognition settings are out of range")
        }
        return self
    }
}

struct AppSettings: Codable, Equatable {
    var uiLanguage: String = "zh"
    var asrBaseURL: String = ""
    var asrModel: String = ""
    var asrLanguage: String = "auto"
    var asrNoAuth: Bool = false
    var llmBaseURL: String = ""
    var llmModel: String = ""
    var llmNoAuth: Bool = false
    var summaryModel: String = ""
    var minutesModel: String = ""
    var translationModel: String = ""
    var askModel: String = ""
    var translateTo: String = ""
    var chunkSeconds: Int = 25
    var overlapSeconds: Int = 2
    var autoSummarySeconds: Int = 180
    var autoSummaryMinCharacters: Int? = nil
    /// Desktop summary.maxChars; nil means 900.
    var summaryMaxCharacters: Int? = nil
    /// Scene and notes detail for new recordings and imports; nil means meeting / detailed.
    var noteMode: String? = nil
    var notesDetail: String? = nil
    var allowInsecureHTTP: Bool = false
    var liveTranscription: Bool = false
    var providers: ProviderCatalog? = nil
    var realtime: RealtimeSettings? = nil

    func validated() throws -> AppSettings {
        guard ["zh", "ja", "en"].contains(uiLanguage) else { throw AppError.message("Unsupported interface language") }
        guard (10...120).contains(chunkSeconds), (0...10).contains(overlapSeconds), overlapSeconds < chunkSeconds else {
            throw AppError.message("Chunk duration or overlap is out of range")
        }
        guard autoSummarySeconds == 0 || (60...1800).contains(autoSummarySeconds) else {
            throw AppError.message("Automatic summary interval is out of range")
        }
        if let minimum = autoSummaryMinCharacters, !(0...2_000).contains(minimum) {
            throw AppError.message("Automatic summary minimum is out of range")
        }
        _ = try providers?.validated()
        _ = try realtime?.validated()
        return self
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

enum L10n {
    static func text(_ lang: String, _ zh: String, _ ja: String, _ en: String) -> String {
        switch lang { case "ja": return ja; case "en": return en; default: return zh }
    }
}

enum SecretStore {
    private static let service = "app.babelecho.ios"

    static func read(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func write(_ value: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if value.isEmpty {
            let result = SecItemDelete(query as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else {
                throw AppError.message("Keychain error \(result)")
            }
            return
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw AppError.message("Keychain error \(update)") }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(add as CFDictionary, nil)
        guard result == errSecSuccess else { throw AppError.message("Keychain error \(result)") }
    }
}

// MARK: - Desktop parity (ported from apps/desktop/lib/prompts.mjs, sentences.mjs, meeting.mjs)

/// Every text-model prompt, kept in step with the desktop `lib/prompts.mjs`. Mobile differs only
/// in asking for no Mermaid diagrams, which it cannot render.
enum NotesPrompts {
    static let meeting = "meeting", classroom = "class", standard = "standard", detailed = "detailed"

    static func normalizeMode(_ mode: String?) -> String { mode == classroom ? classroom : meeting }
    static func normalizeDetail(_ detail: String?) -> String { detail == standard ? standard : detailed }

    private static let languages = ["zh": "简体中文", "ja": "日本語", "en": "English", "ko": "한국어",
                                    "fr": "Français", "de": "Deutsch", "es": "Español", "auto": "与原文一致"]
    static func languageName(_ code: String) -> String { languages[code] ?? code }

    /// Desktop `ts()`: h:mm:ss past an hour, otherwise mm:ss.
    static func timestamp(_ ms: Int) -> String {
        let total = (max(0, ms) + 500) / 1000
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func renderTranscript(_ segments: [TranscriptSegment]) -> String {
        segments.map { "[\(timestamp($0.startMs))] \($0.speaker.isEmpty ? "说话人" : $0.speaker)：\($0.text)" }.joined(separator: "\n")
    }

    static func summary(previous: String?, newSegments: [TranscriptSegment], maxChars: Int, title: String, mode: String) -> (system: String, user: String) {
        let isClass = normalizeMode(mode) == classroom
        let system = [
            isClass ? "你是一名严谨的学习笔记助手，正在为一堂课生成「课堂摘要」。重点保留知识框架、概念定义、公式条件、推导步骤、例题方法、老师强调的重点、易错点和明确布置的作业；不要套用商务会议的决议、负责人和风险模板。"
                : "你是一名资深会议记录员，正在为一场进行中的会议生成「实时摘要」。重点保留议题、论据、讨论分歧、决策依据、行动与未决问题。",
            "要求：",
            "1. 只写已经明确出现的信息，绝对不要推测或补充不存在的内容。",
            "2. 用 Markdown 二级标题和短要点；适合比较的事实可整理成表格，明确待办可用任务列表。",
            "3. 保留具体的数字、金额、日期、人名、产品名、专有名词（原文照抄，不要改写）。",
            "4. 若出现分歧、未定事项、明确结论，单独标注。",
            "5. 输出的是「更新后的完整摘要」，覆盖旧摘要，不要写成增量变更说明。",
            "6. 篇幅控制在 \(maxChars) 字以内，宁可精炼也不要注水。",
            "7. 直接输出摘要正文，不要任何寒暄或解释。",
            "8. 不要输出 Mermaid 或其他图表代码。",
        ].joined(separator: "\n")
        var parts: [String] = []
        if !title.isEmpty { parts.append((isClass ? "课程主题：" : "会议主题：") + title) }
        parts.append("【已有摘要】")
        parts.append((previous?.isEmpty == false ? previous! : "（暂无，这是第一版摘要）"))
        parts.append("")
        parts.append("【新增转写内容】")
        let body = renderTranscript(newSegments)
        parts.append(body.isEmpty ? "（无）" : body)
        parts.append("")
        parts.append("请输出覆盖了上述全部内容的、更新后的" + (isClass ? "课堂摘要。" : "会议摘要。"))
        return (system, parts.joined(separator: "\n"))
    }

    static func minutes(transcript: String, title: String, summary: String, targetLanguage: String, mode: String, notesDetail: String) -> (system: String, user: String) {
        let isClass = normalizeMode(mode) == classroom
        let isDetailed = normalizeDetail(notesDetail) == detailed
        let system = [
            isClass ? "你是一名严谨的课堂笔记整理者。请把完整课堂转写整理成可用于复习的课程笔记，而不是商务会议纪要。"
                : "你是一名专业的会议记录撰写者。请把完整会议转写整理成信息充分、能回溯讨论过程的结构化纪要。",
            "你会收到完整转写（含时间戳与说话人），实时摘要仅供参考，不能代替完整转写或作为删减信息的依据。",
            isDetailed ? "详细模式：不要压缩成几个结论。按实际讲授/讨论顺序完整覆盖主要话题，topics 写清背景、解释、依据、过程、例子、限制与结论，points 保留具体步骤和细节；概述在素材充分时写 6–12 句，但不能凑字。"
                : "标准模式：保留每个主要话题及必要解释、依据和关键细节，合并重复表达；不要只列无解释的关键词。",
            isClass ? "课堂重点：知识框架、定义与适用条件、公式符号含义、推导过程、例题步骤与解法、概念间关系、易错点、老师强调内容、作业与明确的考试提示。keyConcepts 解释概念；examples 保留讲过的例子和步骤；reviewQuestions 只根据已讲内容整理复习问答，答案不能引入课外知识。未提及考试重点时禁止自行标成必考。没有真正的决议/负责人时，对应会议字段留空。"
                : "会议重点：各方观点及依据、备选方案与取舍、关键决议的背景、执行细节、风险的影响和待确认问题。不能把未定讨论写成已达成的共识。",
            "硬性要求：",
            "1. 只使用转写中出现的信息，禁止编造人名、数字、日期或结论。",
            "2. 待办事项的负责人和截止时间只能来自原文；原文没提到就写「待定」「未定」。",
            "3. 章节按真实话题转折与时间戳划分，不固定为 2–6 章；长内容允许更多章节。保留信息量但不逐字抄写转写，不添加未出现的内容；无依据的字段使用空数组。",
            "4. 输出语言：\(languageName(targetLanguage.isEmpty ? "zh" : targetLanguage))。",
            "5. 只输出一个 JSON 对象，不要 Markdown 代码块，不要任何解释文字。",
        ].joined(separator: "\n")
        var schema: [String: Any] = [
            "title": isClass ? "课程主题" : "一句话会议主题",
            "abstract": isDetailed ? "素材充分时用6–12句概述，覆盖主要内容；禁止补写事实" : "整体概述，包含主要内容与必要背景",
            "participants": ["出现的说话人/人名"],
            "decisions": [["decision": "已明确达成的结论", "context": "依据"]],
            "actionItems": [["task": "待办事项", "owner": "负责人，未提及则写\"待定\"", "due": "截止时间，未提及则写\"未定\""]],
            "risks": [["risk": "风险、分歧或阻塞", "impact": "影响"]],
            "openQuestions": ["尚未解决的问题"],
            "keywords": ["关键词/专有名词"],
            "topics": [["title": "话题或知识点标题", "detail": "完整解释、依据、过程、条件与结论", "points": ["具体细节、步骤与原文例子"]]],
            "chapters": [["title": "章节标题", "start": "原文起始时间 mm:ss", "summary": "该章的内容、解释与具体细节"]],
        ]
        if isClass {
            schema["keyConcepts"] = [["term": "原文概念或公式", "explanation": "定义、符号含义和适用条件"]]
            schema["examples"] = [["title": "原文例题或案例", "explanation": "原文条件、步骤、方法和结果"]]
            schema["reviewQuestions"] = [["question": "基于所讲内容的复习问题", "answer": "只依据原文的回答"]]
        }
        let schemaText = (try? JSONSerialization.data(withJSONObject: schema, options: [.prettyPrinted, .sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        var user: [String] = []
        if !title.isEmpty { user.append((isClass ? "课程主题（用户填写）：" : "会议主题（用户填写）：") + title) }
        if !summary.isEmpty { user.append("【实时摘要（参考，可修正）】\n" + summary) }
        user += ["【完整转写记录】", transcript, "", "请严格按以下 JSON 结构输出（字段名保持英文，值用目标语言）：", schemaText]
        return (system, user.joined(separator: "\n"))
    }

    static func translate(_ items: [(id: String, text: String)], target: String, context: [String]) -> (system: String, user: String) {
        let system = [
            "你是专业会议口译员。你会收到若干条带编号的会议转写片段。",
            "要求：",
            "1. 翻译成 \(languageName(target))，保持口语自然、术语准确。",
            "2. 保留原有语气与信息量，不要总结、不要增删。",
            "3. 只有在该条内容确实已经是\(languageName(target))时才原样返回；其余一律翻译，短句也必须翻译。",
            "4. 专业名词、产品名、人名按业界习惯处理（可保留原文并加括号）。",
            "5. 只输出 JSON：{\"translations\":[{\"id\":<编号>,\"text\":\"<译文>\"}]}，不要代码块，不要解释。",
            "6. 片段按时间顺序排列，可能承接上文；结合前文理解指代和省略，但每条只翻译它自己的内容。",
        ].joined(separator: "\n")
        let objects = items.map { ["id": $0.id, "text": $0.text] }
        let json = (try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let before = context.isEmpty ? "" : "前文（仅供理解，不要翻译）：\n" + context.joined(separator: "\n") + "\n\n"
        return (system, before + "待翻译片段：\n" + json)
    }

    /// Desktop keeps the last six messages, i.e. three question/answer pairs.
    static func ask(_ question: String, transcript: String, summary: String, history: [(String, String)]) -> (system: String, user: String) {
        let system = [
            "你是这场会议的助理。你只能依据提供的转写记录和摘要回答。",
            "要求：",
            "1. 如果转写里没有相关信息，直接说「会议记录中没有提到」，不要编造。",
            "2. 回答要引用时间戳，例如「（12:34）」。",
            "3. 简洁，用要点列出，不要重复整段原文。",
        ].joined(separator: "\n")
        let conversation = history.suffix(3).map { "用户：\($0.0)\n助手：\($0.1)" }.joined(separator: "\n")
        var user: [String] = []
        if !summary.isEmpty { user.append("【会议摘要】\n" + summary) }
        user += ["【转写记录】", transcript]
        if !conversation.isEmpty { user.append("【此前的问答】\n" + conversation) }
        user += ["【当前问题】", question]
        return (system, user.joined(separator: "\n"))
    }

    static func speakerSplit(_ segments: [TranscriptSegment], known: [String]) -> (system: String, user: String) {
        let system = [
            "你会收到一段会议转写，其中所有内容都被标成了同一个说话人。",
            "请根据称呼、语气、应答、问答关系等语言线索，把片段归到不同的说话人。",
            "不要修改任何文字内容，只做归属。",
            "只输出 JSON：{\"assignments\":[{\"id\":<片段编号>,\"speaker\":\"说话人N\"}]}，不要解释。",
            "若确实无法区分，全部归为「说话人1」。",
        ].joined(separator: "\n")
        let items: [[String: Any]] = segments.map { ["id": $0.id.uuidString, "start": $0.startMs, "text": $0.text] }
        let json = (try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted])).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return (system, "已知说话人：" + known.joined(separator: "、") + "\n\n片段：\n" + json)
    }
}

/// Renders structured notes JSON like the desktop `toMarkdown()`; malformed fields are skipped.
enum MinutesRenderer {
    private static let labels: [String: [String]] = [
        "zh": ["课程笔记", "智能纪要", "内容详解", "核心概念与公式", "例题与案例", "复习问答", "关键决议", "待办事项", "事项", "负责人", "截止", "风险与分歧", "关键词：", "待确认问题", "章节回顾", "参与者"],
        "ja": ["授業ノート", "議事録", "詳細", "重要概念と公式", "例題と事例", "復習問答", "決定事項", "ToDo", "項目", "担当", "期限", "リスクと相違点", "キーワード：", "未解決の問題", "章の振り返り", "参加者"],
        "en": ["Class notes", "Minutes", "Details", "Key concepts and formulas", "Examples", "Review questions", "Decisions", "Action items", "Task", "Owner", "Due", "Risks and disagreements", "Keywords: ", "Open questions", "Chapters", "Participants"],
    ]

    /// The JSON object inside a model reply that may be fenced or chatty.
    static func parse(_ raw: String) -> [String: Any]? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8))) as? [String: Any]
    }

    static func render(_ data: [String: Any], mode: String, language: String = "zh") -> String {
        let l = labels[language] ?? labels["zh"]!
        let isClass = NotesPrompts.normalizeMode(mode) == NotesPrompts.classroom
        var lines: [String] = []
        func strings(_ key: String) -> [String] { (data[key] as? [Any] ?? []).compactMap { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } } }
        func objects(_ key: String) -> [[String: Any]] { (data[key] as? [Any] ?? []).compactMap { $0 as? [String: Any] } }
        func text(_ item: Any, _ key: String) -> String {
            if let object = item as? [String: Any] { return object[key] as? String ?? "" }
            return item as? String ?? ""
        }
        func cell(_ value: String) -> String {
            value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        lines += ["## " + (isClass ? l[0] : l[1]), ""]
        if let abstract = data["abstract"] as? String, !abstract.isEmpty { lines += [abstract, ""] }
        let participants = strings("participants")
        if !participants.isEmpty { lines += ["**\(l[15])**：" + participants.joined(separator: "、"), ""] }
        for topic in objects("topics") {
            let title = text(topic, "title")
            lines += ["### " + (title.isEmpty ? l[2] : title), ""]
            let detail = text(topic, "detail")
            if !detail.isEmpty { lines += [detail, ""] }
            for point in (topic["points"] as? [Any] ?? []).compactMap({ $0 as? String }) where !point.isEmpty { lines.append("- " + point) }
            lines.append("")
        }
        for (key, heading, name, detail) in [("keyConcepts", l[3], "term", "explanation"), ("examples", l[4], "title", "explanation"), ("reviewQuestions", l[5], "question", "answer")] {
            let items = objects(key)
            if items.isEmpty { continue }
            lines += ["### " + heading, ""]
            for item in items { lines += ["#### " + text(item, name), "", text(item, detail), ""] }
        }
        let decisions = data["decisions"] as? [Any] ?? []
        if !decisions.isEmpty {
            lines.append("### " + l[6])
            for item in decisions {
                let context = text(item, "context")
                lines.append("- " + (item is String ? text(item, "") : text(item, "decision")) + (context.isEmpty ? "" : "（\(context)）"))
            }
            lines.append("")
        }
        let actions = objects("actionItems")
        if !actions.isEmpty {
            lines += ["### " + l[7], "| \(l[8]) | \(l[9]) | \(l[10]) |", "| --- | --- | --- |"]
            for item in actions { lines.append("| " + ["task", "owner", "due"].map { cell(text(item, $0)) }.joined(separator: " | ") + " |") }
            lines.append("")
        }
        let risks = data["risks"] as? [Any] ?? []
        if !risks.isEmpty {
            lines.append("### " + l[11])
            for item in risks {
                let impact = text(item, "impact")
                lines.append("- " + (item is String ? text(item, "") : text(item, "risk")) + (impact.isEmpty ? "" : "（\(impact)）"))
            }
            lines.append("")
        }
        let keywords = strings("keywords")
        if !keywords.isEmpty { lines += [l[12] + keywords.joined(separator: "、"), ""] }
        let questions = strings("openQuestions")
        if !questions.isEmpty { lines += ["### " + l[13], ""] + questions.map { "- " + $0 } + [""] }
        let chapters = objects("chapters")
        if !chapters.isEmpty {
            lines += ["### " + l[14], ""]
            for chapter in chapters {
                lines += ["#### " + "\(text(chapter, "start")) \(text(chapter, "title"))".trimmingCharacters(in: .whitespaces), "", text(chapter, "summary"), ""]
            }
        }
        var output = lines.joined(separator: "\n")
        while output.contains("\n\n\n") { output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return output.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

/// Sentence boundaries, ported from the desktop `lib/sentences.mjs`.
enum Sentences {
    // Terminal punctuation plus closing quotes/brackets; a Latin period ends a sentence only
    // before whitespace or the end, keeping 3.5 and v1.2 intact.
    private static let end = try! NSRegularExpression(pattern: "(?:[。！？!?…]+|\\.(?=\\s|$))[\"'”’」』）)\\]]*")
    private static let latinEnd = try! NSRegularExpression(pattern: "[\\p{Latin}\\p{N}.,;:!?'\"”’)\\]]$")
    private static let latinStart = try! NSRegularExpression(pattern: "^[\\p{Latin}\\p{N}(\"“‘\\[]")

    private static func trim(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func split(_ text: String) -> [String] {
        let value = trim(text)
        if value.isEmpty { return [] }
        let ns = value as NSString
        var out: [String] = []
        var from = 0
        for match in end.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            let to = match.range.location + match.range.length
            let sentence = trim(ns.substring(with: NSRange(location: from, length: to - from)))
            if !sentence.isEmpty { out.append(sentence) }
            from = to
        }
        let rest = trim(ns.substring(from: from))
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    static func endsSentence(_ text: String?) -> Bool {
        let value = trim(text ?? "")
        if value.isEmpty { return false }
        let length = (value as NSString).length
        guard let last = end.matches(in: value, range: NSRange(location: 0, length: length)).last else { return false }
        return last.range.location + last.range.length == length
    }

    static func join(_ left: String, _ right: String) -> String {
        var a = left
        while let last = a.last, last.isWhitespace { a.removeLast() }
        let b = String(right.drop(while: { $0.isWhitespace }))
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        let latin = latinEnd.firstMatch(in: a, range: NSRange(location: 0, length: (a as NSString).length)) != nil &&
            latinStart.firstMatch(in: b, range: NSRange(location: 0, length: (b as NSString).length)) != nil
        return a + (latin ? " " : "") + b
    }

    /// Group sentences into pieces of about `target` characters; a sentence is never split.
    static func group(_ sentences: [String], target: Int) -> [String] {
        var groups: [String] = []
        var current = ""
        for sentence in sentences {
            if !current.isEmpty && current.count + sentence.count > target {
                groups.append(current)
                current = sentence
            } else { current = join(current, sentence) }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Remove text recognised twice from audio carried over an overlap (desktop trimRepeatedPrefix).
    static func trimRepeatedPrefix(previous: String?, current: String?) -> String {
        let text = current ?? ""
        guard let previous, !previous.isEmpty, !text.isEmpty else { return trim(text) }
        func units(_ value: String) -> [(char: String, end: String.Index)] {
            var out: [(String, String.Index)] = []
            var index = value.startIndex
            while index < value.endIndex {
                let next = value.index(after: index)
                let character = value[index]
                if character.isLetter || character.isNumber { out.append((String(character).lowercased(), next)) }
                index = next
            }
            return out
        }
        let left = Array(units(previous).suffix(80))
        let right = Array(units(text).prefix(80))
        var count = min(left.count, right.count)
        while count >= 3 {
            if left.suffix(count).map(\.char).joined() == right.prefix(count).map(\.char).joined() {
                var rest = Substring(text[right[count - 1].end...])
                while let first = rest.first, first.isWhitespace || first.isPunctuation || first.isSymbol { rest.removeFirst() }
                return trim(String(rest))
            }
            count -= 1
        }
        return trim(text)
    }
}

/// Builds transcript segments the way the desktop meeting does (`Meeting.addText()`): an
/// unfinished sentence absorbs the next piece from the same speaker, short sentences are grouped.
struct TranscriptAssembler {
    struct Change {
        var updated: [TranscriptSegment] = []
        var added: [TranscriptSegment] = []
        var closedIDs: [UUID] = []

        /// Applies text edits by ID, so translations written meanwhile are kept.
        func apply(to segments: [TranscriptSegment]) -> [TranscriptSegment] {
            let byID = Dictionary(updated.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            return segments.map { segment in
                guard let edit = byID[segment.id] else { return segment }
                var value = segment
                value.text = edit.text
                value.endMs = edit.endMs
                return value
            } + added
        }
    }

    static let continueGapMs = 1_500
    static let segmentTargetChars = 80
    static let maxOpenChars = 240

    private(set) var last: TranscriptSegment?
    private(set) var lastOpen = false

    init(existing: [TranscriptSegment] = []) { last = existing.last }

    var openSegmentID: UUID? { lastOpen ? last?.id : nil }

    mutating func add(_ text: String, startMs: Int, endMs: Int, speaker: String, provider: String? = nil) -> Change {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var change = Change()
        if rest.isEmpty { return change }
        let total = rest.count
        let span = max(0, endMs - startMs)
        func at(_ chars: Int) -> Int { startMs + span * min(chars, total) / total }

        if var previous = last, lastOpen {
            if previous.speaker == speaker && startMs - previous.endMs <= Self.continueGapMs {
                let head = Sentences.split(rest).first ?? rest
                rest = String(rest.dropFirst(head.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                previous.text = Sentences.join(previous.text, head)
                previous.endMs = max(previous.endMs, rest.isEmpty ? endMs : at(total - rest.count))
                change.updated.append(previous)
                last = previous
                if Sentences.endsSentence(head) || previous.text.count >= Self.maxOpenChars {
                    lastOpen = false
                    change.closedIDs.append(previous.id)
                }
                if rest.isEmpty { return change }
            } else {
                lastOpen = false
                change.closedIDs.append(previous.id)
            }
        }

        var sentences = Sentences.split(rest)
        let tail: String? = Sentences.endsSentence(sentences.last) ? nil : sentences.popLast()
        var groups = Sentences.group(sentences, target: Self.segmentTargetChars)
        if let tail { groups.append(tail) }
        var offset = total - rest.count
        for (index, group) in groups.enumerated() {
            let isFinal = index == groups.count - 1
            let from = offset
            offset += group.count
            let segment = TranscriptSegment(startMs: at(from), endMs: isFinal ? endMs : at(offset), text: group,
                                            speaker: speaker, provider: provider)
            let open = isFinal && tail != nil && group.count < Self.maxOpenChars
            if !open { change.closedIDs.append(segment.id) }
            if isFinal { last = segment; lastOpen = open }
            change.added.append(segment)
        }
        return change
    }

    /// Finish the trailing sentence; returns its ID if one was open.
    mutating func closeOpen() -> UUID? {
        guard lastOpen else { return nil }
        lastOpen = false
        return last?.id
    }

    /// Close the open sentence once nothing recorded after `nowMs` can still continue it.
    mutating func closeIfStale(nowMs: Int, graceMs: Int) -> UUID? {
        guard lastOpen, let open = last, nowMs - open.endMs > Self.continueGapMs + graceMs else { return nil }
        return closeOpen()
    }
}

/// Text exports shared by the share sheet and tests. Mirrors the desktop export menu: Markdown
/// with or without the transcript, TXT, VTT (bilingual), SRT.
enum MeetingExport {
    static func fileExtension(_ format: String) -> String {
        switch format { case "bilingual-vtt": return "vtt"; case "md-notes": return "md"; default: return format }
    }

    static func suffix(_ format: String) -> String {
        switch format { case "bilingual-vtt": return "-bilingual"; case "md-notes": return "-notes"; default: return "" }
    }

    static func text(_ meeting: Meeting, format: String) -> String {
        switch format {
        case "vtt", "bilingual-vtt":
            return "WEBVTT\n\n" + meeting.segments.enumerated().map { index, segment in
                let translation = format == "bilingual-vtt" && !segment.translation.isEmpty ? "\n\(cue(segment.translation))" : ""
                return "\(timestamp(segment.startMs)) --> \(timestamp(cueEnd(meeting.segments, index)))\n\(speakerPrefix(segment))\(cue(segment.text))\(translation)\n"
            }.joined(separator: "\n")
        case "srt":
            // SubRip numbers cues and uses a comma before milliseconds.
            return meeting.segments.enumerated().map { index, segment in
                "\(index + 1)\n\(timestamp(segment.startMs, separator: ",")) --> \(timestamp(cueEnd(meeting.segments, index), separator: ","))\n\(speakerPrefix(segment))\(cue(segment.text))\n"
            }.joined(separator: "\n")
        case "txt":
            return meeting.segments.map { "[\(NotesPrompts.timestamp($0.startMs))] \(speakerPrefix($0))\($0.text)" }.joined(separator: "\n")
        default:
            let isClass = meeting.noteMode == NotesPrompts.classroom
            var parts = ["# \(meeting.title)", "", "- " + (isClass ? "使用场景：上课 / Class" : "使用场景：会议 / Meeting"), ""]
            if !meeting.summary.isEmpty { parts += ["## " + (isClass ? "课堂摘要" : "摘要") + " / Summary", "", meeting.summary, ""] }
            if !meeting.minutes.isEmpty {
                // Structured notes already start with their own "## 课程笔记/智能纪要" heading.
                if meeting.minutes.hasPrefix("## ") { parts += [meeting.minutes.trimmingCharacters(in: .whitespacesAndNewlines), ""] }
                else { parts += ["## " + (isClass ? "课程笔记" : "纪要") + " / Minutes", "", meeting.minutes, ""] }
            }
            if !meeting.questions.isEmpty {
                parts += ["## 问答 / Q&A", ""] + meeting.questions.flatMap { ["Q: \($0.question)", "A: \($0.answer)", ""] }
            }
            if format == "md-notes" { return parts.joined(separator: "\n") }
            parts += ["## 转写 / Transcript", ""]
            parts += meeting.segments.map {
                "- [\(NotesPrompts.timestamp($0.startMs))] \(speakerPrefix($0))\($0.text)\($0.translation.isEmpty ? "" : "\n  - \($0.translation)")"
            }
            return parts.joined(separator: "\n")
        }
    }

    /// A cue ends no later than the next one starts, so overlapping recognition windows
    /// (older recordings) never stack two captions on screen.
    static func cueEnd(_ segments: [TranscriptSegment], _ index: Int) -> Int {
        let segment = segments[index]
        var end = segment.endMs
        if index + 1 < segments.count, segments[index + 1].startMs > segment.startMs { end = min(end, segments[index + 1].startMs) }
        return max(end, segment.startMs + 1)
    }

    private static func speakerPrefix(_ segment: TranscriptSegment) -> String { segment.speaker.isEmpty ? "" : "\(segment.speaker): " }

    /// A blank line or "-->" inside a cue would end or corrupt it.
    private static func cue(_ text: String) -> String {
        text.replacingOccurrences(of: "-->", with: "→").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    static func timestamp(_ milliseconds: Int, separator: String = ".") -> String {
        let value = max(0, milliseconds)
        return String(format: "%02d:%02d:%02d", value / 3_600_000, value / 60_000 % 60, value / 1000 % 60) + separator + String(format: "%03d", value % 1000)
    }
}

/// The Markdown subset that summaries and notes use, split into blocks for native display
/// (same rules as Android `MarkdownBlocks.kt`). Unrecognised lines stay paragraphs, so no text
/// is dropped; inline bold/code is left to `AttributedString(markdown:)`.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(text: String, depth: Int, marker: String)
    case table(header: [String], rows: [[String]])
    case quote(String)
    case code(String)
    case paragraph(String)
    case rule

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [MarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) }
            paragraph = []
        }
        func trimmed(_ line: String) -> String { line.trimmingCharacters(in: .whitespaces) }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let text = trimmed(line)
            if text.isEmpty {
                flush()
            } else if text.hasPrefix("```") {
                flush()
                var code: [String] = []
                index += 1
                while index < lines.count, !trimmed(lines[index]).hasPrefix("```") { code.append(lines[index]); index += 1 }
                out.append(.code(code.joined(separator: "\n")))
            } else if let heading = Self.heading(text) {
                flush(); out.append(heading)
            } else if Self.isRule(text) {
                flush(); out.append(.rule)
            } else if text.hasPrefix("|"), index + 1 < lines.count, Self.isTableDivider(lines[index + 1]) {
                flush()
                let header = cells(text)
                var rows: [[String]] = []
                index += 2
                while index < lines.count, trimmed(lines[index]).hasPrefix("|") { rows.append(cells(trimmed(lines[index]))); index += 1 }
                out.append(.table(header: header, rows: rows))
                continue
            } else if text.hasPrefix(">") {
                flush(); out.append(.quote(trimmed(String(text.dropFirst()))))
            } else if let bullet = Self.bullet(line) {
                flush(); out.append(bullet)
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flush()
        return out
    }

    private static func heading(_ text: String) -> MarkdownBlock? {
        let hashes = text.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), text.dropFirst(hashes).first == " " else { return nil }
        var body = String(text.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
        while body.hasSuffix("#") { body.removeLast() }
        return .heading(level: hashes, text: body.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        guard let first = compact.first, "-*_".contains(first), compact.count >= 3 else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func isTableDivider(_ line: String) -> Bool {
        let compact = line.trimmingCharacters(in: .whitespaces)
        return compact.contains("--") && compact.allSatisfy { "|-: ".contains($0) }
    }

    private static func bullet(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        let rest = line.drop(while: { $0 == " " || $0 == "\t" })
        var marker: String
        var body: Substring
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            marker = "•"; body = rest.dropFirst(2)
        } else {
            let digits = rest.prefix(while: { $0.isNumber })
            guard (1...3).contains(digits.count), let punctuation = rest.dropFirst(digits.count).first, ".)".contains(punctuation),
                  rest.dropFirst(digits.count + 1).first == " " else { return nil }
            marker = String(digits) + String(punctuation); body = rest.dropFirst(digits.count + 2)
        }
        var text = String(body).trimmingCharacters(in: .whitespaces)
        for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) { text.removeFirst(box.count) }
        return .bullet(text: text, depth: indent / 2, marker: marker)
    }

    /// Splits a table row on unescaped pipes; `\|` stays a literal pipe.
    static func cells(_ row: String) -> [String] {
        var body = Substring(row.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") && !body.hasSuffix("\\|") { body = body.dropLast() }
        var out: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped { current.append(character == "|" ? "|" : "\\" + String(character)); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { out.append(current.trimmingCharacters(in: .whitespaces)); current = "" } else { current.append(character) }
        }
        if escaped { current.append("\\") }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out
    }
}
