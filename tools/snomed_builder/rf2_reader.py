from __future__ import annotations

import csv
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterator, Optional


@dataclass
class RF2Snapshot:
    """
    RF2 Snapshot reader (folder-based).

    For now:
      - expects an *extracted* RF2 release folder
      - locates Snapshot files under root via rglob
      - yields rows as dicts keyed by RF2 header columns

    Next step will add ZIP support (same iterator API).
    """

    root: Path
    lang: str = "en"

    def __post_init__(self) -> None:
        self.root = Path(self.root).expanduser()

    def infer_release_id(self) -> Optional[str]:
        """Try to infer YYYYMMDD from the zip/folder name."""
        m = re.search(r"(20\d{6})", self.root.name)
        return m.group(1) if m else None

    # -------------------------
    # File location
    # -------------------------

    def _pick_one(self, patterns: list[str]) -> Path:
        """
        Find files matching patterns under root. If multiple matches exist,
        pick the last by lexicographic sort (usually includes release date).
        """
        matches: list[Path] = []
        for pat in patterns:
            matches.extend(self.root.rglob(pat))
        if not matches:
            raise FileNotFoundError(
                "RF2 Snapshot file not found under root. Tried patterns: " + ", ".join(patterns)
            )
        matches = sorted({p.resolve() for p in matches})
        return matches[-1]

    def concept_snapshot_path(self) -> Path:
        # sct2_Concept_Snapshot_INT_20240101.txt
        # sct2_Concept_Snapshot_US1000124_20240301.txt
        return self._pick_one([
            "sct2_Concept_Snapshot_*.txt",
            "sct2_Concept_Snapshot_*",
        ])

    def description_snapshot_path(self) -> Path:
        # sct2_Description_Snapshot-en_INT_20240101.txt
        # sct2_Description_Snapshot_en_US1000124_20240301.txt  (some variants)
        lang = self.lang
        return self._pick_one([
            f"sct2_Description_Snapshot-{lang}_*.txt",
            f"sct2_Description_Snapshot_{lang}_*.txt",
            "sct2_Description_Snapshot_*.txt",
            "sct2_Description_Snapshot_*",
        ])

    def language_refset_snapshot_path(self) -> Path:
        # der2_cRefset_LanguageSnapshot-en_INT_20240101.txt
        # der2_cRefset_LanguageSnapshot_en_US1000124_20240301.txt
        lang = self.lang
        return self._pick_one([
            f"der2_cRefset_LanguageSnapshot-{lang}_*.txt",
            f"der2_cRefset_LanguageSnapshot_{lang}_*.txt",
            "der2_cRefset_LanguageSnapshot_*.txt",
            "der2_cRefset_LanguageSnapshot_*",
        ])

    # -------------------------
    # TSV iteration
    # -------------------------

    def _iter_tsv_dicts(self, path: Path) -> Iterator[Dict[str, str]]:
        """Yield each RF2 row as a dict keyed by header columns."""
        with path.open("r", encoding="utf-8", newline="") as f:
            reader = csv.DictReader(f, delimiter="\t")
            for row in reader:
                if not row:
                    continue
                yield row

    @staticmethod
    def _is_active(row: Dict[str, str]) -> bool:
        return row.get("active", "0") == "1"

    # -------------------------
    # Public iterators
    # -------------------------

    def iter_concepts(self, active_only: bool = True) -> Iterator[Dict[str, str]]:
        path = self.concept_snapshot_path()
        for row in self._iter_tsv_dicts(path):
            if active_only and not self._is_active(row):
                continue
            yield row

    def iter_descriptions(self, active_only: bool = True) -> Iterator[Dict[str, str]]:
        path = self.description_snapshot_path()
        for row in self._iter_tsv_dicts(path):
            if active_only and not self._is_active(row):
                continue
            yield row

    def iter_language_refset(self, active_only: bool = True) -> Iterator[Dict[str, str]]:
        path = self.language_refset_snapshot_path()
        for row in self._iter_tsv_dicts(path):
            if active_only and not self._is_active(row):
                continue
            yield row
