//
//  NewPatientSheet.swift
//  DrsMainApp
//
//  Created by yunastic on 10/26/25.
//

// DrsMainApp/Sources/UI/NewPatientSheet.swift
import SwiftUI
import Foundation
import PediaShared

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

    // Default save location
    @State private var parentDir: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Pedia/Bundles", isDirectory: true)
        // Ensure the default exists
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create New Patient").font(.title2).bold()

            Group {
                HStack {
                    Text("First name").frame(width: 120, alignment: .trailing)
                    TextField("e.g. Alice", text: $firstName)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("Last name").frame(width: 120, alignment: .trailing)
                    TextField("e.g. Chen", text: $lastName)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Group {
                HStack {
                    Text("Alias").frame(width: 120, alignment: .trailing)
                    TextField("", text: $aliasLabel)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                    Button {
                        regenerateAlias()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Generate a new random alias")
                }

                HStack {
                    Text("Alias ID").frame(width: 120, alignment: .trailing)
                    TextField("", text: $aliasID)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                }

                HStack {
                    Text("MRN").frame(width: 120, alignment: .trailing)
                    TextField("", text: $mrnPreview)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                }
            }

            HStack {
                Text("Date of birth").frame(width: 120, alignment: .trailing)
                DatePicker("", selection: $dob, displayedComponents: .date)
                    .labelsHidden()
            }

            HStack {
                Text("Sex").frame(width: 120, alignment: .trailing)
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
                Text("Save to").frame(width: 120, alignment: .trailing)
                Text(parentDir.path)
                    .font(.callout).foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Choose Folder…") {
                    if let url = PediaBundlePicker.selectBundleDirectory() {
                        parentDir = url
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage).foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            parentDir = appState.bundlesRoot
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
                into: parentDir,
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
