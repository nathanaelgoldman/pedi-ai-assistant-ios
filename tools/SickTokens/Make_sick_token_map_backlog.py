python3 - <<'PY'
import csv
from pathlib import Path

SRC = Path("sick_tokens.csv")
OUT = Path("sick_token_map_backlog.csv")

rows = []
with SRC.open("r", encoding="utf-8", newline="") as f:
    r = csv.DictReader(f)
    for row in r:
        token = (row.get("token") or "").strip()
        domain = (row.get("domain") or "").strip()
        field  = (row.get("field") or "").strip()
        raw    = (row.get("raw_value") or "").strip()
        norm   = (row.get("value_norm") or "").strip()

        rows.append({
            # identity (language-agnostic)
            "token": token,                 # e.g. sick.pe.eye.red
            "domain": domain,               # hpi | pe | plan (or whatever your generator emits)
            "field": field,                 # appearance | eye | lungs | etc
            "raw_value_en": raw,            # stable stored value in Swift (English code)
            "value_norm": norm,             # normalized helper

            # mapping targets
            "map_to_snomed": "TRUE",
            "snomed_concept_id": "",        # fill later (SCTID)
            "snomed_fsn": "",               # optional: “Fully Specified Name”
            "snomed_semantic_tag": "",      # e.g. (finding), (procedure)
            "mapping_confidence": "",       # high | medium | low
            "status": "pending",            # pending | mapped | deferred | skip
            "notes": ""
        })

with OUT.open("w", encoding="utf-8", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    w.writeheader()
    w.writerows(rows)

print(f"Wrote {OUT} with {len(rows)} rows.")
PY