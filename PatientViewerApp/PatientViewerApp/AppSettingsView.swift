//
//  AppSettingsView.swift
//  PatientViewerApp
//
//  Created by yunastic on 12/12/25.
//
import SwiftUI

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
                            Text(appLock.isLockEnabled ? "App Lock enabled" : "App Lock disabled")
                                .font(.headline)

                            Text("Protect access to this app with a simple passcode.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("App Lock")
                }

                if appLock.isLockEnabled {
                    Section("Change passcode") {
                        SecureField("Current passcode", text: $currentPasscode)
                            .textContentType(.password)

                        SecureField("New passcode", text: $newPasscode)
                            .textContentType(.newPassword)

                        SecureField("Confirm new passcode", text: $confirmPasscode)
                            .textContentType(.newPassword)

                        Button {
                            changePasscode()
                        } label: {
                            Label("Change Passcode", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newPasscode.isEmpty || confirmPasscode.isEmpty)
                    }

                    Section("Turn off App Lock") {
                        SecureField("Current passcode", text: $currentPasscode)
                            .textContentType(.password)

                        Button(role: .destructive) {
                            removePasscode()
                        } label: {
                            Label("Remove Passcode", systemImage: "lock.open")
                        }
                        .disabled(currentPasscode.isEmpty)
                    }
                } else {
                    Section("Set up App Lock") {
                        SecureField("New passcode", text: $newPasscode)
                            .textContentType(.newPassword)

                        SecureField("Confirm new passcode", text: $confirmPasscode)
                            .textContentType(.newPassword)

                        Button {
                            setInitialPasscode()
                        } label: {
                            Label("Set Passcode", systemImage: "lock")
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
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Actions

    private func setInitialPasscode() {
        guard newPasscode == confirmPasscode else {
            showError("Passcodes do not match.")
            return
        }
        guard !newPasscode.isEmpty else {
            showError("Passcode cannot be empty.")
            return
        }

        do {
            try appLock.setPassword(newPasscode)
            clearFields()
            showSuccess("Passcode set. App Lock is now enabled.")
        } catch {
            showError("Failed to set passcode: \(error.localizedDescription)")
        }
    }

    private func changePasscode() {
        guard appLock.verifyPassword(currentPasscode) else {
            showError("Current passcode is incorrect.")
            return
        }
        guard newPasscode == confirmPasscode else {
            showError("New passcodes do not match.")
            return
        }
        guard !newPasscode.isEmpty else {
            showError("New passcode cannot be empty.")
            return
        }

        do {
            try appLock.setPassword(newPasscode)
            clearFields()
            showSuccess("Passcode updated.")
        } catch {
            showError("Failed to update passcode: \(error.localizedDescription)")
        }
    }

    private func removePasscode() {
        guard appLock.verifyPassword(currentPasscode) else {
            showError("Current passcode is incorrect.")
            return
        }

        appLock.clearPassword()
        clearFields()
        showSuccess("Passcode removed. App Lock is now disabled.")
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
