//
//  AliasGenerator.swift
//  DrsMainApp
//
//  Created by yunastic on 10/31/25.
//

import Foundation

/// Centralized alias generator for patient bundles.
/// Produces a human-facing label like "Gold_Dolphin_🐬"
/// and a machine-safe id like "gold_dolphin".
enum AliasGenerator {

    // MARK: - Vocabularies
    private static let emojis = ["🐬","🦊","🐼","🦁","🦉","🐢","🐨","🦄","🐧","🐳","🐯","🦜","🦋","🐙","🦕","🦓"]

    // Tokens are stable (used for machine-safe ids). Display labels are localized.
    private static let colorTokens  = [
        "gold","silver","emerald","sapphire","ruby","amber","indigo","ivory","obsidian","coral","mint","violet","azure","cocoa","slate"
    ]
    private static let animalTokens = [
        "dolphin","panda","falcon","tiger","owl","turtle","koala","unicorn","penguin","whale","lion","parrot","butterfly","octopus","dragon","zebra"
    ]

    // MARK: - Public API

    /// Legacy name kept for backward compatibility with earlier calls.
    /// Use `generate()` going forward.
    static func makeAlias() -> (label: String, id: String) {
        return generate()
    }

    /// Generate an alias using the system RNG.
    static func generate() -> (label: String, id: String) {
        var rng = SystemRandomNumberGenerator()
        return generate(using: &rng)
    }

    /// Generate an alias with a caller-supplied RNG (useful for testing).
    static func generate<R: RandomNumberGenerator>(using rng: inout R) -> (label: String, id: String) {
        let colorToken  = pick(Self.colorTokens, using: &rng)
        let animalToken = pick(Self.animalTokens, using: &rng)
        let emoji       = pick(Self.emojis, using: &rng)

        let label = "\(displayColor(colorToken))_\(displayAnimal(animalToken))_\(emoji)"
        let rawID = "\(colorToken)_\(animalToken)"
        let id = sanitize(rawID)

        return (label, id)
    }

    /// Generate a unique alias not present in `existingIDs`.
    /// Tries up to `maxTries` times, then appends a numeric suffix if needed.
    static func uniqueAlias(existingIDs: Set<String>, maxTries: Int = 64) -> (label: String, id: String) {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<maxTries {
            let a = generate(using: &rng)
            if !existingIDs.contains(a.id) { return a }
        }
        // Fallback: deterministically add a suffix until unique
        var attempt = 1
        while true {
            let a = generate(using: &rng)
            let candidate = "\(a.id)_\(attempt)"
            if !existingIDs.contains(candidate) {
                // Insert the numeric suffix just before the emoji segment in the human label.
                var parts = a.label.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
                if parts.count >= 2 {
                    let insertAt = max(parts.count - 1, 1)
                    parts.insert(String(attempt), at: insertAt)
                } else {
                    parts.append(String(attempt))
                }
                let label = parts.joined(separator: "_")
                return (label, candidate)
            }
            attempt += 1
        }
    }

    // MARK: - Helpers

    /// Localized string helper (kept local so this file compiles without external dependencies).
    private static func L(_ key: String, _ comment: String = "") -> String {
        NSLocalizedString(key, comment: comment)
    }

    private static func displayColor(_ token: String) -> String {
        let key = "alias.color.\(token)"
        let v = L(key, "Alias color")
        // Fallback to a readable value if a key is missing.
        return v == key ? token.capitalized : v
    }

    private static func displayAnimal(_ token: String) -> String {
        let key = "alias.animal.\(token)"
        let v = L(key, "Alias animal")
        return v == key ? token.capitalized : v
    }

    /// Pick a random element.
    private static func pick<T>(_ array: [T], using rng: inout some RandomNumberGenerator) -> T {
        let idx = Int.random(in: 0..<array.count, using: &rng)
        return array[idx]
    }

    /// Lowercase snake-case, strip/replace anything non [a-z0-9_].
    private static func sanitize(_ s: String) -> String {
        let lowered = s.lowercased().replacingOccurrences(of: " ", with: "_")
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "_"))
        let scalars = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        // Collapse consecutive underscores
        let collapsed = String(scalars).replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}
