import SQLite3
import FMDB
@preconcurrency import SwiftUI
import Foundation
import UniformTypeIdentifiers
import UIKit
import SQLite
import os

private let log = AppLog.feature("ContentView")
// SupportLog (optional; records only safe tokens)
// SupportLog (optional; records only safe tokens)
// NOTE: SupportLog is @MainActor. These helpers hop to the main actor so they are safe to call
// from synchronous/nonisolated contexts (e.g. view builders, background tasks, callbacks).
@inline(__always)
private func S(_ message: String) {
    Task { @MainActor in
        SupportLog.shared.info(message)
    }
}

@inline(__always)
private func SWarn(_ message: String) {
    Task { @MainActor in
        SupportLog.shared.warn(message)
    }
}

@inline(__always)
private func SError(_ message: String) {
    Task { @MainActor in
        SupportLog.shared.error(message)
    }
}

// MARK: - Localization (file-local)
@inline(__always)
private func L(_ key: String, comment: String = "") -> String {
    NSLocalizedString(key, comment: comment)
}

@inline(__always)
private func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

struct ContentView: SwiftUI.View {
    @State private var extractedFolderURL: URL?
    @State private var bundleAliasLabel: String?
    @State private var bundleDOB: String?
    @State private var bundleFullName: String?
    @State private var showingFileImporter = false
    // File export (Save As…) routing
    @State private var showFileExporter = false
    @State private var exportDoc = ZipFileDocument(data: Data())
    @State private var exportDefaultName = L("patient_viewer.content.export.default_filename", comment: "Default export filename")
    // Unified sheet router (single source of truth for modal sheets)
    enum SheetRoute: Identifiable, Equatable {
        case bundleLibrary
        case settings

        var id: String {
            switch self {
            case .bundleLibrary:
                return "bundleLibrary"
            case .settings:
                return "settings"
            }
        }
    }

    @State private var sheetRoute: SheetRoute? = nil
    // New unified import flow state (BundleIO)
    @State private var pendingImport: BundleIO.Pending? = nil
    @State private var showDuplicateDialog = false
    @State private var importError: String? = nil
    // Cached growth data for the active bundle (avoid re-fetching on every body recompute)
    @State private var growthDBPath: String? = nil
    @State private var cachedPatientSex: String = "M"
    @State private var cachedAllPatientData: [String: [GrowthDataPoint]] = [:]
    @Environment(\.scenePhase) private var scenePhase
    

    init() {
        _extractedFolderURL = State(initialValue: nil)
        _bundleAliasLabel = State(initialValue: nil)
        _bundleDOB = State(initialValue: nil)
        _bundleFullName = State(initialValue: nil)
    }

    

    var body: some SwiftUI.View {
        NavigationView {
            Group {
                if extractedFolderURL == nil {
                    emptyStateView
                } else if let url = extractedFolderURL {
                    activeBundleView(for: url)
                }
            }
            .sheet(item: $sheetRoute, onDismiss: { sheetRoute = nil }) { route in
                switch route {
                case .bundleLibrary:
                    BundleLibraryView(
                        extractedFolderURL: $extractedFolderURL,
                        bundleAlias: Binding(get: { bundleAliasLabel ?? L("patient_viewer.content.placeholder.unknown", comment: "Placeholder: unknown") }, set: { bundleAliasLabel = $0 }),
                        bundleDOB: Binding(get: { bundleDOB ?? L("patient_viewer.content.placeholder.unknown", comment: "Placeholder: unknown") }, set: { bundleDOB = $0 })
                    )

                case .settings:
                    AppSettingsView()
                }
            }
            .fileExporter(
                isPresented: $showFileExporter,
                document: exportDoc,
                contentType: UTType(filenameExtension: "pemr") ?? .data,
                defaultFilename: exportDefaultName
            ) { result in
                switch result {
                case .success(let url):
                    let filename = url.lastPathComponent
                    let fileTok = AppLog.token(filename)
                    log.info("Exported bundle | fileTok=\(fileTok, privacy: .public)")
                    S("EXPORT ok | fileTok=\(fileTok)")
                case .failure(let error):
                    let ns = error as NSError
                    log.error("Export failed | err=\(ns.domain, privacy: .public):\(ns.code, privacy: .public)")
                    SError("EXPORT failed | err=\(ns.domain):\(ns.code)")
                }
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [
                    UTType(filenameExtension: "pemr") ?? .data,
                    .zip
                ],
                allowsMultipleSelection: false
            ) { result in
                let t0 = Date()

                switch result {
                case .failure(let error):
                    let ns = error as NSError
                    log.error("File import picker failed | err=\(ns.domain, privacy: .public):\(ns.code, privacy: .public)")
                    SError("IMPORT picker failed | err=\(ns.domain):\(ns.code)")
                    importError = error.localizedDescription

                case .success(let urls):
                    guard let selectedFile = urls.first else {
                        SWarn("IMPORT no file selected")
                        return
                    }

                    let ext = selectedFile.pathExtension.lowercased()
                    S("IMPORT tap | ext=\(ext)")
                    S("IMPORT processing")

                    do {
                        let outcome = try BundleIO.ImportService.handleZipImport(selectedFile)
                        let elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)

                        switch outcome {
                        case .needsOverwrite(let pending):
                            pendingImport = pending
                            showDuplicateDialog = true
                            S("IMPORT duplicate dialog shown")

                            let destTok = AppLog.bundleRef(pending.destinationURL)
                            let reason = pending.matchedOn ?? "unknown"
                            S("IMPORT duplicate | matchedOn=\(reason) dest=\(destTok) elapsedMs=\(elapsedMs)")

                        case .activated(let activation):
                            let tok = AppLog.bundleRef(activation.activeBase)
                            S("IMPORT ok | bundle=\(tok) elapsedMs=\(elapsedMs)")

                            // Reset first to force reload even if it's the same path
                            extractedFolderURL = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                                extractedFolderURL = activation.activeBase
                                bundleAliasLabel = activation.alias
                                bundleDOB = activation.dob
                            }
                        }

                    } catch {
                        let ns = error as NSError
                        log.error("Import failed | err=\(ns.domain, privacy: .public):\(ns.code, privacy: .public)")
                        SError("IMPORT failed | err=\(ns.domain):\(ns.code)")
                        importError = error.localizedDescription
                    }
                }
            }
            .confirmationDialog(L("patient_viewer.content.import.duplicate.title", comment: "Import: duplicate bundle"),
                                isPresented: $showDuplicateDialog) {
                Button(L("patient_viewer.content.import.duplicate.overwrite", comment: "Import: overwrite bundle"), role: .destructive) {
                    guard let p = pendingImport else { return }
                    S("IMPORT overwrite confirmed")
                    S("IMPORT overwrite processing")
                    let t1 = Date()
                    do {
                        let activation = try BundleIO.ImportService.confirmOverwrite(p)
                        let elapsedMs = Int(Date().timeIntervalSince(t1) * 1000)
                        S("IMPORT overwrite ok | bundle=\(AppLog.bundleRef(activation.activeBase)) elapsedMs=\(elapsedMs)")
                        pendingImport = nil
                        // Reset first to force reload even if it's the same path
                        extractedFolderURL = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                            extractedFolderURL = activation.activeBase
                            bundleAliasLabel = activation.alias
                            bundleDOB = activation.dob
                        }
                    } catch {
                        let ns = error as NSError
                        log.error("Overwrite import failed | err=\(ns.domain, privacy: .public):\(ns.code, privacy: .public)")
                        SError("IMPORT overwrite failed | err=\(ns.domain):\(ns.code)")
                        importError = error.localizedDescription
                    }
                }
                Button(L("patient_viewer.content.common.cancel", comment: "Common: cancel"), role: .cancel) {
                    SWarn("IMPORT overwrite cancelled")
                    if let p = pendingImport { BundleIO.ImportService.cancelOverwrite(p) }
                    S("IMPORT overwrite dialog dismissed")
                    pendingImport = nil
                }
            }
            .alert(L("patient_viewer.content.error.title", comment: "Alert title"), isPresented: .constant(importError != nil), actions: {
                Button(L("patient_viewer.content.common.ok", comment: "Common: OK")) {
                    SWarn("IMPORT error dismissed")
                    importError = nil
                }
            }, message: {
                Text(importError ?? "")
            })
            .appBackground()
            .appNavBarBackground()
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .background, .inactive:
                    saveActiveBundleToPersistent()
                default:
                    break
                }
            }
            .onChange(of: extractedFolderURL) { _, newURL in
                guard let url = newURL else {
                    bundleFullName = nil
                    growthDBPath = nil
                    cachedPatientSex = "M"
                    cachedAllPatientData = [:]
                    return
                }

                let dbPath = url.appendingPathComponent("db.sqlite").path

                // Cache patient full name (existing behavior)
                bundleFullName = PatientHeaderLoader.fetchPatientFullName(dbPath: dbPath)

                // Cache growth series once per DB path (prevents double/extra fetches due to SwiftUI recompute)
                if growthDBPath != dbPath {
                    growthDBPath = dbPath
                    let (sex, all) = GrowthDataFetcher.fetchAllGrowthData(dbPath: dbPath)
                    cachedPatientSex = sex
                    cachedAllPatientData = all
                }
            }
        }
    }

    @ViewBuilder
    private var emptyStateView: some SwiftUI.View {
        VStack(spacing: 32) {
            // Header / intro
            VStack(alignment: .leading, spacing: 10) {
                CareViewKidsMark(style: .compact)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(L("patient_viewer.content.nav_title", comment: "Navigation title"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(L("patient_viewer.content.intro", comment: "Intro text"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal)
            .padding(.top, 24)

            // Action cards
            VStack(spacing: 16) {
                // Load new bundle from device
                Button {
                    S("UI open file importer")
                    showingFileImporter = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.title2)
                            .frame(width: 32, height: 32)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("patient_viewer.content.action.load_new.title", comment: "Empty state action title"))
                                .font(.headline)
                            Text(L("patient_viewer.content.action.load_new.subtitle", comment: "Empty state action subtitle"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding()
                    .frame(maxWidth: 520)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(AppTheme.card)
                            .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 4)
                    )
                }
                .buttonStyle(.plain)

                // Load from saved bundles
                Button {
                    S("UI open bundle library")
                    sheetRoute = .bundleLibrary
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "books.vertical.fill")
                            .font(.title2)
                            .frame(width: 32, height: 32)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("patient_viewer.content.action.load_saved.title", comment: "Empty state action title"))
                                .font(.headline)
                            Text(L("patient_viewer.content.action.load_saved.subtitle", comment: "Empty state action subtitle"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding()
                    .frame(maxWidth: 520)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(AppTheme.card)
                            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 3)
                    )
                }
                .buttonStyle(.plain)

                // Settings
                Button {
                    sheetRoute = .settings
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .frame(width: 32, height: 32)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("patient_viewer.content.action.settings.title", comment: "Empty state action title"))
                                .font(.headline)
                            Text(L("patient_viewer.content.action.settings.subtitle", comment: "Empty state action subtitle"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding()
                    .frame(maxWidth: 520)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(AppTheme.card)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.12), lineWidth: 0.8)
                            )
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appBackground()
    }

    @ViewBuilder
    private func activeBundleView(for url: URL) -> some SwiftUI.View {
        // Precompute DB-related values once
        let dbPath = url.appendingPathComponent("db.sqlite").path
        let patientSex = cachedPatientSex
        let allPatientData = cachedAllPatientData
        let patientId = GrowthDataFetcher.getPatientId(from: dbPath) ?? -1
        let alias = bundleAliasLabel ?? L("patient_viewer.content.placeholder.unknown_patient", comment: "Placeholder: unknown patient")
        let dob = bundleDOB ?? L("patient_viewer.content.placeholder.unknown_dob", comment: "Placeholder: unknown date of birth")
        let fullName = bundleFullName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = (fullName?.isEmpty == false) ? fullName! : alias

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Brand header (same “title-under-logo” as empty state)
                VStack(alignment: .leading, spacing: 10) {
                    CareViewKidsMark(style: .compact)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(L("patient_viewer.content.nav_title", comment: "Navigation title"))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Patient header card
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.black)
                                .frame(width: 56, height: 56)

                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundColor(.white)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayName)
                                .font(.title2.bold())
                                .lineLimit(2)

                            // Keep alias visible when we also show full name.
                            if let fn = fullName, !fn.isEmpty {
                                Text(alias)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }

                            Text(dob)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }

                    if !patientSex.isEmpty {
                        Text(LF("patient_viewer.content.patient.sex", patientSex))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(AppTheme.patientHeaderCard)
                        .shadow(color: Color.black.opacity(0.06), radius: 10, x: 0, y: 6)
                )

                // Action cards
                VStack(spacing: 16) {
                    // Visits
                    NavigationLink(
                        destination: VisitListView(dbURL: url)
                    ) {
                        ActionCard(
                            systemImage: "list.bullet.rectangle",
                            title: L("patient_viewer.content.card.visits.title", comment: "Visits card title"),
                            subtitle: L("patient_viewer.content.card.visits.subtitle", comment: "Visits card subtitle"),
                            background: AppTheme.card
                        )
                    }
                    .buttonStyle(.plain)

                    // Growth chart
                    NavigationLink(
                        destination: GrowthChartScreen(
                            patientSex: patientSex,
                            allPatientData: allPatientData
                        )
                    ) {
                        ActionCard(
                            systemImage: "chart.bar.xaxis",
                            title: L("patient_viewer.content.card.growth.title", comment: "Growth card title"),
                            subtitle: L("patient_viewer.content.card.growth.subtitle", comment: "Growth card subtitle"),
                            background: AppTheme.card
                        )
                    }
                    .buttonStyle(.plain)

                    // Parent notes (only if we have a valid ID)
                    if patientId >= 0 {
                        NavigationLink(
                            destination:
                                ParentNotesView(
                                    dbURL: url,
                                    patientId: patientId
                                )
                                .id(patientId)
                                .onAppear {
                                    log.debug("🧠 Passing patient ID to ParentNotesView: \(patientId, privacy: .public)")
                                }
                        ) {
                            ActionCard(
                                systemImage: "text.bubble.fill",
                                title: L("patient_viewer.content.card.parent_notes.title", comment: "Parent notes card title"),
                                subtitle: L("patient_viewer.content.card.parent_notes.subtitle", comment: "Parent notes card subtitle"),
                                background: AppTheme.card
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // Documents
                    NavigationLink(
                        destination: PatientDocumentsView(dbURL: url)
                    ) {
                        ActionCard(
                            systemImage: "paperclip",
                            title: L("patient_viewer.content.card.documents.title", comment: "Documents card title"),
                            subtitle: L("patient_viewer.content.card.documents.subtitle", comment: "Documents card subtitle"),
                            background: AppTheme.card
                        )
                    }
                    .buttonStyle(.plain)

                    // Export
                    NavigationLink(
                        destination: {
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
                        }()
                    ) {
                        ActionCard(
                            systemImage: "square.and.arrow.up",
                            title: L("patient_viewer.content.card.export.title", comment: "Export card title"),
                            subtitle: L("patient_viewer.content.card.export.subtitle", comment: "Export card subtitle"),
                            background: AppTheme.card
                        )
                    }
                    .buttonStyle(.plain)
                }

                // Clear bundle (destructive) – simple but clear
                VStack(alignment: .leading, spacing: 8) {
                    Button(role: .destructive) {
                        clearActiveBundle()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "trash")
                            Text(L("patient_viewer.content.clear_button", comment: "Clear bundle button"))
                        }
                        .font(.subheadline.weight(.semibold))
                    }

                    Text(L("patient_viewer.content.clear_note", comment: "Clear bundle note"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)
            }
            .padding()
        }
        .appBackground()
    }

    // MARK: - Clear helper (logic unchanged, just extracted for reuse)

    private func clearActiveBundle() {
        // Always persist current ActiveBundle first
        saveActiveBundleToPersistent()
        if let url = extractedFolderURL {
            // Confirm DB is present before clearing (avoid logging absolute paths)
            let dbURL = url.appendingPathComponent("db.sqlite")
            log.debug("Pre-clear check: confirming DB exists.")

            let exists = FileManager.default.fileExists(atPath: dbURL.path)
            let dbRef = AppLog.dbRef(dbURL)

            if exists {
                log.info("Pre-clear check OK | db=\(dbRef, privacy: .public)")
            } else {
                log.error("Pre-clear check FAILED (missing DB) | db=\(dbRef, privacy: .public)")
            }

            log.debug("Ensuring only temporary bundle is cleared. Persistent bundles remain untouched.")

            // Only remove volatile temporary folders, not persistent ActiveBundle/{alias_label}
            let path = url.path
            let folderLabel = url.lastPathComponent

            if path.contains("tmp") || path.contains("Temporary") {
                try? FileManager.default.removeItem(at: url)
                log.info("Cleared volatile bundle | folder=\(folderLabel, privacy: .public)")
                log.debug("Cleared volatile bundle | bundle=\(AppLog.bundleRef(url), privacy: .public)")
            } else {
                log.debug("Skipped clearing persistent ActiveBundle | bundle=\(AppLog.bundleRef(url), privacy: .public)")
            }
        }
        // Flush DB to disk before clearing
        if let url = extractedFolderURL {
            let dbPath = url.appendingPathComponent("db.sqlite").path
            let dbURL = url.appendingPathComponent("db.sqlite")
            log.debug("Forcing DB flush before clear | db=\(AppLog.dbRef(dbURL), privacy: .public)")
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
            let fileTok = AppLog.token(destDB.lastPathComponent)
            log.info("Saved db.sqlite to persistent | fileTok=\(fileTok, privacy: .public)")

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

            // Log-safe reference (no alias / full path)
            log.info("Saved active bundle back to persistent | bundle=\(AppLog.bundleRef(persistentAlias), privacy: .public)")
        } catch {
            let ns = error as NSError
            log.error("Save to persistent failed | err=\(ns.domain, privacy: .public):\(ns.code, privacy: .public)")
            log.debug("Save to persistent failed | detail=\(ns.localizedDescription, privacy: .private)")
        }
    }
}

// MARK: - Brand mark (in-app)

private struct CareViewKidsMark: SwiftUI.View {
    enum Style {
        case large
        case compact

        var font: SwiftUI.Font {
            switch self {
            case .large:
                return .system(.title2, design: .default).weight(.bold)
            case .compact:
                return .system(.headline, design: .default).weight(.semibold)
            }
        }

        var paddingX: CGFloat {
            switch self {
            case .large: return 16
            case .compact: return 12
            }
        }

        var paddingY: CGFloat {
            switch self {
            case .large: return 8
            case .compact: return 6
            }
        }
    }

    let style: Style

    var body: some SwiftUI.View {
        HStack(spacing: 8) {
            Text("CareView")
                .font(style.font)
                .foregroundStyle(.primary)

            Text("Kids")
                .font(style.font)
                .italic()
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, style.paddingX)
        .padding(.vertical, style.paddingY)
        .background(
            Capsule(style: .continuous)
                .fill(Color(.systemGray6))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
        )
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .fixedSize(horizontal: false, vertical: false)
        .accessibilityLabel(Text("CareView Kids"))
    }
}

// Reusable black badge-style card used in the active patient dashboard
private struct ActionCard: SwiftUI.View {
    let systemImage: String
    let title: String
    let subtitle: String
    let background: Color

    var body: some SwiftUI.View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.systemGray6))
                    .frame(width: 48, height: 48)

                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(background)
                .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 4)
        )
    }
}

// Simple FileDocument wrapper for exporting the generated .peMR bundle
struct ZipFileDocument: SwiftUI.FileDocument {
    static var readableContentTypes: [UTType] {
        if let pemr = UTType(filenameExtension: "pemr") {
            return [pemr]
        } else {
            return [.data]
        }
    }

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
