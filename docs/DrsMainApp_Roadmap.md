# DrsMainApp Roadmap (macOS)

A phased plan to build the **DrsMainApp** (macOS) for clinicians, reusing core logic via **PediaShared**, and interoperating with the iOS **PatientViewerApp** through the on-disk bundle model.

> **Location:** `docs/DrsMainApp_Roadmap.md`  
> **Audience:** You (lead dev), future contributors

---

## 0) Scope & Principles

### In Scope
- Create/manage **ActiveBundle** for a patient on macOS.
- Import/export bundles to/from disk (no cloud).
- View/edit patient data (demographics, visits, notes).
- Generate/preview/share **Well**/**Sick** visit PDFs.
- Display growth charts (WHO CSV) for context and reports.
- Strong diagnostics with `os.Logger`, defensive file/URL checks.

### Out of Scope (v1)
- Multi-user sync/collab, server backends, advanced AI.
- Cross-device cloud storage (consider later).

### Design Principles
- **Local-first privacy** (PHI stays on disk).
- **PediaShared-only** for domain code; no platform UI inside the package.
- **Protocols at the edges** (stores, PDF hooks, growth adapters).
- **Idempotent migrations** for SQLite.

---

## 1) Architecture Snapshot

- **App target:** DrsMainApp (macOS, SwiftUI + minimal AppKit bridges)
- **Dependency:** PediaShared (SPM, local)
- **Storage:** SQLite inside `ActiveBundle/<Alias>/db.sqlite`
- **Documents:** `docs/manifest.json` + files under `docs/`
- **Import/Export:** zip/folder validation, checksum, copy to `PersistentBundles`

Key modules (app side):
- `PathsMac.swift` — resolves `ActiveBundle`, `PersistentBundles`, `ImportTemp`
- `SQLiteStoreMac.swift` — implements PediaShared store protocols
- `BundleIO.swift` — import/validate/export helpers
- `PDFPreviewMac.swift` — Quick Look + NSSharingServicePicker
- `GrowthChartsMacAdapter.swift` — render charts for PDFs

---

## 2) UI Map (macOS)

**Sidebar**
- Patients
- Visits (filtered by selected patient)
- Documents (manifest-driven)
- Tools (Import, Set Active, Export)

**Primary Views**
- Patient List → Patient Detail (demographics + notes)
- Visit List → Visit Detail (well/sick forms, preview PDF)
- Documents → QuickLook preview + Share/Reveal in Finder

**Global**
- Status bar/log view (optional)
- Settings: default export location; logging level (basic)

---

## 3) Data & Schema (Summary)

- `patients`, `visits`, `parent_notes`, `docs_manifest`, `meta`
- Idempotent `CREATE TABLE IF NOT EXISTS` on open
- `meta.schema_version` for drift; `ALTER TABLE ADD COLUMN` for additive changes
- VACUUM + checkpoint before export

(Full SQL lives in `docs/DATA_MODEL.md`.)

---

## 4) Logging & Diagnostics

- Subsystem: `com.pediai.DrsMainApp`
- Categories: `core`, `io`, `db`, `ui`, `pdf`, `growth`
- Use `.private(mask: .hash)` for file paths; counts are `.public`
- No `print` in production; logs must be actionable

---

## 5) Error Handling

- Non-fatal: inline callouts with retry
- Fatal: dialog with “Open Console” and “Reveal in Finder”
- Wrap SQLite/file errors with **operation + path** context

---

## 6) Import / Set Active / Export

**Import (zip or folder)**
- Validate structure: `db.sqlite` exists; `docs/` optional; `manifest.json` valid JSON
- Copy under `PersistentBundles/<Alias>/`
- Log duration, bytes copied

**Set Active**
- Copy to `ActiveBundle/<Alias>` (or refresh in place)  
- Verify writable DB; run migrations

**Export**
- Ensure DB flushed (checkpoint/VACUUM)
- Zip `ActiveBundle/<Alias>` → `Exports/` (or user pick location)
- Show share options; on failure, offer “Reveal in Finder”

---

## 7) PDF & Growth Charts

- Reuse WHO CSVs via PediaShared loaders
- Render charts to images (CoreGraphics/SwiftUI ImageRenderer) → embed in PDF
- PDF Preview with Quick Look; Share via NSSharingServicePicker
- Handle -10814 and file URL access gracefully (fallback to Finder reveal)

---

## 8) Build Targets & Scripts

- Schemes: `DrsMainApp-Debug`, `DrsMainApp-Release`
- Scripts (in repo `scripts/`):
  - `backup_sanity.sh` — verifies LaunchAgent backup service healthy
  - `upgrade_sanity.sh` — Xcode/iOS bump checks
  - `lint.sh` — optional swiftlint/swift-format

---

## 9) Testing Strategy

**Unit (PediaShared)**
- Models: Codable/Sendable; CSV parsing; growth math
- Path utils resolution

**Integration (DrsMainApp)**
- Import bundle → set active → list patients/visits
- Generate PDF & verify file exists and opens in QL
- Export path writeability & checksum check

**Manual QA**
- Console filters by subsystem/category
- Try share failures and permission edges

---

## 10) Security & Privacy

- Never log PHI raw
- Sandboxed file access; user-consented locations
- Clean temp dirs after export/import
- Consider notarization/signing later

---

## 11) Phases, Tasks & Milestones

### Phase A — Project Bring-Up
- [ ] Add PediaShared as local SPM dep
- [ ] Wire `Log` categories
- [ ] Add `PathsMac.swift` to resolve working dirs
**Milestone A:** App builds; logging works; paths resolve

### Phase B — Storage & Bundle IO
- [ ] Implement `SQLiteStoreMac` (conform to `PatientStore`, `VisitStore`, `NotesStore`, `AttachmentStore`)
- [ ] Implement `BundleIO` (import/validate/export; checksum)
- [ ] Open DB on Active selection; create tables if missing
**Milestone B:** Can import a sample bundle and see lists

### Phase C — Screens & Workflows
- [ ] Sidebar + lists
- [ ] Patient Detail + Notes editor (autosave w/ debounce)
- [ ] Visit Detail (well/sick) with preview buttons
- [ ] Docs list with QuickLook + Share
**Milestone C:** Clinician can manage a bundle end-to-end locally

### Phase D — Reports & Charts
- [ ] GrowthChartsMacAdapter (produce images)
- [ ] Well/Sick PDF builders (reuse PediaShared layout logic)
- [ ] Preview + Share flows; file existence checks
**Milestone D:** PDFs look correct; export with embedded images

### Phase E — QA & Release
- [ ] Unit tests (PediaShared); integration tests (basic)
- [ ] Docs updated: ROADMAP, DATA_MODEL, PEDIA_SHARED_GUIDE
- [ ] Tag `v1.0.0` (internal)
**Milestone E:** Ready for internal pilots

---

## 12) Risks & Mitigations

- **Stale paths / sandbox quirks** → Path helpers + logs show resolution + permissions
- **SQLite locking** → Single writer queue; checkpoint before export
- **Share sheet errors** → Verify readable file URLs; fallback to Finder reveal
- **Schema drift** → `meta.schema_version` + additive migrations only

---

## 13) Deliverables Checklist (v1)

- [ ] DrsMainApp app bundle (Debug/Release)
- [ ] Import/Active/Export workflows with logs
- [ ] Patient/Visit/Docs views functional
- [ ] Well/Sick PDF generation + preview + share
- [ ] Growth charts embedded in PDFs
- [ ] Basic test coverage and developer docs

---

## 14) Suggested DrsMainApp Structure
DrsMainApp/
Sources/
App/
DrsMainApp.swift
AppState.swift
UI/
SidebarView.swift
PatientListView.swift
PatientDetailView.swift
VisitListView.swift
VisitDetailView.swift
DocumentsView.swift
PDFPreviewMac.swift
Data/
SQLiteStoreMac.swift
BundleIO.swift
PathsMac.swift
Features/
GrowthChartsMacAdapter.swift
PDFBuilders/
WellVisitPDFBuilder.swift
SickVisitPDFBuilder.swift
Util/
Logging.swift
ErrorBridging.swift
Tests/
DrsMainAppTests.swift

---

## 15) Getting Started (Dev)

```bash
# From repo root
xed PediWorkspace.xcworkspace

# In Xcode: select DrsMainApp scheme → Run
# Check Console app for subsystem: com.pediai.DrsMainApp

Pro Tips
    - Keep PediaShared UI-free; add only protocols/helpers/models
    - Any time you handle file URLs, log their existence + isReadable (privacy-masked)
    - Before export: VACUUM + PRAGMA wal_checkpoint(TRUNCATE)
    
---

## 16) Backlog (Post-v1)
    - Theming + nicer typography
    - “Reveal in Finder” buttons across flows
    - Optional local backup of last N exports
    - AI helpers (later, behind consent)
    
**Optional add/commit:**
```bash
mkdir -p docs
printf "%s" "<PASTE THE CONTENT ABOVE>" > docs/DrsMainApp_Roadmap.md
git add docs/DrsMainApp_Roadmap.md
git commit -m "docs: add focused DrsMainApp roadmap"
git push


