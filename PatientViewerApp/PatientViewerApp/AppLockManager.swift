///
//  AppLockManager.swift
//  PatientViewerApp
//
//  Simple app-level lock manager.
//  - Stores a hashed password in Keychain
//  - Remembers via UserDefaults whether the lock is enabled
//  - Exposes `isLocked` so the UI can show/hide the app content
//

import Foundation
import Security
import CryptoKit
import LocalAuthentication
import Combine

@MainActor
final class AppLockManager: ObservableObject {
    /// Whether the user has configured an app lock password.
    @Published private(set) var isLockEnabled: Bool

    /// Whether the app is currently locked (used by the UI to show lock screen).
    @Published private(set) var isLocked: Bool

    private let lockEnabledKey = "AppLock.Enabled"

    // Keychain identifiers
    private let keychainService = "Yunastic.PatientViewerApp.AppLock"
    private let keychainAccount = "AppLockPasswordHash"

    init() {
        let enabled = UserDefaults.standard.bool(forKey: lockEnabledKey)
        self.isLockEnabled = enabled
        // If lock is enabled, start in locked state; otherwise unlocked.
        self.isLocked = enabled
    }

    // MARK: - Public API

    /// Enable or change the lock password.
    /// Callers should already have confirmed "new" and "confirm" match.
    func setPassword(_ password: String) throws {
        let hash = sha256(password)
        try storePasswordHash(hash)

        UserDefaults.standard.set(true, forKey: lockEnabledKey)
        isLockEnabled = true
        // Do NOT force-lock immediately; let the user keep using the app.
        // Lock will apply on next background/launch when `lockIfNeeded()` is called.
    }

    /// Clear the lock and remove the stored password hash.
    func clearPassword() {
        deletePasswordHash()
        UserDefaults.standard.removeObject(forKey: lockEnabledKey)
        isLockEnabled = false
        isLocked = false
    }

    /// Lock the app if a password has been configured.
    /// Call this from scenePhase changes (e.g. when going to background).
    func lockIfNeeded() {
        if isLockEnabled {
            isLocked = true
        }
    }

    /// Force unlock (used internally after successful verification).
    private func unlock() {
        isLocked = false
    }

    /// Check a candidate password. Returns true if correct and unlocks the app.
    @discardableResult
    func verifyPassword(_ candidate: String) -> Bool {
        guard let stored = loadPasswordHash() else {
            return false
        }
        let candidateHash = sha256(candidate)
        if stored == candidateHash {
            unlock()
            return true
        } else {
            return false
        }
    }

    /// Attempt to unlock the app with the given passcode.
    /// Returns true on success (and clears the locked state).
    @discardableResult
    func unlock(with attempt: String) -> Bool {
        // If no lock is configured, treat as always unlocked.
        guard isLockEnabled else {
            isLocked = false
            return true
        }
        return verifyPassword(attempt)
    }

    /// Utility to ask: should we show the lock screen right now?
    var shouldShowLockScreen: Bool {
        isLockEnabled && isLocked
    }

    // MARK: - Biometrics (Face ID / Touch ID)

    /// Returns true if Face ID / Touch ID is available and enrolled on this device.
    var canUseBiometrics: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Attempt to unlock using Face ID / Touch ID.
    /// - Parameters:
    ///   - reason: The localized reason shown in the system auth dialog.
    ///   - completion: Called on the main actor with true on success.
    func unlockWithBiometrics(
        reason: String = NSLocalizedString(
            "app_lock.biometrics.reason.unlock",
            comment: "Reason shown in the system Face ID/Touch ID prompt"
        ),
        completion: @escaping (Bool) -> Void
    ) {
        // If no lock is configured, treat as unlocked.
        guard isLockEnabled else {
            isLocked = false
            completion(true)
            return
        }

        let context = LAContext()
        context.localizedCancelTitle = NSLocalizedString(
            "common.cancel",
            comment: "Cancel button title"
        )

        var authError: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) {
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                   localizedReason: reason) { success, _ in
                Task { @MainActor in
                    if success {
                        self.unlock()
                        completion(true)
                    } else {
                        completion(false)
                    }
                }
            }
        } else {
            // Biometrics not available / not enrolled
            completion(false)
        }
    }

    // MARK: - Hashing

    private func sha256(_ string: String) -> Data {
        let data = Data(string.utf8)
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }

    // MARK: - Keychain helpers

    private func storePasswordHash(_ hash: Data) throws {
        // Remove any existing item first
        deletePasswordHash()

        var query: [String: Any] = [:]
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrService as String] = keychainService
        query[kSecAttrAccount as String] = keychainAccount
        query[kSecValueData as String] = hash

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "AppLock.Keychain",
                code: Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        format: NSLocalizedString(
                            "app_lock.keychain.store_failed",
                            comment: "Error when storing password hash in Keychain; parameter is OSStatus"
                        ),
                        status
                    )
                ]
            )
        }
    }

    private func loadPasswordHash() -> Data? {
        var query: [String: Any] = [:]
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrService as String] = keychainService
        query[kSecAttrAccount as String] = keychainAccount
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return data
    }

    private func deletePasswordHash() {
        var query: [String: Any] = [:]
        query[kSecClass as String] = kSecClassGenericPassword
        query[kSecAttrService as String] = keychainService
        query[kSecAttrAccount as String] = keychainAccount

        SecItemDelete(query as CFDictionary)
    }
}
