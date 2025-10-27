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

    @State private var alias = ""
    @State private var fullName = ""
    @State private var dob = Date()
    @State private var sex = "M"

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

            HStack {
                Text("Alias").frame(width: 120, alignment: .trailing)
                TextField("e.g. Teal Robin", text: $alias)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Full name").frame(width: 120, alignment: .trailing)
                TextField("Optional", text: $fullName)
                    .textFieldStyle(.roundedBorder)
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
                .disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func create() {
        let trimmedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFullName = fullName.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            let url = try appState.createNewPatient(
                into: parentDir,
                alias: trimmedAlias,
                fullName: trimmedFullName.isEmpty ? nil : trimmedFullName,
                dob: dob,
                sex: sex
            )
            appState.selectBundle(url)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
