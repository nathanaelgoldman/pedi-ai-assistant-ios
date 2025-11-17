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

        let body = OpenAIChatRequest(
            model: model,
            messages: [
                .init(role: "user", content: prompt)
            ],
            temperature: 0.2
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

        // For now we do not attempt to parse an ICD-10 code out of the free text.
        // That can be done later either by:
        // - asking OpenAI for structured JSON, or
        // - reusing local heuristics on `content`.
        return AppState.EpisodeAIResult(
            providerModel: model,
            summary: content,
            icd10Suggestion: nil
        )
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
