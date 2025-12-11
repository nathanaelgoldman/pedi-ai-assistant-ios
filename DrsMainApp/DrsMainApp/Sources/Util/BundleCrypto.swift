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

    /// Static seed used to derive the symmetric key.
    /// Must be identical in DrsMainApp and PatientViewerApp.
    private static let keySeed = "peMR-BUNDLE-ENCRYPTION-KEY-v1"

    /// Deterministic symmetric key derived from the seed via SHA-256.
    private static var key: SymmetricKey {
        let data = Data(keySeed.utf8)
        let hash = SHA256.hash(data: data)
        return SymmetricKey(data: Data(hash))
    }

    /// Encrypt a file at `src` and write AES-GCM combined (nonce + ciphertext + tag) to `dst`.
    static func encryptFile(at src: URL, to dst: URL) throws {
        let plaintext = try Data(contentsOf: src)
        let sealedBox = try AES.GCM.seal(plaintext, using: key)

        guard let combined = sealedBox.combined else {
            throw NSError(
                domain: "BundleCrypto",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Failed to obtain combined AES-GCM box for \(src.path)"]
            )
        }

        try combined.write(to: dst, options: .atomic)
    }

    /// Decrypt an AES-GCM combined file at `src` into a plaintext file at `dst`.
    /// (Not used yet in Step 1, but ready for the importer step.)
    static func decryptFile(at src: URL, to dst: URL) throws {
        let combined = try Data(contentsOf: src)
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(sealedBox, using: key)
        try plaintext.write(to: dst, options: .atomic)
    }

    /// Ensure there is a plaintext db.sqlite under the given bundle root.
    /// - If db.sqlite already exists, this is a no-op.
    /// - If only db.sqlite.enc exists, it is decrypted to db.sqlite.
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
