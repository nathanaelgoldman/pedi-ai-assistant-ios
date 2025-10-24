# ---------- Pretty printing ----------
is_tty() { [[ -t 1 ]]; }
bold()  { is_tty && tput bold || true; }
sgr0()  { is_tty && tput sgr0 || true; }
green() { is_tty && tput setaf 2 || true; }
yellow(){ is_tty && tput setaf 3 || true; }
cyan()  { is_tty && tput setaf 6 || true; }
red()   { is_tty && tput setaf 1 || true; }

hdr(){ echo -e "$(bold)$(cyan)⇨ $*$(sgr0)"; }
ok(){  echo -e "$(green)✓$(sgr0) $*"; }
warn(){ echo -e "$(yellow)⚠$(sgr0) $*"; }
err(){ echo -e "$(red)✗$(sgr0) $*"; }

# ---------- Locate repo root & checklist ----------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
CHECKLIST="$REPO_ROOT/UPGRADE_CHECKLIST.md"

cd "$REPO_ROOT"

echo
hdr "Upgrade Assistant (read-only checks + open checklist)"
echo "Repo root: $REPO_ROOT"
echo

# ---------- Checklist existence ----------
if [[ -f "$CHECKLIST" ]]; then
  ok "Found UPGRADE_CHECKLIST.md at repo root."
else
  warn "UPGRADE_CHECKLIST.md not found at repo root."
fi

# ---------- Xcode Command Line Tools ----------
hdr "Xcode / CLT"
if XCODE_PATH="$(xcode-select -p 2>/dev/null)"; then
  ok "xcode-select path: $XCODE_PATH"
else
  err "Xcode Command Line Tools not installed. Run: xcode-select --install"
fi

if XCB_VER="$(xcodebuild -version 2>/dev/null)"; then
  echo "$XCB_VER" | sed 's/^/  /'
else
  warn "xcodebuild not available."
fi

# ---------- SDKs ----------
hdr "Installed SDKs"
if xcodebuild -showsdks >/dev/null 2>&1; then
  xcodebuild -showsdks | sed 's/^/  /'
else
  warn "Could not list SDKs (xcodebuild -showsdks failed)."
fi

# ---------- Swift version ----------
hdr "Swift toolchain"
if SWIFT_VER="$(swift --version 2>/dev/null)"; then
  echo "  $SWIFT_VER"
else
  warn "swift not found."
fi

# ---------- Simulators ----------
hdr "Simulator runtimes"
if xcrun simctl list runtimes >/dev/null 2>&1; then
  xcrun simctl list runtimes | sed 's/^/  /'
else
  warn "Unable to list sim runtimes (xcrun simctl)."
fi

# ---------- Project/Workspace presence ----------
hdr "Project structure"
FOUND=0
if ls -1 *.xcworkspace >/dev/null 2>&1; then
  echo "  Workspaces:"
  ls -1 *.xcworkspace | sed 's/^/    • /'
  FOUND=1
fi
if ls -1 *.xcodeproj >/dev/null 2>&1; then
  echo "  Projects:"
  ls -1 *.xcodeproj | sed 's/^/    • /'
  FOUND=1
fi
if [[ $FOUND -eq 0 ]]; then
  warn "No .xcworkspace or .xcodeproj files found at repo root."
fi

# ---------- Git status ----------
hdr "Git status"
if git rev-parse --git-dir >/dev/null 2>&1; then
  echo "  Current branch: $(git rev-parse --abbrev-ref HEAD)"
  echo "  Recent commits:"
  git --no-pager log --oneline -n 3 | sed 's/^/    /'
  echo "  Uncommitted changes:"
  if git status --porcelain | sed 's/^/    /' | grep . >/dev/null; then
    git status --porcelain | sed 's/^/    /'
  else
    echo "    (clean)"
  fi
else
  warn "Not a git repository."
fi

# ---------- Open the checklist ----------
if [[ -f "$CHECKLIST" ]]; then
  echo
  hdr "Opening checklist"
  open "$CHECKLIST" >/dev/null 2>&1 || warn "Couldn't auto-open the checklist; open it manually."
fi

echo
ok "Done. Review the checklist and proceed with the Xcode/iOS upgrade when ready."
echo "You can re-run this script anytime: ./scripts/upgrade-assistant.sh"
