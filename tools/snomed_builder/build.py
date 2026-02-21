from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path
from datetime import date

from rf2_reader import RF2Snapshot
from subset import load_subset_concept_ids, build_subset_rows
from sqlite_writer import SQLiteWriter


def main():
    parser = argparse.ArgumentParser(
        description="Build SNOMED subset SQLite DB from RF2 Snapshot release."
    )

    parser.add_argument("--rf2", required=True, help="Path to RF2 release ZIP or extracted folder")
    parser.add_argument("--subset", required=True, help="Path to subset concept list file")
    parser.add_argument("--schema", required=True, help="Path to snomed_schema.sql")
    parser.add_argument("--out", required=True, help="Output path for snomed.sqlite")

    parser.add_argument(
        "--feature-map",
        default="",
        help=(
            "Optional SickTokens CSV to populate feature_snomed_map (app bridge). "
            "Expected headers: token,map_to_snomed,snomed_concept_id,notes (others ignored). "
            "Only rows with map_to_snomed TRUE/1/YES/Y and a numeric snomed_concept_id are imported."
        ),
    )

    parser.add_argument("--subset-name", default="custom_subset")
    parser.add_argument("--subset-version", default=date.today().isoformat())
    parser.add_argument("--schema-version", default="1.1")
    parser.add_argument("--rf2-release", default="unknown")
    parser.add_argument("--lang", default="en", choices=["en"])
    parser.add_argument("--limit", type=int, default=0)

    args = parser.parse_args()

    rf2_path = Path(args.rf2)
    subset_path = Path(args.subset)
    schema_path = Path(args.schema)
    out_path = Path(args.out)

    print("Loading RF2 snapshot...")
    rf2 = RF2Snapshot(rf2_path)

    print("Loading subset concept IDs...")
    seed_ids = load_subset_concept_ids(subset_path)
    print(f"Seed concepts: {len(seed_ids)}")

    print("Building subset rows...")
    result = build_subset_rows(
        rf2=rf2,
        seed_concept_ids=seed_ids,
        limit_descriptions=args.limit,
    )

    print(f"Kept concepts: {result.kept_concepts}")
    print(f"Kept descriptions: {result.kept_descriptions}")
    print(f"Kept lang refset rows: {result.kept_langrefset}")

    print("Creating SQLite DB...")
    writer = SQLiteWriter(out_path)
    writer.init_schema(schema_path)

    writer.insert_concepts(result.concept_rows)
    writer.insert_descriptions(result.description_rows)
    writer.insert_langrefset(result.langrefset_rows)

    # -------------------------
    # SNOMED hierarchy (IS-A)
    # -------------------------
    # We store active IS-A edges (typeId = 116680003) for kept concepts.
    # For v1, we keep edges where the CHILD is in the subset. Parents may be outside
    # the subset; that's OK for `isA()` checks later, but name/term lookup for those
    # parents will be unavailable unless we also include them in the subset.
    print("Extracting IS-A edges (typeId=116680003)...")
    kept_concept_ids = {row[0] for row in result.concept_rows}

    isa_edges: list[tuple[int, int]] = []
    for rel in rf2.iter_relationships(active_only=True):
        if rel.get("typeId") != "116680003":
            continue
        try:
            child = int(rel["sourceId"])
            parent = int(rel["destinationId"])
        except Exception:
            continue

        if child in kept_concept_ids:
            isa_edges.append((child, parent))

    print(f"Kept IS-A edges: {len(isa_edges)}")
    writer.insert_isa_edges(isa_edges)

    # -------------------------
    # App bridge: feature_key → SNOMED concept mapping
    # -------------------------
    feature_map_rows: list[tuple[str, int, int, str | None]] = []
    if args.feature_map:
        feature_map_path = Path(args.feature_map)
        print(f"Loading feature map CSV: {feature_map_path}")
        # NOTE: the SickTokens CSV uses these headers (as of Feb 2026):
        #   token, map_to_snomed, snomed_concept_id, notes, ...
        # We only import rows where map_to_snomed is TRUE and a concept_id is present.
        with feature_map_path.open("r", encoding="utf-8-sig", newline="") as f:
            reader = csv.DictReader(f)
            for r in reader:
                fk = (r.get("token") or "").strip()
                map_flag = (r.get("map_to_snomed") or "").strip().upper()
                cid = (r.get("snomed_concept_id") or "").strip()

                if not fk:
                    continue
                if map_flag not in {"TRUE", "1", "YES", "Y"}:
                    continue
                if not cid:
                    continue

                try:
                    concept_id = int(cid)
                except Exception:
                    continue

                # Active is implied by map_to_snomed=TRUE for this CSV.
                active = 1

                note = (r.get("notes") or "").strip() or None
                feature_map_rows.append((fk, concept_id, active, note))

        print(f"Feature map rows: {len(feature_map_rows)}")

        if len(feature_map_rows) == 0:
            print(
                "ERROR: --feature-map was provided but 0 rows were imported. "
                "This usually means the CSV was parsed incorrectly (wrong delimiter/encoding) or the shell command "
                "accidentally broke an argument (common cause: a line-continuation \\ followed by a trailing space).",
                file=sys.stderr,
            )
            sys.exit(2)

        writer.insert_feature_snomed_map(feature_map_rows)

    writer.write_meta(
        {
            "subset_name": args.subset_name,
            "subset_version": args.subset_version,
            "schema_version": args.schema_version,
            "rf2_release": args.rf2_release,
        }
    )

    writer.finalize()
    writer.close()

    print("Done.")
    print(f"Output written to: {out_path}")


if __name__ == "__main__":
    main()
