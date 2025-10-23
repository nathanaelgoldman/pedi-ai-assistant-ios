# pedi-ai-assistant-ios

SwiftUI workspace for pediatrics tools on iOS.

- **PatientViewerApp** – a local, privacy-first viewer/editor for a single patient “bundle”.
  - Import/export `.peMR.zip` bundles (zip containing `db.sqlite`, optional `docs/`, and `manifest.json`)
  - Edit Parent Notes, view growth charts (WHO curves), manage active/persistent bundles
  - On-device only; no servers required
- **DrsMainApp** – placeholder for a clinician-facing app (coming next)

---

## Requirements
- Xcode 15+  
- iOS 16+ (tested on iOS 17 simulator)  
- Swift 5.9+

## Project Layout
> Exact subfolders may differ slightly—open the `PatientViewerApp` project in Xcode to build/run.

## Build & Run (PatientViewerApp)
1. Open **PatientViewerApp/PatientViewerApp.xcodeproj** in Xcode.
2. Select **iPhone Simulator** (or a device) and **Run**.
3. The app works fully offline; documents live in the app container.

## Bundles & Export Format
- Active bundle folder structure (inside app container):
  - `db.sqlite` – SQLite database
  - `docs/` – optional user documents
  - `manifest.json` – metadata (format version, timestamps, patient ID/alias, etc.)
- **Export** creates a `.peMR.zip` named like:  
  `alias-timestamp-patientviewer.peMR.zip`
- Sharing uses the iOS share sheet (`ShareLink`) instead of opening file URLs directly.

## Known/Recent Fixes
- Replaced direct `openURL` of exported zips with `ShareLink` to avoid  
  `NSOSStatusErrorDomain -10814 ("Only support loading options for CKShare and SWY types")`.
- Centralized sheet presentation via a simple router to avoid “only one sheet at a time” warnings.
- Safer, slugged export filenames; removed emoji/spaces from archive names.

## Roadmap
- Finish/extend **DrsMainApp**
- More robust import validation & UI polish
- Unit tests for bundle import/export

## Contributing
PRs and issues welcome once DrsMainApp scaffolding lands.

## License
TBD
