//
//  GrowthWHO.swift
//  DrsMainApp
//
//  Created by yunastic on 11/5/25.
//
import Foundation

enum GrowthWHOError: Error {
    case resourceNotFound(String)
    case csvParseFailed(String)
}

final class GrowthWHO {

    /// Loads WHO curves (0–24m) from app bundle Resources/WHO
    /// Columns expected: age_months,p3,p15,p50,p85,p97
    static func loadCurves(kind: ReportGrowth.Kind,
                           sex: ReportGrowth.Sex,
                           bundle: Bundle = .main) throws -> ReportGrowth.Curves {

        let file = "\(kind.rawValue)_0_24m_\(sex == .male ? "M" : "F")"
        guard let url = bundle.url(forResource: file, withExtension: "csv", subdirectory: "WHO") else {
            throw GrowthWHOError.resourceNotFound("WHO/\(file).csv")
        }

        let raw = try String(contentsOf: url, encoding: .utf8)
        var ages: [Double] = []
        var p3:  [Double] = []
        var p15: [Double] = []
        var p50: [Double] = []
        var p85: [Double] = []
        var p97: [Double] = []

        let lines = raw.split(whereSeparator: \.isNewline)
        guard let header = lines.first?.lowercased(),
              header.contains("age_months"),
              header.contains("p3"),
              header.contains("p15"),
              header.contains("p50"),
              header.contains("p85"),
              header.contains("p97")
        else {
            throw GrowthWHOError.csvParseFailed("Bad header in \(file).csv")
        }

        for line in lines.dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard cols.count >= 6,
                  let ageM = Double(cols[0]),
                  let v3   = Double(cols[1]),
                  let v15  = Double(cols[2]),
                  let v50  = Double(cols[3]),
                  let v85  = Double(cols[4]),
                  let v97  = Double(cols[5])
            else { continue }

            ages.append(ageM)
            p3.append(v3); p15.append(v15); p50.append(v50); p85.append(v85); p97.append(v97)
        }

        guard ages.count > 1 else {
            throw GrowthWHOError.csvParseFailed("No data rows in \(file).csv")
        }

        return ReportGrowth.Curves(agesMonths: ages, p3: p3, p15: p15, p50: p50, p85: p85, p97: p97)
    }
}
