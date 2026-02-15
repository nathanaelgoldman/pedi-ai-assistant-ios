
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
        problemLines: [ProblemLine]
    ) -> PatientClinicalProfile {

        var notes: [String] = []
        var features: [ClinicalFeature] = []

        // Age
        let age = Self.computeAge(dob: dob, on: encounterDate)
        if let sexToken {
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
                snomedConceptId: 386661006, // Fever (can be revised if you prefer a different concept)
                note: "derived from vital.temp_c.max >= 38.0",
                isObjectivePositive: true,
                isAbnormal: maxTemp >= 38.0,
                source: "derived"
            ))
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

        // Problem lines (already curated by your form logic; we treat tokens as stable contract)
        // We DO NOT parse the display string here.
        for line in problemLines {
            // Emit one feature per token for matching, plus keep the display as provenance.
            if line.tokens.isEmpty {
                // Still keep the display line as a note so nothing is lost.
                notes.append("ProblemLine(\(line.source)): \(line.display)")
                continue
            }
            for tok in line.tokens {
                features.append(.init(
                    key: tok,
                    value: .bool(true),
                    snomedConceptId: nil,
                    note: line.display,
                    isObjectivePositive: line.isObjective,
                    isAbnormal: line.isAbnormal,
                    source: line.source
                ))
            }
        }

        // Partitions
        let objective = features.filter { $0.isObjectivePositive }
        let abnormal = features.filter { $0.isAbnormal }

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

