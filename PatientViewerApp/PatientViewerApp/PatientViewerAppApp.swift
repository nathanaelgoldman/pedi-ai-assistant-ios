//
//  PatientViewerAppApp.swift
//  PatientViewerApp
//
//  Created by yunastic on 10/9/25.
//

import SwiftUI

// MARK: - SupportLog Environment key (writable + cross-file accessible)

private struct SupportLogKey: EnvironmentKey {
    static let defaultValue: SupportLog = .shared
}

extension EnvironmentValues {
    /// App-wide support log instance. Injected at the App root.
    var supportLog: SupportLog {
        get { self[SupportLogKey.self] }
        set { self[SupportLogKey.self] = newValue }
    }
}

@main
struct PatientViewerAppApp: App {
    @StateObject private var appLock = AppLockManager()

    init() {
        // Root-level lifecycle marker for support.
        SupportLog.shared.info("APP start")
    }

    var body: some Scene {
        WindowGroup {
            RootShellView()
                .environmentObject(appLock)
                // Provide SupportLog to the whole view tree (safe for sheets / previews / deep views)
                .environment(\.supportLog, .shared)
        }
    }
}

/// Root shell that hosts the existing ContentView and overlays the lock screen when needed.
struct RootShellView: View {
    @EnvironmentObject var appLock: AppLockManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.supportLog) private var supportLog

    private func S(_ message: String) {
        Task { @MainActor in
            supportLog.info(message)
        }
    }

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
        .onAppear {
            S("UI root appeared")
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                S("APP scenePhase=background")
                // Auto-lock when app goes to background if a passcode exists
                appLock.lockIfNeeded()
                S("APP auto-lock requested")
            case .inactive:
                S("APP scenePhase=inactive")
                // Auto-lock when app goes inactive if a passcode exists
                appLock.lockIfNeeded()
                S("APP auto-lock requested")
            case .active:
                S("APP scenePhase=active")
            @unknown default:
                S("APP scenePhase=unknown")
            }
        }
    }
}

/// Minimal lock screen UI that asks for the app-level passcode.
struct LockScreenView: View {
    @EnvironmentObject var appLock: AppLockManager
    @Environment(\.supportLog) private var supportLog
    @State private var passcode: String = ""
    @State private var errorMessage: String?

    private func S(_ message: String) {
        Task { @MainActor in
            supportLog.info(message)
        }
    }

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

                    Text(NSLocalizedString("lock_screen.title", comment: "Lock screen title"))
                        .font(.title2.weight(.semibold))

                    Text(NSLocalizedString("lock_screen.subtitle", comment: "Lock screen helper text"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                // Passcode + error
                VStack(spacing: 10) {
                    SecureField(NSLocalizedString("lock_screen.passcode.placeholder", comment: "Passcode field placeholder"), text: $passcode)
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
                        S("LOCK unlock attempt (passcode)")
                        let ok = appLock.unlock(with: passcode)
                        if ok {
                            S("LOCK unlock ok (passcode)")
                            passcode = ""
                            errorMessage = nil
                        } else {
                            S("LOCK unlock failed (passcode)")
                            errorMessage = NSLocalizedString("lock_screen.error.incorrect_passcode", comment: "Incorrect passcode error")
                            passcode = ""
                        }
                    } label: {
                        Text(NSLocalizedString("lock_screen.action.unlock", comment: "Unlock button"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: 320)

                    if appLock.canUseBiometrics {
                        Button {
                            S("LOCK unlock attempt (biometrics)")
                            appLock.unlockWithBiometrics { success in
                                if success {
                                    Task { @MainActor in
                                        supportLog.info("LOCK unlock ok (biometrics)")
                                    }
                                    errorMessage = nil
                                    passcode = ""
                                } else {
                                    Task { @MainActor in
                                        supportLog.warn("LOCK unlock failed (biometrics)")
                                    }
                                    // Non-fatal: user can still unlock with passcode
                                    errorMessage = NSLocalizedString("lock_screen.error.biometric_failed", comment: "Biometrics failed error")
                                }
                            }
                        } label: {
                            Label(NSLocalizedString("lock_screen.action.use_biometrics", comment: "Use biometrics button"), systemImage: "faceid")
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
