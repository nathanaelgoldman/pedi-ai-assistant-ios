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
        WindowGroup("") {
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

                    // Wire clinician-specific well-visit AI prompt into AppState so that
                    // AI queries can use the active clinician's configured well prompt.
                    appState.wellPromptResolver = {
                        if let uid = appState.activeUserID {
                            return clinicianStore.users.first(where: { $0.id == uid })?.aiWellPrompt
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

                        // Normalise provider choice; default to "openai" if not set.
                        let providerID = (clinician.aiProvider ?? "openai")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()

                        // If clinician explicitly picked "local", always use the local stub
                        // (i.e. return nil here so EpisodeAIEngine falls back accordingly).
                        if providerID == "local" {
                            return nil
                        }

                        // For any cloud provider, we still require an API key.
                        guard let apiKeyRaw = clinician.aiAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !apiKeyRaw.isEmpty
                        else {
                            return nil
                        }

                        // Determine model: use clinician-specific value if present, otherwise fall back to a reasonable default.
                        let model: String = {
                            if let raw = clinician.aiModel?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !raw.isEmpty {
                                return raw
                            }
                            // Default: you can change this to any supported model string.
                            return "gpt-5.1-mini"
                        }()

                        switch providerID {
                        case "openai", "":
                            // Optional custom endpoint; defaults to the public OpenAI API.
                            let baseURL: URL = {
                                if let endpointRaw = clinician.aiEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
                                   !endpointRaw.isEmpty,
                                   let url = URL(string: endpointRaw) {
                                    return url
                                }
                                return URL(string: "https://api.openai.com/v1")!
                            }()

                            return OpenAIProvider(
                                apiKey: apiKeyRaw,
                                model: model,
                                apiBaseURL: baseURL
                            )

                        case "anthropic":
                            // Placeholder: in a future phase, this will return an AnthropicProvider.
                            // For now, fall back to local stub behaviour.
                            return nil

                        case "gemini":
                            // Placeholder: in a future phase, this will return a GeminiProvider.
                            // For now, fall back to local stub behaviour.
                            return nil

                        default:
                            // Unknown provider string → be defensive and fall back to local stub.
                            return nil
                        }
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
                    .frame(
                        minWidth: 1100,
                        idealWidth: 1400,
                        maxWidth: 1600,
                        minHeight: 720,
                        idealHeight: 860,
                        maxHeight: 1000,
                        alignment: .center
                    )
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
                                    let who: String
                                    if n.isEmpty {
                                        who = String(format: NSLocalizedString("app.clinician.user_number", comment: ""), active.id)
                                    } else {
                                        who = n
                                    }
                                    return String(format: NSLocalizedString("app.toolbar.signed_in_as", comment: ""), who)
                                }())
                                Divider()
                                Button("app.toolbar.edit_profile") { showClinicianProfile = true }
                                Button("app.toolbar.switch_clinician") { showSignIn = true }
                                Button("app.toolbar.sign_out") {
                                    appState.activeUserID = nil
                                    showSignIn = true
                                }
                            } else {
                                Button("app.toolbar.sign_in_ellipsis") { showSignIn = true }
                            }
                        } label: {
                            if let active {
                                Label({
                                    let n = (active.firstName + " " + active.lastName).trimmingCharacters(in: .whitespaces)
                                    if n.isEmpty {
                                        return NSLocalizedString("app.toolbar.doctor", comment: "")
                                    }
                                    return String(format: NSLocalizedString("app.toolbar.doctor_name", comment: ""), n)
                                }(), systemImage: "person.crop.circle")
                            } else {
                                Label("app.toolbar.sign_in", systemImage: "person.crop.circle.badge.questionmark")
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
                    Text("app.signin.no_clinicians_found")
                        .font(.callout)
                        .foregroundColor(.secondary)
                } else {
                    List {
                        ForEach(clinicianStore.users, id: \.id) { u in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text({
                                        let n = (u.firstName + " " + u.lastName)
                                            .trimmingCharacters(in: .whitespacesAndNewlines)
                                        if n.isEmpty {
                                            return String(format: NSLocalizedString("app.clinician.user_number", comment: ""), u.id)
                                        }
                                        return n
                                    }())
                                    .foregroundStyle(.primary)
                                }
                                Spacer()
                                if selectedID == u.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                } else if appState.activeUserID == u.id {
                                    Text("app.signin.active")
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
                                    Label("app.common.delete", systemImage: "trash")
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
                                    Label("app.common.delete", systemImage: "trash")
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
                    Text("app.signin.create_clinician")
                        .font(.headline)
                    HStack {
                        TextField("app.signin.first_name", text: $firstName)
                            .textFieldStyle(.roundedBorder)
                        TextField("app.signin.last_name", text: $lastName)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("app.signin.add") {
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
                    SecureField("app.signin.password_optional", text: $password)
                        .textFieldStyle(.roundedBorder)
                    if let loginError {
                        Text(loginError)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                Spacer()

                HStack {
                    Button("app.common.cancel") {
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

                    Button("app.signin.use_selected") {
                        let chosenID: Int? = {
                            if let sel = selectedID { return sel }
                            return clinicianStore.users.first?.id
                        }()
                        if let uid = chosenID {
                            // If a password is set for this clinician, require it
                            if clinicianStore.hasPassword(forUserID: uid) {
                                guard clinicianStore.verifyPassword(password, forUserID: uid) else {
                                    loginError = NSLocalizedString("app.signin.incorrect_password", comment: "")
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
            .navigationTitle("app.signin.title")
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
    @State private var aiProvider = "openai"
    
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

    private func persistAndClose() {
        // Reset any previous password error
        passwordError = nil

        // Determine if we have a new password to set
        var effectiveNewPassword: String? = nil
        if !removePassword {
            let trimmedNew = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedConfirm = confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedNew.isEmpty || !trimmedConfirm.isEmpty {
                guard !trimmedNew.isEmpty, !trimmedConfirm.isEmpty else {
                    passwordError = NSLocalizedString("app.clinician_profile.app_lock.error.enter_and_confirm", comment: "")
                    return
                }
                guard trimmedNew == trimmedConfirm else {
                    passwordError = NSLocalizedString("app.clinician_profile.app_lock.error.mismatch", comment: "")
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
                model:    aiModel.isEmpty    ? nil : aiModel,
                provider: aiProvider
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
                    model:    aiModel.isEmpty    ? nil : aiModel,
                    provider: aiProvider
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

    @ViewBuilder
    private var formContent: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(spacing: 0) {
                ScrollView {
                    HStack(alignment: .top, spacing: 24) {
                        // LEFT COLUMN
                        VStack(alignment: .leading, spacing: 16) {
                            GroupBox {
                                VStack(alignment: .leading, spacing: 10) {
                                    TextField("app.clinician_profile.first_name", text: $firstName)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("app.clinician_profile.last_name",  text: $lastName)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("app.clinician_profile.title", text: $title)
                                        .textFieldStyle(.roundedBorder)
                                }
                                .padding(.top, 2)
                            } label: {
                                Text("app.clinician_profile.section.identity")
                            }

                            GroupBox {
                                VStack(alignment: .leading, spacing: 10) {
                                    TextField("app.clinician_profile.email", text: $email)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("app.clinician_profile.website", text: $website)
                                        .textFieldStyle(.roundedBorder)
                                }
                                .padding(.top, 2)
                            } label: {
                                Text("app.clinician_profile.section.contact")
                            }

                            GroupBox {
                                VStack(alignment: .leading, spacing: 10) {
                                    TextField("app.clinician_profile.societies", text: $societies)
                                        .textFieldStyle(.roundedBorder)
                                }
                                .padding(.top, 2)
                            } label: {
                                Text("app.clinician_profile.section.professional")
                            }

                            GroupBox {
                                VStack(alignment: .leading, spacing: 10) {
                                    TextField("app.clinician_profile.twitter", text: $twitter)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("app.clinician_profile.wechat",    text: $wechat)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("app.clinician_profile.instagram", text: $instagram)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("app.clinician_profile.linkedin",  text: $linkedin)
                                        .textFieldStyle(.roundedBorder)
                                }
                                .padding(.top, 2)
                            } label: {
                                Text("app.clinician_profile.section.social")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                        // RIGHT COLUMN
                        VStack(alignment: .leading, spacing: 16) {
                            GroupBox {
                                VStack(alignment: .leading, spacing: 10) {
                                    TextField("app.clinician_profile.ai.endpoint_url", text: $aiEndpoint)
                                        .textFieldStyle(.roundedBorder)
                                    TextField("app.clinician_profile.ai.model", text: $aiModel)
                                        .textFieldStyle(.roundedBorder)

                                    Picker("app.clinician_profile.ai.provider", selection: $aiProvider) {
                                        Text("app.clinician_profile.ai.provider.openai").tag("openai")
                                        Text("app.clinician_profile.ai.provider.anthropic").tag("anthropic")
                                        Text("app.clinician_profile.ai.provider.gemini").tag("gemini")
                                        Text("app.clinician_profile.ai.provider.local").tag("local")
                                    }
                                    .pickerStyle(.menu)

                                    SecureField("app.clinician_profile.ai.api_key", text: $aiAPIKey)
                                        .textContentType(.password)
                                        .textFieldStyle(.roundedBorder)
                                }
                                .padding(.top, 2)
                            } label: {
                                Text("app.clinician_profile.section.ai_assistant")
                            }

                            GroupBox {
                                VStack(alignment: .leading, spacing: 12) {
                                    DisclosureGroup("app.clinician_profile.ai_prompts_rules.sick_group") {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("app.clinician_profile.ai_prompts_rules.sick_prompt_label")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            TextEditor(text: $aiSickPrompt)
                                                .frame(minHeight: 120)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(Color.secondary.opacity(0.2))
                                                )

                                            Text("app.clinician_profile.ai_prompts_rules.sick_rules_label")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .padding(.top, 4)
                                            TextEditor(text: $aiSickRulesJSON)
                                                .frame(minHeight: 120)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(Color.secondary.opacity(0.2))
                                                )
                                        }
                                        .padding(.vertical, 4)
                                    }

                                    DisclosureGroup("app.clinician_profile.ai_prompts_rules.well_group") {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("app.clinician_profile.ai_prompts_rules.well_prompt_label")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            TextEditor(text: $aiWellPrompt)
                                                .frame(minHeight: 110)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(Color.secondary.opacity(0.2))
                                                )

                                            Text("app.clinician_profile.ai_prompts_rules.well_rules_label")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .padding(.top, 4)
                                            TextEditor(text: $aiWellRulesJSON)
                                                .frame(minHeight: 110)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(Color.secondary.opacity(0.2))
                                                )
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                                .padding(.top, 2)
                            } label: {
                                Text("app.clinician_profile.section.ai_prompts_rules")
                            }

                            GroupBox {
                                VStack(alignment: .leading, spacing: 10) {
                                    if let user, hasPassword {
                                        Text("app.clinician_profile.app_lock.password_set")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("app.clinician_profile.app_lock.no_password")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    SecureField("app.clinician_profile.app_lock.new_password", text: $newPassword)
                                        .textContentType(.newPassword)
                                        .textFieldStyle(.roundedBorder)
                                        .disabled(removePassword)

                                    SecureField("app.clinician_profile.app_lock.confirm_password", text: $confirmPassword)
                                        .textContentType(.newPassword)
                                        .textFieldStyle(.roundedBorder)
                                        .disabled(removePassword)

                                    if let user, hasPassword {
                                        Toggle("app.clinician_profile.app_lock.remove_existing", isOn: $removePassword)
                                    }

                                    if let passwordError {
                                        Text(passwordError)
                                            .font(.footnote)
                                            .foregroundStyle(.red)
                                    }
                                }
                                .padding(.top, 2)
                            } label: {
                                Text("app.clinician_profile.section.app_lock")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .top)
                }

                Divider()

                HStack {
                    Spacer()
                    Button("app.common.close") { onClose() }
                    Button(user == nil ? "app.common.create" : "app.common.save") {
                        persistAndClose()
                    }
                    .keyboardShortcut(.defaultAction)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }
            // Let the form be wider (and therefore more legible) while still staying centered.
            .frame(minWidth: 1100, idealWidth: 1400, maxWidth: 1600)
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    var body: some View {
        // On macOS, NavigationView can behave like a split view and visually "stick" content to the left.
        // Using NavigationStack keeps this screen as a single, centered content area.
        Group {
            #if os(macOS)
            NavigationStack {
                formContent
                    .navigationTitle(user == nil ? "app.clinician_profile.nav_title.create" : "app.clinician_profile.nav_title.edit")
            }
            #else
            NavigationView {
                formContent
                    .navigationTitle(user == nil ? "app.clinician_profile.nav_title.create" : "app.clinician_profile.nav_title.edit")
            }
            #endif
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
                aiProvider = u.aiProvider ?? "openai"
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
