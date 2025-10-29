//  SidebarView.swift
//  DrsMainApp

import SwiftUI
import OSLog
#if os(macOS)
import AppKit
#endif

struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingNewPatient = false

    private let log = Logger(subsystem: "com.pediai.DrsMainApp", category: "Sidebar")

    var body: some View {
        VStack(spacing: 0) {
            header

            List {
                // MARK: - Recent Bundles
                Section("Recent Bundles") {
                    if appState.recentBundles.isEmpty {
                        Text("No bundles yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.recentBundles, id: \.path) { url in
                            Button {
                                appState.selectBundle(url)
                            } label: {
                                HStack {
                                    Image(systemName: "folder")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(url.lastPathComponent)
                                            .font(.body)
                                        Text(url.path)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .listRowSeparator(.visible)
                            .contextMenu {
                                Button("Reveal in Finder") { revealInFinder(url) }
                                Button("Copy Path") { copyToPasteboard(url.path) }
                            }
                        }
                    }
                } // end Section: Recent Bundles

                // MARK: - Patients
                Section("Patients") {
                    if appState.currentBundleURL == nil {
                        HStack {
                            Text("Select a bundle to load patients")
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                    } else if appState.patients.isEmpty {
                        HStack {
                            Text("No patients in this bundle")
                            Spacer()
                            Button {
                                appState.reloadPatients()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Reload patients from current db.sqlite")
                        }
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.patients) { p in
                            let title = p.alias.isEmpty
                                ? (p.fullName.isEmpty ? "Patient #\(p.id)" : p.fullName)
                                : p.alias

                            HStack {
                                Image(systemName: "person.crop.circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(title)
                                    if !p.fullName.isEmpty && p.fullName != title {
                                        Text(p.fullName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if !p.dobISO.isEmpty || !p.sex.isEmpty {
                                        Text("\(p.dobISO)\(p.sex.isEmpty ? "" : " • \(p.sex)")")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                appState.selectedPatientID = p.id
                                appState.reloadVisitsForSelectedPatient()
                            }
                            .background(
                                appState.selectedPatientID == p.id ? Color.accentColor.opacity(0.12) : .clear
                            )
                        }
                    }
                } // end Section: Patients
            } // end List
            .listStyle(.inset)
            .toolbar { toolbar }
            .sheet(isPresented: $showingNewPatient) {
                NewPatientSheet(appState: appState)
            }
        }
        .frame(minWidth: 240)
    }

    // MARK: - Header
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pedi•AI — Doctor")
                .font(.title3).bold()
            if let active = appState.currentBundleURL {
                Text("Active: \(active.lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No active bundle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Toolbar
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                pickAndAddBundles()
            } label: {
                Label("Add Bundles…", systemImage: "folder.badge.plus")
            }

            Button {
                showingNewPatient = true
            } label: {
                Label("New Patient…", systemImage: "person.badge.plus")
            }
        }
    }

    // MARK: - Actions
    private func pickAndAddBundles() {
        #if os(macOS)
        FilePicker.selectBundles { urls in
            if !urls.isEmpty {
                appState.importBundles(from: urls)
            }
        }
        #endif
    }

    private func revealInFinder(_ url: URL) {
        #if os(macOS)
        FilePicker.revealInFinder(url)
        #endif
    }

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        FilePicker.copyToPasteboard(text)
        #endif
    }
}
