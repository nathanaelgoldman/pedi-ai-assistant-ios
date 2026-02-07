//
//  AppSettingsView.swift
//  PatientViewerApp
//
//  Created by yunastic on 12/12/25.
//
import SwiftUI
import UIKit

// MARK: - Localization (file-local)
@inline(__always)
private func L(_ key: String, comment: String = "") -> String {
    NSLocalizedString(key, comment: comment)
}

@inline(__always)
private func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

struct AppSettingsView: View {
    @EnvironmentObject var appLock: AppLockManager
    @Environment(\.dismiss) private var dismiss

    @State private var currentPasscode: String = ""
    @State private var newPasscode: String = ""
    @State private var confirmPasscode: String = ""

    @State private var statusMessage: String?
    @State private var isError: Bool = false

    // MARK: - Support Log (off by default)
    @StateObject private var supportLog = SupportLog.shared
    
    

    private struct SupportSharePayload: Identifiable {
        let id = UUID()
        let items: [Any]
    }

    @State private var supportSharePayload: SupportSharePayload? = nil

    // MARK: - De-dupe UI open/close logs
    // SwiftUI can trigger onAppear/onDisappear more than once (e.g., NavigationView layout passes).
    // We track presence with a shared ref-count and only log on 0->1 and 1->0 transitions.
    @MainActor
    private final class _Presence {
        static let shared = _Presence()
        var count: Int = 0

        // SwiftUI can fire appear/disappear twice in quick succession during layout.
        // We suppress identical open/close logs within a small window.
        var lastOpenLogAt: Date? = nil
        var lastCloseLogAt: Date? = nil
        let dedupeWindow: TimeInterval = 0.5
    }

    @MainActor
    private func logOpenOnce() {
        let p = _Presence.shared
        let was = p.count
        p.count = was + 1

        guard was == 0 else { return }

        let now = Date()
        if let last = p.lastOpenLogAt, now.timeIntervalSince(last) < p.dedupeWindow {
            return
        }
        p.lastOpenLogAt = now
        SL("UI open settings")
    }

    @MainActor
    private func logCloseOnce() {
        let p = _Presence.shared
        if p.count > 0 { p.count -= 1 }

        guard p.count == 0 else { return }

        let now = Date()
        if let last = p.lastCloseLogAt, now.timeIntervalSince(last) < p.dedupeWindow {
            return
        }
        p.lastCloseLogAt = now
        SL("UI close settings")
    }
    
    private func setSupportLogEnabled(_ enabled: Bool) {
        if enabled {
            supportLog.setEnabled(true)
            SL("SupportLog enabled")
        } else {
            // Log BEFORE disabling so the event is captured.
            SL("SupportLog disabled")
            supportLog.setEnabled(false)
        }
    }

    // MARK: - SupportLog helpers
    private func SL(_ message: String) {
        // SupportLog methods are @MainActor; wrapping avoids cross-actor errors.
        Task { await supportLog.info(message) }
    }

    private func SLerr(_ message: String) {
        Task { await supportLog.error(message) }
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.12))
                                .frame(width: 40, height: 40)
                            Image(systemName: appLock.isLockEnabled ? "lock.fill" : "lock.open")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.accentColor)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(appLock.isLockEnabled
                                 ? L("patient_viewer.app_settings.app_lock.status_enabled", comment: "App Lock status")
                                 : L("patient_viewer.app_settings.app_lock.status_disabled", comment: "App Lock status"))
                                .font(.headline)

                            Text(L("patient_viewer.app_settings.app_lock.subtitle", comment: "App Lock subtitle"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(L("patient_viewer.app_settings.app_lock.header", comment: "Section header"))
                }

                if appLock.isLockEnabled {
                    Section(L("patient_viewer.app_settings.change_passcode.section", comment: "Section title")) {
                        SecureField(L("patient_viewer.app_settings.field.current_passcode", comment: "Field placeholder"), text: $currentPasscode)
                            .textContentType(.password)

                        SecureField(L("patient_viewer.app_settings.field.new_passcode", comment: "Field placeholder"), text: $newPasscode)
                            .textContentType(.newPassword)

                        SecureField(L("patient_viewer.app_settings.field.confirm_new_passcode", comment: "Field placeholder"), text: $confirmPasscode)
                            .textContentType(.newPassword)

                        Button {
                            changePasscode()
                        } label: {
                            Label(L("patient_viewer.app_settings.action.change_passcode", comment: "Button"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newPasscode.isEmpty || confirmPasscode.isEmpty)
                    }

                    Section(L("patient_viewer.app_settings.turn_off.section", comment: "Section title")) {
                        SecureField(L("patient_viewer.app_settings.field.current_passcode", comment: "Field placeholder"), text: $currentPasscode)
                            .textContentType(.password)

                        Button(role: .destructive) {
                            removePasscode()
                        } label: {
                            Label(L("patient_viewer.app_settings.action.remove_passcode", comment: "Button"), systemImage: "lock.open")
                        }
                        .disabled(currentPasscode.isEmpty)
                    }
                } else {
                    Section(L("patient_viewer.app_settings.setup.section", comment: "Section title")) {
                        SecureField(L("patient_viewer.app_settings.field.new_passcode", comment: "Field placeholder"), text: $newPasscode)
                            .textContentType(.newPassword)

                        SecureField(L("patient_viewer.app_settings.field.confirm_new_passcode", comment: "Field placeholder"), text: $confirmPasscode)
                            .textContentType(.newPassword)

                        Button {
                            setInitialPasscode()
                        } label: {
                            Label(L("patient_viewer.app_settings.action.set_passcode", comment: "Button"), systemImage: "lock")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newPasscode.isEmpty || confirmPasscode.isEmpty)
                    }
                }

                if let message = statusMessage {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundColor(isError ? .red : .green)
                            Text(message)
                                .font(.footnote)
                        }
                        .padding(.vertical, 2)
                    }
                }

                // MARK: - Support Log
                Section {
                    Toggle(isOn: Binding(
                        get: { supportLog.isEnabled },
                        set: { setSupportLogEnabled($0) }
                    )) {
                        HStack(spacing: 10) {
                            Label(
                                L("patient_viewer.app_settings.support_log.toggle", comment: "Support logging toggle"),
                                systemImage: "doc.text.magnifyingglass"
                            )

                            Spacer(minLength: 8)

                            // Visible state badge when enabled
                            if supportLog.isEnabled {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("ON")
                                        .font(.caption.weight(.semibold))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.yellow.opacity(0.22))
                                )
                                .foregroundColor(.orange)
                                .accessibilityLabel(Text("Support logging is ON"))
                            }
                        }
                    }

                    Button {
                        SL("SET support log share tap")
                        shareSupportLog()
                    } label: {
                        Label(
                            L("patient_viewer.app_settings.support_log.share", comment: "Share support log button"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .disabled(!supportLog.isEnabled)

                    Button(role: .destructive) {
                        SL("SET support log clear tap")
                        supportLog.clear()
                        showSuccess(L("patient_viewer.app_settings.support_log.cleared", comment: "Support log cleared"))
                    } label: {
                        Label(
                            L("patient_viewer.app_settings.support_log.clear", comment: "Clear support log button"),
                            systemImage: "trash"
                        )
                    }
                    .disabled(!supportLog.isEnabled)

                    if supportLog.isEnabled {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(L("patient_viewer.app_settings.support_log.hint", comment: "Support log hint"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                } header: {
                    Text(L("patient_viewer.app_settings.support_log.header", comment: "Support log section header"))
                }

                // MARK: - Help + About
                Section {
                    NavigationLink {
                        HelpCareViewKidsView()
                    } label: {
                        Label(
                            L("patient_viewer.app_settings.help.title", comment: "Help section title"),
                            systemImage: "questionmark.circle"
                        )
                    }

                    NavigationLink {
                        AboutCareViewKidsView()
                    } label: {
                        Label(
                            L("patient_viewer.app_settings.about.title", comment: "About section title"),
                            systemImage: "info.circle"
                        )
                    }
                }
            }
            .appListBackground()
            .appNavBarBackground()
            .navigationTitle(L("patient_viewer.app_settings.nav_title", comment: "Navigation title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("patient_viewer.app_settings.done", comment: "Done button")) { dismiss() }
                }
            }
            .sheet(item: $supportSharePayload, onDismiss: {
                SL("SET support log share sheet dismissed")
                supportSharePayload = nil
            }) { payload in
                ShareSheet(activityItems: payload.items)
            }
            .onAppear {
                logOpenOnce()
            }
            .onDisappear {
                logCloseOnce()
            }
        }
    }

    // MARK: - Support Log helpers
    private func shareSupportLog() {
        Task {
            SL("SET support log export start")
            do {
                // Generate the log file.
                let url = try await Task.detached(priority: .utility) {
                    try await supportLog.exportURL()
                }.value

                // Verify the file is readable and non-empty.
                let data = try Data(contentsOf: url)
                if data.isEmpty {
                    throw NSError(domain: "SupportLog", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Support log is empty."
                    ])
                }

                // Prefer sharing as plain text (most reliable).
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)

                await MainActor.run {
                    // Creating a new payload forces the sheet (and UIActivityViewController) to be recreated.
                    supportSharePayload = SupportSharePayload(items: [text])
                    // Emit after payload is set to confirm the sheet should present.
                    SL("SET support log share sheet present")
                }
                SL("SET support log export ok")
            } catch {
                SLerr("SET support log export failed | err=\(error.localizedDescription)")
                showError(LF("patient_viewer.app_settings.support_log.error.export_failed_fmt",
                             error.localizedDescription))
            }
        }
    }

    // MARK: - Actions

    private func setInitialPasscode() {
        guard newPasscode == confirmPasscode else {
            showError(L("patient_viewer.app_settings.error.passcodes_do_not_match", comment: "Error"))
            return
        }
        guard !newPasscode.isEmpty else {
            showError(L("patient_viewer.app_settings.error.passcode_cannot_be_empty", comment: "Error"))
            return
        }

        do {
            try appLock.setPassword(newPasscode)
            clearFields()
            showSuccess(L("patient_viewer.app_settings.success.passcode_set_enabled", comment: "Success"))
        } catch {
            showError(LF("patient_viewer.app_settings.error.failed_to_set_passcode", error.localizedDescription))
        }
    }

    private func changePasscode() {
        guard appLock.verifyPassword(currentPasscode) else {
            showError(L("patient_viewer.app_settings.error.current_passcode_incorrect", comment: "Error"))
            return
        }
        guard newPasscode == confirmPasscode else {
            showError(L("patient_viewer.app_settings.error.new_passcodes_do_not_match", comment: "Error"))
            return
        }
        guard !newPasscode.isEmpty else {
            showError(L("patient_viewer.app_settings.error.new_passcode_cannot_be_empty", comment: "Error"))
            return
        }

        do {
            try appLock.setPassword(newPasscode)
            clearFields()
            showSuccess(L("patient_viewer.app_settings.success.passcode_updated", comment: "Success"))
        } catch {
            showError(LF("patient_viewer.app_settings.error.failed_to_update_passcode", error.localizedDescription))
        }
    }

    private func removePasscode() {
        guard appLock.verifyPassword(currentPasscode) else {
            showError(L("patient_viewer.app_settings.error.current_passcode_incorrect", comment: "Error"))
            return
        }

        appLock.clearPassword()
        clearFields()
        showSuccess(L("patient_viewer.app_settings.success.passcode_removed_disabled", comment: "Success"))
    }

    private func clearFields() {
        currentPasscode = ""
        newPasscode = ""
        confirmPasscode = ""
    }

    private func showError(_ message: String) {
        statusMessage = message
        isError = true
    }

    private func showSuccess(_ message: String) {
        statusMessage = message
        isError = false
    }
}


// MARK: - Help screen (offline)

private struct HelpCareViewKidsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("patient_viewer.help.header.title", comment: "Help header title"))
                        .font(.headline)

                    Text(L("patient_viewer.help.header.subtitle", comment: "Help header subtitle"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section(L("patient_viewer.help.section.quick_start", comment: "Help section header")) {
                HelpBullet("patient_viewer.help.quick_start.item.open_bundle", systemImage: "folder")
                HelpBullet("patient_viewer.help.quick_start.item.import_bundle", systemImage: "tray.and.arrow.down")
                HelpBullet("patient_viewer.help.quick_start.item.export_bundle", systemImage: "square.and.arrow.up")
            }

            Section(L("patient_viewer.help.section.what_you_can_do", comment: "Help section header")) {
                HelpBullet("patient_viewer.help.can_do.item.visits", systemImage: "list.bullet.rectangle")
                HelpBullet("patient_viewer.help.can_do.item.growth", systemImage: "chart.line.uptrend.xyaxis")
                HelpBullet("patient_viewer.help.can_do.item.parent_notes", systemImage: "text.bubble")
                HelpBullet("patient_viewer.help.can_do.item.documents", systemImage: "paperclip")
            }

            Section(L("patient_viewer.help.section.privacy", comment: "Help section header")) {
                Text(L("patient_viewer.help.privacy.body", comment: "Help privacy body"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(L("patient_viewer.help.footer.tip", comment: "Help footer tip"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .appListBackground()
        .appNavBarBackground()
        .navigationTitle(L("patient_viewer.app_settings.help.nav_title", comment: "Help nav title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L("patient_viewer.app_settings.done", comment: "Done button")) { dismiss() }
            }
        }
    }
}

private struct HelpBullet: View {
    let key: String
    let systemImage: String

    init(_ key: String, systemImage: String) {
        self.key = key
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(L(key, comment: "Help bullet"))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundColor(.accentColor)
        }
    }
}

// MARK: - About screen

private struct AboutCareViewKidsView: View {
    @Environment(\.dismiss) private var dismiss

    private var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? "CareView Kids"
    }

    private var versionString: String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "-"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "-"
        return "\(version) (\(build))"
    }

    private var bundleID: String {
        Bundle.main.bundleIdentifier ?? "-"
    }

    // TODO: Replace placeholders with your real contacts.
    private let whatsappContact = "+32475416394"   // E.164 recommended (e.g. +14155552671)
    private let wechatContact = "yunastic"          // e.g. CareViewKids

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(appName)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .allowsTightening(true)

                    Text(L("patient_viewer.app_settings.about.subtitle", comment: "About subtitle"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section(L("patient_viewer.app_settings.about.section.app_info", comment: "About section")) {
                AboutRow(labelKey: "patient_viewer.app_settings.about.row.version", value: versionString)
                AboutRow(labelKey: "patient_viewer.app_settings.about.row.bundle_id", value: bundleID)
            }

            Section(L("patient_viewer.app_settings.about.section.privacy", comment: "About section")) {
                Text(L("patient_viewer.app_settings.about.privacy.body", comment: "Privacy blurb"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(L("patient_viewer.app_settings.about.section.support", comment: "About section")) {

                // WhatsApp
                Button {
                    copyToPasteboard(whatsappContact)
                } label: {
                    Label(
                        String(format: L("patient_viewer.app_settings.about.support.whatsapp_fmt", comment: "WhatsApp label"), whatsappContact),
                        systemImage: "message"
                    )
                }

                // WeChat
                Button {
                    copyToPasteboard(wechatContact)
                } label: {
                    Label(
                        String(format: L("patient_viewer.app_settings.about.support.wechat_fmt", comment: "WeChat label"), wechatContact),
                        systemImage: "qrcode"
                    )
                }

                Text(L("patient_viewer.app_settings.about.support.tap_to_copy", comment: "Support hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(L("patient_viewer.app_settings.about.credits", comment: "Credits"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .appListBackground()
        .appNavBarBackground()
        .navigationTitle(L("patient_viewer.app_settings.about.nav_title", comment: "About nav title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L("patient_viewer.app_settings.done", comment: "Done button")) { dismiss() }
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        UIPasteboard.general.string = text
    }
}

private struct AboutRow: View {
    let labelKey: String
    let value: String

    var body: some View {
        HStack {
            Text(L(labelKey, comment: "About row label"))
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}


// MARK: - Share sheet (UIKit bridge)
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var excludedActivityTypes: [UIActivity.ActivityType]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        vc.excludedActivityTypes = excludedActivityTypes

        // iPad: must provide a popover anchor, otherwise UIActivityViewController can show a blank/white sheet.
        if let popover = vc.popoverPresentationController {
            if let anchor = UIApplication.shared._supportLogTopMostViewController()?.view {
                popover.sourceView = anchor
                popover.sourceRect = CGRect(
                    x: anchor.bounds.midX,
                    y: anchor.bounds.midY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
        }

        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // no-op
    }
}

// Helper to locate a safe presentation anchor for popovers (iPad) and other modal UI.
private extension UIApplication {
    func _supportLogTopMostViewController() -> UIViewController? {
        // Prefer the active foreground scene.
        let scenes = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }

        for scene in scenes {
            if let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
                return root._supportLogTopMostPresented()
            }
        }

        // Fallback: any key window we can find.
        if let root = windows.first(where: { $0.isKeyWindow })?.rootViewController {
            return root._supportLogTopMostPresented()
        }

        return nil
    }
}

private extension UIViewController {
    func _supportLogTopMostPresented() -> UIViewController {
        if let presented = presentedViewController {
            return presented._supportLogTopMostPresented()
        }
        if let nav = self as? UINavigationController, let visible = nav.visibleViewController {
            return visible._supportLogTopMostPresented()
        }
        if let tab = self as? UITabBarController, let selected = tab.selectedViewController {
            return selected._supportLogTopMostPresented()
        }
        return self
    }
}
