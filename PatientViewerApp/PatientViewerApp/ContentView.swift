import SQLite3
import FMDB
@preconcurrency import SwiftUI
import Foundation
import UniformTypeIdentifiers
import UIKit
import SQLite
import os

private let log = Logger(subsystem: "Yunastic.PatientViewerApp", category: "ContentView")

struct ContentView: SwiftUI.View {
    @State private var extractedFolderURL: URL?
    @State private var bundleAliasLabel: String?
    @State private var bundleDOB: String?
    @State private var showingFileImporter = false
    // File export (Save As…) routing
    @State private var showFileExporter = false
    @State private var exportDoc = ZipFileDocument(data: Data())
    @State private var exportDefaultName = "patientviewer"
    // Unified sheet router (single source of truth for modal sheets)
    enum SheetRoute: Identifiable, Equatable {
        case bundleLibrary

        var id: String {
            switch self {
            case .bundleLibrary:
                return "bundleLibrary"
            }
        }
    }

    @State private var sheetRoute: SheetRoute? = nil
    // New unified import flow state (BundleIO)
    @State private var pendingImport: BundleIO.Pending? = nil
    @State private var showDuplicateDialog = false
    @State private var importError: String? = nil
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _extractedFolderURL = State(initialValue: nil)
        _bundleAliasLabel = State(initialValue: nil)
        _bundleDOB = State(initialValue: nil)
    }

    var body: some SwiftUI.View {
        NavigationView {
            VStack {
                if extractedFolderURL == nil {
                    Button("📁 Load New Bundle from Device") {
                        showingFileImporter = true
                    }
                    .padding()

                    Button("📚 Load from Saved Bundles") {
                        sheetRoute = .bundleLibrary
                    }
                    .padding()
                } else {
                    if let aliasLabel = bundleAliasLabel {
                        Text("👤 Active patient: \(aliasLabel)")
                            .font(.headline)
                            .foregroundColor(.blue)
                            .padding(.bottom, 4)
                    }

                

                    

                    if let url = extractedFolderURL {
                        NavigationLink("➡️ Next: View Visits", destination: VisitListView(dbURL: url))
                            .padding(.top)

                        let dbPath = url.appendingPathComponent("db.sqlite").path
                        let (patientSex, allPatientData) = GrowthDataFetcher.fetchAllGrowthData(dbPath: dbPath)
                        let patientId = GrowthDataFetcher.getPatientId(from: dbPath) ?? -1

                        NavigationLink("📈 View Growth Chart (test)", destination:
                            GrowthChartScreen(
                                patientSex: patientSex,
                                allPatientData: allPatientData
                            )
                        )
                        .padding(.top)

                        if patientId >= 0 {
                            NavigationLink(destination:
                                ParentNotesView(
                                    dbURL: url,
                                    patientId: patientId
                                )
                                .id(patientId)
                                .onAppear {
                                    log.debug("🧠 Passing patient ID to ParentNotesView: \(patientId, privacy: .public)")
                                }
                            ) {
                                Text("📝 Parent Notes")
                            }
                            .padding(.top)
                        }

                        NavigationLink("📎 Patient Documents", destination: PatientDocumentsView(dbURL: url))
                            .padding(.top)

                        NavigationLink("📤 Export Bundle", destination: {
                            ExportBundleView(dbURL: url, onShare: { shareURL in
                                do {
                                    let data = try Data(contentsOf: shareURL)
                                    // Use the exported filename (without path) as default if available
                                    exportDefaultName = shareURL.deletingPathExtension().lastPathComponent
                                    exportDoc = ZipFileDocument(data: data)
                                    showFileExporter = true
                                } catch {
                                    log.error("Failed to prepare document for export: \(error.localizedDescription, privacy: .public)")
                                }
                            })
                        })
                            .padding(.top)


                        Button("🗑 Clear Active Bundle") {
                            // Always persist current ActiveBundle first
                            saveActiveBundleToPersistent()
                            if let url = extractedFolderURL {
                                // Confirm persistent DB is written before clearing
                                let dbPath = url.appendingPathComponent("db.sqlite").path
                                log.debug("Pre-clear check: Confirming persistent DB exists and is intact.")
                                if FileManager.default.fileExists(atPath: dbPath) {
                                    log.info("Persistent DB file exists at \(dbPath, privacy: .public)")
                                } else {
                                    log.error("Persistent DB file is MISSING at \(dbPath, privacy: .public)")
                                }
                                log.debug("Ensuring only temporary bundle is cleared. Persistent bundles remain untouched.")

                                // Only remove volatile temporary folders, not persistent ActiveBundle/{alias_label}
                                let path = url.path
                                if path.contains("tmp") || path.contains("Temporary") {
                                    try? FileManager.default.removeItem(at: url)
                                    log.info("Cleared volatile bundle at \(path, privacy: .public)")
                                } else {
                                    log.debug("Skipped clearing persistent ActiveBundle at \(path, privacy: .public)")
                                }
                            }
                            // Flush DB to disk before clearing
                            if let url = extractedFolderURL {
                                let dbPath = url.appendingPathComponent("db.sqlite").path
                                log.debug("Forcing DB flush before clear at: \(dbPath, privacy: .public)")
                                let db = FMDatabase(path: dbPath)
                                if db.open() {
                                    db.executeUpdate("VACUUM;", withArgumentsIn: [])
                                    db.close()
                                    log.info("DB flushed using VACUUM.")
                                } else {
                                    log.error("Failed to open DB for flushing.")
                                }
                            }
                            extractedFolderURL = nil
                            bundleAliasLabel = nil
                            bundleDOB = nil
                            sheetRoute = nil

                            // Force reloading the same bundle path later
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                                extractedFolderURL = nil
                            }
                        }
                        .foregroundColor(.red)
                        .padding(.top, 20)
                    }
                }
            }
            .sheet(item: $sheetRoute, onDismiss: { sheetRoute = nil }) { route in
                switch route {
                case .bundleLibrary:
                    BundleLibraryView(
                        extractedFolderURL: $extractedFolderURL,
                        bundleAlias: Binding(get: { bundleAliasLabel ?? "Unknown" }, set: { bundleAliasLabel = $0 }),
                        bundleDOB: Binding(get: { bundleDOB ?? "Unknown" }, set: { bundleDOB = $0 })
                    )
                }
            }
            .fileExporter(
                isPresented: $showFileExporter,
                document: exportDoc,
                contentType: .zip,
                defaultFilename: exportDefaultName
            ) { result in
                switch result {
                case .success(let url):
                    log.info("Exported zip to: \(url.path, privacy: .public)")
                case .failure(let error):
                    log.error("Export failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.zip],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let selectedFile = try result.get().first else { return }

                    let outcome = try BundleIO.ImportService.handleZipImport(selectedFile)
                    switch outcome {
                    case .activated(let activation):
                        // Reset first to force reload even if it's the same path
                        extractedFolderURL = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                            extractedFolderURL = activation.activeBase
                            bundleAliasLabel = activation.alias
                            bundleDOB = activation.dob
                        }
                    case .needsOverwrite(let p):
                        pendingImport = p
                        showDuplicateDialog = true
                    }
                } catch {
                    log.error("Import failed: \(error.localizedDescription, privacy: .public)")
                    importError = error.localizedDescription
                }
            }
            .confirmationDialog("A bundle for this patient already exists.",
                                isPresented: $showDuplicateDialog) {
                Button("Overwrite (archive previous)", role: .destructive) {
                    guard let p = pendingImport else { return }
                    do {
                        let activation = try BundleIO.ImportService.confirmOverwrite(p)
                        pendingImport = nil
                        // Reset first to force reload even if it's the same path
                        extractedFolderURL = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                            extractedFolderURL = activation.activeBase
                            bundleAliasLabel = activation.alias
                            bundleDOB = activation.dob
                        }
                    } catch {
                        log.error("Overwrite import failed: \(error.localizedDescription, privacy: .public)")
                        importError = error.localizedDescription
                    }
                }
                Button("Cancel", role: .cancel) {
                    if let p = pendingImport { BundleIO.ImportService.cancelOverwrite(p) }
                    pendingImport = nil
                }
            }
            .alert("Error", isPresented: .constant(importError != nil), actions: {
                Button("OK") { importError = nil }
            }, message: {
                Text(importError ?? "")
            })
            .navigationTitle("Patient Viewer")
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .background, .inactive:
                    saveActiveBundleToPersistent()
                default:
                    break
                }
            }
        }
    }

    private func saveActiveBundleToPersistent() {
        guard let activeURL = extractedFolderURL else {
            log.debug("No active bundle to save.")
            return
        }
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let alias = activeURL.lastPathComponent
        let persistentAlias = docs
            .appendingPathComponent("PersistentBundles", isDirectory: true)
            .appendingPathComponent(alias, isDirectory: true)

        do {
            // Ensure destination folder exists
            if !fm.fileExists(atPath: persistentAlias.path) {
                try fm.createDirectory(at: persistentAlias, withIntermediateDirectories: true)
            }

            // Flush DB (merge WAL and compact) before copying
            let srcDB = activeURL.appendingPathComponent("db.sqlite")
            let db = FMDatabase(path: srcDB.path)
            if db.open() {
                _ = db.executeStatements("PRAGMA wal_checkpoint(FULL); VACUUM;")
                db.close()
                log.debug("DB checkpoint & vacuum performed before save.")
            } else {
                log.error("Failed to open DB for checkpoint before save.")
            }

            // Copy db.sqlite
            let destDB = persistentAlias.appendingPathComponent("db.sqlite")
            if fm.fileExists(atPath: destDB.path) {
                try fm.removeItem(at: destDB)
            }
            try fm.copyItem(at: srcDB, to: destDB)
            log.info("Saved db.sqlite to persistent: \(destDB.path, privacy: .public)")

            // Copy docs folder if present (replace atomically)
            let srcDocs = activeURL.appendingPathComponent("docs", isDirectory: true)
            if fm.fileExists(atPath: srcDocs.path) {
                let destDocs = persistentAlias.appendingPathComponent("docs", isDirectory: true)
                if fm.fileExists(atPath: destDocs.path) {
                    try fm.removeItem(at: destDocs)
                }
                try fm.copyItem(at: srcDocs, to: destDocs)
                log.info("Saved docs/ to persistent.")
            }

            // Optional: copy manifest.json if present at root
            let srcManifest = activeURL.appendingPathComponent("manifest.json")
            if fm.fileExists(atPath: srcManifest.path) {
                let destManifest = persistentAlias.appendingPathComponent("manifest.json")
                if fm.fileExists(atPath: destManifest.path) {
                    try fm.removeItem(at: destManifest)
                }
                try fm.copyItem(at: srcManifest, to: destManifest)
                log.info("Saved manifest.json to persistent.")
            }

            log.info("Saved active bundle back to persistent at: \(persistentAlias.path, privacy: .public)")
        } catch {
            log.error("Save to persistent failed: \(String(describing: error), privacy: .public)")
        }
    }
}

// Simple FileDocument wrapper for exporting the generated .zip
struct ZipFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        // Not used for exporting; provide empty data for formality
        self.data = Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
