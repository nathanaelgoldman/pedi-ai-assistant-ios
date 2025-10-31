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
    private static let emojis  = ["🐬","🦊","🐼","🦁","🦉","🐢","🐨","🦄","🐧","🐳","🐯","🦜","🦋","🐙","🦕","🦓"]
    private static let colors  = ["Gold","Silver","Emerald","Sapphire","Ruby","Amber","Indigo","Ivory","Obsidian","Coral","Mint","Violet","Azure","Cocoa","Slate"]
    private static let animals = ["Dolphin","Panda","Falcon","Tiger","Owl","Turtle","Koala","Unicorn","Penguin","Whale","Lion","Parrot","Butterfly","Octopus","Dragon","Zebra"]

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
        let color  = pick(Self.colors, using: &rng)
        let animal = pick(Self.animals, using: &rng)
        let emoji  = pick(Self.emojis, using: &rng)

        let label = "\(color)_\(animal)_\(emoji)"
        let rawID = "\(color)_\(animal)"
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
                let label = a.label.replacingOccurrences(of: "_\(a.id.split(separator: "_").last ?? "")", with: "_\(a.id.split(separator: "_").last ?? "")_\(attempt)")
                return (label, candidate)
            }
            attempt += 1
        }
    }

    // MARK: - Helpers

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
