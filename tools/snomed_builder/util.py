from __future__ import annotations

from pathlib import Path


def require_file(path: Path) -> None:
    if not path.exists() or not path.is_file():
        raise FileNotFoundError(f"Required file not found: {path}")


def require_dir(path: Path) -> None:
    if not path.exists() or not path.is_dir():
        raise FileNotFoundError(f"Required directory not found: {path}")


def atomic_replace_file(tmp_path: Path, final_path: Path) -> None:
    """Atomically replace final_path with tmp_path (same filesystem)."""
    final_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path.replace(final_path)
