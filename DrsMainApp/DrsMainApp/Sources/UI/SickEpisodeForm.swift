//
//  SickEpisodeForm.swift
//  DrsMainApp
//
//  Created by yunastic on 11/14/25.
//
//
//  SickEpisodeForm.swift
//  DrsMainApp
//
//  Created by ChatGPT on 11/14/25.
//

import SwiftUI
import OSLog
import SQLite3

// SQLite helper: transient destructor pointer for sqlite3_bind_text
fileprivate let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Form for creating or editing a sick episode.
/// This version focuses on a stable UI; persistence will be wired in next.
struct SickEpisodeForm: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    /// If non-nil, the form is editing that specific episode id.
    let editingEpisodeID: Int?

    // MARK: - Core HPI
    @State private var presetComplaints: Set<String> = []
    @State private var otherComplaints: String = ""
    @State private var hpi: String = ""
    @State private var duration: String = ""

    // MARK: - Structured HPI
    @State private var appearance: String = "Well"
    @State private var feeding: String = "Normal"
    @State private var breathing: String = "Normal"
    @State private var urination: String = "Normal"
    @State private var pain: String = "None"
    @State private var stools: String = "Normal"
    @State private var context: Set<String> = []

    // MARK: - Physical Exam
    @State private var generalAppearance: String = "Well"
    @State private var hydration: String = "Normal"
    @State private var heart: String = "Normal"
    @State private var color: String = "Normal"
    @State private var skin: String = "Normal"
    @State private var ent: Set<String> = ["Normal"]
    @State private var rightEar: String = "Normal"
    @State private var leftEar: String = "Normal"
    @State private var rightEye: String = "Normal"
    @State private var leftEye: String = "Normal"
    @State private var lungs: String = "Normal"
    @State private var abdomen: String = "Normal"
    @State private var peristalsis: String = "Normal"
    @State private var genitalia: String = "Normal"
    @State private var neurological: String = "Alert"
    @State private var musculoskeletal: String = "Normal"
    @State private var lymphNodes: String = "None"

    // MARK: - Plan
    @State private var problemListing: String = ""
    @State private var complementaryInvestigations: String = ""
    @State private var diagnosis: String = ""
    @State private var icd10: String = ""
    @State private var medications: String = ""
    @State private var anticipatoryGuidance: String = "URI"
    @State private var comments: String = ""

    // MARK: - Choices
    private let complaintOptions = [
        "Fever","Cough","Runny nose","Diarrhea","Vomiting",
        "Rash","Abdominal pain","Headache"
    ]
    private let appearanceChoices = ["Well","Tired","Irritable","Lethargic"]
    private let feedingChoices = ["Normal","Decreased","Refuses"]
    private let breathingChoices = ["Normal","Fast","Labored","Noisy"]
    private let urinationChoices = ["Normal","Decreased","Painful","Foul-smelling"]
    private let painChoices = ["None","Abdominal","Ear","Throat","Limb"]
    private let stoolsChoices = ["Normal","Soft","Liquid"]
    private let contextChoices = ["Travel","Sick contact","Daycare","None"]

    private let generalChoices = ["Well","Tired","Irritable","Lethargic"]
    private let hydrationChoices = ["Normal","Decreased"]
    private let heartChoices = ["Normal","Murmur","Tachycardia"]
    private let colorChoices = ["Normal","Pale","Yellow"]
    private let skinChoices = ["Normal","Papular rash","Macular rash","Maculopapular rash","Petechiae","Purpura"]
    private let entChoices = ["Normal","Red throat","Ear discharge","Congested nose"]
    private let earChoices = ["Normal","Red TM","Red & Bulging with pus","Pus in canal","Not seen (wax)","Red canal"]
    private let eyeChoices = ["Normal","Discharge","Red","Crusty"]
    private let lungsChoices = ["Normal","Crackles","Wheeze","Decreased sounds"]
    private let abdomenChoices = ["Normal","Tender","Distended","Guarding"]
    private let peristalsisChoices = ["Normal","Increased","Decreased"]
    private let genitaliaChoices = ["Normal","Redness","Discharge","Abnormal"]
    private let neuroChoices = ["Alert","Sleepy","Irritable","Abnormal tone"]
    private let mskChoices = ["Normal","Limping","Swollen joint","Pain"]
    private let nodesChoices = ["None","Cervical","Generalized"]

    private let guidanceChoices = ["URI","AGE","UTI","Otitis"]

    private let log = Logger(subsystem: "DrsMainApp", category: "SickEpisodeForm")

    init(editingEpisodeID: Int? = nil) {
        self.editingEpisodeID = editingEpisodeID
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    HStack {
                        Image(systemName: "stethoscope")
                            .font(.system(size: 22))
                        Text(editingEpisodeID == nil ? "New Sick Episode" : "Edit Sick Episode #\(editingEpisodeID!)")
                            .font(.title2.bold())
                        Spacer()
                    }

                    // Two columns using Grid
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 16) {
                        GridRow {
                            // Column A
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeader("Main Complaint")
                                complaintBlock
                                SectionHeader("History of Present Illness")
                                pickerRow("Appearance", $appearance, appearanceChoices)
                                pickerRow("Feeding", $feeding, feedingChoices)
                                pickerRow("Breathing", $breathing, breathingChoices)
                                pickerRow("Urination", $urination, urinationChoices)
                                pickerRow("Pain", $pain, painChoices)
                                pickerRow("Stools", $stools, stoolsChoices)
                                multiSelectChips(title: "Context", options: contextChoices, selection: $context)
                                TextField("HPI summary", text: $hpi, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(3...6)
                                TextField("Duration (hours)", text: $duration)
                                    .textFieldStyle(.roundedBorder)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)

                            // Column B
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeader("Physical Examination")
                                pickerRow("General appearance", $generalAppearance, generalChoices)
                                pickerRow("Hydration", $hydration, hydrationChoices)
                                pickerRow("Heart", $heart, heartChoices)
                                pickerRow("Color / Hemodynamics", $color, colorChoices)
                                pickerRow("Skin", $skin, skinChoices)
                                multiSelectChips(title: "ENT", options: entChoices, selection: $ent)
                                pickerRow("Right ear", $rightEar, earChoices)
                                pickerRow("Left ear", $leftEar, earChoices)
                                pickerRow("Right eye", $rightEye, eyeChoices)
                                pickerRow("Left eye", $leftEye, eyeChoices)
                                pickerRow("Lungs", $lungs, lungsChoices)
                                pickerRow("Abdomen", $abdomen, abdomenChoices)
                                pickerRow("Peristalsis", $peristalsis, peristalsisChoices)
                                pickerRow("Genitalia", $genitalia, genitaliaChoices)
                                pickerRow("Neurological", $neurological, neuroChoices)
                                pickerRow("Musculoskeletal", $musculoskeletal, mskChoices)
                                pickerRow("Lymph nodes", $lymphNodes, nodesChoices)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }

                    // Plan
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader("Plan")
                        HStack {
                            Button {
                                generateProblemList()
                            } label: {
                                Label("Generate Problem List", systemImage: "brain.head.profile")
                            }
                            .buttonStyle(.borderedProminent)
                            .help("Build an aggregated problem listing from patient age/sex, complaint, duration, and abnormal findings.")
                            Spacer()
                        }
                        TextEditor(text: $problemListing)
                            .frame(minHeight: 120)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                        TextField("Complementary investigations", text: $complementaryInvestigations, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                        TextField("Working diagnosis", text: $diagnosis)
                            .textFieldStyle(.roundedBorder)
                        TextField("ICD-10", text: $icd10)
                            .textFieldStyle(.roundedBorder)
                        TextEditor(text: $medications)
                            .frame(minHeight: 80)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                        pickerRow("Anticipatory guidance", $anticipatoryGuidance, guidanceChoices)
                        TextField("Comments", text: $comments, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .frame(minWidth: 860, idealWidth: 980, maxWidth: .infinity,
                   minHeight: 580, idealHeight: 720, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveTapped() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .onAppear {
                loadEditingIfNeeded()
            }
        }
    }

    // MARK: - Subviews

    private var complaintBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Select common complaints")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Simple chip-like toggles in rows of 4 for predictable wrapping
            WrappingChips(strings: complaintOptions, selection: $presetComplaints)

            TextField("Other complaints (comma-separated)", text: $otherComplaints)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func pickerRow(_ title: String, _ selection: Binding<String>, _ options: [String]) -> some View {
        HStack {
            Text(title)
                .frame(width: 220, alignment: .leading)
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func multiSelectChips(title: String, options: [String], selection: Binding<Set<String>>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            WrappingChips(strings: options, selection: selection)
        }
    }

    // MARK: - DB Helpers (local insert/update)
    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    private func dbOpen(_ url: URL) throws -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open(url.path, &db) != SQLITE_OK {
            defer { if db != nil { sqlite3_close(db) } }
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SickEpisodeForm.DB", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed: \(msg)"])
        }
        return db
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let s = value, !s.isEmpty {
            sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func insertEpisode(dbURL: URL, patientID: Int64, payload: [String: Any]) throws -> Int64 {
        log.info("insertEpisode → db=\(dbURL.path, privacy: .public), pid=\(patientID)")
        var db: OpaquePointer?
        db = try dbOpen(dbURL)
        defer { if db != nil { sqlite3_close(db) } }

        let sql = """
        INSERT INTO episodes (
          patient_id, user_id, created_at,
          main_complaint, hpi, duration,
          appearance, feeding, breathing, urination, pain, stools, context,
          general_appearance, hydration, heart, color, skin,
          ent, right_ear, left_ear, right_eye, left_eye,
          lungs, abdomen, peristalsis, genitalia,
          neurological, musculoskeletal, lymph_nodes,
          problem_listing, complementary_investigations, diagnosis, icd10, medications,
          anticipatory_guidance, comments
        ) VALUES ( ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? );
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SickEpisodeForm.DB", code: 2, userInfo: [NSLocalizedDescriptionKey: "prepare insert failed: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }

        // 1: patient_id
        sqlite3_bind_int64(stmt, 1, patientID)
        // 2: created_at
        bindText(stmt, 2, isoNow())

        func str(_ k: String) -> String? { payload[k] as? String }

        // 3.. end: follow the column order above
        bindText(stmt, 3,  str("main_complaint"))
        bindText(stmt, 4,  str("hpi"))
        bindText(stmt, 5,  str("duration"))
        bindText(stmt, 6,  str("appearance"))
        bindText(stmt, 7,  str("feeding"))
        bindText(stmt, 8,  str("breathing"))
        bindText(stmt, 9,  str("urination"))
        bindText(stmt, 10, str("pain"))
        bindText(stmt, 11, str("stools"))
        bindText(stmt, 12, str("context"))
        bindText(stmt, 13, str("general_appearance"))
        bindText(stmt, 14, str("hydration"))
        bindText(stmt, 15, str("heart"))
        bindText(stmt, 16, str("color"))
        bindText(stmt, 17, str("skin"))
        bindText(stmt, 18, str("ent"))
        bindText(stmt, 19, str("right_ear"))
        bindText(stmt, 20, str("left_ear"))
        bindText(stmt, 21, str("right_eye"))
        bindText(stmt, 22, str("left_eye"))
        bindText(stmt, 23, str("lungs"))
        bindText(stmt, 24, str("abdomen"))
        bindText(stmt, 25, str("peristalsis"))
        bindText(stmt, 26, str("genitalia"))
        bindText(stmt, 27, str("neurological"))
        bindText(stmt, 28, str("musculoskeletal"))
        bindText(stmt, 29, str("lymph_nodes"))
        bindText(stmt, 30, str("problem_listing"))
        bindText(stmt, 31, str("complementary_investigations"))
        bindText(stmt, 32, str("diagnosis"))
        bindText(stmt, 33, str("icd10"))
        bindText(stmt, 34, str("medications"))
        bindText(stmt, 35, str("anticipatory_guidance"))
        bindText(stmt, 36, str("comments"))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SickEpisodeForm.DB", code: 3, userInfo: [NSLocalizedDescriptionKey: "insert step failed: \(msg)"])
        }
        return sqlite3_last_insert_rowid(db)
    }

    private func updateEpisode(dbURL: URL, episodeID: Int64, payload: [String: Any]) throws {
        var db: OpaquePointer?
        db = try dbOpen(dbURL)
        defer { if db != nil { sqlite3_close(db) } }

        let sql = """
        UPDATE episodes SET
          main_complaint = ?, hpi = ?, duration = ?,
          appearance = ?, feeding = ?, breathing = ?, urination = ?, pain = ?, stools = ?, context = ?,
          general_appearance = ?, hydration = ?, heart = ?, color = ?, skin = ?,
          ent = ?, right_ear = ?, left_ear = ?, right_eye = ?, left_eye = ?,
          lungs = ?, abdomen = ?, peristalsis = ?, genitalia = ?,
          neurological = ?, musculoskeletal = ?, lymph_nodes = ?,
          problem_listing = ?, complementary_investigations = ?, diagnosis = ?, icd10 = ?, medications = ?,
          anticipatory_guidance = ?, comments = ?
        WHERE id = ?;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SickEpisodeForm.DB", code: 4, userInfo: [NSLocalizedDescriptionKey: "prepare update failed: \(msg)"])
        }
        defer { sqlite3_finalize(stmt) }

        func str(_ k: String) -> String? { payload[k] as? String }

        // Follow the order in the UPDATE
        bindText(stmt, 1,  str("main_complaint"))
        bindText(stmt, 2,  str("hpi"))
        bindText(stmt, 3,  str("duration"))
        bindText(stmt, 4,  str("appearance"))
        bindText(stmt, 5,  str("feeding"))
        bindText(stmt, 6,  str("breathing"))
        bindText(stmt, 7,  str("urination"))
        bindText(stmt, 8,  str("pain"))
        bindText(stmt, 9,  str("stools"))
        bindText(stmt, 10, str("context"))
        bindText(stmt, 11, str("general_appearance"))
        bindText(stmt, 12, str("hydration"))
        bindText(stmt, 13, str("heart"))
        bindText(stmt, 14, str("color"))
        bindText(stmt, 15, str("skin"))
        bindText(stmt, 16, str("ent"))
        bindText(stmt, 17, str("right_ear"))
        bindText(stmt, 18, str("left_ear"))
        bindText(stmt, 19, str("right_eye"))
        bindText(stmt, 20, str("left_eye"))
        bindText(stmt, 21, str("lungs"))
        bindText(stmt, 22, str("abdomen"))
        bindText(stmt, 23, str("peristalsis"))
        bindText(stmt, 24, str("genitalia"))
        bindText(stmt, 25, str("neurological"))
        bindText(stmt, 26, str("musculoskeletal"))
        bindText(stmt, 27, str("lymph_nodes"))
        bindText(stmt, 28, str("problem_listing"))
        bindText(stmt, 29, str("complementary_investigations"))
        bindText(stmt, 30, str("diagnosis"))
        bindText(stmt, 31, str("icd10"))
        bindText(stmt, 32, str("medications"))
        bindText(stmt, 33, str("anticipatory_guidance"))
        bindText(stmt, 34, str("comments"))

        sqlite3_bind_int64(stmt, 35, episodeID)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SickEpisodeForm.DB", code: 5, userInfo: [NSLocalizedDescriptionKey: "update step failed: \(msg)"])
        }
        log.info("updateEpisode OK → id=\(episodeID), changes=\(sqlite3_changes(db))")
    }

    /// Ensure the `episodes` table exists with the expected schema.
    private func ensureEpisodesTable(dbURL: URL) throws {
        var db: OpaquePointer?
        db = try dbOpen(dbURL)
        defer { if db != nil { sqlite3_close(db) } }

        let sql = """
        CREATE TABLE IF NOT EXISTS episodes (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          patient_id INTEGER,
          user_id INTEGER,
          created_at TEXT DEFAULT CURRENT_TIMESTAMP,
          main_complaint TEXT,
          hpi TEXT,
          duration TEXT,
          appearance TEXT,
          feeding TEXT,
          breathing TEXT,
          urination TEXT,
          pain TEXT,
          stools TEXT,
          context TEXT,
          general_appearance TEXT,
          hydration TEXT,
          color TEXT,
          skin TEXT,
          ent TEXT,
          right_ear TEXT,
          left_ear TEXT,
          right_eye TEXT,
          left_eye TEXT,
          heart TEXT,
          lungs TEXT,
          abdomen TEXT,
          peristalsis TEXT,
          genitalia TEXT,
          neurological TEXT,
          musculoskeletal TEXT,
          lymph_nodes TEXT,
          problem_listing TEXT,
          complementary_investigations TEXT,
          diagnosis TEXT,
          icd10 TEXT,
          medications TEXT,
          anticipatory_guidance TEXT,
          comments TEXT
        );
        """
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(domain: "SickEpisodeForm.DB", code: 10, userInfo: [NSLocalizedDescriptionKey: "schema ensure failed: \(msg)"])
        }
    }

    /// Debug helper: log count of episodes for patient to verify persistence path.
    private func debugCountEpisodes(dbURL: URL, patientID: Int64) {
        var db: OpaquePointer?
        do { db = try dbOpen(dbURL) } catch {
            log.error("debugCountEpisodes: open failed")
            return
        }
        defer { if db != nil { sqlite3_close(db) } }
        let sql = "SELECT COUNT(*) FROM episodes WHERE patient_id=?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, patientID)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let c = sqlite3_column_int64(stmt, 0)
            log.info("Episodes count for pid \(patientID): \(c)")
        }
    }

    // MARK: - Editing Prefill Helpers

    /// Load the episode from DB if we're in edit mode and prefill the form.
    private func loadEditingIfNeeded() {
        guard let eid = editingEpisodeID,
              let dbURL = appState.currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            return
        }
        if let row = fetchEpisodeRow(dbURL: dbURL, id: Int64(eid)) {
            prefillFromRow(row)
        }
    }

    /// Fetch a single episode row as a string dictionary keyed by column name.
    private func fetchEpisodeRow(dbURL: URL, id: Int64) -> [String: String]? {
        var db: OpaquePointer?
        do { db = try dbOpen(dbURL) } catch { return nil }
        defer { if db != nil { sqlite3_close(db) } }

        let sql = """
        SELECT main_complaint, hpi, duration,
               appearance, feeding, breathing, urination, pain, stools, context,
               general_appearance, hydration, heart, color, skin,
               ent, right_ear, left_ear, right_eye, left_eye,
               lungs, abdomen, peristalsis, genitalia,
               neurological, musculoskeletal, lymph_nodes,
               problem_listing, complementary_investigations, diagnosis, icd10, medications,
               anticipatory_guidance, comments
        FROM episodes
        WHERE id = ?
        LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        func col(_ i: Int32) -> String? {
            if let c = sqlite3_column_text(stmt, i) {
                return String(cString: c)
            }
            return nil
        }

        let keys = [
            "main_complaint","hpi","duration",
            "appearance","feeding","breathing","urination","pain","stools","context",
            "general_appearance","hydration","heart","color","skin",
            "ent","right_ear","left_ear","right_eye","left_eye",
            "lungs","abdomen","peristalsis","genitalia",
            "neurological","musculoskeletal","lymph_nodes",
            "problem_listing","complementary_investigations","diagnosis","icd10","medications",
            "anticipatory_guidance","comments"
        ]
        var out: [String: String] = [:]
        for (idx, key) in keys.enumerated() {
            out[key] = col(Int32(idx)) ?? ""
        }
        return out
    }

    /// Assign picker value only if it exists in the allowed list.
    private func assignPicker(_ value: String?, allowed: [String], assign: (String) -> Void) {
        if let v = value, allowed.contains(v) {
            assign(v)
        }
    }

    /// Split a comma or comma+space separated string, trimmed; filters empty parts.
    private func splitTrim(_ s: String?) -> [String] {
        guard let s = s, !s.isEmpty else { return [] }
        return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Prefill all @State fields from a row dict.
    private func prefillFromRow(_ row: [String: String]) {
        // Complaints → split and map into preset + "other"
        let allComplaints = splitTrim(row["main_complaint"])
        let presetSet = Set(allComplaints.filter { complaintOptions.contains($0) })
        let freeList = allComplaints.filter { !complaintOptions.contains($0) }
        self.presetComplaints = presetSet
        self.otherComplaints = freeList.joined(separator: ", ")

        self.hpi = row["hpi"] ?? ""
        self.duration = row["duration"] ?? ""

        assignPicker(row["appearance"], allowed: appearanceChoices) { self.appearance = $0 }
        assignPicker(row["feeding"],   allowed: feedingChoices)   { self.feeding = $0 }
        assignPicker(row["breathing"], allowed: breathingChoices) { self.breathing = $0 }
        assignPicker(row["urination"], allowed: urinationChoices) { self.urination = $0 }
        assignPicker(row["pain"],      allowed: painChoices)      { self.pain = $0 }
        assignPicker(row["stools"],    allowed: stoolsChoices)    { self.stools = $0 }
        self.context = Set(splitTrim(row["context"]).filter { contextChoices.contains($0) })

        assignPicker(row["general_appearance"], allowed: generalChoices) { self.generalAppearance = $0 }
        assignPicker(row["hydration"], allowed: hydrationChoices) { self.hydration = $0 }
        assignPicker(row["heart"], allowed: heartChoices) { self.heart = $0 }
        assignPicker(row["color"], allowed: colorChoices) { self.color = $0 }
        assignPicker(row["skin"], allowed: skinChoices) { self.skin = $0 }

        let entParts = splitTrim(row["ent"])
        self.ent = Set(entParts.filter { entChoices.contains($0) })
        assignPicker(row["right_ear"], allowed: earChoices) { self.rightEar = $0 }
        assignPicker(row["left_ear"],  allowed: earChoices) { self.leftEar  = $0 }
        assignPicker(row["right_eye"], allowed: eyeChoices) { self.rightEye = $0 }
        assignPicker(row["left_eye"],  allowed: eyeChoices) { self.leftEye  = $0 }
        assignPicker(row["lungs"],     allowed: lungsChoices) { self.lungs = $0 }
        assignPicker(row["abdomen"],   allowed: abdomenChoices) { self.abdomen = $0 }
        assignPicker(row["peristalsis"], allowed: peristalsisChoices) { self.peristalsis = $0 }
        assignPicker(row["genitalia"], allowed: genitaliaChoices) { self.genitalia = $0 }
        assignPicker(row["neurological"], allowed: neuroChoices) { self.neurological = $0 }
        assignPicker(row["musculoskeletal"], allowed: mskChoices) { self.musculoskeletal = $0 }
        assignPicker(row["lymph_nodes"], allowed: nodesChoices) { self.lymphNodes = $0 }

        self.problemListing = row["problem_listing"] ?? ""
        self.complementaryInvestigations = row["complementary_investigations"] ?? ""
        self.diagnosis = row["diagnosis"] ?? ""
        self.icd10 = row["icd10"] ?? ""
        self.medications = row["medications"] ?? ""
        assignPicker(row["anticipatory_guidance"], allowed: guidanceChoices) { self.anticipatoryGuidance = $0 }
        self.comments = row["comments"] ?? ""
    }

    // MARK: - Problem List Generation Helpers

    /// Compute a combined complaint string from preset + free text.
    private func currentMainComplaintString() -> String {
        let free = otherComplaints
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let complaints = Array(presetComplaints).sorted() + free
        return complaints.joined(separator: ", ")
    }

    /// Fetch basic demographics for the active patient from the DB.
    private func fetchPatientDemographics(dbURL: URL, patientID: Int64) -> (first: String?, last: String?, dobISO: String?, sex: String?, vax: String?) {
        var db: OpaquePointer?
        do {
            db = try dbOpen(dbURL)
        } catch {
            return (nil, nil, nil, nil, nil)
        }
        defer { if db != nil { sqlite3_close(db) } }

        let sql = "SELECT first_name, last_name, dob, sex, vaccination_status FROM patients WHERE id = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return (nil, nil, nil, nil, nil)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, patientID)

        if sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ i: Int32) -> String? {
                if let c = sqlite3_column_text(stmt, i) {
                    return String(cString: c)
                }
                return nil
            }
            return (col(0), col(1), col(2), col(3), col(4))
        }
        return (nil, nil, nil, nil, nil)
    }

    /// Render age as a human-friendly string from ISO DOB "YYYY-MM-DD".
    private func ageText(from dobISO: String?) -> String? {
        guard let s = dobISO, !s.isEmpty else { return nil }
        let comps = s.split(separator: "-").map(String.init)
        guard comps.count >= 3,
              let y = Int(comps[0]), let m = Int(comps[1]), let d = Int(comps[2]) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let dob = DateComponents(calendar: cal, year: y, month: m, day: d).date ?? Date()
        let now = Date()
        let diff = cal.dateComponents([.year, .month, .day], from: dob, to: now)
        if let yr = diff.year, yr >= 2 {
            return "\(yr) y"
        } else if let mo = diff.month, mo >= 1 {
            return "\(mo) mo"
        } else if let day = diff.day {
            return "\(day) d"
        }
        return nil
    }

    /// Build an aggregated problem list and place it in `problemListing`.
    private func generateProblemList() {
        var lines: [String] = []

        if let pid = appState.selectedPatientID,
           let dbURL = appState.currentDBURL,
           FileManager.default.fileExists(atPath: dbURL.path) {
            let demo = fetchPatientDemographics(dbURL: dbURL, patientID: Int64(pid))
            if let f = demo.first, let l = demo.last, (!f.isEmpty || !l.isEmpty) {
                lines.append("Patient: \(f) \(l)".trimmingCharacters(in: .whitespaces))
            }
            if let a = ageText(from: demo.dobISO) {
                lines.append("Age: \(a)")
            }
            if let sx = demo.sex, !sx.isEmpty {
                lines.append("Sex: \(sx)")
            }
            if let vax = demo.vax, !vax.isEmpty, vax.lowercased() != "up to date", vax.lowercased() != "up‑to‑date" {
                lines.append("Vaccination status: \(vax)")
            }
        }

        let mc = currentMainComplaintString()
        if !mc.isEmpty { lines.append("Main complaint: \(mc)") }
        if !duration.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("Duration: \(duration) hours")
        }

        // Structured HPI abnormalities
        if appearance != "Well" { lines.append("Appearance: \(appearance)") }
        if feeding != "Normal" { lines.append("Feeding: \(feeding)") }
        if breathing != "Normal" { lines.append("Breathing: \(breathing)") }
        if urination != "Normal" { lines.append("Urination: \(urination)") }
        if pain != "None" { lines.append("Pain: \(pain)") }
        if stools != "Normal" { lines.append("Stools: \(stools)") }
        let ctx = Array(context).filter { $0 != "None" }
        if !ctx.isEmpty { lines.append("Context: \(ctx.sorted().joined(separator: ", "))") }

        // PE abnormalities
        if generalAppearance != "Well" { lines.append("General Appearance: \(generalAppearance)") }
        if hydration != "Normal" { lines.append("Hydration: \(hydration)") }
        if heart != "Normal" { lines.append("Heart: \(heart)") }
        if color != "Normal" { lines.append("Color: \(color)") }
        if skin != "Normal" { lines.append("Skin: \(skin)") }
        if !(ent.count == 1 && ent.contains("Normal")) {
            lines.append("ENT: \(Array(ent).sorted().joined(separator: ", "))")
        }
        if rightEar != "Normal" { lines.append("Right Ear: \(rightEar)") }
        if leftEar  != "Normal" { lines.append("Left Ear: \(leftEar)") }
        if rightEye != "Normal" { lines.append("Right Eye: \(rightEye)") }
        if leftEye  != "Normal" { lines.append("Left Eye: \(leftEye)") }
        if lungs != "Normal" { lines.append("Lungs: \(lungs)") }
        if abdomen != "Normal" { lines.append("Abdomen: \(abdomen)") }
        if peristalsis != "Normal" { lines.append("Peristalsis: \(peristalsis)") }
        if genitalia != "Normal" { lines.append("Genitalia: \(genitalia)") }
        if neurological != "Alert" { lines.append("Neurological: \(neurological)") }
        if musculoskeletal != "Normal" { lines.append("MSK: \(musculoskeletal)") }
        if lymphNodes != "None" { lines.append("Lymph Nodes: \(lymphNodes)") }

        problemListing = lines.joined(separator: "\n")
    }

    // MARK: - Save (commit to db + refresh UI)
    private func saveTapped() {
        let free = otherComplaints
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let complaints = Array(presetComplaints).sorted() + free

        var payload: [String: Any] = [:]
        // Core
        payload["main_complaint"] = complaints.joined(separator: ", ")
        payload["hpi"] = hpi
        payload["duration"] = duration
        // Structured HPI
        payload["appearance"] = appearance
        payload["feeding"] = feeding
        payload["breathing"] = breathing
        payload["urination"] = urination
        payload["pain"] = pain
        payload["stools"] = stools
        payload["context"] = Array(context).sorted().joined(separator: ",")
        // PE
        payload["general_appearance"] = generalAppearance
        payload["hydration"] = hydration
        payload["heart"] = heart
        payload["color"] = color
        payload["skin"] = skin
        payload["ent"] = Array(ent).sorted().joined(separator: ", ")
        payload["right_ear"] = rightEar
        payload["left_ear"] = leftEar
        payload["right_eye"] = rightEye
        payload["left_eye"] = leftEye
        payload["lungs"] = lungs
        payload["abdomen"] = abdomen
        payload["peristalsis"] = peristalsis
        payload["genitalia"] = genitalia
        payload["neurological"] = neurological
        payload["musculoskeletal"] = musculoskeletal
        payload["lymph_nodes"] = lymphNodes
        // Plan
        payload["problem_listing"] = problemListing
        payload["complementary_investigations"] = complementaryInvestigations
        payload["diagnosis"] = diagnosis
        payload["icd10"] = icd10
        payload["medications"] = medications
        payload["anticipatory_guidance"] = anticipatoryGuidance
        payload["comments"] = comments

        let episodeLabel = editingEpisodeID.map(String.init) ?? "new"
        let keysJoined = payload.keys.joined(separator: ",")
        log.info("Save tapped (episode: \(episodeLabel)) payload keys: \(keysJoined)")

        guard let pid = appState.selectedPatientID,
              let dbURL = appState.currentDBURL,
              FileManager.default.fileExists(atPath: dbURL.path) else {
            log.error("Cannot save episode: missing pid or dbURL.")
            return
        }

        log.info("Persisting SickEpisode to DB: \(dbURL.path, privacy: .public) for pid \(pid)")
        do {
            try ensureEpisodesTable(dbURL: dbURL)
        } catch {
            log.error("ensureEpisodesTable failed: \(String(describing: error), privacy: .public)")
        }

        do {
            if let eid = editingEpisodeID {
                try updateEpisode(dbURL: dbURL, episodeID: Int64(eid), payload: payload)
                debugCountEpisodes(dbURL: dbURL, patientID: Int64(pid))
            } else {
                _ = try insertEpisode(dbURL: dbURL, patientID: Int64(pid), payload: payload)
                debugCountEpisodes(dbURL: dbURL, patientID: Int64(pid))
            }

            // Refresh visits/profile and close
            appState.loadVisits(for: pid)
            appState.loadPatientProfile(for: Int64(pid))
            dismiss()
        } catch {
            log.error("Episode save failed: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - Small helpers

private struct SectionHeader: View {
    let title: String
    init(_ t: String) { title = t }
    var body: some View {
        Text(title)
            .font(.headline)
            .padding(.top, 4)
    }
}

/// Minimal wrapping chips component backed by a Set of strings.
private struct WrappingChips: View {
    let strings: [String]
    @Binding var selection: Set<String>

    var body: some View {
        // Use simple flexible rows to avoid heavy layout logic.
        VStack(alignment: .leading, spacing: 8) {
            let rows = stride(from: 0, to: strings.count, by: 4).map {
                Array(strings[$0 ..< min($0 + 4, strings.count)])
            }
            ForEach(rows.indices, id: \.self) { idx in
                HStack(spacing: 8) {
                    ForEach(rows[idx], id: \.self) { s in
                        Toggle(isOn: Binding(
                            get: { selection.contains(s) },
                            set: { on in
                                if on { selection.insert(s) } else { selection.remove(s) }
                            })
                        ) {
                            Text(s)
                        }
                        .toggleStyle(.button)
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

