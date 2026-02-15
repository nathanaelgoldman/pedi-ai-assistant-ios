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
    """

    def __init__(self, out_path: Path):
        self.out_path = out_path
        self.conn = sqlite3.connect(str(out_path))
        self.conn.execute("PRAGMA foreign_keys=ON")

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

    def finalize(self) -> None:
        self.conn.commit()

    def close(self) -> None:
        try:
            self.conn.close()
        except Exception:
            pass
