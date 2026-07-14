"""
db.py — SQLite database layer for NexVoice.

Tables:
  transcripts  — full history of STT results
  vocab        — custom vocabulary / bias hints
  settings     — key-value store for runtime config
"""

from __future__ import annotations

import sqlite3
import os
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Generator


# ---------------------------------------------------------------------------
# Connection helpers
# ---------------------------------------------------------------------------

_DB_PATH: str = ""


def init_db(db_path: str, defaults: dict[str, str] | None = None) -> None:
    """Create tables and seed defaults.  Call once at server startup."""
    global _DB_PATH
    _DB_PATH = db_path
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    os.chmod(Path(db_path).parent, 0o700)

    with _conn() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS transcripts (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                ts          TEXT NOT NULL,
                source      TEXT,
                engine      TEXT,
                model       TEXT,
                duration_ms INTEGER,
                raw         TEXT,
                cleaned     TEXT,
                style       TEXT
            );

            CREATE TABLE IF NOT EXISTS vocab (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                phrase      TEXT NOT NULL,
                sounds_like TEXT,
                enabled     INTEGER NOT NULL DEFAULT 1,
                ts          TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS settings (
                key   TEXT PRIMARY KEY,
                value TEXT
            );
            """
        )

        # Lightweight migration: add transcripts.style to pre-v2 DBs.
        cols = {r["name"] for r in conn.execute("PRAGMA table_info(transcripts)")}
        if "style" not in cols:
            conn.execute("ALTER TABLE transcripts ADD COLUMN style TEXT")

        # Seed default settings if they are missing
        seed: dict[str, str] = {
            "engine_default": "local",
            "cleanup_enabled": "0",
            "privacy_mode": "0",
            "cloud_model": "gemini-2.5-flash",
            "local_model": "mlx-community/whisper-large-v3-turbo",
            "cleanup_style": "tidy",
            "cleanup_engine": "local",
            "cleanup_nim_model": "qwen/qwen3-next-80b-a3b-instruct",
            "cleanup_local_model": "qwen3:4b-instruct",
        }
        if defaults:
            seed.update(defaults)

        for key, value in seed.items():
            conn.execute(
                "INSERT OR IGNORE INTO settings (key, value) VALUES (?, ?)",
                (key, value),
            )
    try:
        os.chmod(db_path, 0o600)
    except OSError:
        pass


@contextmanager
def _conn() -> Generator[sqlite3.Connection, None, None]:
    """Return a SQLite connection with row_factory set."""
    conn = sqlite3.connect(_DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Transcript helpers
# ---------------------------------------------------------------------------


def insert_transcript(
    ts: str,
    source: str,
    engine: str,
    model: str,
    duration_ms: int,
    raw: str,
    cleaned: str,
    style: str | None = None,
) -> int:
    """Insert a transcript row and return the new id."""
    with _conn() as conn:
        cur = conn.execute(
            """
            INSERT INTO transcripts (ts, source, engine, model, duration_ms, raw, cleaned, style)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (ts, source, engine, model, duration_ms, raw, cleaned, style),
        )
        return cur.lastrowid  # type: ignore[return-value]


def get_history(
    limit: int = 50, offset: int = 0, q: str | None = None
) -> list[dict[str, Any]]:
    """Return transcripts newest-first, optionally filtered by full-text search."""
    with _conn() as conn:
        if q:
            like = f"%{q}%"
            rows = conn.execute(
                """
                SELECT * FROM transcripts
                WHERE raw LIKE ? OR cleaned LIKE ?
                ORDER BY id DESC LIMIT ? OFFSET ?
                """,
                (like, like, limit, offset),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM transcripts ORDER BY id DESC LIMIT ? OFFSET ?",
                (limit, offset),
            ).fetchall()
        return [dict(r) for r in rows]


# ---------------------------------------------------------------------------
# Vocab helpers
# ---------------------------------------------------------------------------


def get_vocab() -> list[dict[str, Any]]:
    with _conn() as conn:
        rows = conn.execute("SELECT * FROM vocab ORDER BY id").fetchall()
        return [dict(r) for r in rows]


def insert_vocab(
    phrase: str, sounds_like: str | None, enabled: int = 1, ts: str = ""
) -> dict[str, Any]:
    with _conn() as conn:
        cur = conn.execute(
            "INSERT INTO vocab (phrase, sounds_like, enabled, ts) VALUES (?, ?, ?, ?)",
            (phrase, sounds_like or "", enabled, ts),
        )
        row = conn.execute(
            "SELECT * FROM vocab WHERE id = ?", (cur.lastrowid,)
        ).fetchone()
        return dict(row)


def update_vocab(vid: int, **fields: Any) -> dict[str, Any] | None:
    """Update whichever fields are provided."""
    if not fields:
        return get_vocab_by_id(vid)
    sets = ", ".join(f"{k} = ?" for k in fields)
    vals = list(fields.values()) + [vid]
    with _conn() as conn:
        conn.execute(f"UPDATE vocab SET {sets} WHERE id = ?", vals)
        row = conn.execute("SELECT * FROM vocab WHERE id = ?", (vid,)).fetchone()
        return dict(row) if row else None


def delete_vocab(vid: int) -> bool:
    with _conn() as conn:
        cur = conn.execute("DELETE FROM vocab WHERE id = ?", (vid,))
        return cur.rowcount > 0


def get_vocab_by_id(vid: int) -> dict[str, Any] | None:
    with _conn() as conn:
        row = conn.execute("SELECT * FROM vocab WHERE id = ?", (vid,)).fetchone()
        return dict(row) if row else None


# ---------------------------------------------------------------------------
# Settings helpers
# ---------------------------------------------------------------------------


def get_all_settings() -> dict[str, str]:
    with _conn() as conn:
        rows = conn.execute("SELECT key, value FROM settings").fetchall()
        return {r["key"]: r["value"] for r in rows}


def set_setting(key: str, value: str) -> None:
    with _conn() as conn:
        conn.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )
