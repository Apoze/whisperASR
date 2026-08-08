import Foundation
import Security

struct TranslationCredentialStoreError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String?
            ?? "Could not access the translation API credential."
    }
}

enum TranslationCredentialStore {
    private static let service = "com.apoze.WhisperASR.translation"
    private static let account = "api-key"

    static func apiKey() throws -> String {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        if status == errSecItemNotFound {
            let defaults = UserDefaults.standard
            let legacy = defaults.string(forKey: "translationAPIKey") ?? ""
            guard !legacy.isEmpty else { return "" }
            try setAPIKey(legacy)
            return legacy
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw TranslationCredentialStoreError(status: status)
        }
        return value
    }

    static func setAPIKey(_ value: String) throws {
        let query = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary
        guard !value.isEmpty else {
            let status = SecItemDelete(query)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TranslationCredentialStoreError(status: status)
            }
            UserDefaults.standard.removeObject(forKey: "translationAPIKey")
            return
        }

        let data = Data(value.utf8)
        var status = SecItemUpdate(query, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
                kSecValueData as String: data,
            ] as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TranslationCredentialStoreError(status: status) }
        UserDefaults.standard.removeObject(forKey: "translationAPIKey")
    }
}

struct TargetLanguage: Identifiable, Hashable {
    let id: String        // locale identifier (e.g. "en", "zh-Hans")
    let name: String      // English name (used in API prompts)
    let nativeName: String // native name (displayed in UI)

    static let available: [TargetLanguage] = [
        .init(id: "en", name: "English", nativeName: "English"),
        .init(id: "zh-Hans", name: "Chinese (Simplified)", nativeName: "简体中文"),
        .init(id: "zh-Hant", name: "Chinese (Traditional)", nativeName: "繁體中文"),
        .init(id: "ja", name: "Japanese", nativeName: "日本語"),
        .init(id: "ko", name: "Korean", nativeName: "한국어"),
        .init(id: "es", name: "Spanish", nativeName: "Español"),
        .init(id: "fr", name: "French", nativeName: "Français"),
        .init(id: "de", name: "German", nativeName: "Deutsch"),
        .init(id: "pt", name: "Portuguese", nativeName: "Português"),
        .init(id: "ru", name: "Russian", nativeName: "Русский"),
        .init(id: "ar", name: "Arabic", nativeName: "العربية"),
        .init(id: "hi", name: "Hindi", nativeName: "हिन्दी"),
        .init(id: "th", name: "Thai", nativeName: "ภาษาไทย"),
        .init(id: "vi", name: "Vietnamese", nativeName: "Tiếng Việt"),
        .init(id: "it", name: "Italian", nativeName: "Italiano"),
        .init(id: "nl", name: "Dutch", nativeName: "Nederlands"),
        .init(id: "pl", name: "Polish", nativeName: "Polski"),
        .init(id: "uk", name: "Ukrainian", nativeName: "Українська"),
        .init(id: "tr", name: "Turkish", nativeName: "Türkçe"),
        .init(id: "id", name: "Indonesian", nativeName: "Bahasa Indonesia"),
    ]
}

enum TranslationError: LocalizedError {
    case invalidEndpoint
    case apiFailed(String)
    case authFailed(String)
    case rateLimited(String)
    case serverError(Int, String)
    case transport(String)
    case parseError
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "Invalid API endpoint URL"
        case .apiFailed(let msg): return "Translation API error: \(msg)"
        case .authFailed(let msg): return "API key invalid or unauthorized: \(msg)"
        case .rateLimited(let msg): return "Translation rate-limited: \(msg)"
        case .serverError(let code, let msg): return "Translation service error (HTTP \(code)): \(msg)"
        case .transport(let msg): return "Translation network error: \(msg)"
        case .parseError: return "Failed to parse translation response"
        case .unavailable: return "Translation requires OpenAI API configuration"
        }
    }

    /// Whether the error is worth retrying (transient). Auth/client errors are not.
    var isRetriable: Bool {
        switch self {
        case .serverError, .transport: return true
        case .invalidEndpoint, .apiFailed, .authFailed, .rateLimited, .parseError, .unavailable: return false
        }
    }
}

enum TranslationService {
    private struct Configuration {
        let url: URL
        let apiKey: String
        let model: String
    }

    private static func configuration() throws -> Configuration {
        let endpoint = (UserDefaults.standard.string(forKey: "translationEndpoint") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var baseURL = endpoint.isEmpty ? "https://api.openai.com/v1" : endpoint
        if !baseURL.hasSuffix("/chat/completions") {
            if !baseURL.hasSuffix("/") { baseURL += "/" }
            baseURL += "chat/completions"
        }
        guard let url = URL(string: baseURL) else { throw TranslationError.invalidEndpoint }
        let configuredModel = (UserDefaults.standard.string(forKey: "translationModel") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            url: url,
            apiKey: try TranslationCredentialStore.apiKey(),
            model: configuredModel.isEmpty ? "gpt-4o-mini" : configuredModel
        )
    }

    static func translateHighQuality(
        _ translationRequest: HighQualityTranslationBatch
    ) async throws -> HighQualityTranslationExchange {
        let configuration = try configuration()
        guard !configuration.apiKey.isEmpty else { throw TranslationError.unavailable }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let contextualCues = String(decoding: try encoder.encode(translationRequest), as: UTF8.self)
        var request = URLRequest(url: configuration.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.model,
            "messages": [
                [
                    "role": "system",
                    "content": "Translate every requested Japanese cue into contextual English. Use surrounding turns, source metadata, and speaker labels when present. Return JSON only as {\"translations\":[{\"id\":\"cue-0001\",\"text\":\"...\"}]}. Return every requested id exactly once and no other ids.",
                ],
                ["role": "user", "content": contextualCues],
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.2,
        ])

        do {
            let result = try await performRequestWithEvidence(request)
            guard let json = try JSONSerialization.jsonObject(with: result.data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw HighQualityTranslationServiceError(
                    model: configuration.model,
                    attempts: result.attempts,
                    response: sanitizedEvidenceText(
                        String(data: result.data, encoding: .utf8),
                        credential: configuration.apiKey
                    ),
                    message: TranslationError.parseError.localizedDescription
                )
            }
            return .init(
                model: configuration.model,
                response: sanitizedEvidenceText(
                    content,
                    credential: configuration.apiKey
                ) ?? "",
                attempts: result.attempts
            )
        } catch let error as RetryFailure {
            throw HighQualityTranslationServiceError(
                model: configuration.model,
                attempts: error.attempts,
                response: nil,
                message: sanitizedEvidenceText(
                    error.underlying.localizedDescription,
                    credential: configuration.apiKey
                ) ?? TranslationError.parseError.localizedDescription
            )
        }
    }

    private static func sanitizedEvidenceText(
        _ text: String?,
        credential: String
    ) -> String? {
        guard !credential.isEmpty else { return text }
        return text?.replacingOccurrences(of: credential, with: "[REDACTED]")
    }

    static func translateSegmentsWithOpenAI(
        segmentTexts: [String],
        targetLanguage: String,
        previousTranslations: [(original: String, translated: String)] = []
    ) async throws -> [String] {
        guard !segmentTexts.isEmpty else { return [] }

        let configuration = try configuration()

        let languageName = TargetLanguage.available.first { $0.id == targetLanguage }?.name ?? targetLanguage

        let numberedInput = segmentTexts.enumerated()
            .map { "\($0.offset + 1). \($0.element.trimmingCharacters(in: .whitespaces))" }
            .joined(separator: "\n")

        // Build context section from previous translations
        var contextSection = ""
        if !previousTranslations.isEmpty {
            let pairs = previousTranslations.suffix(2)
                .map { "\"\($0.original)\" → \"\($0.translated)\"" }
                .joined(separator: "\n")
            contextSection = "\n\nPreviously translated segments from this conversation (use as reference for consistent terminology and style):\n\(pairs)"
        }

        var request = URLRequest(url: configuration.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": "You are a translator for a live transcription. Translate each numbered line to \(languageName). If a line is already in \(languageName), output it unchanged. Output ONLY the translations in the same numbered format (e.g. \"1. ...\"). Keep exactly \(segmentTexts.count) lines.\(contextSection)"],
                ["role": "user", "content": numberedInput]
            ],
            "temperature": 0.3
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await performRequestWithRetry(request)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationError.parseError
        }

        // Parse numbered lines, stripping the "1. " prefix
        let lines = content.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { line -> String in
                if let range = line.range(of: #"^\d+\.\s*"#, options: .regularExpression) {
                    return String(line[range.upperBound...])
                }
                return line
            }

        // Pad or trim to match input count
        if lines.count >= segmentTexts.count {
            return Array(lines.prefix(segmentTexts.count))
        } else {
            return lines + Array(repeating: "", count: segmentTexts.count - lines.count)
        }
    }

    /// Send the request with up to 2 retries (3 attempts total) for transient failures
    /// (URLSession transport errors and 5xx). Auth/client errors are never retried.
    private static func performRequestWithRetry(_ request: URLRequest) async throws -> Data {
        do {
            return try await performRequestWithEvidence(request).data
        } catch let error as RetryFailure {
            throw error.underlying
        }
    }

    private struct RetryFailure: Error {
        let underlying: Error
        let attempts: [HighQualityTranslationAttempt]
    }

    private static func performRequestWithEvidence(
        _ request: URLRequest
    ) async throws -> (data: Data, attempts: [HighQualityTranslationAttempt]) {
        let backoffs: [Duration] = [.milliseconds(500), .milliseconds(1500)]
        var attempt = 0
        var attempts: [HighQualityTranslationAttempt] = []
        while true {
            try Task.checkCancellation()
            let startedAt = Date()
            do {
                let data = try await performRequest(request)
                attempts.append(.init(
                    number: attempt + 1,
                    duration: Date().timeIntervalSince(startedAt),
                    outcome: "success"
                ))
                return (data, attempts)
            } catch let err as TranslationError where err.isRetriable && attempt < backoffs.count {
                attempts.append(.init(
                    number: attempt + 1,
                    duration: Date().timeIntervalSince(startedAt),
                    outcome: attemptOutcome(err)
                ))
                do {
                    try await Task.sleep(for: backoffs[attempt])
                } catch {
                    throw RetryFailure(underlying: error, attempts: attempts)
                }
                attempt += 1
                continue
            } catch {
                attempts.append(.init(
                    number: attempt + 1,
                    duration: Date().timeIntervalSince(startedAt),
                    outcome: (error as? TranslationError).map(attemptOutcome) ?? "error"
                ))
                throw RetryFailure(underlying: error, attempts: attempts)
            }
        }
    }

    private static func attemptOutcome(_ error: TranslationError) -> String {
        switch error {
        case .invalidEndpoint: "invalid-endpoint"
        case .apiFailed: "api-error"
        case .authFailed: "auth-error"
        case .rateLimited: "rate-limited"
        case .serverError(let status, _): "server-error-\(status)"
        case .transport: "transport-error"
        case .parseError: "parse-error"
        case .unavailable: "unavailable"
        }
    }

    private static func performRequest(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranslationError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.transport("Invalid response")
        }
        if (200...299).contains(httpResponse.statusCode) {
            return data
        }

        let message = parseErrorMessage(data) ?? "HTTP \(httpResponse.statusCode)"
        switch httpResponse.statusCode {
        case 401, 403:
            throw TranslationError.authFailed(message)
        case 429:
            throw TranslationError.rateLimited(message)
        case 500...599:
            throw TranslationError.serverError(httpResponse.statusCode, message)
        default:
            throw TranslationError.apiFailed(message)
        }
    }

    /// Extract `error.message` from an OpenAI-style error body.
    private static func parseErrorMessage(_ data: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String,
            !message.isEmpty
        else { return nil }
        return message
    }
}
