import SwiftUI
import os

struct GrowthChartScreen: View {
    let patientSex: String
    let allPatientData: [String: [GrowthDataPoint]]

    @State private var selectedMeasurement = "weight"
    private let measurementOptions = ["weight", "height", "head_circ", "bmi"]
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PatientViewerApp", category: "GrowthChartScreen")

    var body: some View {
        VStack {
            Picker("Measurement", selection: $selectedMeasurement) {
                Text("Weight").tag("weight")
                Text("Height").tag("height")
                Text("Head Circ.").tag("head_circ")
                Text("BMI").tag("bmi")
            }
            .pickerStyle(.segmented)
            .padding()
            .onChange(of: selectedMeasurement) { _, newValue in
                let file = "\(filePrefix(for: newValue))_0_24m_\(patientSex)"
                logger.debug("WHO file selected for \(newValue, privacy: .public): \(file, privacy: .public)")
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
                        Text("No BMI yet")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Add a weight and height measurement to see the BMI chart.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("No measurements yet")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Add a measurement to see the \(selectedMeasurement) chart.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { logger.warning("patientData is empty for \(self.selectedMeasurement, privacy: .public)") }
            } else if referenceCurves.isEmpty {
                // Also avoid rendering if reference curves failed to load.
                VStack(spacing: 12) {
                    Text("Reference curves unavailable")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Missing WHO reference for “\(whoFileName)”. The chart will appear once curves are available.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { logger.error("reference curves empty for \(whoFileName, privacy: .public)") }
            } else {
                GrowthChartView(
                    dataPoints: patientData,
                    referenceCurves: referenceCurves,
                    measurement: selectedMeasurement
                )
                .onAppear {
                    logger.info("Chart appear: measurement=\(self.selectedMeasurement, privacy: .public) points=\(patientData.count) curves=\(referenceCurves.count)")
                }
            }
        }
        .onAppear {
            logger.info("GrowthChartScreen appeared for sex=\(self.patientSex, privacy: .public) initialMeasurement=\(self.selectedMeasurement, privacy: .public)")
        }
        .navigationTitle("Growth Chart")
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
