# memory_sidecar/identity.py
import os
import numpy as np
from typing import Optional

FACE_APP = None       # insightface.app.FaceAnalysis
FACE_INDEX = None     # faiss.IndexFlatIP for 512-d
VOICE_MODEL = None    # pyannote Inference
VOICE_INDEX = None    # faiss.IndexFlatIP for 256-d

_face_person_ids: list[str] = []
_voice_person_ids: list[str] = []

DB_PATH = os.environ.get(
    "BANTI_DB_PATH",
    os.path.expanduser("~/Library/Application Support/banti/data/identity.db")
)

FACE_THRESHOLD = 0.6
VOICE_THRESHOLD = 0.75

async def init_identity() -> None:
    global FACE_APP, FACE_INDEX, VOICE_MODEL, VOICE_INDEX
    import faiss
    from db import init_db, get_all_persons, get_all_persons_with_voice

    db_path = _get_db_path()
    init_db(db_path)

    # Always create fresh FAISS indexes on startup so stale state doesn't persist
    FACE_INDEX = faiss.IndexFlatIP(512)
    _rebuild_face_index(get_all_persons(db_path))

    VOICE_INDEX = faiss.IndexFlatIP(256)
    _rebuild_voice_index(get_all_persons_with_voice(db_path))

    # Only init ML models if not already set (pre-set by tests via mocking)
    if FACE_APP is None:
        try:
            from insightface.app import FaceAnalysis
            FACE_APP = FaceAnalysis(
                name="buffalo_l",
                providers=["CoreMLExecutionProvider", "CPUExecutionProvider"]
            )
            FACE_APP.prepare(ctx_id=0, det_size=(640, 640))
        except Exception as e:
            print(f"[warn] InsightFace init failed: {e} — face identity disabled")
            FACE_APP = None

    if VOICE_MODEL is None:
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


def _rebuild_face_index(persons: list[dict]) -> None:
    global _face_person_ids
    import faiss
    _face_person_ids = []
    if not persons or FACE_INDEX is None:
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
    if not persons or VOICE_INDEX is None:
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


def _get_db_path() -> str:
    """Read DB path dynamically to pick up env var changes (important for tests)."""
    return os.environ.get(
        "BANTI_DB_PATH",
        os.path.expanduser("~/Library/Application Support/banti/data/identity.db")
    )


def _ensure_face_index() -> None:
    """Lazily initialize FACE_INDEX if init_identity was never called (e.g. lifespan failed)."""
    global FACE_INDEX
    if FACE_INDEX is None:
        import faiss
        FACE_INDEX = faiss.IndexFlatIP(512)


def identify_face(jpeg_bytes: bytes) -> tuple[str, Optional[str], float]:
    """Returns (person_id, name_or_None, confidence). Enrolls on first sight."""
    import faiss
    from db import create_person, get_person_by_id, update_person_embeddings

    db_path = _get_db_path()
    _ensure_face_index()

    if FACE_APP is None:
        raise RuntimeError("Face model not initialized")

    # Decode JPEG using PIL (available in all environments including tests)
    from PIL import Image
    import io
    try:
        pil_img = Image.open(io.BytesIO(jpeg_bytes))
        img = np.array(pil_img.convert("RGB"))
        img = img[:, :, ::-1]  # RGB → BGR for InsightFace
    except Exception:
        raise ValueError("Could not decode JPEG")

    faces = FACE_APP.get(img)
    if not faces:
        raise ValueError("No face detected in image")

    face = max(faces, key=lambda f: getattr(f, "det_score", 0.0))
    raw_emb = face.embedding.astype(np.float32)
    emb = _normalize(raw_emb)
    emb_row = emb.reshape(1, -1).copy()

    if FACE_INDEX is not None and FACE_INDEX.ntotal > 0:
        faiss.normalize_L2(emb_row)
        distances, indices = FACE_INDEX.search(emb_row, 1)
        best_score = float(distances[0][0])
        best_idx = int(indices[0][0])

        if best_score >= FACE_THRESHOLD and best_idx < len(_face_person_ids):
            person_id = _face_person_ids[best_idx]
            person = get_person_by_id(db_path, person_id)
            name = person["display_name"] if person else None
            return person_id, name, best_score

    # New person — enroll
    emb_blob = emb.tobytes()
    person_id = create_person(db_path, display_name=None,
                               face_embedding=emb_blob, voice_embedding=None)

    if FACE_INDEX is not None:
        faiss_id = FACE_INDEX.ntotal
        faiss_emb = emb.reshape(1, -1).copy()
        faiss.normalize_L2(faiss_emb)
        FACE_INDEX.add(faiss_emb)
        _face_person_ids.append(person_id)
        update_person_embeddings(db_path, person_id,
                                  face_embedding=emb_blob,
                                  face_faiss_id=faiss_id)
    return person_id, None, 0.0
