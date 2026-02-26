#!/usr/bin/env bash
set -euo pipefail
set -x

cd "/Users/goldman/Documents/CodeProjects/pedi-ai-assistant-ios/tools/snomed_builder"

rm -f snomed.sqlite snomed.sqlite-wal snomed.sqlite-shm snomed.sqlite-journal

RF2_PATH="/Users/goldman/Documents/CodeProjects/SnomedCT_InternationalRF2_PRODUCTION_20260201T120000Z"
SUBSET_PATH="${SUBSET_PATH:-/Users/goldman/Documents/CodeProjects/pedi-ai-assistant-ios/tools/SickTokens/subset_concepts_from_csv.txt}"
FEATURE_MAP_PATH="/Users/goldman/Documents/CodeProjects/pedi-ai-assistant-ios/tools/SickTokens/sick_token_map_backlog_clean.csv"
SCHEMA_PATH="snomed_schema.sql"
OUT_PATH="snomed.sqlite"

# --- Regenerate subset concept list from the feature-map CSV ---
# This ensures snomed.sqlite always matches the latest concept IDs in the CSV.
export FEATURE_MAP_PATH
export SUBSET_PATH

python3 - <<'PY'
import csv, re, pathlib, os, sys

csv_path = pathlib.Path(os.environ.get("FEATURE_MAP_PATH", ""))
out_path = pathlib.Path(os.environ.get("SUBSET_PATH", ""))

if not csv_path.is_file():
    print(f"ERROR: feature-map CSV not found: {csv_path}", file=sys.stderr)
    raise SystemExit(2)

out_path.parent.mkdir(parents=True, exist_ok=True)

def is_true(x: str) -> bool:
    return (x or "").strip().lower() in {"true","1","yes","y"}

concepts = set()
with csv_path.open("r", encoding="utf-8", newline="") as f:
    for row in csv.DictReader(f):
        if not is_true(row.get("map_to_snomed", "")):
            continue
        cid = (row.get("snomed_concept_id") or "").strip()
        if re.fullmatch(r"\d+", cid):
            concepts.add(cid)

out_path.write_text("\n".join(sorted(concepts, key=int)) + "\n", encoding="utf-8")
print(f"✅ Regenerated subset list: {out_path} (ids={len(concepts)})")
PY

echo "=== SNOMED SickTokens build ==="
echo "RF2:         $RF2_PATH"
echo "Subset list: $SUBSET_PATH"
echo "Feature map: $FEATURE_MAP_PATH"
echo "Schema:      $(pwd)/$SCHEMA_PATH"
echo "Out:         $(pwd)/$OUT_PATH"

# Fail fast if any inputs are missing
[[ -e "$RF2_PATH" ]] || { echo "ERROR: RF2 not found: $RF2_PATH"; exit 2; }
# SUBSET_PATH is regenerated from the CSV above.
[[ -f "$SUBSET_PATH" ]] || { echo "ERROR: subset list not found after regeneration: $SUBSET_PATH"; exit 2; }
[[ -f "$FEATURE_MAP_PATH" ]] || { echo "ERROR: feature-map CSV not found: $FEATURE_MAP_PATH"; exit 2; }
[[ -f "$SCHEMA_PATH" ]] || { echo "ERROR: schema.sql not found in $(pwd): $SCHEMA_PATH"; exit 2; }


python3 -u build.py \
  --rf2 "$RF2_PATH" \
  --subset "$SUBSET_PATH" \
  --schema "$SCHEMA_PATH" \
  --out "$OUT_PATH" \
  --rf2-release 20260201 \
  --subset-name sick_tokens_v1 \
  --subset-version 2026-02-01 \
  --feature-map "$FEATURE_MAP_PATH" \
  --validate-feature-map \
  --feature-map-report "${OUT_PATH}.feature_map_report.csv" \
  # --fail-on-feature-map-mismatch

# Show feature-map validation report location
echo "Feature-map report: $(pwd)/${OUT_PATH}.feature_map_report.csv"

# --- Sanity checks on the generated SQLite DB ---
command -v sqlite3 >/dev/null 2>&1 || { echo "ERROR: sqlite3 not found in PATH"; exit 2; }

echo "=== Sanity checks: snomed.sqlite ==="

# 1) Integrity check
sqlite3 "$OUT_PATH" "PRAGMA quick_check;" | head -n 5

# 2) Required tables exist
for t in meta concept description langrefset isa_edge feature_snomed_map; do
  ok=$(sqlite3 "$OUT_PATH" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='$t' LIMIT 1;")
  if [[ "$ok" != "1" ]]; then
    echo "ERROR: missing required table: $t"; exit 2
  fi
done

# 3) Feature map row count (should be > 0 when feature-map CSV is provided)
FM_COUNT=$(sqlite3 "$OUT_PATH" "SELECT COUNT(*) FROM feature_snomed_map;")
echo "feature_snomed_map rows: $FM_COUNT"
if [[ "${FM_COUNT:-0}" -le 0 ]]; then
  echo "ERROR: feature_snomed_map is empty (expected > 0)."; exit 2
fi

# 4) Basic row counts (informational)
C_COUNT=$(sqlite3 "$OUT_PATH" "SELECT COUNT(*) FROM concept;")
D_COUNT=$(sqlite3 "$OUT_PATH" "SELECT COUNT(*) FROM description;")
I_COUNT=$(sqlite3 "$OUT_PATH" "SELECT COUNT(*) FROM isa_edge;")
echo "concept rows: $C_COUNT | description rows: $D_COUNT | isa_edge rows: $I_COUNT"

mkdir -p "$HOME/Library/Containers/com.yunastic.careflowkids/Data/Library/Application Support/DrsMainApp/Terminology"
cp -f snomed.sqlite "$HOME/Library/Containers/com.yunastic.careflowkids/Data/Library/Application Support/DrsMainApp/Terminology/snomed.sqlite"

echo "✅ Copied snomed.sqlite into app container Terminology folder"
