from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path
from datetime import date

from rf2_reader import RF2Snapshot
from subset import load_subset_concept_ids, build_subset_rows
from sqlite_writer import SQLiteWriter


def _build_fsn_index(rf2: RF2Snapshot) -> dict[int, str]:
    """Build a concept_id -> FSN(term) index from RF2 descriptions.

    This is used only for validation. We try a few common iterator names to stay compatible
    with different rf2_reader implementations.

    FSN typeId: 900000000000003001
    """
    fsn_type = "900000000000003001"
    idx: dict[int, str] = {}

    # Try common APIs
    it = None
    if hasattr(rf2, "iter_descriptions"):
        it = getattr(rf2, "iter_descriptions")
    elif hasattr(rf2, "iter_description_rows"):
        it = getattr(rf2, "iter_description_rows")

    if it is None:
        return idx

    try:
        for d in it(active_only=True):
            # DictReader-style rows
            try:
                if d.get("typeId") != fsn_type:
                    continue
                cid = int(d.get("conceptId"))
                term = (d.get("term") or "").strip()
            except Exception:
                continue
            if cid and term:
                idx[cid] = term
    except TypeError:
        # Some iterators may not accept active_only
        try:
            for d in it():
                try:
                    if d.get("typeId") != fsn_type:
                        continue
                    if d.get("active") not in {"1", 1, True, "true", "TRUE"}:
                        continue
                    cid = int(d.get("conceptId"))
                    term = (d.get("term") or "").strip()
                except Exception:
                    continue
                if cid and term:
                    idx[cid] = term
        except Exception:
            return idx
    except Exception:
        return idx

    return idx


def _is_concept_active(rf2: RF2Snapshot, concept_id: int) -> bool | None:
    """Best-effort concept active check. Returns None if not supported by rf2_reader."""
    if hasattr(rf2, "get_concept"):
        try:
            c = rf2.get_concept(concept_id)
            if isinstance(c, dict):
                v = c.get("active")
                if v in {"1", 1, True, "true", "TRUE"}:
                    return True
                if v in {"0", 0, False, "false", "FALSE"}:
                    return False
        except Exception:
            return None
    if hasattr(rf2, "concept_active"):
        try:
            return bool(rf2.concept_active(concept_id))
        except Exception:
            return None
    return None


def _write_feature_map_report(
    out_csv: Path,
    rows: list[dict[str, str]],
) -> None:
    out_csv.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "token",
        "snomed_concept_id",
        "csv_snomed_fsn",
        "rf2_fsn",
        "concept_active",
        "status",
        "notes",
    ]
    with out_csv.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "") for k in fieldnames})


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

    parser.add_argument(
        "--validate-feature-map",
        action="store_true",
        help=(
            "If set, validate mapped SNOMED IDs in --feature-map against RF2 FSN/active status "
            "and write a CSV mismatch report. Does not stop the build unless --fail-on-feature-map-mismatch is set."
        ),
    )

    parser.add_argument(
        "--feature-map-report",
        default="",
        help=(
            "Optional path for feature-map validation report CSV. "
            "If empty and --validate-feature-map is set, defaults to <out>.feature_map_report.csv"
        ),
    )

    parser.add_argument(
        "--fail-on-feature-map-mismatch",
        action="store_true",
        help=(
            "If set with --validate-feature-map, exit with non-zero status when mismatches are found."
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

        fsn_index: dict[int, str] = {}
        if args.validate_feature_map:
            print("Building RF2 FSN index for validation...")
            fsn_index = _build_fsn_index(rf2)
            print(f"FSN index entries: {len(fsn_index)}")

        report_rows: list[dict[str, str]] = []

        # NOTE: the SickTokens CSV uses these headers (as of Feb 2026):
        #   token, map_to_snomed, snomed_concept_id, notes, ...
        # We only import rows where map_to_snomed is TRUE and a concept_id is present.
        with feature_map_path.open("r", encoding="utf-8-sig", newline="") as f:
            reader = csv.DictReader(f)
            for r in reader:
                fk = (r.get("token") or "").strip()
                map_flag = (r.get("map_to_snomed") or "").strip().upper()
                cid = (r.get("snomed_concept_id") or "").strip()
                csv_fsn = (r.get("snomed_fsn") or r.get("fsn") or "").strip()

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

                if args.validate_feature_map:
                    rf2_fsn = fsn_index.get(concept_id, "")
                    active_flag = _is_concept_active(rf2, concept_id)
                    active_str = "" if active_flag is None else ("1" if active_flag else "0")

                    status = "ok"
                    notes_v = note or ""

                    if rf2_fsn and csv_fsn and (rf2_fsn.strip() != csv_fsn.strip()):
                        status = "fsn_mismatch"
                    elif not rf2_fsn and csv_fsn:
                        status = "fsn_not_found_in_rf2"
                    elif rf2_fsn and not csv_fsn:
                        status = "csv_fsn_missing"

                    if active_flag is False:
                        status = "concept_inactive"

                    report_rows.append(
                        {
                            "token": fk,
                            "snomed_concept_id": str(concept_id),
                            "csv_snomed_fsn": csv_fsn,
                            "rf2_fsn": rf2_fsn,
                            "concept_active": active_str,
                            "status": status,
                            "notes": notes_v,
                        }
                    )

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

        if args.validate_feature_map:
            report_path = Path(args.feature_map_report) if args.feature_map_report else out_path.with_suffix(".feature_map_report.csv")
            _write_feature_map_report(report_path, report_rows)

            mismatches = [r for r in report_rows if r.get("status") not in {"ok", ""}]
            print(f"Feature map validation report: {report_path}")
            print(f"Feature map mismatches: {len(mismatches)}")

            if args.fail_on_feature_map_mismatch and mismatches:
                print("ERROR: feature-map mismatches detected; failing because --fail-on-feature-map-mismatch is set.", file=sys.stderr)
                sys.exit(3)

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
