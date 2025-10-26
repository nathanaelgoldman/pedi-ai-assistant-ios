//
//  SidebarView.swift
//  DrsMainApp
//
//  Created by yunastic on 10/26/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    // File picking / sheets
    @State private var isImportingFolder = false
    @State private var showNewPatientSheet = false
    @State private var sheetError: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $appState.selection) {
                Section("Main") {
                    Label("Dashboard", systemImage: "speedometer")
                        .tag(SidebarSelection.dashboard)

                    Label("Patients", systemImage: "person.3")
                        .tag(SidebarSelection.patients)

                    Label("Imports", systemImage: "tray.and.arrow.down")
                        .tag(SidebarSelection.imports)
                }

                if !appState.recentBundles.isEmpty {
                    Section("Recent Bundles") {
                        ForEach(appState.recentBundles, id: \.self) { url in
                            Button {
                                appState.selectBundle(url)
                            } label: {
                                HStack {
                                    Image(systemName: "externaldrive")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(url.lastPathComponent)
                                            .lineLimit(1)
                                        Text(url.path)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Reveal in Finder") {
#if os(macOS)
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
#endif
                                }
                                Button("Remove from Recents") {
                                    removeFromRecents(url)
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(titleText)
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        isImportingFolder = true
                    } label: {
                        Label("Open Bundle…", systemImage: "folder.badge.plus")
                    }

                    Button {
                        showNewPatientSheet = true
                    } label: {
                        Label("New Patient…", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
            // SwiftUI folder picker (macOS)
            .fileImporter(
                isPresented: $isImportingFolder,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let url):
                    // Accept either bundle root or a subfolder; we just record the folder chosen.
                    appState.selectBundle(url)
                case .failure(let err):
                    sheetError = err.localizedDescription
                }
            }
            .sheet(isPresented: $showNewPatientSheet) {
                NewPatientSheet(
                    isPresented: $showNewPatientSheet,
                    onCreate: { alias, fullName, dob, sex in
                        do {
                            let parent = try defaultPatientsRoot()
                            _ = try appState.createNewPatient(
                                into: parent,
                                alias: alias,
                                fullName: fullName.isEmpty ? nil : fullName,
                                dob: dob,
                                sex: sex.rawValue
                            )
                        } catch {
                            sheetError = error.localizedDescription
                        }
                    }
                )
                .frame(minWidth: 480, minHeight: 380)
            }
            .alert("Error", isPresented: .constant(sheetError != nil), actions: {
                Button("OK") { sheetError = nil }
            }, message: {
                Text(sheetError ?? "")
            })

        } detail: {
            DetailRouter(selection: appState.selection)
        }
    }

    private var titleText: String {
        if let url = appState.currentBundleURL {
            return "Dr’s Assistant — \(url.lastPathComponent)"
        } else {
            return "Dr’s Assistant"
        }
    }

    private func removeFromRecents(_ url: URL) {
        let key = "recentBundlePaths"
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        UserDefaults.standard.set(paths, forKey: key)
        appState.recentBundles = paths.map { URL(fileURLWithPath: $0) }
    }

    private func defaultPatientsRoot() throws -> URL {
        let fm = FileManager.default
#if os(macOS)
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
#else
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
#endif
        let root = docs.appendingPathComponent("PediaPatients", isDirectory: true)
        if !fm.fileExists(atPath: root.path) {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }
}

private struct DetailRouter: View {
    let selection: SidebarSelection?

    var body: some View {
        switch selection {
        case .dashboard:
            DashboardView()

        case .patients:
            PatientsPlaceholder()

        case .imports:
            ImportsPlaceholder()

        case .none:
            Text("Select a section")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct DashboardView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.system(size: 48, weight: .regular))
            Text("Welcome to DrsMainApp")
                .font(.title2.weight(.semibold))
            Text("We’ll wire features in incrementally.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PatientsPlaceholder: View {
    var body: some View {
        Text("Patients area — coming next")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ImportsPlaceholder: View {
    var body: some View {
        Text("Bundle imports — coming next")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - New Patient sheet

private struct NewPatientSheet: View {
    enum Sex: String, CaseIterable, Identifiable {
        case unknown = "U"
        case male = "M"
        case female = "F"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .unknown: return "Unknown"
            case .male: return "Male"
            case .female: return "Female"
            }
        }
    }

    @Binding var isPresented: Bool
    var onCreate: (_ alias: String, _ fullName: String, _ dob: Date?, _ sex: Sex) -> Void

    @State private var alias: String = ""
    @State private var fullName: String = ""
    @State private var hasDOB: Bool = false
    @State private var dob: Date = Date()
    @State private var sex: Sex = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack {
                Text("New Patient")
                    .font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 16)

            Divider().padding(.top, 12)

            Form {
                Section("Identity") {
                    TextField("Alias (required, e.g. “Teal Robin”)", text: $alias)
                    TextField("Full name (optional)", text: $fullName)
                    Picker("Sex", selection: $sex) {
                        ForEach(Sex.allCases) { s in
                            Text(s.label).tag(s)
                        }
                    }
                    Toggle("Set date of birth", isOn: $hasDOB)
                    if hasDOB {
                        DatePicker("DOB", selection: $dob, displayedComponents: .date)
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Button("Cancel") { isPresented = false }
                        Button("Create") {
                            let finalDOB: Date? = hasDOB ? dob : nil
                            onCreate(alias, fullName, finalDOB, sex)
                            isPresented = false
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
}
