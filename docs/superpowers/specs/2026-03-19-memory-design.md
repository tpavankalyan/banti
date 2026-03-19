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

The memory layer sits as a new ring around the existing perception pipeline. Nothing in the existing code changes — `MemoryEngine` subscribes to the same `PerceptionContext` snapshots already flowing every 2 seconds.

```
──────────────────── EXISTING ────────────────────
MicrophoneCapture → AudioRouter → DeepgramStreamer → PerceptionContext
CameraCapture ──→ LocalPerception → PerceptionRouter ──→ PerceptionContext
ScreenCapture ──→    (same)                              (speech, face, screen,
AXReader ─────────────────────────────────────────→       activity, etc.)

──────────────────── NEW ─────────────────────────
PerceptionContext ──→ MemoryEngine (Swift actor)
                          │
               ┌──────────┼────────────────┐
               ↓          ↓                ↓
        FaceIdentifier  SpeakerResolver  MemoryIngestor
               │          │
               └──────────┘
                    ↓
              IdentityStore (SQLite, local)
                    ↓
          ┌─────────┴──────────┐
     Graphiti              mem0
  (Neo4j Aura)       (OpenAI embeddings)
  temporal entity      semantic facts
  "who/when/where"     "what I know about X"

Python Sidecar (localhost:7700)
  InsightFace  ── face embeddings + FAISS index
  pyannote     ── voice embeddings + FAISS index

SelfModel (Swift actor, every 10 min)
  recent snapshots → GPT-4o → self-observations → Graphiti "self" entity

ProactiveIntroducer (Swift actor)
  unknown face > 30s without name → text prompt → enrollment
```

**Three memory layers — mirroring human memory:**
- **Who is here now** → Identity pipeline (InsightFace + pyannote, local)
- **What happened and when** → Graphiti temporal graph (Neo4j Aura)
- **What I know about them** → mem0 semantic facts (OpenAI embeddings)
- **Who I am** → SelfModel reflection (GPT-4o, every 10 min)

---

## Technology Choices

| Concern | Technology | Reason |
|---|---|---|
| Face embedding + recognition | InsightFace (ArcFace, buffalo_l model) | 99.83% LFW accuracy, sub-2ms latency on Apple Silicon. Cloud APIs (Rekognition) are 1.5–6s — too slow for passive ambient use |
| Face similarity search | FAISS (local file) | Zero cost, persists as a file alongside identity.db |
| Speaker embedding + recognition | pyannote/embedding | State-of-the-art EER 0.68% on VoxCeleb1, runs on Apple Silicon MPS, wraps Deepgram's session-local speaker IDs into persistent cross-session identity |
| Speech-to-text | Deepgram nova-2 (existing) | Already wired, fast, kept unchanged |
| Temporal entity graph | Graphiti + Neo4j Aura | Bi-temporal model (valid_from/valid_to + ingested_at) — only system designed for "what was true at 3pm Tuesday" queries. Backed by arxiv paper (Jan 2026). Neo4j Aura free tier covers months of ambient data |
| Semantic fact store | mem0 (OpenAI embeddings) | LLM-powered fact extraction, deduplication, natural language retrieval. 30k+ GitHub stars, production-proven |
| Fact extraction + self-reflection | GPT-4o | Already available via OPENAI_API_KEY |
| Sidecar framework | FastAPI (Python) | Minimal, already the standard for Python ML sidecar patterns |
| Identity persistence | SQLite (local) | Single file, zero config, maps person names to FAISS index IDs |

**Not used:**
- Azure Speaker Recognition — retired September 2025
- Speechmatics — $1.35/hr continuous would be ~$300/month; Deepgram already handles STT
- AWS Rekognition — 1.5–6s per lookup is too slow for ambient passive use
- Supermemory — cloud-only SaaS, early-stage, not designed for continuous ambient ingestion

---

## Identity Pipeline

### Face Identity

`FaceIdentifier` (Swift actor) watches `PerceptionContext.face`, throttled to one lookup per detected face region every 5 seconds.

**Request:**
```
POST /identity/face
{ jpeg_b64: "...", session_id: "uuid" }
```

**Response:**
```json
{ "matched": true,  "name": "John", "confidence": 0.94 }
{ "matched": false, "unknown_id": "face_a3b7" }
```

InsightFace extracts a 512-d ArcFace embedding. FAISS cosine search against enrolled persons. Threshold: similarity > 0.6 → match.

`unknown_id` is a stable hash of the embedding — the same unknown face gets the same ID across frames and sessions. Tracked as `unknown_a3b7` until named.

`FaceIdentifier` writes back to `PerceptionContext` as a new `PersonState` (name or unknown ID, confidence, last_seen).

### Voice Identity

`SpeakerResolver` (Swift actor) watches `SpeechState`. Deepgram provides session-local speaker IDs (0, 1, 2…). The resolver maps these to persistent names.

**Request (on segments ≥ 3 seconds):**
```
POST /identity/voice
{ pcm_b64: "...", deepgram_speaker_id: 1, session_id: "uuid" }
```

**Response:**
```json
{ "matched": true,  "name": "Sarah", "confidence": 0.89 }
{ "matched": false, "unknown_id": "voice_c1f2" }
```

pyannote/embedding extracts a 256-d voiceprint. FAISS cosine search. Threshold: similarity > 0.75 → match.

`SpeakerResolver` maintains a session map `[Int: String]` — once speaker_1 resolves to "Sarah," all subsequent speaker_1 transcripts are tagged without re-querying.

### Identity Store

SQLite at `~/Library/Application Support/banti/identity.db`:

```sql
persons (
  id            TEXT PRIMARY KEY,   -- "john" or "unknown_a3b7"
  display_name  TEXT,               -- null if unknown
  face_faiss_id INTEGER,
  voice_faiss_id INTEGER,
  first_seen    REAL,               -- unix timestamp
  last_seen     REAL,
  metadata      TEXT                -- JSON blob: role, workplace, notes
)
```

When an unknown is named, the row is updated in place. FAISS index updated with the display name.

### Passive Name Inference

banti resolves names from existing signals before prompting the user:

| Signal | Example | Extraction method |
|---|---|---|
| Transcript | "Hey John, got a minute?" | GPT-4o extracts addressee |
| Screen | Zoom participant list, Slack DM header, email To: | GPT-4o screen analyzer |
| AX reader | "Messages — chat with Alex" | Window title parsing |

When a name is extracted and an unknown face is currently visible, they are linked automatically.

---

## Memory Pipeline

### MemoryIngestor

Every 2 seconds, receives `snapshotJSON()` output. Filters out empty/duplicate frames. Fans out in parallel:

- **→ Graphiti** (via sidecar `/memory/ingest`): full snapshot as episodic event with wall-clock timestamp. Graphiti's extraction pipeline writes bi-temporal graph edges for all entities (persons, activities, topics, apps).
- **→ mem0** (via sidecar `/memory/ingest`): semantically rich fields only (transcript, activity, screen description, person states). GPT-4o extracts durable facts.

### Graphiti (Neo4j Aura)

Bi-temporal edges:
- `valid_from` / `valid_to`: when the state was true in the world
- `ingested_at`: when banti recorded it

Example edges:
```
(John) -[PRESENT_AT {valid_from: 14:00, valid_to: 15:00}]-> (2026-03-19)
(John) -[DISCUSSED]-> (Q1 roadmap)
(Sarah) -[CO_PRESENT_WITH]-> (John)
```

Answers: *"Who was here at 3pm Tuesday?"*, *"What has John been discussing this week?"*

### mem0 (OpenAI embeddings)

Facts scoped per entity. Deduplicated on ingest — the same fact learned three times stays one fact with higher confidence.

Answers: *"What do I know about John?"*, *"What platforms does the user work on most?"*

### SelfModel

Runs every 10 minutes. Collects last 10 minutes of snapshots. GPT-4o prompt structured around three questions:

1. **Observations** — time-anchored facts → Graphiti `"banti"` entity
2. **Patterns** — recurring signals → mem0 `user_id: "self"`
3. **Relationships** — reinforces person facts in mem0

Maintains `~/Library/Application Support/banti/self.json`:

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

Fans out to Graphiti (temporal) + mem0 (semantic) in parallel. GPT-4o fuses results. Current `PerceptionContext` passed as grounding — if John is visible now, his facts are boosted in relevance.

---

## Enrollment Flows

### Flow 1: Passive inference
1. Unknown face visible. Unknown voice speaking.
2. Transcript: *"Thanks John, see you tomorrow"*
3. GPT-4o extracts: `{ name: "John" }`
4. IdentityStore links unknown_a3b7 → "John"
5. FAISS and Graphiti updated. mem0 fact written.

### Flow 2: Proactive introduction
1. Unknown face visible for 30+ seconds with no passive inference result.
2. `ProactiveIntroducer` emits: `"I noticed someone new — what's their name?"`
3. Text input: *"That's Sarah, she's a designer"*
4. GPT-4o parses: `{ name: "Sarah", role: "designer" }`
5. Face + voice enrolled. IdentityStore, Graphiti, mem0 all updated.
6. If no text input: unknown tracked stably, prompt retried once after 60s then silenced.

### Flow 3: Correction
1. Text input: *"That's not John, that's Mike"*
2. GPT-4o: `{ correction: true, wrong_name: "John", correct_name: "Mike" }`
3. IdentityStore, FAISS, Graphiti updated. mem0 adds disambiguation fact.

### Flow 4: Self-enrollment (first launch)
1. IdentityStore empty → first launch detected.
2. `ProactiveIntroducer` emits: *"Hi, I'm Banti. What's your name?"*
3. Text input: *"I'm Pavan, I'm a software engineer"*
4. Owner face + voice enrolled. `self.json` seeded.

---

## Swift File Map

### New files (`Sources/BantiCore/`)

| File | Responsibility |
|---|---|
| `MemoryTypes.swift` | `PersonState`, `MemoryAction`, `MemoryResponse`, `PersonRecord` |
| `IdentityStore.swift` | SQLite actor — CRUD for persons, name↔ID lookups |
| `FaceIdentifier.swift` | Throttled face crop → sidecar `/identity/face` → writes `PersonState` to `PerceptionContext` |
| `SpeakerResolver.swift` | Session map Deepgram speaker IDs → resolved names via sidecar `/identity/voice` |
| `MemoryIngestor.swift` | Snapshot fan-out → sidecar `/memory/ingest` |
| `MemoryQuery.swift` | Text query → sidecar `/memory/query` → `MemoryResponse` |
| `SelfModel.swift` | 10-min timer → reflection → sidecar `/memory/reflect` |
| `ProactiveIntroducer.swift` | Unknown face/voice → `MemoryAction.introduceYourself` |
| `MemoryEngine.swift` | Top-level actor, owns all above, wired in `main.swift` |
| `MemorySidecar.swift` | Launches and monitors the Python sidecar process |

### Modified files

| File | Change |
|---|---|
| `PerceptionContext.swift` | Add `var person: PersonState?` |
| `PerceptionTypes.swift` | Add `PersonState` to `PerceptionObservation` enum |
| `Sources/banti/main.swift` | Wire `MemoryEngine` after existing pipeline setup |

---

## Python Sidecar (`memory_sidecar/`)

```
memory_sidecar/
├── main.py          — FastAPI app, startup/shutdown lifecycle
├── identity.py      — InsightFace + pyannote + FAISS logic
├── memory.py        — Graphiti client + mem0 client
├── models.py        — Pydantic request/response models
├── requirements.txt
└── data/            — FAISS index files (face.index, voice.index)
```

**Endpoints:**

| Method | Path | Purpose |
|---|---|---|
| POST | `/identity/face` | Identify or enroll a face |
| POST | `/identity/voice` | Identify or enroll a voice segment |
| POST | `/identity/enroll` | Explicit enrollment (name + face + voice) |
| POST | `/memory/ingest` | Snapshot JSON → Graphiti + mem0 |
| GET | `/memory/query` | Natural language query → fused results |
| POST | `/memory/reflect` | Trigger SelfModel reflection cycle |
| GET | `/health` | Liveness check |

**Launch:** `MemorySidecar.swift` uses `Foundation.Process` to launch `python3 memory_sidecar/main.py`. Polls `/health` with 500ms intervals, times out after 10s.

---

## Environment Variables

```
OPENAI_API_KEY=...        # already present — used by mem0 + GPT-4o reflection
NEO4J_URI=...             # Neo4j Aura bolt URI
NEO4J_USER=...
NEO4J_PASSWORD=...
MEMORY_SIDECAR_PORT=7700  # optional override, default 7700
```

---

## Error Handling

| Failure | Behaviour |
|---|---|
| Sidecar fails to start | Log warning, `MemoryEngine` disabled, all perception continues |
| Face lookup timeout (>2s) | Skip frame, retry next cycle |
| Neo4j Aura unreachable | Buffer up to 100 snapshots, retry with exponential backoff |
| mem0 API error | Log and skip — non-critical |
| Unknown face, no input for 60s | Emit prompt once more, then stay silent until next session |
| GPT-4o name extraction returns nothing | No-op, passive inference continues next cycle |
| FAISS index corrupted | Rebuild from IdentityStore SQLite on next launch |

---

## Success Criteria

| Criterion | How to verify |
|---|---|
| Recognizes same face across sessions | Restart banti, re-appear on camera — name logged without re-enrollment |
| Recognizes same voice across sessions | Restart banti, speak — speaker name in SpeechState transcript |
| Passive name inference works | Say "Hi John" near mic while John is on camera — John enrolled without prompt |
| Proactive introduction fires | New unknown face visible 30s — text prompt emitted |
| Temporal query works | Ask "who was here at 3pm?" — Graphiti returns correct person |
| Semantic query works | Ask "what do I know about John?" — mem0 returns facts |
| Self-model persists | Restart banti — `self.json` retains known people and schedule patterns |
| Graceful degradation | Kill sidecar mid-run — banti continues logging perception, no crash |
