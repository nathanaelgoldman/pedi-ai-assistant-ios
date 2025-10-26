//
//  Logging.swift
//  PediaShared
//
//  Created by yunastic on 10/25/25.
//

import Foundation

// Prefer the modern OSLog module (Xcode 14+/macOS 12+/iOS 16+ toolchains),
// but also support older "os" module if that's what's present.
// If neither is present (very old SDK), provide a tiny shim so builds still succeed.

#if canImport(OSLog)
import OSLog
public typealias SystemLogger = Logger
#elseif canImport(os)
import os
public typealias SystemLogger = Logger
#else
// Fallback shim with a subset of the os.Logger API used in this project.
public struct SystemLogger {
    private let subsystem: String
    private let category: String
    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
    }
    private func emit(_ level: String, _ message: String) {
        NSLog("[\(level)][\(subsystem)][\(category)] \(message)")
    }
    public func debug(_ message: String)  { emit("debug", message) }
    public func info(_ message: String)   { emit("info", message) }
    public func notice(_ message: String) { emit("notice", message) }
    public func error(_ message: String)  { emit("error", message) }
    public func fault(_ message: String)  { emit("fault", message) }
}
#endif

public enum Log {
    public static let core = SystemLogger(subsystem: "org.pediai", category: "core")
    public static let ui   = SystemLogger(subsystem: "org.pediai", category: "ui")
    public static let db   = SystemLogger(subsystem: "org.pediai", category: "db")
    public static let pdf  = SystemLogger(subsystem: "org.pediai", category: "pdf")
}
