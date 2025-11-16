//
//  VitalsRanges.swift
//  DrsMainApp
//
//  Created by yunastic on 11/15/25.
//

import Foundation

/// Age-banded ranges and simple classifiers for HR/RR/Temp/SpO₂.
/// Keep this file tiny and dependency-free so it can be reused anywhere.

public enum VitalsAgeBand: CaseIterable {
    case neonate     // < 28 days
    case infant      // < 1 year
    case toddler     // < 3 years
    case preschool   // < 6 years
    case schoolAge   // < 12 years
    case adolescent  // < 16 years
    case adultLike   // ≥ 16 years

    public var label: String {
        switch self {
        case .neonate:    return "neonate"
        case .infant:     return "infant"
        case .toddler:    return "toddler"
        case .preschool:  return "preschool"
        case .schoolAge:  return "school age"
        case .adolescent: return "adolescent"
        case .adultLike:  return "adult-like"
        }
    }
}

public struct VRRange {
    public let low: Double?
    public let high: Double?

    public init(_ low: Double?, _ high: Double?) {
        self.low = low; self.high = high
    }

    /// Return "low", "high", or "normal" for a given numeric value.
    public func classify(_ value: Double?) -> String {
        guard let v = value else { return "unknown" }
        if let lo = low, v < lo { return "low" }
        if let hi = high, v > hi { return "high" }
        return "normal"
    }
}

public struct VitalsBandRanges {
    public let hr: VRRange
    public let rr: VRRange
}

public enum VitalsRanges {
    /// Ranges adapted from the Python app mapping.
    public static let table: [VitalsAgeBand: VitalsBandRanges] = [
        .neonate:    .init(hr: .init(100, 205), rr: .init(30, 53)),
        .infant:     .init(hr: .init(100, 190), rr: .init(30, 53)),
        .toddler:    .init(hr: .init(98, 140),  rr: .init(22, 37)),
        .preschool:  .init(hr: .init(80, 120),  rr: .init(20, 28)),
        .schoolAge:  .init(hr: .init(75, 118),  rr: .init(18, 25)),
        .adolescent: .init(hr: .init(60, 100),  rr: .init(12, 20)),
        .adultLike:  .init(hr: .init(60, 100),  rr: .init(12, 20))
    ]

    // MARK: - Age helpers

    /// Compute age in years (decimal) from ISO DOB string (YYYY-MM-DD).
    public static func ageYears(fromDOB dobISO: String) -> Double? {
        let fmt = DateFormatter(); fmt.calendar = .init(identifier: .gregorian)
        fmt.dateFormat = "yyyy-MM-dd"; fmt.locale = .init(identifier: "en_US_POSIX")
        guard let dob = fmt.date(from: dobISO) else { return nil }
        let days = Date().timeIntervalSince(dob) / 86_400.0
        return max(0.0, days / 365.25)
    }

    /// Map a decimal age (years) to an age band.
    public static func band(forAgeYears age: Double) -> VitalsAgeBand {
        if age < (28.0/365.25) { return .neonate }
        if age < 1.0 { return .infant }
        if age < 3.0 { return .toddler }
        if age < 6.0 { return .preschool }
        if age < 12.0 { return .schoolAge }
        if age < 16.0 { return .adolescent }
        return .adultLike
    }

    // MARK: - Classifiers

    /// "low" / "normal" / "high" / "unknown"
    public static func classifyHR(_ value: Int?, ageYears: Double) -> String {
        guard let v = value, v > 0 else { return "unknown" }
        let band = band(forAgeYears: ageYears)
        return table[band]?.hr.classify(Double(v)) ?? "unknown"
    }

    /// "low" / "normal" / "high" / "unknown"
    public static func classifyRR(_ value: Int?, ageYears: Double) -> String {
        guard let v = value, v > 0 else { return "unknown" }
        let band = band(forAgeYears: ageYears)
        return table[band]?.rr.classify(Double(v)) ?? "unknown"
    }

    /// "hypothermia" / "normal" / "fever" / "unknown"
    public static func classifyTempC(_ value: Double?) -> String {
        guard let t = value, t > 0 else { return "unknown" }
        if t >= 38.0 { return "fever" }
        if t < 35.5 { return "hypothermia" }
        return "normal"
    }

    /// "low" / "normal" / "unknown"
    public static func classifySpO2(_ value: Int?) -> String {
        guard let s = value, s > 0 else { return "unknown" }
        return (s < 95) ? "low" : "normal"
    }

    /// Convenience: build human‑readable flags like the Python helper.
    public static func flags(ageYears: Double,
                             hr: Int?, rr: Int?, tempC: Double?, spo2: Int?) -> [String] {
        var out: [String] = []
        let bandName = band(forAgeYears: ageYears).label

        switch classifyHR(hr, ageYears: ageYears) {
        case "low", "high": out.append("Heart rate \(hr ?? 0) bpm (\(classifyHR(hr, ageYears: ageYears))) for \(bandName).")
        default: break
        }
        switch classifyRR(rr, ageYears: ageYears) {
            case "low", "high": out.append("Respiratory rate \(rr ?? 0)/min (\(classifyRR(rr, ageYears: ageYears))) for \(bandName).")
            default: break
        }
        switch classifyTempC(tempC) {
            case "fever": out.append(String(format: "Fever: %.1f °C (≥ 38.0).", tempC ?? 0))
            case "hypothermia": out.append(String(format: "Hypothermia: %.1f °C (< 35.5).", tempC ?? 0))
            default: break
        }
        if classifySpO2(spo2) == "low" { out.append("Low SpO₂: \(spo2 ?? 0)% (< 95%).") }
        return out
    }
}
