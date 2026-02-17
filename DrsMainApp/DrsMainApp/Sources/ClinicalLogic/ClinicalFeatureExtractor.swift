
//
//  ClinicalFeatureExtractor.swift
//  DrsMainApp
//
//  Builds a structured, locale-agnostic clinical “identity” snapshot of a patient
//  for guideline matching + AI context.
//
//  Key design goal: avoid brittle string matching on localized UI text.
//  We emit stable feature keys (and optionally SNOMED IDs) while keeping
//  the original display strings for UI/debug.
//


import Foundation

/// Minimal contract for building a canonical clinical profile from an episode context,
/// without coupling ClinicalFeatureExtractor to AppState.
protocol EpisodeAIContextProviding {
    var patientID: Int { get }
    var episodeID: Int { get }

    var problemListing: String { get }
    var complementaryInvestigations: String { get }

    var vaccinationStatus: String? { get }
    var perinatalSummary: String? { get }
    var pmhSummary: String? { get }

    var patientAgeDays: Int? { get }
    var patientSex: String? { get }
    var maxTempC: Double? { get }
}

// MARK: - Core Models

/// A stable, locale-agnostic feature emitted by extraction.
///
/// - `key` should be a *stable token* used by guideline predicates.
///   Example: "vital.temp_c.max", "symptom.fever.present", "pe.lungs.wheeze".
/// - `snomedConceptId` is optional and can be filled later once SNOMED lookup is wired.
struct ClinicalFeature: Codable, Hashable {
    enum Value: Codable, Hashable {
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case strings([String])
        case date(Date)

        // Convenience for JSON-ish payloads
        var asString: String {
            switch self {
            case .bool(let b): return b ? "true" : "false"
            case .int(let i): return String(i)
            case .double(let d):
                // Keep it human friendly; avoid scientific notation.
                return String(format: "%.3f", d).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
            case .string(let s): return s
            case .strings(let a): return a.joined(separator: ", ")
            case .date(let dt):
                return ISO8601DateFormatter().string(from: dt)
            }
        }
    }

    let key: String
    let value: Value

    /// Optional SNOMED CT concept id (e.g., 386661006 for Fever).
    var snomedConceptId: Int64?

    /// Optional free text / provenance.
    var note: String?

    /// Whether this is an objective positive finding (vitals abnormality, PE finding, lab result).
    var isObjectivePositive: Bool

    /// Whether this should be considered abnormal/flagged.
    /// (Some positives are normal by definition; e.g., normal weight gain.)
    var isAbnormal: Bool

    /// Source tag for debugging and provenance.
    /// Examples: "vitals", "pe", "pmh", "vaccinations", "perinatal", "well_visit", "episode".
    var source: String
}

/// A structured clinical snapshot for decision support.
struct PatientClinicalProfile: Codable {
    // Identity
    var patientId: Int64
    var sex: String?              // stable token if possible ("M", "F", "X")
    var dob: Date?                // used to compute age at encounter

    // Encounter context
    var encounterDate: Date?
    var ageDays: Int?
    var ageMonths: Int?

    // Aggregates
    var features: [ClinicalFeature]

    // Convenience partitions
    var objectivePositiveFindings: [ClinicalFeature]
    var abnormalFindings: [ClinicalFeature]

    // Text “breadcrumbs” (kept for humans/debugging; NOT for matching)
    var provenanceNotes: [String]
}

// MARK: - Matching-friendly views

extension PatientClinicalProfile {

    /// Deterministic lookup map: last-write-wins if duplicate keys exist.
    /// Intended for guideline predicate evaluation.
    var featureValueByKey: [String: ClinicalFeature.Value] {
        var map: [String: ClinicalFeature.Value] = [:]
        for f in features {
            map[f.key] = f.value
        }
        return map
    }

    /// Convenience set of keys that are effectively "present".
    ///
    /// Rules of thumb:
    /// - `.bool(true)` => present
    /// - numeric/string/date => present
    /// - `.strings([])` => not present
    /// - `.string("")` => not present
    var presentKeys: Set<String> {
        var s: Set<String> = []
        for f in features {
            switch f.value {
            case .bool(let b):
                if b { s.insert(f.key) }
            case .int:
                s.insert(f.key)
            case .double:
                s.insert(f.key)
            case .date:
                s.insert(f.key)
            case .string(let str):
                if !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    s.insert(f.key)
                }
            case .strings(let arr):
                if !arr.isEmpty {
                    s.insert(f.key)
                }
            }
        }
        return s
    }

    /// Fetch the first feature for a key (preserving original order).
    func firstFeature(_ key: String) -> ClinicalFeature? {
        features.first(where: { $0.key == key })
    }

    /// Fetch the first value for a key.
    func firstValue(_ key: String) -> ClinicalFeature.Value? {
        firstFeature(key)?.value
    }

    /// Convenience typed getters commonly used by guideline predicates.
    func boolValue(_ key: String) -> Bool? {
        if case .bool(let b) = firstValue(key) { return b }
        return nil
    }

    func intValue(_ key: String) -> Int? {
        if case .int(let i) = firstValue(key) { return i }
        return nil
    }

    func doubleValue(_ key: String) -> Double? {
        if case .double(let d) = firstValue(key) { return d }
        return nil
    }

    func stringValue(_ key: String) -> String? {
        if case .string(let s) = firstValue(key) { return s }
        return nil
    }
}

// MARK: - GuidelineEngine bridge
//
// Let the profile be consumed directly by GuidelineEngine without an AppState wrapper.
extension PatientClinicalProfile: ClinicalFeatureProviding {

    func bool(_ key: String) -> Bool? {
        if case .bool(let b) = firstValue(key) { return b }
        return nil
    }

    func int(_ key: String) -> Int? {
        if case .int(let i) = firstValue(key) { return i }
        return nil
    }

    func double(_ key: String) -> Double? {
        if case .double(let d) = firstValue(key) { return d }
        return nil
    }

    func string(_ key: String) -> String? {
        if case .string(let s) = firstValue(key) { return s }
        return nil
    }

    func strings(_ key: String) -> [String]? {
        if case .strings(let arr) = firstValue(key) { return arr }
        return nil
    }
}

extension PatientClinicalProfile {
    /// Compact, human-readable snapshot for logs/debug panels.
    /// Avoids duplicating clinical derivations in AppState.
    func debugSummaryLine() -> String {
        let n = features.count
        let abn = abnormalFindings.count
        let obj = objectivePositiveFindings.count
        let age = ageDays.map { "ageDays=\($0)" } ?? "ageDays=nil"
        let t = (doubleValue(ClinicalFeatureExtractor.Key.tempCMax)).map { "maxTempC=\($0)" } ?? "maxTempC=nil"
        let fever = (boolValue(ClinicalFeatureExtractor.Key.feverPresent)).map { "fever=\($0)" } ?? "fever=nil"
        return "Profile(\(age) \(t) \(fever) features=\(n) objective=\(obj) abnormal=\(abn))"
    }
}

// MARK: - SNOMED normalization (dev)
//
// Goal: convert any remaining free-text findings into SNOMED concept IDs using TerminologyStore.
// Numbers/measurements are not touched here.

extension ClinicalFeatureExtractor {

    struct NormalizedConcept: Hashable, Identifiable {
        let id: Int64              // conceptID (SNOMED SCTID)
        let sourceText: String     // original text that led to this match
        let matchedTerm: String    // term from description.term that matched
    }

    /// Convert free text → SNOMED concepts (best-effort).
    /// Keep it intentionally simple until RF2 is available.
    func normalizeFreeTextFindings(
        _ texts: [String],
        terminology: TerminologyStore
    ) -> [NormalizedConcept] {
        var out: [NormalizedConcept] = []
        out.reserveCapacity(texts.count)

        for raw in texts {
            let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { continue }

            if let hit = terminology.bestConceptMatch(q) {
                out.append(
                    NormalizedConcept(
                        id: hit.conceptID,
                        sourceText: q,
                        matchedTerm: hit.term
                    )
                )
            }
        }

        // de-dup by conceptID (keep first sourceText for now)
        var seen = Set<Int64>()
        return out.filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Input Shapes (minimal + decoupled)

/// Minimal vitals snapshot (extend as needed).
struct VitalsSnapshot {
    var takenAt: Date?
    var tempC: Double?
    var hr: Int?
    var rr: Int?
    var spo2: Int?
    var systolic: Int?
    var diastolic: Int?
}

/// Minimal vaccination snapshot (tokens should be stable, not localized).
struct VaccinationSnapshot {
    /// e.g., "complete", "incomplete", "none", "unknown".
    var statusToken: String?
    /// optional list of codes/tokens for known vaccines.
    var vaccineTokens: [String]
}

/// Minimal perinatal snapshot (extend as needed).
struct PerinatalSnapshot {
    var gestationalAgeWeeks: Int?
    var birthWeightG: Int?
    var nicuStay: Bool?
    var infectionRiskText: String?
}

/// A normalized episode / problem list line emitted by forms.
/// IMPORTANT: `tokens` should be stable (ideally SNOMED-backed later).
struct ProblemLine {
    var display: String
    var tokens: [String]           // stable tokens (not localized)
    var isObjective: Bool
    var isAbnormal: Bool
    var source: String
}

// MARK: - Extractor

@MainActor
final class ClinicalFeatureExtractor {

    // MARK: Feature Keys (stable contract)
    enum Key {
        // Demographics
        // v1 guideline engine canonical keys
        static let demographicsSex = "demographics.sex"
        static let demographicsAgeDays = "demographics.age_days"
        static let demographicsAgeMonths = "demographics.age_months"

        // Back-compat keys (older rules / legacy consumers)
        static let sex = "patient.sex"
        static let ageDays = "patient.age_days"
        static let ageMonths = "patient.age_months"

        // Vaccinations
        static let vaxStatus = "vaccination.status"

        // Vitals
        static let tempCMax = "vital.temp_c.max"
        static let feverPresent = "symptom.fever.present"
        static let hr = "vital.hr"
        static let rr = "vital.rr"
        static let spo2 = "vital.spo2"
        static let bpSys = "vital.bp.systolic"
        static let bpDia = "vital.bp.diastolic"

        // Perinatal
        static let gaWeeks = "perinatal.ga_weeks"
        static let birthWeightG = "perinatal.birth_weight_g"
        static let nicuStay = "perinatal.nicu_stay"

        // Examples for PE tokens (expand)
        static let peLungsWheeze = "pe.lungs.wheeze"
        static let generalIrritable = "behavior.irritable"
    }

    /// Extract a structured clinical profile.
    ///
    /// You can call this from AppState when you have:
    /// - patient demographics
    /// - latest vitals around encounter
    /// - vaccination/perinatal summary
    /// - normalized problem lines from episode/well visit
    func buildProfile(
        patientId: Int64,
        sexToken: String?,
        dob: Date?,
        encounterDate: Date?,
        vitals: [VitalsSnapshot],
        vaccination: VaccinationSnapshot?,
        perinatal: PerinatalSnapshot?,
        problemLines: [ProblemLine],
        terminology: TerminologyStore? = nil
    ) -> PatientClinicalProfile {

        var notes: [String] = []
        var features: [ClinicalFeature] = []
        // Minimal extraction-owned debug breadcrumbs (keeps AppState dumb).
        if let encounterDate {
            notes.append("Encounter date: \(ISO8601DateFormatter().string(from: encounterDate))")
        }

        // Age
        let age = Self.computeAge(dob: dob, on: encounterDate)
        if let sexToken {
            // Canonical key for v1 engine
            features.append(.init(
                key: Key.demographicsSex,
                value: .string(sexToken),
                snomedConceptId: nil,
                note: nil,
                isObjectivePositive: true,
                isAbnormal: false,
                source: "demographics"
            ))
            // Back-compat key
            features.append(.init(
                key: Key.sex,
                value: .string(sexToken),
                snomedConceptId: nil,
                note: nil,
                isObjectivePositive: true,
                isAbnormal: false,
                source: "demographics"
            ))
        }
        if let d = age.ageDays {
            // Canonical key for v1 engine
            features.append(.init(
                key: Key.demographicsAgeDays,
                value: .int(d),
                snomedConceptId: nil,
                note: nil,
                isObjectivePositive: true,
                isAbnormal: false,
                source: "demographics"
            ))
            // Back-compat key
            features.append(.init(
                key: Key.ageDays,
                value: .int(d),
                snomedConceptId: nil,
                note: nil,
                isObjectivePositive: true,
                isAbnormal: false,
                source: "demographics"
            ))
        }
        if let m = age.ageMonths {
            // Canonical key for v1 engine
            features.append(.init(
                key: Key.demographicsAgeMonths,
                value: .int(m),
                snomedConceptId: nil,
                note: nil,
                isObjectivePositive: true,
                isAbnormal: false,
                source: "demographics"
            ))
            // Back-compat key
            features.append(.init(
                key: Key.ageMonths,
                value: .int(m),
                snomedConceptId: nil,
                note: nil,
                isObjectivePositive: true,
                isAbnormal: false,
                source: "demographics"
            ))
        }

        // Vaccinations
        if let vaccination {
            if let status = vaccination.statusToken {
                features.append(.init(
                    key: Key.vaxStatus,
                    value: .string(status),
                    snomedConceptId: nil,
                    note: nil,
                    isObjectivePositive: true,
                    isAbnormal: false,
                    source: "vaccinations"
                ))
            }
            if !vaccination.vaccineTokens.isEmpty {
                notes.append("Vaccines tokens: \(vaccination.vaccineTokens.joined(separator: ", "))")
            }
        }

        // Perinatal
        if let perinatal {
            if let ga = perinatal.gestationalAgeWeeks {
                features.append(.init(
                    key: Key.gaWeeks,
                    value: .int(ga),
                    snomedConceptId: nil,
                    note: nil,
                    isObjectivePositive: true,
                    isAbnormal: false,
                    source: "perinatal"
                ))
            }
            if let bw = perinatal.birthWeightG {
                features.append(.init(
                    key: Key.birthWeightG,
                    value: .int(bw),
                    snomedConceptId: nil,
                    note: nil,
                    isObjectivePositive: true,
                    isAbnormal: false,
                    source: "perinatal"
                ))
            }
            if let nicu = perinatal.nicuStay {
                features.append(.init(
                    key: Key.nicuStay,
                    value: .bool(nicu),
                    snomedConceptId: nil,
                    note: nil,
                    isObjectivePositive: true,
                    isAbnormal: false,
                    source: "perinatal"
                ))
            }
            if let txt = perinatal.infectionRiskText, !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                notes.append("Perinatal infection risk: \(txt)")
            }
        }

        // Vitals (use max temp for fever logic; other vitals: last-known at/near encounter)
        let vAgg = Self.aggregateVitals(vitals, encounterDate: encounterDate)
        if let maxTemp = vAgg.maxTempC {
            features.append(.init(
                key: Key.tempCMax,
                value: .double(maxTemp),
                snomedConceptId: nil,
                note: "max temp among selected vitals",
                isObjectivePositive: true,
                isAbnormal: maxTemp >= 38.0,
                source: "vitals"
            ))

            // Fever boolean feature (stable)
            features.append(.init(
                key: Key.feverPresent,
                value: .bool(maxTemp >= 38.0),
                snomedConceptId: nil,
                note: "derived from vital.temp_c.max >= 38.0",
                isObjectivePositive: true,
                isAbnormal: maxTemp >= 38.0,
                source: "derived"
            ))

            // Optional: if we have a terminology store, map the derived fever flag to a SNOMED concept
            // via DB lookup (no hard-coded concept IDs).
            if maxTemp >= 38.0, let terminology {
                // Try English + French (keeps UI locale independent enough for now).
                let queries = ["fever", "fièvre"]
                for q in queries {
                    if let hit = terminology.bestConceptMatch(q) {
                        let sctKey = "sct:\(hit.conceptID)"

                        // Avoid duplicate SCT features if the same concept was already emitted
                        // (e.g., via ProblemLines mapping).
                        if !features.contains(where: { $0.key == sctKey }) {
                            features.append(.init(
                                key: sctKey,
                                value: .bool(true),
                                snomedConceptId: hit.conceptID,
                                note: "derived fever → \(hit.term)",
                                isObjectivePositive: true,
                                isAbnormal: true,
                                source: "derived.snomed"
                            ))
                        }
                        break
                    }
                }
            }
        }
        if let hr = vAgg.hr {
            features.append(.init(
                key: Key.hr,
                value: .int(hr),
                snomedConceptId: nil,
                note: "nearest vitals",
                isObjectivePositive: true,
                isAbnormal: false,
                source: "vitals"
            ))
        }
        if let rr = vAgg.rr {
            features.append(.init(
                key: Key.rr,
                value: .int(rr),
                snomedConceptId: nil,
                note: "nearest vitals",
                isObjectivePositive: true,
                isAbnormal: false,
                source: "vitals"
            ))
        }
        if let spo2 = vAgg.spo2 {
            features.append(.init(
                key: Key.spo2,
                value: .int(spo2),
                snomedConceptId: nil,
                note: "nearest vitals",
                isObjectivePositive: true,
                isAbnormal: spo2 < 95,
                source: "vitals"
            ))
        }
        if let sys = vAgg.systolic {
            features.append(.init(
                key: Key.bpSys,
                value: .int(sys),
                snomedConceptId: nil,
                note: "nearest vitals",
                isObjectivePositive: true,
                isAbnormal: false,
                source: "vitals"
            ))
        }
        if let dia = vAgg.diastolic {
            features.append(.init(
                key: Key.bpDia,
                value: .int(dia),
                snomedConceptId: nil,
                note: "nearest vitals",
                isObjectivePositive: true,
                isAbnormal: false,
                source: "vitals"
            ))
        }

        // Problem lines
        // - If tokens are already stable keys (e.g. "pe.lungs.wheeze"), we emit them directly.
        // - If tokens look like SNOMED ids ("sct:386661006" or "386661006"), we emit an SCT feature.
        // - If tokens are free text and `terminology` is available, we best-effort map to SNOMED and emit SCT features.
        // - We always keep the original display line as provenance via `note` or `provenanceNotes`.

        func emitToken(_ rawToken: String, line: ProblemLine) {
            let t = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }

            // Helper: detect numeric SCTID
            func parseSCTID(_ s: String) -> Int64? {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("sct:") {
                    let rest = String(trimmed.dropFirst(4))
                    return Int64(rest)
                }
                return Int64(trimmed)
            }

            // Case A: token is already an SCTID (numeric or sct: prefix)
            if let sct = parseSCTID(t) {
                features.append(.init(
                    key: "sct:\(sct)",
                    value: .bool(true),
                    snomedConceptId: sct,
                    note: line.display,
                    isObjectivePositive: line.isObjective,
                    isAbnormal: line.isAbnormal,
                    source: line.source
                ))
                return
            }

            // Case B: token is a stable key we can use directly
            // (We do not attempt to localize/parse these here.)
            features.append(.init(
                key: t,
                value: .bool(true),
                snomedConceptId: nil,
                note: line.display,
                isObjectivePositive: line.isObjective,
                isAbnormal: line.isAbnormal,
                source: line.source
            ))
        }

        for line in problemLines {
            if line.tokens.isEmpty {
                // Best-effort: if we have terminology, try mapping the display text.
                if let terminology {
                    // Many ProblemLine.display values are formatted like "Section : Finding".
                    // Try several candidate strings so localized prefixes don't block matching.
                    let raw = line.display.trimmingCharacters(in: .whitespacesAndNewlines)

                    var candidates: [String] = []
                    candidates.append(raw)

                    // Split on common separators and keep the *rightmost* chunk.
                    let seps: [String] = [":", "：", "-", "—"]
                    for sep in seps {
                        if raw.contains(sep) {
                            let parts = raw.split(separator: Character(sep), omittingEmptySubsequences: true)
                            if let last = parts.last {
                                let tail = String(last).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !tail.isEmpty { candidates.append(tail) }
                            }
                        }
                    }

                    // Also try comma/semicolon-splitting on the tail (e.g., "wheeze, crackles").
                    if let last = candidates.last {
                        let more = last
                            .split(whereSeparator: { ",;".contains($0) })
                            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        candidates.append(contentsOf: more)
                    }

                    // De-dup while preserving order.
                    var seen = Set<String>()
                    let uniqueCandidates = candidates.filter { seen.insert($0.lowercased()).inserted }

                    let hits = normalizeFreeTextFindings(uniqueCandidates, terminology: terminology)
                    if hits.isEmpty {
                        notes.append("ProblemLine(\(line.source)): \(line.display)")
                    } else {
                        for h in hits {
                            features.append(.init(
                                key: "sct:\(h.id)",
                                value: .bool(true),
                                snomedConceptId: h.id,
                                note: "\(line.display) → \(h.matchedTerm)",
                                isObjectivePositive: line.isObjective,
                                isAbnormal: line.isAbnormal,
                                source: line.source
                            ))
                        }
                    }
                } else {
                    notes.append("ProblemLine(\(line.source)): \(line.display)")
                }
                continue
            }

            // Emit tokens as-is first (stable contract), then optionally add SNOMED normalization for tokens
            // that look like free text (contains spaces) when terminology is available.
            for tok in line.tokens {
                emitToken(tok, line: line)

                // If this token looks like free text (e.g., contains spaces) and terminology exists, add SCT mapping too.
                if let terminology {
                    let tt = tok.trimmingCharacters(in: .whitespacesAndNewlines)
                    if tt.contains(" ") {
                        if let hit = terminology.bestConceptMatch(tt) {
                            features.append(.init(
                                key: "sct:\(hit.conceptID)",
                                value: .bool(true),
                                snomedConceptId: hit.conceptID,
                                note: "\(line.display) → \(hit.term)",
                                isObjectivePositive: line.isObjective,
                                isAbnormal: line.isAbnormal,
                                source: line.source
                            ))
                        }
                    }
                }
            }
        }

        // SNOMED mirror features
        let existingKeys = Set(features.map { $0.key })
        let snapshot = features
        var addedSCTKeys = Set<String>()

        for f in snapshot {
            guard let id = f.snomedConceptId else { continue }
            let k = "sct:\(id)"
            guard !existingKeys.contains(k), addedSCTKeys.insert(k).inserted else { continue }

            features.append(.init(
                key: k,
                value: .bool(true),
                snomedConceptId: id,
                note: f.key,
                isObjectivePositive: f.isObjectivePositive,
                isAbnormal: f.isAbnormal,
                source: "snomed_mirror"
            ))
        }
        // Final de-dupe: keep the FIRST occurrence of each key (preserves provenance order)
        var seenKeys = Set<String>()
        features = features.filter { seenKeys.insert($0.key).inserted }
        // Partitions
        let objective = features.filter { $0.isObjectivePositive }
        let abnormal = features.filter { $0.isAbnormal }

        // Extraction summary breadcrumbs
        notes.append("Features total: \(features.count)")
        if !abnormal.isEmpty {
            let abnKeys = abnormal.map { $0.key }.prefix(20).joined(separator: ", ")
            notes.append("Abnormal keys (first 20): \(abnKeys)")
        }

        return PatientClinicalProfile(
            patientId: patientId,
            sex: sexToken,
            dob: dob,
            encounterDate: encounterDate,
            ageDays: age.ageDays,
            ageMonths: age.ageMonths,
            features: features,
            objectivePositiveFindings: objective,
            abnormalFindings: abnormal,
            provenanceNotes: notes
        )
    }
}

// MARK: - Helpers

extension ClinicalFeatureExtractor {

    struct AgeResult {
        var ageDays: Int?
        var ageMonths: Int?
    }

    static func computeAge(dob: Date?, on date: Date?) -> AgeResult {
        guard let dob, let date else { return .init(ageDays: nil, ageMonths: nil) }
        let cal = Calendar(identifier: .gregorian)
        let days = cal.dateComponents([.day], from: dob, to: date).day
        let months = cal.dateComponents([.month], from: dob, to: date).month
        return .init(ageDays: days, ageMonths: months)
    }

    struct VitalsAgg {
        var maxTempC: Double?
        var hr: Int?
        var rr: Int?
        var spo2: Int?
        var systolic: Int?
        var diastolic: Int?
    }

    /// For now: choose max temperature across all provided vitals.
    /// For other vitals: pick the nearest snapshot to encounterDate, else last.
    static func aggregateVitals(_ vitals: [VitalsSnapshot], encounterDate: Date?) -> VitalsAgg {
        guard !vitals.isEmpty else { return .init() }

        let maxTemp = vitals.compactMap { $0.tempC }.max()

        func nearest() -> VitalsSnapshot {
            guard let encounterDate else {
                return vitals.sorted(by: { ($0.takenAt ?? .distantPast) < ($1.takenAt ?? .distantPast) }).last ?? vitals[0]
            }
            return vitals.min(by: {
                abs(($0.takenAt ?? .distantPast).timeIntervalSince(encounterDate)) < abs(($1.takenAt ?? .distantPast).timeIntervalSince(encounterDate))
            }) ?? vitals[0]
        }

        let n = nearest()
        return .init(
            maxTempC: maxTemp,
            hr: n.hr,
            rr: n.rr,
            spo2: n.spo2,
            systolic: n.systolic,
            diastolic: n.diastolic
        )
    }
}

// MARK: - Convenience factories

extension ClinicalFeature {
    static func flag(
        _ key: String,
        _ abnormal: Bool,
        source: String,
        note: String? = nil,
        snomed: Int64? = nil,
        objective: Bool = true
    ) -> ClinicalFeature {
        .init(
            key: key,
            value: .bool(true),
            snomedConceptId: snomed,
            note: note,
            isObjectivePositive: objective,
            isAbnormal: abnormal,
            source: source
        )
    }
}



// MARK: - Episode context adapter

extension ClinicalFeatureExtractor {

    /// Build a canonical clinical profile from an episode context, but with demographics supplied
    /// by the caller (DB-backed), so the extractor does not invent DOB/sex.
    ///
    /// - Note: This is the preferred entry point once AppState can pass DOB/sex from the patient record.
    func buildProfile(
        fromEpisodeContext ctx: EpisodeAIContextProviding,
        patientDOB: Date?,
        patientSexToken: String?,
        encounterDate: Date = Date(),
        terminology: TerminologyStore? = nil
    ) -> PatientClinicalProfile {

        // Structured vitals (max temp). Other vitals are not available in EpisodeAIContext yet.
        let vitals: [VitalsSnapshot] = [
            VitalsSnapshot(
                takenAt: encounterDate,
                tempC: ctx.maxTempC,
                hr: nil,
                rr: nil,
                spo2: nil,
                systolic: nil,
                diastolic: nil
            )
        ]

        // Vaccination token (already structured enough for now).
        let vaccination: VaccinationSnapshot? = {
            guard let raw = ctx.vaccinationStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return VaccinationSnapshot(statusToken: raw, vaccineTokens: [])
        }()

        // Perinatal: keep as provenance until structured fields exist.
        let perinatal: PerinatalSnapshot? = {
            guard let raw = ctx.perinatalSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return PerinatalSnapshot(
                gestationalAgeWeeks: nil,
                birthWeightG: nil,
                nicuStay: nil,
                infectionRiskText: raw
            )
        }()

        // Problem lines: transport only; no parsing. Tokens remain empty until form emits stable tokens.
        func toProblemLines(_ text: String, source: String) -> [ProblemLine] {
            text.split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map {
                    ProblemLine(
                        display: $0,
                        tokens: [],
                        isObjective: false,
                        isAbnormal: false,
                        source: source
                    )
                }
        }

        var problemLines: [ProblemLine] = []
        problemLines.append(contentsOf: toProblemLines(ctx.problemListing, source: "episode.problem_listing"))

        let inv = ctx.complementaryInvestigations.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inv.isEmpty {
            problemLines.append(contentsOf: toProblemLines(inv, source: "episode.complementary_investigations"))
        }

        if let pmhRaw = ctx.pmhSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !pmhRaw.isEmpty {
            problemLines.append(contentsOf: toProblemLines(pmhRaw, source: "episode.pmh"))
        }

        let sexToken = patientSexToken?.trimmingCharacters(in: .whitespacesAndNewlines)

        return buildProfile(
            patientId: Int64(ctx.patientID),
            sexToken: (sexToken?.isEmpty == true ? nil : sexToken),
            dob: patientDOB,
            encounterDate: encounterDate,
            vitals: vitals,
            vaccination: vaccination,
            perinatal: perinatal,
            problemLines: problemLines,
            terminology: terminology
        )
    }

    /// Build a canonical clinical profile directly from an episode context.
    ///
    /// This keeps AppState free of clinical parsing/derivation logic.
    /// AppState should pass its EpisodeAIContext (conforming to EpisodeAIContextProviding)
    /// and let the extractor perform any necessary *structured* adaptation.
    func buildProfile(
        fromEpisodeContext ctx: EpisodeAIContextProviding,
        encounterDate: Date = Date(),
        terminology: TerminologyStore? = nil
    ) -> PatientClinicalProfile {

        #if DEBUG
        print("[Extractor] Incoming ctx: patientID=\(ctx.patientID) ageDays=\(String(describing: ctx.patientAgeDays)) sex=\(String(describing: ctx.patientSex)) maxTempC=\(String(describing: ctx.maxTempC))")
        #endif

        // Back-compat shim: if the caller did not provide DOB yet, we can only
        // derive a DOB from a structured numeric age (days). This is NOT free-text parsing.
        let dobFallback: Date? = {
            guard let ageDays = ctx.patientAgeDays else { return nil }
            return Calendar(identifier: .gregorian).date(byAdding: .day, value: -ageDays, to: encounterDate)
        }()

        let profile = buildProfile(
            fromEpisodeContext: ctx,
            patientDOB: dobFallback,
            patientSexToken: ctx.patientSex,
            encounterDate: encounterDate,
            terminology: terminology
        )

        #if DEBUG
        print("[Extractor] Built profile: \(profile.debugSummaryLine())")
        #endif

        return profile
    }
}
