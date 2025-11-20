//
//  OpenAIProvider.swift
//  DrsMainApp
//
//  Created by yunastic on 11/17/25.
//
import Foundation
import OSLog

/// Protocol that any episode-level AI provider (OpenAI, UpToDate, local model, etc.)
/// can conform to. This keeps AppState decoupled from provider-specific details.
protocol EpisodeAIProvider {
    /// Run an AI evaluation for the given episode context and fully rendered prompt text.
    /// The caller (AppState) is responsible for building the prompt from templates
    /// stored in the clinician profile.
    func evaluateEpisode(
        context: AppState.EpisodeAIContext,
        prompt: String
    ) async throws -> AppState.EpisodeAIResult
}

/// Concrete implementation that calls OpenAI's chat completions endpoint.
/// This type is intentionally tiny and stateless; all configuration is injected.
final class OpenAIProvider: EpisodeAIProvider {

    private let apiKey: String
    private let model: String
    private let apiBaseURL: URL
    private let log = Logger(subsystem: "DrsMainApp", category: "OpenAIProvider")

    /// - Parameters:
    ///   - apiKey: Secret API key for the OpenAI account (from the clinician profile).
    ///   - model: Chat model identifier (e.g. "gpt-4o", "gpt-4o-mini").
    ///   - apiBaseURL: Base URL for the OpenAI-compatible API, defaulting to
    ///     "https://api.openai.com/v1".
    init(
        apiKey: String,
        model: String,
        apiBaseURL: URL = URL(string: "https://api.openai.com/v1")!
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
        let url = apiBaseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Some newer GPT‑5 family models only support the default temperature (1.0).
        // To keep compatibility, we send 1.0 for any model whose name starts with "gpt-5"
        // and keep a lower temperature for others.
        let temperature: Double = {
            if model.lowercased().hasPrefix("gpt-5") {
                return 1.0
            } else {
                return 0.2
            }
        }()

        let body = OpenAIChatRequest(
            model: model,
            messages: [
                .init(role: "user", content: prompt)
            ],
            temperature: temperature
        )

        request.httpBody = try JSONEncoder().encode(body)

        log.info("OpenAIProvider: calling \(url.absoluteString, privacy: .public) with model \(self.model, privacy: .public)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw OpenAIProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            log.error("OpenAIProvider: status \(http.statusCode) body=\(snippet, privacy: .public)")
            throw OpenAIProviderError.httpStatus(code: http.statusCode, body: snippet)
        }

        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !content.isEmpty else {
            throw OpenAIProviderError.emptyContent
        }

        // Try to heuristically extract an ICD-10-like code from the free-text
        // response. This is intentionally simple and conservative; the clinician
        // can always override the suggestion in the UI.
        let icd10 = extractICD10Code(from: content)

        return AppState.EpisodeAIResult(
            providerModel: model,
            summary: content,
            icd10Suggestion: icd10
        )
    }

    /// Attempt to extract the first ICD-10-like code from an AI response.
    /// Pattern: a letter A–T or V–Z, followed by two alphanumeric characters,
    /// optionally followed by a dot and 1–4 more alphanumerics, e.g. "A09",
    /// "J10.1", "K52.9".
    private func extractICD10Code(from text: String) -> String? {
        // Use an NSRegularExpression for broad Swift compatibility.
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

// MARK: - OpenAI wire formats

private struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double
}

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let role: String
            let content: String
        }
        let index: Int?
        let message: Message
        let finish_reason: String?
    }

    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
}

enum OpenAIProviderError: Error {
    case invalidResponse
    case httpStatus(code: Int, body: String)
    case emptyContent
}
