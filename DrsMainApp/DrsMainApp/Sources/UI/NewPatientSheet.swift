//
//  NewPatientSheet.swift
//  DrsMainApp
//
//  Created by yunastic on 10/26/25.
//

// DrsMainApp/Sources/UI/NewPatientSheet.swift
import SwiftUI
import Foundation

struct NewPatientSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var appState: AppState

    // Identity
    @State private var firstName = ""
    @State private var lastName = ""

    // Alias (read-only fields presented to user; can regenerate)
    @State private var aliasLabel = ""
    @State private var aliasID = ""

    // DOB / Sex
    @State private var dob = Date()
    @State private var sex = "M"      // "M" | "F" | "U"

    // MRN preview (read-only)
    @State private var mrnPreview = ""

    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(NSLocalizedString("new_patient_sheet.title", comment: "Title for the create new patient sheet")).font(.title2).bold()

            Group {
                HStack {
                    Text(NSLocalizedString("new_patient_sheet.field.first_name", comment: "Label for first name field")).frame(width: 120, alignment: .trailing)
                    TextField(NSLocalizedString("new_patient_sheet.placeholder.first_name_example", comment: "Placeholder example for first name"), text: $firstName)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text(NSLocalizedString("new_patient_sheet.field.last_name", comment: "Label for last name field")).frame(width: 120, alignment: .trailing)
                    TextField(NSLocalizedString("new_patient_sheet.placeholder.last_name_example", comment: "Placeholder example for last name"), text: $lastName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Group {
                HStack {
                    Text(NSLocalizedString("new_patient_sheet.field.alias", comment: "Label for alias field"))
                        .frame(width: 120, alignment: .trailing)
                    TextField("", text: $aliasLabel)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    Button {
                        regenerateAlias()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(NSLocalizedString("new_patient_sheet.alias.regenerate_help", comment: "Help text for regenerate alias button"))
                }

                HStack {
                    Text(NSLocalizedString("new_patient_sheet.field.alias_id", comment: "Label for alias ID field"))
                        .frame(width: 120, alignment: .trailing)
                    TextField("", text: $aliasID)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                }

                HStack {
                    Text(NSLocalizedString("new_patient_sheet.field.mrn", comment: "Label for MRN field"))
                        .frame(width: 120, alignment: .trailing)
                    TextField("", text: $mrnPreview)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                }
            }

            HStack {
                Text(NSLocalizedString("new_patient_sheet.field.dob", comment: "Label for date of birth field"))
                    .frame(width: 120, alignment: .trailing)
                DatePicker("", selection: $dob, displayedComponents: .date)
                    .labelsHidden()
            }

            HStack {
                Text(NSLocalizedString("new_patient_sheet.field.sex", comment: "Label for sex picker"))
                    .frame(width: 120, alignment: .trailing)
                Picker("", selection: $sex) {
                    Text("M").tag("M")
                    Text("F").tag("F")
                    Text("U").tag("U")
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            Divider().padding(.vertical, 4)

            HStack(alignment: .center) {
                Text(NSLocalizedString("new_patient_sheet.field.save_to", comment: "Label for save-to folder row"))
                    .frame(width: 120, alignment: .trailing)
                Text(appState.bundlesRoot.path)
                    .font(.callout).foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
            }

            if let errorMessage {
                Text(errorMessage).foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button(NSLocalizedString("new_patient_sheet.button.cancel", comment: "Cancel button to dismiss the new patient sheet")) { dismiss() }
                Button(NSLocalizedString("new_patient_sheet.button.create", comment: "Create button to create the new patient")) {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        )
        .padding(20)
        .frame(width: 560)
        .onAppear {
            // Seed alias & MRN on open
            if aliasLabel.isEmpty { regenerateAlias() }
            recomputeMRN()
        }
        .onChange(of: firstName) { _, _ in recomputeMRN() }
        .onChange(of: lastName)  { _, _ in recomputeMRN() }
        .onChange(of: dob)       { _, _ in recomputeMRN() }
        .onChange(of: sex)       { _, _ in recomputeMRN() }
    }

    private var canCreate: Bool {
        // Minimal requirements: alias present, DOB set (always), sex in allowed set
        !aliasLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ["M","F","U"].contains(sex)
    }

    private func create() {
        let f = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = lastName.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let url = try appState.createNewPatient(
                into: appState.bundlesRoot,
                alias: aliasLabel,                // for folder label friendliness
                firstName: f.isEmpty ? nil : f,
                lastName: l.isEmpty ? nil : l,
                fullName: nil,                    // let AppState compose if needed
                dob: dob,
                sex: sex,
                aliasLabel: aliasLabel,
                aliasID: aliasID,
                mrnOverride: mrnPreview.isEmpty ? nil : mrnPreview
            )
            appState.selectBundle(url)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func regenerateAlias() {
        let a = AliasGenerator.generate()
        aliasLabel = a.label
        aliasID = a.id
    }

    private func recomputeMRN() {
        // Prefer MRN utility if present; else compute a simple checksum-based ID.
        // Format: YYYYMMDD-SX-CCCC where SX = sex initial; CCCC = base36 checksum
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd"
        let ymd = df.string(from: dob)
        let sx = (sex.first.map { String($0) } ?? "U")
        let nameSeed = (firstName + "|" + lastName).lowercased()
        let seed = "\(ymd)#\(sx)#\(nameSeed)"
        let csum = simpleChecksumBase36(seed)
        mrnPreview = "\(ymd)-\(sx)-\(csum)"
    }

    private func simpleChecksumBase36(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603 // FNV offset basis
        for b in s.utf8 {
            h ^= UInt64(b)
            h &*= 1099511628211
        }
        // produce 4 base36 chars
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var x = h ^ (h >> 32)
        var out = ""
        for _ in 0..<4 {
            let idx = Int(x % 36)
            out.append(alphabet[idx])
            x /= 36
        }
        return out
    }
}
