
//
//  GuidelineEngine.swift
//  DrsMainApp
//
//  Local (offline) guideline matching engine.
//  Goal: deterministic matching over a canonical, non-localized feature dictionary.
//
//  IMPORTANT:
//  - This file intentionally does NOT parse localized UI text.
//  - It evaluates guideline JSON against a stable feature map (later SNOMED-backed).
//

import Foundation

// MARK: - Canonical clinical profile interface

/// A read-only view over extracted clinical features.
///
/// Feature keys MUST be stable (non-localized), e.g.
///   - "demographics.age_days"
///   - "vital.temp_c.max"
///   - "symptom.fever.present"
///   - "immunization.status"
///
/// Values are typed. Missing keys are treated as "unknown".
public protocol ClinicalFeatureProviding {
    func bool(_ key: String) -> Bool?
    func int(_ key: String) -> Int?
    func double(_ key: String) -> Double?
    func string(_ key: String) -> String?
    func strings(_ key: String) -> [String]?
}

/// Convenience wrapper you can construct from `[String: Any]`.
/// (Useful while ClinicalFeatureExtractor is still evolving.)
public struct FeatureMapProfile: ClinicalFeatureProviding {
    public let features: [String: Any]

    public init(features: [String: Any]) {
        self.features = features
    }

    public func bool(_ key: String) -> Bool? {
        if let v = features[key] as? Bool { return v }
        if let v = features[key] as? Int { return v != 0 }
        if let v = features[key] as? String {
            let s = v.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "y", "1"].contains(s) { return true }
            if ["false", "no", "n", "0"].contains(s) { return false }
        }
        return nil
    }

    public func int(_ key: String) -> Int? {
        if let v = features[key] as? Int { return v }
        if let v = features[key] as? Int64 { return Int(v) }
        if let v = features[key] as? Double { return Int(v) }
        if let v = features[key] as? String {
            return Int(v.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    public func double(_ key: String) -> Double? {
        if let v = features[key] as? Double { return v }
        if let v = features[key] as? Float { return Double(v) }
        if let v = features[key] as? Int { return Double(v) }
        if let v = features[key] as? String {
            return Double(v.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    public func string(_ key: String) -> String? {
        if let v = features[key] as? String {
            let s = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        if let v = features[key] {
            return String(describing: v)
        }
        return nil
    }

    public func strings(_ key: String) -> [String]? {
        if let v = features[key] as? [String] {
            let cleaned = v.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return cleaned.isEmpty ? nil : cleaned
        }
        if let v = features[key] as? String {
            // Allow a comma-separated string (handy during early refactors)
            let parts = v
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts
        }
        return nil
    }
}

// MARK: - Engine result types

public struct GuidelineMatch: Equatable {
    public let ruleId: String
    public let flagText: String
    public let priority: Int

    public init(ruleId: String, flagText: String, priority: Int = 0) {
        self.ruleId = ruleId
        self.flagText = flagText
        self.priority = priority
    }
}

public struct GuidelineResult {
    public let matches: [GuidelineMatch]

    public init(matches: [GuidelineMatch]) {
        self.matches = matches
    }

    public var flagsForUI: [String] {
        matches
            .sorted { $0.priority > $1.priority }
            .map { $0.flagText }
    }

    public var matchedRuleIds: [String] {
        matches.map { $0.ruleId }
    }
}

// MARK: - Guideline JSON model (minimal, deterministic)

/// Minimal JSON schema we can safely support today.
///
/// Example structure:
/// {
///   "schema_version": "1.0.0",
///   "rules": [
///     {
///       "id": "INFANT_29_60_FEVER",
///       "flag": "Febrile infant 29–60 days: consider UA/IM/blood culture",
///       "priority": 10,
///       "when": {
///         "all": [
///           {"key":"demographics.age_days","op":"between_inclusive","min":29,"max":60},
///           {"key":"vital.temp_c.max","op":"gte","value":38.0}
///         ]
///       }
///     }
///   ]
/// }
public struct GuidelineRuleSetV1: Codable {
    public let schemaVersion: String?
    public let rules: [Rule]

    public init(schemaVersion: String? = nil, rules: [Rule]) {
        self.schemaVersion = schemaVersion
        self.rules = rules
    }

    public struct Rule: Codable {
        public let id: String
        public let flag: String
        public let priority: Int?
        public let when: Predicate

        public init(id: String, flag: String, priority: Int? = nil, when: Predicate) {
            self.id = id
            self.flag = flag
            self.priority = priority
            self.when = when
        }
    }
}

public indirect enum Predicate: Codable {
    case all([Predicate])
    case any([Predicate])
    case not(Predicate)
    case condition(Condition)

    private enum CodingKeys: String, CodingKey {
        case all, any, not
        case key, op, value, values, min, max
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        if c.contains(.all) {
            let arr = try c.decode([Predicate].self, forKey: .all)
            self = .all(arr)
            return
        }
        if c.contains(.any) {
            let arr = try c.decode([Predicate].self, forKey: .any)
            self = .any(arr)
            return
        }
        if c.contains(.not) {
            let p = try c.decode(Predicate.self, forKey: .not)
            self = .not(p)
            return
        }

        // Otherwise: leaf condition
        let key = try c.decode(String.self, forKey: .key)
        let op = try c.decode(String.self, forKey: .op)

        // We support a few value shapes.
        let value = try? c.decode(Double.self, forKey: .value)
        let intValue = try? c.decode(Int.self, forKey: .value)
        let strValue = try? c.decode(String.self, forKey: .value)
        let boolValue = try? c.decode(Bool.self, forKey: .value)
        let values = try? c.decode([String].self, forKey: .values)
        let min = try? c.decode(Double.self, forKey: .min)
        let max = try? c.decode(Double.self, forKey: .max)
        let minInt = try? c.decode(Int.self, forKey: .min)
        let maxInt = try? c.decode(Int.self, forKey: .max)

        let cond = Condition(
            key: key,
            op: Condition.Op(rawValue: op) ?? .unknown(op),
            valueDouble: value,
            valueInt: intValue,
            valueString: strValue,
            valueBool: boolValue,
            values: values,
            minDouble: min,
            maxDouble: max,
            minInt: minInt,
            maxInt: maxInt
        )
        self = .condition(cond)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all(let arr):
            try c.encode(arr, forKey: .all)
        case .any(let arr):
            try c.encode(arr, forKey: .any)
        case .not(let p):
            try c.encode(p, forKey: .not)
        case .condition(let cond):
            try c.encode(cond.key, forKey: .key)
            try c.encode(cond.op.stringValue, forKey: .op)
            if let v = cond.valueDouble {
                try c.encode(v, forKey: .value)
            } else if let v = cond.valueInt {
                try c.encode(v, forKey: .value)
            } else if let v = cond.valueString {
                try c.encode(v, forKey: .value)
            } else if let v = cond.valueBool {
                try c.encode(v, forKey: .value)
            }
            if let vs = cond.values {
                try c.encode(vs, forKey: .values)
            }
            if let mn = cond.minDouble { try c.encode(mn, forKey: .min) }
            if let mx = cond.maxDouble { try c.encode(mx, forKey: .max) }
            if let mn = cond.minInt { try c.encode(mn, forKey: .min) }
            if let mx = cond.maxInt { try c.encode(mx, forKey: .max) }
        }
    }
}

public struct Condition: Codable {
    public enum Op: Codable, Equatable {
        case eq
        case neq
        case inSet
        case contains
        case gte
        case gt
        case lte
        case lt
        case betweenInclusive
        case present
        case absent
        case unknown(String)

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Op(rawValue: raw) ?? .unknown(raw)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(self.stringValue)
        }

        public init?(rawValue: String) {
            switch rawValue {
            case "eq": self = .eq
            case "neq": self = .neq
            case "in": self = .inSet
            case "contains": self = .contains
            case "gte": self = .gte
            case "gt": self = .gt
            case "lte": self = .lte
            case "lt": self = .lt
            case "between_inclusive": self = .betweenInclusive
            case "present": self = .present
            case "exists": self = .present
            case "absent": self = .absent
            default: return nil
            }
        }

        public var stringValue: String {
            switch self {
            case .eq: return "eq"
            case .neq: return "neq"
            case .inSet: return "in"
            case .contains: return "contains"
            case .gte: return "gte"
            case .gt: return "gt"
            case .lte: return "lte"
            case .lt: return "lt"
            case .betweenInclusive: return "between_inclusive"
            case .present: return "present"
            case .absent: return "absent"
            case .unknown(let s): return s
            }
        }
    }

    public let key: String
    public let op: Op

    public let valueDouble: Double?
    public let valueInt: Int?
    public let valueString: String?
    public let valueBool: Bool?
    public let values: [String]?

    public let minDouble: Double?
    public let maxDouble: Double?
    public let minInt: Int?
    public let maxInt: Int?

    public init(
        key: String,
        op: Op,
        valueDouble: Double? = nil,
        valueInt: Int? = nil,
        valueString: String? = nil,
        valueBool: Bool? = nil,
        values: [String]? = nil,
        minDouble: Double? = nil,
        maxDouble: Double? = nil,
        minInt: Int? = nil,
        maxInt: Int? = nil
    ) {
        self.key = key
        self.op = op
        self.valueDouble = valueDouble
        self.valueInt = valueInt
        self.valueString = valueString
        self.valueBool = valueBool
        self.values = values
        self.minDouble = minDouble
        self.maxDouble = maxDouble
        self.minInt = minInt
        self.maxInt = maxInt
    }
}

// MARK: - Engine

public enum GuidelineEngine {

    /// Evaluate a guideline JSON ruleset against a clinical profile.
    ///
    /// - Parameters:
    ///   - profile: canonical clinical features (stable keys, non-localized)
    ///   - rulesJSON: the physician-configured JSON
    /// - Returns: deterministic matches, suitable for UI flags
    public static func evaluate(profile: ClinicalFeatureProviding, rulesJSON: String) -> GuidelineResult {
        let trimmed = rulesJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return GuidelineResult(matches: [])
        }

        do {
            let data = Data(trimmed.utf8)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            let ruleSet = try decoder.decode(GuidelineRuleSetV1.self, from: data)

            #if DEBUG
            print("GuidelineEngine: decoded rules=\(ruleSet.rules.count) schema=\(ruleSet.schemaVersion ?? "nil")")

            // Best-effort key sampling for debugging.
            // `ClinicalFeatureProviding` does not expose keys, so we downcast known implementations.
            if let p = profile as? PatientClinicalProfile {
                let keys = p.features.map { $0.key }
                let hasSCT = keys.contains { $0.hasPrefix("sct:") }
                print("GuidelineEngine: profile has sct keys? \(hasSCT)")
                print("GuidelineEngine: sample keys=\(Array(keys.prefix(20)))")
            } else if let p = profile as? FeatureMapProfile {
                let keys = Array(p.features.keys)
                let hasSCT = keys.contains { $0.hasPrefix("sct:") }
                print("GuidelineEngine: profile has sct keys? \(hasSCT)")
                print("GuidelineEngine: sample keys=\(Array(keys.prefix(20)))")
            } else {
                print("GuidelineEngine: profile key sampling unavailable for type \(type(of: profile))")
            }
            #endif

            var matches: [GuidelineMatch] = []
            matches.reserveCapacity(ruleSet.rules.count)

            for rule in ruleSet.rules {

                #if DEBUG
                // Minimal trace to explain why v1 matches or not.
                // NOTE: These keys are the canonical (non-localized) keys used by the engine.
                let ageDays   = profile.int("demographics.age_days")
                let ageMonths = profile.int("demographics.age_months")
                let tempMax   = profile.double("vital.temp_c.max")
                let fever     = profile.bool("symptom.fever.present")
                let sex       = profile.string("demographics.sex")
                let vax       = profile.string("immunization.status")

                print("[GuidelineEngine v1] rule=\(rule.id) pri=\(rule.priority ?? 0)")
                print("  profile: ageDays=\(String(describing: ageDays)) ageMonths=\(String(describing: ageMonths)) tempMax=\(String(describing: tempMax)) fever=\(String(describing: fever)) sex=\(String(describing: sex)) vax=\(String(describing: vax))")
                print("  when: \(rule.when)")
                #endif

                let ok = predicateMatches(rule.when, profile: profile)

                #if DEBUG
                print("  -> match=\(ok)")
                #endif

                if ok {
                    let p = rule.priority ?? 0
                    let text = rule.flag.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        matches.append(GuidelineMatch(ruleId: rule.id, flagText: text, priority: p))
                    }
                }
            }

            return GuidelineResult(matches: matches)
        } catch {
            #if DEBUG
            print("GuidelineEngine: failed to decode rulesJSON: \(error)")
            #endif
            return GuidelineResult(matches: [])
        }
    }

    // MARK: - Predicate evaluation

    private static func predicateMatches(_ p: Predicate, profile: ClinicalFeatureProviding) -> Bool {
        switch p {
        case .all(let arr):
            return arr.allSatisfy { predicateMatches($0, profile: profile) }
        case .any(let arr):
            return arr.contains { predicateMatches($0, profile: profile) }
        case .not(let inner):
            return !predicateMatches(inner, profile: profile)
        case .condition(let c):
            return conditionMatches(c, profile: profile)
        }
    }

    private static func conditionMatches(_ c: Condition, profile: ClinicalFeatureProviding) -> Bool {
        func hasAnyValue(_ key: String) -> Bool {
            if let b = profile.bool(key) { return b || true }
            if profile.int(key) != nil { return true }
            if profile.double(key) != nil { return true }
            if profile.string(key) != nil { return true }
            if profile.strings(key) != nil { return true }
            return false
        }
        switch c.op {
        case .eq:
            // Try string equality first, then numeric.
            if let expected = c.valueBool {
                    return profile.bool(c.key) == expected
                }
            if let expected = c.valueString {
                let actual = profile.string(c.key)
                return normalize(actual) == normalize(expected)
            }
            if let expected = c.valueInt {
                return profile.int(c.key) == expected
            }
            if let expected = c.valueDouble {
                return profile.double(c.key) == expected
            }
            return false

        case .neq:
            if let expected = c.valueBool {
                    return profile.bool(c.key) != expected
                }
            if let expected = c.valueString {
                let actual = profile.string(c.key)
                return normalize(actual) != normalize(expected)
            }
            if let expected = c.valueInt {
                return profile.int(c.key) != expected
            }
            if let expected = c.valueDouble {
                return profile.double(c.key) != expected
            }
            return false

        case .inSet:
            // String membership.
            if let expected = c.values, !expected.isEmpty {
                let set = Set(expected.map { normalize($0) })
                if let actual = profile.string(c.key) {
                    return set.contains(normalize(actual))
                }
                // If the feature is itself an array, treat as any-overlap.
                if let actuals = profile.strings(c.key) {
                    return actuals.contains { set.contains(normalize($0)) }
                }
            }
            return false

        case .contains:
            // Feature string contains expected substring (case-insensitive).
            if let needle = c.valueString {
                let n = normalize(needle)
                if let hay = profile.string(c.key) {
                    return normalize(hay).contains(n)
                }
                if let arr = profile.strings(c.key) {
                    return arr.map(normalize).contains { $0.contains(n) }
                }
            }
            return false

        case .gte:
            if let expected = c.valueDouble {
                if let actual = profile.double(c.key) { return actual >= expected }
            }
            if let expected = c.valueInt {
                if let actual = profile.int(c.key) { return actual >= expected }
            }
            return false

        case .gt:
            if let expected = c.valueDouble {
                if let actual = profile.double(c.key) { return actual > expected }
            }
            if let expected = c.valueInt {
                if let actual = profile.int(c.key) { return actual > expected }
            }
            return false

        case .lte:
            if let expected = c.valueDouble {
                if let actual = profile.double(c.key) { return actual <= expected }
            }
            if let expected = c.valueInt {
                if let actual = profile.int(c.key) { return actual <= expected }
            }
            return false

        case .lt:
            if let expected = c.valueDouble {
                if let actual = profile.double(c.key) { return actual < expected }
            }
            if let expected = c.valueInt {
                if let actual = profile.int(c.key) { return actual < expected }
            }
            return false

        case .betweenInclusive:
            // Numeric range. Supports int or double.
            if let mn = c.minInt, let mx = c.maxInt {
                if let actual = profile.int(c.key) { return actual >= mn && actual <= mx }
                return false
            }
            if let mn = c.minDouble, let mx = c.maxDouble {
                if let actual = profile.double(c.key) { return actual >= mn && actual <= mx }
                return false
            }
            return false

        case .present:
            return hasAnyValue(c.key)

        case .absent:
            return !hasAnyValue(c.key)

        case .unknown:
            return false
        }
    }

    private static func normalize(_ s: String?) -> String {
        (s ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

