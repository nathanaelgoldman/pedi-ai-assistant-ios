# Xcode / iOS SDK Upgrade Checklist

**Goal:** Build with the latest Xcode & iOS SDK while keeping your current Deployment Target.  
**Branch**: `chore/xcode-upgrade`

---

## 0) Prep
- [ ] Create branch: `git switch -c chore/xcode-upgrade`
- [ ] Install latest Xcode + Command Line Tools
- [ ] Select it (if you use CLI): `sudo xcode-select -s /Applications/Xcode.app`

## 1) Clean caches
- [ ] Quit Xcode
- [ ] Remove DerivedData: `rm -rf ~/Library/Developer/Xcode/DerivedData/*`
- [ ] (Optional) Remove SPM cache if you see weird package issues: `rm -rf ~/Library/Developer/Xcode/DerivedData/SourcePackages`

## 2) Open & migrate
- [ ] Open the project, accept any migration prompts
- [ ] Confirm **Deployment Target** is unchanged (keep older device support)
- [ ] Set **Swift Language Version** to latest (Project & Targets)

## 3) Update dependencies
- [ ] Xcode: File ▸ Packages ▸ *Update to Latest Package Versions*  
  Or CLI: `xcodebuild -resolvePackageDependencies`

## 4) Build settings quick scan
- [ ] **Build Active Architecture Only (Debug)**: Yes (faster local builds)
- [ ] **Treat warnings as errors**: optional but recommended for CI
- [ ] Keep `CODE_SIGNING_ALLOWED=NO` for unsigned CI/one-off scripts
- [ ] Avoid raising Deployment Target unless truly needed; prefer `#available`

## 5) Regressions to re-check (we’ve seen these before)
- [ ] Swift 6 rules: captured vars in concurrent code, `@MainActor` on UI updaters
- [ ] Deprecated APIs replaced (e.g., `Scanner.scanDouble`)
- [ ] `QLPreviewController` + `UIActivityViewController` optionality
- [ ] `onChange` new signatures on iOS 17+
- [ ] `UIActivityItemSource` optional return types (match protocol!)
- [ ] Logging: noisy logs behind `#if DEBUG`

## 6) Manual smoke tests (functional flows)
- [ ] Bundle export/import
- [ ] Document preview + Share + Done
- [ ] Visit list → detail → Sick & Well PDF preview + share
- [ ] Growth charts (screen + PDF embed)
- [ ] Parent notes (add/edit/delete)
- [ ] Switching ActiveBundle/patient, persistence to PersistentBundles

## 7) Analyzer & archive
- [ ] Product ▸ Analyze (address new warnings)
- [ ] Archive (Release) once with `generic iOS device` to ensure nothing breaks
- [ ] Verify export/share still good on device

## 8) CI / scripts
- [ ] Run `scripts/upgrade_smoke.sh` (see below)
- [ ] Commit results (screenshots/logs) under `artifacts/` if helpful

## 9) Done
- [ ] PR created, description includes SDK/Xcode version + test notes
- [ ] Tag after merge if this is a tooling baseline#  <#Title#>

