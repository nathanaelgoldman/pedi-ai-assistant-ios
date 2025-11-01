//
//  VitalsTableView.swift
//  DrsMainApp
//
//  Created by yunastic on 11/1/25.
//

import SwiftUI

struct VitalsTableView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var vitals: [VitalsPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Patient Vitals")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("Close") {
                    dismiss()
                }
            }
            .padding(.bottom, 8)

            if vitals.isEmpty {
                Text("No vitals recorded for this patient.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(vitals) {
                    TableColumn("Date/Time") { item in
                        Text(item.recordedAtISO.isEmpty ? "—" : item.recordedAtISO)
                    }
                    TableColumn("Temp °C") { item in
                        if let v = item.temperatureC {
                            Text(String(format: "%.1f", v))
                        }
                    }
                    TableColumn("HR") { item in
                        if let v = item.heartRate {
                            Text("\(v)")
                        }
                    }
                    TableColumn("RR") { item in
                        if let v = item.respiratoryRate {
                            Text("\(v)")
                        }
                    }
                    TableColumn("SpO₂") { item in
                        if let v = item.spo2 {
                            Text("\(v)%")
                        }
                    }
                    TableColumn("BP") { item in
                        if let sys = item.bpSystolic, let dia = item.bpDiastolic {
                            Text("\(sys)/\(dia)")
                        }
                    }
                    TableColumn("Weight (kg)") { item in
                        if let v = item.weightKg {
                            Text(String(format: "%.2f", v))
                        }
                    }
                    TableColumn("Height (cm)") { item in
                        if let v = item.heightCm {
                            Text(String(format: "%.1f", v))
                        }
                    }
                    TableColumn("HC (cm)") { item in
                        if let v = item.headCircumferenceCm {
                            Text(String(format: "%.1f", v))
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding()
        .frame(minWidth: 900, minHeight: 500)
        .onAppear {
            vitals = appState.loadVitalsForSelectedPatient()
        }
    }
}

#Preview {
    VitalsTableView()
        .environmentObject(AppState(clinicianStore: ClinicianStore()))
}
