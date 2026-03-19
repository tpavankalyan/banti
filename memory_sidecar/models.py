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
