import SwiftUI

// MARK: - Localization (file-local)
@inline(__always)
private func L(_ key: String, comment: String = "") -> String {
    NSLocalizedString(key, comment: comment)
}

@inline(__always)
private func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

// MARK: - Support Log (file-local)
@inline(__always)
private func SL(_ message: String) {
    Task { await SupportLog.shared.info(message) }
}

struct GrowthChartScreen: View {
    private let log = AppLog.feature("GrowthChartScreen")
    let patientSex: String
    let allPatientData: [String: [GrowthDataPoint]]

    @State private var selectedMeasurement = "weight"

    var body: some View {
        VStack {
            Picker(L("patient_viewer.growth_chart.picker.measurement", comment: "Picker label"), selection: $selectedMeasurement) {
                Text(L("patient_viewer.growth_chart.measurement.weight", comment: "Segment title")).tag("weight")
                Text(L("patient_viewer.growth_chart.measurement.height", comment: "Segment title")).tag("height")
                Text(L("patient_viewer.growth_chart.measurement.head_circ", comment: "Segment title")).tag("head_circ")
                Text(L("patient_viewer.growth_chart.measurement.bmi", comment: "Segment title")).tag("bmi")
            }
            .pickerStyle(.segmented)
            // Keep the segmented control on a themed card, but do NOT tint the chart itself.
            .padding(8)
            .background(AppTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 0.8)
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .onChange(of: selectedMeasurement) { _, newValue in
                let file = "\(filePrefix(for: newValue))_0_24m_\(patientSex)"
                log.debug("WHO file selected for \(newValue, privacy: .public): \(file, privacy: .public)")
                SL("GC measurement change | sex=\(self.patientSex) m=\(newValue)")
            }

            let patientData: [GrowthDataPoint] = {
                if selectedMeasurement == "bmi" {
                    let w = allPatientData["weight"] ?? []
                    let h = allPatientData["height"] ?? []
                    return computeBMIData(weight: w, height: h)
                }
                return allPatientData[selectedMeasurement] ?? []
            }()

            let whoFilePrefix = filePrefix(for: selectedMeasurement)
            let whoFileName = "\(whoFilePrefix)_0_24m_\(patientSex)"
            let referenceCurves = WhoReferenceLoader.loadCurve(fromCSV: whoFileName, sex: patientSex)

            if patientData.isEmpty {
                // Avoid drawing an empty chart which can cause NaN in CoreGraphics on iOS.
                VStack(spacing: 12) {
                    if selectedMeasurement == "bmi" {
                        Text(L("patient_viewer.growth_chart.empty_bmi.title", comment: "Empty BMI title"))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(L("patient_viewer.growth_chart.empty_bmi.message", comment: "Empty BMI message"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text(L("patient_viewer.growth_chart.empty.title", comment: "Empty state title"))
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(LF("patient_viewer.growth_chart.empty.message", measurementDisplayName(for: selectedMeasurement)))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { log.warning("patientData is empty for \(self.selectedMeasurement, privacy: .public)") }
            } else if referenceCurves.isEmpty {
                // Also avoid rendering if reference curves failed to load.
                VStack(spacing: 12) {
                    Text(L("patient_viewer.growth_chart.reference_unavailable.title", comment: "Reference missing title"))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(LF("patient_viewer.growth_chart.reference_unavailable.message", whoFileName))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { log.error("reference curves empty for \(whoFileName, privacy: .public)") }
            } else {
                // Add left padding so the x=0 month tick/label isn't clipped.
                // If the chart is scrollable, a larger pad is often needed to be noticeable.
                let xPadMonths: Double = 1.0   // ~1 month; tweak if needed

                let patientMinX = patientData.map { $0.ageMonths }.min() ?? 0
                let patientMaxX = patientData.map { $0.ageMonths }.max() ?? 0

                let refMinX = referenceCurves
                    .flatMap { $0.points }
                    .map { $0.ageMonths }
                    .min() ?? 0

                let refMaxX = referenceCurves
                    .flatMap { $0.points }
                    .map { $0.ageMonths }
                    .max() ?? 0

                // WHO curves start at 0; we allow a negative domain to create visual padding.
                // Force the lower bound to be at most `-xPadMonths` so padding always exists.
                let minX = min(patientMinX, refMinX, 0)
                let maxX = max(patientMaxX, refMaxX)
                let domainLower = min(minX - xPadMonths, -xPadMonths)
                let domainUpper = maxX

                // --- Y domain padding (prevents the top of the chart from being clipped) ---
                let patientVals = patientData.map { $0.value }.filter { $0.isFinite }
                let refVals = referenceCurves.flatMap { $0.points }.map { $0.value }.filter { $0.isFinite }
                let allVals = patientVals + refVals

                // If for some reason values are missing, fall back to automatic scaling.
                if let vMin = allVals.min(), let vMax = allVals.max(), vMin.isFinite, vMax.isFinite {
                    let span = max(0.0001, vMax - vMin)

                    // Padding: give a bit more vertical headroom so curves/points never clip at the top.
                    // (We prefer a slightly "roomy" chart over risking truncation.)
                    let relPad = span * 0.12
                    let absPad: Double = {
                        switch selectedMeasurement {
                        case "weight": return 0.5      // kg
                        case "height": return 3.0      // cm (needs more headroom on 0–60m curves)
                        case "head_circ": return 1.0   // cm
                        case "bmi": return 1.0         // kg/m²
                        default: return 1.0
                        }
                    }()
                    let pad = max(relPad, absPad)

                    // Keep lower bound sensible (avoid negative weights/lengths/head circumference/BMI).
                    let yLower: Double = {
                        let raw = vMin - pad
                        switch selectedMeasurement {
                        case "weight", "height", "head_circ", "bmi":
                            return max(0.0, raw)
                        default:
                            return raw
                        }
                    }()

                    // Add a touch more headroom than bottom padding.
                    let baseUpper = vMax + (pad * 1.25)

                    // For length/height, ensure the chart can accommodate tall 5‑year‑olds comfortably.
                    // This prevents top curves from being clipped when the WHO reference extends higher.
                    let yUpper = (selectedMeasurement == "height")
                        ? max(baseUpper, 130.0)
                        : baseUpper

                    GrowthChartView(
                        dataPoints: patientData,
                        referenceCurves: referenceCurves,
                        measurement: selectedMeasurement
                    )
                    .chartXScale(domain: domainLower...domainUpper)
                    .chartYScale(domain: yLower...yUpper)
                    .padding(.leading, 18)
                    .onAppear {
                        log.info("Chart appear: measurement=\(self.selectedMeasurement, privacy: .public) points=\(patientData.count) curves=\(referenceCurves.count)")
                    }
                } else {
                    // Fallback: let Charts pick the Y-domain automatically.
                    GrowthChartView(
                        dataPoints: patientData,
                        referenceCurves: referenceCurves,
                        measurement: selectedMeasurement
                    )
                    .chartXScale(domain: domainLower...domainUpper)
                    .padding(.leading, 18)
                    .onAppear {
                        log.info("Chart appear: measurement=\(self.selectedMeasurement, privacy: .public) points=\(patientData.count) curves=\(referenceCurves.count)")
                    }
                }
            }
        }
        .appBackground()
        .appNavBarBackground()
        .onAppear {
            log.info("GrowthChartScreen appeared for sex=\(self.patientSex, privacy: .public) initialMeasurement=\(self.selectedMeasurement, privacy: .public)")
            SL("UI open growth charts | sex=\(self.patientSex) m=\(self.selectedMeasurement)")
        }
        .onDisappear {
            SL("UI close growth charts | sex=\(self.patientSex) m=\(self.selectedMeasurement)")
        }
        .navigationTitle(L("patient_viewer.growth_chart.title", comment: "Screen title"))
    }

    private func measurementDisplayName(for measurement: String) -> String {
        switch measurement {
        case "weight": return L("patient_viewer.growth_chart.measurement.weight", comment: "Measurement name")
        case "height": return L("patient_viewer.growth_chart.measurement.height", comment: "Measurement name")
        case "head_circ": return L("patient_viewer.growth_chart.measurement.head_circ", comment: "Measurement name")
        case "bmi": return L("patient_viewer.growth_chart.measurement.bmi", comment: "Measurement name")
        default: return L("patient_viewer.growth_chart.measurement.weight", comment: "Measurement name")
        }
    }

    private func computeBMIData(weight: [GrowthDataPoint], height: [GrowthDataPoint]) -> [GrowthDataPoint] {
        let w = weight
            .filter { $0.ageMonths.isFinite && $0.value.isFinite && $0.value > 0 }
            .sorted { $0.ageMonths < $1.ageMonths }
        let h = height
            .filter { $0.ageMonths.isFinite && $0.value.isFinite && $0.value > 0 }
            .sorted { $0.ageMonths < $1.ageMonths }

        guard !w.isEmpty, !h.isEmpty else { return [] }

        // Match weight points to the nearest height point by age (months).
        let ageTol: Double = 0.10   // ~3 days
        var out: [GrowthDataPoint] = []
        var j = 0

        for wp in w {
            while j + 1 < h.count && h[j].ageMonths < wp.ageMonths - ageTol {
                j += 1
            }

            var candidates: [GrowthDataPoint] = []
            if j < h.count { candidates.append(h[j]) }
            if j + 1 < h.count { candidates.append(h[j + 1]) }

            guard let best = candidates.min(by: { abs($0.ageMonths - wp.ageMonths) < abs($1.ageMonths - wp.ageMonths) }) else {
                continue
            }

            guard abs(best.ageMonths - wp.ageMonths) <= ageTol else {
                continue
            }

            let cm = best.value
            let m = cm / 100.0
            guard m.isFinite, m > 0 else { continue }

            let bmi = wp.value / (m * m)
            guard bmi.isFinite, bmi > 0 else { continue }

            out.append(GrowthDataPoint(ageMonths: wp.ageMonths, value: bmi))
        }

        // Sort + de-duplicate near-identical ages.
        out.sort { $0.ageMonths < $1.ageMonths }
        var dedup: [GrowthDataPoint] = []
        for p in out {
            if let last = dedup.last, abs(last.ageMonths - p.ageMonths) < 0.02 {
                dedup[dedup.count - 1] = p
            } else {
                dedup.append(p)
            }
        }
        return dedup
    }

    func filePrefix(for measurement: String) -> String {
        switch measurement {
        case "weight": return "wfa"
        case "height": return "lhfa"
        case "head_circ": return "hcfa" // head circumference-for-age
        case "bmi": return "bmi" // BMI-for-age
        default: return "wfa"
        }
    }
}
