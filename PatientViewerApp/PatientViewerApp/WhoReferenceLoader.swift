import Foundation
import SwiftUI

struct WhoReferenceLoader {
    static func loadCurve(fromCSV csvName: String, sex: String) -> [(label: String, points: [GrowthDataPoint])] {
        guard let url = Bundle.main.url(forResource: csvName, withExtension: "csv") else {
            print("❌ Could not find file \(csvName).csv")
            return []
        }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let rows = content.components(separatedBy: .newlines).filter { !$0.isEmpty }

            guard let header = rows.first?.components(separatedBy: ",") else {
                print("❌ No header found in \(csvName)")
                return []
            }

            let percentileLabels = header.dropFirst()  // First column is age
            var curves: [String: [GrowthDataPoint]] = [:]

            for row in rows.dropFirst() {
                let columns = row.components(separatedBy: ",")
                guard let age = Double(columns[0]) else { continue }

                for (i, pLabel) in percentileLabels.enumerated() {
                    let label = pLabel.trimmingCharacters(in: .whitespaces)
                    let val = Double(columns[i + 1]) ?? 0.0
                    curves[label, default: []].append(GrowthDataPoint(ageMonths: age, value: val))
                }
            }

            return curves.map { (label: $0.key, points: $0.value) }
                .sorted { $0.label < $1.label }

        } catch {
            print("❌ Failed to read \(csvName): \(error)")
            return []
        }
    }
}//  WhoReferenceLoader.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/12/25.
//

