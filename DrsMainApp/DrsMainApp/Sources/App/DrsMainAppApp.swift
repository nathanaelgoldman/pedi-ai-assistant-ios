//
//  DrsMainAppApp.swift
//  DrsMainApp
//
//  Created by yunastic on 10/25/25.
//

// DrsMainApp/Sources/App/DrsMainAppApp.swift
import SwiftUI

@main
struct DrsMainAppApp: App {
    @StateObject private var clinicianStore: ClinicianStore
    @StateObject private var appState: AppState
    @State private var showSignIn: Bool = false

    init() {
        let store = ClinicianStore()
        _clinicianStore = StateObject(wrappedValue: store)
        _appState = StateObject(wrappedValue: AppState(clinicianStore: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(clinicianStore)
                .onAppear {
                    // Show sign-in if no active clinician selected yet
                    if appState.activeUserID == nil {
                        showSignIn = true
                    }
                }
                .sheet(isPresented: $showSignIn) {
                    SignInSheet(showSignIn: $showSignIn)
                        .environmentObject(appState)
                        .environmentObject(clinicianStore)
                }
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        let active: Clinician? = {
                            if let uid = appState.activeUserID {
                                return clinicianStore.users.first(where: { $0.id == uid })
                            }
                            return nil
                        }()

                        Menu {
                            if let active {
                                Text({
                                    let n = (active.firstName + " " + active.lastName).trimmingCharacters(in: .whitespaces)
                                    return "Signed in as " + (n.isEmpty ? "User #\(active.id)" : n)
                                }())
                                Divider()
                                Button("Switch clinician…") { showSignIn = true }
                                Button("Sign out") {
                                    appState.activeUserID = nil
                                    showSignIn = true
                                }
                            } else {
                                Button("Sign in…") { showSignIn = true }
                            }
                        } label: {
                            if let active {
                                Label({
                                    let n = (active.firstName + " " + active.lastName).trimmingCharacters(in: .whitespaces)
                                    return (n.isEmpty ? "Dr" : "Dr " + n)
                                }(), systemImage: "person.crop.circle")
                            } else {
                                Label("Sign in", systemImage: "person.crop.circle.badge.questionmark")
                            }
                        }
                    }
                }
        }
    }
}

private struct SignInSheet: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var clinicianStore: ClinicianStore
    @Binding var showSignIn: Bool

    @State private var selectedID: Int? = nil
    @State private var firstName: String = ""
    @State private var lastName: String = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                // Existing clinicians
                if clinicianStore.users.isEmpty {
                    Text("No clinicians found. Create one below.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                } else {
                    List {
                        ForEach(clinicianStore.users, id: \.id) { u in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text({
                                        let n = (u.firstName + " " + u.lastName).trimmingCharacters(in: .whitespacesAndNewlines)
                                        return n.isEmpty ? "User #\(u.id)" : n
                                    }())
                                    .foregroundStyle(.primary)

                                }

                                Spacer()

                                if selectedID == u.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                } else if appState.activeUserID == u.id {
                                    Text("Active")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedID = u.id
                            }
                            // macOS context menu delete
                            .contextMenu {
                                Button(role: .destructive) {
                                    let idToDelete = u.id
                                    clinicianStore.deleteUser(u)
                                    if selectedID == idToDelete { selectedID = nil }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            #if os(iOS)
                            // iOS swipe-to-delete
                            .swipeActions {
                                Button(role: .destructive) {
                                    let idToDelete = u.id
                                    clinicianStore.deleteUser(u)
                                    if selectedID == idToDelete { selectedID = nil }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            #endif
                        }
                        // Also enable Delete via List's built-in edit mode (iOS)
                        #if os(iOS)
                        .onDelete { indexSet in
                            for index in indexSet {
                                let user = clinicianStore.users[index]
                                let idToDelete = user.id
                                clinicianStore.deleteUser(user)
                                if selectedID == idToDelete { selectedID = nil }
                            }
                        }
                        #endif
                    }
                }

                // Create new clinician
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create clinician")
                        .font(.headline)
                    HStack {
                        TextField("First name", text: $firstName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Last name", text: $lastName)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("Add") {
                        let fn = firstName.trimmingCharacters(in: .whitespaces)
                        let ln = lastName.trimmingCharacters(in: .whitespaces)
                        guard !fn.isEmpty, !ln.isEmpty else { return }
                        _ = clinicianStore.createUser(firstName: fn, lastName: ln)
                        // Pick the last user (newly appended) as selected
                        selectedID = clinicianStore.users.last?.id
                        firstName = ""
                        lastName = ""
                    }
                    .buttonStyle(.borderedProminent)
                }

                Spacer()

                HStack {
                    Button("Cancel") {
                        // Allow proceeding without selecting (viewer mode)
                        showSignIn = false
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Use selected") {
                        let chosenID: Int? = {
                            if let sel = selectedID { return sel }
                            return clinicianStore.users.first?.id
                        }()
                        if let uid = chosenID {
                            appState.activeUserID = uid
                            showSignIn = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedID == nil && clinicianStore.users.isEmpty)
                }
            }
            .frame(minWidth: 560, minHeight: 380) // ensure comfortable size on macOS
            .padding()
            .navigationTitle("Sign in")
        }
        .frame(minWidth: 640, minHeight: 420) // enforce sheet size on macOS
        .onAppear {
        }
    }
}
