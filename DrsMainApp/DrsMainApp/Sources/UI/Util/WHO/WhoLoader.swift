//
//  WhoLoader.swift
//  DrsMainApp
//
//  Created by yunastic on 11/2/25.
//

import Foundation

enum WhoMeasure { case weightForAge, lengthForAge, headCircForAge }
enum WhoSex: String { case M, F }

struct WhoPoint {
    let ageMonths: Double
    let p3: Double
    let p15: Double
    let p50: Double
    let p85: Double
    let p97: Double
}

enum WhoLoader {
    /// Loads WHO curves (0–24m) for the given measure+sex from app bundle.
    /// Supports either percentile CSV columns or LMS CSV columns.
    static func load(
        measure: WhoMeasure,
        sex: WhoSex,
        limitMonths: Int = 24
    ) -> [WhoPoint] {
        guard let url = bundleURL(measure: measure, sex: sex) else { return [] }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { return [] }

        let header = lines.first!.lowercased()
        let rows = lines.dropFirst()

        if header.contains("p50") || header.contains(",p3,") {
            // Percentile columns present
            return rows.compactMap { line -> WhoPoint? in
                let cols = line.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                guard cols.count >= 6,
                      let m = Double(cols[0]), m >= 0, m <= Double(limitMonths),
                      let p3  = Double(cols[1]),
                      let p15 = Double(cols[2]),
                      let p50 = Double(cols[3]),
                      let p85 = Double(cols[4]),
                      let p97 = Double(cols[5]) else { return nil }
                return WhoPoint(ageMonths: m, p3: p3, p15: p15, p50: p50, p85: p85, p97: p97)
            }
        } else if header.contains("l,") || header.contains(",m,") {
            // LMS columns -> derive percentiles
            func qz(L: Double, M: Double, S: Double, z: Double) -> Double {
                // Box-Cox LMS back-transform
                if L == 0 { return M * exp(S * z) }
                return M * pow(1 + L * S * z, 1 / L)
            }
            // z-scores corresponding to target percentiles
            let z3  = -1.8807936081512509   // Φ^-1(0.03)
            let z15 = -1.0364333894937896   // Φ^-1(0.15)
            let z50 =  0.0
            let z85 =  1.0364333894937896
            let z97 =  1.8807936081512509

            return rows.compactMap { line -> WhoPoint? in
                let cols = line.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                guard cols.count >= 4,
                      let m = Double(cols[0]), m >= 0, m <= Double(limitMonths),
                      let L = Double(cols[1]),
                      let M = Double(cols[2]),
                      let S = Double(cols[3]) else { return nil }
                return WhoPoint(
                    ageMonths: m,
                    p3:  qz(L: L, M: M, S: S, z: z3),
                    p15: qz(L: L, M: M, S: S, z: z15),
                    p50: qz(L: L, M: M, S: S, z: z50),
                    p85: qz(L: L, M: M, S: S, z: z85),
                    p97: qz(L: L, M: M, S: S, z: z97)
                )
            }
        } else {
            return []
        }
    }

    private static func bundleURL(measure: WhoMeasure, sex: WhoSex) -> URL? {
        let baseNames: [String]
        switch measure {
        case .weightForAge:
            baseNames = ["wfa_0_24m_\(sex.rawValue)"]
        case .lengthForAge:
            // Prefer lhfa (length/height-for-age) but fall back to lfa if present
            baseNames = ["lhfa_0_24m_\(sex.rawValue)", "lfa_0_24m_\(sex.rawValue)"]
        case .headCircForAge:
            baseNames = ["hcfa_0_24m_\(sex.rawValue)"]
        }

        for name in baseNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "csv", subdirectory: "WHO") {
                return url
            }
            if let url = Bundle.main.url(forResource: name, withExtension: "csv") { // fallback if not in subdir
                return url
            }
        }
        return nil
    }
}
