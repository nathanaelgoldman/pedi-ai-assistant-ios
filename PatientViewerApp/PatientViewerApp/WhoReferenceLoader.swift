//
//  WhoReferenceLoader.swift
//  PatientViewerApp
//

import Foundation
import OSLog

struct WhoReferenceLoader {
    private static let log = AppLog.feature("WhoReferenceLoader")

    // Cache key must include sex to avoid returning the wrong curves when callers pass a generic name
    // (e.g., "wfa_0_24m") with different `sex` values across calls.
    private static var cache: [String: [(label: String, points: [GrowthDataPoint])]] = [:]

    /// Load WHO/CDC curves from a CSV in the bundle.
    /// - Parameters:
    ///   - csvName: Resource name without ".csv" (e.g. "wfa_0_24m_M")
    ///   - sex: "M" or "F" (not strictly required if csvName already encodes sex). Kept for signature compatibility.
    /// - Returns: Curves as (label, points). We *aim* for 5 standard curves when possible.
    static func loadCurve(fromCSV csvName: String, sex: String) -> [(label: String, points: [GrowthDataPoint])] {
        let sexNorm = sex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let cacheKey = "\(csvName)|\(sexNorm)"

        // Cache hit (keyed by name + sex)
        if let cached = cache[cacheKey] {
            log.debug("Cache hit for \(cacheKey, privacy: .private)")
            return cached
        }

        // Find the CSV (try a few likely subdirectories too)
        guard let url = findCSV(named: csvName) ?? findCSV(named: "\(csvName)_\(sexNorm)") else {
            log.error("Could not find CSV resource for \(csvName, privacy: .public)")
            return []
        }

        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            var rows = raw
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }

            guard !rows.isEmpty else {
                log.error("CSV at \(url.lastPathComponent, privacy: .public) is empty")
                return []
            }

            let delimiter: Character = detectDelimiter(in: rows[0])
            let header = splitCSVRow(rows[0], by: delimiter).map { $0.trimmingCharacters(in: .whitespaces) }
            guard header.count >= 2 else {
                log.error("Header too short in \(url.lastPathComponent, privacy: .public)")
                return []
            }

            let lower = header.map { $0.lowercased() }
            let ageIdx: Int = {
                if let idx = lower.firstIndex(where: { $0.contains("age") || $0.contains("agemos") || $0.contains("month") }) {
                    return idx
                }
                return 0 // fallback: first column
            }()

            // Identify SD or percentile columns available
            let sdMap = detectSDColumns(in: header)       // canonical label -> index
            let pMap  = detectPercentileColumns(in: header)

            // Desired column order (prefer SD set; else percentile set)
            let desired: [(label: String, idx: Int)] = {
                if !sdMap.isEmpty {
                    let order = ["-2 SD", "-1 SD", "50th", "+1 SD", "+2 SD"]
                    let pick = order.compactMap { lab -> (String, Int)? in
                        guard let i = sdMap[lab] else { return nil }
                        return (lab, i)
                    }
                    if !pick.isEmpty { return pick }
                }
                let orderP = ["P3", "P15", "P50", "P85", "P97"]
                let pickP = orderP.compactMap { lab -> (String, Int)? in
                    guard let i = pMap[lab] else { return nil }
                    return (lab, i)
                }
                return pickP
            }()

            if desired.isEmpty {
                log.error("No recognizable SD or percentile columns in \(url.lastPathComponent, privacy: .public). Header: \(header.joined(separator: ","), privacy: .public)")
                return []
            }

            var accum: [String: [GrowthDataPoint]] = Dictionary(uniqueKeysWithValues: desired.map { ($0.label, []) })

            // Parse rows
            rows.removeFirst()
            for row in rows {
                let cols = splitCSVRow(row, by: delimiter)
                guard ageIdx < cols.count, let age = parseNumber(cols[ageIdx]) else { continue }

                for (label, idx) in desired {
                    guard idx < cols.count, let v = parseNumber(cols[idx]), v.isFinite else { continue }
                    accum[label, default: []].append(GrowthDataPoint(ageMonths: age, value: v))
                }
            }

            // Sort by age & build final array
            var curves: [(label: String, points: [GrowthDataPoint])] = []
            for (label, pts) in accum {
                let sorted = pts.sorted { $0.ageMonths < $1.ageMonths }
                if !sorted.isEmpty {
                    curves.append((label: label, points: sorted))
                } else {
                    log.warning("No points parsed for \(label, privacy: .public) in \(url.lastPathComponent, privacy: .public)")
                }
            }

            // Stable preferred order
            let order = ["-2 SD", "-1 SD", "50th", "+1 SD", "+2 SD", "P3", "P15", "P50", "P85", "P97"]
            curves.sort { lhs, rhs in
                let li = order.firstIndex(of: lhs.label) ?? Int.max
                let ri = order.firstIndex(of: rhs.label) ?? Int.max
                return li < ri || (li == ri && lhs.label < rhs.label)
            }

            cache[cacheKey] = curves
            log.debug("Parsed \(curves.count, privacy: .public) curve(s) from \(url.lastPathComponent, privacy: .public)")
            return curves
        } catch {
            log.error("Failed reading \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    // MARK: - Helpers

    private static func findCSV(named name: String) -> URL? {
        let subdirs = ["", "who", "WHO", "who_growth", "Growth"]
        for dir in subdirs {
            if dir.isEmpty {
                if let u = Bundle.main.url(forResource: name, withExtension: "csv") {
                    return u
                }
            } else if let u = Bundle.main.url(forResource: name, withExtension: "csv", subdirectory: dir) {
                return u
            }
        }
        return nil
    }

    private static func detectDelimiter(in header: String) -> Character {
        if header.contains(";") && !header.contains(",") { return ";" }
        return ","
    }

    /// CSV splitter that respects double-quoted fields.
    private static func splitCSVRow(_ row: String, by delimiter: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var insideQuotes = false

        for ch in row {
            if ch == "\"" {
                insideQuotes.toggle()
                continue
            }
            if ch == delimiter && !insideQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Parse number supporting "12.3", "12,3", and strings with units. Avoids deprecated Scanner APIs.
    private static func parseNumber(_ raw: String) -> Double? {
        // Keep only digits, sign, comma, dot
        let allowed = Set("0123456789-+.,")
        let filtered = raw.unicodeScalars.filter { allowed.contains(Character($0)) }
        var s = String(String.UnicodeScalarView(filtered))

        // If both '.' and ',' exist, treat the last one as decimal separator.
        if s.contains(",") && s.contains(".") {
            if let lastSep = s.lastIndex(where: { $0 == "," || $0 == "." }) {
                // Keep a copy with separators to compute how many digits follow the last separator
                let original = s
                let digitsAfter = original[original.index(after: lastSep)..<original.endIndex].filter { $0.isNumber }.count
                // Remove all separators, then reinsert a '.' before the last `digitsAfter` digits.
                s.removeAll(where: { $0 == "," || $0 == "." })
                if digitsAfter > 0 && digitsAfter < s.count {
                    let idx = s.index(s.endIndex, offsetBy: -digitsAfter)
                    s.insert(".", at: idx)
                }
            }
        } else if s.contains(",") && !s.contains(".") {
            s = s.replacingOccurrences(of: ",", with: ".")
        }
        return Double(s)
    }

    /// Map SD headers to canonical labels.
    private static func detectSDColumns(in header: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (i, h) in header.enumerated() {
            let t = h.replacingOccurrences(of: " ", with: "").lowercased()
            func set(_ label: String) { map[label] = i }

            if t.contains("sd") || t.contains("z") {
                if t.contains("-2") { set("-2 SD") }
                if t.contains("-1") { set("-1 SD") }
                if t.contains("+1") || t.contains("1+") { set("+1 SD") }
                if t.contains("+2") || t.contains("2+") { set("+2 SD") }
                if t == "sd0" || t == "0sd" || t == "sd_0" || t.contains("z=0") { set("50th") }
            }
            if t.contains("median") { set("50th") }
        }
        return map
    }

    /// Map percentile headers (P3/P15/P50/P85/P97, 3rd, etc.) to canonical labels.
    private static func detectPercentileColumns(in header: [String]) -> [String: Int] {
        var map: [String: Int] = [:]
        for (i, h) in header.enumerated() {
            let t = h.replacingOccurrences(of: " ", with: "").lowercased()

            func hit(_ keys: [String], label: String) {
                if keys.contains(where: { t.contains($0) }) {
                    map[label] = i
                }
            }

            hit(["p3", "3rd", "p03", "03rd"], label: "P3")
            hit(["p15", "15th"], label: "P15")
            hit(["p50", "50th", "median"], label: "P50")
            hit(["p85", "85th"], label: "P85")
            hit(["p97", "97th", "p97.7", "p977"], label: "P97")
        }
        return map
    }
}

