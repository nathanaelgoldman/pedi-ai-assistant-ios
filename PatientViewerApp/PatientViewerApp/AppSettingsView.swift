//
//  AppSettingsView.swift
//  PatientViewerApp
//
//  Created by yunastic on 12/12/25.
//
import SwiftUI

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

                // MARK: - About
                Section {
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
