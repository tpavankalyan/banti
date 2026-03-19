# Memory Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a persistent, human-like memory layer to banti — recognizing faces and voices across sessions, accumulating semantic facts about people, and maintaining a self-model — all passively with no user intervention required.

**Architecture:** A Python FastAPI sidecar (localhost:7700) handles all ML and cloud work: InsightFace + pyannote for biometric identity, Graphiti + Neo4j Aura for temporal memory, mem0 + GPT-4o for semantic facts. Swift actors wrap each capability and feed the existing PerceptionContext/AudioRouter pipeline with minimal changes.

**Tech Stack:** Swift actors (BantiCore), Python 3.11+, FastAPI, InsightFace (ArcFace buffalo_l), pyannote/embedding, FAISS, Graphiti-core, mem0ai, Neo4j Aura, OpenAI GPT-4o, SQLite, XCTest, pytest.

---

## File Map

### New files — Python (`memory_sidecar/`)
| File | Responsibility |
|---|---|
| `main.py` | FastAPI app, lifespan, all HTTP endpoints |
| `db.py` | SQLite init, CRUD for persons table |
| `identity.py` | InsightFace + pyannote + FAISS + identity logic |
| `memory.py` | Graphiti client + mem0 client + snapshot_to_episode |
| `models.py` | Pydantic request/response schemas |
| `requirements.txt` | Python dependencies |
| `setup.sh` | venv creation, pip install, HF_TOKEN docs |
| `tests/conftest.py` | pytest fixtures (test DB, mock app) |
| `tests/test_health.py` | /health endpoint |
| `tests/test_db.py` | SQLite CRUD |
| `tests/test_face.py` | /identity/face (mocked InsightFace) |
| `tests/test_voice.py` | /identity/voice (mocked pyannote) |
| `tests/test_memory.py` | /memory/ingest, /memory/query, /memory/reflect |

### New files — Swift (`Sources/BantiCore/`)
| File | Responsibility |
|---|---|
| `MemoryTypes.swift` | PersonState, PersonRecord, MemoryAction, MemoryResponse |
| `IdentityStore.swift` | In-memory session cache: person_id → name |
| `FaceIdentifier.swift` | JPEG → POST /identity/face → PersonState in PerceptionContext |
| `SpeakerResolver.swift` | 1s poll on context.speech → PCM ring buffer → POST /identity/voice → resolvedName write-back |
| `MemoryIngestor.swift` | 2s timer → snapshotJSON() → POST /memory/ingest with buffering |
| `MemoryQuery.swift` | Text query → POST /memory/query → MemoryResponse |
| `SelfModel.swift` | 10-min timer → POST /memory/reflect → update self.json |
| `ProactiveIntroducer.swift` | Unknown face duration tracking → stdout prompt |
| `MemoryEngine.swift` | Top-level actor, owns all above, start() |
| `MemorySidecar.swift` | Foundation.Process launch + /health polling |

### New files — Swift tests (`Tests/BantiTests/`)
| File | Tests |
|---|---|
| `MemoryTypesTests.swift` | PersonState, MemoryAction, MemoryResponse |
| `IdentityStoreTests.swift` | Cache set/get/clear |
| `MemoryQueryTests.swift` | query() with running/not-running sidecar |
| `AudioRouterPCMTests.swift` | Ring buffer append, overflow trim, readPCMRingBuffer |
| `FaceIdentifierTests.swift` | dispatch() with stub sidecar URL |
| `SpeakerResolverTests.swift` | Session map lookup, minAccumulationBytes constant |
| `MemoryIngestorTests.swift` | Duplicate filter, empty-snapshot filter |
| `ProactiveIntroducerTests.swift` | 30s threshold, 60s re-emit, silence after second prompt |
| `MemorySidecarTests.swift` | Path resolution logic |

### Modified files
| File | Change |
|---|---|
| `Sources/BantiCore/AudioTypes.swift` | Add `resolvedName: String?` to SpeechState (Task 8); update `DeepgramStreamer.parseResponse` to pass `resolvedName: nil` |
| `Sources/BantiCore/AudioRouter.swift` | Add PCM ring buffer: `pcmRingBuffer`, `appendToPCMRingBuffer`, `readPCMRingBuffer`, `pcmRingBufferMaxBytes` |
| `Sources/BantiCore/PerceptionTypes.swift` | Add `case person(PersonState)` to PerceptionObservation |
| `Sources/BantiCore/PerceptionContext.swift` | Add `var person: PersonState?`; add `.person` case to update() and snapshotJSON() |
| `Sources/BantiCore/PerceptionRouter.swift` | Add `var faceIdentifier: FaceIdentifier?`, throttled dispatch at 5s per "faceIdentifier" key |
| `Sources/banti/main.swift` | Wire MemoryEngine after pipeline setup |

---

## Task 1: Python sidecar scaffold

**Files:**
- Create: `memory_sidecar/models.py`
- Create: `memory_sidecar/main.py`
- Create: `memory_sidecar/requirements.txt`
- Create: `memory_sidecar/setup.sh`
- Create: `memory_sidecar/tests/__init__.py`
- Create: `memory_sidecar/tests/conftest.py`
- Create: `memory_sidecar/tests/test_health.py`

- [ ] **Step 1: Write the failing test**

```python
# memory_sidecar/tests/test_health.py
import pytest
from httpx import AsyncClient, ASGITransport

@pytest.mark.asyncio
async def test_health_returns_ok(app):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
```

- [ ] **Step 2: Create conftest.py fixture**

```python
# memory_sidecar/tests/conftest.py
import pytest
from main import create_app

@pytest.fixture
def app():
    return create_app(testing=True)
```

- [ ] **Step 3: Run test to verify it fails**

```bash
cd memory_sidecar
source .venv/bin/activate
pytest tests/test_health.py -v
```
Expected: `ModuleNotFoundError: No module named 'main'`

- [ ] **Step 4: Write requirements.txt**

```
fastapi>=0.109.0
uvicorn[standard]>=0.27.0
insightface>=0.7.3
onnxruntime>=1.17.0
faiss-cpu>=1.7.4
pyannote.audio>=3.1.1
graphiti-core>=0.3.0
mem0ai>=0.1.0
openai>=1.12.0
numpy>=1.26.0
Pillow>=10.2.0
opencv-python-headless>=4.9.0.80
python-dotenv>=1.0.0
pytest>=7.4.0
pytest-asyncio>=0.23.0
httpx>=0.26.0
```

- [ ] **Step 5: Write setup.sh**

```bash
#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

echo ""
echo "Setup complete."
echo ""
echo "REQUIRED before first run:"
echo "  1. Copy .env.example to .env and fill in API keys"
echo "  2. Accept pyannote/embedding model terms at https://huggingface.co/pyannote/embedding"
echo "     then set HF_TOKEN in .env"
echo "  3. Create a free Neo4j Aura instance at https://console.neo4j.io"
echo "     and add NEO4J_URI / NEO4J_USER / NEO4J_PASSWORD to .env"
```

- [ ] **Step 6: Write models.py**

```python
# memory_sidecar/models.py
from pydantic import BaseModel
from typing import Optional

class FaceRequest(BaseModel):
    jpeg_b64: str           # base64-encoded JPEG
    session_id: str

class VoiceRequest(BaseModel):
    pcm_b64: str            # base64-encoded raw PCM Int16 LE 16kHz mono
    deepgram_speaker_id: int
    session_id: str

class EnrollRequest(BaseModel):
    person_id: str
    name: str
    metadata: Optional[dict] = None

class IdentityResponse(BaseModel):
    matched: bool
    person_id: str
    name: Optional[str] = None
    confidence: float

class IngestRequest(BaseModel):
    snapshot_json: str      # raw snapshotJSON() output
    wall_ts: str            # ISO-8601 timestamp

class QueryRequest(BaseModel):
    q: str
    context_json: Optional[str] = None

class QueryResponse(BaseModel):
    answer: str
    sources: list[str] = []

class ReflectRequest(BaseModel):
    snapshots: list[str]    # array of snapshotJSON() strings

class ReflectResponse(BaseModel):
    summary: str
```

- [ ] **Step 7: Write main.py with /health endpoint**

```python
# memory_sidecar/main.py
import os
from contextlib import asynccontextmanager
from fastapi import FastAPI
from dotenv import load_dotenv

load_dotenv()

def create_app(testing: bool = False) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        # Startup: initialize heavy models only in production
        if not testing:
            from identity import init_identity
            from memory import init_memory
            await init_identity()
            await init_memory()
        yield
        # Shutdown: nothing to clean up yet

    app = FastAPI(title="banti memory sidecar", lifespan=lifespan)

    @app.get("/health")
    async def health():
        return {"status": "ok"}

    # Routers registered in later tasks
    return app

app = create_app()

if __name__ == "__main__":
    import uvicorn
    port = int(os.getenv("MEMORY_SIDECAR_PORT", "7700"))
    uvicorn.run("main:app", host="127.0.0.1", port=port, reload=False)
```

- [ ] **Step 8: Run test to verify it passes**

```bash
pytest tests/test_health.py -v
```
Expected: `PASSED tests/test_health.py::test_health_returns_ok`

- [ ] **Step 9: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git add memory_sidecar/
git commit -m "feat: memory sidecar scaffold — FastAPI health endpoint, models, setup.sh"
```

---

## Task 2: SQLite identity store

**Files:**
- Create: `memory_sidecar/db.py`
- Create: `memory_sidecar/tests/test_db.py`

- [ ] **Step 1: Write the failing tests**

```python
# memory_sidecar/tests/test_db.py
import pytest
import os
from db import init_db, create_person, get_person_by_id, update_person_name, get_all_persons

@pytest.fixture
def test_db(tmp_path):
    db_path = str(tmp_path / "test.db")
    init_db(db_path)
    return db_path

def test_init_db_creates_table(test_db):
    import sqlite3
    conn = sqlite3.connect(test_db)
    cursor = conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='persons'")
    assert cursor.fetchone() is not None
    conn.close()

def test_create_person_returns_id(test_db):
    person_id = create_person(test_db, display_name=None, face_embedding=None, voice_embedding=None)
    assert person_id.startswith("p_")

def test_create_person_assigns_mem0_user_id(test_db):
    person_id = create_person(test_db, display_name="Alice", face_embedding=None, voice_embedding=None)
    person = get_person_by_id(test_db, person_id)
    assert person["mem0_user_id"] == f"person_{person_id}"

def test_get_person_by_id_returns_none_for_missing(test_db):
    result = get_person_by_id(test_db, "p_9999")
    assert result is None

def test_update_person_name(test_db):
    person_id = create_person(test_db, display_name=None, face_embedding=None, voice_embedding=None)
    update_person_name(test_db, person_id, "Bob")
    person = get_person_by_id(test_db, person_id)
    assert person["display_name"] == "Bob"

def test_get_all_persons_empty_initially(test_db):
    assert get_all_persons(test_db) == []
```

- [ ] **Step 2: Run to verify failure**

```bash
pytest tests/test_db.py -v
```
Expected: `ModuleNotFoundError: No module named 'db'`

- [ ] **Step 3: Implement db.py**

```python
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
```

- [ ] **Step 4: Run to verify pass**

```bash
pytest tests/test_db.py -v
```
Expected: all 6 tests PASSED

- [ ] **Step 5: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git add memory_sidecar/db.py memory_sidecar/tests/test_db.py
git commit -m "feat: memory sidecar SQLite identity store — persons table CRUD"
```

---

## Task 3: Face recognition endpoint

**Files:**
- Create: `memory_sidecar/identity.py` (face section)
- Modify: `memory_sidecar/main.py` (register /identity/face route)
- Create: `memory_sidecar/tests/test_face.py`

- [ ] **Step 1: Write the failing tests**

```python
# memory_sidecar/tests/test_face.py
import pytest
import base64
import numpy as np
from unittest.mock import patch, MagicMock
from httpx import AsyncClient, ASGITransport

# 1x1 white JPEG (smallest valid JPEG)
TINY_JPEG_B64 = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/xAAUAQEAAAAAAAAAAAAAAAAAAAAA/8QAFBEBAAAAAAAAAAAAAAAAAAAAAP/aAAwDAQACEQMRAD8AJQAB/9k="

@pytest.fixture
def app_with_mock_identity(tmp_path):
    import os
    os.environ["BANTI_DB_PATH"] = str(tmp_path / "test.db")
    from db import init_db
    init_db(str(tmp_path / "test.db"))

    # Mock InsightFace so tests don't download models
    with patch("identity.FACE_APP") as mock_face_app:
        mock_face = MagicMock()
        mock_face.embedding = np.random.rand(512).astype(np.float32)
        mock_face_app.get.return_value = [mock_face]

        from main import create_app
        yield create_app(testing=False), tmp_path

@pytest.mark.asyncio
async def test_face_unknown_returns_new_person_id(app_with_mock_identity):
    app, tmp_path = app_with_mock_identity
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/identity/face", json={
            "jpeg_b64": TINY_JPEG_B64,
            "session_id": "test-session-1"
        })
    assert response.status_code == 200
    data = response.json()
    assert data["matched"] == False
    assert data["person_id"].startswith("p_")
    assert data["name"] is None

@pytest.mark.asyncio
async def test_face_same_person_matches_on_second_call(app_with_mock_identity):
    app, tmp_path = app_with_mock_identity
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r1 = await client.post("/identity/face", json={
            "jpeg_b64": TINY_JPEG_B64,
            "session_id": "test-session-2"
        })
        r2 = await client.post("/identity/face", json={
            "jpeg_b64": TINY_JPEG_B64,
            "session_id": "test-session-2"
        })
    id1 = r1.json()["person_id"]
    id2 = r2.json()["person_id"]
    assert id1 == id2  # Same embedding → same person
    assert r2.json()["matched"] == True

@pytest.mark.asyncio
async def test_face_no_faces_detected_returns_400(tmp_path):
    import os
    os.environ["BANTI_DB_PATH"] = str(tmp_path / "test.db")
    from db import init_db
    init_db(str(tmp_path / "test.db"))

    with patch("identity.FACE_APP") as mock_face_app:
        mock_face_app.get.return_value = []  # No faces
        from main import create_app
        app = create_app(testing=False)
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post("/identity/face", json={
                "jpeg_b64": TINY_JPEG_B64,
                "session_id": "test-session-3"
            })
    assert response.status_code == 400
```

- [ ] **Step 2: Run to verify failure**

```bash
pytest tests/test_face.py -v
```
Expected: `ImportError` or `ModuleNotFoundError` for identity module

- [ ] **Step 3: Implement identity.py (face section)**

```python
# memory_sidecar/identity.py
import os
import base64
import numpy as np
from typing import Optional

# --- Module-level globals (populated by init_identity) ---
FACE_APP = None       # insightface.app.FaceAnalysis
FACE_INDEX = None     # faiss.IndexFlatIP for 512-d
VOICE_MODEL = None    # pyannote Inference (None if HF_TOKEN missing)
VOICE_INDEX = None    # faiss.IndexFlatIP for 256-d

# person_id lists parallel to FAISS index positions
_face_person_ids: list[str] = []
_voice_person_ids: list[str] = []

DB_PATH = os.environ.get(
    "BANTI_DB_PATH",
    os.path.expanduser("~/Library/Application Support/banti/data/identity.db")
)

FACE_INDEX_PATH = os.path.expanduser(
    "~/Library/Application Support/banti/data/face.index"
)
VOICE_INDEX_PATH = os.path.expanduser(
    "~/Library/Application Support/banti/data/voice.index"
)

FACE_THRESHOLD = 0.6   # cosine similarity
VOICE_THRESHOLD = 0.75

async def init_identity() -> None:
    """Load models and rebuild FAISS indexes from SQLite on startup."""
    global FACE_APP, FACE_INDEX, VOICE_MODEL, VOICE_INDEX
    import faiss
    from db import init_db, get_all_persons, get_all_persons_with_voice

    init_db(DB_PATH)

    # Init InsightFace
    try:
        import insightface
        from insightface.app import FaceAnalysis
        FACE_APP = FaceAnalysis(
            name="buffalo_l",
            providers=["CoreMLExecutionProvider", "CPUExecutionProvider"]
        )
        FACE_APP.prepare(ctx_id=0, det_size=(640, 640))
    except Exception as e:
        print(f"[warn] InsightFace init failed: {e} — face identity disabled")
        FACE_APP = None

    # Init FAISS face index
    FACE_INDEX = faiss.IndexFlatIP(512)
    _rebuild_face_index(get_all_persons(DB_PATH))

    # Init pyannote (optional — requires HF_TOKEN)
    hf_token = os.environ.get("HF_TOKEN")
    if hf_token:
        try:
            from pyannote.audio import Model, Inference
            model = Model.from_pretrained("pyannote/embedding", use_auth_token=hf_token)
            VOICE_MODEL = Inference(model, window="whole")
        except Exception as e:
            print(f"[warn] pyannote init failed: {e} — voice identity disabled")
            VOICE_MODEL = None
    else:
        print("[warn] HF_TOKEN missing — voice identity disabled")
        VOICE_MODEL = None

    # Init FAISS voice index
    VOICE_INDEX = faiss.IndexFlatIP(256)
    _rebuild_voice_index(get_all_persons_with_voice(DB_PATH))


def _rebuild_face_index(persons: list[dict]) -> None:
    global _face_person_ids
    import faiss
    _face_person_ids = []
    if not persons:
        return
    embeddings = []
    for p in persons:
        if p["face_embedding"]:
            emb = np.frombuffer(p["face_embedding"], dtype=np.float32).copy()
            embeddings.append(emb)
            _face_person_ids.append(f"p_{p['id']}")
    if embeddings:
        matrix = np.stack(embeddings).astype(np.float32)
        faiss.normalize_L2(matrix)
        FACE_INDEX.add(matrix)


def _rebuild_voice_index(persons: list[dict]) -> None:
    global _voice_person_ids
    import faiss
    _voice_person_ids = []
    if not persons:
        return
    embeddings = []
    for p in persons:
        if p["voice_embedding"]:
            emb = np.frombuffer(p["voice_embedding"], dtype=np.float32).copy()
            embeddings.append(emb)
            _voice_person_ids.append(f"p_{p['id']}")
    if embeddings:
        matrix = np.stack(embeddings).astype(np.float32)
        faiss.normalize_L2(matrix)
        VOICE_INDEX.add(matrix)


def _normalize(vec: np.ndarray) -> np.ndarray:
    norm = np.linalg.norm(vec)
    if norm < 1e-8:
        return vec
    return vec / norm


def identify_face(jpeg_bytes: bytes) -> tuple[str, Optional[str], float]:
    """Returns (person_id, name_or_None, confidence). Enrolls on first sight."""
    import cv2
    import faiss
    from db import create_person, get_person_by_id, update_person_embeddings

    if FACE_APP is None:
        raise RuntimeError("Face model not initialized")

    # Decode JPEG → BGR for InsightFace
    img_array = np.frombuffer(jpeg_bytes, dtype=np.uint8)
    img = cv2.imdecode(img_array, cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError("Could not decode JPEG")

    faces = FACE_APP.get(img)
    if not faces:
        raise ValueError("No face detected in image")

    # Pick highest-confidence detection
    face = max(faces, key=lambda f: getattr(f, "det_score", 0.0))
    raw_emb = face.embedding.astype(np.float32)
    emb = _normalize(raw_emb)
    emb_row = emb.reshape(1, -1).copy()

    # Search FAISS
    if FACE_INDEX.ntotal > 0:
        faiss.normalize_L2(emb_row)
        distances, indices = FACE_INDEX.search(emb_row, 1)
        best_score = float(distances[0][0])
        best_idx = int(indices[0][0])

        if best_score >= FACE_THRESHOLD and best_idx < len(_face_person_ids):
            person_id = _face_person_ids[best_idx]
            person = get_person_by_id(DB_PATH, person_id)
            name = person["display_name"] if person else None
            return person_id, name, best_score

    # New person — enroll
    emb_blob = emb.tobytes()
    person_id = create_person(DB_PATH, display_name=None,
                               face_embedding=emb_blob, voice_embedding=None)

    faiss_id = FACE_INDEX.ntotal
    faiss_emb = emb.reshape(1, -1).copy()
    faiss.normalize_L2(faiss_emb)
    FACE_INDEX.add(faiss_emb)
    _face_person_ids.append(person_id)

    update_person_embeddings(DB_PATH, person_id,
                              face_embedding=emb_blob,
                              face_faiss_id=faiss_id)
    return person_id, None, 0.0
```

- [ ] **Step 4: Register /identity/face in main.py**

Add to `create_app()` after the /health route:

```python
    from fastapi import HTTPException
    from models import FaceRequest, IdentityResponse

    @app.post("/identity/face", response_model=IdentityResponse)
    async def identity_face(req: FaceRequest):
        import base64
        from identity import identify_face
        try:
            jpeg_bytes = base64.b64decode(req.jpeg_b64)
            person_id, name, confidence = identify_face(jpeg_bytes)
            return IdentityResponse(
                matched=confidence >= 0.6,
                person_id=person_id,
                name=name,
                confidence=confidence,
            )
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))
```

- [ ] **Step 5: Run to verify pass**

```bash
pytest tests/test_face.py -v
```
Expected: all 3 tests PASSED

- [ ] **Step 6: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git add memory_sidecar/identity.py memory_sidecar/main.py memory_sidecar/tests/test_face.py
git commit -m "feat: face identity endpoint — InsightFace ArcFace + FAISS cosine search"
```

---

## Task 4: Voice recognition endpoint

**Files:**
- Modify: `memory_sidecar/identity.py` (add voice section)
- Modify: `memory_sidecar/main.py` (register /identity/voice route)
- Create: `memory_sidecar/tests/test_voice.py`

- [ ] **Step 1: Write the failing tests**

```python
# memory_sidecar/tests/test_voice.py
import pytest
import base64
import numpy as np
from unittest.mock import patch, MagicMock
from httpx import AsyncClient, ASGITransport

# 3 seconds of silence as PCM Int16 LE 16kHz mono
SILENT_3S_PCM_B64 = base64.b64encode(bytes(16000 * 3 * 2)).decode()

@pytest.fixture
def app_with_mock_voice(tmp_path):
    import os
    os.environ["BANTI_DB_PATH"] = str(tmp_path / "test.db")
    from db import init_db
    init_db(str(tmp_path / "test.db"))

    with patch("identity.VOICE_MODEL") as mock_voice_model:
        mock_voice_model.return_value = np.random.rand(256).astype(np.float32)
        from main import create_app
        yield create_app(testing=False), tmp_path

@pytest.mark.asyncio
async def test_voice_unknown_speaker_returns_new_person_id(app_with_mock_voice):
    app, _ = app_with_mock_voice
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/identity/voice", json={
            "pcm_b64": SILENT_3S_PCM_B64,
            "deepgram_speaker_id": 0,
            "session_id": "voice-session-1"
        })
    assert response.status_code == 200
    data = response.json()
    assert data["matched"] == False
    assert data["person_id"].startswith("p_")

@pytest.mark.asyncio
async def test_voice_same_speaker_matches_on_second_call(app_with_mock_voice):
    app, _ = app_with_mock_voice
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r1 = await client.post("/identity/voice", json={
            "pcm_b64": SILENT_3S_PCM_B64,
            "deepgram_speaker_id": 1,
            "session_id": "voice-session-2"
        })
        r2 = await client.post("/identity/voice", json={
            "pcm_b64": SILENT_3S_PCM_B64,
            "deepgram_speaker_id": 1,
            "session_id": "voice-session-2"
        })
    assert r1.json()["person_id"] == r2.json()["person_id"]
    assert r2.json()["matched"] == True

@pytest.mark.asyncio
async def test_voice_without_hf_token_returns_503(tmp_path):
    import os
    os.environ["BANTI_DB_PATH"] = str(tmp_path / "test.db")
    from db import init_db
    init_db(str(tmp_path / "test.db"))

    with patch("identity.VOICE_MODEL", None):
        from main import create_app
        app = create_app(testing=False)
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post("/identity/voice", json={
                "pcm_b64": SILENT_3S_PCM_B64,
                "deepgram_speaker_id": 0,
                "session_id": "voice-session-3"
            })
    assert response.status_code == 503
    assert "voice identity disabled" in response.json()["detail"].lower()
```

- [ ] **Step 2: Run to verify failure**

```bash
pytest tests/test_voice.py -v
```
Expected: `ImportError` or attribute error (identify_voice not defined)

- [ ] **Step 3: Add voice functions to identity.py**

Append to `identity.py`:

```python
def identify_voice(pcm_bytes: bytes) -> tuple[str, Optional[str], float]:
    """Returns (person_id, name_or_None, confidence). Enrolls on first sight."""
    import faiss
    import torch
    from db import create_person, get_person_by_id, update_person_embeddings

    if VOICE_MODEL is None:
        raise RuntimeError("Voice model not initialized (HF_TOKEN missing)")

    # Convert raw PCM Int16 LE to float32 [-1, 1]
    pcm_int16 = np.frombuffer(pcm_bytes, dtype=np.int16)
    pcm_float = pcm_int16.astype(np.float32) / 32768.0

    # pyannote expects (channels, samples)
    waveform = torch.from_numpy(pcm_float).unsqueeze(0)  # (1, samples)
    raw_emb = VOICE_MODEL({"waveform": waveform, "sample_rate": 16000})
    emb = _normalize(np.array(raw_emb, dtype=np.float32))
    emb_row = emb.reshape(1, -1).copy()

    # Search FAISS
    if VOICE_INDEX.ntotal > 0:
        faiss.normalize_L2(emb_row)
        distances, indices = VOICE_INDEX.search(emb_row, 1)
        best_score = float(distances[0][0])
        best_idx = int(indices[0][0])

        if best_score >= VOICE_THRESHOLD and best_idx < len(_voice_person_ids):
            person_id = _voice_person_ids[best_idx]
            person = get_person_by_id(DB_PATH, person_id)
            name = person["display_name"] if person else None
            return person_id, name, best_score

    # New speaker — enroll
    emb_blob = emb.tobytes()
    person_id = create_person(DB_PATH, display_name=None,
                               face_embedding=None, voice_embedding=emb_blob)

    faiss_id = VOICE_INDEX.ntotal
    faiss_emb = emb.reshape(1, -1).copy()
    faiss.normalize_L2(faiss_emb)
    VOICE_INDEX.add(faiss_emb)
    _voice_person_ids.append(person_id)

    update_person_embeddings(DB_PATH, person_id,
                              voice_embedding=emb_blob,
                              voice_faiss_id=faiss_id)
    return person_id, None, 0.0
```

- [ ] **Step 4: Register /identity/voice in main.py**

Add after /identity/face route:

```python
    from models import VoiceRequest
    from fastapi import HTTPException

    @app.post("/identity/voice", response_model=IdentityResponse)
    async def identity_voice(req: VoiceRequest):
        import base64
        from identity import identify_voice, VOICE_MODEL
        if VOICE_MODEL is None:
            raise HTTPException(status_code=503, detail="Voice identity disabled — HF_TOKEN missing")
        try:
            pcm_bytes = base64.b64decode(req.pcm_b64)
            person_id, name, confidence = identify_voice(pcm_bytes)
            return IdentityResponse(
                matched=confidence >= 0.75,
                person_id=person_id,
                name=name,
                confidence=confidence,
            )
        except ValueError as e:
            raise HTTPException(status_code=400, detail=str(e))
```

- [ ] **Step 5: Run to verify pass**

```bash
pytest tests/test_voice.py -v
```
Expected: all 3 tests PASSED

- [ ] **Step 6: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git add memory_sidecar/identity.py memory_sidecar/main.py memory_sidecar/tests/test_voice.py
git commit -m "feat: voice identity endpoint — pyannote + FAISS, graceful 503 when HF_TOKEN absent"
```

---

## Task 5: Memory ingestion — Graphiti

**Files:**
- Create: `memory_sidecar/memory.py`
- Modify: `memory_sidecar/main.py` (register /memory/ingest)
- Create: `memory_sidecar/tests/test_memory.py` (ingest section)

- [ ] **Step 1: Write the failing tests**

```python
# memory_sidecar/tests/test_memory.py
import pytest
import json
from unittest.mock import patch, AsyncMock, MagicMock
from httpx import AsyncClient, ASGITransport

SAMPLE_SNAPSHOT = json.dumps({
    "speech": {"transcript": "Hello world", "resolvedName": "Alice",
                "isFinal": True, "confidence": 0.95,
                "updatedAt": "2026-03-19T10:00:00Z"},
    "activity": {"description": "typing", "updatedAt": "2026-03-19T10:00:00Z"}
})

EMPTY_SNAPSHOT = "{}"

@pytest.fixture
def app_with_mock_memory():
    with patch("memory.GRAPHITI") as mock_graphiti, \
         patch("memory.MEM0") as mock_mem0:
        mock_graphiti.add_episode = AsyncMock()
        mock_mem0.add = MagicMock()
        from main import create_app
        yield create_app(testing=False), mock_graphiti, mock_mem0

@pytest.mark.asyncio
async def test_ingest_calls_graphiti_add_episode(app_with_mock_memory):
    app, mock_graphiti, _ = app_with_mock_memory
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/memory/ingest", json={
            "snapshot_json": SAMPLE_SNAPSHOT,
            "wall_ts": "2026-03-19T10:00:00Z"
        })
    assert response.status_code == 200
    mock_graphiti.add_episode.assert_called_once()

@pytest.mark.asyncio
async def test_ingest_skips_empty_snapshot(app_with_mock_memory):
    app, mock_graphiti, _ = app_with_mock_memory
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/memory/ingest", json={
            "snapshot_json": EMPTY_SNAPSHOT,
            "wall_ts": "2026-03-19T10:00:00Z"
        })
    assert response.status_code == 200
    assert response.json()["skipped"] == True
    mock_graphiti.add_episode.assert_not_called()

def test_snapshot_to_episode_extracts_speech():
    from memory import snapshot_to_episode
    from datetime import datetime
    snap = {"speech": {"transcript": "Hello Alice", "resolvedName": "Bob"}}
    episode = snapshot_to_episode(snap, datetime.now())
    assert "Bob" in episode
    assert "Hello Alice" in episode

def test_snapshot_to_episode_returns_none_for_empty():
    from memory import snapshot_to_episode
    from datetime import datetime
    episode = snapshot_to_episode({}, datetime.now())
    assert episode is None

def test_snapshot_to_episode_handles_missing_resolved_name():
    from memory import snapshot_to_episode
    from datetime import datetime
    snap = {"speech": {"transcript": "Something was said"}}
    episode = snapshot_to_episode(snap, datetime.now())
    assert "unknown speaker" in episode
```

- [ ] **Step 2: Run to verify failure**

```bash
pytest tests/test_memory.py::test_snapshot_to_episode_extracts_speech \
       tests/test_memory.py::test_snapshot_to_episode_returns_none_for_empty \
       tests/test_memory.py::test_snapshot_to_episode_handles_missing_resolved_name -v
```
Expected: `ModuleNotFoundError: No module named 'memory'`

- [ ] **Step 3: Implement memory.py (Graphiti section)**

```python
# memory_sidecar/memory.py
import os
import uuid
from datetime import datetime
from typing import Optional
from collections import deque

GRAPHITI = None   # graphiti_core.Graphiti instance
MEM0 = None       # mem0.Memory instance

_episode_buffer: deque = deque(maxlen=100)  # Buffered on Graphiti disconnect
_last_snapshot_text: Optional[str] = None   # For duplicate detection

async def init_memory() -> None:
    global GRAPHITI, MEM0

    neo4j_uri  = os.environ.get("NEO4J_URI")
    neo4j_user = os.environ.get("NEO4J_USER", "neo4j")
    neo4j_pass = os.environ.get("NEO4J_PASSWORD")

    if neo4j_uri and neo4j_pass:
        try:
            from graphiti_core import Graphiti
            GRAPHITI = Graphiti(neo4j_uri, neo4j_user, neo4j_pass)
            await GRAPHITI.build_indices_and_constraints()
        except Exception as e:
            print(f"[warn] Graphiti init failed: {e} — temporal memory disabled")
            GRAPHITI = None
    else:
        print("[warn] NEO4J_URI/NEO4J_PASSWORD missing — temporal memory disabled")

    openai_key = os.environ.get("OPENAI_API_KEY")
    if openai_key:
        try:
            from mem0 import Memory
            MEM0 = Memory()
        except Exception as e:
            print(f"[warn] mem0 init failed: {e} — semantic memory disabled")
            MEM0 = None
    else:
        print("[warn] OPENAI_API_KEY missing — semantic memory disabled")


def snapshot_to_episode(snapshot: dict, wall_ts: datetime) -> Optional[str]:
    """Transform raw snapshotJSON dict into human-readable episode text."""
    parts = []

    if sp := snapshot.get("speech"):
        name = sp.get("resolvedName") or "unknown speaker"
        transcript = sp.get("transcript", "")
        if transcript.strip():
            parts.append(f'{name} said: "{transcript}"')

    if p := snapshot.get("person"):
        name = p.get("name") or "an unknown person"
        parts.append(f"{name} was visible on camera")

    if a := snapshot.get("activity"):
        desc = a.get("description", "")
        if desc:
            parts.append(f"Activity: {desc}")

    if sc := snapshot.get("screen"):
        interp = sc.get("interpretation", "")
        if interp:
            parts.append(f"Screen: {interp}")

    if em := snapshot.get("voiceEmotion"):
        emotions = em.get("emotions", [])
        if emotions:
            top = sorted(emotions, key=lambda e: e.get("score", 0), reverse=True)[:2]
            labels = ", ".join(e["label"] for e in top)
            parts.append(f"Vocal emotion: {labels}")

    return ". ".join(parts) if parts else None


async def ingest_snapshot(snapshot_json: str, wall_ts: datetime) -> dict:
    """Parse snapshot, transform to episode text, send to Graphiti + mem0."""
    import json
    global _last_snapshot_text

    if snapshot_json == "{}" or not snapshot_json.strip():
        return {"skipped": True, "reason": "empty"}

    try:
        snapshot = json.loads(snapshot_json)
    except json.JSONDecodeError:
        return {"skipped": True, "reason": "invalid json"}

    episode_text = snapshot_to_episode(snapshot, wall_ts)
    if not episode_text:
        return {"skipped": True, "reason": "no meaningful content"}

    if episode_text == _last_snapshot_text:
        return {"skipped": True, "reason": "duplicate"}

    _last_snapshot_text = episode_text

    # Send to Graphiti
    if GRAPHITI is not None:
        try:
            await GRAPHITI.add_episode(
                name=f"snapshot_{uuid.uuid4().hex[:8]}",
                episode_body=episode_text,
                source_description="banti ambient perception",
                reference_time=wall_ts,
            )
        except Exception as e:
            print(f"[warn] Graphiti ingest failed: {e} — buffering")
            _episode_buffer.append((episode_text, wall_ts))

    # Send to mem0 (best-effort)
    if MEM0 is not None:
        try:
            MEM0.add(episode_text, user_id="banti_self")
        except Exception as e:
            print(f"[warn] mem0 ingest failed: {e}")

    return {"skipped": False, "episode": episode_text}
```

- [ ] **Step 4: Register /memory/ingest in main.py**

Add after identity routes:

```python
    from models import IngestRequest
    import json as _json

    @app.post("/memory/ingest")
    async def memory_ingest(req: IngestRequest):
        from memory import ingest_snapshot
        from datetime import datetime
        wall_ts = datetime.fromisoformat(req.wall_ts.replace("Z", "+00:00"))
        result = await ingest_snapshot(req.snapshot_json, wall_ts)
        return result
```

- [ ] **Step 5: Run to verify pass**

```bash
pytest tests/test_memory.py -k "ingest or episode" -v
```
Expected: all 5 tests PASSED

- [ ] **Step 6: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git add memory_sidecar/memory.py memory_sidecar/main.py memory_sidecar/tests/test_memory.py
git commit -m "feat: memory ingest endpoint — Graphiti temporal graph + snapshot_to_episode transform"
```

---

## Task 6: mem0 semantic query endpoint

**Files:**
- Modify: `memory_sidecar/main.py` (register /memory/query)
- Modify: `memory_sidecar/tests/test_memory.py` (add query tests)

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_memory.py`:

```python
@pytest.mark.asyncio
async def test_query_returns_answer(app_with_mock_memory):
    app, _, mock_mem0 = app_with_mock_memory
    mock_mem0.search.return_value = [
        {"memory": "Alice is a software engineer", "score": 0.95}
    ]
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/memory/query", json={"q": "who is Alice?"})
    assert response.status_code == 200
    data = response.json()
    assert "answer" in data

@pytest.mark.asyncio
async def test_query_returns_empty_answer_when_mem0_disabled(tmp_path):
    with patch("memory.MEM0", None), patch("memory.GRAPHITI", None):
        from main import create_app
        app = create_app(testing=False)
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post("/memory/query", json={"q": "anything"})
    assert response.status_code == 200
    assert response.json()["answer"] == ""
```

- [ ] **Step 2: Run to verify failure**

```bash
pytest tests/test_memory.py -k "query" -v
```
Expected: `404 Not Found` (route not registered)

- [ ] **Step 3: Add query_memory to memory.py**

Append to `memory.py`:

```python
async def query_memory(q: str, context_json: Optional[str] = None) -> dict:
    """Fan out to Graphiti + mem0, fuse with GPT-4o."""
    import json
    results = []

    if MEM0 is not None:
        try:
            hits = MEM0.search(q, user_id="banti_self", limit=5)
            results.extend(h["memory"] for h in hits if "memory" in h)
        except Exception as e:
            print(f"[warn] mem0 search failed: {e}")

    if not results:
        return {"answer": "", "sources": []}

    # Fuse with GPT-4o
    openai_key = os.environ.get("OPENAI_API_KEY")
    if not openai_key:
        return {"answer": ". ".join(results[:3]), "sources": results}

    try:
        from openai import AsyncOpenAI
        client = AsyncOpenAI(api_key=openai_key)
        facts = "\n".join(f"- {r}" for r in results)
        messages = [
            {"role": "system", "content": "You are banti's memory. Answer the user's question using only the provided facts. Be concise."},
            {"role": "user", "content": f"Facts:\n{facts}\n\nQuestion: {q}"}
        ]
        if context_json:
            messages[0]["content"] += f" Current context: {context_json}"
        resp = await client.chat.completions.create(
            model="gpt-4o", messages=messages, max_tokens=200
        )
        answer = resp.choices[0].message.content or ""
    except Exception as e:
        print(f"[warn] GPT-4o query fusion failed: {e}")
        answer = ". ".join(results[:3])

    return {"answer": answer, "sources": results}
```

- [ ] **Step 4: Register /memory/query in main.py**

```python
    from models import QueryRequest, QueryResponse

    @app.post("/memory/query", response_model=QueryResponse)
    async def memory_query(req: QueryRequest):
        from memory import query_memory
        result = await query_memory(req.q, req.context_json)
        return QueryResponse(answer=result["answer"], sources=result.get("sources", []))
```

- [ ] **Step 5: Run to verify pass**

```bash
pytest tests/test_memory.py -k "query" -v
```
Expected: both query tests PASSED

- [ ] **Step 6: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git add memory_sidecar/memory.py memory_sidecar/main.py memory_sidecar/tests/test_memory.py
git commit -m "feat: memory query endpoint — mem0 semantic search + GPT-4o fusion"
```

---

## Task 7: Self-reflection endpoint

**Files:**
- Modify: `memory_sidecar/memory.py` (add reflect_memory)
- Modify: `memory_sidecar/main.py` (register /memory/reflect)
- Modify: `memory_sidecar/tests/test_memory.py` (add reflect tests)

- [ ] **Step 1: Write the failing test**

Add to `tests/test_memory.py`:

```python
@pytest.mark.asyncio
async def test_reflect_returns_summary(app_with_mock_memory):
    app, _, _ = app_with_mock_memory
    snapshots = [SAMPLE_SNAPSHOT, SAMPLE_SNAPSHOT]
    with patch("memory.reflect_memory", new_callable=AsyncMock) as mock_reflect:
        mock_reflect.return_value = {"summary": "User was coding"}
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post("/memory/reflect", json={"snapshots": snapshots})
    assert response.status_code == 200
    assert "summary" in response.json()
```

- [ ] **Step 2: Run to verify failure**

```bash
pytest tests/test_memory.py -k "reflect" -v
```
Expected: `404 Not Found`

- [ ] **Step 3: Add reflect_memory to memory.py**

Append to `memory.py`:

```python
async def reflect_memory(snapshots: list[str]) -> dict:
    """GPT-4o reflection over recent snapshots → Graphiti + mem0 + self.json."""
    import json
    import re

    if not snapshots:
        return {"summary": ""}

    openai_key = os.environ.get("OPENAI_API_KEY")
    if not openai_key:
        return {"summary": ""}

    # Build episode list from snapshots
    episodes = []
    now = datetime.utcnow()
    for snap in snapshots:
        try:
            ep = snapshot_to_episode(json.loads(snap), now)
            if ep:
                episodes.append(ep)
        except Exception:
            continue

    if not episodes:
        return {"summary": "No meaningful episodes"}

    context = "\n".join(f"- {ep}" for ep in episodes[-50:])  # last 50 episodes
    prompt = f"""You are banti's self-model. Analyze recent observations and respond with JSON:
{{
  "observations": ["time-anchored facts"],
  "patterns": ["recurring signals"],
  "relationships": [{{"person": "Name", "facts": ["..."]}}],
  "summary": "one sentence"
}}

Recent observations:
{context}"""

    try:
        from openai import AsyncOpenAI
        client = AsyncOpenAI(api_key=openai_key)
        resp = await client.chat.completions.create(
            model="gpt-4o",
            messages=[{"role": "user", "content": prompt}],
            max_tokens=500,
            response_format={"type": "json_object"},
        )
        result = json.loads(resp.choices[0].message.content or "{}")
    except Exception as e:
        print(f"[warn] GPT-4o reflection failed: {e}")
        return {"summary": "reflection failed"}

    # Write to self.json
    self_json_path = os.path.expanduser(
        "~/Library/Application Support/banti/self.json"
    )
    os.makedirs(os.path.dirname(self_json_path), exist_ok=True)
    existing = {}
    if os.path.exists(self_json_path):
        try:
            with open(self_json_path) as f:
                existing = json.load(f)
        except Exception:
            pass

    existing["last_reflection"] = now.isoformat() + "Z"
    if "patterns" in result:
        existing["recent_patterns"] = result["patterns"]
    if "observations" in result:
        existing["recent_observations"] = result["observations"]

    with open(self_json_path, "w") as f:
        json.dump(existing, f, indent=2)

    # Persist patterns to mem0
    if MEM0 is not None:
        for pattern in result.get("patterns", []):
            try:
                MEM0.add(pattern, user_id="banti_self")
            except Exception:
                pass

    return {"summary": result.get("summary", "reflection complete")}
```

- [ ] **Step 4: Register /memory/reflect in main.py**

```python
    from models import ReflectRequest, ReflectResponse

    @app.post("/memory/reflect", response_model=ReflectResponse)
    async def memory_reflect(req: ReflectRequest):
        from memory import reflect_memory
        result = await reflect_memory(req.snapshots)
        return ReflectResponse(summary=result.get("summary", ""))
```

- [ ] **Step 5: Run all memory tests**

```bash
pytest tests/test_memory.py -v
```
Expected: all memory tests PASSED

- [ ] **Step 6: Run full test suite**

```bash
pytest -v
```
Expected: all tests PASSED

- [ ] **Step 7: Commit**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
git add memory_sidecar/memory.py memory_sidecar/main.py memory_sidecar/tests/test_memory.py
git commit -m "feat: memory reflect endpoint — GPT-4o self-reflection, self.json update"
```

---

## Task 8: Swift foundations — SpeechState.resolvedName + MemoryTypes.swift

**Files:**
- Modify: `Sources/BantiCore/AudioTypes.swift`
- Create: `Sources/BantiCore/MemoryTypes.swift`
- Create: `Tests/BantiTests/MemoryTypesTests.swift`

> **Important:** This task must be done before Tasks 9–17. PersonState (defined here) is referenced by PerceptionTypes.swift and PerceptionContext.swift in the next task.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BantiTests/MemoryTypesTests.swift
import XCTest
@testable import BantiCore

final class MemoryTypesTests: XCTestCase {

    func testSpeechStateAcceptsResolvedName() {
        let state = SpeechState(
            transcript: "hello",
            speakerID: 0,
            isFinal: true,
            confidence: 0.9,
            resolvedName: "Alice",
            updatedAt: Date()
        )
        XCTAssertEqual(state.resolvedName, "Alice")
    }

    func testSpeechStateResolvedNameDefaultsToNil() {
        let state = SpeechState(
            transcript: "hello",
            speakerID: nil,
            isFinal: false,
            confidence: 0.5,
            resolvedName: nil,
            updatedAt: Date()
        )
        XCTAssertNil(state.resolvedName)
    }

    func testPersonStateIsCreatable() {
        let state = PersonState(id: "p_001", name: "Bob", confidence: 0.92, updatedAt: Date())
        XCTAssertEqual(state.id, "p_001")
        XCTAssertEqual(state.name, "Bob")
        XCTAssertEqual(state.confidence, 0.92, accuracy: 0.001)
    }

    func testPersonStateUnknownHasNilName() {
        let state = PersonState(id: "p_099", name: nil, confidence: 0.0, updatedAt: Date())
        XCTAssertNil(state.name)
    }

    func testMemoryActionIntroduceYourself() {
        let action = MemoryAction.introduceYourself(personID: "p_042")
        if case .introduceYourself(let id) = action {
            XCTAssertEqual(id, "p_042")
        } else {
            XCTFail("Wrong case")
        }
    }

    func testMemoryResponseHasAnswer() {
        let response = MemoryResponse(answer: "Alice is a designer", sources: ["mem0"])
        XCTAssertEqual(response.answer, "Alice is a designer")
        XCTAssertEqual(response.sources, ["mem0"])
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
swift test --filter MemoryTypesTests 2>&1 | tail -20
```
Expected: compiler error — `SpeechState` has no `resolvedName` parameter, `PersonState` does not exist

- [ ] **Step 3: Update SpeechState in AudioTypes.swift**

In [Sources/BantiCore/AudioTypes.swift](Sources/BantiCore/AudioTypes.swift), replace the `SpeechState` struct:

```swift
public struct SpeechState: Codable {
    public let transcript: String
    public let speakerID: Int?
    public let isFinal: Bool
    public let confidence: Float
    public let resolvedName: String?
    public let updatedAt: Date

    public init(transcript: String, speakerID: Int?, isFinal: Bool, confidence: Float,
                resolvedName: String? = nil, updatedAt: Date) {
        self.transcript = transcript
        self.speakerID = speakerID
        self.isFinal = isFinal
        self.confidence = confidence
        self.resolvedName = resolvedName
        self.updatedAt = updatedAt
    }
}
```

Also update `DeepgramStreamer.parseResponse` (line 193 in [Sources/BantiCore/DeepgramStreamer.swift](Sources/BantiCore/DeepgramStreamer.swift)) to pass `resolvedName: nil`:

```swift
        return SpeechState(
            transcript: transcript,
            speakerID: speakerID,
            isFinal: true,
            confidence: confidence,
            resolvedName: nil,
            updatedAt: Date()
        )
```

- [ ] **Step 4: Create MemoryTypes.swift**

```swift
// Sources/BantiCore/MemoryTypes.swift
import Foundation

// MARK: - PersonState (live camera annotation — added to PerceptionContext in Task 9)

public struct PersonState: Codable {
    public let id: String         // "p_0042" — stable SQLite rowid-based ID
    public let name: String?      // nil if unknown
    public let confidence: Float
    public let updatedAt: Date

    public init(id: String, name: String?, confidence: Float, updatedAt: Date) {
        self.id = id
        self.name = name
        self.confidence = confidence
        self.updatedAt = updatedAt
    }
}

// MARK: - PersonRecord (Swift-side mirror of SQLite person row)

public struct PersonRecord {
    public let id: String
    public let displayName: String?
    public let mem0UserID: String
    public let firstSeen: Date
    public let lastSeen: Date

    public init(id: String, displayName: String?, mem0UserID: String,
                firstSeen: Date, lastSeen: Date) {
        self.id = id
        self.displayName = displayName
        self.mem0UserID = mem0UserID
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

// MARK: - MemoryAction (output from ProactiveIntroducer; speech layer will consume in future)

public enum MemoryAction {
    case introduceYourself(personID: String)
    case correction(wrongName: String, correctName: String)
}

// MARK: - MemoryResponse (return type of MemoryQuery.query)

public struct MemoryResponse {
    public let answer: String
    public let sources: [String]

    public init(answer: String, sources: [String] = []) {
        self.answer = answer
        self.sources = sources
    }
}
```

- [ ] **Step 5: Run to verify pass**

```bash
swift test --filter MemoryTypesTests 2>&1 | tail -20
```
Expected: all 6 tests PASSED

- [ ] **Step 6: Verify existing tests still pass**

```bash
swift test 2>&1 | tail -20
```
Expected: all existing tests pass (no regressions from SpeechState change)

- [ ] **Step 7: Commit**

```bash
git add Sources/BantiCore/AudioTypes.swift \
        Sources/BantiCore/DeepgramStreamer.swift \
        Sources/BantiCore/MemoryTypes.swift \
        Tests/BantiTests/MemoryTypesTests.swift
git commit -m "feat: add SpeechState.resolvedName + MemoryTypes (PersonState, MemoryAction, MemoryResponse)"
```

---

## Task 9: PerceptionContext/Types + IdentityStore

**Files:**
- Modify: `Sources/BantiCore/PerceptionTypes.swift`
- Modify: `Sources/BantiCore/PerceptionContext.swift`
- Create: `Sources/BantiCore/IdentityStore.swift`
- Create: `Tests/BantiTests/PersonStateTests.swift`
- Create: `Tests/BantiTests/IdentityStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BantiTests/PersonStateTests.swift
import XCTest
@testable import BantiCore

final class PersonStateTests: XCTestCase {

    func testUpdateSetsPersonField() async {
        let ctx = PerceptionContext()
        let state = PersonState(id: "p_001", name: "Alice", confidence: 0.95, updatedAt: Date())
        await ctx.update(.person(state))
        let person = await ctx.person
        XCTAssertEqual(person?.id, "p_001")
        XCTAssertEqual(person?.name, "Alice")
    }

    func testPersonFieldIsNilInitially() async {
        let ctx = PerceptionContext()
        let person = await ctx.person
        XCTAssertNil(person)
    }

    func testSnapshotIncludesPersonWhenSet() async {
        let ctx = PerceptionContext()
        let state = PersonState(id: "p_007", name: "Bob", confidence: 0.88, updatedAt: Date())
        await ctx.update(.person(state))
        let json = await ctx.snapshotJSON()
        XCTAssertTrue(json.contains("Bob"))
        XCTAssertTrue(json.contains("p_007"))
    }

    func testSnapshotExcludesPersonWhenNil() async {
        let ctx = PerceptionContext()
        let json = await ctx.snapshotJSON()
        XCTAssertFalse(json.contains("\"person\""))
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter PersonStateTests 2>&1 | tail -20
```
Expected: compiler error — `.person` case does not exist in `PerceptionObservation`

- [ ] **Step 3: Add `case person(PersonState)` to PerceptionTypes.swift**

In [Sources/BantiCore/PerceptionTypes.swift:95-105](Sources/BantiCore/PerceptionTypes.swift#L95-L105), add the case:

```swift
public enum PerceptionObservation {
    case face(FaceState)
    case pose(PoseState)
    case emotion(EmotionState)
    case activity(ActivityState)
    case gesture(GestureState)
    case screen(ScreenState)
    case speech(SpeechState)
    case voiceEmotion(VoiceEmotionState)
    case sound(SoundState)
    case person(PersonState)
}
```

- [ ] **Step 4: Update PerceptionContext.swift**

Add `var person: PersonState?` property and update `update()` and `snapshotJSON()`:

```swift
    public var person: PersonState?
```

In the `update()` switch, add:
```swift
        case .person(let s):   person = s
```

In `snapshotJSON()`, add:
```swift
        if let pe = person  { dict["person"]   = encodable(pe) }
```

- [ ] **Step 5: Run to verify pass**

```bash
swift test --filter PersonStateTests 2>&1 | tail -20
```
Expected: all 4 tests PASSED

- [ ] **Step 6: Run full suite**

```bash
swift test 2>&1 | tail -20
```
Expected: all tests PASSED

- [ ] **Step 5b: Write failing tests for IdentityStore**

```swift
// Tests/BantiTests/IdentityStoreTests.swift
import XCTest
@testable import BantiCore

final class IdentityStoreTests: XCTestCase {

    func testStoreStartsEmpty() async {
        let store = IdentityStore()
        let name = await store.name(forPersonID: "p_001")
        XCTAssertNil(name)
    }

    func testSetNameCanBeRetrieved() async {
        let store = IdentityStore()
        await store.setName("Alice", forPersonID: "p_001")
        let name = await store.name(forPersonID: "p_001")
        XCTAssertEqual(name, "Alice")
    }

    func testSetNameOverwritesPrevious() async {
        let store = IdentityStore()
        await store.setName("Alice", forPersonID: "p_001")
        await store.setName("Alicia", forPersonID: "p_001")
        let name = await store.name(forPersonID: "p_001")
        XCTAssertEqual(name, "Alicia")
    }

    func testClearRemovesAllEntries() async {
        let store = IdentityStore()
        await store.setName("Bob", forPersonID: "p_002")
        await store.clear()
        let name = await store.name(forPersonID: "p_002")
        XCTAssertNil(name)
    }
}
```

- [ ] **Step 5c: Run IdentityStore tests to verify failure**

```bash
swift test --filter IdentityStoreTests 2>&1 | tail -20
```
Expected: compiler error — `IdentityStore` not defined

- [ ] **Step 5d: Implement IdentityStore.swift**

```swift
// Sources/BantiCore/IdentityStore.swift
import Foundation

/// In-memory session cache for person_id → display_name mappings.
/// Populated by FaceIdentifier and SpeakerResolver responses during a session.
/// Cleared on restart (persistence is handled by the Python sidecar's SQLite).
public actor IdentityStore {
    private var cache: [String: String] = [:]  // person_id → name

    public init() {}

    public func name(forPersonID personID: String) -> String? {
        cache[personID]
    }

    public func setName(_ name: String, forPersonID personID: String) {
        cache[personID] = name
    }

    public func clear() {
        cache.removeAll()
    }
}
```

- [ ] **Step 5e: Run IdentityStore tests to verify pass**

```bash
swift test --filter IdentityStoreTests 2>&1 | tail -20
```
Expected: all 4 tests PASSED

- [ ] **Step 6: Run full suite**

```bash
swift test 2>&1 | tail -20
```
Expected: all tests PASSED

- [ ] **Step 7: Commit**

```bash
git add Sources/BantiCore/PerceptionTypes.swift \
        Sources/BantiCore/PerceptionContext.swift \
        Sources/BantiCore/IdentityStore.swift \
        Tests/BantiTests/PersonStateTests.swift \
        Tests/BantiTests/IdentityStoreTests.swift
git commit -m "feat: PersonState in PerceptionContext/Types + IdentityStore session cache"
```

---

## Task 10: AudioRouter PCM ring buffer

**Files:**
- Modify: `Sources/BantiCore/AudioRouter.swift`
- Create: `Tests/BantiTests/AudioRouterPCMTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BantiTests/AudioRouterPCMTests.swift
import XCTest
@testable import BantiCore

final class AudioRouterPCMTests: XCTestCase {

    func testPCMRingBufferMaxBytesIs160000() {
        XCTAssertEqual(AudioRouter.pcmRingBufferMaxBytes, 160_000)
    }

    func testRingBufferStartsEmpty() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let data = await router.readPCMRingBuffer()
        XCTAssertTrue(data.isEmpty)
    }

    func testAppendAccumulatesData() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let chunk = Data(repeating: 1, count: 1_000)
        await router.appendToPCMRingBuffer(chunk)
        await router.appendToPCMRingBuffer(chunk)
        let data = await router.readPCMRingBuffer()
        XCTAssertEqual(data.count, 2_000)
    }

    func testBufferTrimsToMaxWhenOverflowed() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        // Write 170,000 bytes — 10,000 more than max
        let chunk = Data(repeating: 0, count: 170_000)
        await router.appendToPCMRingBuffer(chunk)
        let data = await router.readPCMRingBuffer()
        XCTAssertEqual(data.count, AudioRouter.pcmRingBufferMaxBytes)
    }

    func testReadIsNonDestructive() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let chunk = Data(repeating: 2, count: 5_000)
        await router.appendToPCMRingBuffer(chunk)
        let read1 = await router.readPCMRingBuffer()
        let read2 = await router.readPCMRingBuffer()
        XCTAssertEqual(read1, read2)
        XCTAssertEqual(read2.count, 5_000)
    }

    func testDispatchCallsAppendToPCMBuffer() async {
        let router = AudioRouter(context: PerceptionContext(), logger: Logger())
        let chunk = Data(repeating: 0, count: 32_000)
        await router.dispatch(pcmChunk: chunk)
        let data = await router.readPCMRingBuffer()
        XCTAssertEqual(data.count, 32_000)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter AudioRouterPCMTests 2>&1 | tail -20
```
Expected: compiler error — `appendToPCMRingBuffer` / `readPCMRingBuffer` not defined

- [ ] **Step 3: Update AudioRouter.swift**

Add ring buffer properties and methods to [Sources/BantiCore/AudioRouter.swift](Sources/BantiCore/AudioRouter.swift):

```swift
    private var pcmRingBuffer: Data = Data()
    static let pcmRingBufferMaxBytes = 160_000   // 5s at 16kHz mono Int16

    public func appendToPCMRingBuffer(_ chunk: Data) {
        pcmRingBuffer.append(chunk)
        if pcmRingBuffer.count > AudioRouter.pcmRingBufferMaxBytes {
            let excess = pcmRingBuffer.count - AudioRouter.pcmRingBufferMaxBytes
            pcmRingBuffer.removeFirst(excess)
        }
    }

    public func readPCMRingBuffer() -> Data {
        return pcmRingBuffer
    }
```

In `dispatch(pcmChunk:)`, add `appendToPCMRingBuffer(pcmChunk)` as the first line after the Deepgram send:

```swift
    public func dispatch(pcmChunk: Data) async {
        if let streamer = deepgram {
            await streamer.send(chunk: pcmChunk)
        }
        appendToPCMRingBuffer(pcmChunk)   // <-- add this line

        humeBuffer.append(pcmChunk)
        // ... rest unchanged
```

- [ ] **Step 4: Run to verify pass**

```bash
swift test --filter AudioRouterPCMTests 2>&1 | tail -20
```
Expected: all 5 tests PASSED

- [ ] **Step 5: Run full suite**

```bash
swift test 2>&1 | tail -20
```
Expected: all tests PASSED

- [ ] **Step 6: Commit**

```bash
git add Sources/BantiCore/AudioRouter.swift \
        Tests/BantiTests/AudioRouterPCMTests.swift
git commit -m "feat: AudioRouter PCM ring buffer — 5s rolling window, non-destructive read"
```

---

## Task 11: MemorySidecar.swift

**Files:**
- Create: `Sources/BantiCore/MemorySidecar.swift`
- Create: `Tests/BantiTests/MemorySidecarTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BantiTests/MemorySidecarTests.swift
import XCTest
@testable import BantiCore

final class MemorySidecarTests: XCTestCase {

    func testSidecarDefaultPortIs7700() {
        XCTAssertEqual(MemorySidecar.defaultPort, 7700)
    }

    func testSidecarBaseURLIncludesPort() {
        let sidecar = MemorySidecar(logger: Logger(), port: 7700)
        XCTAssertEqual(sidecar.baseURL.absoluteString, "http://127.0.0.1:7700")
    }

    func testSidecarBaseURLRespectsCustomPort() {
        let sidecar = MemorySidecar(logger: Logger(), port: 9090)
        XCTAssertEqual(sidecar.baseURL.absoluteString, "http://127.0.0.1:9090")
    }

    func testSidecarIsRunningFalseInitially() async {
        let sidecar = MemorySidecar(logger: Logger())
        let running = await sidecar.isRunning
        XCTAssertFalse(running)
    }

    func testPostJSONReturnsNilWhenNotRunning() async throws {
        let sidecar = MemorySidecar(logger: Logger())
        let result = await sidecar.post(path: "/health", body: [String: String]())
        XCTAssertNil(result)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter MemorySidecarTests 2>&1 | tail -20
```
Expected: compiler error — `MemorySidecar` not defined

- [ ] **Step 3: Implement MemorySidecar.swift**

```swift
// Sources/BantiCore/MemorySidecar.swift
import Foundation

public actor MemorySidecar {
    public static let defaultPort = 7700

    public let baseURL: URL
    private let logger: Logger
    private var process: Process?
    public var isRunning: Bool = false

    public init(logger: Logger, port: Int = defaultPort) {
        self.logger = logger
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    // MARK: - Launch

    public func start() async {
        guard !isRunning else { return }

        let sidecarDir = resolveSidecarDir()
        let pythonPath = sidecarDir.appendingPathComponent(".venv/bin/python3").path
        let mainPath = sidecarDir.appendingPathComponent("main.py").path

        guard FileManager.default.fileExists(atPath: mainPath) else {
            logger.log(source: "memory", message: "[warn] sidecar not found at \(mainPath) — memory disabled")
            return
        }

        let python = FileManager.default.fileExists(atPath: pythonPath) ? pythonPath : "/usr/bin/python3"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [mainPath]
        proc.currentDirectoryURL = sidecarDir
        proc.environment = ProcessInfo.processInfo.environment

        do {
            try proc.run()
            process = proc
            logger.log(source: "memory", message: "sidecar launched (pid \(proc.processIdentifier))")
        } catch {
            logger.log(source: "memory", message: "[warn] sidecar launch failed: \(error.localizedDescription)")
            return
        }

        await waitForHealth()
    }

    public func stop() {
        process?.terminate()
        process = nil
        isRunning = false
    }

    // MARK: - HTTP helpers

    public func post<T: Encodable>(path: String, body: T) async -> Data? {
        guard isRunning else { return nil }
        guard let url = URL(string: path, relativeTo: baseURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5.0
        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Private helpers

    private func resolveSidecarDir() -> URL {
        // In app bundle: <Bundle>/Contents/Resources/memory_sidecar/
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("memory_sidecar")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        // In development (swift run): executable is .build/debug/banti
        // Walk up 3 levels to project root, then append memory_sidecar/
        if let execURL = Bundle.main.executableURL {
            let projectRoot = execURL
                .deletingLastPathComponent()  // debug/
                .deletingLastPathComponent()  // .build/
                .deletingLastPathComponent()  // project root
            return projectRoot.appendingPathComponent("memory_sidecar")
        }
        return URL(fileURLWithPath: "memory_sidecar")
    }

    private func waitForHealth(attempts: Int = 20) async {
        let healthURL = baseURL.appendingPathComponent("health")
        for _ in 0..<attempts {
            try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
            do {
                let (_, response) = try await URLSession.shared.data(from: healthURL)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    isRunning = true
                    logger.log(source: "memory", message: "sidecar ready at \(baseURL)")
                    return
                }
            } catch { /* still starting up */ }
        }
        logger.log(source: "memory", message: "[warn] sidecar did not respond in 10s — memory disabled")
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
swift test --filter MemorySidecarTests 2>&1 | tail -20
```
Expected: all 5 tests PASSED

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/MemorySidecar.swift \
        Tests/BantiTests/MemorySidecarTests.swift
git commit -m "feat: MemorySidecar — Process launch, health polling, post() HTTP helper"
```

---

## Task 12: FaceIdentifier.swift

**Files:**
- Create: `Sources/BantiCore/FaceIdentifier.swift`
- Create: `Tests/BantiTests/FaceIdentifierTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BantiTests/FaceIdentifierTests.swift
import XCTest
import Vision
@testable import BantiCore

final class FaceIdentifierTests: XCTestCase {

    func testDispatchSkipsWhenSidecarNotRunning() async {
        let context = PerceptionContext()
        let sidecar = MemorySidecar(logger: Logger())
        // isRunning is false by default
        let identifier = FaceIdentifier(context: context, sidecar: sidecar, logger: Logger(), sessionID: "test-session")
        // dispatch should return without writing anything to context
        let fakeJpeg = Data(repeating: 0, count: 100)
        let obs = VNFaceObservation(boundingBox: CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5))
        await identifier.dispatch(jpegData: fakeJpeg, faceObservation: obs)
        let person = await context.person
        XCTAssertNil(person)
    }

    func testSessionIDIsStored() {
        let identifier = FaceIdentifier(
            context: PerceptionContext(),
            sidecar: MemorySidecar(logger: Logger()),
            logger: Logger(),
            sessionID: "abc-123"
        )
        XCTAssertEqual(identifier.sessionID, "abc-123")
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter FaceIdentifierTests 2>&1 | tail -20
```
Expected: compiler error — `FaceIdentifier` not defined

- [ ] **Step 3: Implement FaceIdentifier.swift**

```swift
// Sources/BantiCore/FaceIdentifier.swift
import Foundation
import Vision

public actor FaceIdentifier {
    private let context: PerceptionContext
    private let sidecar: MemorySidecar
    private let logger: Logger
    public let sessionID: String

    public init(context: PerceptionContext, sidecar: MemorySidecar, logger: Logger, sessionID: String) {
        self.context = context
        self.sidecar = sidecar
        self.logger = logger
        self.sessionID = sessionID
    }

    // MARK: - Called by PerceptionRouter (throttled 5s per "faceIdentifier" key)

    public func dispatch(jpegData: Data, faceObservation: VNFaceObservation) async {
        guard await sidecar.isRunning else { return }

        let jpeg64 = jpegData.base64EncodedString()
        let body: [String: String] = [
            "jpeg_b64": jpeg64,
            "session_id": sessionID
        ]

        guard let responseData = await sidecar.post(path: "/identity/face", body: body) else { return }

        do {
            let decoded = try JSONDecoder().decode(IdentityAPIResponse.self, from: responseData)
            let state = PersonState(
                id: decoded.person_id,
                name: decoded.name,
                confidence: decoded.confidence,
                updatedAt: Date()
            )
            await context.update(.person(state))
            if let name = decoded.name {
                logger.log(source: "memory", message: "face recognized: \(name) (\(decoded.person_id))")
            } else {
                logger.log(source: "memory", message: "face unknown: \(decoded.person_id)")
            }
        } catch {
            logger.log(source: "memory", message: "[warn] face identity parse error: \(error.localizedDescription)")
        }
    }

    // MARK: - Decodable response shape

    private struct IdentityAPIResponse: Decodable {
        let matched: Bool
        let person_id: String
        let name: String?
        let confidence: Float
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
swift test --filter FaceIdentifierTests 2>&1 | tail -20
```
Expected: both tests PASSED

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/FaceIdentifier.swift \
        Tests/BantiTests/FaceIdentifierTests.swift
git commit -m "feat: FaceIdentifier — JPEG → /identity/face → PersonState in PerceptionContext"
```

---

## Task 13: PerceptionRouter FaceIdentifier integration

**Files:**
- Modify: `Sources/BantiCore/PerceptionRouter.swift`
- Modify: `Tests/BantiTests/PerceptionRouterTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/BantiTests/PerceptionRouterTests.swift`:

```swift
    func testSetFaceIdentifierIsStoredOnRouter() async {
        let router = PerceptionRouter(context: PerceptionContext(), logger: Logger())
        let sidecar = MemorySidecar(logger: Logger())
        let identifier = FaceIdentifier(
            context: PerceptionContext(),
            sidecar: sidecar,
            logger: Logger(),
            sessionID: "test"
        )
        await router.setFaceIdentifier(identifier)
        let has = await router.hasFaceIdentifier
        XCTAssertTrue(has)
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter PerceptionRouterTests 2>&1 | tail -20
```
Expected: compiler error — `setFaceIdentifier` not defined

- [ ] **Step 3: Update PerceptionRouter.swift**

Add `faceIdentifier` property, `setFaceIdentifier` method, `hasFaceIdentifier` accessor, and dispatch call in `dispatch()`:

```swift
    private var faceIdentifier: FaceIdentifier?

    public func setFaceIdentifier(_ identifier: FaceIdentifier) {
        faceIdentifier = identifier
    }

    var hasFaceIdentifier: Bool { faceIdentifier != nil }
```

In `dispatch(jpegData:source:events:)`, add face dispatch after face state is written (after the `await context.update(.face(state))` block, before cloud analyzer dispatches):

```swift
        // Dispatch FaceIdentifier (throttled 5s)
        if hasFace && source == "camera", let identifier = faceIdentifier,
           shouldFire(analyzerName: "faceIdentifier", throttleSeconds: 5) {
            markFired(analyzerName: "faceIdentifier")
            // Extract the VNFaceObservation from the events array
            let faceObs: VNFaceObservation? = events.compactMap { event -> VNFaceObservation? in
                if case .faceDetected(let obs) = event { return obs }
                return nil
            }.first
            if let obs = faceObs {
                let capturedJpeg = jpegData
                Task { await identifier.dispatch(jpegData: capturedJpeg, faceObservation: obs) }
            }
        }
```

- [ ] **Step 4: Run to verify pass**

```bash
swift test --filter PerceptionRouterTests 2>&1 | tail -20
```
Expected: all 4 tests PASSED

- [ ] **Step 5: Run full suite**

```bash
swift test 2>&1 | tail -20
```
Expected: all tests PASSED

- [ ] **Step 6: Commit**

```bash
git add Sources/BantiCore/PerceptionRouter.swift \
        Tests/BantiTests/PerceptionRouterTests.swift
git commit -m "feat: PerceptionRouter dispatches FaceIdentifier on faceDetected, throttled 5s"
```

---

## Task 14: SpeakerResolver.swift

**Files:**
- Create: `Sources/BantiCore/SpeakerResolver.swift`
- Create: `Tests/BantiTests/SpeakerResolverTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BantiTests/SpeakerResolverTests.swift
import XCTest
@testable import BantiCore

final class SpeakerResolverTests: XCTestCase {

    func testMinAccumulationBytesIs48000() {
        // 3 seconds at 16kHz mono Int16 = 3 * 16000 * 2 = 96000 bytes
        // We use the ring buffer directly; just verify the threshold constant
        XCTAssertEqual(SpeakerResolver.minAccumulationBytes, 96_000)
    }

    func testSessionMapLookupReturnsCachedName() async {
        let resolver = SpeakerResolver(
            context: PerceptionContext(),
            audioRouter: AudioRouter(context: PerceptionContext(), logger: Logger()),
            sidecar: MemorySidecar(logger: Logger()),
            logger: Logger(),
            sessionID: "test"
        )
        await resolver.cacheResolvedName("Alice", forSpeakerID: 2)
        let name = await resolver.resolvedName(forSpeakerID: 2)
        XCTAssertEqual(name, "Alice")
    }

    func testSessionMapReturnsNilForUnknownSpeaker() async {
        let resolver = SpeakerResolver(
            context: PerceptionContext(),
            audioRouter: AudioRouter(context: PerceptionContext(), logger: Logger()),
            sidecar: MemorySidecar(logger: Logger()),
            logger: Logger(),
            sessionID: "test"
        )
        let name = await resolver.resolvedName(forSpeakerID: 99)
        XCTAssertNil(name)
    }

    func testPendingTrackerIsEmpty() async {
        let resolver = SpeakerResolver(
            context: PerceptionContext(),
            audioRouter: AudioRouter(context: PerceptionContext(), logger: Logger()),
            sidecar: MemorySidecar(logger: Logger()),
            logger: Logger(),
            sessionID: "test"
        )
        let pending = await resolver.pendingSpeakerIDs
        XCTAssertTrue(pending.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter SpeakerResolverTests 2>&1 | tail -20
```
Expected: compiler error — `SpeakerResolver` not defined

- [ ] **Step 3: Implement SpeakerResolver.swift**

```swift
// Sources/BantiCore/SpeakerResolver.swift
import Foundation

public actor SpeakerResolver {
    private let context: PerceptionContext
    private let audioRouter: AudioRouter
    private let sidecar: MemorySidecar
    private let logger: Logger
    private let sessionID: String

    /// Minimum PCM bytes needed before sending to voice identity (3s at 16kHz mono Int16)
    public static let minAccumulationBytes = 96_000

    private var sessionMap: [Int: String] = [:]    // speakerID → resolved name
    private var pendingSet: Set<Int> = []           // speakerIDs currently being resolved

    public init(context: PerceptionContext, audioRouter: AudioRouter, sidecar: MemorySidecar,
                logger: Logger, sessionID: String) {
        self.context = context
        self.audioRouter = audioRouter
        self.sidecar = sidecar
        self.logger = logger
        self.sessionID = sessionID
    }

    // MARK: - Public start

    public func start() {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self.poll()
            }
        }
    }

    // MARK: - Testable accessors

    public func cacheResolvedName(_ name: String, forSpeakerID id: Int) {
        sessionMap[id] = name
    }

    public func resolvedName(forSpeakerID id: Int) -> String? {
        sessionMap[id]
    }

    public var pendingSpeakerIDs: Set<Int> { pendingSet }

    // MARK: - Polling logic

    private func poll() async {
        guard await sidecar.isRunning else { return }
        guard let speech = await context.speech,
              let speakerID = speech.speakerID else { return }

        // Already resolved in this session — write back if resolvedName is missing
        if let name = sessionMap[speakerID] {
            if speech.resolvedName == nil {
                let updated = SpeechState(
                    transcript: speech.transcript,
                    speakerID: speech.speakerID,
                    isFinal: speech.isFinal,
                    confidence: speech.confidence,
                    resolvedName: name,
                    updatedAt: speech.updatedAt
                )
                await context.update(.speech(updated))
            }
            return
        }

        // Already pending resolution
        guard !pendingSet.contains(speakerID) else { return }

        // Check ring buffer has enough audio
        let pcmData = await audioRouter.readPCMRingBuffer()
        guard pcmData.count >= SpeakerResolver.minAccumulationBytes else { return }

        pendingSet.insert(speakerID)
        let capturedPCM = pcmData
        let capturedSpeakerID = speakerID

        Task { [weak self] in
            guard let self else { return }
            await self.resolve(speakerID: capturedSpeakerID, pcmData: capturedPCM)
        }
    }

    private func resolve(speakerID: Int, pcmData: Data) async {
        defer { pendingSet.remove(speakerID) }

        struct VoiceRequest: Encodable {
            let pcm_b64: String
            let deepgram_speaker_id: Int
            let session_id: String
        }

        let body = VoiceRequest(
            pcm_b64: pcmData.base64EncodedString(),
            deepgram_speaker_id: speakerID,
            session_id: sessionID
        )

        guard let responseData = await sidecar.post(path: "/identity/voice", body: body) else { return }

        struct VoiceResponse: Decodable {
            let matched: Bool
            let person_id: String
            let name: String?
            let confidence: Float
        }

        guard let response = try? JSONDecoder().decode(VoiceResponse.self, from: responseData) else { return }

        let resolvedName = response.name ?? response.person_id
        sessionMap[speakerID] = resolvedName

        // Write back to PerceptionContext
        if let speech = await context.speech, speech.speakerID == speakerID {
            let updated = SpeechState(
                transcript: speech.transcript,
                speakerID: speech.speakerID,
                isFinal: speech.isFinal,
                confidence: speech.confidence,
                resolvedName: resolvedName,
                updatedAt: speech.updatedAt
            )
            await context.update(.speech(updated))
        }

        logger.log(source: "memory", message: "speaker \(speakerID) resolved: \(resolvedName)")
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
swift test --filter SpeakerResolverTests 2>&1 | tail -20
```
Expected: all 4 tests PASSED

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/SpeakerResolver.swift \
        Tests/BantiTests/SpeakerResolverTests.swift
git commit -m "feat: SpeakerResolver — 1s poll, PCM ring buffer → /identity/voice → resolvedName write-back"
```

---

## Task 15: MemoryIngestor.swift

**Files:**
- Create: `Sources/BantiCore/MemoryIngestor.swift`
- Create: `Tests/BantiTests/MemoryIngestorTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/BantiTests/MemoryIngestorTests.swift
import XCTest
@testable import BantiCore

final class MemoryIngestorTests: XCTestCase {

    func testPollIntervalIs2Seconds() {
        XCTAssertEqual(MemoryIngestor.pollIntervalNanoseconds, 2_000_000_000)
    }

    func testMaxBufferSizeIs100() {
        XCTAssertEqual(MemoryIngestor.maxBufferSize, 100)
    }

    func testDuplicateSnapshotIsFiltered() {
        let snapshot = "{\"speech\":{\"transcript\":\"hello\"}}"
        XCTAssertTrue(MemoryIngestor.isDuplicate(snapshot, previous: snapshot))
    }

    func testDifferentSnapshotIsNotDuplicate() {
        let a = "{\"speech\":{\"transcript\":\"hello\"}}"
        let b = "{\"speech\":{\"transcript\":\"world\"}}"
        XCTAssertFalse(MemoryIngestor.isDuplicate(a, previous: b))
    }

    func testEmptySnapshotIsFiltered() {
        XCTAssertTrue(MemoryIngestor.isEmpty("{}"))
        XCTAssertTrue(MemoryIngestor.isEmpty(""))
        XCTAssertFalse(MemoryIngestor.isEmpty("{\"activity\":{\"description\":\"typing\"}}"))
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter MemoryIngestorTests 2>&1 | tail -20
```
Expected: compiler error — `MemoryIngestor` not defined

- [ ] **Step 3: Implement MemoryIngestor.swift**

```swift
// Sources/BantiCore/MemoryIngestor.swift
import Foundation

public actor MemoryIngestor {
    private let context: PerceptionContext
    private let sidecar: MemorySidecar
    private let logger: Logger

    public static let pollIntervalNanoseconds: UInt64 = 2_000_000_000
    public static let maxBufferSize = 100

    private var lastSnapshot: String = ""
    private var episodeBuffer: [String] = []

    public init(context: PerceptionContext, sidecar: MemorySidecar, logger: Logger) {
        self.context = context
        self.sidecar = sidecar
        self.logger = logger
    }

    public func start() {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: MemoryIngestor.pollIntervalNanoseconds)
                await self.ingestCycle()
            }
        }
    }

    // MARK: - Testable static helpers

    public static func isDuplicate(_ snapshot: String, previous: String) -> Bool {
        snapshot == previous
    }

    public static func isEmpty(_ snapshot: String) -> Bool {
        snapshot.trimmingCharacters(in: .whitespaces).isEmpty || snapshot == "{}"
    }

    // MARK: - Private

    private func ingestCycle() async {
        guard await sidecar.isRunning else { return }

        let snapshot = await context.snapshotJSON()

        guard !MemoryIngestor.isEmpty(snapshot),
              !MemoryIngestor.isDuplicate(snapshot, previous: lastSnapshot) else { return }

        lastSnapshot = snapshot

        struct IngestBody: Encodable {
            let snapshot_json: String
            let wall_ts: String
        }

        let iso = ISO8601DateFormatter().string(from: Date())
        let body = IngestBody(snapshot_json: snapshot, wall_ts: iso)

        if let _ = await sidecar.post(path: "/memory/ingest", body: body) {
            // Flush any buffered episodes on reconnect
            if !episodeBuffer.isEmpty {
                episodeBuffer.removeAll()
            }
        } else {
            // Sidecar unreachable — buffer
            if episodeBuffer.count < MemoryIngestor.maxBufferSize {
                episodeBuffer.append(snapshot)
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
swift test --filter MemoryIngestorTests 2>&1 | tail -20
```
Expected: all 5 tests PASSED

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/MemoryIngestor.swift \
        Tests/BantiTests/MemoryIngestorTests.swift
git commit -m "feat: MemoryIngestor — 2s timer, duplicate/empty filter, 100-episode buffer"
```

---

## Task 16: MemoryQuery + SelfModel + ProactiveIntroducer

**Files:**
- Create: `Sources/BantiCore/MemoryQuery.swift`
- Create: `Sources/BantiCore/SelfModel.swift`
- Create: `Sources/BantiCore/ProactiveIntroducer.swift`
- Create: `Tests/BantiTests/MemoryQueryTests.swift`
- Create: `Tests/BantiTests/ProactiveIntroducerTests.swift`

- [ ] **Step 1: Write the failing tests for MemoryQuery**

```swift
// Tests/BantiTests/MemoryQueryTests.swift
import XCTest
@testable import BantiCore

final class MemoryQueryTests: XCTestCase {

    func testQueryReturnsFallbackWhenSidecarNotRunning() async {
        let sidecar = MemorySidecar(logger: Logger())
        // isRunning is false by default
        let query = MemoryQuery(sidecar: sidecar, logger: Logger())
        let response = await query.query("who is Alice?")
        XCTAssertFalse(response.answer.isEmpty)  // fallback message
        XCTAssertTrue(response.sources.isEmpty)
    }

    func testMemoryResponseDefaultsToEmptySources() {
        let response = MemoryResponse(answer: "test answer")
        XCTAssertEqual(response.sources, [])
        XCTAssertEqual(response.answer, "test answer")
    }
}
```

- [ ] **Step 1b: Run MemoryQuery tests to verify failure**

```bash
swift test --filter MemoryQueryTests 2>&1 | tail -20
```
Expected: compiler error — `MemoryQuery` not defined

- [ ] **Step 2: Write the failing tests for ProactiveIntroducer**

```swift
// Tests/BantiTests/ProactiveIntroducerTests.swift
import XCTest
@testable import BantiCore

final class ProactiveIntroducerTests: XCTestCase {

    func testFirstPromptThresholdIs30Seconds() {
        XCTAssertEqual(ProactiveIntroducer.firstPromptThreshold, 30.0)
    }

    func testSecondPromptThresholdIs60Seconds() {
        XCTAssertEqual(ProactiveIntroducer.secondPromptThreshold, 60.0)
    }

    func testShouldPromptFirstTimeAfter30Seconds() {
        let firstSeen = Date(timeIntervalSinceNow: -31)
        let result = ProactiveIntroducer.shouldPrompt(
            firstSeen: firstSeen,
            hasPromptedOnce: false,
            hasPromptedTwice: false,
            now: Date()
        )
        XCTAssertTrue(result)
    }

    func testShouldNotPromptBefore30Seconds() {
        let firstSeen = Date(timeIntervalSinceNow: -10)
        let result = ProactiveIntroducer.shouldPrompt(
            firstSeen: firstSeen,
            hasPromptedOnce: false,
            hasPromptedTwice: false,
            now: Date()
        )
        XCTAssertFalse(result)
    }

    func testShouldPromptSecondTimeAfter60Seconds() {
        let firstSeen = Date(timeIntervalSinceNow: -65)
        let result = ProactiveIntroducer.shouldPrompt(
            firstSeen: firstSeen,
            hasPromptedOnce: true,
            hasPromptedTwice: false,
            now: Date()
        )
        XCTAssertTrue(result)
    }

    func testShouldNotPromptAfterTwoPrompts() {
        let firstSeen = Date(timeIntervalSinceNow: -120)
        let result = ProactiveIntroducer.shouldPrompt(
            firstSeen: firstSeen,
            hasPromptedOnce: true,
            hasPromptedTwice: true,
            now: Date()
        )
        XCTAssertFalse(result)
    }

    func testPersonSeenWithNameStopsTracking() async {
        let introducer = ProactiveIntroducer(logger: Logger())
        // Start tracking an unknown person
        await introducer.personSeen("p_001", name: nil)
        let isTracked1 = await introducer.isTracking("p_001")
        XCTAssertTrue(isTracked1)
        // Provide a name — should stop tracking
        await introducer.personSeen("p_001", name: "Alice")
        let isTracked2 = await introducer.isTracking("p_001")
        XCTAssertFalse(isTracked2)
    }

    func testPersonSeenUnknownBeginsTracking() async {
        let introducer = ProactiveIntroducer(logger: Logger())
        await introducer.personSeen("p_002", name: nil)
        let isTracked = await introducer.isTracking("p_002")
        XCTAssertTrue(isTracked)
    }
}
```

> **Note:** `isTracking(_:)` is a testable accessor added to ProactiveIntroducer that returns `tracking[personID] != nil`.

- [ ] **Step 2: Run to verify failure**

```bash
swift test --filter ProactiveIntroducerTests 2>&1 | tail -20
```
Expected: compiler error — `ProactiveIntroducer` not defined

- [ ] **Step 3: Implement ProactiveIntroducer.swift**

```swift
// Sources/BantiCore/ProactiveIntroducer.swift
import Foundation

public actor ProactiveIntroducer {
    private let logger: Logger
    public static let firstPromptThreshold: Double = 30.0
    public static let secondPromptThreshold: Double = 60.0

    private struct PersonTracking {
        var firstSeen: Date
        var hasPromptedOnce: Bool = false
        var hasPromptedTwice: Bool = false
    }

    private var tracking: [String: PersonTracking] = [:]  // personID → tracking

    public init(logger: Logger) {
        self.logger = logger
    }

    // MARK: - Called from MemoryEngine when a PersonState update arrives

    public func personSeen(_ personID: String, name: String?) {
        guard name == nil else {
            // Known person — stop tracking
            tracking.removeValue(forKey: personID)
            return
        }

        if tracking[personID] == nil {
            tracking[personID] = PersonTracking(firstSeen: Date())
        }

        guard var t = tracking[personID] else { return }

        if ProactiveIntroducer.shouldPrompt(
            firstSeen: t.firstSeen,
            hasPromptedOnce: t.hasPromptedOnce,
            hasPromptedTwice: t.hasPromptedTwice
        ) {
            if !t.hasPromptedOnce {
                t.hasPromptedOnce = true
                logger.log(source: "memory",
                    message: "I noticed someone new nearby. What's their name?")
            } else if !t.hasPromptedTwice {
                t.hasPromptedTwice = true
                logger.log(source: "memory",
                    message: "Still haven't caught their name — feel free to introduce them.")
            }
            tracking[personID] = t
        }
    }

    // MARK: - Testable accessors

    public func isTracking(_ personID: String) -> Bool {
        tracking[personID] != nil
    }

    // MARK: - Testable static helper

    public static func shouldPrompt(
        firstSeen: Date,
        hasPromptedOnce: Bool,
        hasPromptedTwice: Bool,
        now: Date = Date()
    ) -> Bool {
        if hasPromptedTwice { return false }
        let elapsed = now.timeIntervalSince(firstSeen)
        if !hasPromptedOnce { return elapsed >= firstPromptThreshold }
        return elapsed >= secondPromptThreshold
    }
}
```

- [ ] **Step 4: Implement MemoryQuery.swift** (after tests are written and verified to fail)

```swift
// Sources/BantiCore/MemoryQuery.swift
import Foundation

public struct MemoryQuery {
    private let sidecar: MemorySidecar
    private let logger: Logger

    public init(sidecar: MemorySidecar, logger: Logger) {
        self.sidecar = sidecar
        self.logger = logger
    }

    public func query(_ text: String, context: PerceptionContext? = nil) async -> MemoryResponse {
        guard await sidecar.isRunning else {
            return MemoryResponse(answer: "Memory unavailable — sidecar not running", sources: [])
        }

        struct QueryBody: Encodable {
            let q: String
            let context_json: String?
        }

        let contextJSON = await context?.snapshotJSON()
        let body = QueryBody(q: text, context_json: contextJSON)

        guard let data = await sidecar.post(path: "/memory/query", body: body) else {
            return MemoryResponse(answer: "", sources: [])
        }

        struct QueryAPIResponse: Decodable {
            let answer: String
            let sources: [String]
        }

        guard let response = try? JSONDecoder().decode(QueryAPIResponse.self, from: data) else {
            return MemoryResponse(answer: "", sources: [])
        }

        return MemoryResponse(answer: response.answer, sources: response.sources)
    }
}
```

- [ ] **Step 5: Implement SelfModel.swift**

```swift
// Sources/BantiCore/SelfModel.swift
import Foundation

public actor SelfModel {
    private let context: PerceptionContext
    private let sidecar: MemorySidecar
    private let logger: Logger

    private static let reflectionIntervalNanoseconds: UInt64 = 600_000_000_000  // 10 minutes
    private var recentSnapshots: [String] = []
    private static let maxSnapshotBuffer = 300  // 10 min × 1 per 2s = 300 max

    public init(context: PerceptionContext, sidecar: MemorySidecar, logger: Logger) {
        self.context = context
        self.sidecar = sidecar
        self.logger = logger
    }

    public func start() {
        // Collect snapshots every 2s
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let snap = await self.context.snapshotJSON()
                await self.addSnapshot(snap)
            }
        }
        // Reflect every 10 minutes
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: SelfModel.reflectionIntervalNanoseconds)
                await self.reflect()
            }
        }
    }

    private func addSnapshot(_ snap: String) {
        if snap == "{}" { return }
        if recentSnapshots.count >= SelfModel.maxSnapshotBuffer {
            recentSnapshots.removeFirst()
        }
        recentSnapshots.append(snap)
    }

    private func reflect() async {
        guard await sidecar.isRunning else { return }
        guard !recentSnapshots.isEmpty else { return }

        struct ReflectBody: Encodable {
            let snapshots: [String]
        }

        let body = ReflectBody(snapshots: recentSnapshots)
        if let data = await sidecar.post(path: "/memory/reflect", body: body) {
            struct ReflectResponse: Decodable { let summary: String }
            if let response = try? JSONDecoder().decode(ReflectResponse.self, from: data) {
                logger.log(source: "memory", message: "reflection: \(response.summary)")
            }
        }
        recentSnapshots.removeAll()
    }
}
```

- [ ] **Step 6: Run to verify pass**

```bash
swift test --filter ProactiveIntroducerTests 2>&1 | tail -20
```
Expected: all 6 tests PASSED

- [ ] **Step 7: Run full suite**

```bash
swift test 2>&1 | tail -20
```
Expected: all tests PASSED

- [ ] **Step 8: Commit**

```bash
git add Sources/BantiCore/MemoryQuery.swift \
        Sources/BantiCore/SelfModel.swift \
        Sources/BantiCore/ProactiveIntroducer.swift \
        Tests/BantiTests/ProactiveIntroducerTests.swift
git commit -m "feat: MemoryQuery, SelfModel (10-min reflection), ProactiveIntroducer (30s prompt)"
```

---

## Task 17: MemoryEngine + main.swift wiring + build verification

**Files:**
- Create: `Sources/BantiCore/MemoryEngine.swift`
- Modify: `Sources/banti/main.swift`

- [ ] **Step 1: Implement MemoryEngine.swift**

No new failing tests needed — this is a composition layer; individual components are already tested. Verify the build compiles cleanly.

```swift
// Sources/BantiCore/MemoryEngine.swift
import Foundation

/// Top-level actor that owns all memory subsystems.
/// Wired in main.swift after the perception and audio pipelines are set up.
public actor MemoryEngine {
    private let context: PerceptionContext
    private let audioRouter: AudioRouter
    private let logger: Logger

    public let sidecar: MemorySidecar
    // nonisolated lets main.swift access faceIdentifier without await
    // (safe because it's a let constant set in init)
    public nonisolated let faceIdentifier: FaceIdentifier
    public let speakerResolver: SpeakerResolver
    private let memoryIngestor: MemoryIngestor
    private let selfModel: SelfModel
    private let proactiveIntroducer: ProactiveIntroducer
    public let memoryQuery: MemoryQuery

    public init(context: PerceptionContext, audioRouter: AudioRouter, logger: Logger) {
        let sessionID = UUID().uuidString
        let port = Int(ProcessInfo.processInfo.environment["MEMORY_SIDECAR_PORT"] ?? "") ?? 7700

        self.context = context
        self.audioRouter = audioRouter
        self.logger = logger

        self.sidecar = MemorySidecar(logger: logger, port: port)

        self.faceIdentifier = FaceIdentifier(
            context: context,
            sidecar: sidecar,
            logger: logger,
            sessionID: sessionID
        )

        self.speakerResolver = SpeakerResolver(
            context: context,
            audioRouter: audioRouter,
            sidecar: sidecar,
            logger: logger,
            sessionID: sessionID
        )

        self.memoryIngestor = MemoryIngestor(context: context, sidecar: sidecar, logger: logger)

        self.selfModel = SelfModel(context: context, sidecar: sidecar, logger: logger)

        self.proactiveIntroducer = ProactiveIntroducer(logger: logger)

        self.memoryQuery = MemoryQuery(sidecar: sidecar, logger: logger)
    }

    public func start() async {
        // Launch sidecar first; all subsystems gracefully no-op if it's not running
        await sidecar.start()

        // Start subsystem loops
        await memoryIngestor.start()
        await selfModel.start()
        await speakerResolver.start()

        // Watch for PersonState updates to drive ProactiveIntroducer
        startPersonObserver()

        logger.log(source: "memory", message: "MemoryEngine started")
    }

    // MARK: - Private

    private func startPersonObserver() {
        Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let person = await self.context.person {
                    await self.proactiveIntroducer.personSeen(person.id, name: person.name)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Wire MemoryEngine in main.swift**

In [Sources/banti/main.swift](Sources/banti/main.swift), add after the audio pipeline setup (after `micCapture.start()`):

```swift
// Memory layer
let memoryEngine = MemoryEngine(context: context, audioRouter: audioRouter, logger: logger)
// faceIdentifier is nonisolated let — accessible without await
Task { await router.setFaceIdentifier(memoryEngine.faceIdentifier) }
Task { await memoryEngine.start() }
```

- [ ] **Step 3: Build to verify it compiles**

```bash
cd /Users/tpavankalyan/Downloads/Code/banti
swift build 2>&1 | tail -30
```
Expected: `Build complete!` with no errors

- [ ] **Step 4: Run full test suite**

```bash
swift test 2>&1 | tail -30
```
Expected: all tests PASSED

- [ ] **Step 5: Commit**

```bash
git add Sources/BantiCore/MemoryEngine.swift \
        Sources/banti/main.swift
git commit -m "feat: MemoryEngine — wire all memory subsystems, start() launches sidecar + all loops"
```

---

## Post-implementation: Create .env.example

- [ ] **Create memory_sidecar/.env.example**

```bash
# memory_sidecar/.env.example
OPENAI_API_KEY=sk-...          # Required — mem0 semantic facts + GPT-4o reflection
NEO4J_URI=neo4j+s://...        # Required — Graphiti temporal graph (free Neo4j Aura)
NEO4J_USER=neo4j
NEO4J_PASSWORD=...
HF_TOKEN=hf_...                # Optional — enables voice identity (pyannote/embedding)
                               # Accept model terms at: https://huggingface.co/pyannote/embedding
MEMORY_SIDECAR_PORT=7700       # Optional — default 7700
```

```bash
git add memory_sidecar/.env.example
git commit -m "docs: add .env.example for memory sidecar"
```

---

## First-run checklist

After all tasks are complete, verify the full system end-to-end:

1. `cd memory_sidecar && bash setup.sh` — installs Python deps
2. `cp .env.example .env` — fill in API keys
3. `swift run banti` — starts banti; memory sidecar launches automatically
4. Check logs for `sidecar ready at http://127.0.0.1:7700`
5. Appear on camera for 5 seconds — check logs for `face unknown: p_1`
6. Speak 3+ seconds — check logs for `speaker 0 resolved: p_X`
7. Say "Hi [name]" — check logs for passive name inference
8. Wait 30s with an unknown face on camera — check for introduction prompt in stdout
