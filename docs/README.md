# 📚 Pedia Workspace Docs

Central index for project documentation across **PediWorkspace** (DrsMainApp, PatientViewerApp, and PediaShared).

---

## 🔗 Quick Links

- **Roadmap (DrsMainApp)**
  - [docs/DRS_MAINAPP_ROADMAP.md](./DRS_MAINAPP_ROADMAP.md)
- **Xcode/iOS Upgrade Checklist**
  - [docs/UPGRADE_CHECKLIST.md](./UPGRADE_CHECKLIST.md)

---

## 🗂 Folder Guide

- `docs/` — All documentation that should **not** ship in any app bundle.
- `scripts/` — Utility scripts (e.g., CI checks, Xcode upgrade helpers).
  - Example: `scripts/validate_xcode_upgrade.sh` (optional; if present, see usage in the upgrade checklist)

---

## ✍️ Editing Docs in Xcode

- Add `docs/` to the workspace as a **blue folder reference** (no targets).
- Click any `.md` file → toggle **Rendered** view from the editor toolbar (or **Editor ▸ Show Rendered Markup**).
- New docs: **File ▸ New ▸ File… ▸ Empty** (or Markdown) → save into `docs/`.

> Double-check docs files aren’t in **Build Phases ▸ Copy Bundle Resources** for any target.

---

## 🧭 Conventions

- **Filenames:** `SNAKE_CASE_WITH_DASHES.md` (e.g., `API-design-notes.md`) or ALLCAPS for formal docs (e.g., `UPGRADE_CHECKLIST.md`).
- **Headings:** Start with `# Title`, then `##` subsections. Keep one H1 per file.
- **Links:** Prefer relative links within `docs/` (e.g., `./UPGRADE_CHECKLIST.md`).
- **Scope:** Keep app-specific docs with the app; shared concepts go here.

---

## ✅ What to Read First

1. **Roadmap** → overall phases, milestones, and shared code plan.  
   See [DRS_MAINAPP_ROADMAP.md](./DRS_MAINAPP_ROADMAP.md)
2. **Upgrade Checklist** → safe path to try new Xcode/iOS.  
   See [UPGRADE_CHECKLIST.md](./UPGRADE_CHECKLIST.md)

---

## 🧩 Future Docs (stubs to add)

- `DATA_MODEL.md` — shared SQLite schema, bundle import/export protocol.
- `PEDIA_SHARED_GUIDE.md` — APIs offered by `PediaShared` (Swift Package) and usage patterns.
- `DRS_MAINAPP_ARCHITECTURE.md` — modules, navigation, and state model (macOS).
- `PATIENT_VIEWER_NOTES.md` — cross-app contracts used by PatientViewerApp.

---

_Last updated: <!-- YYYY-MM-DD -->_
