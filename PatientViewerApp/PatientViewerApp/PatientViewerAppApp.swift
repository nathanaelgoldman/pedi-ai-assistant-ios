//
//  PatientViewerAppApp.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/9/25.
//

import SwiftUI

@main
struct PatientViewerAppApp: App {
    @StateObject private var appLock = AppLockManager()

    var body: some Scene {
        WindowGroup {
            RootShellView()
                .environmentObject(appLock)
        }
    }
}

/// Root shell that hosts the existing ContentView and overlays the lock screen when needed.
struct RootShellView: View {
    @EnvironmentObject var appLock: AppLockManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            // Your existing main UI
            ContentView()
                .blur(radius: appLock.isLocked ? 10 : 0)
                .disabled(appLock.isLocked)

            if appLock.isLocked {
                LockScreenView()
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background, .inactive:
                // Auto-lock when app goes to background if a passcode exists
                appLock.lockIfNeeded()
            default:
                break
            }
        }
    }
}

/// Minimal lock screen UI that asks for the app-level passcode.
struct LockScreenView: View {
    @EnvironmentObject var appLock: AppLockManager
    @State private var passcode: String = ""
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            // Dimmed backdrop over the blurred content
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                // Header: icon + title + helper text
                VStack(spacing: 8) {
                    Image(systemName: "lock.circle.fill")
                        .font(.system(size: 52, weight: .semibold))
                        .foregroundStyle(.tint)

                    Text("Patient Viewer Locked")
                        .font(.title2.weight(.semibold))

                    Text("Enter your passcode or use Face ID / Touch ID to continue.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                // Passcode + error
                VStack(spacing: 10) {
                    SecureField("Passcode", text: $passcode)
                        .textContentType(.password)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )
                        .frame(maxWidth: 320)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .frame(maxWidth: 320, alignment: .leading)
                            .transition(.opacity)
                    }
                }

                // Actions
                VStack(spacing: 12) {
                    Button {
                        let ok = appLock.unlock(with: passcode)
                        if ok {
                            passcode = ""
                            errorMessage = nil
                        } else {
                            errorMessage = "Incorrect passcode. Please try again."
                            passcode = ""
                        }
                    } label: {
                        Text("Unlock")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: 320)

                    if appLock.canUseBiometrics {
                        Button {
                            appLock.unlockWithBiometrics { success in
                                if success {
                                    errorMessage = nil
                                    passcode = ""
                                } else {
                                    // Non-fatal: user can still unlock with passcode
                                    errorMessage = "Biometric authentication failed. You can try again or use your passcode."
                                }
                            }
                        } label: {
                            Label("Use Face ID / Touch ID", systemImage: "faceid")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(maxWidth: 320)
                    }
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.systemBackground).opacity(0.96))
                    .shadow(color: Color.black.opacity(0.25), radius: 20, x: 0, y: 10)
            )
            .padding(.horizontal, 24)
        }
    }
}
