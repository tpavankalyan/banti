# memory_sidecar/models.py
from pydantic import BaseModel
from typing import Optional, Literal

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

class BrainDecideRequest(BaseModel):
    snapshot_json: str
    recent_speech: list[str] = []
    last_spoke_seconds_ago: float = 9999.0
    last_spoke_text: Optional[str] = None

class ProactiveDecisionResponse(BaseModel):
    action: Literal["speak", "silent"]
    text: Optional[str] = None
    reason: str

class ConversationTurn(BaseModel):
    speaker: str      # "banti" or "human"
    text: str
    timestamp: float  # unix timestamp

class BrainStreamRequest(BaseModel):
    track: Literal["reflex", "reasoning"]
    ambient_context: str = "{}"                      # was: snapshot_json
    conversation_history: list[ConversationTurn] = []  # was: recent_speech: list[str]
    last_banti_utterance: Optional[str] = None       # was: last_spoke_text
    last_spoke_seconds_ago: float = 9999.0
    is_interruption: bool = False
    current_speech: Optional[str] = None
