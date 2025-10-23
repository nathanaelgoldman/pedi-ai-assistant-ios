import SwiftUI

struct GrowthChartScreen: View {
    let patientSex: String
    let allPatientData: [String: [GrowthDataPoint]]

    @State private var selectedMeasurement = "weight"
    private let measurementOptions = ["weight", "height", "head_circ"]

    var body: some View {
        VStack {
            Picker("Measurement", selection: $selectedMeasurement) {
                Text("Weight").tag("weight")
                Text("Height").tag("height")
                Text("Head Circ.").tag("head_circ")
            }
            .pickerStyle(.segmented)
            .padding()
            .onChange(of: selectedMeasurement) { _, newValue in
                let file = "\(filePrefix(for: newValue))_0_24m_\(patientSex)"
                print("[DEBUG] WHO file selected for \(newValue): \(file)")
            }

            let patientData = allPatientData[selectedMeasurement] ?? []

            let whoFilePrefix = filePrefix(for: selectedMeasurement)
            let whoFileName = "\(whoFilePrefix)_0_24m_\(patientSex)"
            let referenceCurves = WhoReferenceLoader.loadCurve(fromCSV: whoFileName, sex: patientSex)

            if patientData.isEmpty {
                // Avoid drawing an empty chart which can cause NaN in CoreGraphics on iOS.
                VStack(spacing: 12) {
                    Text("No measurements yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Add a measurement to see the \(selectedMeasurement) chart.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { print("[DEBUG] GrowthChartScreen: patientData is empty for \(selectedMeasurement)") }
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
                .onAppear { print("[DEBUG] GrowthChartScreen: reference curves empty for \(whoFileName)") }
            } else {
                GrowthChartView(
                    dataPoints: patientData,
                    referenceCurves: referenceCurves,
                    measurement: selectedMeasurement
                )
            }
        }
        .navigationTitle("Growth Chart")
    }

    func filePrefix(for measurement: String) -> String {
        switch measurement {
        case "weight": return "wfa"
        case "height": return "lhfa"
        case "head_circ": return "hcfa" // head circumference-for-age
        default: return "wfa"
        }
    }
}
