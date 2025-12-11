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
        VStack(spacing: 16) {
            Text("🔒 Patient Viewer Locked")
                .font(.title2).bold()

            SecureField("Enter passcode", text: $passcode)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button("Unlock") {
                let ok = appLock.unlock(with: passcode)
                if ok {
                    passcode = ""
                    errorMessage = nil
                } else {
                    errorMessage = "Incorrect passcode. Please try again."
                    passcode = ""
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(radius: 10)
        )
    }
}
