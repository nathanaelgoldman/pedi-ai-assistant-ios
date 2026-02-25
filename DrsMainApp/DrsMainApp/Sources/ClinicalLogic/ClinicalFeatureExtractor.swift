
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

// Curated “reassuring negatives” allowlist.
// When the *normal/well* UI token is present, we emit the corresponding neg: key.


/// Minimal contract for building a canonical clinical profile from an episode context,
/// without coupling ClinicalFeatureExtractor to AppState.
protocol EpisodeAIContextProviding {
    var patientID: Int { get }
    var episodeID: Int { get }

    var problemListing: String { get }
    var complementaryInvestigations: String { get }

    /// Stable, locale-agnostic tokens for guideline matching (UI choice keys).
    /// Example: "sick_episode_form.choice.wheeze".
    var problemTokens: [String] { get }

    var vaccinationStatus: String? { get }
    var perinatalSummary: String? { get }
    var pmhSummary: String? { get }

    // Structured perinatal fields (optional). These complement perinatalSummary (free text) and
    // allow guideline rules to match on stable numeric/boolean keys.
    var gestationalAgeWeeks: Int? { get }
    var birthWeightG: Int? { get }
    var nicuStay: Bool? { get }
    var perinatalRaw: [String: String]? { get }

    var patientAgeDays: Int? { get }
    var patientSex: String? { get }
    
    /// Fever duration in days (structured UI field if available)
    var feverDurationDays: Int? { get }

    // Vitals (values + pre-evaluated abnormal flags; evaluator lives outside extractor)
    var maxTempC: Double? { get }
    var maxTempIsAbnormal: Bool? { get }

    var spo2: Int? { get }
    var spo2IsAbnormal: Bool? { get }
}

extension EpisodeAIContextProviding {
    var problemTokens: [String] { [] }
    var feverDurationDays: Int? { nil }
    var maxTempIsAbnormal: Bool? { nil }
    var spo2: Int? { nil }
    var spo2IsAbnormal: Bool? { nil }

    var gestationalAgeWeeks: Int? { nil }
    var birthWeightG: Int? { nil }
    var nicuStay: Bool? { nil }
    var perinatalRaw: [String: String]? { nil }
    
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
    
    private static let reassuringNegMap: [String: String] = [
        // HPI
        "sick.hpi.appearance.well":       "neg:hpi.general_condition.poor",
        "sick.hpi.feeding.normal":        "neg:hpi.feeding.poor",
        "sick.hpi.breathing.normal":      "neg:hpi.resp.distress",
        "sick.hpi.urination.normal":      "neg:hpi.urination.decreased",
        "sick.hpi.pain_location.none":    "neg:hpi.pain.present",
        "sick.hpi.vomiting.no":           "neg:hpi.vomiting.present",  // adjust if your token name differs

        // PE
        "sick.pe.general_appearance.well":"neg:pe.appearance.toxic",
        "sick.pe.hydration.normal":       "neg:pe.hydration.dehydrated",
        "sick.pe.color_hemodynamics.normal":"neg:pe.hemodynamics.abnormal",
        "sick.pe.neuro.alert":            "neg:pe.neuro.altered",
        "sick.pe.skin.no_petechiae":      "neg:pe.skin.petechiae"      // adjust if your token name differs
    ]

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
/// Minimal vitals snapshot (extend as needed).
/// NOTE: abnormality evaluation is owned by VitalsRange / VitalsBP.
/// This struct just transports already-evaluated flags into the extractor.
struct VitalsSnapshot {
    var takenAt: Date?

    var tempC: Double?
    var tempIsAbnormal: Bool?      // e.g., >= 38.0 (or your rule)

    var hr: Int?
    var hrIsAbnormal: Bool?

    var rr: Int?
    var rrIsAbnormal: Bool?

    var spo2: Int?
    var spo2IsAbnormal: Bool?

    var systolic: Int?
    var diastolic: Int?
    var bpIsAbnormal: Bool?        // or keep more granular if you want later
    var bpCategoryToken: String?   // optional: "normal", "elevated", "stage1", ...
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

    // MARK: - Perinatal risk factors (for guideline matching)

    /// Maternal gestational diabetes during pregnancy.
    var maternalGestationalDiabetes: Bool?

    /// Any significant maternal infection during pregnancy (non-specific; local database does not store details).
    var maternalInfectionPregnancy: Bool?

    /// TORCH seroconversion during pregnancy (non-specific; local database does not store which pathogen).
    var torchSeroconversion: Bool?

    /// Prolonged rupture of membranes. If true, we will emit `perinatal.prom_hours` with a conservative default (18h).
    var promProlonged: Bool?

    /// GBS prophylaxis at delivery.
    /// - "antibiotic": GBS+ with adequate intrapartum antibiotics
    /// - "none": GBS+ without antibiotics
    /// - nil/"unknown": not known
    var gbsProphylaxis: String?

    // If you add an explicit initializer, update it to include these fields.
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

    // MARK: - Guideline Key Registry (single source of truth)

    enum GuidelineKeyCategory: String, CaseIterable {
        case demographics
        case fever
        case vitals
        case vaccination
        case perinatal
        case negatives
        case snomed
        case other

        /// Localization key for the category label shown in UI.
        var labelKey: String {
            switch self {
            case .demographics: return "guideline.key.category.demographics"
            case .fever:        return "guideline.key.category.fever"
            case .vitals:       return "guideline.key.category.vitals"
            case .vaccination:  return "guideline.key.category.vaccination"
            case .perinatal:    return "guideline.key.category.perinatal"
            case .negatives:    return "guideline.key.category.negatives"
            case .snomed:       return "guideline.key.category.snomed"
            case .other:        return "guideline.key.category.other"
            }
        }
    }

    enum GuidelineKeyValueType: String {
        case bool
        case number
        case string
        case list
    }

    struct GuidelineKeyDescriptor: Identifiable, Hashable {
        /// Stable key used by the guideline engine (e.g., "vital.spo2", "symptom.fever.present").
        let key: String

        /// Category used to group keys in the builder UI.
        let category: GuidelineKeyCategory

        /// Localization key (Localizable.strings) for display.
        let labelKey: String

        /// Value type to drive operator choices / input widgets.
        let valueType: GuidelineKeyValueType

        /// Search tags/synonyms (non-localized) to support quick lookup.
        let searchTags: [String]

        /// Optional example shown in UI help.
        let example: String?

        var id: String { key }

        init(
            key: String,
            category: GuidelineKeyCategory,
            labelKey: String,
            valueType: GuidelineKeyValueType,
            searchTags: [String] = [],
            example: String? = nil
        ) {
            self.key = key
            self.category = category
            self.labelKey = labelKey
            self.valueType = valueType
            self.searchTags = searchTags
            self.example = example
        }

        /// Utility used by UI search: combine key + tags + (localized) label.
        func searchBlob(localizedLabel: String) -> String {
            ([localizedLabel, key] + searchTags)
                .joined(separator: " ")
                .lowercased()
        }
    }

    /// Canonical list of guideline keys emitted by the extractor.
    /// UI should render `labelKey` via localization and use `searchTags` for lookup.
    static let guidelineKeyRegistry: [GuidelineKeyDescriptor] = [
        // Demographics
        .init(
            key: Key.demographicsAgeDays,
            category: .demographics,
            labelKey: "guideline.key.demographics.age_days",
            valueType: .number,
            searchTags: ["age", "days", "newborn"],
            example: "e.g. 12"
        ),
        .init(
            key: Key.demographicsAgeMonths,
            category: .demographics,
            labelKey: "guideline.key.demographics.age_months",
            valueType: .number,
            searchTags: ["age", "months", "infant"],
            example: "e.g. 3"
        ),
        .init(
            key: Key.demographicsSex,
            category: .demographics,
            labelKey: "guideline.key.demographics.sex",
            valueType: .string,
            searchTags: ["sex", "gender", "M", "F"],
            example: "M / F"
        ),

        // Fever
        .init(
            key: Key.feverPresent,
            category: .fever,
            labelKey: "guideline.key.symptom.fever.present",
            valueType: .bool,
            searchTags: ["fever", "temperature"],
            example: "present"
        ),
        .init(
            key: Key.tempCMax,
            category: .fever,
            labelKey: "guideline.key.vital.temp_c.max",
            valueType: .number,
            searchTags: ["temp", "temperature", "celsius", "max"],
            example: "e.g. 39.5"
        ),
        .init(
            key: Key.feverDurationDays,
            category: .fever,
            labelKey: "guideline.key.symptom.fever.duration_days",
            valueType: .number,
            searchTags: ["duration", "days"],
            example: "e.g. 2"
        ),
        .init(
            key: Key.feverDurationHours,
            category: .fever,
            labelKey: "guideline.key.symptom.fever.duration_hours",
            valueType: .number,
            searchTags: ["duration", "hours"],
            example: "e.g. 36"
        ),

        // Vitals
        .init(
            key: Key.spo2,
            category: .vitals,
            labelKey: "guideline.key.vital.spo2",
            valueType: .number,
            searchTags: ["spo2", "oxygen", "sat", "saturation"],
            example: "e.g. 97"
        ),
        .init(
            key: Key.spo2Low,
            category: .vitals,
            labelKey: "guideline.key.vital.spo2.low",
            valueType: .bool,
            searchTags: ["spo2", "low", "hypoxemia"],
            example: "present"
        ),
        .init(
            key: Key.spo2LowNeg,
            category: .negatives,
            labelKey: "guideline.key.neg.vital.spo2.low",
            valueType: .bool,
            searchTags: ["spo2", "not low", "normal oxygen"],
            example: "present"
        ),
        .init(
            key: Key.hr,
            category: .vitals,
            labelKey: "guideline.key.vital.hr",
            valueType: .number,
            searchTags: ["heart", "rate", "hr", "tachycardia"],
            example: "e.g. 140"
        ),
        .init(
            key: Key.rr,
            category: .vitals,
            labelKey: "guideline.key.vital.rr",
            valueType: .number,
            searchTags: ["resp", "rate", "rr", "tachypnea"],
            example: "e.g. 40"
        ),
        .init(
            key: Key.bpSys,
            category: .vitals,
            labelKey: "guideline.key.vital.bp.systolic",
            valueType: .number,
            searchTags: ["bp", "blood", "pressure", "systolic"],
            example: "e.g. 100"
        ),
        .init(
            key: Key.bpDia,
            category: .vitals,
            labelKey: "guideline.key.vital.bp.diastolic",
            valueType: .number,
            searchTags: ["bp", "blood", "pressure", "diastolic"],
            example: "e.g. 60"
        ),

        // Vaccination
        .init(
            key: Key.vaxStatus,
            category: .vaccination,
            labelKey: "guideline.key.vaccination.status",
            valueType: .string,
            searchTags: ["vaccine", "vaccination", "status"],
            example: "complete / incomplete / unknown"
        ),

        // Perinatal
        .init(
            key: Key.gaWeeks,
            category: .perinatal,
            labelKey: "guideline.key.perinatal.ga_weeks",
            valueType: .number,
            searchTags: ["gestational", "age", "ga"],
            example: "e.g. 39"
        ),
        .init(
            key: Key.birthWeightG,
            category: .perinatal,
            labelKey: "guideline.key.perinatal.birth_weight_g",
            valueType: .number,
            searchTags: ["birth", "weight", "grams"],
            example: "e.g. 3200"
        ),
        .init(
            key: Key.nicuStay,
            category: .perinatal,
            labelKey: "guideline.key.perinatal.nicu_stay",
            valueType: .bool,
            searchTags: ["nicu", "neonatal", "stay"],
            example: "present"
        ),
        
        .init(
            key: Key.perinatalInfectionRFPresent,
            category: .perinatal,
            labelKey: "guideline.key.perinatal.infection_rf_present",
            valueType: .bool,
            searchTags: ["infection", "rf", "eos", "prom", "gbs", "torch"],
            example: "present"
        ),
        .init(
            key: Key.perinatalInfectionRFProm,
            category: .perinatal,
            labelKey: "guideline.key.perinatal.infection_rf_prom",
            valueType: .bool,
            searchTags: ["prom", "rupture", "membranes"],
            example: "present"
        ),
        .init(
            key: Key.perinatalInfectionRFTorch,
            category: .perinatal,
            labelKey: "guideline.key.perinatal.infection_rf_torch",
            valueType: .bool,
            searchTags: ["torch", "sero", "seroconversion"],
            example: "present"
        ),
        .init(
            key: Key.perinatalInfectionRFGbsTreatment,
            category: .perinatal,
            labelKey: "guideline.key.perinatal.infection_rf_gbs_treatment",
            valueType: .bool,
            searchTags: ["gbs", "antibiotic", "treatment"],
            example: "present"
        ),
        .init(
            key: Key.perinatalInfectionRFGbsNoTreatment,
            category: .perinatal,
            labelKey: "guideline.key.perinatal.infection_rf_gbs_no_treatment",
            valueType: .bool,
            searchTags: ["gbs", "no", "antibiotic"],
            example: "present"
        ),

        // General condition / red flags (HPI + PE)
        .init(
            key: "sick.hpi.appearance.irritable",
            category: .other,
            labelKey: "guideline.key.sick.hpi.appearance.irritable",
            valueType: .bool,
            searchTags: ["appearance", "general condition", "irritable", "hpi"],
            example: "present"
        ),
        .init(
            key: "sick.hpi.appearance.lethargic",
            category: .other,
            labelKey: "guideline.key.sick.hpi.appearance.lethargic",
            valueType: .bool,
            searchTags: ["appearance", "general condition", "lethargy", "lethargic", "hpi"],
            example: "present"
        ),
        .init(
            key: "sick.pe.general_appearance.irritable",
            category: .other,
            labelKey: "guideline.key.sick.pe.general_appearance.irritable",
            valueType: .bool,
            searchTags: ["general appearance", "irritable", "pe"],
            example: "present"
        ),
        .init(
            key: "sick.pe.general_appearance.lethargic",
            category: .other,
            labelKey: "guideline.key.sick.pe.general_appearance.lethargic",
            valueType: .bool,
            searchTags: ["general appearance", "lethargy", "lethargic", "pe"],
            example: "present"
        ),

        // SNOMED helper (dynamic keys)
        .init(
            key: "sct:",
            category: .snomed,
            labelKey: "guideline.key.snomed.concept",
            valueType: .bool,
            searchTags: ["snomed", "sct", "concept", "id"],
            example: "sct:56018004"
        )
    ]


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
        static let feverDurationDays = "symptom.fever.duration_days"
        static let feverDurationHours = "symptom.fever.duration_hours"
        static let hr = "vital.hr"
        static let rr = "vital.rr"
        static let spo2 = "vital.spo2"
        // Derived boolean flags (preferred for simple presence-based rule predicates)
        static let spo2Low = "vital.spo2.low"          // SpO₂ classified as low
        static let spo2LowNeg = "neg:vital.spo2.low"   // SpO₂ present and classified as NOT low
        static let bpSys = "vital.bp.systolic"
        static let bpDia = "vital.bp.diastolic"

        // Perinatal
        static let gaWeeks = "perinatal.ga_weeks"
        static let birthWeightG = "perinatal.birth_weight_g"
        static let nicuStay = "perinatal.nicu_stay"
        static let perinatalInfectionRFPresent = "perinatal.infection_rf.present"
        static let perinatalInfectionRFProm = "perinatal.infection_rf.prom"
        static let perinatalInfectionRFTorch = "perinatal.infection_rf.torch_seroconversion"
        static let perinatalInfectionRFGbsTreatment = "perinatal.infection_rf.gbs_treatment"
        static let perinatalInfectionRFGbsNoTreatment = "perinatal.infection_rf.gbs_no_treatment"

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
                isAbnormal: vAgg.maxTempIsAbnormal ?? (maxTemp >= 38.0),
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

            // Curated reassuring negative: afebrile
            if maxTemp < 38.0 {
                let negKey = "neg:vital.temp.fever"
                if !features.contains(where: { $0.key == negKey }) {
                    features.append(.init(
                        key: negKey,
                        value: .bool(true),
                        snomedConceptId: nil,
                        note: "derived from vital.temp_c.max < 38.0",
                        isObjectivePositive: true,
                        isAbnormal: false,
                        source: "derived.neg.vitals"
                    ))
                }

                #if DEBUG
                print("[Extractor] neg vital: afebrile")
                #endif
            }

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
                isAbnormal: vAgg.hrIsAbnormal ?? false,
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
                isAbnormal: vAgg.rrIsAbnormal ?? false,
                source: "vitals"
            ))
        }
        if let spo2 = vAgg.spo2 {
            let isLow = (vAgg.spo2IsAbnormal ?? false)

            // Numeric value remains available for dashboards / future numeric predicates.
            features.append(.init(
                key: Key.spo2,
                value: .int(spo2),
                snomedConceptId: nil,
                note: "nearest vitals",
                isObjectivePositive: true,
                isAbnormal: isLow,
                source: "vitals"
            ))

            // Derived boolean flags for presence-based rules.
            if isLow {
                features.append(.flag(Key.spo2Low, true, source: "derived" , note: "VitalsRanges.classifySpO2 == low"))
            } else {
                features.append(.init(
                    key: Key.spo2LowNeg,
                    value: .bool(true),
                    snomedConceptId: nil,
                    note: "VitalsRanges.classifySpO2 != low",
                    isObjectivePositive: true,
                    isAbnormal: false,
                    source: "derived.neg.vitals"
                ))
            }
        }
        if let sys = vAgg.systolic {
            features.append(.init(
                key: Key.bpSys,
                value: .int(sys),
                snomedConceptId: nil,
                note: "nearest vitals",
                isObjectivePositive: true,
                isAbnormal: vAgg.bpIsAbnormal ?? false,
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
                isAbnormal: vAgg.bpIsAbnormal ?? false,
                source: "vitals"
            ))
        }

        // Problem lines
        // - If tokens are already stable keys (e.g. "pe.lungs.wheeze"), we emit them directly.
        // - If tokens look like SNOMED ids ("sct:386661006" or "386661006"), we emit an SCT feature.
        // - If tokens are free text and `terminology` is available, we best-effort map to SNOMED and emit SCT features.
        // - We always keep the original display line as provenance via `note` or `provenanceNotes`.

        func emitToken(_ rawToken: String, line: ProblemLine, terminology: TerminologyStore?) {
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

            // Case B: token is a stable app feature key.
            // Emit it directly for matching, and if a terminology store exists,
            // also emit the mapped SNOMED SCT feature (sct:<id>) via feature_snomed_map.
            if let terminology {
                if let conceptID = terminology.conceptIDForFeatureKey(t) {
                    features.append(.init(
                        key: "sct:\(conceptID)",
                        value: .bool(true),
                        snomedConceptId: conceptID,
                        note: "feature_key=\(t)",
                        isObjectivePositive: line.isObjective,
                        isAbnormal: line.isAbnormal,
                        source: "feature_map"
                    ))

                    notes.append("feature_map: \(t) -> sct:\(conceptID)")
                    AppLog.feature("extractor").debug("feature_map: \(t) -> sct:\(conceptID)")
                } else {
                    // Telemetry: surface unmapped feature keys so we can fill feature_snomed_map systematically.
                    // Many tokens are intentionally *not* mapped (normal/well/none reassurance tokens),
                    // so only log for tokens that look like positive/abnormal findings.

                    let isReassuringOrNegativeToken: Bool = {
                        if t.hasPrefix("neg:") { return true }
                        if Self.reassuringNegMap[t] != nil { return true }
                        if t.hasSuffix(".normal") { return true }
                        if t.hasSuffix(".well") { return true }
                        if t.hasSuffix(".none") { return true }
                        if t.hasSuffix(".no") { return true }
                        if t.hasSuffix(".alert") { return true }
                        return false
                    }()

                    if !isReassuringOrNegativeToken {
                        // Deduped per app run to avoid log spam.
                        struct MissingFeatureMapLogOnce {
                            static var seen = Set<String>()
                        }
                        if MissingFeatureMapLogOnce.seen.insert(t).inserted {
                            AppLog.feature("extractor").debug("missing_feature_map: \(t)")
                        }
                    }
                }
            }

            // Always keep the stable key too (some rules may key off non-SCT tokens).
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
                emitToken(tok, line: line, terminology: terminology)

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

        // Curated reassuring negatives (emit neg: keys from normal/well tokens)
        do {
            var negKeys: [String] = []
            for f in features {
                if let neg = Self.reassuringNegMap[f.key] {
                    negKeys.append(neg)
                }
            }
            let uniqueNeg = Array(Set(negKeys)).sorted()

            for nk in uniqueNeg {
                if !features.contains(where: { $0.key == nk }) {
                    features.append(.init(
                        key: nk,
                        value: .bool(true),
                        snomedConceptId: nil,
                        note: "derived reassuring negative",
                        isObjectivePositive: true,
                        isAbnormal: false,
                        source: "derived.neg"
                    ))
                }
            }

            #if DEBUG
            if !uniqueNeg.isEmpty {
                print("[Extractor] neg keys: count=\(uniqueNeg.count) sample=\(uniqueNeg.prefix(10))")
            }
            #endif
        }

        // SNOMED mirror features
        // If a feature carries `snomedConceptId`, ensure we also expose a stable `sct:<id>` key.
        // Avoid duplicating keys that are already explicit SCT features.
        var allKeys = Set(features.map { $0.key })
        let snapshot = features

        for f in snapshot {
            // If the feature is already an explicit SCT feature, don't mirror it again.
            if f.key.hasPrefix("sct:") { continue }

            guard let id = f.snomedConceptId, id > 0 else { continue }
            let k = "sct:\(id)"

            // Insert into the key set so we dedupe across both existing and newly-added keys.
            guard allKeys.insert(k).inserted else { continue }

            features.append(.init(
                key: k,
                value: .bool(true),
                snomedConceptId: id,
                note: "mirrored_from=\(f.key)",
                isObjectivePositive: f.isObjectivePositive,
                isAbnormal: f.isAbnormal,
                source: "snomed_mirror"
            ))
        }
        // Final de-dupe: keep the FIRST occurrence of each key (preserves provenance order)
        var seenKeys = Set<String>()
        features = features.filter { seenKeys.insert($0.key).inserted }
        
        // SNOMED ancestor expansion
        // If we have a terminology store with an `isa_edge` subset graph, expand present SCT keys
        // to include their ancestors. This allows guideline rules to target higher-level concepts.
/*        if let terminology {
            // Collect present SCTIDs from explicit `sct:<id>` features.
            let presentSCT: [Int64] = features.compactMap { f in
                guard f.key.hasPrefix("sct:") else { return nil }
                // Present == `.bool(true)`
                if case .bool(let b) = f.value, b == true {
                    let raw = String(f.key.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                    return Int64(raw)
                }
                return nil
            }

            var keys = Set(features.map { $0.key })
            var added = 0
            let maxAdded = 256

            for child in presentSCT {
                if added >= maxAdded { break }
                for anc in terminology.ancestors(of: child) {
                    if added >= maxAdded { break }
                    if anc == child { continue }
                    let k = "sct:\(anc)"
                    guard keys.insert(k).inserted else { continue }

                    features.append(.init(
                        key: k,
                        value: .bool(true),
                        snomedConceptId: anc,
                        note: "ancestor_of=\(child)",
                        isObjectivePositive: false,
                        isAbnormal: false,
                        source: "snomed_ancestor"
                    ))
                    added += 1
                }
            }

            #if DEBUG
            if added > 0 {
                print("[Extractor] SNOMED ancestor expansion added=\(added)")
            }
            #endif

            // Re-run de-dupe to keep first occurrence order stable.
            seenKeys.removeAll(keepingCapacity: true)
            features = features.filter { seenKeys.insert($0.key).inserted }
        }
 */
        #if DEBUG
        // Debug: verify whether high-level ancestors are actually present as explicit SCT keys.
        func isTrueFlag(_ f: ClinicalFeature) -> Bool {
            if case .bool(let b) = f.value { return b }
            return false
        }
        let hasClinicalFinding = features.contains { $0.key == "sct:404684003" && isTrueFlag($0) }
        if hasClinicalFinding {
            print("[Extractor] DEBUG: profile contains sct:404684003 (Clinical finding)")
        } else {
            print("[Extractor] DEBUG: profile does NOT contain sct:404684003 (Clinical finding)")
        }
        #endif
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
        var maxTempIsAbnormal: Bool?

        var hr: Int?
        var hrIsAbnormal: Bool?

        var rr: Int?
        var rrIsAbnormal: Bool?

        var spo2: Int?
        var spo2IsAbnormal: Bool?

        var systolic: Int?
        var diastolic: Int?
        var bpIsAbnormal: Bool?
        var bpCategoryToken: String?
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

        // For temp: if ANY snapshot flagged abnormal => abnormal.
        // If no flags exist at all => nil.
        let tempFlags = vitals.compactMap { $0.tempIsAbnormal }
        let maxTempIsAbnormal: Bool? = tempFlags.isEmpty ? nil : tempFlags.contains(true)

        return .init(
            maxTempC: maxTemp,
            maxTempIsAbnormal: maxTempIsAbnormal,

            hr: n.hr,
            hrIsAbnormal: n.hrIsAbnormal,

            rr: n.rr,
            rrIsAbnormal: n.rrIsAbnormal,

            spo2: n.spo2,
            spo2IsAbnormal: n.spo2IsAbnormal,

            systolic: n.systolic,
            diastolic: n.diastolic,
            bpIsAbnormal: n.bpIsAbnormal,
            bpCategoryToken: n.bpCategoryToken
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




    // MARK: - Perinatal coded-choice translation (guideline-only)

    /// Split a CSV-ish string (commas/semicolons/newlines) into trimmed tokens.
    private func splitCSVish(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return [] }
        return s
            .split(whereSeparator: { ",;\n".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Best-effort translation from localized labels (current UI language) to stable codes.
    /// If the raw values already contain stable codes, they are accepted as-is.
    private func translateChoices(
        raw: String?,
        map: [(labelKey: String, code: String)],
        allowCodes: Set<String>
    ) -> [String] {
        let parts = splitCSVish(raw)
        guard !parts.isEmpty else { return [] }

        let localizedPairs: [(label: String, code: String)] = map.map {
            (label: String(localized: String.LocalizationValue($0.labelKey)), code: $0.code)
        }

        var out: [String] = []
        out.reserveCapacity(4)

        for p in parts {
            if allowCodes.contains(p) {
                if !out.contains(p) { out.append(p) }
                continue
            }
            if let hit = localizedPairs.first(where: { $0.label == p }) {
                if !out.contains(hit.code) { out.append(hit.code) }
            }
        }
        return out
    }

    /// Translate perinatal infection risk selections into stable codes.
    /// Codes: prom, torch_seroconversion, gbs_treatment, gbs_no_treatment
    private func infectionRiskCodes(from perinatalRaw: [String: String]?) -> [String] {
        let raw = perinatalRaw?["infectionRisk"]
        let map: [(labelKey: String, code: String)] = [
            ("perinatal.choice.infrisk.prom", "prom"),
            ("perinatal.choice.infrisk.seroconversion_torch", "torch_seroconversion"),
            ("perinatal.choice.infrisk.gbs_treatment", "gbs_treatment"),
            ("perinatal.choice.infrisk.gbs_no_treatment", "gbs_no_treatment")
        ]
        let allowCodes: Set<String> = ["prom", "torch_seroconversion", "gbs_treatment", "gbs_no_treatment"]
        return translateChoices(raw: raw, map: map, allowCodes: allowCodes)
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
                tempIsAbnormal: ctx.maxTempIsAbnormal,

                hr: nil,
                hrIsAbnormal: nil,

                rr: nil,
                rrIsAbnormal: nil,

                spo2: ctx.spo2,
                spo2IsAbnormal: ctx.spo2IsAbnormal,

                systolic: nil,
                diastolic: nil,
                bpIsAbnormal: nil,
                bpCategoryToken: nil
            )
        ]

        // Vaccination token (already structured enough for now).
        let vaccination: VaccinationSnapshot? = {
            guard let raw = ctx.vaccinationStatus?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return VaccinationSnapshot(statusToken: raw, vaccineTokens: [])
        }()

        // Perinatal: populate structured fields and provenance text if available.
        let perinatal: PerinatalSnapshot? = {
            let raw = ctx.perinatalSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasText = (raw != nil && !(raw ?? "").isEmpty)

            let ga = ctx.gestationalAgeWeeks
            let bw = ctx.birthWeightG
            let nicu = ctx.nicuStay

            // If nothing is provided (no text and no structured fields), omit perinatal.
            if !hasText && ga == nil && bw == nil && nicu == nil {
                return nil
            }

            return PerinatalSnapshot(
                gestationalAgeWeeks: ga,
                birthWeightG: bw,
                nicuStay: nicu,
                infectionRiskText: hasText ? raw : nil
            )
        }()

        // Problem lines:
        // - problemTokens: stable tokens from UI (preferred for matching)
        // - problemListing: human-readable provenance (kept for logs/AI context)
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

        func toProblemTokenLines(_ tokens: [String], source: String) -> [ProblemLine] {
            tokens
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map {
                    ProblemLine(
                        display: $0,
                        tokens: [$0],
                        isObjective: false,
                        isAbnormal: true,
                        source: source
                    )
                }
        }

        var problemLines: [ProblemLine] = []

        // Preferred: stable tokens emitted by the UI (guideline matching)
        if !ctx.problemTokens.isEmpty {
            problemLines.append(contentsOf: toProblemTokenLines(ctx.problemTokens, source: "episode.problem_tokens"))
        }

        // Provenance: human-readable listing (kept for AI/logs; may also be SNOMED-mapped later)
        problemLines.append(contentsOf: toProblemLines(ctx.problemListing, source: "episode.problem_listing"))

        let inv = ctx.complementaryInvestigations.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inv.isEmpty {
            problemLines.append(contentsOf: toProblemLines(inv, source: "episode.complementary_investigations"))
        }

        if let pmhRaw = ctx.pmhSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !pmhRaw.isEmpty {
            problemLines.append(contentsOf: toProblemLines(pmhRaw, source: "episode.pmh"))
        }

        let sexToken = patientSexToken?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Guideline-only: derive stable perinatal infection RF flags from raw coded-choice payload.
        let infCodes = infectionRiskCodes(from: ctx.perinatalRaw)

        var profile = buildProfile(
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

        // Perinatal infection risk factors (guideline-only; does not affect reports/UI).
        if !infCodes.isEmpty {
            profile.features.append(.flag(
                Key.perinatalInfectionRFPresent,
                true,
                source: "perinatal",
                note: "derived from perinatal infectionRisk selections",
                objective: true
            ))

            for c in infCodes {
                switch c {
                case "prom":
                    profile.features.append(.flag(Key.perinatalInfectionRFProm, true, source: "perinatal", note: "derived from perinatal infectionRisk selections", objective: true))
                case "torch_seroconversion":
                    profile.features.append(.flag(Key.perinatalInfectionRFTorch, true, source: "perinatal", note: "derived from perinatal infectionRisk selections", objective: true))
                case "gbs_treatment":
                    profile.features.append(.flag(Key.perinatalInfectionRFGbsTreatment, true, source: "perinatal", note: "derived from perinatal infectionRisk selections", objective: true))
                case "gbs_no_treatment":
                    profile.features.append(.flag(Key.perinatalInfectionRFGbsNoTreatment, true, source: "perinatal", note: "derived from perinatal infectionRisk selections", objective: true))
                default:
                    break
                }
            }

            // Recompute partitions to include the newly appended perinatal flags.
            profile.objectivePositiveFindings = profile.features.filter { $0.isObjectivePositive }
            profile.abnormalFindings = profile.features.filter { $0.isAbnormal }
        }

        // Fever duration (structured)
        if let d = ctx.feverDurationDays, d >= 0 {
            profile.features.append(.init(
                key: Key.feverDurationDays,
                value: .int(d),
                snomedConceptId: nil,
                note: "from episode UI",
                isObjectivePositive: true,
                isAbnormal: false,
                source: "episode"
            ))

            // Canonical numeric unit for thresholds in rules.
            let h = d * 24
            profile.features.append(.init(
                key: Key.feverDurationHours,
                value: .int(h),
                snomedConceptId: nil,
                note: "derived from duration_days * 24",
                isObjectivePositive: true,
                isAbnormal: false,
                source: "derived"
            ))
            
            #if DEBUG
            if let d = ctx.feverDurationDays {
                print("[Extractor] feverDurationDays=\(d) -> durationHours=\(d * 24)")
            }
            #endif

            // Recompute partitions to include the new features.
            profile.objectivePositiveFindings = profile.features.filter { $0.isObjectivePositive }
            profile.abnormalFindings = profile.features.filter { $0.isAbnormal }
        }

        return profile
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
        print("[Extractor] Incoming ctx: patientID=\(ctx.patientID) ageDays=\(String(describing: ctx.patientAgeDays)) sex=\(String(describing: ctx.patientSex)) maxTempC=\(String(describing: ctx.maxTempC)) spo2=\(String(describing: ctx.spo2)) spo2Abn=\(String(describing: ctx.spo2IsAbnormal))")
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
