from __future__ import annotations

from pathlib import Path
from sqlite_writer import SQLiteWriter


def main():
    # Adjust paths if you want, but keep them simple for now.
    repo_root = Path(__file__).resolve().parents[2]
    schema_path = repo_root / "tools" / "snomed_builder" / "snomed_schema.sql"
    out_path = repo_root / "tools" / "snomed_builder" / "snomed_mock.sqlite"

    # Hardcoded mini "terminology slice" (NOT real RF2 content; dev scaffold only)
    # Concepts
    #  404684003 = Clinical finding
    #  386661006 = Fever
    #  29857009  = Cough
    #
    # Description typeIds:
    #  FSN: 900000000000003001
    #  SYN: 900000000000013009
    #
    # English langrefsets:
    #  en-US: 900000000000509007
    #  en-GB: 900000000000508004
    #
    # Acceptability:
    #  preferred: 900000000000548007
    #  acceptable: 900000000000549004

    effective = "20260131"
    module_id = 900000000000207008  # Core module (common in examples)
    def_status = 900000000000074008  # Primitive (ok for mock)

    concepts = [
        (404684003, 1, effective, module_id, def_status),
        (386661006, 1, effective, module_id, def_status),
        (29857009,  1, effective, module_id, def_status),
    ]

    FSN = 900000000000003001
    SYN = 900000000000013009
    case_sig = 900000000000448009  # Only initial character case insensitive (common)

    descriptions = [
        # Clinical finding
        (1000001, 404684003, 1, effective, module_id, "en", FSN, "Clinical finding (finding)", case_sig),
        (1000002, 404684003, 1, effective, module_id, "en", SYN, "Clinical finding", case_sig),

        # Fever
        (1000101, 386661006, 1, effective, module_id, "en", FSN, "Fever (finding)", case_sig),
        (1000102, 386661006, 1, effective, module_id, "en", SYN, "Fever", case_sig),
        (1000103, 386661006, 1, effective, module_id, "en", SYN, "Pyrexia", case_sig),

        # Cough
        (1000201, 29857009,  1, effective, module_id, "en", FSN, "Cough (finding)", case_sig),
        (1000202, 29857009,  1, effective, module_id, "en", SYN, "Cough", case_sig),
    ]

    EN_US = 900000000000509007
    EN_GB = 900000000000508004
    PREF  = 900000000000548007
    ACC   = 900000000000549004

    # langrefset rows refer to description IDs
    lang = [
        # Fever preferred in both
        (2000101, 1, effective, module_id, EN_US, 1000102, PREF),
        (2000102, 1, effective, module_id, EN_GB, 1000102, PREF),
        # Pyrexia acceptable
        (2000103, 1, effective, module_id, EN_US, 1000103, ACC),
        (2000104, 1, effective, module_id, EN_GB, 1000103, ACC),

        # Cough preferred
        (2000201, 1, effective, module_id, EN_US, 1000202, PREF),
        (2000202, 1, effective, module_id, EN_GB, 1000202, PREF),

        # Clinical finding preferred
        (2000001, 1, effective, module_id, EN_US, 1000002, PREF),
        (2000002, 1, effective, module_id, EN_GB, 1000002, PREF),
    ]

    # Build DB
    if out_path.exists():
        out_path.unlink()

    w = SQLiteWriter(out_path)
    w.init_schema(schema_path)

    w.insert_concepts(concepts)
    w.insert_descriptions(descriptions)
    w.insert_langrefset(lang)

    w.write_meta({
        "subset_name": "mock",
        "subset_version": "dev",
        "schema_version": "1.0",
        "rf2_release": "mock",
    })

    w.finalize()
    w.close()

    print(f"✅ Wrote mock DB: {out_path}")


if __name__ == "__main__":
    main()