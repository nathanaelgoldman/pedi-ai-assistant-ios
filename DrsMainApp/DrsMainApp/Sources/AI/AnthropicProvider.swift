//
//  AnthropicProvider.swift
//  DrsMainApp
//
//  Episode-level AI provider for Anthropic (Claude 3, etc).
//

import Foundation
import OSLog

/// Concrete implementation that calls Anthropic's Messages API.
/// This type is intentionally tiny and stateless; all configuration is injected.
final class AnthropicProvider: EpisodeAIProvider {

    private let apiKey: String
    private let model: String
    private let apiBaseURL: URL
    private let log = AppLog.feature("ai.anthropic")

    /// - Parameters:
    ///   - apiKey: Secret API key for the Anthropic account (from the clinician profile).
    ///   - model: Model identifier (e.g. "claude-3-5-sonnet-20241022").
    ///   - apiBaseURL: Base URL for the Anthropic API, defaulting to
    ///     "https://api.anthropic.com".
    init(
        apiKey: String,
        model: String,
        apiBaseURL: URL = URL(string: "https://api.anthropic.com")!
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
        // For now we ignore `context` here, because `prompt` is already the fully
        // rendered text built in AppState. Keeping the parameter lets us extend
        // this later if needed (e.g. for logging or routing).
        let url = apiBaseURL.appendingPathComponent("v1/messages")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        // Pin a stable API version; can be updated later.
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body = AnthropicMessagesRequest(
            model: model,
            max_tokens: 1024,
            messages: [
                .init(
                    role: "user",
                    content: [
                        .init(type: "text", text: prompt)
                    ]
                )
            ]
        )

        request.httpBody = try JSONEncoder().encode(body)

        log.info("AnthropicProvider: calling endpoint=/v1/messages model=\(self.model, privacy: .public)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            let snippetForLog = String(snippet.prefix(512))
            log.error("AnthropicProvider: status \(http.statusCode) body=\(snippetForLog, privacy: .private)")
            throw AnthropicProviderError.httpStatus(code: http.statusCode, body: snippet)
        }

        let decoded = try JSONDecoder().decode(AnthropicMessagesResponse.self, from: data)

        // Find the first text block in the content array
        let contentText: String? = decoded.content
            .compactMap { block -> String? in
                guard block.type == "text" else { return nil }
                return block.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .first(where: { !$0.isEmpty })

        guard let content = contentText, !content.isEmpty else {
            throw AnthropicProviderError.emptyContent
        }

        let icd10 = extractICD10Code(from: content)

        return AppState.EpisodeAIResult(
            providerModel: model,
            summary: content,
            icd10Suggestion: icd10
        )
    }

    /// Attempt to extract the first ICD-10-like code from an AI response.
    /// Pattern: a letter A–T or V–Z, followed by two alphanumeric characters,
    /// optionally followed by a dot and 1–4 more alphanumerics.
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

// MARK: - Anthropic wire formats

private struct AnthropicMessagesRequest: Encodable {
    struct Message: Encodable {
        struct ContentBlock: Encodable {
            let type: String   // "text"
            let text: String
        }

        let role: String     // "user"
        let content: [ContentBlock]
    }

    let model: String
    let max_tokens: Int
    let messages: [Message]
}

private struct AnthropicMessagesResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    let id: String
    let model: String
    let content: [ContentBlock]
}

enum AnthropicProviderError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(code: Int, body: String)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return L("anthropic.error.invalid_response")
        case .emptyContent:
            return L("anthropic.error.empty_content")
        case .httpStatus(let code, let body):
            return L("anthropic.error.http_status", code, body)
        }
    }
}
