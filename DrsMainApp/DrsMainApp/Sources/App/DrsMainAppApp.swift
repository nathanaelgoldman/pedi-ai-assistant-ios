//
//  DrsMainAppApp.swift
//  DrsMainApp
//
//  Created by yunastic on 10/25/25.
//

// DrsMainApp/Sources/App/DrsMainAppApp.swift

import SwiftUI
#if os(macOS)
import AppKit
#endif

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

                    // Wire clinician-specific sick-visit JSON rules into AppState so that
                    // guideline flags can use the active clinician's configured rules.
                    appState.sickRulesJSONResolver = {
                        if let uid = appState.activeUserID {
                            return clinicianStore.users.first(where: { $0.id == uid })?.aiSickRulesJSON
                        }
                        return nil
                    }

                    // Wire clinician-specific sick-visit AI prompt into AppState so that
                    // AI queries can use the active clinician's configured sick prompt.
                    appState.sickPromptResolver = {
                        if let uid = appState.activeUserID {
                            return clinicianStore.users.first(where: { $0.id == uid })?.aiSickPrompt
                        }
                        return nil
                    }

                    // Wire clinician-specific AI provider into AppState. If the active clinician
                    // has configured an API key (and optionally a custom endpoint), AppState will
                    // prefer that provider over the local stub when running episode AI.
                    appState.episodeAIProviderResolver = {
                        guard
                            let uid = appState.activeUserID,
                            let clinician = clinicianStore.users.first(where: { $0.id == uid })
                        else {
                            return nil
                        }

                        // Require at least an API key; if missing, fall back to the local stub.
                        guard let apiKeyRaw = clinician.aiAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !apiKeyRaw.isEmpty
                        else {
                            return nil
                        }

                        // Optional custom endpoint; defaults to the public OpenAI API.
                        let baseURL: URL = {
                            if let endpointRaw = clinician.aiEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !endpointRaw.isEmpty,
                               let url = URL(string: endpointRaw) {
                                return url
                            }
                            return URL(string: "https://api.openai.com/v1")!
                        }()

                        // Determine model: use clinician-specific value if present, otherwise fall back to a reasonable default.
                        let model: String = {
                            if let raw = clinician.aiModel?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !raw.isEmpty {
                                return raw
                            }
                            // Default: you can change this to any supported OpenAI model string.
                            return "gpt-5.1-mini"
                        }()

                        return OpenAIProvider(
                            apiKey: apiKeyRaw,
                            model: model,
                            apiBaseURL: baseURL
                        )
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
                    .frame(minWidth: 640, minHeight: 760)
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
    @State private var password: String = ""
    @State private var loginError: String? = nil

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
                                loginError = nil
                                password = ""
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

                // Password for selected clinician (if required)
                VStack(alignment: .leading, spacing: 4) {
                    SecureField("Password (if required)", text: $password)
                        .textFieldStyle(.roundedBorder)
                    if let loginError {
                        Text(loginError)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                Spacer()

                HStack {
                    Button("Cancel") {
                        if appState.activeUserID == nil {
                            // No active clinician: do not allow using the app without sign‑in
                            #if os(macOS)
                            // On macOS, terminate the app if user refuses to pick a clinician
                            NSApp.terminate(nil)
                            #else
                            // On iOS (if ever used), keep the sheet open (no escape without clinician)
                            // Do nothing here so the sign‑in sheet stays visible.
                            #endif
                        } else {
                            // A clinician is already active: just dismiss the sheet
                            showSignIn = false
                        }
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Use selected") {
                        let chosenID: Int? = {
                            if let sel = selectedID { return sel }
                            return clinicianStore.users.first?.id
                        }()
                        if let uid = chosenID {
                            // If a password is set for this clinician, require it
                            if clinicianStore.hasPassword(forUserID: uid) {
                                guard clinicianStore.verifyPassword(password, forUserID: uid) else {
                                    loginError = "Incorrect password."
                                    return
                                }
                            }
                            appState.activeUserID = uid
                            showSignIn = false
                            // Clear password state on successful sign-in
                            password = ""
                            loginError = nil
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
    @State private var aiModel    = ""

    // Per-clinician AI prompts and JSON rules
    @State private var aiSickPrompt: String = ""
    @State private var aiWellPrompt: String = ""
    @State private var aiSickRulesJSON: String = ""
    @State private var aiWellRulesJSON: String = ""

    // App lock (password) state
    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var passwordError: String? = nil
    @State private var hasPassword: Bool = false
    @State private var removePassword: Bool = false

    var body: some View {
        NavigationView {
            ScrollView {
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
                        TextField("Model (e.g. gpt-5.1-mini)", text: $aiModel)
                        SecureField("API Key",     text: $aiAPIKey)
                            .textContentType(.password)
                    }
                    Section("AI Prompts & Rules") {
                        DisclosureGroup("Sick visit prompts & rules") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Sick visit AI prompt")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextEditor(text: $aiSickPrompt)
                                    .frame(minHeight: 100)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.secondary.opacity(0.2))
                                    )

                                Text("Sick visit JSON rules (paste JSON here)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                                TextEditor(text: $aiSickRulesJSON)
                                    .frame(minHeight: 100)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.secondary.opacity(0.2))
                                    )
                            }
                            .padding(.vertical, 4)
                        }

                        DisclosureGroup("Well visit prompts & rules") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Well visit AI prompt")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextEditor(text: $aiWellPrompt)
                                    .frame(minHeight: 80)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.secondary.opacity(0.2))
                                    )

                                Text("Well visit JSON rules (optional, future use)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)
                                TextEditor(text: $aiWellRulesJSON)
                                    .frame(minHeight: 80)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.secondary.opacity(0.2))
                                    )
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // --- App lock (password) section ---
                    Section("App lock (password)") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let user, hasPassword {
                                Text("A password is currently set for this clinician.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("No password set yet.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            SecureField("New password", text: $newPassword)
                                .textContentType(.newPassword)
                                .disabled(removePassword)

                            SecureField("Confirm password", text: $confirmPassword)
                                .textContentType(.newPassword)
                                .disabled(removePassword)

                            if let user, hasPassword {
                                Toggle("Remove existing password", isOn: $removePassword)
                            }

                            if let passwordError {
                                Text(passwordError)
                                    .font(.footnote)
                                    .foregroundColor(.red)
                            }
                        }
                    }

                    Section {
                        HStack {
                            Spacer()
                            Button("Close") { onClose() }
                            Button(user == nil ? "Create" : "Save") {
                                // Reset any previous password error
                                passwordError = nil

                                // Determine if we have a new password to set
                                var effectiveNewPassword: String? = nil
                                if !removePassword {
                                    let trimmedNew = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let trimmedConfirm = confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmedNew.isEmpty || !trimmedConfirm.isEmpty {
                                        guard !trimmedNew.isEmpty, !trimmedConfirm.isEmpty else {
                                            passwordError = "Please enter and confirm the password."
                                            return
                                        }
                                        guard trimmedNew == trimmedConfirm else {
                                            passwordError = "Passwords do not match."
                                            return
                                        }
                                        effectiveNewPassword = trimmedNew
                                    }
                                }

                                if let u = user {
                                    // Update existing clinician
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
                                    clinicianStore.updateAISettings(
                                        id: u.id,
                                        endpoint: aiEndpoint.isEmpty ? nil : aiEndpoint,
                                        apiKey:   aiAPIKey.isEmpty   ? nil : aiAPIKey,
                                        model:    aiModel.isEmpty    ? nil : aiModel
                                    )
                                    clinicianStore.updateAIPromptsAndRules(
                                        id: u.id,
                                        sickPrompt: aiSickPrompt.isEmpty ? nil : aiSickPrompt,
                                        wellPrompt: aiWellPrompt.isEmpty ? nil : aiWellPrompt,
                                        sickRulesJSON: aiSickRulesJSON.isEmpty ? nil : aiSickRulesJSON,
                                        wellRulesJSON: aiWellRulesJSON.isEmpty ? nil : aiWellRulesJSON
                                    )
                                    // Handle password changes for existing clinician
                                    if let newPwd = effectiveNewPassword {
                                        clinicianStore.setPassword(newPwd, forUserID: u.id)
                                        hasPassword = true
                                    } else if removePassword {
                                        clinicianStore.clearPassword(forUserID: u.id)
                                        hasPassword = false
                                    }
                                } else {
                                    // Create new clinician
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
                                        clinicianStore.updateAISettings(
                                            id: new.id,
                                            endpoint: aiEndpoint.isEmpty ? nil : aiEndpoint,
                                            apiKey:   aiAPIKey.isEmpty   ? nil : aiAPIKey,
                                            model:    aiModel.isEmpty    ? nil : aiModel
                                        )
                                        clinicianStore.updateAIPromptsAndRules(
                                            id: new.id,
                                            sickPrompt: aiSickPrompt.isEmpty ? nil : aiSickPrompt,
                                            wellPrompt: aiWellPrompt.isEmpty ? nil : aiWellPrompt,
                                            sickRulesJSON: aiSickRulesJSON.isEmpty ? nil : aiSickRulesJSON,
                                            wellRulesJSON: aiWellRulesJSON.isEmpty ? nil : aiWellRulesJSON
                                        )
                                        clinicianStore.setActiveUser(new)
                                        // Handle password for newly created clinician
                                        if let newPwd = effectiveNewPassword {
                                            clinicianStore.setPassword(newPwd, forUserID: new.id)
                                            hasPassword = true
                                        } else {
                                            hasPassword = false
                                        }
                                    }
                                }
                                onClose()
                            }
                            .keyboardShortcut(.defaultAction)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle(user == nil ? "Create Clinician" : "Clinician Profile")
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
                aiModel    = u.aiModel ?? ""
                aiSickPrompt    = u.aiSickPrompt ?? ""
                aiWellPrompt    = u.aiWellPrompt ?? ""
                aiSickRulesJSON = u.aiSickRulesJSON ?? ""
                aiWellRulesJSON = u.aiWellRulesJSON ?? ""
                hasPassword = clinicianStore.hasPassword(forUserID: u.id)
                newPassword = ""
                confirmPassword = ""
                passwordError = nil
                removePassword = false
            }
        }
    }
}
