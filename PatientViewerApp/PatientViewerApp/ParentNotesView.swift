//
//  ParentNotesView.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/14/25
//

import SwiftUI
import SQLite
import OSLog

private let notesLog = Logger(subsystem: "Yunastic.PatientViewerApp", category: "ParentNotesView")

struct ParentNotesView: SwiftUI.View {
    let dbURL: URL
    let patientId: Int64
    var onAutoSaveToPersistent: (() -> Void)? = nil

    @State private var noteInput: String = ""
    @State private var notes: [String] = []
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var refreshTrigger = false

    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 16) {
            Text("📓 Parent Notes")
                .font(.title2)
                .padding(.bottom, 8)

            TextEditor(text: $noteInput)
                .frame(height: 100)
                .border(Color.gray, width: 1)

            HStack {
                Spacer()
                Button("💾 Save Note") {
                    saveNote()
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            if notes.isEmpty {
                Text("No notes added yet.")
                    .foregroundColor(.gray)
            } else {
                Text("🗒️ Notes")
                    .font(.headline)

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(notes.indices, id: \.self) { idx in
                            HStack {
                                Text(notes[idx])
                                    .font(.body)
                                    .padding(8)
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(8)
                                Spacer()
                                Button("🗑") {
                                    deleteNote(at: idx)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .onAppear {
            loadNotes()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            loadNotes()
        }
        .onChange(of: refreshTrigger) { _, _ in
            loadNotes()
        }
        .onChange(of: patientId) { _, _ in
            loadNotes()
        }
        .onDisappear {
            onAutoSaveToPersistent?()
        }
        .alert("Error", isPresented: $showAlert, actions: {}) {
            Text(alertMessage)
        }
    }

    // MARK: - Self-heal helpers
    private func ensureParentNotesColumn(dbPath: String) throws {
        let db = try Connection(dbPath)
        let count = (try db.scalar("SELECT count(*) FROM pragma_table_info('patients') WHERE name = 'parent_notes'") as? Int64) ?? 0
        if count == 0 {
            try db.run("ALTER TABLE patients ADD COLUMN parent_notes TEXT")
            notesLog.info("Added missing parent_notes column in patients table at \(dbPath, privacy: .public)")
        }
    }

    // MARK: - DB path resolution
    private func resolveDBURL() -> URL? {
        let fm = FileManager.default
        var isDir: ObjCBool = false

        // Ensure base is a directory and prefer the common root location first
        if fm.fileExists(atPath: dbURL.path, isDirectory: &isDir), isDir.boolValue {
            let direct = dbURL.appendingPathComponent("db.sqlite")
            if fm.fileExists(atPath: direct.path) {
                return direct
            }
            // Fallback: walk the tree and find the first db.sqlite
            if let enumerator = fm.enumerator(at: dbURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                for case let u as URL in enumerator where u.lastPathComponent == "db.sqlite" {
                    return u
                }
            }
        } else {
            notesLog.warning("Provided dbURL is not a directory: \(dbURL.path, privacy: .public)")
        }
        return nil
    }

    private func loadNotes() {
        do {
            notesLog.debug("Attempting to load db from base URL: \(dbURL.path, privacy: .public)")
            guard let dbFileURL = resolveDBURL() else {
                alertMessage = "Could not locate db.sqlite under \(dbURL.lastPathComponent)."
                showAlert = true
                return
            }
            try ensureParentNotesColumn(dbPath: dbFileURL.path)
            notesLog.debug("Loading from DB path: \(dbFileURL.path, privacy: .public)")
            let db = try Connection(dbFileURL.path)
            let patients = Table("patients")
            
            let id = Expression<Int64>("id")
            let parentNotes = Expression<String?>("parent_notes")

            guard let patientRow = try db.pluck(patients.filter(id == patientId)) else {
                alertMessage = "No patient found."
                showAlert = true
                return
            }

            let raw = try patientRow.get(parentNotes) ?? ""
            notesLog.debug("Fetched parent_notes for patient \(patientId, privacy: .public) (length: \((raw as NSString).length, privacy: .public))")
            notes = raw.split(separator: "\n\n").map { String($0) }
            notesLog.debug("View notes array now contains \(notes.count, privacy: .public) items.")
        } catch {
            alertMessage = "Failed to load notes: \(error)"
            showAlert = true
        }
    }

    private func saveNote() {
        let trimmed = noteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            guard let dbFileURL = resolveDBURL() else {
                alertMessage = "Could not locate db.sqlite to save."
                showAlert = true
                return
            }
            try ensureParentNotesColumn(dbPath: dbFileURL.path)
            notesLog.debug("Saving to DB path: \(dbFileURL.path, privacy: .public)")
            let db = try Connection(dbFileURL.path)
            let patients = Table("patients")
            let id = Expression<Int64>("id")
            let parentNotes = Expression<String?>("parent_notes")

            guard let patientRow = try db.pluck(patients.filter(id == patientId)) else {
                alertMessage = "No patient found."
                showAlert = true
                return
            }

            let existing = try patientRow.get(parentNotes) ?? ""
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let newNote = "[\(timestamp)] \(trimmed)"
            var allNotes = existing.split(separator: "\n\n").map { String($0) }
            allNotes.insert(newNote, at: 0)
            let joined = allNotes.joined(separator: "\n\n")

            let update = patients.filter(id == patientId)
            notesLog.debug("Executing SQL update on column 'parent_notes' (new length: \(joined.count, privacy: .public))")
            let changes = try db.run(update.update(parentNotes <- joined))
            notesLog.debug("Update affected rows: \(changes, privacy: .public)")

            // Read-back test
            if let confirmRow = try? db.pluck(patients.filter(id == patientId)) {
                let confirmNotes = try confirmRow.get(parentNotes) ?? "[empty]"
                notesLog.debug("Confirm saved notes for patient \(patientId, privacy: .public) (length: \(confirmNotes.count, privacy: .public))")
            }

            noteInput = ""
            loadNotes()
            refreshTrigger.toggle()
        } catch {
            alertMessage = "Failed to save note: \(error)"
            showAlert = true
        }
    }

    private func deleteNote(at index: Int) {
        guard index < notes.count else { return }

        do {
            guard let dbFileURL = resolveDBURL() else {
                alertMessage = "Could not locate db.sqlite to delete note."
                showAlert = true
                return
            }
            let db = try Connection(dbFileURL.path)
            let patients = Table("patients")
            let id = Expression<Int64>("id")
            let parentNotes = Expression<String?>("parent_notes")

            guard try db.pluck(patients.filter(id == patientId)) != nil else {
                alertMessage = "No patient found."
                showAlert = true
                return
            }

            var allNotes = notes
            allNotes.remove(at: index)
            let joined = allNotes.joined(separator: "\n\n")

            let update = patients.filter(id == patientId)
            notesLog.debug("Deleting note at index \(index, privacy: .public); remaining count will be \(allNotes.count, privacy: .public)")
            try db.run(update.update(parentNotes <- joined))

            loadNotes()
        } catch {
            alertMessage = "Failed to delete note: \(error)"
            showAlert = true
        }
    }
}
