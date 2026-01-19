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
    

    // Bundle deletion (remove an imported bundle from the app's library)
    @State private var pendingDeleteBundleURL: URL? = nil
    @State private var showDeleteBundleConfirm = false

    private let log = AppLog.feature("sidebar")

    var body: some View {
        VStack(spacing: 0) {
            header

            List {
                patientsSection
                recentBundlesSection
            }
            .listStyle(.inset)
            .toolbar { toolbar }
            .confirmationDialog(
                NSLocalizedString("sidebar.bundles.delete.confirm.title", comment: "Delete bundle confirm title"),
                isPresented: $showDeleteBundleConfirm
            ) {
                Button(NSLocalizedString("sidebar.bundles.delete.confirm.delete", comment: "Confirm delete bundle"), role: .destructive) {
                    guard let url = pendingDeleteBundleURL else { return }
                    // Step 2: implement in AppState (delete imported bundle folder + update recentBundles)
                    appState.deleteBundle(url)
                    pendingDeleteBundleURL = nil
                }

                Button(NSLocalizedString("sidebar.bundles.delete.confirm.cancel", comment: "Cancel delete bundle"), role: .cancel) {
                    pendingDeleteBundleURL = nil
                }
            }
            .sheet(isPresented: $showingNewPatient) {
                NewPatientSheet(appState: appState)
            }
        }
        .frame(minWidth: 240)
    }
    // MARK: - Sections

    @ViewBuilder
    private var patientsSection: some View {
        Section(header: patientsSectionHeader) {
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
                }
                .foregroundStyle(.secondary)
            } else {
                ForEach(appState.patients) { p in
                    PatientRowView(
                        title: p.alias.isEmpty
                            ? (p.fullName.isEmpty ? "Patient #\(p.id)" : p.fullName)
                            : p.alias,
                        fullName: p.fullName,
                        dobISO: p.dobISO,
                        sex: p.sex,
                        isSelected: appState.selectedPatientID == p.id,
                        onSelect: {
                            appState.selectedPatientID = p.id
                            appState.reloadVisitsForSelectedPatient()
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var recentBundlesSection: some View {
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeleteBundleURL = url
                            showDeleteBundleConfirm = true
                        } label: {
                            Label(
                                NSLocalizedString("sidebar.bundles.delete", comment: "Delete bundle action"),
                                systemImage: "trash"
                            )
                        }
                    }
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
                        Button(role: .destructive) {
                            pendingDeleteBundleURL = url
                            showDeleteBundleConfirm = true
                        } label: {
                            Label(
                                NSLocalizedString("sidebar.bundles.delete", comment: "Delete bundle action"),
                                systemImage: "trash"
                            )
                        }
                    }
                }
            }
        }
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

    // MARK: - Section Headers
    private var patientsSectionHeader: some View {
        HStack(spacing: 8) {
            Text(NSLocalizedString("sidebar.section.patients",
                                   comment: "Sidebar section title for patients"))
                .font(.subheadline.weight(.semibold))

            Spacer()

            // Small badge showing currently selected patient (if available)
            if let selID = appState.selectedPatientID,
               let p = appState.patients.first(where: { $0.id == selID }) {
                let title = p.alias.isEmpty
                    ? (p.fullName.isEmpty ? "Patient #\(p.id)" : p.fullName)
                    : p.alias

                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.10))
                    )
            }

            Button {
                appState.reloadPatients()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("sidebar.patients.reloadHelp",
                                    comment: "Help text for reloading patients from the current database"))
        }
        .textCase(nil) // keep casing as provided (avoid auto-uppercase section headers)
        .padding(.vertical, 2)
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

// MARK: - Lightweight patient row (keeps SidebarView.body type-checkable)
private struct PatientRowView: View {
    let title: String
    let fullName: String
    let dobISO: String
    let sex: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "person.crop.circle")

            VStack(alignment: .leading, spacing: 2) {
                Text(title)

                if !fullName.isEmpty && fullName != title {
                    Text(fullName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !dobISO.isEmpty || !sex.isEmpty {
                    Text("\(dobISO)\(sex.isEmpty ? "" : " • \(sex)")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : .clear
        )
    }
}
