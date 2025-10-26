# DrsMainApp Architecture (macOS)

Authoritative overview of the DrsMainApp design: modules, navigation, state, data flow, and boundaries with **PediaShared**.

> **Location:** `docs/DRS_MAINAPP_ARCHITECTURE.md`  
> **Related:** `docs/DrsMainApp_Roadmap.md` (phases/milestones), `docs/PEDIA_SHARED_GUIDE.md`, `docs/DATA_MODEL.md`

---

## 1) Goals & Scope

- **Local-first** clinician app on macOS (SwiftUI + minimal AppKit).
- Reuse domain logic via **PediaShared** (SPM), keep UI out of the package.
- Interoperate with iOS **PatientViewerApp** by reading/writing the same **bundle** format:
    /
    db.sqlite
    docs/
    manifest.json
    
- - Strong diagnostics with `os.Logger`, defensive file/URL checks, predictable errors.

Non-goals (v1): cloud sync, multi-user collaboration, server backends.

---

## 2) High-Level Modules

DrsMainApp/
Sources/
App/
DrsMainApp.swift          // App entry / Scene
AppState.swift             // Global selection + routing
UI/
SidebarView.swift
PatientListView.swift
PatientDetailView.swift
VisitListView.swift
VisitDetailView.swift
DocumentsView.swift
PDFPreviewMac.swift        // QLPreview + NSSharingServicePicker
Data/
PathsMac.swift             // ActiveBundle, PersistentBundles, ImportTemp
SQLiteStoreMac.swift       // PediaShared store protocol impls
BundleIO.swift             // Import/validate/export helpers
Features/
GrowthChartsMacAdapter.swift // Charts → images for PDFs
PDFBuilders/
WellVisitPDFBuilder.swift
SickVisitPDFBuilder.swift
Util/
Logging.swift              // os.Logger categories
ErrorBridging.swift        // Error→UserMessage
Tests/
DrsMainAppTests.swift

**PediaShared (SPM)** contains:
- Domain models (Codable/Sendable)
- Protocols: `PatientStore`, `VisitStore`, `NotesStore`, `AttachmentStore`
- WHO loaders, CSV parsing, growth math
- Utilities free of platform UI

DrsMainApp provides **macOS implementations** of those protocols and all UI.

---

## 3) Data Flow

1. **Path resolution** (`PathsMac`) determines:
   - `ActiveBundle/<Alias>/db.sqlite` (read/write)
   - `PersistentBundles/<Alias>/` (long-lived storage)
   - `ImportTemp` (staging area)

2. **Store layer** (`SQLiteStoreMac`) opens `db.sqlite`, runs:
   - `CREATE TABLE IF NOT EXISTS …`
   - Additive migrations controlled by `meta.schema_version`.
   - WAL checkpoint + `VACUUM` before export.

3. **UI** binds to `AppState`:
   - Sidebar selects Patient → lists Visits & Documents.
   - Detail screens read/write via store protocols.
   - Report builders pull chart images from `GrowthChartsMacAdapter` and persist PDFs under the bundle root.

4. **Export/Share**:
   - `BundleIO` zips current ActiveBundle to a user-chosen location.
   - Quick Look for preview; `NSSharingServicePicker` for share.
   - If share fails (e.g., `-10814`), offer **Reveal in Finder**.

---

## 4) Navigation & State

- Single-window SwiftUI app.
- `AppState` (Observable) holds:
  - `selectedPatientID: Int?`
  - `selectedVisitID: Int?`
  - `activeBundleAlias: String?`
  - `isImporting: Bool`, `isExporting: Bool`, `lastError: UserMessage?`
- **Sidebar** → sets selections in `AppState`.
- **Sheets** for Import/Export flows; **QL** for PDF preview.

---

## 5) Boundaries & Protocols

PediaShared defines protocols; DrsMainApp implements them:

```swift
public protocol PatientStore {
  func listPatients() throws -> [Patient]
  func getPatient(_ id: Int) throws -> Patient?
  func upsertPatient(_ p: Patient) throws
}

public protocol VisitStore {
  func listVisits(patientID: Int, kind: VisitKind?) throws -> [Visit]
  func getVisit(_ id: Int) throws -> Visit?
  func upsertVisit(_ v: Visit) throws
}

public protocol NotesStore {
  func getParentNotes(patientID: Int) throws -> String
  func setParentNotes(patientID: Int, text: String) throws
}

public protocol AttachmentStore {
  func listDocuments() throws -> [DocItem]
  func addDocument(_ data: Data, name: String) throws -> DocItem
}

Do not import SwiftUI/AppKit in PediaShared. Keep it testable and platform-agnostic.

---

## 6) Error Handling & Logging

- Subsystem: com.pediai.DrsMainApp
- Categories: core, io, db, ui, pdf, growth
- Redact PHI:
    - Paths: logger.log("opening db at: \(.private(path))")
    - Counts/flags: public
- Convert internal errors to UserMessage (title, detail, recovery suggestion).
- UI surfaces:
    - Non-fatal: Alert/Sheet with retry
    - Fatal: dialog with Open Console / Reveal in Finder
    
---

## 7) PDFs & Growth Charts
- WHO CSVs loaded via PediaShared.
- Render charts using ImageRenderer (SwiftUI) or CoreGraphics → embed as JPEG in PDF context.
- Save PDFs under <ActiveBundle>/<Alias>/ with deterministic names:
    - WellVisitReport_<id>.pdf
    - VisitReport_<id>.pdf
- Preview with Quick Look; share with NSSharingServicePicker.
- Handle file URL access and -10814 edges with clear fallbacks.

## 8) Testing Strategy
- Unit (PediaShared): models, CSV parsing, growth math, path helpers (pure).
- Integration (DrsMainApp): open test bundle → list patients/visits → create PDFs → verify files exist & QL loads.
- Fixtures: minimal bundles in test resources (no PHI).
- Manual QA checklist: import, set active, edit notes, generate reports, export, share failure paths.

---

## 9) Security & Privacy
- No raw PHI in logs.
- Respect sandbox; use user-approved locations.
- Clean temp dirs on success/failure.
- Consider code signing/notarization later.

---

## 10) Build & Scripts
- Schemes: DrsMainApp-Debug, DrsMainApp-Release
- scripts/:
    - backup_sanity.sh — validates LaunchAgent backup job
    - upgrade_sanity.sh — checks toolchain/Xcode/iOS deltas
    - lint.sh — optional swift-format/swiftlint

---

## 11) Future Extensions
- Theming & typography polish
- Finder reveals across all file ops
- Optional local backup rotation
- AI assistants (behind consent gates)
