//
//  VisitDetailSheet.swift
//  DrsMainApp
//
//  Created by yunastic on 11/2/25.
//

import SwiftUI

struct VisitDetailSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Text("Visit Details").font(.title2).bold()
                Spacer()
                Button("Close") { dismiss() }
            }

            // Content
            if let d = appState.visitDetails {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Group {
                            Text("Patient").font(.headline)
                            let full = (d.patientFullName ?? "").trimmingCharacters(in: .whitespaces)
                            let alias = (d.patientAlias ?? "").trimmingCharacters(in: .whitespaces)
                            Text(full.isEmpty ? (alias.isEmpty ? "—" : alias) : full)
                            if let dob = d.patientDOB, !dob.isEmpty { Text("DOB: \(dob)") }
                            if let sex = d.patientSex, !sex.isEmpty { Text("Sex: \(sex)") }
                            Divider()
                        }

                        Group {
                            Text("Visit").font(.headline)
                            if let dateStr = d.visitDateISO, !dateStr.isEmpty { Text("Date: \(dateStr)") }
                            if let cat = d.category, !cat.isEmpty { Text("Type: \(cat)") }
                            if let mc = d.mainComplaint, !mc.isEmpty { LabeledField("Main Complaint", mc) }
                            if let pb = d.problems, !pb.isEmpty { LabeledField("Problem Listing", pb) }
                            if let dx = d.diagnosis, !dx.isEmpty { LabeledField("Diagnosis", dx) }
                            if let icd = d.icd10, !icd.isEmpty { LabeledField("ICD-10", icd) }
                            if let cons = d.conclusions, !cons.isEmpty { LabeledField("Conclusions / Plan", cons) }
                            if let ms = d.milestonesSummary, !ms.isEmpty { LabeledField("Milestones", ms) }
                            Divider()
                        }

                        Group {
                            Text("Latest Vitals at/≤ visit").font(.headline)
                            if let v = d.latestVitals {
                                VStack(alignment: .leading, spacing: 6) {
                                    if let w = v.weightKg { Text(String(format: "Weight: %.3f kg", w)) }
                                    if let h = v.heightCm { Text(String(format: "Length/Height: %.1f cm", h)) }
                                    if let hc = v.headCircumferenceCm { Text(String(format: "Head Circ: %.1f cm", hc)) }
                                    if let t = v.temperatureC { Text(String(format: "Temp: %.1f °C", t)) }
                                    if let hr = v.heartRate { Text("HR: \(hr) bpm") }
                                    if let rr = v.respiratoryRate { Text("RR: \(rr)/min") }
                                    if let s = v.spo2 { Text("SpO₂: \(s)%") }
                                    if let sys = v.bpSystolic, let dia = v.bpDiastolic { Text("BP: \(sys)/\(dia) mmHg") }
                                    if let rec = v.recordedAtISO, !rec.isEmpty {
                                        Text("Recorded: \(rec)").font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                Text("— no vitals found —").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            } else {
                Text("No details to show.").foregroundStyle(.secondary)
            }

            // Footer actions (PDF export can be added later)
            HStack {
                Spacer()
            }
        }
        .frame(minWidth: 520, minHeight: 560)
        .padding(16)
    }
}

// Compact labeled field used above
private struct LabeledField: View {
    let title: String
    let text: String
    init(_ title: String, _ text: String) { self.title = title; self.text = text }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(text).textSelection(.enabled)
        }
    }
}
