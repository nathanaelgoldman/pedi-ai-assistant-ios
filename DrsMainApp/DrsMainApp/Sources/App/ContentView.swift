//
//  ContentView.swift
//  DrsMainApp
//
//  Created by yunastic on 10/25/25.
//
//
//  ContentView.swift
//  DrsMainApp
//
//  Created by yunastic on 10/25/25.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            Group {
                if let patient = appState.selectedPatient {
                    PatientDetailView(patient: patient)
                } else if appState.currentBundleURL != nil {
                    BundleDetailView()
                } else {
                    EmptyStateView {
                        FilePicker.selectBundles { urls in
                            appState.importBundles(from: urls)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    FilePicker.selectBundles { urls in
                        appState.importBundles(from: urls)
                    }
                } label: {
                    Label("Add Bundles…", systemImage: "folder.badge.plus")
                }
            }
        }
    }
}

struct EmptyStateView: View {
    let onImport: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Text("No bundle selected")
                .font(.title2)
                .foregroundStyle(.secondary)
            Button(action: onImport) {
                Label("Add Bundles…", systemImage: "tray.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView().environmentObject(AppState())
}
