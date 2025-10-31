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
    @State private var showClinicianProfile = false

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
                .sheet(isPresented: $showClinicianProfile) {
                    ClinicianProfileForm(
                        clinicianStore: clinicianStore,
                        user: {
                            if let uid = appState.activeUserID {
                                return clinicianStore.users.first(where: { $0.id == uid })
                            }
                            return nil
                        }(),
                        onClose: { showClinicianProfile = false }
                    )
                    .frame(minWidth: 640, minHeight: 610)
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
                                Button("Edit profile…") { showClinicianProfile = true }
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

private struct ClinicianProfileForm: View {
    @ObservedObject var clinicianStore: ClinicianStore
    let user: Clinician?
    let onClose: () -> Void

    @State private var firstName = ""
    @State private var lastName  = ""
    @State private var title     = ""
    @State private var email     = ""
    @State private var societies = ""
    @State private var website   = ""
    @State private var twitter   = ""
    @State private var wechat    = ""
    @State private var instagram = ""
    @State private var linkedin  = ""
    @State private var aiEndpoint = ""
    @State private var aiAPIKey   = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(user == nil ? "Create Clinician" : "Clinician Profile")
                .font(.title2)
                .padding(.horizontal)
                .padding(.top)

            Divider()

            Form {
                Section("Identity") {
                    TextField("First name", text: $firstName)
                    TextField("Last name",  text: $lastName)
                    TextField("Title (e.g., MD, FAAP)", text: $title)
                }
                Section("Contact") {
                    TextField("Email", text: $email)
                    TextField("Website", text: $website)
                }
                Section("Professional") {
                    TextField("Societies (comma-separated)", text: $societies)
                }
                Section("Social") {
                    TextField("Twitter/X", text: $twitter)
                    TextField("WeChat",    text: $wechat)
                    TextField("Instagram", text: $instagram)
                    TextField("LinkedIn",  text: $linkedin)
                }
                Section("AI Assistant (optional)") {
                    TextField("Endpoint URL", text: $aiEndpoint)
                    SecureField("API Key",     text: $aiAPIKey)
                        .textContentType(.password)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") { onClose() }
                Button(user == nil ? "Create" : "Save") {
                    if let u = user {
                        clinicianStore.updateUser(
                            id: u.id,
                            firstName: firstName.isEmpty ? nil : firstName,
                            lastName:  lastName.isEmpty  ? nil : lastName,
                            title:     title,
                            email:     email,
                            societies: societies,
                            website:   website,
                            twitter:   twitter,
                            wechat:    wechat,
                            instagram: instagram,
                            linkedin:  linkedin
                        )
                        clinicianStore.updateAISettings(id: u.id,
                                                        endpoint: aiEndpoint.isEmpty ? nil : aiEndpoint,
                                                        apiKey:   aiAPIKey.isEmpty   ? nil : aiAPIKey)
                    } else {
                        if let new = clinicianStore.createUser(
                            firstName: firstName,
                            lastName:  lastName,
                            title:     title,
                            email:     email,
                            societies: societies,
                            website:   website,
                            twitter:   twitter,
                            wechat:    wechat,
                            instagram: instagram,
                            linkedin:  linkedin
                        ) {
                            clinicianStore.updateAISettings(id: new.id,
                                                            endpoint: aiEndpoint.isEmpty ? nil : aiEndpoint,
                                                            apiKey:   aiAPIKey.isEmpty   ? nil : aiAPIKey)
                            clinicianStore.setActiveUser(new)
                        }
                    }
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .onAppear {
            if let u = user {
                firstName = u.firstName
                lastName  = u.lastName
                title     = u.title ?? ""
                email     = u.email ?? ""
                societies = u.societies ?? ""
                website   = u.website ?? ""
                twitter   = u.twitter ?? ""
                wechat    = u.wechat ?? ""
                instagram = u.instagram ?? ""
                linkedin  = u.linkedin ?? ""
                aiEndpoint = u.aiEndpoint ?? ""
                aiAPIKey   = u.aiAPIKey ?? ""
            }
        }
    }
}
