# memory_sidecar/db.py
import sqlite3
import time
import os

DEFAULT_DB_PATH = os.path.expanduser(
    "~/Library/Application Support/banti/data/identity.db"
)

def _conn(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn

def init_db(db_path: str = DEFAULT_DB_PATH) -> None:
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    with _conn(db_path) as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS persons (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                display_name    TEXT,
                face_embedding  BLOB,
                voice_embedding BLOB,
                face_faiss_id   INTEGER,
                voice_faiss_id  INTEGER,
                mem0_user_id    TEXT UNIQUE,
                first_seen      REAL,
                last_seen       REAL,
                metadata        TEXT
            )
        """)
        conn.commit()

def create_person(
    db_path: str,
    display_name: str | None,
    face_embedding: bytes | None,
    voice_embedding: bytes | None,
    metadata: dict | None = None,
) -> str:
    import json
    now = time.time()
    with _conn(db_path) as conn:
        cursor = conn.execute(
            """INSERT INTO persons
               (display_name, face_embedding, voice_embedding,
                first_seen, last_seen, metadata)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (display_name, face_embedding, voice_embedding,
             now, now, json.dumps(metadata or {})),
        )
        rowid = cursor.lastrowid
        person_id = f"p_{rowid}"
        mem0_user_id = f"person_{person_id}"
        conn.execute(
            "UPDATE persons SET mem0_user_id = ? WHERE id = ?",
            (mem0_user_id, rowid),
        )
        conn.commit()
    return person_id

def get_person_by_id(db_path: str, person_id: str) -> dict | None:
    rowid = int(person_id.lstrip("p_"))
    with _conn(db_path) as conn:
        row = conn.execute("SELECT * FROM persons WHERE id = ?", (rowid,)).fetchone()
    return dict(row) if row else None

def update_person_name(db_path: str, person_id: str, name: str) -> None:
    rowid = int(person_id.lstrip("p_"))
    with _conn(db_path) as conn:
        conn.execute(
            "UPDATE persons SET display_name = ?, last_seen = ? WHERE id = ?",
            (name, time.time(), rowid),
        )
        conn.commit()

def update_person_embeddings(
    db_path: str,
    person_id: str,
    face_embedding: bytes | None = None,
    voice_embedding: bytes | None = None,
    face_faiss_id: int | None = None,
    voice_faiss_id: int | None = None,
) -> None:
    rowid = int(person_id.lstrip("p_"))
    updates = []
    params = []
    if face_embedding is not None:
        updates.append("face_embedding = ?"); params.append(face_embedding)
    if voice_embedding is not None:
        updates.append("voice_embedding = ?"); params.append(voice_embedding)
    if face_faiss_id is not None:
        updates.append("face_faiss_id = ?"); params.append(face_faiss_id)
    if voice_faiss_id is not None:
        updates.append("voice_faiss_id = ?"); params.append(voice_faiss_id)
    if not updates:
        return
    updates.append("last_seen = ?"); params.append(time.time())
    params.append(rowid)
    with _conn(db_path) as conn:
        conn.execute(f"UPDATE persons SET {', '.join(updates)} WHERE id = ?", params)
        conn.commit()

def get_all_persons(db_path: str) -> list[dict]:
    with _conn(db_path) as conn:
        rows = conn.execute(
            "SELECT * FROM persons WHERE face_embedding IS NOT NULL"
        ).fetchall()
    return [dict(r) for r in rows]

def get_all_persons_with_voice(db_path: str) -> list[dict]:
    with _conn(db_path) as conn:
        rows = conn.execute(
            "SELECT * FROM persons WHERE voice_embedding IS NOT NULL"
        ).fetchall()
    return [dict(r) for r in rows]
