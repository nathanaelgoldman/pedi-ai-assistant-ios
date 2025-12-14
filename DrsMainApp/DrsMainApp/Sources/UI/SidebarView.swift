//  SidebarView.swift
//  DrsMainApp

import SwiftUI
import Foundation
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
                Section(NSLocalizedString("sidebar.section.recentBundles",
                                          comment: "Sidebar section title for recent peMR bundles")) {
                    if appState.recentBundles.isEmpty {
                        Text(NSLocalizedString("sidebar.recent.empty",
                                               comment: "Shown when there are no recent bundles"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.recentBundles, id: \.path) { url in
                            let summary = appState.buildBundleSidebarSummary(for: url)
                            let isActive = appState.currentBundleURL?.standardizedFileURL == url.standardizedFileURL

                            Button {
                                if appState.currentBundleURL != url {
                                    appState.selectBundle(url)
                                }
                            } label: {
                                bundleRowContent(
                                    summary: summary,
                                    isActive: isActive,
                                    fileName: url.deletingPathExtension().lastPathComponent
                                )
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .listRowSeparator(.visible)
                            .contextMenu {
                                Button(
                                    NSLocalizedString("sidebar.context.revealInFinder",
                                                      comment: "Context menu action to reveal the bundle in Finder")
                                ) {
                                    revealInFinder(url)
                                }
                                Button(
                                    NSLocalizedString("sidebar.context.copyPath",
                                                      comment: "Context menu action to copy the bundle path to the clipboard")
                                ) {
                                    copyToPasteboard(url.path)
                                }
                            }
                        }
                    }
                } // end Section: Recent Bundles

                // MARK: - Patients
                Section(NSLocalizedString("sidebar.section.patients",
                                          comment: "Sidebar section title for patients")) {
                    if appState.currentBundleURL == nil {
                        HStack {
                            Text(NSLocalizedString("sidebar.patients.noBundle",
                                                   comment: "Shown when no bundle is selected yet"))
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                    } else if appState.patients.isEmpty {
                        HStack {
                            Text(NSLocalizedString("sidebar.patients.empty",
                                                   comment: "Shown when the selected bundle has no patients"))
                            Spacer()
                            Button {
                                appState.reloadPatients()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help(NSLocalizedString("sidebar.patients.reloadHelp",
                                                    comment: "Help text for reloading patients from the current database"))
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
            Text(NSLocalizedString("sidebar.header.title",
                                   comment: "Main sidebar header title (doctor app)"))
                .font(.title3).bold()
            if let active = appState.currentBundleURL {
                Text(
                    String(
                        format: NSLocalizedString("sidebar.header.active",
                                                  comment: "Label showing the active bundle file name in the sidebar header"),
                        active.lastPathComponent
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(NSLocalizedString("sidebar.header.inactive",
                                       comment: "Shown in sidebar header when no bundle is active"))
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
                Label(
                    NSLocalizedString("sidebar.toolbar.importBundles",
                                      comment: "Toolbar button to import peMR bundles"),
                    systemImage: "square.and.arrow.down"
                )
            }

            Button {
                showingNewPatient = true
            } label: {
                Label(
                    NSLocalizedString("sidebar.toolbar.newPatient",
                                      comment: "Toolbar button to create a new patient in the active bundle"),
                    systemImage: "person.badge.plus"
                )
            }
        }
    }

    // MARK: - Row Builders
    @ViewBuilder
    private func bundleRowContent(summary: BundleSidebarSummary, isActive: Bool, fileName: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: isActive ? "folder.fill" : "folder")
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    // Primary title: alias if available, otherwise fallback to filename (without extension)
                    Text(summary.alias.isEmpty ? fileName : summary.alias)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    // Optional full name line if distinct from title
                    if !summary.fullName.isEmpty && summary.fullName != summary.alias {
                        Text(summary.fullName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    // Small metadata line: DOB if present
                    if !summary.dob.isEmpty && summary.dob != "—" {
                        Text(summary.dob)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Timing metadata block
            VStack(alignment: .leading, spacing: 2) {
                if !summary.createdOn.isEmpty && summary.createdOn != "—" {
                    Text(
                        String(
                            format: NSLocalizedString("sidebar.bundle.createdOn",
                                                      comment: "Metadata line: Created: <timestamp>"),
                            summary.createdOn
                        )
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !summary.importedOn.isEmpty && summary.importedOn != "—" {
                    Text(
                        String(
                            format: NSLocalizedString("sidebar.bundle.importedOn",
                                                      comment: "Metadata line: Imported: <timestamp>"),
                            summary.importedOn
                        )
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !summary.lastSavedOn.isEmpty && summary.lastSavedOn != "—" {
                    Text(
                        String(
                            format: NSLocalizedString("sidebar.bundle.lastSave",
                                                      comment: "Metadata line: Last save: <timestamp>"),
                            summary.lastSavedOn
                        )
                    )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }

    // MARK: - Actions
    private func pickAndAddBundles() {
        #if os(macOS)
        FilePicker.selectBundles { urls in
            if !urls.isEmpty {
                Task { @MainActor in
                    appState.importBundles(from: urls)   // non-switching import path
                }
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
