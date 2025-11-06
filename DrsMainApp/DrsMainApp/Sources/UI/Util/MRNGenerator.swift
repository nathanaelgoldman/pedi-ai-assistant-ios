//
//  MRNGenerator.swift
//  DrsMainApp
//
//  Created by yunastic on 10/31/25.
//
//  MRNGenerator.swift
//  DrsMainApp

import Foundation
import CryptoKit

enum MRNGenerator {
    /// Make a 12-digit MRN: 10-digit payload + 2-digit ISO 7064 mod97-10 checksum
    /// Inputs are used to seed randomness but MRN is not trivially reversible.
    static func generate(dobYYYYMMDD: String, sex: String, aliasID: String) -> String {
        // Seed: SHA256(aliasID|dob|sex|nonce)
        let nonce = UUID().uuidString
        let seed = "\(aliasID)|\(dobYYYYMMDD)|\(sex)|\(nonce)"
        let digest = SHA256.hash(data: Data(seed.utf8))

        // Take first 10 digits from digest by mapping bytes to digits
        var digits = ""
        for b in digest {
            digits.append(String(b % 10))
            if digits.count == 10 { break }
        }
        // Compute checksum (ISO 7064 Mod 97-10)
        let check = mod97_10(digits)
        let checkStr = String(format: "%02d", check)
        return digits + checkStr
    }

    /// Validate a 12-digit MRN
    static func validate(_ mrn: String) -> Bool {
        let trimmed = mrn.filter(\.isNumber)
        guard trimmed.count == 12 else { return false }
        let payload = String(trimmed.prefix(10))
        let check = String(trimmed.suffix(2))
        return String(format: "%02d", mod97_10(payload)) == check
    }

    /// ISO 7064 Mod 97-10 checksum for a numeric string
    private static func mod97_10(_ numeric: String) -> Int {
        // Append "00", then compute remainder, then checksum = 98 - (remainder mod 97)
        let working = numeric + "00"
        var remainder = 0
        for ch in working {
            guard let d = ch.wholeNumberValue else { continue }
            remainder = (remainder * 10 + d) % 97
        }
        let cs = 98 - remainder
        return cs % 97
    }
}
