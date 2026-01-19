//
//  GeminiProvider.swift
//  DrsMainApp
//
//  Episode-level AI provider for Google Gemini (direct API).
//

import Foundation
// Logging is centralized via AppLog

/// Concrete implementation that calls Gemini's generateContent API.
/// This type is intentionally tiny and stateless; all configuration is injected.
final class GeminiProvider: EpisodeAIProvider {

    private let apiKey: String
    private let model: String
    private let apiBaseURL: URL
    // Feature-specific logger (AppLog convention)
    private let log = AppLog.feature("ai.gemini")

    // MARK: - Localization
    /// Localized string helper (fileprivate to avoid cross-file symbol collisions).
    fileprivate static func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = NSLocalizedString(key, comment: "")
        if args.isEmpty {
            return format
        }
        return String(format: format, locale: Locale.current, arguments: args)
    }

    /// - Parameters:
    ///   - apiKey: Secret API key for the Gemini project (from the clinician profile).
    ///   - model: Model identifier (e.g. "gemini-1.5-pro" or "gemini-1.5-flash").
    ///   - apiBaseURL: Base URL for the Gemini API, defaulting to
    ///     "https://generativelanguage.googleapis.com/v1beta".
    ///
    /// NOTE: For Gemini, the API key is passed as a `?key=` query parameter,
    /// not as a Bearer header.
    init(
        apiKey: String,
        model: String,
        apiBaseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
    ) {
        self.apiKey = apiKey
        self.model = model
        self.apiBaseURL = apiBaseURL
    }

    // MARK: - Public API

    func evaluateEpisode(
        context: AppState.EpisodeAIContext,
        prompt: String
    ) async throws -> AppState.EpisodeAIResult {
        // Encode the model into the URL path safely.
        let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let basePathURL = apiBaseURL.appendingPathComponent("models/\(encodedModel):generateContent")

        guard var components = URLComponents(url: basePathURL, resolvingAgainstBaseURL: false) else {
            throw GeminiProviderError.invalidURL
        }

        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "key", value: apiKey))
        components.queryItems = query

        guard let url = components.url else {
            throw GeminiProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Use a relatively low temperature for clinical-ish outputs.
        let temperature: Double = 0.2

        let body = GeminiGenerateContentRequest(
            contents: [
                .init(
                    parts: [
                        .init(text: prompt)
                    ]
                )
            ],
            generationConfig: .init(
                temperature: temperature
            )
        )

        request.httpBody = try JSONEncoder().encode(body)

        let safeURLForLog = "\(url.scheme ?? "")://\(url.host ?? "")\(url.path)"
        log.info("GeminiProvider: calling \(safeURLForLog, privacy: .public) with model \(self.model, privacy: .public)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw GeminiProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            let snippetForLog = String(snippet.prefix(512))
            log.error("GeminiProvider: status \(http.statusCode) body=\(snippetForLog, privacy: .private)")
            throw GeminiProviderError.httpStatus(code: http.statusCode, body: snippet)
        }

        let decoded = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)

        // Extract first candidate's first text part if available.
        let content: String? = decoded.candidates?
            .compactMap { candidate -> String? in
                guard let parts = candidate.content.parts.first,
                      let text = parts.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else {
                    return nil
                }
                return text
            }
            .first

        guard let summary = content, !summary.isEmpty else {
            throw GeminiProviderError.emptyContent
        }

        let icd10 = extractICD10Code(from: summary)

        return AppState.EpisodeAIResult(
            providerModel: model,
            summary: summary,
            icd10Suggestion: icd10
        )
    }

    /// Attempt to extract the first ICD-10-like code from an AI response.
    private func extractICD10Code(from text: String) -> String? {
        let pattern = #"\b([A-TV-Z][0-9][0-9A-Z](?:\.[0-9A-Z]{1,4})?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2 else {
            return nil
        }

        let codeRange = match.range(at: 1)
        guard codeRange.location != NSNotFound,
              let swiftRange = Range(codeRange, in: text) else {
            return nil
        }

        let candidate = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }
}

// MARK: - Gemini wire formats

private struct GeminiGenerateContentRequest: Encodable {
    struct Content: Encodable {
        struct Part: Encodable {
            let text: String
        }
        let parts: [Part]
    }

    struct GenerationConfig: Encodable {
        let temperature: Double?
    }

    let contents: [Content]
    let generationConfig: GenerationConfig?
}

private struct GeminiGenerateContentResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }
            let parts: [Part]
        }
        let content: Content
    }

    let candidates: [Candidate]?
}

enum GeminiProviderError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(code: Int, body: String)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return GeminiProvider.tr("ai.gemini.error.invalid_url")
        case .invalidResponse:
            return GeminiProvider.tr("ai.gemini.error.invalid_response")
        case .httpStatus(let code, _):
            return GeminiProvider.tr("ai.gemini.error.http_status", code)
        case .emptyContent:
            return GeminiProvider.tr("ai.gemini.error.empty_content")
        }
    }
}
