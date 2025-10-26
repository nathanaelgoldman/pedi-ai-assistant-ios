# PediaShared Guide

A lightweight, multi-platform Swift Package that hosts code shared by **DrsMainApp** (macOS) and **PatientViewerApp** (iOS/iPadOS). This guide explains **what** goes here, **how** to reference it from Xcode, and **patterns** (logging, DI, persistence boundaries) to keep both apps robust and consistent.

---

## 1) Goals

- **Single source of truth** for shared types and utilities.
- **No UI kit dependencies** inside the package (keep platform UI in each app).
- **Strict module boundaries**: app targets depend on PediaShared, not vice-versa.
- **Testable**: package comes with its own unit test target.

---

## 2) Supported Platforms & Tools

- Swift 5.9+ (concurrency first)
- iOS 16+ / iPadOS 16+ / macOS 13+
- SPM (Swift Package Manager)
- `os.Logger` for diagnostics

> Keep the package **UI-free** (no SwiftUI/UIKit/AppKit views). If you need view helpers, put thin adapters in each app target.

---

## 3) Package Layout
PediaShared/
├─ Package.swift
├─ Sources/
│  └─ PediaShared/
│     ├─ PediaShared.swift                 # Module header (exports)
│     ├─ Logging.swift                     # Logger categories & helpers
│     ├─ DI.swift                          # Minimal dependency container
│     ├─ Domain/
│     │  ├─ Models.swift                   # Patient, Visit, Enums, etc.
│     │  └─ Validation.swift               # Simple domain validators
│     ├─ Persistence/
│     │  ├─ StoreProtocols.swift           # Protocols (no SQLite here)
│     │  └─ Paths.swift                    # App directories (App Support)
│     ├─ Interop/
│     │  └─ PDFShareAbstraction.swift      # Protocols to request PDF share
│     └─ Utils/
│        ├─ Dates.swift
│        └─ ResultExtensions.swift
├─ Tests/
│  └─ PediaSharedTests/
│     ├─ PediaSharedTests.swift
│     └─ Fixtures/
│        └─ sample.json
└─ Resources/
└─ .keep                                # (optional) placeholder

---

## 4) `Package.swift` template

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "PediaShared",
  platforms: [
    .iOS(.v16),
    .macOS(.v13)
  ],
  products: [
    .library(name: "PediaShared", targets: ["PediaShared"])
  ],
  targets: [
    .target(
      name: "PediaShared",
      resources: [
        // .process("Resources") // keep empty or add data files if needed
      ]
    ),
    .testTarget(
      name: "PediaSharedTests",
      dependencies: ["PediaShared"],
      resources: [
        // .process("Fixtures")
      ]
    )
  ]
)

## 5) Adding to the Workspace & Linking

1. **Open the workspace**: `PediWorkspace.xcworkspace`.
2. **Add the package**: `File ▸ Add Packages…` → **Add Local…** → select the `PediaShared` folder (where `Package.swift` is).
3. **Choose targets**: In the dialog, set **Add to Target** for **DrsMainApp** and **PatientViewerApp**.
4. **Build**: SPM will resolve; no manual linking needed.

> If Xcode shows `PediaShared` as a *blue folder* instead of a Package, remove it and re-add via **Add Packages…** (don’t “Add Files…”).

---

## 6) Public API Design Rules

- **Public only when shared**; default to `internal`.
- Prefer **value types** (`struct`) for domain models; make them `Codable`/`Sendable`.
- Use **async/await**; prefer `async throws` for I/O protocols.
- Keep **platform UI out** of the package (no SwiftUI/UIKit/AppKit).
- Version changes with semantic intent (see §15).

---

## 7) Logging

Centralize diagnostics with `os.Logger` and consistent categories. Keep **all** prints out of production code—use the shared loggers below so both apps (macOS/iOS) emit structured, privacy-safe logs that you can filter in Console.

### 7.1 `Logging.swift` (in `Sources/PediaShared/Logging.swift`)
```swift
import os

/// Shared loggers for all modules/apps.
/// Use privacy annotations on interpolations: `.public` only for non-sensitive values.
public enum Log {
  /// Keep the subsystem stable so Console filters remain useful
  public static let subsystem = "com.pediai.shared"

  // Functional categories
  public static let core   = Logger(subsystem: subsystem, category: "core")
  public static let db     = Logger(subsystem: subsystem, category: "db")
  public static let pdf    = Logger(subsystem: subsystem, category: "pdf")
  public static let io     = Logger(subsystem: subsystem, category: "io")
  public static let growth = Logger(subsystem: subsystem, category: "growth")

  /// Only for thin UI adapters/bridges that still live outside app targets.
  /// Prefer app-local loggers for view/controllers.
  public static let ui     = Logger(subsystem: subsystem, category: "ui")
}

### 7.2 Usage examples

// DB paths are sensitive — mask/hash in logs
Log.db.info("Opening SQLite at: \(dbURL.path, privacy: .private(mask: .hash))")

// Public because it’s just a count
Log.core.info("Loaded \(patients.count, privacy: .public) patients")

// Debug-only signal (still visible if you enable the debug stream in Console)
Log.growth.debug("Built \(curveCount, privacy: .public) curves for sex=\(sex.rawValue, privacy: .public)")

// Error with public message but private error details
Log.pdf.error("Failed to render page \(pageIndex, privacy: .public): \(error.localizedDescription, privacy: .public)")
Log.pdf.debug("Underlying error: \(String(describing: error), privacy: .private)")

### 7.3 Guidance & conventions
    - Always annotate privacy:
        - Use .private(mask: .hash) for paths, IDs, names, or anything patient-related.
        - Use .public only for non-sensitive counters/flags.
    - Choose the right category (db, pdf, io, growth, core, ui) so Console filters are meaningful.
    - Replace print calls with Log.* to keep output structured and filterable.
    - Don’t log PHI (Protected Health Information) in .public. When in doubt, treat as private.
    - Performance: os.Logger is efficient and defers string formatting; you can keep calls in hot paths.

---

## 8) Minimal DI (Dependency Injection)
Expose a tiny container that each app composes at launch. The package only defines protocols and a convenience struct.

// Sources/PediaShared/DI.swift
public struct AppServices: Sendable {
  public let patientStore: PatientStore
  public let visitStore: VisitStore
  public let pdfShare: PDFShareRouter

  public init(patientStore: PatientStore, visitStore: VisitStore, pdfShare: PDFShareRouter) {
    self.patientStore = patientStore
    self.visitStore = visitStore
    self.pdfShare = pdfShare
  }
}

- Concrete implementations (e.g., SQLite stores, platform share routers) live inside app targets.

---

## 9) Domain Models
// Sources/PediaShared/Domain/Models.swift
import Foundation

public enum Sex: String, Codable, Sendable { case male = "M", female = "F", unknown = "U" }

public struct Patient: Codable, Sendable, Identifiable, Hashable {
  public let id: Int64
  public var alias: String
  public var legalName: String?
  public var dob: Date
  public var sex: Sex

  public init(id: Int64, alias: String, legalName: String?, dob: Date, sex: Sex) {
    self.id = id
    self.alias = alias
    self.legalName = legalName
    self.dob = dob
    self.sex = sex
  }
}

public enum VisitCategory: String, Codable, Sendable { case well, sick }

public struct Visit: Codable, Sendable, Identifiable, Hashable {
  public let id: Int64
  public let patientId: Int64
  public var category: VisitCategory
  public var createdAt: Date

  public init(id: Int64, patientId: Int64, category: VisitCategory, createdAt: Date) {
    self.id = id
    self.patientId = patientId
    self.category = category
    self.createdAt = createdAt
  }
}

---

## 10) Persistence Interfaces (protocols only; no SQLite here)
// Sources/PediaShared/Persistence/StoreProtocols.swift
import Foundation

public protocol PatientStore: Sendable {
  func getPatient(id: Int64) async throws -> Patient
  func listPatients() async throws -> [Patient]
}

public protocol VisitStore: Sendable {
  func listVisits(patientId: Int64) async throws -> [Visit]
  func getVisit(id: Int64) async throws -> Visit
}

---

## 11) App Directories (where to put files)
// Sources/PediaShared/Persistence/Paths.swift
import Foundation

public enum AppPaths {
  public static func appSupport(subdir: String? = nil) throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    guard let subdir else { return base }
    let dir = base.appendingPathComponent(subdir, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }
}

---

## 12) PDF Sharing Abstraction
Define a platform-agnostic protocol in the package; implement per platform in app targets.

// Sources/PediaShared/Interop/PDFShareAbstraction.swift
import Foundation

public protocol PDFShareRouter: Sendable {
  func sharePDF(at url: URL, title: String) async
}

    - iOS: use UIActivityViewController via SwiftUI .sheet.
    - macOS: use NSSharingServicePicker.

## 13) Utilities
Keep helpers small and dependency-free.
    - Utils/Dates.swift: ISO8601, age-in-months, friendly formatters.
    - Utils/ResultExtensions.swift: map/catch helpers to attach diagnostics.

Example:
// Sources/PediaShared/Utils/Dates.swift
import Foundation

public enum Dates {
  public static let iso8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
}

---

## 14) Testing
    - Unit-test pure logic in PediaSharedTests.
    - For DB (app implementations), test in app test targets using a throwaway DB file.
    - Keep fixtures in Tests/PediaSharedTests/Fixtures.

// Tests/PediaSharedTests/PediaSharedTests.swift
import XCTest
@testable import PediaShared

final class PediaSharedTests: XCTestCase {
  func testPatientCodableRoundTrip() throws {
    let p = Patient(id: 1, alias: "Teal Robin", legalName: nil, dob: Date(timeIntervalSince1970: 0), sex: .male)
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(Patient.self, from: data)
    XCTAssertEqual(p, back)
  }
}

---

## 15) Versioning & Change Control
    - Tag stable API points: git tag pedia-shared-0.1.0.
    - Maintain CHANGELOG.md with Added / Changed / Deprecated / Removed / Fixed.
    - Treat warnings as errors in app targets; keep the package clean.
    
---

## 16) How Apps Use the Package
    // App target composition (e.g., Scene delegate / SwiftUI App)
import PediaShared

@MainActor
func composeServices(db: SQLiteDriver, shareRouter: PDFShareRouter) -> AppServices {
  let patientStore = db as PatientStore
  let visitStore = db as VisitStore
  return AppServices(patientStore: patientStore, visitStore: visitStore, pdfShare: shareRouter)
}

// Feature code (app target)
let patients = try await services.patientStore.listPatients()
Log.core.info("Loaded \(patients.count, privacy: .public) patients")

The SQLiteDriver (or CloudKit, etc.) is an app-side type conforming to the Store protocols.

---

## 17) Do / Don’t

- Do
    - Keep protocols + models in PediaShared.
    - Use os.Logger with proper privacy.
    - Prefer async/await, Sendable, Codable.
    
- Don’t
    - Put any UI (SwiftUI/UIKit/AppKit) in PediaShared.
    - Embed SQLite/CloudKit networking in PediaShared.
    - Create reverse dependencies (package must not depend on apps).
    
## 18) Migration Tips

    - When code is duplicated across apps, extract only the platform-agnostic parts.
    - If a small platform shim is needed, define a protocol in shared and implement it per app.
    - Move gradually: keep changes small and covered by tests.
    
## 19) FAQ

Q: Where do growth-chart algorithms or CSV parsing live?
A: In PediaShared if UI-free. File locations and sandbox paths belong to the apps; generic parsing helpers can live here.

Q: Can the package hold assets?
A: Prefer data (CSV/JSON) in Resources. UI assets belong in app bundles.

Q: How do I add new shared APIs?
A: Add under Sources/PediaShared/<Area>/, mark only necessary symbols public, write a unit test, and update CHANGELOG.md.
