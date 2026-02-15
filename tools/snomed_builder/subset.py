from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, Iterator, Set


# SNOMED Description typeIds (common)
FSN_TYPE_ID = 900000000000003001   # Fully specified name
SYN_TYPE_ID = 900000000000013009   # Synonym

# English language refsets (commonly used)
EN_GB_LANGREFSET = 900000000000508004
EN_US_LANGREFSET = 900000000000509007

# Acceptability
PREFERRED = 900000000000548007
ACCEPTABLE = 900000000000549004


def load_subset_concept_ids(path: Path) -> set[int]:
    """
    Load a seed subset list (one conceptId per line).
    Supports comments after '#'.
    """
    ids: set[int] = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line:
            continue
        if "#" in line:
            line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if not line.isdigit():
            raise ValueError(f"Invalid conceptId in subset file: {raw!r}")
        ids.add(int(line))
    return ids


@dataclass
class SubsetResult:
    concept_rows: list[tuple[int, int, str, int, int]]
    description_rows: list[tuple[int, int, int, str, int, str, int, str, int]]
    langrefset_rows: list[tuple[int, int, str, int, int, int, int]]

    kept_concepts: int
    kept_descriptions: int
    kept_langrefset: int


def build_subset_rows(
    *,
    rf2,  # RF2Snapshot
    seed_concept_ids: set[int],
    lang_refset_ids: set[int] | None = None,
    prefer_fsn_and_synonyms: bool = True,
    limit_descriptions: int = 0,
) -> SubsetResult:
    """
    Create row-tuples for the SQLite schema.

    Strategy (minimal, deterministic):
      1) Keep active concepts whose id is in seed_concept_ids
      2) Keep active descriptions whose conceptId is in kept concepts
         - If prefer_fsn_and_synonyms=True: keep only FSN + SYN typeIds
      3) Keep active language refset rows for kept descriptionIds
         - If lang_refset_ids provided: keep only those refsetIds
    """
    if lang_refset_ids is None:
        lang_refset_ids = {EN_US_LANGREFSET, EN_GB_LANGREFSET}

    kept_concepts: Set[int] = set()
    concept_rows: list[tuple[int, int, str, int, int]] = []

    for row in rf2.iter_concepts(active_only=True):
        cid = int(row["id"])
        if cid not in seed_concept_ids:
            continue
        kept_concepts.add(cid)
        concept_rows.append(
            (
                cid,
                int(row["active"]),
                row["effectiveTime"],
                int(row["moduleId"]),
                int(row["definitionStatusId"]),
            )
        )

    kept_desc_ids: Set[int] = set()
    description_rows: list[tuple[int, int, int, str, int, str, int, str, int]] = []

    for row in rf2.iter_descriptions(active_only=True):
        concept_id = int(row["conceptId"])
        if concept_id not in kept_concepts:
            continue

        type_id = int(row["typeId"])
        if prefer_fsn_and_synonyms and type_id not in (FSN_TYPE_ID, SYN_TYPE_ID):
            continue

        did = int(row["id"])
        kept_desc_ids.add(did)
        description_rows.append(
            (
                did,
                concept_id,
                int(row["active"]),
                row["effectiveTime"],
                int(row["moduleId"]),
                row["languageCode"],
                type_id,
                row["term"],
                int(row["caseSignificanceId"]),
            )
        )

        if limit_descriptions and len(description_rows) >= limit_descriptions:
            break

    langrefset_rows: list[tuple[int, int, str, int, int, int, int]] = []
    kept_lang = 0

    for row in rf2.iter_language_refset(active_only=True):
        ref_comp = int(row["referencedComponentId"])
        if ref_comp not in kept_desc_ids:
            continue

        refset_id = int(row["refsetId"])
        if lang_refset_ids and refset_id not in lang_refset_ids:
            continue

        langrefset_rows.append(
            (
                int(row["id"]),
                int(row["active"]),
                row["effectiveTime"],
                int(row["moduleId"]),
                refset_id,
                ref_comp,
                int(row["acceptabilityId"]),
            )
        )
        kept_lang += 1

    return SubsetResult(
        concept_rows=concept_rows,
        description_rows=description_rows,
        langrefset_rows=langrefset_rows,
        kept_concepts=len(concept_rows),
        kept_descriptions=len(description_rows),
        kept_langrefset=kept_lang,
    )
