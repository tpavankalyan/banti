# Memory Layer Design

**Date:** 2026-03-19
**Status:** Approved

---

## Goal

Add a persistent, human-like memory layer to banti. Banti should remember people (by face and voice), remember what happened and when, accumulate semantic facts about people and the environment, and maintain a model of itself — all passively, with minimal user input.

---

## Requirements

| Capability | Priority |
|---|---|
| Face identity — recognize the same person across sessions | Must have |
| Voice identity — recognize the same speaker across sessions | Must have |
| Passive name inference from transcript, screen, AX reader | Must have |
| Proactive introduction when unknown person is seen | Must have |
| Text input for explicit enrollment and correction | Must have |
| Temporal memory — "who was here at 3pm Tuesday?" | Must have |
| Semantic memory — "what do I know about John?" | Must have |
| Self-model — banti's knowledge of itself and its environment | Must have |
| Graceful degradation if sidecar or cloud is unavailable | Must have |
| Cross-session identity persistence | Must have |

---

## Architecture

The memory layer sits as a new outer ring around the existing perception pipeline. The existing code has minimal changes — only `PerceptionRouter` and `AudioRouter` gain new dispatch calls, and `PerceptionContext` / `PerceptionTypes` gain new types.

```
──────────────────── EXISTING (unchanged except dispatch additions) ────
MicrophoneCapture → AudioRouter → DeepgramStreamer → PerceptionContext
                         │ (new: PCM + speakerID dispatch)
                         └──────────────────────────────→ SpeakerResolver

CameraCapture → LocalPerception → PerceptionRouter → PerceptionContext
                                       │ (new: face JPEG dispatch when face detected)
                                       └──────────────────────→ FaceIdentifier

──────────────────── NEW ─────────────────────────────────────────────
FaceIdentifier ──→ IdentityStore ──→ PerceptionContext.person
SpeakerResolver ─→ IdentityStore ──→ SpeechState.resolvedName

MemoryEngine (Swift actor, 2s timer)
  ├── reads PerceptionContext.snapshotJSON()
  ├── MemoryIngestor → sidecar /memory/ingest → Graphiti + mem0
  └── SelfModel (10-min timer) → sidecar /memory/reflect

ProactiveIntroducer → stdout via Logger when unknown face > 30s

Python Sidecar (localhost:7700)
  identity.py  — InsightFace (ArcFace) + pyannote + FAISS + SQLite
  memory.py    — Graphiti client (Neo4j Aura) + mem0 client (OpenAI)
```

**Three memory layers:**
- **Who is here now** → Identity pipeline (InsightFace + pyannote, local Python)
- **What happened and when** → Graphiti temporal graph (Neo4j Aura, cloud)
- **What I know about them** → mem0 semantic facts (OpenAI embeddings, cloud)
- **Who I am** → SelfModel reflection (GPT-4o, every 10 min)

---

## Technology Choices

| Concern | Technology | Reason |
|---|---|---|
| Face embedding + recognition | InsightFace (ArcFace, buffalo_l model) | 99.83% LFW accuracy, sub-2ms on Apple Silicon. Cloud APIs (Rekognition) are 1.5–6s per call — too slow for passive ambient use |
| Face similarity search | FAISS (local file, persisted to disk) | Zero cost, sub-millisecond lookup |
| Speaker embedding + recognition | pyannote/embedding (HuggingFace gated model) | State-of-the-art EER 0.68% VoxCeleb1, runs on Apple Silicon MPS, wraps Deepgram's session-local speaker IDs into persistent cross-session identity |
| Speech-to-text | Deepgram nova-2 (existing, unchanged) | Already wired, fast |
| Temporal entity graph | Graphiti + Neo4j Aura | Bi-temporal model — the only system designed for "what was true at 3pm Tuesday" queries. Neo4j Aura free tier covers months of ambient data |
| Semantic fact store | mem0 (OpenAI embeddings) | LLM-powered fact extraction, deduplication, natural language retrieval. Production-proven |
| Fact extraction + self-reflection | GPT-4o | Already available via OPENAI_API_KEY |
| Sidecar framework | FastAPI (Python) | Standard for Python ML sidecars |
| Identity persistence | SQLite (local, in sidecar data dir) | Single file, zero config, stores embeddings as BLOBs for index rebuild |

**Not used:**
- Azure Speaker Recognition — retired September 2025
- Speechmatics — $1.35/hr continuous would be ~$300/month; Deepgram already handles STT
- AWS Rekognition — 1.5–6s per lookup is too slow for ambient passive use
- Supermemory — cloud-only SaaS, early-stage, not designed for continuous ambient ingestion

---

## Raw Media Plumbing

### Face JPEG access for FaceIdentifier

`PerceptionContext` does not store raw JPEG frames. The JPEG flows through `LocalPerception → PerceptionRouter.dispatch(jpegData:source:events:)` and is consumed there.

`PerceptionRouter` gains one new dispatch: when a `faceDetected` event fires and the source is `"camera"`, it calls `FaceIdentifier.dispatch(jpegData: jpegData, faceObservation: obs)` directly — the same pattern used for `HumeEmotionAnalyzer`. This is throttled inside `PerceptionRouter` using the existing `shouldFire/markFired` mechanism at a 5-second interval per `"faceIdentifier"` key.

No JPEG is stored in `PerceptionContext`. `FaceIdentifier` receives the JPEG inline.

### PCM access for SpeakerResolver

`PerceptionContext` does not store raw PCM. PCM flows through `AudioRouter.dispatch(pcmChunk:)` and is forwarded to `DeepgramStreamer`. Deepgram responds with a speakerID asynchronously (300ms–2s later), so the speakerID is not known at PCM dispatch time.

**Mechanism:** `AudioRouter` maintains a rolling ring buffer of the last 5 seconds of raw PCM (~160 KB at 16kHz mono Int16). `SpeakerResolver` (Swift actor) runs its own 1-second polling loop watching `PerceptionContext.speech`. When it sees a `speakerID` it has not yet resolved in this session, it calls `audioRouter.drainPCMBuffer()` to obtain the buffered audio, accumulates until ≥ 3 seconds per `speakerID`, then sends to the sidecar.

This gives `SpeakerResolver` a best-effort slice of recent audio attributed to the active speaker — sufficient for voiceprint extraction since pyannote only needs ~3 seconds of mostly-clean speech. `AudioRouter` exposes two new methods:
- `func appendToPCMRingBuffer(_ chunk: Data)` — called from `dispatch(pcmChunk:)` alongside existing Deepgram dispatch
- `func drainPCMBuffer() -> Data` — returns current ring buffer contents without clearing

---

## Identity Pipeline

### Face Identity

`FaceIdentifier` (Swift actor) receives face JPEGs directly from `PerceptionRouter` (throttled 5s per `"faceIdentifier"` key). It crops the face region using the `VNFaceObservation.boundingBox` and POSTs to the sidecar:

**Request:**
```
POST /identity/face
{ "jpeg_b64": "...", "session_id": "uuid" }
```

**Response:**
```json
{ "matched": true,  "name": "John", "person_id": "p_0042", "confidence": 0.94 }
{ "matched": false, "person_id": "p_0099" }
```

InsightFace extracts a 512-d ArcFace embedding. FAISS cosine search against enrolled persons. Threshold: cosine similarity > 0.6 → match.

**Cross-session stability of unknown IDs:** When no match is found, the sidecar immediately inserts a new row in SQLite with `display_name = NULL` and stores the 512-d embedding as a BLOB. The returned `person_id` is `"p_{rowid}"` — stable because it is the SQLite row ID, not a FAISS index. On subsequent frames the same face will match its own FAISS entry (added on first sight) and return the same `person_id`. This makes unknown tracking stable across sessions.

`FaceIdentifier` writes back to `PerceptionContext` via `context.update(.person(PersonState(id: "p_0099", name: nil, confidence: 0.94, updatedAt: Date())))`.

### Voice Identity

`SpeakerResolver` (Swift actor) polls `PerceptionContext.speech` every 1 second. When it sees a new `speakerID`, it calls `audioRouter.drainPCMBuffer()` and accumulates per speakerID until ≥ 3 seconds, then:

**Request:**
```
POST /identity/voice
{ "pcm_b64": "...", "deepgram_speaker_id": 1, "session_id": "uuid" }
```

**Response:**
```json
{ "matched": true,  "name": "Sarah", "person_id": "p_0031", "confidence": 0.89 }
{ "matched": false, "person_id": "p_0105" }
```

pyannote/embedding extracts a 256-d voiceprint. FAISS cosine search. Threshold: similarity > 0.75 → match.

`SpeakerResolver` maintains a session map `[Int: String]` — once Deepgram speaker_1 resolves to "Sarah," all subsequent speaker_1 transcripts in that session are tagged with `resolvedName = "Sarah"` without re-querying.

### Identity Store (SQLite in sidecar)

Stored at `~/Library/Application Support/banti/data/identity.db`. Managed entirely by the Python sidecar.

```sql
persons (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  display_name    TEXT,              -- NULL if unknown
  face_embedding  BLOB,              -- 512 float32 values (2048 bytes) — enables FAISS rebuild
  voice_embedding BLOB,              -- 256 float32 values (1024 bytes) — enables FAISS rebuild
  face_faiss_id   INTEGER,           -- FAISS vector index position
  voice_faiss_id  INTEGER,           -- FAISS vector index position
  mem0_user_id    TEXT UNIQUE,       -- "person_p0042" — used to scope mem0 facts
  first_seen      REAL,              -- unix timestamp
  last_seen       REAL,
  metadata        TEXT               -- JSON: { "role": "...", "workplace": "...", "notes": "..." }
)
```

`face_embedding` and `voice_embedding` BLOBs are stored so the FAISS index can be fully rebuilt from SQLite if the index files are lost or corrupted — no re-enrollment needed.

`mem0_user_id` is derived as `"person_" + person_id` (e.g., `person_id = "p_0042"` → `mem0_user_id = "person_p0042"`). This is the string passed to every `mem0.add()` and `mem0.search()` call for that person, scoping their facts correctly.

### Passive Name Inference

banti resolves names from existing signals before prompting the user:

| Signal | Example | Extraction method |
|---|---|---|
| Transcript | "Hey John, got a minute?" | GPT-4o extracts addressee |
| Screen | Zoom participant list, Slack DM header, email To: | GPT-4o screen analyzer |
| AX reader | "Messages — chat with Alex" | Window title parsing via `PerceptionRouter` |

When a name is extracted and a face with a matching `person_id` is currently visible, they are linked: `display_name` set in SQLite, FAISS entry updated, Graphiti node created, mem0 fact written.

---

## Memory Pipeline

### MemoryIngestor

`MemoryEngine` runs its own 2-second `Task.sleep` loop (parallel to `startSnapshotTimer`) calling `context.snapshotJSON()` and forwarding to the sidecar. No modifications to `startSnapshotTimer` are required.

Filters before ingest: skip frames where `snapshotJSON()` returns `"{}"` (empty state), or where the snapshot is byte-for-byte identical to the previous one.

**Sidecar snapshot-to-episode transformation:** Raw `snapshotJSON()` output contains sensor data (`boundingBox`, `landmarksDetected`, etc.) that is not suitable for Graphiti's LLM extraction. The sidecar's `memory.py` transforms the JSON into a human-readable episode string before calling `graphiti.add_episode()`:

```python
# Example transformation
def snapshot_to_episode(snapshot: dict, wall_ts: datetime) -> str:
    parts = []
    if sp := snapshot.get("speech"):
        name = sp.get("resolvedName") or f"unknown speaker"
        parts.append(f'{name} said: "{sp["transcript"]}"')
    if p := snapshot.get("person"):
        name = p.get("name") or "an unknown person"
        parts.append(f"{name} was visible on camera")
    if a := snapshot.get("activity"):
        parts.append(f"Activity: {a['description']}")
    if sc := snapshot.get("screen"):
        parts.append(f"Screen: {sc['description']}")
    return ". ".join(parts) if parts else None
```

Only non-empty episodes are forwarded to Graphiti.

### Graphiti (Neo4j Aura)

Accessed via `graphiti-core` Python library in the sidecar. Each transformed episode is added as:

```python
await graphiti.add_episode(
    name=f"snapshot_{uuid}",
    episode_body=episode_text,
    source_description="banti ambient perception",
    reference_time=wall_ts,     # when the event occurred
)
```

Graphiti's internal LLM pipeline extracts entities and relationships, writes bi-temporal edges. `valid_from`/`valid_to` is derived from `reference_time`.

Answers: *"Who was here at 3pm Tuesday?"*, *"What was discussed during yesterday's meeting?"*

**Buffering on disconnect:** `MemoryIngestor` maintains an in-memory deque of up to 100 transformed episode strings. If Graphiti is unreachable, episodes are buffered and flushed with exponential backoff (1s, 2s, 4s… up to 60s).

### mem0 (OpenAI embeddings)

Accessed via `mem0ai` Python SDK in the sidecar. Facts are written using the person's `mem0_user_id` from the SQLite store:

```python
memory.add(episode_text, user_id=person.mem0_user_id)
```

Self-model facts use `user_id="banti_self"`.

Facts are deduplicated by mem0 on ingest. Same fact learned three times stays one fact with higher confidence.

Query: `memory.search(query, user_id=person.mem0_user_id)`.

### SelfModel

`SelfModel` (Swift actor) runs a reflection cycle every 10 minutes. Collects the last 10 minutes of `snapshotJSON()` snapshots, POSTs to `/memory/reflect`. The sidecar sends them to GPT-4o with a prompt structured around three questions:

1. **Observations** — time-anchored facts → Graphiti under `"banti"` entity node
2. **Patterns** — recurring signals → mem0 `user_id: "banti_self"`
3. **Relationships** — person facts → reinforces existing mem0 entries per person

`SelfModel` also maintains `~/Library/Application Support/banti/self.json`:

```json
{
  "owner": "Pavan",
  "owner_role": "software engineer",
  "known_people": ["John (colleague)", "Sarah (designer)"],
  "frequent_apps": ["Xcode", "Figma", "Slack"],
  "typical_schedule": "meetings 9-11am, deep work 2-5pm",
  "environment": "home office, MacBook Pro",
  "last_reflection": "2026-03-19T14:30:00Z"
}
```

Seeds every session with stable context so banti never starts cold.

### MemoryQuery

```swift
func query(_ text: String, context: PerceptionContext?) async -> MemoryResponse
```

Fans out to Graphiti (temporal) + mem0 (semantic) via sidecar `/memory/query` in parallel. GPT-4o fuses results into a coherent answer. Current `PerceptionContext` passed as grounding context — if John is visible now, his facts are boosted in relevance.

---

## Enrollment Flows

### Flow 1: Passive inference
1. `FaceIdentifier` → `person_id: "p_0099"` (unknown), face visible.
2. `SpeakerResolver` → `person_id: "p_0099"` voice matches same unknown.
3. Transcript arrives: *"Thanks John, see you tomorrow"*.
4. `MemoryIngestor` sends to GPT-4o name extraction: `{ name: "John" }`.
5. `IdentityStore`: `display_name = "John"` for `p_0099`. FAISS entry updated.
6. Graphiti: `Person("John")` node created.
7. mem0: `memory.add("John was present", user_id="person_p0099")`.

### Flow 2: Proactive introduction
1. `person_id: "p_0105"` visible for 30+ seconds with no passive inference result.
2. `ProactiveIntroducer` calls `logger.log(source: "memory", message: "I noticed someone new — what's their name?")` → printed to stdout.
3. Text input arrives (via stdin or future UI): *"That's Sarah, she's a designer"*.
4. GPT-4o: `{ name: "Sarah", role: "designer" }`.
5. Face + voice enrolled under "Sarah". SQLite, FAISS, Graphiti, mem0 updated.
6. If no text input: unknown tracked stably. Prompt re-emitted once after 60s, then silent.

**Phase-1 output mechanism:** stdout via `Logger`. A future speech output layer will replace this with spoken output — the `MemoryAction` type is defined now to make that transition easy.

### Flow 3: Correction
1. Text input: *"That's not John, that's Mike"*.
2. GPT-4o: `{ correction: true, wrong_name: "John", correct_name: "Mike" }`.
3. `display_name` updated. FAISS entry relabelled. Graphiti node renamed.
4. mem0: `"Mike was previously confused with John, they are different people"`.

### Flow 4: Self-enrollment (first launch)
1. SQLite empty → first launch detected.
2. `ProactiveIntroducer` logs: *"Hi, I'm Banti. What's your name?"*.
3. Text input: *"I'm Pavan, I'm a software engineer"*.
4. Owner face + voice enrolled as `display_name = "Pavan"`, `metadata.is_owner = true`.
5. `self.json` seeded with `owner: "Pavan"`, `owner_role: "software engineer"`.

---

## Swift File Map

### New files (`Sources/BantiCore/`)

| File | Responsibility |
|---|---|
| `MemoryTypes.swift` | `PersonState` (live sensor annotation for PerceptionContext), `PersonRecord` (SQLite row DTO), `MemoryAction` enum (introduceYourself, correction), `MemoryResponse` |
| `IdentityStore.swift` | Swift-side SQLite actor for Swift-readable identity lookups (mirrors sidecar SQLite) |
| `FaceIdentifier.swift` | Receives face JPEG from PerceptionRouter → sidecar `/identity/face` → writes `PersonState` to PerceptionContext |
| `SpeakerResolver.swift` | 1s poll on PerceptionContext.speech → AudioRouter PCM ring buffer → sidecar `/identity/voice` → session map Int→resolvedName |
| `MemoryIngestor.swift` | 2s timer → `snapshotJSON()` → sidecar `/memory/ingest` with buffering |
| `MemoryQuery.swift` | Text query → sidecar `/memory/query` → `MemoryResponse` |
| `SelfModel.swift` | 10-min timer → collect snapshots → sidecar `/memory/reflect` → update `self.json` |
| `ProactiveIntroducer.swift` | Tracks unknown face duration → emits `MemoryAction.introduceYourself` + logs prompt |
| `MemoryEngine.swift` | Top-level actor — owns all above, wired in `main.swift` |
| `MemorySidecar.swift` | Launches and monitors Python sidecar, polls `/health` |

### Modified files

| File | Change |
|---|---|
| `PerceptionContext.swift` | Add `var person: PersonState?`; add `case .person(let s): person = s` to `update()` switch |
| `PerceptionTypes.swift` | Add `PersonState` to `PerceptionObservation` enum: `case person(PersonState)` |
| `PerceptionRouter.swift` | Add throttled `FaceIdentifier.dispatch(jpegData:faceObservation:)` call in `dispatch()` when face detected; inject `FaceIdentifier` via init |
| `AudioTypes.swift` | Add `resolvedName: String?` to `SpeechState` |
| `AudioRouter.swift` | Add PCM ring buffer (last 5s); expose `appendToPCMRingBuffer(_:)` and `drainPCMBuffer() -> Data`; inject `SpeakerResolver` via init |
| `Sources/banti/main.swift` | Wire `MemoryEngine` after existing pipeline setup |

---

## Python Sidecar

### Structure

```
memory_sidecar/
├── main.py          — FastAPI app, startup/shutdown lifecycle
├── identity.py      — InsightFace + pyannote + FAISS + SQLite logic
├── memory.py        — Graphiti client + mem0 client + episode transformer
├── models.py        — Pydantic request/response schemas
├── requirements.txt
└── data/            — FAISS index files (face.index, voice.index), identity.db
```

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| POST | `/identity/face` | Identify or enroll a face |
| POST | `/identity/voice` | Identify or enroll a voice segment |
| POST | `/identity/enroll` | Explicit enrollment (name + person_id + optional metadata) |
| POST | `/memory/ingest` | Snapshot JSON + wall_ts → Graphiti episode + mem0 facts |
| GET | `/memory/query` | `?q=...` natural language → fused Graphiti + mem0 results |
| POST | `/memory/reflect` | Array of snapshots → GPT-4o reflection → Graphiti + mem0 + self.json |
| GET | `/health` | Liveness check |

### Launch path

`MemorySidecar.swift` resolves the sidecar path relative to the executable using `Bundle.main.executableURL`:

```swift
// In development (swift run): executable is .build/debug/banti
// In app bundle: executable is Banti.app/Contents/MacOS/banti
// Sidecar is always adjacent to the project root in dev,
// or bundled at Banti.app/Contents/Resources/memory_sidecar/ in distribution.
let sidecarDir = Bundle.main.resourceURL?
    .appendingPathComponent("memory_sidecar")
    ?? executableURL
        .deletingLastPathComponent()   // .build/debug/
        .deletingLastPathComponent()   // .build/
        .deletingLastPathComponent()   // project root
        .appendingPathComponent("memory_sidecar")
```

Polls `/health` at 500ms intervals, times out after 10s. If timeout: `MemoryEngine` logs warning and operates without memory.

### Environment bootstrap

A `memory_sidecar/setup.sh` script handles first-run setup:

```bash
#!/usr/bin/env bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
# pyannote/embedding is a gated HuggingFace model.
# User must accept model terms at https://hf.co/pyannote/embedding
# and set HF_TOKEN in .env before first run.
```

`MemorySidecar.swift` uses `.venv/bin/python3` if the venv exists, otherwise falls back to system `python3`. If `HF_TOKEN` is missing, pyannote is disabled and voice identity is skipped (face identity and memory still work).

### Environment variables (`.env`)

```
OPENAI_API_KEY=...           # already present — mem0 + GPT-4o reflection
NEO4J_URI=...                # Neo4j Aura bolt URI
NEO4J_USER=...
NEO4J_PASSWORD=...
HF_TOKEN=...                 # HuggingFace token for pyannote/embedding (gated model)
MEMORY_SIDECAR_PORT=7700     # optional override
```

---

## Error Handling

| Failure | Behaviour |
|---|---|
| Sidecar fails to start (no Python, missing deps) | Log warning, `MemoryEngine` disabled, all perception continues |
| `HF_TOKEN` missing | Voice identity disabled, face identity and memory continue |
| Face lookup timeout (>2s) | Skip this frame, retry next cycle |
| Neo4j Aura unreachable | Buffer up to 100 episodes in memory, retry with exponential backoff (1s→60s) |
| mem0 API error | Log and skip — non-critical |
| FAISS index files deleted/corrupted | Sidecar rebuilds indexes from `face_embedding`/`voice_embedding` BLOBs in SQLite on startup — no re-enrollment needed |
| Unknown face, no input for 60s | Re-emit prompt once, then stay silent until next session |
| GPT-4o name extraction returns nothing | No-op, passive inference continues |
| Snapshot-to-episode transformation produces empty string | Skip ingest for that cycle |

---

## Success Criteria

| Criterion | How to verify |
|---|---|
| Recognizes same face across sessions | Restart banti, re-appear on camera — name logged within 5s without re-enrollment |
| Recognizes same voice across sessions | Restart banti, speak ≥3s — speaker name in `SpeechState.resolvedName` |
| Passive name inference works | Say "Hi John" near mic while John is on camera — John enrolled without prompt |
| Proactive introduction fires | New unknown face visible 30s with no passive signal — prompt logged to stdout |
| Temporal query works | `MemoryQuery.query("who was here at 3pm?")` — Graphiti returns correct person |
| Semantic query works | `MemoryQuery.query("what do I know about John?")` — mem0 returns facts |
| Self-model persists across sessions | Restart banti — `self.json` retains known people and schedule patterns |
| FAISS rebuild works | Delete index files, restart — sidecar rebuilds from SQLite, recognition still works |
| Graceful degradation | Kill sidecar mid-run — banti continues logging perception, no crash |
