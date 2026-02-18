#!/usr/bin/env python3
"""
Generate canonical, language-agnostic clinical tokens from SickEpisodeForm.swift
by reading the // MARK: - Choices arrays (the context is the array name).
Outputs: sick_tokens.csv
"""

from __future__ import annotations
import re
from pathlib import Path
import csv

SRC = Path("/Users/goldman/Documents/CodeProjects/pedi-ai-assistant-ios/DrsMainApp/DrsMainApp/Sources/UI/SickEpisodeForm.swift")  # adjust if needed
OUT = Path("sick_tokens.csv")

# Protocol A: sick.<domain>.<field>.<value>
# domain inferred from field bucket (hpi vs pe)
HPI_FIELDS = {
    "complaintOptions": "complaint",
    "appearanceChoices": "appearance",
    "feedingChoices": "feeding",
    "breathingChoices": "breathing",
    "urinationChoices": "urination",
    "painChoices": "pain_location",
    "stoolsChoices": "stools",
    "contextChoices": "context",
}
PE_FIELDS = {
    "generalChoices": "general_appearance",
    "hydrationChoices": "hydration",
    "heartChoices": "heart",
    "colorChoices": "color",
    "entChoices": "ent",
    "earChoices": "ear",        # laterality comes from UI field (right/left) later; keep generic here
    "eyeChoices": "eye",        # same
    "skinOptionsMulti": "skin",
    "lungsOptionsMulti": "lungs",
    "abdomenOptionsMulti": "abdomen",
    "genitaliaOptionsMulti": "genitalia",
    "nodesOptionsMulti": "lymph_nodes",
    "peristalsisChoices": "peristalsis",
    "neuroChoices": "neurological",
    "mskChoices": "musculoskeletal",
}

ARRAY_RE = re.compile(
    r"private\s+let\s+(?P<name>[A-Za-z0-9_]+)\s*=\s*\[(?P<body>.*?)\]",
    re.S
)

def norm_value(s: str) -> str:
    s = s.strip()
    s = s.lower()
    s = s.replace("&", " and ")
    # turn things like "Crackles (R)" -> "crackles_r"
    s = re.sub(r"\(([^)]+)\)", r" \1", s)
    s = re.sub(r"[^a-z0-9]+", "_", s)
    s = re.sub(r"_+", "_", s).strip("_")
    return s

def parse_string_literals(body: str) -> list[str]:
    # matches "..." strings, ignoring escaped quotes
    return re.findall(r'"((?:\\.|[^"\\])*)"', body)

def main():
    text = SRC.read_text(encoding="utf-8")
    arrays = {m.group("name"): parse_string_literals(m.group("body")) for m in ARRAY_RE.finditer(text)}

    rows = []
    seen = set()

    def add(domain: str, field: str, raw: str):
        value = norm_value(raw)
        token = f"sick.{domain}.{field}.{value}"
        if token in seen:
            return
        seen.add(token)
        rows.append({
            "token": token,
            "domain": domain,
            "field": field,
            "raw_value": raw,
            "value_norm": value,
            "source_array": array_name,
        })

    for array_name, values in arrays.items():
        if array_name in HPI_FIELDS:
            field = HPI_FIELDS[array_name]
            for v in values:
                add("hpi", field, v)
        elif array_name in PE_FIELDS:
            field = PE_FIELDS[array_name]
            for v in values:
                add("pe", field, v)

    rows.sort(key=lambda r: r["token"])

    with OUT.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["token","domain","field","raw_value","value_norm","source_array"])
        w.writeheader()
        w.writerows(rows)

    print(f"Wrote {OUT} with {len(rows)} tokens.")

if __name__ == "__main__":
    main()
