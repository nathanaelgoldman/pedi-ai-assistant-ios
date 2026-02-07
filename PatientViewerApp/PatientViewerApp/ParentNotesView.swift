//
//  ParentNotesView.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/14/25
//

import SwiftUI
import SQLite
import OSLog
import UIKit


private let notesLog = AppLog.feature("ParentNotesView")

// SupportLog wiring (keep logs lightweight + privacy-safe)
@MainActor private func S(_ msg: String) {
    // SupportLog is the user-exportable log; keep messages short and avoid raw identifiers.
    SupportLog.shared.info(msg)
}

private func tokPatient(_ patientId: Int64) -> String {
    AppLog.token(String(patientId))
}

private func L(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
}

private func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let isoFormatterNoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private let noteDisplayFormatter: DateFormatter = {
    let df = DateFormatter()
    df.locale = .current
    df.timeZone = .current
    df.dateStyle = .medium
    df.timeStyle = .short
    return df
}()

private extension SwiftUI.View {
    @ViewBuilder
    func scrollContentBackgroundCompatHidden() -> some SwiftUI.View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

@MainActor struct ParentNotesView: SwiftUI.View {
    let dbURL: URL
    let patientId: Int64
    var onAutoSaveToPersistent: (() -> Void)? = nil

    @State private var noteInput: String = ""
    @State private var notes: [String] = []
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var refreshTrigger = false

    // MARK: - Display helpers
    private func parseISO8601(_ s: String) -> Date? {
        if let d = isoFormatter.date(from: s) { return d }
        if let d = isoFormatterNoFrac.date(from: s) { return d }
        return nil
    }

    /// Converts stored notes like "[2026-02-04T08:35:16.134Z] Hello" into
    /// "[Feb 4, 2026, 4:35 PM] Hello" using the current locale.
    private func formatNoteForDisplay(_ raw: String) -> String {
        guard raw.hasPrefix("[") else { return raw }
        guard let end = raw.firstIndex(of: "]") else { return raw }

        let tsStart = raw.index(after: raw.startIndex)
        let ts = String(raw[tsStart..<end])
        let remainderStart = raw.index(after: end)
        let remainder = raw[remainderStart...].trimmingCharacters(in: .whitespaces)

        guard let d = parseISO8601(ts) else { return raw }
        let pretty = noteDisplayFormatter.string(from: d)

        if remainder.isEmpty {
            return "[\(pretty)]"
        }
        return "[\(pretty)] \(remainder)"
    }

    var body: some SwiftUI.View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("parentNotes.title")
                    .font(.title2)
                    .padding(.bottom, 8)

                // Rounded note input area (theme card)
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $noteInput)
                        .frame(minHeight: 110)
                        .padding(10)
                        .background(Color.clear)
                        .scrollContentBackgroundCompatHidden()
                }
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                        .fill(AppTheme.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.cornerRadius, style: .continuous)
                        .stroke(AppTheme.cardStroke, lineWidth: 0.8)
                )

                HStack {
                    Spacer()
                    Button("parentNotes.saveNote") {
                        saveNote()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Divider()

                if notes.isEmpty {
                    Text("parentNotes.empty")
                        .foregroundColor(.secondary)
                } else {
                    Text("parentNotes.notesHeader")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(notes.indices, id: \.self) { idx in
                            HStack(alignment: .top, spacing: 10) {
                                Text(formatNoteForDisplay(notes[idx]))
                                    .font(.body)
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                                            .fill(AppTheme.card)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: AppTheme.smallCornerRadius, style: .continuous)
                                            .stroke(AppTheme.cardStroke, lineWidth: 0.8)
                                    )

                                Button {
                                    deleteNote(at: idx)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel(Text("parentNotes.deleteNote.accessibilityLabel"))
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .appBackground()
        .appNavBarBackground()
        .navigationTitle(L("parentNotes.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadNotes()
            S("UI open parent notes | patientTok=\(tokPatient(patientId))")
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
            S("UI close parent notes | patientTok=\(tokPatient(patientId))")
            onAutoSaveToPersistent?()
        }
        .alert("common.error", isPresented: $showAlert, actions: {}) {
            Text(alertMessage)
        }
    }

    // MARK: - Self-heal helpers
    private func ensureParentNotesColumn(dbPath: String) throws {
        let db = try Connection(dbPath)
        let count = (try db.scalar("SELECT count(*) FROM pragma_table_info('patients') WHERE name = 'parent_notes'") as? Int64) ?? 0
        if count == 0 {
            try db.run("ALTER TABLE patients ADD COLUMN parent_notes TEXT")
            notesLog.info("Added missing parent_notes column in patients table at \(((dbPath as NSString).lastPathComponent), privacy: .public)")
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
            notesLog.warning("Provided dbURL is not a directory: \(dbURL.lastPathComponent, privacy: .public)")
        }
        return nil
    }

    private func loadNotes() {
        do {
            notesLog.debug("Attempting to load DB | base=BUNDLE#\(AppLog.token(dbURL.lastPathComponent), privacy: .public)")
            S("PN load start | patientTok=\(tokPatient(patientId))")
            guard let dbFileURL = resolveDBURL() else {
                alertMessage = LF("parentNotes.error.dbNotFoundUnder_fmt", dbURL.lastPathComponent)
                showAlert = true
                return
            }
            try ensureParentNotesColumn(dbPath: dbFileURL.path)
            notesLog.debug("Loading from DB: \(dbFileURL.lastPathComponent, privacy: .public)")
            let db = try Connection(dbFileURL.path)
            let patients = Table("patients")
            
            let id = Expression<Int64>("id")
            let parentNotes = Expression<String?>("parent_notes")

            guard let patientRow = try db.pluck(patients.filter(id == patientId)) else {
                alertMessage = L("parentNotes.error.noPatientFound")
                showAlert = true
                return
            }

            let raw = try patientRow.get(parentNotes) ?? ""
            notesLog.debug("Fetched parent_notes for patient \(patientId, privacy: .public) (length: \((raw as NSString).length, privacy: .public))")
            notes = raw.split(separator: "\n\n").map { String($0) }
            S("PN load ok | patientTok=\(tokPatient(patientId)) count=\(notes.count)")
            notesLog.debug("View notes array now contains \(notes.count, privacy: .public) items.")
        } catch {
            S("PN load error | patientTok=\(tokPatient(patientId)) err=\((error as NSError).localizedDescription)")
            alertMessage = LF("parentNotes.error.loadFailed_fmt", (error as NSError).localizedDescription)
            showAlert = true
        }
    }

    private func saveNote() {
        let trimmed = noteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        S("PN save tap | patientTok=\(tokPatient(patientId))")

        do {
            guard let dbFileURL = resolveDBURL() else {
                alertMessage = L("parentNotes.error.dbNotFoundToSave")
                showAlert = true
                return
            }
            try ensureParentNotesColumn(dbPath: dbFileURL.path)
            notesLog.debug("Saving to DB: \(dbFileURL.lastPathComponent, privacy: .public)")
            let db = try Connection(dbFileURL.path)
            let patients = Table("patients")
            let id = Expression<Int64>("id")
            let parentNotes = Expression<String?>("parent_notes")

            guard let patientRow = try db.pluck(patients.filter(id == patientId)) else {
                alertMessage = L("parentNotes.error.noPatientFound")
                showAlert = true
                return
            }

            let existing = try patientRow.get(parentNotes) ?? ""
            let timestamp = isoFormatter.string(from: Date())
            let newNote = "[\(timestamp)] \(trimmed)"
            var allNotes = existing.split(separator: "\n\n").map { String($0) }
            allNotes.insert(newNote, at: 0)
            let joined = allNotes.joined(separator: "\n\n")

            let update = patients.filter(id == patientId)
            notesLog.debug("Executing SQL update on column 'parent_notes' (new length: \(joined.count, privacy: .public))")
            let changes = try db.run(update.update(parentNotes <- joined))
            notesLog.debug("Update affected rows: \(changes, privacy: .public)")
            S("PN save ok | patientTok=\(tokPatient(patientId)) rows=\(changes) notes=\(allNotes.count)")

            // Read-back test
            if let confirmRow = try? db.pluck(patients.filter(id == patientId)) {
                let confirmNotes = try confirmRow.get(parentNotes) ?? "[empty]"
                notesLog.debug("Confirm saved notes for patient \(patientId, privacy: .public) (length: \(confirmNotes.count, privacy: .public))")
            }

            noteInput = ""
            loadNotes()
        } catch {
            S("PN save error | patientTok=\(tokPatient(patientId)) err=\((error as NSError).localizedDescription)")
            alertMessage = LF("parentNotes.error.saveFailed_fmt", (error as NSError).localizedDescription)
            showAlert = true
        }
    }

    private func deleteNote(at index: Int) {
        guard index < notes.count else { return }
        S("PN delete tap | patientTok=\(tokPatient(patientId)) idx=\(index)")

        do {
            guard let dbFileURL = resolveDBURL() else {
                alertMessage = L("parentNotes.error.dbNotFoundToDelete")
                showAlert = true
                return
            }
            let db = try Connection(dbFileURL.path)
            let patients = Table("patients")
            let id = Expression<Int64>("id")
            let parentNotes = Expression<String?>("parent_notes")

            guard try db.pluck(patients.filter(id == patientId)) != nil else {
                alertMessage = L("parentNotes.error.noPatientFound")
                showAlert = true
                return
            }

            var allNotes = notes
            allNotes.remove(at: index)
            let joined = allNotes.joined(separator: "\n\n")

            let update = patients.filter(id == patientId)
            notesLog.debug("Deleting note at index \(index, privacy: .public); remaining count will be \(allNotes.count, privacy: .public)")
            try db.run(update.update(parentNotes <- joined))
            S("PN delete ok | patientTok=\(tokPatient(patientId)) remaining=\(allNotes.count)")

            loadNotes()
        } catch {
            S("PN delete error | patientTok=\(tokPatient(patientId)) err=\((error as NSError).localizedDescription)")
            alertMessage = LF("parentNotes.error.deleteFailed_fmt", (error as NSError).localizedDescription)
            showAlert = true
        }
    }
}
