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
import UniformTypeIdentifiers
#endif

#if os(macOS)
// Disable macOS window tabbing (prevents ghost tabs/windows and hides the tab bar UI).
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Global preference: do not allow tabbing.
        NSWindow.allowsAutomaticWindowTabbing = false

        // Apply to any windows that already exist.
        for w in NSApp.windows {
            w.tabbingMode = .disallowed
        }

        // Ensure any future windows also have tabbing disabled.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            (note.object as? NSWindow)?.tabbingMode = .disallowed
        }
    }
}
#endif

@main
struct DrsMainAppApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @StateObject private var clinicianStore: ClinicianStore
    @StateObject private var appState: AppState
    @State private var showSignIn: Bool = false
    @State private var showClinicianProfile = false
    // Unified alert presenter (avoid stacking multiple .alert modifiers)
    @State private var activeAlert: ActiveAlert? = nil
    @State private var pendingShareURL: URL? = nil
    #if os(macOS)
    @State private var helpWindowController: NSWindowController? = nil
    #endif

    private enum ActiveAlert: Identifiable {
        case supportLog(title: String, message: String, fileURL: URL?)
        case lastError(title: String, message: String)

        var id: String {
            switch self {
            case .supportLog:
                return "supportLog"
            case .lastError:
                return "lastError"
            }
        }

        var title: String {
            switch self {
            case .supportLog(let t, _, _):
                return t
            case .lastError(let t, _):
                return t
            }
        }

        var message: String {
            switch self {
            case .supportLog(_, let m, _):
                return m
            case .lastError(_, let m):
                return m
            }
        }
    }

    #if os(macOS)
    init() {
        let store = ClinicianStore()
        _clinicianStore = StateObject(wrappedValue: store)
        _appState = StateObject(wrappedValue: AppState(clinicianStore: store))

        // Disable window tabbing as early as possible (before windows are created).
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    #else
    init() {
        let store = ClinicianStore()
        _clinicianStore = StateObject(wrappedValue: store)
        _appState = StateObject(wrappedValue: AppState(clinicianStore: store))
    }
    #endif

    var body: some Scene {
        WindowGroup("") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(clinicianStore)
                .alert(item: $activeAlert) { a in
                    switch a {
                    case .lastError:
                        return Alert(
                            title: Text(a.title),
                            message: Text(a.message),
                            dismissButton: .default(
                                Text(NSLocalizedString("app.common.ok", comment: "OK")),
                                action: {
                                    // Only mark as seen when the user actually dismisses an error alert.
                                    AppLog.feature("ui.alert").info("User dismissed error alert")
                                    if appState.userErrorStatus == .present {
                                        appState.userErrorStatus = .seen
                                    }
                                }
                            )
                        )
                    case .supportLog(_, _, let fileURL):
                        #if os(macOS)
                        let revealTitle = NSLocalizedString(
                            "support_log.export.success.reveal",
                            comment: "Button title to reveal the exported support log in Finder"
                        )
                        let shareTitle = NSLocalizedString(
                            "support_log.export.success.share",
                            comment: "Button title to share the exported support log"
                        )
                        let okTitle = NSLocalizedString("app.common.ok", comment: "OK")

                        // If we don't have a file URL (should be rare), fall back to OK only.
                        guard let fileURL else {
                            return Alert(
                                title: Text(a.title),
                                message: Text(a.message),
                                dismissButton: .default(Text(okTitle))
                            )
                        }

                        return Alert(
                            title: Text(a.title),
                            message: Text(a.message),
                            primaryButton: .default(Text(shareTitle), action: {
                                // Defer presentation until after the alert is dismissed.
                                pendingShareURL = fileURL
                                activeAlert = nil
                            }),
                            secondaryButton: .default(Text(revealTitle), action: {
                                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                            })
                        )
                        #else
                        return Alert(
                            title: Text(a.title),
                            message: Text(a.message),
                            dismissButton: .default(Text(NSLocalizedString("app.common.ok", comment: "OK")))
                        )
                        #endif
                    }
                }
                .onChange(of: appState.lastError?.id) { _, _ in
                    guard let e = appState.lastError else { return }
                    // Present the alert; the dismiss action will mark userErrorStatus as .seen.
                    activeAlert = .lastError(title: e.title, message: e.message)
                    // Clear the published error payload to prevent repeat triggers.
                    appState.lastError = nil
                }
                .onChange(of: pendingShareURL) { _, url in
                    #if os(macOS)
                    guard let url else { return }
                    // Small async hop so the alert has fully dismissed and the window is valid.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        presentShareSheet(for: url)
                        pendingShareURL = nil
                    }
                    #endif
                }
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

                        // Determine model: use clinician-specific value if present, otherwise fall back to a reasonable default
                        // for the chosen provider.
                        let modelRaw: String = {
                            if let raw = clinician.aiModel?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !raw.isEmpty {
                                return raw
                            }
                            switch providerID {
                            case "gemini":
                                // Known-good baseModelId examples are published in the Gemini Models API docs.
                                // (We can always list supported models via GET /v1beta/models?key=...)
                                return "gemini-2.0-flash"
                            case "anthropic":
                                return "claude-3-5-sonnet-latest"
                            default:
                                return "gpt-5.1-mini"
                            }
                        }()

                        // Normalize model strings that clinicians might paste (e.g., "models/..." or accidental whitespace).
                        func normalizeModel(providerID: String, raw: String) -> String {
                            var m = raw.trimmingCharacters(in: .whitespacesAndNewlines)

                            // Common paste: "models/gemini-..." → strip leading "models/".
                            if m.lowercased().hasPrefix("models/") {
                                m = String(m.dropFirst("models/".count))
                            }

                            // Gemini API v1beta requires a model that exists and supports generateContent.
                            // If the clinician entered a non-existent alias (e.g., "gemini-3-flash"),
                            // fall back to a known valid baseModelId so the app keeps working.
                            if providerID == "gemini" {
                                let lower = m.lowercased()
                                if lower == "gemini-3-flash" || lower.hasPrefix("gemini-3-") {
                                    AppLog.feature("ai.gemini").warning("Unknown Gemini model \(m, privacy: .public); falling back to gemini-2.0-flash")
                                    m = "gemini-2.0-flash"
                                }
                            }

                            return m
                        }

                        let model = normalizeModel(providerID: providerID, raw: modelRaw)

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
                            // Optional custom endpoint; defaults to the public Anthropic API.
                            let baseURL: URL = {
                                if let endpointRaw = clinician.aiEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
                                   !endpointRaw.isEmpty,
                                   let url = URL(string: endpointRaw) {
                                    return url
                                }
                                return URL(string: "https://api.anthropic.com/v1")!
                            }()

                            return AnthropicProvider(
                                apiKey: apiKeyRaw,
                                model: model,
                                apiBaseURL: baseURL
                            )

                        case "gemini":
                            // Optional custom endpoint; defaults to the public Gemini Generative Language API.
                            // IMPORTANT: clinicians may paste the *full* generateContent URL (including `/models/...:generateContent`).
                            // GeminiProvider expects a *base* like `.../v1beta`, so we normalise any supplied endpoint.
                            func normaliseGeminiBaseURL(_ raw: String?) -> URL {
                                // Default base
                                let fallback = URL(string: "https://generativelanguage.googleapis.com/v1beta")!
                                guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                    return fallback
                                }
                                guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                                    return fallback
                                }
                                guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                                    return fallback
                                }

                                // Drop query/fragment for safety.
                                comps.query = nil
                                comps.fragment = nil

                                // Trim any accidental full endpoint paths like `/models/<model>:generateContent`.
                                var path = comps.path
                                if let r = path.range(of: "/models/") {
                                    path = String(path[..<r.lowerBound])
                                }

                                // If user pasted something even deeper, also trim after the API version segment.
                                // Keep `/v1beta` or `/v1` if present; otherwise keep the current trimmed path.
                                if let r = path.range(of: "/v1beta") {
                                    path = String(path[..<r.upperBound])
                                } else if let r = path.range(of: "/v1") {
                                    path = String(path[..<r.upperBound])
                                }

                                // Ensure we have *some* version path.
                                if path.isEmpty {
                                    path = "/v1beta"
                                }

                                // Remove trailing slash to avoid double slashes when appending.
                                while path.hasSuffix("/") {
                                    path.removeLast()
                                }

                                comps.path = path

                                return comps.url ?? fallback
                            }

                            let baseURL: URL = normaliseGeminiBaseURL(clinician.aiEndpoint)

                            return GeminiProvider(
                                apiKey: apiKeyRaw,
                                model: model,
                                apiBaseURL: baseURL
                            )

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
                    .environmentObject(appState)
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
                                Button("app.toolbar.export_support_log") {
                                    exportSupportLog()
                                }
#if DEBUG
                                Button(NSLocalizedString("app.toolbar.trigger_test_error", comment: "Debug-only menu item to trigger a test error")) {
                                    let err = NSError(
                                        domain: "DrsMainApp.Test",
                                        code: 999,
                                        userInfo: [NSLocalizedDescriptionKey: "This is a fake test error to verify alert dismissal logging."]
                                    )
                                    appState.presentError(err, context: "Test")
                                }
#endif
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
        .commands {
            // Disable extra windows/tabs for now to avoid “ghost” scenes.
            // This removes File ▸ New Window / New Tab (and New Document if present).
            CommandGroup(replacing: .newItem) { }
            #if os(macOS)
            CommandGroup(replacing: .help) {
                Button(NSLocalizedString("help.menu.open", comment: "Help menu item title")) {
                    openHelpWindow()
                }
                .keyboardShortcut("?", modifiers: [.command, .shift])
            }
            #endif
        }
    }
    #if os(macOS)
    private func presentShareSheet(for fileURL: URL) {
        // Ensure we're on the main thread and the app is foregrounded.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)

            // Prefer the key window; fall back to any visible window.
            let window = NSApp.windows.first(where: { $0.isKeyWindow })
                ?? NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible })

            guard let window, let view = window.contentView else {
                // If we cannot present the share picker, at least reveal the file.
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                return
            }

            let picker = NSSharingServicePicker(items: [fileURL])

            // Anchor to a stable rect in the contentView.
            let bounds = view.bounds
            let anchorRect = NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1)

            picker.show(relativeTo: anchorRect, of: view, preferredEdge: .minY)
        }
    }
    #endif

    #if os(macOS)
    private func openHelpWindow() {
        // Reuse an existing controller if the window is still around.
        if let wc = helpWindowController, let w = wc.window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }

        let root = HelpView()
        let host = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: host)
        window.title = NSLocalizedString("help.window.title", comment: "Help window title")
        window.setContentSize(NSSize(width: 720, height: 760))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()

        let wc = NSWindowController(window: window)
        helpWindowController = wc

        // When the user closes the window, drop our reference so it can be recreated cleanly.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            helpWindowController = nil
        }

        NSApp.activate(ignoringOtherApps: true)
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
    #endif

private struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(NSLocalizedString("help.header.title", comment: "Help header"))
                    .font(.title2).bold()

                Text(NSLocalizedString("help.header.subtitle", comment: "Help subtitle"))
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 6)

                helpSection(titleKey: "help.section.quick_start.title", bodyKey: "help.section.quick_start.body")
                helpSection(titleKey: "help.section.patients.title", bodyKey: "help.section.patients.body")
                helpSection(titleKey: "help.section.visits.title", bodyKey: "help.section.visits.body")
                helpSection(titleKey: "help.section.ai.title", bodyKey: "help.section.ai.body")
                helpSection(titleKey: "help.section.export.title", bodyKey: "help.section.export.body")
                helpSection(titleKey: "help.section.privacy.title", bodyKey: "help.section.privacy.body")

                Divider().padding(.vertical, 6)

                // Support / contact
                VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("help.footer.contact.title", comment: "Support contact section title"))
                        .font(.headline)

                    // Keep values as separate keys so they can be updated without touching code.
                    (Text("help.footer.contact.whatsapp.label") + Text(": ") + Text("help.footer.contact.whatsapp.value"))
                        .font(.body)
                        .textSelection(.enabled)

                    (Text("help.footer.contact.wechat.label") + Text(": ") + Text("help.footer.contact.wechat.value"))
                        .font(.body)
                        .textSelection(.enabled)

                    Text(NSLocalizedString("help.footer.contact.note", comment: "Support contact note"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.bottom, 4)

                Text(NSLocalizedString("help.footer.support", comment: "Help footer tip"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func helpSection(titleKey: String, bodyKey: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString(titleKey, comment: ""))
                .font(.headline)
            Text(NSLocalizedString(bodyKey, comment: ""))
                .font(.body)
                .textSelection(.enabled)
        }
        .padding(.bottom, 6)
    }
}

    // MARK: - Support log export (macOS)

    private func exportSupportLog() {
        #if os(macOS)
        Task {
            do {
                // 1) Create a temp support log from unified logging (current process)
                //    Include hashed context so the file can be correlated without leaking raw identifiers.
                var ctx: [String: String] = [:]

                if let bundleURL = appState.currentBundleURL {
                    ctx["bundle"] = AppLog.token(bundleURL.lastPathComponent)
                }
                if let pid = appState.selectedPatientID {
                    ctx["patient_id"] = AppLog.token(String(pid))
                }
                if let uid = appState.activeUserID {
                    ctx["clinician_id"] = AppLog.token(String(uid))
                }
                ctx["user_error"] = appState.userErrorStatus.rawValue

                let tmpURL = try SupportLogExporter.exportCurrentProcessLogs(
                    sinceSeconds: 1800,
                    maxEntries: 4000,
                    context: ctx
                )

                // 2) Ask user where to save it
                let panel = NSSavePanel()
                panel.canCreateDirectories = true
                panel.isExtensionHidden = false
                panel.nameFieldStringValue = tmpURL.lastPathComponent
                panel.allowedContentTypes = [.plainText]

                let response = panel.runModal()
                if response == .OK, let dstURL = panel.url {
                    // Replace if exists
                    if FileManager.default.fileExists(atPath: dstURL.path) {
                        try? FileManager.default.removeItem(at: dstURL)
                    }
                    try FileManager.default.copyItem(at: tmpURL, to: dstURL)

                    // Clean up temp file
                    try? FileManager.default.removeItem(at: tmpURL)

                    await MainActor.run {
                        let title = NSLocalizedString(
                            "support_log.export.success.title",
                            comment: "Title shown when support log export succeeded"
                        )
                        let message = String(
                            format: NSLocalizedString(
                                "support_log.export.success.message",
                                comment: "Message shown when support log export succeeded; placeholder is filename"
                            ),
                            dstURL.lastPathComponent
                        )
                        activeAlert = .supportLog(title: title, message: message, fileURL: dstURL)
                    }
                } else {
                    // User cancelled: no alert
                    try? FileManager.default.removeItem(at: tmpURL)
                }
            } catch {
                await MainActor.run {
                    appState.presentError(error, context: "Support Log")
                }
            }
        }
        #endif
    }
}

private struct SignInSheet: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var clinicianStore: ClinicianStore
    @Binding var showSignIn: Bool
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedID: Int? = nil
    @State private var firstName: String = ""
    @State private var lastName: String = ""
    @State private var password: String = ""
    @State private var loginError: String? = nil

    // Match the light blue "card" styling used elsewhere in the app, but keep it readable in Dark Mode.
    private var signInCardFill: Color {
        #if os(macOS)
        if colorScheme == .dark {
            // Use a system adaptive background in dark mode so text and controls remain legible.
            return Color(nsColor: NSColor.controlBackgroundColor)
        } else {
            return Color(nsColor: NSColor(calibratedRed: 0.88, green: 0.94, blue: 1.00, alpha: 1.0))
        }
        #else
        return Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.08)
        #endif
    }

    // Dynamic height for the clinician list: grow with item count, then scroll beyond a cap.
    private var cliniciansListHeight: CGFloat {
        // Rough per-row height for `clinicianRow` + padding/background.
        let rowH: CGFloat = 44
        let verticalPadding: CGFloat = 20 // LazyVStack padding(.vertical, 10)
        let count = max(1, clinicianStore.users.count)
        let contentH = CGFloat(count) * rowH + verticalPadding
        // Keep it compact for small lists, but avoid a tiny box.
        return min(260, max(80, contentH))
    }

    var body: some View {
        Group {
            #if os(macOS)
            NavigationStack {
                sheetContent
                    .navigationTitle("app.signin.title")
            }
            #else
            NavigationView {
                sheetContent
                    .navigationTitle("app.signin.title")
            }
            #endif
        }
        // Give the sheet a bit more breathing room.
        .frame(minWidth: 760, idealWidth: 860, maxWidth: 980,
               minHeight: 560, idealHeight: 640, maxHeight: 760,
               alignment: .center)
    }

    @ViewBuilder
    private var sheetContent: some View {
        VStack {
            Spacer(minLength: 0)

            HStack {
                Spacer(minLength: 0)

                VStack(spacing: 16) {
                    // Existing clinicians
                    if clinicianStore.users.isEmpty {
                        Text("app.signin.no_clinicians_found")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    } else {
                        cliniciansPicker
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
                // Keep the form centered and not stretched too wide.
                .frame(maxWidth: 560)
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(signInCardFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 4)

                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
    }

    @ViewBuilder
    private var cliniciansPicker: some View {
        #if os(macOS)
        // macOS: use a list-like scroll container that sizes to content, up to a max height.
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(clinicianStore.users, id: \.id) { u in
                        clinicianRow(u)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(selectedID == u.id
                                          ? Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.10)
                                          : Color.clear)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedID = u.id
                                loginError = nil
                                password = ""
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    let idToDelete = u.id
                                    clinicianStore.deleteUser(u)
                                    if selectedID == idToDelete { selectedID = nil }
                                } label: {
                                    Label("app.common.delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.vertical, 10)
            }
            // Expand naturally when a few users exist; scroll when many.
            .frame(height: cliniciansListHeight)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(colorScheme == .dark ? 0.14 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(colorScheme == .dark ? 0.26 : 0.15))
            )
        }
        #else
        // iOS: keep native List behavior.
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
                .swipeActions {
                    Button(role: .destructive) {
                        let idToDelete = u.id
                        clinicianStore.deleteUser(u)
                        if selectedID == idToDelete { selectedID = nil }
                    } label: {
                        Label("app.common.delete", systemImage: "trash")
                    }
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    let user = clinicianStore.users[index]
                    let idToDelete = user.id
                    clinicianStore.deleteUser(user)
                    if selectedID == idToDelete { selectedID = nil }
                }
            }
        }
        #endif
    }

    private func clinicianRow(_ u: Clinician) -> some View {
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
    }

}

// MARK: - Section styling helpers

private extension View {
    /// Applies a soft card-like tinted background + border, used for section blocks (GroupBox wrappers).
    /// We intentionally tint using the app accent color so the blocks are visually distinct from the window.
    func sectionCardBackground(tint: Color = .accentColor) -> some View {
        self
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(sectionCardFill(tint: tint))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(sectionCardStroke(tint: tint), lineWidth: 1)
            )
            // Subtle lift so the tint reads even on very light backgrounds.
            .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
    }

    private func sectionCardFill(tint: Color) -> Color {
        #if os(macOS)
        // macOS GroupBox tends to look “flat” on windowBackgroundColor.
        // A tiny accent tint makes each section clearly a separate block.
        return tint.opacity(0.07)
        #else
        // iOS: slightly stronger tint so it still reads over system backgrounds.
        return tint.opacity(0.10)
        #endif
    }

    private func sectionCardStroke(tint: Color) -> Color {
        // Use a neutral stroke; accent would be too loud.
        Color.secondary.opacity(0.18)
    }
}

private struct ClinicianProfileForm: View {
    @ObservedObject var clinicianStore: ClinicianStore
    @EnvironmentObject var appState: AppState
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

    // Guideline builder UI (avoids hand-editing JSON)
    @State private var showGuidelineBuilder: Bool = false
    @State private var guidelineBuilderError: String? = nil
    
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
                            .sectionCardBackground()

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
                            .sectionCardBackground()

                            GroupBox {
                                VStack(alignment: .leading, spacing: 10) {
                                    TextField("app.clinician_profile.societies", text: $societies)
                                        .textFieldStyle(.roundedBorder)
                                }
                                .padding(.top, 2)
                            } label: {
                                Text("app.clinician_profile.section.professional")
                            }
                            .sectionCardBackground()

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
                            .sectionCardBackground()
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
                            .sectionCardBackground()

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
                                            HStack(spacing: 10) {
                                                Button {
                                                    guidelineBuilderError = nil
                                                    showGuidelineBuilder = true
                                                } label: {
                                                    Text(NSLocalizedString("app.clinician_profile.guidelines.builder.open", comment: "Open guideline builder"))
                                                }
                                                .buttonStyle(.bordered)

                                                Button {
                                                    formatSickRulesJSONInPlace()
                                                } label: {
                                                    Text(NSLocalizedString("app.clinician_profile.guidelines.format", comment: "Format sick rules JSON"))
                                                }
                                                .buttonStyle(.bordered)

                                                #if os(macOS)
                                                Button {
                                                    exportSickRulesJSONToFile()
                                                } label: {
                                                    Text(NSLocalizedString("app.clinician_profile.guidelines.export", comment: "Export sick rules JSON"))
                                                }
                                                .buttonStyle(.bordered)
                                                #endif

                                                Spacer()

                                                // Lightweight validation hint
                                                if let err = guidelineBuilderError {
                                                    Text(err)
                                                        .font(.caption)
                                                        .foregroundStyle(.red)
                                                        .lineLimit(2)
                                                }
                                            }

                                            TextEditor(text: $aiSickRulesJSON)
                                                .frame(minHeight: 120)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(Color.secondary.opacity(0.2))
                                                )
                                                .onChange(of: aiSickRulesJSON) { _, newValue in
                                                    guidelineBuilderError = validateSickRulesJSON(newValue)
                                                }
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
                            .sectionCardBackground()

                            GroupBox {
                                VStack(alignment: .leading, spacing: 10) {
                                    if user != nil && hasPassword {
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

                                    if user != nil && hasPassword {
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
                            .sectionCardBackground()
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
        .sheet(isPresented: $showGuidelineBuilder) {
            GuidelineBuilderSheet(
                rulesJSON: $aiSickRulesJSON,
                terminology: appState.terminologyStore,
                onValidationMessage: { msg in
                    guidelineBuilderError = msg
                }
            )
            .frame(
                minWidth: 900,
                idealWidth: 1100,
                maxWidth: 1300,
                minHeight: 620,
                idealHeight: 760,
                maxHeight: 900
            )
        }
    }

    private func validateSickRulesJSON(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let data = Data(trimmed.utf8)

        // First: run a cheap JSON parse to get an error *location* (line/column) when possible.
        if let locMsg = jsonParseLocationErrorMessage(from: data, originalText: trimmed) {
            return locMsg
        }

        // Second: schema-level decode (gives better structural errors).
        do {
            _ = try JSONDecoder().decode(GuidelineDoc.self, from: data)
            return nil
        } catch {
            return "Invalid JSON (schema): \(error.localizedDescription)"
        }
    }

    private func formatSickRulesJSONInPlace() {
        let trimmed = aiSickRulesJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            guidelineBuilderError = NSLocalizedString(
                "app.clinician_profile.guidelines.format.empty",
                comment: "Shown when formatting an empty sick rules JSON"
            )
            return
        }

        let data = Data(trimmed.utf8)

        // If JSON is syntactically invalid, show a precise location.
        if let locMsg = jsonParseLocationErrorMessage(from: data, originalText: trimmed) {
            guidelineBuilderError = locMsg
            return
        }

        do {
            let decoded = try JSONDecoder().decode(GuidelineDoc.self, from: data)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let out = try enc.encode(decoded)
            aiSickRulesJSON = String(data: out, encoding: .utf8) ?? aiSickRulesJSON
            guidelineBuilderError = nil
        } catch {
            guidelineBuilderError = "Invalid JSON (schema): \(error.localizedDescription)"
        }
    }
    /// Returns a user-friendly JSON syntax error message with line/column if available.
    /// - Important: This only checks JSON *syntax*, not schema.
    private func jsonParseLocationErrorMessage(from data: Data, originalText: String) -> String? {
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
            return nil
        } catch {
            let ns = error as NSError
            // Apple uses NSJSONSerializationErrorDomain with the failing character index.
            let idx = ns.userInfo["NSJSONSerializationErrorIndex"] as? Int
            if let idx {
                let (line, col) = lineAndColumn(in: originalText, utf8Index: idx)
                // Keep this short; it will be shown inline next to the editor.
                return "Invalid JSON at line \(line), col \(col): \(ns.localizedDescription)"
            }
            return "Invalid JSON: \(ns.localizedDescription)"
        }
    }

    /// Compute 1-based (line, column) from a UTF-8 byte index.
    private func lineAndColumn(in text: String, utf8Index: Int) -> (Int, Int) {
        // Clamp to bounds; NSJSONSerializationErrorIndex can occasionally point at end.
        let bytes = Array(text.utf8)
        let i = max(0, min(utf8Index, bytes.count))

        var line = 1
        var col = 1
        var j = 0
        while j < i {
            if bytes[j] == 0x0A { // \n
                line += 1
                col = 1
            } else {
                col += 1
            }
            j += 1
        }
        return (line, col)
    }

#if os(macOS)
    private func exportSickRulesJSONToFile() {
        let text = aiSickRulesJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            guidelineBuilderError = NSLocalizedString(
                "app.clinician_profile.guidelines.export.empty",
                comment: "Shown when exporting an empty sick rules JSON"
            )
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "sick_guidelines.json"

        let response = panel.runModal()
        guard response == .OK, let dstURL = panel.url else { return }

        do {
            try text.data(using: .utf8)?.write(to: dstURL, options: [.atomic])
            guidelineBuilderError = nil
        } catch {
            guidelineBuilderError = error.localizedDescription
        }
    }
#endif
}

// MARK: - Guideline Builder (minimal, JSON-safe)

private struct GuidelineBuilderSheet: View {
    @Binding var rulesJSON: String
    let terminology: TerminologyStore
    let onValidationMessage: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var doc: GuidelineDoc = GuidelineDoc(schema_version: "1.0.0", rules: [])
    @State private var selectedRuleID: String? = nil
    @State private var parseError: String? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Button("app.common.cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("app.clinician_profile.guidelines.builder.add_rule") {
                        addRule()
                    }
                    .buttonStyle(.bordered)

                    Button("app.common.save") {
                        saveBackToJSON()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let parseError {
                    Text(parseError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 14) {
                    // Left: rule list
                    List(selection: $selectedRuleID) {
                        ForEach(doc.rules) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.id).font(.headline)
                                Text(r.flag).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(r.id)
                        }
                        .onDelete(perform: deleteRules)
                    }
                    .frame(minWidth: 320)

                    Divider()

                    // Right: editor
                    if let binding = selectedRuleBinding {
                        RuleEditor(rule: binding, terminology: terminology)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("app.clinician_profile.guidelines.builder.no_selection")
                                .foregroundStyle(.secondary)
                            Text("app.clinician_profile.guidelines.builder.tip")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            .padding(16)
            .navigationTitle("app.clinician_profile.guidelines.builder.title")
            .onAppear {
                loadFromJSON()
            }
        }
    }

    private var selectedRuleBinding: Binding<GuidelineRule>? {
        guard let selectedRuleID else { return nil }
        guard let idx = doc.rules.firstIndex(where: { $0.id == selectedRuleID }) else { return nil }
        return $doc.rules[idx]
    }

    private func loadFromJSON() {
        parseError = nil
        onValidationMessage(nil)

        let trimmed = rulesJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            doc = GuidelineDoc(schema_version: "1.0.0", rules: [])
            selectedRuleID = nil
            return
        }

        do {
            let data = Data(trimmed.utf8)

            // Prefer a syntax error with location if possible.
            do {
                _ = try JSONSerialization.jsonObject(with: data, options: [])
            } catch {
                let ns = error as NSError
                let idx = ns.userInfo["NSJSONSerializationErrorIndex"] as? Int
                if let idx {
                    let (line, col) = lineAndColumn(in: trimmed, utf8Index: idx)
                    parseError = "Invalid JSON at line \(line), col \(col): \(ns.localizedDescription)"
                } else {
                    parseError = "Invalid JSON: \(ns.localizedDescription)"
                }
                return
            }

            doc = try JSONDecoder().decode(GuidelineDoc.self, from: data)
            selectedRuleID = doc.rules.first?.id
        } catch {
            // Don't destroy the raw text; just surface the schema-level error.
            parseError = "Invalid JSON (schema): \(error.localizedDescription)"
        }
    }

    private func saveBackToJSON() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(doc)
            rulesJSON = String(data: data, encoding: .utf8) ?? rulesJSON
            onValidationMessage(nil)
        } catch {
            onValidationMessage(error.localizedDescription)
        }
    }

    private func addRule() {
        // Simple defaults; clinician can edit.
        let newID = "RULE_\(Int(Date().timeIntervalSince1970))"
        let r = GuidelineRule(
            id: newID,
            flag: "New guideline",
            priority: 10,
            when: GuidelineWhen(all: [GuidelineCondition(key: "", op: .present, value: nil)])
        )
        doc.rules.append(r)
        selectedRuleID = r.id
    }

    private func deleteRules(at offsets: IndexSet) {
        doc.rules.remove(atOffsets: offsets)
        selectedRuleID = doc.rules.first?.id
    }
}

private struct RuleEditor: View {
    @Binding var rule: GuidelineRule
    let terminology: TerminologyStore

    private enum ConditionScope: String, Equatable {
        case all
        case any
    }

    private enum PickerTarget: Equatable {
        case conditionKey(ConditionScope, UUID)
        case conditionAncestor(ConditionScope, UUID)
    }

    @State private var showSnomedPicker: Bool = false
    @State private var pickerTarget: PickerTarget? = nil

    @State private var snomedQuery: String = ""
    @State private var snomedHits: [TerminologyStore.TermHit] = []

    @State private var showKeyPicker: Bool = false
    @State private var keyPickerTarget: PickerTarget? = nil
    @State private var keySearch: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("ID", text: $rule.id)
                            .textFieldStyle(.roundedBorder)

                        TextField("Flag", text: $rule.flag)
                            .textFieldStyle(.roundedBorder)

                        TextEditor(
                            text: Binding(
                                get: { rule.note ?? "" },
                                set: { newValue in
                                    let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                    rule.note = t.isEmpty ? nil : t
                                }
                            )
                        )
                        .frame(minHeight: 90)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2))
                        )
                        .help("Optional: clinician instructions/warnings (stored in JSON, not evaluated yet).")

                        Stepper(value: $rule.priority, in: 0...100) {
                            Text("Priority: \(rule.priority)")
                        }
                    }
                    .padding(.top, 2)
                } label: {
                    Text("Rule")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach($rule.when.all) { $c in
                            VStack(alignment: .leading, spacing: 8) {

                                HStack(spacing: 8) {
                                    TextField("Feature key (e.g., sct:386661006)", text: $c.key)
                                        .textFieldStyle(.roundedBorder)

                                    Button {
                                        keyPickerTarget = .conditionKey(.all, c.id)
                                        keySearch = ""
                                        showKeyPicker = true
                                    } label: {
                                        Label("Keys", systemImage: "list.bullet")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Search and pick a clinical key emitted by the extractor.")

                                    Button {
                                        pickerTarget = .conditionKey(.all, c.id)
                                        snomedQuery = sanitizeQuery(from: c.key)
                                        refreshHits()
                                        showSnomedPicker = true
                                    } label: {
                                        Label("SNOMED", systemImage: "magnifyingglass")
                                    }
                                    .buttonStyle(.bordered)
                                }

                                Picker("Operator", selection: $c.op) {
                                    Text("present").tag(GuidelineCondition.Op.present)
                                    Text("absent").tag(GuidelineCondition.Op.absent)
                                    Text("descendant_of").tag(GuidelineCondition.Op.descendantOf)

                                    Divider()

                                    Text("equals").tag(GuidelineCondition.Op.equals)
                                    Text("not_equals").tag(GuidelineCondition.Op.notEquals)
                                    Text("gte").tag(GuidelineCondition.Op.gte)
                                    Text("lte").tag(GuidelineCondition.Op.lte)
                                    Text("between").tag(GuidelineCondition.Op.between)
                                    Text("one_of").tag(GuidelineCondition.Op.oneOf)
                                }
                                .pickerStyle(.menu)

                                if c.op == .equals || c.op == .notEquals {
                                    TextField("Value (text)", text: Binding(
                                        get: { c.value ?? "" },
                                        set: {
                                            c.value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                                            c.valueNumber = nil
                                            c.minNumber = nil
                                            c.maxNumber = nil
                                            c.values = nil
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                }

                                if c.op == .gte || c.op == .lte {
                                    TextField("Value (number)", text: Binding(
                                        get: { c.valueNumber.map { String($0) } ?? "" },
                                        set: {
                                            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                                            c.valueNumber = Double(t)
                                            c.value = nil
                                            c.minNumber = nil
                                            c.maxNumber = nil
                                            c.values = nil
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                }

                                if c.op == .between {
                                    HStack(spacing: 8) {
                                        TextField("Min", text: Binding(
                                            get: { c.minNumber.map { String($0) } ?? "" },
                                            set: { c.minNumber = Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                                        ))
                                        .textFieldStyle(.roundedBorder)

                                        TextField("Max", text: Binding(
                                            get: { c.maxNumber.map { String($0) } ?? "" },
                                            set: { c.maxNumber = Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                    }
                                    .onChange(of: c.minNumber) { _, _ in c.value = nil; c.valueNumber = nil; c.values = nil }
                                    .onChange(of: c.maxNumber) { _, _ in c.value = nil; c.valueNumber = nil; c.values = nil }
                                }

                                if c.op == .oneOf {
                                    TextField("Values (comma-separated)", text: Binding(
                                        get: { (c.values ?? []).joined(separator: ", ") },
                                        set: {
                                            c.values = $0
                                                .split(separator: ",")
                                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                                .filter { !$0.isEmpty }
                                            c.value = nil
                                            c.valueNumber = nil
                                            c.minNumber = nil
                                            c.maxNumber = nil
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                }

                                if c.op == .descendantOf {
                                    HStack(spacing: 8) {
                                        TextField(
                                            "Ancestor key (e.g., sct:404684003)",
                                            text: Binding(
                                                get: { c.value ?? "" },
                                                set: { c.value = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                            )
                                        )
                                        .textFieldStyle(.roundedBorder)

                                        Button {
                                            pickerTarget = .conditionAncestor(.all, c.id)
                                            snomedQuery = sanitizeQuery(from: c.value ?? "")
                                            refreshHits()
                                            showSnomedPicker = true
                                        } label: {
                                            Label("SNOMED", systemImage: "magnifyingglass")
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }

                                Divider()
                            }
                        }

                        Button("Add condition") {
                            rule.when.all.append(GuidelineCondition(key: "", op: .present, value: nil))
                        }
                        .buttonStyle(.bordered)

                        Text("Tip: Use Keys for common profile fields (age, fever duration, vitals), or SNOMED to insert an sct:<id> token.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                } label: {
                    Text("When (all)")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach($rule.when.any) { $c in
                            VStack(alignment: .leading, spacing: 8) {

                                HStack(spacing: 8) {
                                    TextField("Feature key (e.g., sct:386661006)", text: $c.key)
                                        .textFieldStyle(.roundedBorder)

                                    Button {
                                        keyPickerTarget = .conditionKey(.any, c.id)
                                        keySearch = ""
                                        showKeyPicker = true
                                    } label: {
                                        Label("Keys", systemImage: "list.bullet")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Search and pick a clinical key emitted by the extractor.")

                                    Button {
                                        pickerTarget = .conditionKey(.any, c.id)
                                        snomedQuery = sanitizeQuery(from: c.key)
                                        refreshHits()
                                        showSnomedPicker = true
                                    } label: {
                                        Label("SNOMED", systemImage: "magnifyingglass")
                                    }
                                    .buttonStyle(.bordered)
                                }

                                Picker("Operator", selection: $c.op) {
                                    Text("present").tag(GuidelineCondition.Op.present)
                                    Text("absent").tag(GuidelineCondition.Op.absent)
                                    Text("descendant_of").tag(GuidelineCondition.Op.descendantOf)

                                    Divider()

                                    Text("equals").tag(GuidelineCondition.Op.equals)
                                    Text("not_equals").tag(GuidelineCondition.Op.notEquals)
                                    Text("gte").tag(GuidelineCondition.Op.gte)
                                    Text("lte").tag(GuidelineCondition.Op.lte)
                                    Text("between").tag(GuidelineCondition.Op.between)
                                    Text("one_of").tag(GuidelineCondition.Op.oneOf)
                                }
                                .pickerStyle(.menu)

                                if c.op == .equals || c.op == .notEquals {
                                    TextField("Value (text)", text: Binding(
                                        get: { c.value ?? "" },
                                        set: {
                                            c.value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                                            c.valueNumber = nil
                                            c.minNumber = nil
                                            c.maxNumber = nil
                                            c.values = nil
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                }

                                if c.op == .gte || c.op == .lte {
                                    TextField("Value (number)", text: Binding(
                                        get: { c.valueNumber.map { String($0) } ?? "" },
                                        set: {
                                            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                                            c.valueNumber = Double(t)
                                            c.value = nil
                                            c.minNumber = nil
                                            c.maxNumber = nil
                                            c.values = nil
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                }

                                if c.op == .between {
                                    HStack(spacing: 8) {
                                        TextField("Min", text: Binding(
                                            get: { c.minNumber.map { String($0) } ?? "" },
                                            set: { c.minNumber = Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                                        ))
                                        .textFieldStyle(.roundedBorder)

                                        TextField("Max", text: Binding(
                                            get: { c.maxNumber.map { String($0) } ?? "" },
                                            set: { c.maxNumber = Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                    }
                                    .onChange(of: c.minNumber) { _, _ in c.value = nil; c.valueNumber = nil; c.values = nil }
                                    .onChange(of: c.maxNumber) { _, _ in c.value = nil; c.valueNumber = nil; c.values = nil }
                                }

                                if c.op == .oneOf {
                                    TextField("Values (comma-separated)", text: Binding(
                                        get: { (c.values ?? []).joined(separator: ", ") },
                                        set: {
                                            c.values = $0
                                                .split(separator: ",")
                                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                                .filter { !$0.isEmpty }
                                            c.value = nil
                                            c.valueNumber = nil
                                            c.minNumber = nil
                                            c.maxNumber = nil
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                }

                                if c.op == .descendantOf {
                                    HStack(spacing: 8) {
                                        TextField(
                                            "Ancestor key (e.g., sct:404684003)",
                                            text: Binding(
                                                get: { c.value ?? "" },
                                                set: { c.value = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                            )
                                        )
                                        .textFieldStyle(.roundedBorder)

                                        Button {
                                            pickerTarget = .conditionAncestor(.any, c.id)
                                            snomedQuery = sanitizeQuery(from: c.value ?? "")
                                            refreshHits()
                                            showSnomedPicker = true
                                        } label: {
                                            Label("SNOMED", systemImage: "magnifyingglass")
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }

                                Divider()
                            }
                        }

                        Button("Add OR condition") {
                            rule.when.any.append(GuidelineCondition(key: "", op: .present, value: nil))
                        }
                        .buttonStyle(.bordered)

                        Text("Any: at least one condition must match. Leave empty for pure AND rules.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                } label: {
                    Text("When (any)")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showKeyPicker) {
            GuidelineKeyPickerSheet(
                searchText: $keySearch,
                registry: ClinicalFeatureExtractor.guidelineKeyRegistry,
                onPick: { pickedKey in
                    applyPickedKey(pickedKey)
                    showKeyPicker = false
                },
                onCancel: {
                    showKeyPicker = false
                }
            )
            .frame(minWidth: 720, idealWidth: 860, maxWidth: 980,
                   minHeight: 560, idealHeight: 680, maxHeight: 800)
        }
        
    
        .sheet(isPresented: $showSnomedPicker) {
    
            SnomedPickerSheet(
                terminology: terminology,
                query: $snomedQuery,
                hits: $snomedHits,
                onPick: { hit in
                    applyPickedConcept(hit.conceptID)
                    showSnomedPicker = false
                },
                onCancel: {
                    showSnomedPicker = false
                }
            )
            .frame(minWidth: 700, idealWidth: 860, maxWidth: 980,
                   minHeight: 560, idealHeight: 680, maxHeight: 800)
        }
        .onChange(of: snomedQuery) { _, _ in
            refreshHits()
        }
    }
    
    private func applyPickedKey(_ key: String) {
        guard let target = keyPickerTarget else { return }
        switch target {
        case .conditionKey(let scope, let condUUID):
            switch scope {
            case .all:
                if let idx = rule.when.all.firstIndex(where: { $0.id == condUUID }) {
                    rule.when.all[idx].key = key
                }
            case .any:
                if let idx = rule.when.any.firstIndex(where: { $0.id == condUUID }) {
                    rule.when.any[idx].key = key
                }
            }
        case .conditionAncestor:
            // Not used by the key picker.
            break
        }
    }

    private func refreshHits() {
        let q = snomedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            snomedHits = []
            return
        }
        snomedHits = terminology.searchTerms(q, limit: 40)
    }

    private func sanitizeQuery(from raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // If user already has sct:12345, don't reuse that as a search query.
        if t.lowercased().hasPrefix("sct:") { return "" }
        return t
    }

    private func applyPickedConcept(_ conceptID: Int64) {
        guard let target = pickerTarget else { return }
        let token = "sct:\(conceptID)"

        switch target {
        case .conditionKey(let scope, let condUUID):
            switch scope {
            case .all:
                if let idx = rule.when.all.firstIndex(where: { $0.id == condUUID }) {
                    rule.when.all[idx].key = token
                }
            case .any:
                if let idx = rule.when.any.firstIndex(where: { $0.id == condUUID }) {
                    rule.when.any[idx].key = token
                }
            }

        case .conditionAncestor(let scope, let condUUID):
            switch scope {
            case .all:
                if let idx = rule.when.all.firstIndex(where: { $0.id == condUUID }) {
                    rule.when.all[idx].value = token
                }
            case .any:
                if let idx = rule.when.any.firstIndex(where: { $0.id == condUUID }) {
                    rule.when.any[idx].value = token
                }
            }
        }
    }
}

private struct SnomedPickerSheet: View {
    let terminology: TerminologyStore
    @Binding var query: String
    @Binding var hits: [TerminologyStore.TermHit]

    let onPick: (TerminologyStore.TermHit) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {

                HStack(spacing: 10) {
                    TextField(
                        NSLocalizedString("guideline.snomed_picker.search.placeholder", comment: "Placeholder for SNOMED search"),
                        text: $query
                    )
                    .textFieldStyle(.roundedBorder)

                    Button(NSLocalizedString("guideline.snomed_picker.clear", comment: "Clear SNOMED search")) {
                        query = ""
                        hits = []
                    }
                    .buttonStyle(.bordered)
                }

                if hits.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(NSLocalizedString("guideline.snomed_picker.empty.title", comment: "Shown when SNOMED search has no results yet"))
                            .foregroundStyle(.secondary)
                        Text(NSLocalizedString("guideline.snomed_picker.empty.tip", comment: "Example search terms for SNOMED picker"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 6)
                } else {
                    List(hits, id: \.id) { h in
                        Button {
                            onPick(h)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(h.term)
                                Text(h.subtitle ?? "sct:\(h.conceptID)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(14)
            .navigationTitle(NSLocalizedString("guideline.snomed_picker.title", comment: "Title of SNOMED picker sheet"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty {
                hits = terminology.searchTerms(q, limit: 40)
            }
        }
    }
}

// MARK: - Codable guideline document (matches GuidelineEngine v1)

private struct GuidelineDoc: Codable {
    var schema_version: String
    var rules: [GuidelineRule]
}

private struct GuidelineRule: Codable, Identifiable {
    var id: String
    var flag: String
    var priority: Int
    var note: String?
    var when: GuidelineWhen

    enum CodingKeys: String, CodingKey {
        case id
        case flag
        case priority
        case note
        case when
    }
}

private struct GuidelineWhen: Codable {
    var all: [GuidelineCondition]
    var any: [GuidelineCondition]

    init(all: [GuidelineCondition] = [], any: [GuidelineCondition] = []) {
        self.all = all
        self.any = any
    }

    enum CodingKeys: String, CodingKey {
        case all
        case any
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.all = try c.decodeIfPresent([GuidelineCondition].self, forKey: .all) ?? []
        self.any = try c.decodeIfPresent([GuidelineCondition].self, forKey: .any) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(all, forKey: .all)
        // Encode explicitly (even if empty) so the schema stays clear.
        try c.encode(any, forKey: .any)
    }
}

private struct GuidelineCondition: Codable, Identifiable {
    var id: UUID = UUID()
    var key: String
    var op: Op

    // String value (e.g., demographics.sex == "M")
    var value: String?

    // Numeric value (e.g., demographics.age_months >= 3)
    var valueNumber: Double?

    // Numeric range (e.g., age_months between 3 and 6)
    var minNumber: Double?
    var maxNumber: Double?

    // Enumerated string set (e.g., sex in ["M","F"])
    var values: [String]?

    enum CodingKeys: String, CodingKey {
        case key
        case op
        case value
        case valueNumber = "value_number"
        case minNumber   = "min_number"
        case maxNumber   = "max_number"
        case values
    }

    enum Op: String, Codable {
        case present
        case absent
        case descendantOf = "descendant_of"

        // NEW (for demographics, duration, vitals…)
        case equals = "equals"
        case notEquals = "not_equals"
        case gte = "gte"
        case lte = "lte"
        case between = "between"
        case oneOf = "one_of"
    }
}

    private func lineAndColumn(in text: String, utf8Index: Int) -> (Int, Int) {
        let bytes = Array(text.utf8)
        let i = max(0, min(utf8Index, bytes.count))

        var line = 1
        var col = 1
        var j = 0
        while j < i {
            if bytes[j] == 0x0A { // \n
                line += 1
                col = 1
            } else {
                col += 1
            }
            j += 1
        }
        return (line, col)
    }

private struct GuidelineKeyPickerSheet: View {
    @Binding var searchText: String
    let registry: [ClinicalFeatureExtractor.GuidelineKeyDescriptor]

    let onPick: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private var filtered: [ClinicalFeatureExtractor.GuidelineKeyDescriptor] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return registry }
        return registry.filter { d in
            let label = localized(d.labelKey)
            return d.searchBlob(localizedLabel: label).contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {

                HStack(spacing: 10) {
                    TextField(
                        NSLocalizedString("guideline.key_picker.search.placeholder", comment: "Placeholder for guideline key search"),
                        text: $searchText
                    )

                    Button(NSLocalizedString("guideline.key_picker.clear", comment: "Clear search button")) {
                        searchText = ""
                    }
                    .buttonStyle(.bordered)
                }

                if filtered.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(NSLocalizedString("guideline.key_picker.empty.title", comment: "Shown when no keys match search"))
                            .foregroundStyle(.secondary)
                        Text(NSLocalizedString("guideline.key_picker.empty.tip", comment: "Tip for searching keys"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 6)
                } else {
                    List {
                        ForEach(ClinicalFeatureExtractor.GuidelineKeyCategory.allCases, id: \.self) { cat in
                            let rows = filtered
                                .filter { $0.category == cat }
                                .sorted { localized($0.labelKey).localizedCaseInsensitiveCompare(localized($1.labelKey)) == .orderedAscending }

                            if !rows.isEmpty {
                                Section {
                                    ForEach(rows, id: \.id) { d in
                                        Button {
                                            onPick(d.key)
                                            dismiss()
                                        } label: {
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(localized(d.labelKey))
                                                Text(d.key)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                if let ex = d.example, !ex.isEmpty {
                                                    Text(ex)
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                } header: {
                                    Text(localized(cat.labelKey))
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
            .navigationTitle(NSLocalizedString("guideline.key_picker.title", comment: "Title of guideline key picker sheet"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("common.cancel", comment: "Cancel")) {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
    }
}
