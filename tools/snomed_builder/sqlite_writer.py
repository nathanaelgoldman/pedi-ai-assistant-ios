from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Iterable


class SQLiteWriter:
    """
    Writes a SNOMED subset SQLite DB.

    Assumes your schema SQL creates:
      - meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)
      - concept(concept_id INTEGER PRIMARY KEY, active INTEGER, effective_time TEXT, module_id INTEGER, definition_status_id INTEGER)
      - description(description_id INTEGER PRIMARY KEY, concept_id INTEGER, active INTEGER, effective_time TEXT, module_id INTEGER,
                    language_code TEXT, type_id INTEGER, term TEXT, case_significance_id INTEGER)
      - langrefset(langrefset_id INTEGER PRIMARY KEY, active INTEGER, effective_time TEXT, module_id INTEGER,
                   refset_id INTEGER, referenced_component_id INTEGER, acceptability_id INTEGER)
      - isa_edge(child_concept_id INTEGER NOT NULL, parent_concept_id INTEGER NOT NULL, PRIMARY KEY(child_concept_id, parent_concept_id))
    """

    def __init__(self, out_path: Path):
        # IMPORTANT: produce a *single-file* SQLite DB suitable for shipping.
        # If the DB ends up in WAL mode, SQLite will try to open `-wal`/`-shm`
        # sidecar files at runtime. We do not want that for a bundled DB.
        self.conn = sqlite3.connect(str(out_path))

        # Safer defaults
        self.conn.execute("PRAGMA foreign_keys=ON")

        # Force non-WAL journaling for the on-disk artifact.
        # (We will also checkpoint+switch again in finalize() as a safety net.)
        self.conn.execute("PRAGMA journal_mode=DELETE")
        self.conn.execute("PRAGMA synchronous=NORMAL")

    def init_schema(self, schema_sql_path: Path) -> None:
        sql = schema_sql_path.read_text(encoding="utf-8")
        self.conn.executescript(sql)
        self.conn.commit()

    def write_meta(self, meta: dict[str, str]) -> None:
        self.conn.execute(
            "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
        )
        rows = [(k, v) for k, v in meta.items()]
        self.conn.executemany(
            "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)",
            rows,
        )
        self.conn.commit()

    # -------------------------
    # Bulk inserts
    # -------------------------

    def insert_concepts(self, rows: Iterable[tuple[int, int, str, int, int]]) -> None:
        """
        rows: (concept_id, active, effective_time, module_id, definition_status_id)
        """
        self.conn.executemany(
            """
            INSERT OR REPLACE INTO concept
              (concept_id, active, effective_time, module_id, definition_status_id)
            VALUES (?, ?, ?, ?, ?)
            """,
            rows,
        )

    def insert_descriptions(
        self,
        rows: Iterable[tuple[int, int, int, str, int, str, int, str, int]],
    ) -> None:
        """
        rows:
          (description_id, concept_id, active, effective_time, module_id,
           language_code, type_id, term, case_significance_id)
        """
        self.conn.executemany(
            """
            INSERT OR REPLACE INTO description
              (description_id, concept_id, active, effective_time, module_id,
               language_code, type_id, term, case_significance_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            rows,
        )

    def insert_langrefset(
        self,
        rows: Iterable[tuple[int, int, str, int, int, int, int]],
    ) -> None:
        """
        rows:
          (langrefset_id, active, effective_time, module_id,
           refset_id, referenced_component_id, acceptability_id)
        """
        self.conn.executemany(
            """
            INSERT OR REPLACE INTO langrefset
              (langrefset_id, active, effective_time, module_id,
               refset_id, referenced_component_id, acceptability_id)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            rows,
        )

    def insert_isa_edges(
        self,
        rows: Iterable[tuple[int, int]],
    ) -> None:
        """
        rows:
          (child_concept_id, parent_concept_id)

        Note: These should already be filtered to active IS-A relationships
        (typeId = 116680003) by the builder.
        """
        self.conn.executemany(
            """
            INSERT OR REPLACE INTO isa_edge
              (child_concept_id, parent_concept_id)
            VALUES (?, ?)
            """,
            rows,
        )

    def insert_feature_snomed_map(
        self,
        rows: Iterable[tuple[str, int, int, str | None]],
    ) -> None:
        """Populate feature_key → SNOMED concept mapping.

        rows:
          (feature_key, concept_id, active, note)

        This table is an *app bridge* from internal tokens (e.g. `sick.pe.lungs.wheezing`)
        to SNOMED concept IDs. It must be present in the shipped DB for TerminologyStore.
        """
        self.conn.executemany(
            """
            INSERT OR REPLACE INTO feature_snomed_map
              (feature_key, concept_id, active, note)
            VALUES (?, ?, ?, ?)
            """,
            rows,
        )

    def finalize(self) -> None:
        """Finalize the DB so it can be copied as a single file.

        We aggressively checkpoint/truncate any WAL and force journal_mode=DELETE
        so the shipped `snomed.sqlite` does not require `-wal`/`-shm` sidecars.
        """
        # Flush any pending work
        self.conn.commit()

        # If WAL ever got enabled (by default settings, tooling, or future edits),
        # checkpoint and truncate it so no sidecar is needed.
        try:
            self.conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        except sqlite3.DatabaseError:
            # Not in WAL mode (or SQLite build does not support it) — ignore.
            pass

        # Force DELETE journal mode for the final artifact
        self.conn.execute("PRAGMA journal_mode=DELETE")
        self.conn.commit()

    def close(self) -> None:
        try:
            self.conn.close()
        except Exception:
            pass
