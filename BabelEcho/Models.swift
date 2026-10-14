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

    var transcript: String { segments.map(\.text).joined(separator: "\n") }
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
