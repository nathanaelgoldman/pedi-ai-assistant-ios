# PatientViewerApp

Privacy-first iOS app to view/edit a single patient “bundle”.

## Features
- Import/export `.peMR.zip` bundles (zip with `db.sqlite`, optional `docs/`, `manifest.json`)
- Parent Notes editing, WHO growth charts (height/weight/head circ.)
- Active vs Persistent bundles; all on-device, no servers

## Requirements
- Xcode 15+
- iOS 16+ (tested on iOS 17 simulator)
- Swift 5.9+

## Build & Run
1. Open `PatientViewerApp/PatientViewerApp.xcodeproj` in Xcode.
2. Select a Simulator (or device) and Run.

## Bundle Format
- `db.sqlite` — SQLite database  
- `docs/` — optional files  
- `manifest.json` — metadata (format version, timestamps, patient id/alias, etc.)

Exported filename: `alias-YYYYMMDD-HHMMSS-patientviewer.peMR.zip`  
Sharing uses iOS share sheet (`ShareLink`) instead of opening file URLs directly.

## Notes
- Centralized sheet routing to avoid “only one sheet at a time” warnings.
- Export filenames are slugged (no emoji/spaces).

## Roadmap
- Import validation UI, polishing, unit tests
