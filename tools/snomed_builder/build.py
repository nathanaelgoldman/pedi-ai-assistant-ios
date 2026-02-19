from __future__ import annotations

import argparse
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

    parser.add_argument("--subset-name", default="custom_subset")
    parser.add_argument("--subset-version", default=date.today().isoformat())
    parser.add_argument("--schema-version", default="1.0")
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
