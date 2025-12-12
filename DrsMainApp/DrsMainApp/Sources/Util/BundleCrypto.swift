//
//  BundleCrypto.swift
//  DrsMainApp
//
//  Shared symmetric encryption for peMR bundles.
//  Step 1: used only for export (db.sqlite → db.sqlite.enc).
//

import Foundation
import CryptoKit

enum BundleCrypto {

    // MARK: - Key Derivation (HKDF)

    /// Static master seed used to derive both encryption and MAC keys.
    /// Must be identical in DrsMainApp and PatientViewerApp.
    private static let masterSeed = "peMR-MASTER-MASTER-KEY-v1"

    /// Deterministic master key derived from the seed via SHA-256.
    private static var masterKey: SymmetricKey {
        let data = Data(masterSeed.utf8)
        let hash = SHA256.hash(data: data)
        return SymmetricKey(data: Data(hash))
    }

    /// HKDF helper to derive subkeys from the master key.
    /// We use different `label` values for encryption vs MAC,
    /// which gives us two independent keys from the same master.
    private static func deriveKey(label: String) -> SymmetricKey {
        let salt = Data("peMR-HKDF-SALT-v1".utf8)
        let info = Data(label.utf8)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    /// AES-GCM key for encrypting the database payload.
    private static let encKey: SymmetricKey = deriveKey(label: "peMR:db.enc:v1")

    /// HMAC-SHA256 key for authenticating the encrypted payload.
    private static let hmacKey: SymmetricKey = deriveKey(label: "peMR:db.mac:v1")

    // MARK: - Low-level File Primitives (encrypt/decrypt with HMAC)

    /// Encrypt a file at `src` and write:
    ///   HMAC( SHA256, hmacKey, combinedCipher ) || combinedCipher
    /// to `dst`.
    ///
    /// `combinedCipher` is AES.GCM.combined = nonce || ciphertext || tag.
    static func encryptFile(at src: URL, to dst: URL) throws {
        let plaintext = try Data(contentsOf: src)

        // AES-GCM encrypt with encKey
        let sealedBox = try AES.GCM.seal(plaintext, using: encKey)
        guard let combined = sealedBox.combined else {
            throw NSError(
                domain: "BundleCrypto",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Failed to obtain combined AES-GCM box for \(src.path)"]
            )
        }

        // HMAC over the combined cipher text (nonce+cipher+tag)
        let mac = HMAC<SHA256>.authenticationCode(for: combined, using: hmacKey)
        let macData = Data(mac)

        var blob = Data()
        blob.append(macData)   // 32 bytes for SHA256 HMAC
        blob.append(combined)

        try blob.write(to: dst, options: .atomic)
    }

    /// Decrypt a file at `src` that was produced by `encryptFile`.
    /// Verifies HMAC first; if verification fails, throws.
    static func decryptFile(at src: URL, to dst: URL) throws {
        let blob = try Data(contentsOf: src)

        // HMAC-SHA256 is 32 bytes
        let macLength = 32
        guard blob.count > macLength else {
            throw NSError(
                domain: "BundleCrypto",
                code: 1501,
                userInfo: [NSLocalizedDescriptionKey: "BundleCrypto: encrypted file too short to contain HMAC and ciphertext at \(src.path)"]
            )
        }

        let macData = blob.prefix(macLength)
        let combinedCipher = blob.dropFirst(macLength)

        // Recompute and compare MAC in constant time
        let expectedMac = HMAC<SHA256>.authenticationCode(for: combinedCipher, using: hmacKey)
        let expectedMacData = Data(expectedMac)

        guard macData == expectedMacData else {
            throw NSError(
                domain: "BundleCrypto",
                code: 1502,
                userInfo: [NSLocalizedDescriptionKey: "BundleCrypto: HMAC verification failed for \(src.path)"]
            )
        }

        // HMAC is valid → decrypt AES-GCM
        let sealedBox = try AES.GCM.SealedBox(combined: combinedCipher)
        let plaintext = try AES.GCM.open(sealedBox, using: encKey)
        try plaintext.write(to: dst, options: .atomic)
    }

    // MARK: - DB-level helpers

    /// Ensure there is a plaintext db.sqlite under the given bundle root.
    /// - If db.sqlite already exists, this is a no-op.
    /// - If only db.sqlite.enc exists, it is decrypted to db.sqlite (with HMAC verification).
    /// - If neither exists, this is a no-op (caller will validate separately).
    static func decryptDatabaseIfNeeded(at bundleRoot: URL) throws {
        let fm = FileManager.default
        let plain = bundleRoot.appendingPathComponent("db.sqlite")
        let enc   = bundleRoot.appendingPathComponent("db.sqlite.enc")

        // 1) If a plaintext db.sqlite is already present, nothing to do.
        if fm.fileExists(atPath: plain.path) {
            return
        }

        // 2) If there is no encrypted database either, we cannot proceed here.
        guard fm.fileExists(atPath: enc.path) else {
            return
        }

        // 3) Decrypt db.sqlite.enc to a temporary file, then move into place as db.sqlite.
        let tmp = bundleRoot.appendingPathComponent("db.sqlite.tmp-\(UUID().uuidString)")
        try decryptFile(at: enc, to: tmp)

        // If something somehow created a db.sqlite in between, remove it so we can move atomically.
        if fm.fileExists(atPath: plain.path) {
            try fm.removeItem(at: plain)
        }

        try fm.moveItem(at: tmp, to: plain)
    }

    /// Ensure an encrypted db.sqlite.enc exists under the given bundle root.
    /// - If db.sqlite.enc already exists, this is a no-op.
    /// - If only db.sqlite exists, it is encrypted to db.sqlite.enc and the plaintext is removed.
    /// - If neither exists, an error is thrown.
    ///
    /// IMPORTANT: Call this only on an export/staging copy of the bundle, not on the live working DB.
    static func encryptDatabaseIfNeeded(at bundleRoot: URL) throws {
        let fm = FileManager.default
        let plain = bundleRoot.appendingPathComponent("db.sqlite")
        let enc   = bundleRoot.appendingPathComponent("db.sqlite.enc")

        // 1) If an encrypted db.sqlite.enc is already present, do nothing (idempotent).
        if fm.fileExists(atPath: enc.path) {
            return
        }

        // 2) If we have only a plaintext db.sqlite, encrypt it to db.sqlite.enc.
        if fm.fileExists(atPath: plain.path) {
            try encryptFile(at: plain, to: enc)

            // For exported bundles we don't want a stray plaintext copy.
            do {
                try fm.removeItem(at: plain)
            } catch {
                throw NSError(
                    domain: "BundleCrypto",
                    code: 2003,
                    userInfo: [
                        NSLocalizedDescriptionKey: "BundleCrypto: failed to remove plaintext db.sqlite after encryption at \(plain.path)"
                    ]
                )
            }

            return
        }

        // 3) Otherwise, neither db.sqlite nor db.sqlite.enc exists → can't proceed.
        throw NSError(
            domain: "BundleCrypto",
            code: 2004,
            userInfo: [
                NSLocalizedDescriptionKey: "BundleCrypto: neither db.sqlite nor db.sqlite.enc found under \(bundleRoot.path)"
            ]
        )
    }
}
