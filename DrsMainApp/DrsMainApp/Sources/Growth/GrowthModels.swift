//
//  GrowthModels.swift
//  DrsMainApp
//
//  Created by yunastic on 11/5/25.
//
import Foundation

// Namespace to avoid collisions with your existing Growth types
enum ReportGrowth {

    enum Kind: String { case wfa = "wfa", lhfa = "lhfa", hcfa = "hcfa" }
    enum Sex: String { case male = "M", female = "F" }

    enum Percentile: String, CaseIterable {
        case p3 = "p3", p15 = "p15", p50 = "p50", p85 = "p85", p97 = "p97"
    }

    struct Curves {
        let agesMonths: [Double]   // x: months (0–24)
        let p3:  [Double]
        let p15: [Double]
        let p50: [Double]
        let p85: [Double]
        let p97: [Double]

        func values(for p: Percentile) -> [Double] {
            switch p {
            case .p3:  return p3
            case .p15: return p15
            case .p50: return p50
            case .p85: return p85
            case .p97: return p97
            }
        }

        /// Linear interpolation of a percentile at age (months)
        func value(percentile: Percentile, at ageM: Double) -> Double? {
            let xs = agesMonths
            let ys = values(for: percentile)
            guard xs.count == ys.count, xs.count >= 2 else { return nil }
            if let first = xs.first, ageM <= first { return ys.first }
            if let last  = xs.last,  ageM >= last  { return ys.last }

            // Find right interval
            var lo = 0
            var hi = xs.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if xs[mid] <= ageM { lo = mid } else { hi = mid }
            }
            let x0 = xs[lo], x1 = xs[hi]
            let y0 = ys[lo], y1 = ys[hi]
            if x1 == x0 { return y0 }
            let t = (ageM - x0) / (x1 - x0)
            return y0 + t * (y1 - y0)
        }

        /// Y-range spanning selected percentiles; you can include patient points later.
        func yRange(percentiles: [Percentile] = [.p3, .p97]) -> (min: Double, max: Double)? {
            let arrays = percentiles.map { values(for: $0) }
            let flat = arrays.flatMap { $0 }
            guard let minV = flat.min(), let maxV = flat.max(), minV.isFinite, maxV.isFinite else { return nil }
            return (minV, maxV)
        }
    }

    struct Point {
        /// Age in months (e.g., days / 30.4375)
        let ageMonths: Double
        /// Value (kg for WFA, cm for L/HFA and HCFA)
        let value: Double
    }
}
