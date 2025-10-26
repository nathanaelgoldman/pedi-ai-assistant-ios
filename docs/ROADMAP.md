# ROADMAP — DrsMainApp (macOS) + PatientViewerApp (iOS) + PediaShared

A phased plan to build **DrsMainApp** (macOS) reusing code with **PatientViewerApp** (iOS/iPadOS) via the **PediaShared** Swift Package, while preserving the Python prototype’s functionality and the on-device bundle DB/export model.

> **Location:** `docs/ROADMAP.md`  
> **Audience:** You (lead dev), future contributors

---

## 0) Goals & Non-Goals

### Goals
- Mac app (**DrsMainApp**) for clinicians to **create/manage patient bundles**, generate PDFs, and export a **self-contained ActiveBundle** to families.
- Keep all **patient PHI on disk** inside bundles (no cloud dependency).
- Share non-UI logic in **PediaShared** (models, logging, protocols, minor utilities).
- **Parity** with Python prototype for core flows (encounters, reports, growth charts).
- **Robustness**: strong logging, diagnostics, and test scaffolding.

### Non-Goals (for now)
- No live sync / multi-user collaboration.
- No server or external database.
- No AI integration beyond what the Python prototype already exposes (placeholder for future).

---

## 1) Architecture at a Glance
PediWorkspace.xcworkspace
├─ DrsMainApp (macOS App)
│  ├─ macOS UI (SwiftUI/AppKit bridges)
│  ├─ Bundle import/export UI
│  ├─ PDF preview/share UI
│  └─ Depends on PediaShared
├─ PatientViewerApp (iOS App)
│  ├─ iOS UI (SwiftUI/UIKit bridges)
│  ├─ Growth charts, documents, notes
│  └─ Depends on PediaShared
└─ PediaShared (Swift Package)
├─ Domain models (Codable/Sendable)
├─ Store protocols & paths utils
├─ Logging (os.Logger) categories
├─ Interop protocols (PDF share hooks)
└─ Small pure helpers (dates, result)

**Separation of concerns**
- **PediaShared**: no platform UI; pure Swift + protocols.
- **Apps**: implement platform UI + concrete stores, PDF preview, sharing sheets.

---

## 2) Phases & Milestones

### Phase A — Workspace + Foundations
- ✅ Create workspace, add projects, add PediaShared package (local SPM).
- ✅ Introduce `Log` (os.Logger) + privacy annotations.
- ✅ Documented **DATA_MODEL.md** and **PEDIA_SHARED_GUIDE.md**.
- ✅ Add upgrade checklist + backup launchd sanity.

**Milestone A**
- Both apps build, link to PediaShared.
- Basic logging present.
- Docs scaffolded under `docs/`.

---

### Phase B — Data & Files (Bundle Boundary)
- Implement `Paths.swift` helpers: **ActiveBundle**, **PersistentBundles**, **ImportTemp** resolution (macOS + iOS).
- Define `StoreProtocols.swift`: `PatientStore`, `VisitStore`, `AttachmentStore`, `NotesStore`.
- macOS concrete SQLite store (`SQLiteStoreMac`), iOS concrete store (`SQLiteStoreIOS`) — both behind protocols.
- **Import/Export** use cases:
  - Import zipped bundle → validate manifest → place under PersistentBundles.
  - Set ActiveBundle → copy/prepare writable copy (if needed).
  - Export ActiveBundle → repackage + checksum.

**Milestone B**
- You can import/test a sample bundle in DrsMainApp and view basic patient/visit lists.
- Console logs show paths with privacy masking.

---

### Phase C — UI & Workflows (macOS first)
- **DrsMainApp** screens:
  - Sidebar: Patients / Visits / Docs
  - Patient detail: demographics, notes (editor), visits list
  - Visit detail: data entry for well/sick visits
  - Document center: list manifest docs + preview (QuickLook) + share
- **PDF flow**:
  - Generate preview (well/sick) → share / save to Docs inside bundle.
  - Errors annotated with `Log.pdf`.
- Growth charts:
  - Reuse models + CSV loaders; render with CoreGraphics or reuse your existing Swift canvas (already working in iOS) via a small rendering adapter.

**Milestone C**
- Clinician can open a bundle, edit notes, view/generate PDFs, export a new bundle, all on macOS.

---

### Phase D — iOS parity & polish
- Ensure PatientViewerApp reuses more from PediaShared where possible (models, validations).
- Align PDF preview/share button behavior (we fixed earlier).
- Add guards + diagnostics around file URLs and share sheets (addressed in recent logs).
- Cosmetic tidy-ups (colors, titles) **later**, once core flows prove stable.

**Milestone D**
- End-to-end parity for common tasks between apps.
- Zero crash sessions in routine use.

---

### Phase E — QA, Docs, and Release Prep
- Unit tests for PediaShared (domain + paths).
- UI smoke tests where feasible (XCTest minimal).
- Developer docs updated: **DATA_MODEL.md**, **PEDIA_SHARED_GUIDE.md**, **README.md**.
- Create **cut** branch (`release/x.y`) for tagged builds.

**Milestone E**
- Tag v1.0.0 of PediaShared.
- Internal v1.0 for DrsMainApp / PatientViewerApp.

---

## 3) Data Model & Migration (Summary)

- **Keep names** aligned with existing SQLite schema (`patients`, `visits`, `parent_notes`, `docs_manifest`, etc.).
- Write **idempotent** `CREATE TABLE IF NOT EXISTS ...` with indexes.
- Migration strategy:
  1. On app open: probe tables; if missing → create.
  2. If schema drift (new column) → `ALTER TABLE ADD COLUMN` + default.
  3. Store `schema_version` in a `meta` table; bump only with breaking changes.

> Full detail lives in `docs/DATA_MODEL.md`.

---

## 4) Logging & Diagnostics

- Use shared `Log` (db/pdf/growth/io/core/ui).
- **Privacy**: `.private(mask: .hash)` for paths, `.public` for counts.
- Avoid `print`. Keep logs actionable (“where + what + next step”).

---

## 5) Error Handling Policy

- Non-fatal: show in UI as **callouts**, log with `.error`, offer **retry**.
- Fatal: log with **category**, present a succinct message + “Show in Finder / Open Console” affordances on macOS.
- Wrap SQLite errors with **context** (which path / which query).

---

## 6) Storage Boundary: Import/Export

- **Import** (macOS):
  - Drop zip/folder → validate checksum, validate manifest (`docs/manifest.json`), copy under `PersistentBundles`.
- **ActiveBundle selection**:
  - Copy to `ActiveBundle/<Alias>` as working dir.
- **Export**:
  - Flush SQLite (VACUUM/checkpoint), zip `ActiveBundle`, write to `Export/` folder; optional share sheet.

---

## 7) PDF & Charts

- Use same WHO CSVs for growth (0–24m M/F etc.).
- Centralize chart rendering in a tiny adapter callable from macOS and iOS.
- Preview controller: Done/Share wires identical across apps; fall back if share fails; log detailed reasons (we handled -10814 cases previously).

---

## 8) Build Targets, Schemes, & Scripts

- Schemes: `DrsMainApp-Debug/Release`, `PatientViewerApp-Debug/Release`, `PediaShared-Package`.
- Scripts:
  - `scripts/backup_sanity.sh` (verify LaunchAgent active)
  - `scripts/upgrade_sanity.sh` (Xcode/iOS bump checklist)
  - `scripts/lint.sh` (swift-format/swiftlint if adopted)

---

## 9) Testing Strategy

- **Unit (PediaShared)**: models, validation, paths resolution.
- **Integration (apps)**: import bundle → load patients → render PDF (golden file compare if practical).
- **Manual QA**: open Console, filter subsystem `com.pediai.shared`, run through:
  - Import, set active, edit notes, generate/preview/share PDFs, export bundle.

---

## 10) Security & Privacy

- PHI never in `.public` logs.
- No network by default. If added later, document endpoints + keychain usage.
- Avoid temp leakage; clear intermediates after exports.

---

## 11) Definition of Done (per Phase)

- **A**: Workspace builds; docs exist; logging working.
- **B**: Bundle import/export ok; data accessible via protocols.
- **C**: Mac UI functional for core flows; PDFs preview/share; charts render.
- **D**: iOS parity; no crashers; consistent interactions.
- **E**: Tests pass; docs up to date; tagged release.

---

## 12) Risks & Mitigations

- **Path confusion / stale references** → Centralize via `Paths.swift`; add `Log.io` breadcrumbs.
- **SQLite locking** → Use one writer queue; checkpoint before exports.
- **Share sheet errors (-10814)** → Verify file URLs exist & are readable; provide fallback “Reveal in Finder”.

---

## 13) Backlog (Post-1.0 Ideas)

- Theming pass (colors, shapes).
- AI helpers gated behind explicit consent.
- Merge duplicate records utilities.
- Multi-bundle dashboard in DrsMainApp.

---

## 14) Repo Hygiene

- Keep **PediaShared** UI-free.
- Avoid circular references (package ↔ app).
- Prefer **protocols** for integration points.
- Update docs when changing data model or flows.

---

## 15) Appendix: Suggested Directories

docs/
README.md
ROADMAP.md
DATA_MODEL.md
PEDIA_SHARED_GUIDE.md

scripts/
backup_sanity.sh
upgrade_sanity.sh
lint.sh   # (optional)

DrsMainApp/
Sources/…
Tests/…

PatientViewerApp/
Sources/…
Tests/…

PediaShared/
Package.swift
Sources/PediaShared/…
Tests/PediaSharedTests/…
