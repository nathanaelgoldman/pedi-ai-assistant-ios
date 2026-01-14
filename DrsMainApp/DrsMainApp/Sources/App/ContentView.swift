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
                .environmentObject(appState)
        } detail: {
            if let patient = appState.selectedPatient {
                // Right pane = patient details + visits
                PatientDetailView(patient: patient)
                    .environmentObject(appState)
            } else if appState.currentBundleURL != nil {
                // Bundle chosen but no patient selected
                BundleDetailView()
                    .environmentObject(appState)
            } else {
                // Nothing chosen yet
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("content_view.empty.no_bundle_title")
                        .font(.title2).bold()
                        .foregroundStyle(.secondary)
                    Text("content_view.empty.no_bundle_message")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text("CareFlow")
                        .fontWeight(.semibold)
                    Text("Kids")
                        .italic()
                        .foregroundStyle(Color.accentColor)
                }
                .font(.title3)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(Color.accentColor.opacity(0.12))
                )
                .overlay(
                    Capsule().strokeBorder(Color.accentColor.opacity(0.20), lineWidth: 1)
                )
            }
        }
    }
}
