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

/// Concrete implementation that calls OpenAI's Responses API endpoint.
final class OpenAIProvider: EpisodeAIProvider {

    private let apiKey: String
    private let model: String
    private let apiBaseURL: URL
    private let log = AppLog.feature("ai.openai")

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
    
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 120      // seconds (request/response)
        cfg.timeoutIntervalForResource = 240     // seconds (overall)
        return URLSession(configuration: cfg)
    }()

    /// Retry transient network errors (timeouts, network connection lost, offline) with exponential backoff.
    private func dataWithRetry(for request: URLRequest,
                              maxAttempts: Int = 3,
                              initialBackoffSeconds: Double = 1.0) async throws -> (Data, URLResponse) {
        var attempt = 0
        var backoff = initialBackoffSeconds

        while true {
            attempt += 1
            do {
                return try await session.data(for: request)
            } catch {
                // Only retry a small set of transient URL errors.
                let nsErr = error as NSError
                let isURLError = (nsErr.domain == NSURLErrorDomain)
                let code = nsErr.code
                let transientCodes: Set<Int> = [
                    NSURLErrorTimedOut,                // -1001
                    NSURLErrorNetworkConnectionLost,    // -1005
                    NSURLErrorNotConnectedToInternet,   // -1009
                    NSURLErrorCannotConnectToHost,      // -1004
                    NSURLErrorDNSLookupFailed           // -1006
                ]

                if isURLError, transientCodes.contains(code), attempt < maxAttempts {
                    log.warning("OpenAIProvider: transient network error (code=\(code, privacy: .public)) attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public); retrying in \(backoff, privacy: .public)s")
                    let nanos = UInt64(backoff * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanos)
                    backoff = min(backoff * 2.0, 8.0)
                    continue
                }

                // Not transient or out of attempts.
                throw error
            }
        }
    }

    // MARK: - Public API

    func evaluateEpisode(
        context: AppState.EpisodeAIContext,
        prompt: String
    ) async throws -> AppState.EpisodeAIResult {
        // For now we ignore `context` here, because `prompt` is already the fully
        // rendered text built in AppState. Keeping the parameter lets us extend
        // this later if needed (e.g. for logging or routing).
        let url = endpointURL(["responses"])

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

        let body = OpenAIResponsesRequest(
            model: model,
            input: prompt,
            temperature: temperature
        )

        request.httpBody = try JSONEncoder().encode(body)

        log.info("OpenAIProvider: calling \(url.absoluteString, privacy: .public) with model \(self.model, privacy: .public)")

        let (data, response) = try await dataWithRetry(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw OpenAIProviderError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            let truncated = String(snippet.prefix(800))  // keep it sane

            log.error("OpenAIProvider: status \(http.statusCode, privacy: .public) body=\(truncated, privacy: .private)")
            throw OpenAIProviderError.httpStatus(code: http.statusCode, body: snippet)
        }

        let decoded = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
        let content = decoded.outputText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !content.isEmpty else {
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

    /// Build a stable endpoint URL under the OpenAI v1 API root.
    ///
    /// This hardens against misconfiguration where `apiBaseURL` is set to
    /// something like `https://api.openai.com/v1/responses` and we then
    /// accidentally append another path segment on top of it.
    private func endpointURL(_ pathComponents: [String]) -> URL {
        // If the base already contains /v1 somewhere, truncate everything after it.
        // Otherwise, append /v1.
        let base: URL = {
            let comps = apiBaseURL.pathComponents
            if let v1Index = comps.firstIndex(of: "v1") {
                let kept = comps.prefix(v1Index + 1)
                var c = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
                c?.path = kept.joined(separator: "/").replacingOccurrences(of: "//", with: "/")
                return c?.url ?? apiBaseURL
            } else {
                return apiBaseURL.appendingPathComponent("v1")
            }
        }()

        var url = base
        for pc in pathComponents {
            url.appendPathComponent(pc)
        }
        return url
    }
}

// MARK: - OpenAI wire formats (Responses API)

private struct OpenAIResponsesRequest: Encodable {
    let model: String
    let input: String
    let temperature: Double
}

private struct OpenAIResponsesResponse: Decodable {
    struct OutputItem: Decodable {
        let type: String
        let role: String?
        let status: String?
        let content: [ContentPart]?
    }

    struct ContentPart: Decodable {
        let type: String
        let text: String?
    }

    let id: String
    let object: String?
    let created_at: Int?
    let model: String?
    let output: [OutputItem]

    /// Extract assistant output text segments from the Responses `output` items.
    /// We look for items of type `message` with role `assistant`, and within those,
    /// content parts of type `output_text`.
    var outputText: String {
        var chunks: [String] = []
        for item in output {
            guard item.type == "message" else { continue }
            guard (item.role ?? "") == "assistant" else { continue }
            guard let parts = item.content else { continue }
            for part in parts {
                if part.type == "output_text", let t = part.text {
                    chunks.append(t)
                }
            }
        }
        return chunks.joined(separator: "\n")
    }
}

private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

enum OpenAIProviderError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(code: Int, body: String)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return L("openai.error.invalid_response")
        case .emptyContent:
            return L("openai.error.empty_content")
        case .httpStatus(let code, let body):
            // Use a format string so translators can reorder placeholders.
            return String(format: L("openai.error.http_status"), code, body)
        }
    }
}
