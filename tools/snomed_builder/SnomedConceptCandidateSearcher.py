from pathlib import Path
import csv
import re

def token_search_phrase(token: str) -> str:
    parts = [p for p in token.strip().split(".") if p]
    if len(parts) < 2:
        return token.strip()

    field = parts[-2]
    value = parts[-1]

    # Expand common abbreviations if you use them in tokens
    abbrev = {"ent": "ear nose throat", "msk": "musculoskeletal", "gi": "gastrointestinal"}
    field_phrase = abbrev.get(field, field)

    # Normalize underscores into words
    value_phrase = value.replace("_", " ")

    # Optional: strip laterality suffixes like _l/_r from the *search* phrase only
    value_phrase = re.sub(r"\b(l|r)\b$", "", value_phrase).strip()

    return f"{field_phrase} {value_phrase}".strip()

RF2 = Path("/Users/goldman/Documents/CodeProjects/SnomedCT_InternationalRF2_PRODUCTION_20260201T120000Z")

DESC = RF2 / "Snapshot/Terminology/sct2_Description_Snapshot-en_INT_20260201.txt"
CONCEPT = RF2 / "Snapshot/Terminology/sct2_Concept_Snapshot_INT_20260201.txt"

# The problematic feature_keys you found (concept missing in your built subset DB)
missing_feature_keys = [
    "sick.hpi.appearance.irritable",
    "sick.pe.ear.red_and_bulging_with_pus",
    "sick.pe.peristalsis.increased",
    "sick.pe.abdomen.guarding",
    "sick.hpi.urination.decreased",
    "sick.pe.lungs.crackles",
    "sick.pe.lungs.crackles_l",
    "sick.pe.lungs.crackles_r",
]

CSV_MAP = Path("/Users/goldman/Documents/CodeProjects/pedi-ai-assistant-ios/tools/SickTokens/sick_token_map_backlog_clean.csv")

def norm(s: str) -> str:
    s = (s or "").strip().lower()
    s = re.sub(r"[\(\)\[\],;:/\-]+", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s

# 1) Load: feature_key -> (raw_value_en, concept_id)
feat = {}
with CSV_MAP.open("r", encoding="utf-8", newline="") as f:
    for r in csv.DictReader(f):
        k = (r.get("token") or "").strip()
        if not k:
            continue
        feat[k] = {
            "raw_value_en": (r.get("raw_value_en") or "").strip(),
            "concept_id": (r.get("snomed_concept_id") or "").strip(),
        }

targets = []
for k in missing_feature_keys:
    if k in feat:
        targets.append((k, feat[k]["raw_value_en"], feat[k]["concept_id"]))
    else:
        targets.append((k, "", ""))

# 2) Build a small concept active lookup (so we can tell if candidates are active)
concept_active = {}
with CONCEPT.open("r", encoding="utf-8", errors="ignore") as f:
    hdr = f.readline().rstrip("\n").split("\t")
    i_id = hdr.index("id")
    i_active = hdr.index("active")
    for line in f:
        p = line.rstrip("\n").split("\t")
        cid = p[i_id]
        concept_active[cid] = p[i_active]

# 3) Scan Description snapshot once, collect candidates for our search strings
#    We'll match by term contains the raw_value_en (case-insensitive), and keep top N per feature.
TOPN = 15
queries = {k: norm(token_search_phrase(k)) for (k, raw, _) in targets}

cands = {k: [] for k in queries.keys()}

with DESC.open("r", encoding="utf-8", errors="ignore") as f:
    hdr = f.readline().rstrip("\n").split("\t")
    i_concept = hdr.index("conceptId")
    i_active = hdr.index("active")
    i_type = hdr.index("typeId")
    i_term = hdr.index("term")

    for line in f:
        p = line.rstrip("\n").split("\t")
        if p[i_active] != "1":
            continue
        term = p[i_term]
        term_n = norm(term)
        cid = p[i_concept]
        type_id = p[i_type]
        # very simple matcher: substring
        for fk, q in queries.items():
            q_words = [w for w in q.split(" ") if w]
            if q_words and all(w in term_n for w in q_words):
                cands[fk].append((cid, type_id, term))

# 4) Write results
OUT = Path("missing_token_candidates_from_rf2.csv")
with OUT.open("w", encoding="utf-8", newline="") as f:
    w = csv.writer(f)
    w.writerow(["feature_key","search_raw_value_en","existing_concept_id_in_csv","candidate_concept_id","candidate_concept_active","type_id","term"])
    for (fk, raw, existing) in targets:
        if fk not in cands:
            w.writerow([fk, raw, existing, "", "", "", "NO RAW_VALUE_EN FOUND"])
            continue
        rows = cands[fk]
        # de-dupe by (concept, term)
        seen = set()
        uniq = []
        for cid, type_id, term in rows:
            key = (cid, term)
            if key in seen:
                continue
            seen.add(key)
            uniq.append((cid, type_id, term))

        # prefer FSN then synonyms (FSN typeId=900000000000003001)
        def sort_key(x):
            cid, type_id, term = x
            is_fsn = (type_id == "900000000000003001")
            return (0 if is_fsn else 1, term.lower())

        uniq.sort(key=sort_key)

        for cid, type_id, term in uniq[:TOPN]:
            w.writerow([fk, raw, existing, cid, concept_active.get(cid,"?"), type_id, term])

print(f"Wrote {OUT} ({sum(len(v) for v in cands.values())} raw hits before trimming).")
